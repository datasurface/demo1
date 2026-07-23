---
name: setup-walkthrough-azure
description: Set up demo1 on Azure AKS with PostgreSQL Flexible Server, Azure SQL, Azure Files NFS, Airflow 3.3, administrator-managed Kubernetes Secrets, and the generated SCD4 infrastructure DAG. Use for a new or rebuilt Azure demo1 environment; optionally add ESO.
---

# DataSurface Azure AKS setup walkthrough

The starter path uses:

- DataSurface `1.8.4`;
- Airflow `3.3.0` with the supported merge-database drivers;
- AKS, PostgreSQL Flexible Server for Airflow metadata, and Azure SQL for the merge database;
- Azure Files NFS for RWX git cache/log storage;
- SCD4 platform `Demo_PSP`;
- administrator-managed namespace-local Kubernetes Secrets;
- ring 1 bootstrap followed by model merge through `demo-psp_infrastructure`.

`rte_azure.py` explicitly sets `externalSecretProvider=None`. Azure Key Vault, Workload Identity,
and External Secrets Operator are optional customer integrations. Airflow pods do not need direct
Key Vault access in the starter configuration.

## Execution rules

1. Verify the subscription, tenant, resource group, region, cluster, namespace, and repository
   before every mutation.
2. Do not delete resource groups, databases, namespaces, releases, or tags unless a clean rebuild
   was explicitly requested.
3. Keep passwords and tokens out of Git, shell tracing, and command output.
4. Render a temporary Helm values file; leave checked-in placeholders intact.
5. Do not apply a standalone model-merge Job. Current model merge runs inside the infrastructure
   DAG.

## Preflight

```bash
az account show --query '{subscription:id,tenant:tenantId,user:user.name}' -o table

AZURE_REGION=${AZURE_REGION:-westus2}
RESOURCE_GROUP=<resource-group>
CLUSTER_NAME=<aks-name>
NAMESPACE=${NAMESPACE:-demo1-azure}
PG_SERVER_NAME=<globally-unique-pg-name>
PG_ADMIN_USER=<pg-admin>
SQL_SERVER_NAME=<globally-unique-sql-name>
SQL_ADMIN_USER=<sql-admin>
DATASURFACE_VERSION=${DATASURFACE_VERSION:-1.8.4}
MODEL_REPO=<owner/model-repo>
AIRFLOW_REPO=<owner/dag-repo>
GITHUB_USERNAME=<github-user>

az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.DBforPostgreSQL
az provider register --namespace Microsoft.Sql
az provider register --namespace Microsoft.Network
```

Also require `PG_ADMIN_PASSWORD`, `SQL_ADMIN_PASSWORD`, `AIRFLOW_ADMIN_PASSWORD`, `GITHUB_TOKEN`,
`GITLAB_CUSTOMER_USER`, and `GITLAB_CUSTOMER_TOKEN` in the environment. Azure-compatible strong
passwords may contain special characters when variables are quoted correctly; do not weaken them
to work around shell quoting. Require `python3` on the operator machine for safe encoding.

Keep AKS, VNet, PostgreSQL, Azure SQL, and private endpoints in the same region. If a subscription
blocks a SKU/region, choose an allowed region before provisioning rather than building a
cross-region workaround.

## 1. Provision or reuse Azure infrastructure

For a new environment:

```bash
az group create --name "$RESOURCE_GROUP" --location "$AZURE_REGION"

az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name datasurface-vnet \
  --address-prefixes 10.0.0.0/16 \
  --subnet-name aks-subnet \
  --subnet-prefixes 10.0.0.0/20

az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name datasurface-vnet \
  --name postgres-subnet \
  --address-prefixes 10.0.16.0/24 \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name datasurface-vnet \
  --name private-endpoints-subnet \
  --address-prefixes 10.0.17.0/24
```

Create AKS:

```bash
AKS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name datasurface-vnet \
  --name aks-subnet --query id -o tsv)

az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$AZURE_REGION" \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --network-plugin azure \
  --vnet-subnet-id "$AKS_SUBNET_ID" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" --overwrite-existing
kubectl get nodes -o wide
```

OIDC/Workload Identity is harmless in the default path and makes an optional future ESO setup
possible; no Airflow identity is created or annotated.

## 2. Provision Airflow and merge databases

Create the VNet-integrated PostgreSQL Flexible Server, then create `airflow_db`:

```bash
PG_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name datasurface-vnet \
  --name postgres-subnet --query id -o tsv)

PG_PRIVATE_DNS_ZONE="${PG_SERVER_NAME}.private.postgres.database.azure.com"
az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PG_PRIVATE_DNS_ZONE"
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$PG_PRIVATE_DNS_ZONE" \
  --name "${CLUSTER_NAME}-postgres-link" \
  --virtual-network datasurface-vnet \
  --registration-enabled false
PG_PRIVATE_DNS_ZONE_ID=$(az network private-dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PG_PRIVATE_DNS_ZONE" --query id -o tsv)

az postgres flexible-server create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PG_SERVER_NAME" \
  --location "$AZURE_REGION" \
  --admin-user "$PG_ADMIN_USER" \
  --admin-password "$PG_ADMIN_PASSWORD" \
  --sku-name Standard_D2s_v3 \
  --tier GeneralPurpose \
  --storage-size 128 \
  --subnet "$PG_SUBNET_ID" \
  --private-dns-zone "$PG_PRIVATE_DNS_ZONE_ID"

az postgres flexible-server db create \
  --resource-group "$RESOURCE_GROUP" \
  --server-name "$PG_SERVER_NAME" \
  --database-name airflow_db

PG_FQDN=$(az postgres flexible-server show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PG_SERVER_NAME" --query fullyQualifiedDomainName -o tsv)
```

Create Azure SQL and `merge_db`:

```bash
az sql server create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_SERVER_NAME" \
  --location "$AZURE_REGION" \
  --admin-user "$SQL_ADMIN_USER" \
  --admin-password "$SQL_ADMIN_PASSWORD"

az sql db create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER_NAME" \
  --name merge_db \
  --service-objective S2

SQL_SERVER_FQDN=$(az sql server show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_SERVER_NAME" --query fullyQualifiedDomainName -o tsv)
```

Create a private endpoint and link the standard Azure SQL private DNS zone:

```bash
SQL_SERVER_ID=$(az sql server show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_SERVER_NAME" --query id -o tsv)

az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name privatelink.database.windows.net
az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name privatelink.database.windows.net \
  --name "${CLUSTER_NAME}-sql-link" \
  --virtual-network datasurface-vnet \
  --registration-enabled false
SQL_PRIVATE_DNS_ZONE_ID=$(az network private-dns zone show \
  --resource-group "$RESOURCE_GROUP" \
  --name privatelink.database.windows.net --query id -o tsv)

az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "${SQL_SERVER_NAME}-private-endpoint" \
  --vnet-name datasurface-vnet \
  --subnet private-endpoints-subnet \
  --private-connection-resource-id "$SQL_SERVER_ID" \
  --group-id sqlServer \
  --connection-name "${SQL_SERVER_NAME}-private-connection"

az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name "${SQL_SERVER_NAME}-private-endpoint" \
  --name default \
  --private-dns-zone "$SQL_PRIVATE_DNS_ZONE_ID" \
  --zone-name privatelink.database.windows.net
```

After both database names resolve to private addresses inside AKS, disable Azure SQL public
network access:

```bash
az sql server update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SQL_SERVER_NAME" \
  --enable-public-network false
```

Verify from the namespace with short-lived `postgres` and SQL client pods before installing
Airflow. Do not proceed on public/private DNS ambiguity.

## 3. Verify RWX storage

Modern AKS normally includes `azurefile-csi-nfs`:

```bash
kubectl get storageclass azurefile-csi-nfs

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datasurface-rwx-test
spec:
  accessModes: [ReadWriteMany]
  storageClassName: azurefile-csi-nfs
  resources:
    requests:
      storage: 1Gi
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/datasurface-rwx-test --timeout=180s
kubectl delete pvc datasurface-rwx-test
```

Current git cache lint requires `ReadWriteMany`; do not substitute an RWO disk class.

## 4. Configure the model and temporary Helm values

Update:

- `eco.py` to import `createDemoRTE` from `rte_azure` and use `MODEL_REPO`;
- `rte_azure.py` placeholders for namespace, SQL FQDN, and PostgreSQL FQDN;
- DataSurface image tag to `v1.8.4`;
- keep `externalSecretProvider=None`.

Create a non-committed values file:

```bash
cp helm/airflow-values-azure.yaml /tmp/airflow-values-azure.yaml
sed -i.bak \
  -e "s|PLACEHOLDER_AIRFLOW_REPO|$AIRFLOW_REPO|g" \
  /tmp/airflow-values-azure.yaml
rm -f /tmp/airflow-values-azure.yaml.bak

AIRFLOW_ADMIN_PASSWORD="$AIRFLOW_ADMIN_PASSWORD" \
  python3 - /tmp/airflow-values-azure.yaml <<'PY'
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(
    path.read_text().replace(
        "PLACEHOLDER_AIRFLOW_ADMIN_PASSWORD",
        json.dumps(os.environ["AIRFLOW_ADMIN_PASSWORD"]),
    )
)
PY
chmod 600 /tmp/airflow-values-azure.yaml

if rg -n 'PLACEHOLDER_[A-Z0-9_]+' /tmp/airflow-values-azure.yaml; then
  echo "Unresolved Airflow values placeholder" >&2
  exit 1
fi
git diff --check
.venv/bin/python -m unittest test_loads
```

The checked-in Airflow image is
`registry.gitlab.com/datasurface-inc/datasurface/airflow:3.3.0-azure-supported-merge-drivers-20260714`.
It supplies the SQL Server merge drivers. The starter does not require Key Vault SDKs in Airflow.

## 5. Publish a stable model release

Commit only model/template changes, push `main`, create the next `vN.N.N-demo` tag, and publish a
stable GitHub Release. Do not delete historical tags/releases.

```bash
git remote set-url origin "https://github.com/${MODEL_REPO}.git"
git add eco.py rte_azure.py requirements.txt
git commit -m "Configure DataSurface for Azure AKS"
git push -u origin main

git fetch --tags
git tag -l 'v*-demo' | sort -V | tail -5
MODEL_TAG=<next-vN.N.N-demo>
git tag -a "$MODEL_TAG" -m "$MODEL_TAG"
git push origin "$MODEL_TAG"
```

Create a non-draft, non-prerelease GitHub Release for `$MODEL_TAG`.

## 6. Create namespace-local Secrets

Use `create-k8-credential` for canonical key shapes and safe rotation:

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -

AIRFLOW_METADATA_URI=$(
  PG_ADMIN_USER="$PG_ADMIN_USER" PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD" PG_FQDN="$PG_FQDN" \
  python3 -c \
  'import os; from urllib.parse import quote; print("postgresql+psycopg2://" + quote(os.environ["PG_ADMIN_USER"], safe="") + ":" + quote(os.environ["PG_ADMIN_PASSWORD"], safe="") + "@" + os.environ["PG_FQDN"] + ":5432/airflow_db?sslmode=require")'
)
kubectl create secret generic airflow-metadata \
  --namespace "$NAMESPACE" \
  --from-literal=connection="$AIRFLOW_METADATA_URI" \
  --dry-run=client -o yaml |
  kubectl apply -f -
unset AIRFLOW_METADATA_URI

kubectl create secret generic git \
  --namespace "$NAMESPACE" \
  --from-literal=TOKEN="$GITHUB_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl create secret generic sqlserver-demo-merge \
  --namespace "$NAMESPACE" \
  --from-literal=USER="$SQL_ADMIN_USER" \
  --from-literal=PASSWORD="$SQL_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl create secret generic git-dags \
  --namespace "$NAMESPACE" \
  --from-literal=GIT_SYNC_USERNAME="$GITHUB_USERNAME" \
  --from-literal=GIT_SYNC_PASSWORD="$GITHUB_TOKEN" \
  --from-literal=GITSYNC_USERNAME="$GITHUB_USERNAME" \
  --from-literal=GITSYNC_PASSWORD="$GITHUB_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl create secret docker-registry datasurface-registry \
  --namespace "$NAMESPACE" \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl patch serviceaccount default -n "$NAMESPACE" \
  -p '{"imagePullSecrets":[{"name":"datasurface-registry"}]}'
```

Quoting `"$SQL_ADMIN_PASSWORD"` preserves special characters. For multiline key material, use
`--from-file` as documented by `create-k8-credential`.

Verify names/key names only:

```bash
kubectl get secrets -n "$NAMESPACE"
kubectl describe secret airflow-metadata -n "$NAMESPACE"
kubectl describe secret sqlserver-demo-merge -n "$NAMESPACE"
kubectl describe secret git -n "$NAMESPACE"
```

No Key Vault, Secrets Store CSI driver, Workload Identity annotation, or manually duplicated
cloud/Kubernetes credential pair is required for the starter path.

## 7. Generate and validate bootstrap artifacts

```bash
IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}"
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 "$IMAGE"

docker run --rm --platform linux/amd64 \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  "$IMAGE" \
  python -m datasurface.entrypoints.platform generatePlatformBootstrap \
    --ringLevel 0 \
    --model /workspace/model \
    --output /workspace/model/generated_output \
    --psp Demo_PSP \
    --rte-name demo

find generated_output/Demo_PSP -maxdepth 1 -type f -print | sort
test ! -e generated_output/Demo_PSP/demo_psp_model_merge_job.yaml
for file in generated_output/Demo_PSP/*.yaml; do
  kubectl apply --dry-run=client -f "$file" >/dev/null
done
python -m py_compile generated_output/Demo_PSP/*_dag.py
```

With `externalSecretProvider=None`, `kubernetes-bootstrap.yaml` must not contain
`kind: ExternalSecret`.

## 8. Publish generated DAGs before Airflow starts

Initialize the DAG repository's `main` branch if necessary, remove only old generated `*_dag.py`
files, and copy every current generated DAG:

```bash
DAG_CLONE=$(mktemp -d)
git clone "https://github.com/${AIRFLOW_REPO}.git" "$DAG_CLONE"
mkdir -p "$DAG_CLONE/dags"
rm -f "$DAG_CLONE"/dags/*_dag.py
cp generated_output/Demo_PSP/*_dag.py "$DAG_CLONE/dags/"
git -C "$DAG_CLONE" add -A dags
git -C "$DAG_CLONE" commit -m "Refresh generated DataSurface DAGs"
git -C "$DAG_CLONE" push origin main
```

## 9. Install Airflow 3.3 and secret-read RBAC

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow
helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  --values /tmp/airflow-values-azure.yaml \
  --set images.airflow.tag=3.3.0-azure-supported-merge-drivers-20260714 \
  --set defaultAirflowTag=3.3.0-azure-supported-merge-drivers-20260714 \
  --reset-values --timeout 20m --wait
rm -f /tmp/airflow-values-azure.yaml
```

Grant read-only access to namespace-local Secrets:

```bash
cat <<YAML | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: airflow-secret-reader
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: airflow-secret-reader
  namespace: ${NAMESPACE}
subjects:
  - {kind: ServiceAccount, name: airflow-dag-processor, namespace: ${NAMESPACE}}
  - {kind: ServiceAccount, name: airflow-worker, namespace: ${NAMESPACE}}
  - {kind: ServiceAccount, name: airflow-scheduler, namespace: ${NAMESPACE}}
  - {kind: ServiceAccount, name: airflow-triggerer, namespace: ${NAMESPACE}}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: airflow-secret-reader
YAML
```

Airflow service accounts need no Azure Workload Identity annotations in this path.

## 10. Apply bootstrap, ring 1, and infrastructure merge

```bash
kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml
kubectl rollout status deployment/demo-psp-mcp-server \
  -n "$NAMESPACE" --timeout=300s

kubectl delete job demo-psp-ring1-init \
  -n "$NAMESPACE" --ignore-not-found --wait=true
kubectl apply -f generated_output/Demo_PSP/demo_psp_ring1_init_job.yaml
kubectl wait --for=condition=complete \
  job/demo-psp-ring1-init -n "$NAMESPACE" --timeout=300s

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger demo-psp_infrastructure
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
```

Wait for the new infrastructure run to reach `success`. Do not apply a
`demo_psp_model_merge_job.yaml`; it is obsolete.

## 11. Verify

```bash
kubectl get pods -n "$NAMESPACE" -o wide
kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning --sort-by=.lastTimestamp
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR airflow version
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR airflow dags list --output json
```

Verify Airflow `3.3.x`, no import errors, successful ring 1 and infrastructure runs, Ready MCP and
Airflow pods, stable restarts, private database DNS/connectivity, and no unresolved warning events.
Discover generated SCD4 DAG IDs from Airflow; do not rely on a historical fixed list.

## Optional: enable ESO for a customer

Only when requested:

1. set `externalSecretProvider="azure"` in `rte_azure.py`;
2. provision Key Vault and install External Secrets Operator;
3. create a dedicated service account and one federated Workload Identity credential;
4. grant that identity `Key Vault Secrets User`;
5. create a namespaced `SecretStore` named `datasurface-runtime-secrets`;
6. store canonical JSON at
   `datasurface--<normalized-namespace>--<normalized-ecosystem>--<credential>--credentials`;
7. regenerate/apply bootstrap and wait for every generated `ExternalSecret` to become Ready.

Use `create-k8-credential` for exact keys and naming. Do not grant Key Vault access to all Airflow
service accounts and do not install the Secrets Store CSI driver for the ESO path.

## Simulator and teardown

After source infrastructure and source credentials exist, use `create-customer-data-simulator`.
For removal, use `teardown-walkthrough-azure`; it treats Key Vault/ESO cleanup as optional and
verifies cost-bearing resources are gone.
