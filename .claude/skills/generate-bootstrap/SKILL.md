---
name: generate-bootstrap
description: Generate, validate, publish, and deploy current DataSurface Yellow ring-0 bootstrap artifacts for demo1. Use when creating an environment, changing the runtime environment or PSP, or upgrading the DataSurface image.
---

# Generate Yellow bootstrap artifacts

Generate ring-0 artifacts with the exact DataSurface image pinned by the selected runtime
environment. Current images expose the bootstrap CLI at
`datasurface.entrypoints.platform`; do not use the retired `datasurface.cmd.platform` module.

## Inputs

Confirm these values before running commands:

```bash
export DATASURFACE_VERSION="1.8.4"
export MODEL_DIR="$(pwd)"
export PSP_NAME="Demo_PSP"
export RTE_NAME="demo"       # demo1 keeps this RTE name for local, AWS, and Azure
export NAMESPACE="demo1"
export AIRFLOW_DAG_REPO="OWNER/REPOSITORY"
```

Run from the model repository. The selected RTE must exist in `eco.py`, its PSP must be present,
and its `datasurfaceDockerImage` must use the same version. In demo1, AWS/Azure selection changes
the imported `createDemoRTE` implementation; the declared RTE name remains `demo`.

## Generate

Authenticate without placing the token on the command line:

```bash
export IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}"

printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 "$IMAGE"
```

Remove only the selected PSP's old generated directory, then render it again:

```bash
rm -rf "${MODEL_DIR:?}/generated_output/${PSP_NAME}"

docker run --rm --platform linux/amd64 \
  -v "$MODEL_DIR":/workspace/model \
  -w /workspace/model \
  "$IMAGE" \
  python -m datasurface.entrypoints.platform generatePlatformBootstrap \
    --ringLevel 0 \
    --model /workspace/model \
    --output /workspace/model/generated_output \
    --psp "$PSP_NAME" \
    --rte-name "$RTE_NAME"
```

Omit `--platform linux/amd64` when the selected image has a native manifest for the host.

## Verify current output

For `Demo_PSP`, the expected ring-0 files are:

```text
generated_output/Demo_PSP/
├── kubernetes-bootstrap.yaml
├── demo_psp_infrastructure_dag.py
├── demo_psp_reconcile_views_job.yaml
└── demo_psp_ring1_init_job.yaml
```

Verify names and syntax:

```bash
find "generated_output/$PSP_NAME" -maxdepth 1 -type f -print | sort
test -f "generated_output/$PSP_NAME/kubernetes-bootstrap.yaml"
test -f "generated_output/$PSP_NAME/demo_psp_infrastructure_dag.py"
test -f "generated_output/$PSP_NAME/demo_psp_ring1_init_job.yaml"
test -f "generated_output/$PSP_NAME/demo_psp_reconcile_views_job.yaml"
test ! -e "generated_output/$PSP_NAME/demo_psp_model_merge_job.yaml"

for file in "generated_output/$PSP_NAME"/*.yaml; do
  kubectl apply --dry-run=client -f "$file" >/dev/null
done
python -m py_compile "generated_output/$PSP_NAME"/*_dag.py
```

The standalone model-merge Job is obsolete. Current model merge is the plan/publish sequence
inside the generated `<psp>_infrastructure` DAG.

When `externalSecretProvider=None`, the generated YAML must not contain `ExternalSecret`,
`SecretStore`, or `ClusterSecretStore` resources:

```bash
if rg -n 'kind: (ExternalSecret|SecretStore|ClusterSecretStore)' \
  "generated_output/$PSP_NAME"; then
  echo "Unexpected ESO resource in direct-secret configuration" >&2
  exit 1
fi
```

ESO resources are expected only when a customer deliberately configures an external secret
provider in the RTE.

## Publish generated DAGs

Publish every generated `*_dag.py`. Remove previously generated DAG files in the clone first so
deleted catalog/export DAGs cannot linger:

```bash
export DAG_CLONE
DAG_CLONE="$(mktemp -d)"
git clone "https://github.com/${AIRFLOW_DAG_REPO}.git" "$DAG_CLONE"
mkdir -p "$DAG_CLONE/dags"
rm -f "$DAG_CLONE"/dags/*_dag.py
cp "generated_output/$PSP_NAME"/*_dag.py "$DAG_CLONE/dags/"

git -C "$DAG_CLONE" add -A dags
git -C "$DAG_CLONE" diff --cached --check
git -C "$DAG_CLONE" commit -m "Refresh generated DataSurface DAGs"
git -C "$DAG_CLONE" push origin main
```

If the repository is initially empty, create and push its `main` branch before installing
Airflow so git-sync has a valid ref.

## Deploy

Apply the bootstrap manifest, then recreate ring 1:

```bash
kubectl apply -f "generated_output/$PSP_NAME/kubernetes-bootstrap.yaml"
kubectl rollout status deployment/demo-psp-mcp-server \
  -n "$NAMESPACE" --timeout=300s

kubectl delete job demo-psp-ring1-init \
  -n "$NAMESPACE" --ignore-not-found --wait=true
kubectl apply -f "generated_output/$PSP_NAME/demo_psp_ring1_init_job.yaml"
kubectl wait --for=condition=complete \
  job/demo-psp-ring1-init -n "$NAMESPACE" --timeout=300s
kubectl logs job/demo-psp-ring1-init -n "$NAMESPACE" --tail=80
```

Wait for git-sync and DAG parsing, then trigger infrastructure/model merge with the Airflow 3
scheduler:

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

Wait for the new infrastructure DAG run to reach `success`. Do not apply or wait for
`demo-psp-model-merge-job`.

## Failure handling

- Import or lint failure: fix the model first; do not deploy partial artifacts.
- PSP/RTE not found: confirm names in `eco.py`; names are case-sensitive.
- Old artifact still present: remove only `generated_output/$PSP_NAME`, then regenerate.
- DAG import error: inspect `airflow dags list-import-errors` before triggering infrastructure.
- Ring 1 failure: inspect the Job logs and Kubernetes events; do not trigger infrastructure until
  ring 1 completes.
- Infrastructure failure: inspect the Airflow task logs. Plan, optional ESO reconcile, and publish
  are tasks in the DAG, not separate bootstrap Jobs.
