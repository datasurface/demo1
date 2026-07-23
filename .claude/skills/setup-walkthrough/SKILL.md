---
name: setup-walkthrough
description: Set up the demo1 DataSurface Yellow SCD4 environment on Docker Desktop Kubernetes with Airflow 3.3, local Kubernetes Secrets, and the generated infrastructure DAG. Use for a new or rebuilt local demo1 environment.
---

# Local DataSurface setup walkthrough

This is the current Docker Desktop path for the `demo1` model. It uses:

- DataSurface `1.8.4`;
- Airflow `3.3.0`;
- SCD4 platform `Demo_PSP`;
- Docker Compose PostgreSQL for Airflow metadata and the merge database;
- direct namespace-local Kubernetes Secrets;
- ring 1 bootstrap followed by model merge through `demo-psp_infrastructure`.

There is no standalone model-merge Job in current bootstrap output. The infrastructure DAG owns
the split plan → publish flow (and plan → ESO reconcile → publish on cloud assemblies).

## Execution rules

1. Run and verify each phase in order.
2. Do not delete a namespace, database volume, Git tag, or release unless the user asked for a
   clean rebuild and the exact target was verified.
3. Keep credential values out of Git and command output.
4. Resolve generated filenames from `generated_output/Demo_PSP`; do not invent legacy names.
5. Use the repo virtual environment for model validation.

## Preflight

```bash
NAMESPACE=${NAMESPACE:-demo1}
DATASURFACE_VERSION=${DATASURFACE_VERSION:-1.8.4}
MODEL_REPO=<owner/model-repo>
AIRFLOW_REPO=<owner/dag-repo>
GITHUB_USERNAME=<github-user>

docker version
kubectl config current-context
kubectl get nodes
helm version
git status --short
```

Require:

- Docker Desktop Kubernetes;
- `kubectl`, `helm`, `git`, `jq`, and `python3`;
- a GitHub token with read/write access to the model and DAG repositories;
- GitLab registry credentials that can pull DataSurface images.

Set `POSTGRES_PASSWORD` to the password used by `docker/postgres/docker-compose.yml` (the checked-in
local default is `password`). Do not echo it.

Discover a shared storage class:

```bash
kubectl get storageclass
```

Current DataSurface git cache lint requires `ReadWriteMany`. Select a Docker Desktop storage class
that supports RWX and use it consistently in `rte_demo.py` and the Airflow values. The checked-in
starter uses `standard` for the git cache and `hostpath` for logs; adjust those names if the local
cluster differs.

## 1. Optional clean rebuild

Skip this phase for an in-place update. For a clean rebuild, verify targets first:

```bash
helm list -n "$NAMESPACE"
kubectl get namespace "$NAMESPACE"
docker compose -f docker/postgres/docker-compose.yml ps
```

Then, only with clean-rebuild authorization:

```bash
helm uninstall airflow -n "$NAMESPACE" --ignore-not-found
kubectl delete namespace "$NAMESPACE" --wait=true
docker compose -f docker/postgres/docker-compose.yml down -v
```

The `-v` operation deletes Airflow metadata and merge data. It is intentionally absent from an
ordinary upgrade.

## 2. Start PostgreSQL

```bash
docker compose -f docker/postgres/docker-compose.yml up -d
docker compose -f docker/postgres/docker-compose.yml ps
```

Verify both databases from the compose README/config:

```bash
docker exec datasurface-postgres \
  psql -U postgres -At -c \
  "SELECT datname FROM pg_database WHERE datname IN ('airflow_db','merge_db') ORDER BY datname;"
```

## 3. Configure and validate the model

Update:

- `eco.py`: `GIT_REPO_OWNER`, `GIT_REPO_NAME`;
- `rte_demo.py`: namespace, RWX storage class, merge endpoint, and image tag;
- `helm/airflow-values.yaml`: DAG repository URL and local storage classes.

The checked-in baseline is:

```python
DATASURFACE_VERSION = "1.8.4"
```

and:

```text
registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.8.4
```

Validate before publishing:

```bash
.venv/bin/python -m unittest test_loads
```

This uses the demo1 `.venv` created from `requirements.txt` (no extra test dependencies
required); a successful run prints `Ecosystem validated OK`.

## 4. Publish a stable model release

`VersionPatternReleaseSelector(..., STABLE_ONLY)` reads GitHub Releases matching
`vN.N.N-demo`; a tag by itself is insufficient.

```bash
git remote set-url origin "https://github.com/${MODEL_REPO}.git"
git add eco.py rte_demo.py helm/airflow-values.yaml requirements.txt
git commit -m "Configure local DataSurface environment"
git push -u origin main

git fetch --tags
git tag -l 'v*-demo' | sort -V | tail -5
MODEL_TAG=<next-vN.N.N-demo>
git tag -a "$MODEL_TAG" -m "$MODEL_TAG"
git push origin "$MODEL_TAG"
```

Create a non-draft, non-prerelease GitHub Release for that tag. Use `gh release create` when the
authenticated CLI is available; otherwise use GitHub's Releases UI. Never delete older releases
merely to make the new release win—publish a monotonically newer matching release.

## 5. Create namespace and administrator-managed Secrets

Use the `create-k8-credential` skill for canonical keys and safe rotation.

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -

AIRFLOW_METADATA_URI=$(
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" python3 -c \
  'import os; from urllib.parse import quote; print("postgresql+psycopg2://postgres:" + quote(os.environ["POSTGRES_PASSWORD"], safe="") + "@host.docker.internal:5432/airflow_db?sslmode=disable")'
)
kubectl create secret generic airflow-metadata \
  --namespace "$NAMESPACE" \
  --from-literal=connection="$AIRFLOW_METADATA_URI" \
  --dry-run=client -o yaml |
  kubectl apply -f -
unset AIRFLOW_METADATA_URI

kubectl create secret generic postgres-demo-merge \
  --namespace "$NAMESPACE" \
  --from-literal=USER=postgres \
  --from-literal=PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl create secret generic git \
  --namespace "$NAMESPACE" \
  --from-literal=TOKEN="$GITHUB_TOKEN" \
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

Verify names and keys only:

```bash
kubectl get secrets -n "$NAMESPACE"
kubectl describe secret airflow-metadata -n "$NAMESPACE"
kubectl describe secret postgres-demo-merge -n "$NAMESPACE"
kubectl describe secret git -n "$NAMESPACE"
```

## 6. Generate current bootstrap artifacts

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
```

Verify current output:

```bash
find generated_output/Demo_PSP -maxdepth 1 -type f -print | sort
test -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml
test -f generated_output/Demo_PSP/demo_psp_ring1_init_job.yaml
test -f generated_output/Demo_PSP/demo_psp_infrastructure_dag.py
test -f generated_output/Demo_PSP/demo_psp_reconcile_views_job.yaml
test ! -e generated_output/Demo_PSP/demo_psp_model_merge_job.yaml

for file in generated_output/Demo_PSP/*.yaml; do
  kubectl apply --dry-run=client -f "$file" >/dev/null
done
python -m py_compile generated_output/Demo_PSP/*_dag.py
```

## 7. Publish every generated DAG

Clone the DAG repository outside this model worktree. Clean only previously generated `*_dag.py`
files, then copy all current generated DAGs so removed catalog/export DAGs do not linger.

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

If the repo is initially empty, create and push its `main` branch before installing Airflow so
git-sync has a valid remote ref.

## 8. Install Airflow 3.3

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update apache-airflow

helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  --values helm/airflow-values.yaml \
  --set images.airflow.tag=3.3.0-azure-supported-merge-drivers-20260714 \
  --set defaultAirflowTag=3.3.0-azure-supported-merge-drivers-20260714 \
  --reset-values \
  --timeout 20m \
  --wait
```

Airflow 3 uses `airflow-api-server` and `airflow-dag-processor`; do not look for an Airflow 2
webserver deployment.

Grant Airflow components read-only access to namespace-local runtime Secrets:

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

## 9. Apply bootstrap and ring 1

```bash
kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml
kubectl rollout status deployment/demo-psp-mcp-server \
  -n "$NAMESPACE" --timeout=300s

kubectl delete job demo-psp-ring1-init \
  -n "$NAMESPACE" --ignore-not-found --wait=true
kubectl apply -f generated_output/Demo_PSP/demo_psp_ring1_init_job.yaml
kubectl wait --for=condition=complete \
  job/demo-psp-ring1-init -n "$NAMESPACE" --timeout=300s
kubectl logs job/demo-psp-ring1-init -n "$NAMESPACE" --tail=80
```

Do not apply or wait for `demo-psp-model-merge-job`; current DataSurface does not render it.

## 10. Trigger infrastructure/model merge

Wait for git-sync and DAG parsing, then:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger demo-psp_infrastructure

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
```

Wait for the new infrastructure run to reach `success`. Only then judge generated ingestion,
CQRS, reconcile, or DataTransformer DAGs.

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

Expected invariants:

- Airflow reports `3.3.x`;
- no DAG import errors;
- `demo-psp_infrastructure` most recent run succeeded;
- the ring 1 Job completed;
- MCP and Airflow core pods are Ready with stable restart counts;
- generated runtime DAG IDs use SCD4/model-derived names. Discover them from `airflow dags list`;
  do not assert an old fixed list.

Access the UI:

```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n "$NAMESPACE"
```

The checked-in demo values create `admin` / `admin`. Change that password for any shared environment.

## Simulator

Source data generation is not part of bootstrap. After source databases and their credentials are
ready, use `create-customer-data-simulator`. It deploys the current
`datasurface-data-simulator` entry point as a restartable Deployment with Secret refs.

## Troubleshooting

- Model lint rejects `ReadWriteOnce`: switch the git-cache PVC to a RWX-capable storage class and
  `ReadWriteMany`.
- `ImagePullBackOff`: inspect `datasurface-registry` and the target service account's
  `imagePullSecrets`.
- ring 1 fails: inspect its retained Job pod and logs; verify Git and merge Secrets by key name.
- infrastructure DAG missing: confirm every generated `*_dag.py` was pushed and git-sync is on the
  expected repository/branch.
- infrastructure run fails: inspect its Airflow task logs. Current model merge is split across
  tasks/containers; a historical failed pod is not the current health signal.
- telemetry export errors with successful jobs are observability degradation, not automatically a
  data-pipeline failure.
