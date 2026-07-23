---
name: create-k8-credential
description: Create, rotate, and verify DataSurface Yellow runtime credentials. Use for administrator-managed Kubernetes Secrets on local, AWS, or Azure deployments, or for an explicitly requested External Secrets Operator integration.
---

# Create a DataSurface Yellow credential

DataSurface model code names and types credentials; it never contains their values. Yellow
workloads consume namespace-local Kubernetes Secrets. The `demo1` local, AWS, and Azure starter
RTEs set `externalSecretProvider=None`, so an administrator creates those Secrets directly.
Customers can opt into External Secrets Operator (ESO); when enabled, AWS Secrets Manager, Azure
Key Vault, or Vault becomes the source of truth and ESO creates the same Kubernetes Secret shape.

Never print, decode, commit, or put credential values directly in a manifest. Verification should
inspect names, key names, ownership, and Ready conditions only.

## 1. Resolve the required Secret

Start from the model declaration:

```python
from datasurface.security import Credential, CredentialType

merge_credential = Credential("postgres-demo-merge", CredentialType.USER_PASSWORD)
```

Yellow normalizes the model name to an RFC 1123 Kubernetes Secret name:

1. lowercase;
2. `_` and spaces become `-`;
3. other characters are removed;
4. repeated and edge hyphens are removed.

Examples:

| Model name | Kubernetes Secret |
|---|---|
| `postgres-demo-merge` | `postgres-demo-merge` |
| `Source_DB` | `source-db` |
| `Snowflake Prod` | `snowflake-prod` |

Distinct model names must not normalize to the same Secret name. Current model lint and ESO
reconciliation reject collisions.

## 2. Use canonical Secret keys

| CredentialType | Required keys | Optional keys |
|---|---|---|
| `USER_PASSWORD` | `USER`, `PASSWORD` | — |
| `API_TOKEN` | `TOKEN` | — |
| `API_KEY_PAIR` | `API_KEY`, `API_SECRET` | — |
| `PRIVATE_KEY_AUTH` | `USER`, `PRIVATE_KEY` | `PASSPHRASE` |
| `MTLS_CERT_WITH_KEY` | `PUBLIC_CERT`, `PRIVATE_KEY` | `PASSPHRASE` |
| `CA_CERT_BUNDLE` | `CA_CERT` | — |
| `PUBLIC_KEY` | `PUBLIC_KEY` | — |
| `PRIVATE_KEY` | `PRIVATE_KEY` | — |

`FILE_TOKEN` is supplied by the runtime as a mounted file and is intentionally not materialized
by Yellow's Kubernetes environment-variable credential store or by ESO.

Old key sets such as `PUB`/`PRV`/`PWD`, `CLIENT_CERT_WITH_KEY`, or lowercase-only `token` are stale.
Use the canonical keys above. ESO accepts lowercase aliases from a remote JSON object for required
fields, but writes canonical uppercase keys to the Kubernetes Secret; new secrets should use the
canonical form directly.

## 3A. Local Kubernetes: create the Secret directly

Use environment variables or protected temporary files so literal values do not appear in the
command text. This idempotent pattern updates an existing Secret:

```bash
NAMESPACE=demo1
CREDENTIAL_NAME=postgres-demo-merge

kubectl create secret generic "$CREDENTIAL_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=USER="$DB_USER" \
  --from-literal=PASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

API token:

```bash
kubectl create secret generic git \
  --namespace "$NAMESPACE" \
  --from-literal=TOKEN="$GITHUB_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

PEM material should come from a file:

```bash
kubectl create secret generic snowflake-prod \
  --namespace "$NAMESPACE" \
  --from-literal=USER="$SNOWFLAKE_USER" \
  --from-file=PRIVATE_KEY=/secure/path/rsa_key.p8 \
  --from-literal=PASSPHRASE="$SNOWFLAKE_PASSPHRASE" \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

Do not use `stringData` or base64 text checked into Git. A Kubernetes Secret is not encrypted merely
because its `data` fields are base64 encoded.

## 3B. Optional AWS ESO: write the remote JSON object

When a customer explicitly sets `externalSecretProvider="aws"`, DataSurface expects one JSON object
per model credential at:

```text
datasurface/<normalized-namespace>/<normalized-ecosystem>/<normalized-credential>
```

For namespace `demo1-aws`, ecosystem `Demo`, and credential `postgres-demo-merge`:

```bash
REMOTE_KEY="datasurface/demo1-aws/demo/postgres-demo-merge"
SECRET_JSON=$(jq -cn --arg user "$DB_USER" --arg password "$DB_PASSWORD" \
  '{USER:$user,PASSWORD:$password}')

if aws secretsmanager describe-secret --secret-id "$REMOTE_KEY" \
     --region "$AWS_REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$REMOTE_KEY" \
    --secret-string "$SECRET_JSON" --region "$AWS_REGION" >/dev/null
else
  aws secretsmanager create-secret --name "$REMOTE_KEY" \
    --secret-string "$SECRET_JSON" --region "$AWS_REGION" >/dev/null
fi
unset SECRET_JSON
```

The namespace must contain a Ready `SecretStore` named `datasurface-runtime-secrets`. Generated
bootstrap/model-merge resources own the `ExternalSecret`; do not hand-create a competing
`ExternalSecret` with the same name.

## 3C. Optional Azure ESO: write the remote JSON object

When a customer explicitly sets `externalSecretProvider="azure"`, Azure Key Vault does not allow
`/` in secret names, so DataSurface uses:

```text
datasurface--<normalized-namespace>--<normalized-ecosystem>--<normalized-credential>--credentials
```

Example:

```bash
REMOTE_KEY="datasurface--demo1-azure--demo--sqlserver-demo-merge--credentials"
SECRET_JSON=$(jq -cn --arg user "$DB_USER" --arg password "$DB_PASSWORD" \
  '{USER:$user,PASSWORD:$password}')

az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$REMOTE_KEY" \
  --value "$SECRET_JSON" \
  --output none
unset SECRET_JSON
```

The namespace must contain a Ready `SecretStore` named `datasurface-runtime-secrets` configured for
Azure Workload Identity. Airflow pods do not need direct Key Vault access.

## 4. Reconcile and verify without exposing values

With ESO enabled, bootstrap credentials such as Git and merge database credentials are emitted as
`ExternalSecret` resources in `kubernetes-bootstrap.yaml`. Credentials discovered from the live
model are reconciled by the generated infrastructure DAG's plan → ESO reconcile → publish
sequence. With `externalSecretProvider=None`, there are no generated `ExternalSecret` resources;
create and rotate the namespace-local Secrets directly.

```bash
kubectl get secretstore datasurface-runtime-secrets -n "$NAMESPACE"
kubectl get externalsecrets -n "$NAMESPACE"
kubectl wait --for=condition=Ready \
  externalsecret/"$CREDENTIAL_NAME" -n "$NAMESPACE" --timeout=300s

# Show only key names, never values.
kubectl get secret "$CREDENTIAL_NAME" -n "$NAMESPACE" \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
```

For local direct Secrets, omit the `ExternalSecret` checks:

```bash
kubectl get secret "$CREDENTIAL_NAME" -n "$NAMESPACE"
kubectl describe secret "$CREDENTIAL_NAME" -n "$NAMESPACE"
```

After rotation, ESO refreshes the target Secret. Restart or rerun only the workloads that read the
credential at process start; do not restart healthy unrelated pipelines.

## Troubleshooting

- `SecretStore` not Ready: inspect `kubectl describe secretstore ...` and the external-secrets
  controller logs. Fix cloud identity, region/vault URL, or RBAC first.
- `ExternalSecret` not Ready: confirm the exact normalized remote key and required JSON fields.
- Secret exists but a job reports a missing credential: compare the model name, normalized Secret
  name, credential type, and canonical key names.
- Two credentials collide after normalization: rename one in the model; never share one Secret
  accidentally.
- Avoid `kubectl exec ... env`, `base64 -d`, shell tracing, and verbose cloud CLI output during
  diagnosis because those can disclose credential values.
