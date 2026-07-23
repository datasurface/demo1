---
name: remote-setup-walkthrough
description: Set up demo1 on a remote self-managed Kubernetes cluster over SSH with external PostgreSQL, RWX storage, Airflow 3.3, administrator-managed Kubernetes Secrets, and the current infrastructure DAG. Use for on-premises or private Kubernetes rather than EKS or AKS.
---

# Remote Kubernetes setup

This path adapts the local demo1 setup to a cluster reached over SSH. It uses:

- separate external PostgreSQL databases for Airflow metadata and DataSurface merge data;
- a storage class that supports `ReadWriteMany` for the shared Git cache;
- Airflow 3.3 with the tested DataSurface Airflow image;
- namespace-local Kubernetes Secrets by default;
- current ring-0 artifacts and infrastructure-DAG model merge.

Keep `externalSecretProvider=None` for the baseline. Add ESO only when the customer explicitly
chooses and operates it.

## Safety

1. Inspect existing namespaces, releases, databases, and storage before changing them.
2. Do not drop databases, delete PVCs, or remove Git releases during a normal setup or repair.
3. Keep credentials in environment variables or Secret input; never commit them.
4. Verify each stage before continuing.
5. Use a new model release; never move or delete an older release tag.

## Inputs and preflight

Set non-secret inputs, then export secret inputs without echoing them:

```bash
export SSH_KEY="<absolute-key-path>"
export SSH_USER="<remote-user>"
export SSH_HOST="<cluster-control-host>"
export NAMESPACE="demo1"
export STORAGE_CLASS="<rwx-storage-class>"
export AIRFLOW_DB_HOST="<airflow-postgres-host>"
export MERGE_DB_HOST="<merge-postgres-host>"
export PG_USER="<postgres-user>"
export MODEL_REPO="<owner/model-repo>"
export AIRFLOW_REPO="<owner/airflow-repo>"
export DATASURFACE_VERSION="${DATASURFACE_VERSION:-1.8.4}"

export SSH_CMD="ssh -i $SSH_KEY $SSH_USER@$SSH_HOST"
export SCP_CMD="scp -i $SSH_KEY"
```

Also export these secret inputs without echoing them: `PG_PASSWORD`, `GITHUB_USERNAME`,
`GITHUB_MODEL_PULL_TOKEN`, `GITHUB_DAG_PULL_TOKEN`, `GITLAB_CUSTOMER_USER`, and
`GITLAB_CUSTOMER_TOKEN`.

Require `python3` locally to URI-encode the Airflow metadata credential safely.

Verify access and current state:

```bash
$SSH_CMD "kubectl cluster-info"
$SSH_CMD "kubectl get nodes -o wide"
$SSH_CMD "kubectl get storageclass"
$SSH_CMD "kubectl get namespace '$NAMESPACE' 2>/dev/null || true"
$SSH_CMD "helm list -A"
```

Confirm the selected storage class supports RWX. For Longhorn, ensure every worker has an NFSv4
client installed. Do not assume package names or install software across nodes without the
operator's approval.

Confirm both database endpoints resolve and accept connections from a pod:

```bash
$SSH_CMD "kubectl run remote-db-check --rm -i --restart=Never \
  --image=busybox:1.36 -- \
  sh -c 'nslookup \"$AIRFLOW_DB_HOST\" && nc -vz \"$AIRFLOW_DB_HOST\" 5432 && \
  nslookup \"$MERGE_DB_HOST\" && nc -vz \"$MERGE_DB_HOST\" 5432'"
```

If DNS fails, have the cluster DNS administrator add the correct internal zone/forwarding. Avoid
hard-coded CoreDNS `hosts` entries unless they are the customer's established design.

## 1. Prepare databases

Create or verify separate databases such as `airflow_db` and `demo_merge`. Preserve existing data
unless the user explicitly requests a clean rebuild.

Test authentication from a trusted machine without printing the password:

```bash
PGPASSWORD="$PG_PASSWORD" psql \
  -h "$AIRFLOW_DB_HOST" -U "$PG_USER" -d airflow_db -c 'select 1'
PGPASSWORD="$PG_PASSWORD" psql \
  -h "$MERGE_DB_HOST" -U "$PG_USER" -d demo_merge -c 'select 1'
```

Ensure PostgreSQL permits the cluster's actual pod/node CIDRs and requires the customer's chosen
TLS mode. Do not copy example CIDRs into `pg_hba.conf` without discovering the real networks.

## 2. Configure the model

Update:

- `eco.py`: Git owner and repository;
- `rte_demo.py`: namespace, merge host, and `MERGE_DBNAME` (set it to the merge database
  created in Step 1, e.g. `demo_merge`; the starter default is `merge_db`), `ReadWriteMany`
  Git cache, selected storage class, and DataSurface image `v1.8.4`;
- `requirements.txt`: `datasurface==1.8.4`.

The Git cache must remain shared:

```python
git_config=GitCacheConfig(
    enabled=True,
    access_mode="ReadWriteMany",
    storageClass="<rwx-storage-class>",
)
```

Keep the RTE's `externalSecretProvider=None`.

Validate with the repository virtual environment:

```bash
.venv/bin/python -m unittest test_loads
git diff --check
```

## 3. Publish the model release

Use the normal reviewed flow to merge the configuration to `main`. Create the next
monotonically newer `vN.N.N-demo` tag and publish it as a stable, non-draft GitHub Release.

The Yellow model loader requires the release. A local commit or tag without a release is
insufficient.

## 4. Generate and publish bootstrap DAGs

Follow `generate-bootstrap/SKILL.md` with:

```bash
export PSP_NAME="Demo_PSP"
export RTE_NAME="demo"
export AIRFLOW_DAG_REPO="$AIRFLOW_REPO"
```

Use:

```bash
python -m datasurface.entrypoints.platform generatePlatformBootstrap
```

inside the `v1.8.4` image. Require these four artifacts:

```text
kubernetes-bootstrap.yaml
demo_psp_infrastructure_dag.py
demo_psp_ring1_init_job.yaml
demo_psp_reconcile_views_job.yaml
```

Publish every generated `*_dag.py` to the DAG repository before installing Airflow. Ensure its
`main` branch exists so git-sync can start.

## 5. Prepare remote Airflow values

Create a temporary copy of `helm/airflow-values.yaml`; do not overwrite the local example merely
to customize the remote installation:

```bash
export REMOTE_AIRFLOW_VALUES=$(mktemp /tmp/demo1-airflow-values.XXXXXX.yaml)
cp helm/airflow-values.yaml "$REMOTE_AIRFLOW_VALUES"
```

Update `$REMOTE_AIRFLOW_VALUES` with:

- `data.metadataSecretName: airflow-metadata`;
- `https://github.com/${AIRFLOW_REPO}.git`;
- the RWX storage class for logs and the appropriate class for Redis/workers;
- the current tested Airflow tag
  `3.3.0-azure-supported-merge-drivers-20260714`;
- production-appropriate Airflow admin credentials.

Keep the custom Airflow image repository:

```text
registry.gitlab.com/datasurface-inc/datasurface/airflow
```

Render before installing:

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow
helm template airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  --values "$REMOTE_AIRFLOW_VALUES" >/tmp/demo1-airflow-rendered.yaml
```

Review the render for the expected storage classes, image tag, DAG repository, and
`airflow-metadata` Secret reference.
Delete the temporary values/render files after the installation is verified.

## 6. Create namespace-local Secrets

Create the namespace if absent:

```bash
$SSH_CMD "kubectl create namespace '$NAMESPACE' --dry-run=client -o yaml | kubectl apply -f -"
```

Apply Secrets idempotently from local input. Keep the pipe input out of version control:

```bash
AIRFLOW_METADATA_URI=$(
  PG_USER="$PG_USER" PG_PASSWORD="$PG_PASSWORD" AIRFLOW_DB_HOST="$AIRFLOW_DB_HOST" \
  python3 -c \
  'import os; from urllib.parse import quote; print("postgresql+psycopg2://" + quote(os.environ["PG_USER"], safe="") + ":" + quote(os.environ["PG_PASSWORD"], safe="") + "@" + os.environ["AIRFLOW_DB_HOST"] + ":5432/airflow_db?sslmode=require")'
)
kubectl create secret generic airflow-metadata \
  --namespace "$NAMESPACE" \
  --from-literal=connection="$AIRFLOW_METADATA_URI" \
  --dry-run=client -o yaml |
  $SSH_CMD "kubectl apply -f -"
unset AIRFLOW_METADATA_URI

kubectl create secret generic postgres-demo-merge \
  --namespace "$NAMESPACE" \
  --from-literal=USER="$PG_USER" \
  --from-literal=PASSWORD="$PG_PASSWORD" \
  --dry-run=client -o yaml |
  $SSH_CMD "kubectl apply -f -"

kubectl create secret generic git \
  --namespace "$NAMESPACE" \
  --from-literal=TOKEN="$GITHUB_MODEL_PULL_TOKEN" \
  --dry-run=client -o yaml |
  $SSH_CMD "kubectl apply -f -"

kubectl create secret generic git-dags \
  --namespace "$NAMESPACE" \
  --from-literal=GIT_SYNC_USERNAME="$GITHUB_USERNAME" \
  --from-literal=GIT_SYNC_PASSWORD="$GITHUB_DAG_PULL_TOKEN" \
  --from-literal=GITSYNC_USERNAME="$GITHUB_USERNAME" \
  --from-literal=GITSYNC_PASSWORD="$GITHUB_DAG_PULL_TOKEN" \
  --dry-run=client -o yaml |
  $SSH_CMD "kubectl apply -f -"

kubectl create secret docker-registry datasurface-registry \
  --namespace "$NAMESPACE" \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  --dry-run=client -o yaml |
  $SSH_CMD "kubectl apply -f -"
```

Patch the default service account:

```bash
$SSH_CMD "kubectl patch serviceaccount default -n '$NAMESPACE' \
  -p '{\"imagePullSecrets\":[{\"name\":\"datasurface-registry\"}]}'"
```

Verify names and keys only:

```bash
$SSH_CMD "kubectl get secrets -n '$NAMESPACE'"
$SSH_CMD "kubectl describe secret airflow-metadata -n '$NAMESPACE'"
$SSH_CMD "kubectl describe secret postgres-demo-merge -n '$NAMESPACE'"
```

Use `create-k8-credential` for additional datastore credentials.

## 7. Install Airflow

Copy the temporary values and install:

```bash
$SCP_CMD "$REMOTE_AIRFLOW_VALUES" \
  "$SSH_USER@$SSH_HOST:/tmp/demo1-airflow-values.yaml"

$SSH_CMD "helm repo add apache-airflow https://airflow.apache.org &&
  helm repo update apache-airflow &&
  helm upgrade --install airflow apache-airflow/airflow \
    --namespace '$NAMESPACE' \
    --values /tmp/demo1-airflow-values.yaml \
    --set images.airflow.tag=3.3.0-azure-supported-merge-drivers-20260714 \
    --set defaultAirflowTag=3.3.0-azure-supported-merge-drivers-20260714 \
    --reset-values --timeout 20m --wait"
```

Airflow 3 uses `airflow-api-server` and `airflow-dag-processor`; do not wait for an Airflow 2
webserver deployment.

Grant the Airflow component service accounts read-only access to namespace-local runtime Secrets:

```bash
cat <<YAML | $SSH_CMD "kubectl apply -f -"
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

## 8. Apply bootstrap and run ring 1

```bash
$SCP_CMD generated_output/Demo_PSP/*.yaml \
  "$SSH_USER@$SSH_HOST:/tmp/"

$SSH_CMD "kubectl apply -f /tmp/kubernetes-bootstrap.yaml"
$SSH_CMD "kubectl rollout status deployment/demo-psp-mcp-server \
  -n '$NAMESPACE' --timeout=300s"

$SSH_CMD "kubectl delete job demo-psp-ring1-init \
  -n '$NAMESPACE' --ignore-not-found --wait=true"
$SSH_CMD "kubectl apply -f /tmp/demo_psp_ring1_init_job.yaml"
$SSH_CMD "kubectl wait --for=condition=complete \
  job/demo-psp-ring1-init -n '$NAMESPACE' --timeout=300s"
$SSH_CMD "kubectl logs job/demo-psp-ring1-init \
  -n '$NAMESPACE' --all-containers --tail=100"
```

Do not apply a model-merge Job; the file no longer exists.

## 9. Trigger infrastructure/model merge

```bash
$SSH_CMD "kubectl exec -n '$NAMESPACE' airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json"

$SSH_CMD "kubectl exec -n '$NAMESPACE' airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger demo-psp_infrastructure"

$SSH_CMD "kubectl exec -n '$NAMESPACE' airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json"
```

Wait for the new run to succeed, then discover the generated DAG IDs with `airflow dags list`.

## 10. Verify and access

```bash
$SSH_CMD "kubectl get pods,jobs,pvc -n '$NAMESPACE' -o wide"
$SSH_CMD "kubectl get events -n '$NAMESPACE' \
  --field-selector type=Warning --sort-by=.lastTimestamp"
$SSH_CMD "kubectl exec -n '$NAMESPACE' airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR airflow version"
```

Require Airflow 3.3.x, Ready core pods, a bound RWX Git-cache PVC, a completed ring-1 Job, no DAG
import errors, and a successful infrastructure run.

Access the UI through an SSH tunnel:

```bash
$SSH_CMD "kubectl port-forward -n '$NAMESPACE' \
  svc/airflow-api-server 8080:8080"
```

In a separate local terminal:

```bash
ssh -i "$SSH_KEY" -L 8080:localhost:8080 "$SSH_USER@$SSH_HOST"
```

Use `troubleshoot-k8s-jobs` for Job/pod failures and `troubleshoot-airflow` for DAG/task failures.
Do not force-delete PVC finalizers or namespaces during troubleshooting.
