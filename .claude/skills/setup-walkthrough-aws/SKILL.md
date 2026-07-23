---
name: setup-walkthrough-aws
description: Set up demo1 on AWS EKS with RDS PostgreSQL, EFS, Airflow 3.3, administrator-managed Kubernetes Secrets, and the generated SCD4 infrastructure DAG. Use for a new or rebuilt AWS demo1 environment; optionally add ESO.
---

# DataSurface AWS EKS setup walkthrough

The starter path uses:

- DataSurface `1.8.4`;
- Airflow `3.3.0`;
- EKS, RDS PostgreSQL, and EFS;
- SCD4 platform `Demo_PSP`;
- administrator-managed namespace-local Kubernetes Secrets;
- ring 1 bootstrap followed by model merge through `demo-psp_infrastructure`.

`rte_aws.py` explicitly sets `externalSecretProvider=None`. External Secrets Operator is an
optional customer choice, not a prerequisite. Airflow pods do not need AWS Secrets Manager access
in the starter configuration.

## Execution rules

1. Verify the AWS account, region, cluster, namespace, and repository before every mutation.
2. Do not delete stacks, databases, releases, tags, or namespaces unless a clean rebuild was
   explicitly requested.
3. Keep passwords and tokens out of committed Helm values and command output.
4. Use a temporary rendered Helm values file.
5. Do not look for or apply a standalone model-merge Job. Current model merge runs inside the
   infrastructure DAG.

## Preflight

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_REGION:-us-east-1}
STACK_NAME=<short-stack-name>
KEY_PAIR_NAME=<ec2-key-pair>
NAMESPACE=${NAMESPACE:-demo1-aws}
DATASURFACE_VERSION=${DATASURFACE_VERSION:-1.8.4}
MODEL_REPO=<owner/model-repo>
AIRFLOW_REPO=<owner/dag-repo>
GITHUB_USERNAME=<github-user>

aws sts get-caller-identity
kubectl version --client
helm version
docker version
git status --short
```

Also require `DATABASE_PASSWORD`, `AIRFLOW_ADMIN_PASSWORD`, `GITHUB_TOKEN`,
`GITLAB_CUSTOMER_USER`, and `GITLAB_CUSTOMER_TOKEN` in the environment, plus `jq` and `python3` on
the operator machine. Do not echo secret values.

## 1. Provision or reuse AWS infrastructure

For a new environment, deploy the checked-in two-stage CloudFormation templates:

```bash
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file aws-marketplace/cloudformation/datasurface-eks-stack.yaml \
  --parameter-overrides \
    KeyPairName="$KEY_PAIR_NAME" \
    DatabasePassword="$DATABASE_PASSWORD" \
    CreateDatabase=true \
    KubernetesDeploymentType=EKS-EC2 \
  --capabilities CAPABILITY_IAM \
  --region "$AWS_REGION"
```

Capture outputs:

```bash
CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' --output text)
POSTGRES_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DatabaseEndpoint`].OutputValue' --output text)
EFS_FILE_SYSTEM_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' --output text)
OIDC_PROVIDER_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EKSOIDCProviderArn`].OutputValue' --output text)

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl get nodes -o wide
```

Deploy the IAM roles stack for the EFS CSI driver. The default stack does not create an
External Secrets role:

```bash
aws cloudformation deploy \
  --stack-name "${STACK_NAME}-iam-roles" \
  --template-file aws-marketplace/cloudformation/iam-roles-for-eks.yaml \
  --parameter-overrides \
    EKSOIDCProviderArn="$OIDC_PROVIDER_ARN" \
    StackName="$STACK_NAME" \
  --capabilities CAPABILITY_IAM \
  --region "$AWS_REGION"
```

## 2. Configure EFS and database connectivity

Scope the EFS role's IRSA trust to
`system:serviceaccount:kube-system:efs-csi-controller-sa`, then install the EKS add-on and annotate
that service account. Do not add Airflow service accounts to the trust policy.

```bash
EFS_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EFSCSIDriverRoleArn`].OutputValue' --output text)
EFS_ROLE_NAME=${EFS_ROLE_ARN##*/}
OIDC_ISSUER=${OIDC_PROVIDER_ARN#*/}

TRUST_FILE=$(mktemp)
jq -n \
  --arg provider "$OIDC_PROVIDER_ARN" \
  --arg sub_key "${OIDC_ISSUER}:sub" \
  --arg aud_key "${OIDC_ISSUER}:aud" \
  '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Federated:$provider},
      Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{StringEquals:{
        ($sub_key):"system:serviceaccount:kube-system:efs-csi-controller-sa",
        ($aud_key):"sts.amazonaws.com"
      }}
    }]
  }' > "$TRUST_FILE"
aws iam update-assume-role-policy \
  --role-name "$EFS_ROLE_NAME" \
  --policy-document "file://$TRUST_FILE"
rm -f "$TRUST_FILE"

if aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-efs-csi-driver \
    --service-account-role-arn "$EFS_ROLE_ARN" \
    --resolve-conflicts PRESERVE \
    --region "$AWS_REGION"
else
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-efs-csi-driver \
    --service-account-role-arn "$EFS_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --region "$AWS_REGION"
fi
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION"
```

Create the RWX storage class:

```bash
cat <<YAML | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_FILE_SYSTEM_ID}
  directoryPerms: "0755"
  uid: "50000"
  gid: "50000"
volumeBindingMode: Immediate
YAML
```

Confirm the RDS security group allows port `5432` from the EKS managed cluster/node security
groups. Test from a short-lived pod before continuing.

Create `airflow_db` and `merge_db` if they do not exist:

```bash
kubectl run db-setup --restart=Never --image=postgres:16 \
  --env="PGPASSWORD=$DATABASE_PASSWORD" \
  --command -- bash -ceu \
  "psql -h '$POSTGRES_ENDPOINT' -U postgres -At -c \
   \"SELECT 1 FROM pg_database WHERE datname='airflow_db'\" | grep -q 1 ||
   psql -h '$POSTGRES_ENDPOINT' -U postgres -c 'CREATE DATABASE airflow_db';
   psql -h '$POSTGRES_ENDPOINT' -U postgres -At -c \
   \"SELECT 1 FROM pg_database WHERE datname='merge_db'\" | grep -q 1 ||
   psql -h '$POSTGRES_ENDPOINT' -U postgres -c 'CREATE DATABASE merge_db'"
kubectl wait --for=condition=Ready pod/db-setup --timeout=120s
kubectl logs db-setup
kubectl delete pod db-setup
```

## 3. Configure the model and temporary Helm values

Update:

- `eco.py` to import `createDemoRTE` from `rte_aws` and use `MODEL_REPO`;
- `rte_aws.py` placeholders for namespace, RDS PostgreSQL endpoint, and AWS account;
- DataSurface image tag to `v1.8.4`;
- keep `externalSecretProvider=None`.

Create a non-committed values file:

```bash
cp helm/airflow-values-aws.yaml /tmp/airflow-values-aws.yaml
sed -i.bak \
  -e "s|PLACEHOLDER_AIRFLOW_REPO|$AIRFLOW_REPO|g" \
  /tmp/airflow-values-aws.yaml
rm -f /tmp/airflow-values-aws.yaml.bak

AIRFLOW_ADMIN_PASSWORD="$AIRFLOW_ADMIN_PASSWORD" \
  python3 - /tmp/airflow-values-aws.yaml <<'PY'
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
chmod 600 /tmp/airflow-values-aws.yaml

if rg -n 'PLACEHOLDER_[A-Z0-9_]+' /tmp/airflow-values-aws.yaml; then
  echo "Unresolved Airflow values placeholder" >&2
  exit 1
fi
git diff --check
.venv/bin/python -m unittest test_loads
```

Do not commit `/tmp/airflow-values-aws.yaml`.

## 4. Publish a stable model release

Commit only model/template changes, push `main`, create the next `vN.N.N-demo` tag, and publish a
stable GitHub Release. Do not delete all historical tags/releases.

```bash
git remote set-url origin "https://github.com/${MODEL_REPO}.git"
git add eco.py rte_aws.py requirements.txt
git commit -m "Configure DataSurface for AWS EKS"
git push -u origin main

git fetch --tags
git tag -l 'v*-demo' | sort -V | tail -5
MODEL_TAG=<next-vN.N.N-demo>
git tag -a "$MODEL_TAG" -m "$MODEL_TAG"
git push origin "$MODEL_TAG"
```

Create a non-draft, non-prerelease GitHub Release for `$MODEL_TAG`.

## 5. Create namespace-local Secrets

Use `create-k8-credential` for canonical key shapes and safe rotation.

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -

AIRFLOW_METADATA_URI=$(
  DATABASE_PASSWORD="$DATABASE_PASSWORD" POSTGRES_ENDPOINT="$POSTGRES_ENDPOINT" python3 -c \
  'import os; from urllib.parse import quote; print("postgresql+psycopg2://postgres:" + quote(os.environ["DATABASE_PASSWORD"], safe="") + "@" + os.environ["POSTGRES_ENDPOINT"] + ":5432/airflow_db?sslmode=require")'
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

kubectl create secret generic postgres-demo-merge \
  --namespace "$NAMESPACE" \
  --from-literal=USER=postgres \
  --from-literal=PASSWORD="$DATABASE_PASSWORD" \
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

Verify names/key names without decoding values:

```bash
kubectl get secrets -n "$NAMESPACE"
kubectl describe secret airflow-metadata -n "$NAMESPACE"
kubectl describe secret postgres-demo-merge -n "$NAMESPACE"
kubectl describe secret git -n "$NAMESPACE"
```

No AWS Secrets Manager objects, Secrets Store CSI driver, or SecretProviderClass are required for
the starter path.

## 6. Generate and validate bootstrap artifacts

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

## 7. Publish generated DAGs before Airflow starts

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

## 8. Install Airflow 3.3 and secret-read RBAC

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow
helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  --values /tmp/airflow-values-aws.yaml \
  --set images.airflow.tag=3.3.0-azure-supported-merge-drivers-20260714 \
  --set defaultAirflowTag=3.3.0-azure-supported-merge-drivers-20260714 \
  --reset-values --timeout 20m --wait
rm -f /tmp/airflow-values-aws.yaml
```

The generated Airflow secret manager reads namespace-local Kubernetes Secrets. Grant read-only
access to Airflow component service accounts:

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

Airflow service accounts need no IRSA annotations in this default path.

## 9. Apply bootstrap, ring 1, and infrastructure merge

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

## 10. Verify

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
Airflow pods, stable restarts, and no unresolved warning events. Discover generated SCD4 DAG IDs
from Airflow; do not rely on a historical fixed list.

## Optional: enable ESO for a customer

Only when requested:

1. set `externalSecretProvider="aws"` in `rte_aws.py`;
2. install External Secrets Operator;
3. provision a dedicated, read-only IAM role scoped to the ESO service account and only this
   environment's `datasurface/...` secret prefix;
4. create a namespaced `SecretStore` named `datasurface-runtime-secrets`;
5. put canonical credential JSON at
   `datasurface/<normalized-namespace>/<normalized-ecosystem>/<credential>`;
6. regenerate/apply bootstrap and wait for every generated `ExternalSecret` to become Ready.

Use `create-k8-credential` for the exact keys and remote naming. Do not give Airflow pods direct
Secrets Manager permissions.

## Simulator and teardown

After the source database and source credential exist, use `create-customer-data-simulator`.
For removal, use `teardown-walkthrough-aws`; it includes cost-bearing resource checks and optional
ESO cleanup without assuming ESO was installed.
