---
name: start-initial-ingestion
description: Start and verify the first DataSurface Yellow ingestion after a new demo1 deployment. Use to publish the initial model release, create source credentials, run infrastructure/model merge, discover generated DAGs, and confirm SCD4 data movement.
---

# Start initial ingestion

Use this only after a setup walkthrough has completed ring 1 and Airflow is healthy. Use
`create-customer-data-simulator` when the demonstration needs changing source data.

Current flow:

```text
stable model release
  → demo-psp_infrastructure
  → dynamic factory/system DAG discovery
  → model-derived ingestion DAG
  → SCD4 current/history and consumer outputs
```

Do not look for a standalone model-merge Job. Model merge and dynamic DAG configuration happen
inside `demo-psp_infrastructure`.

## 1. Confirm the model release

The model loader selects stable GitHub Releases matching the RTE selector, normally
`vN.N.N-demo`.

```bash
git fetch --tags
git tag -l 'v*-demo' --sort=-version:refname | head -5
```

If the desired commit is not published, merge it to `main`, create the next monotonically newer
tag, push it, and create a stable, non-draft GitHub Release. A tag alone is insufficient. Do not
move or delete old release tags.

## 2. Create source credentials

Read the actual `Credential` declarations in the released model. Normalize each name to
lowercase/hyphenated Kubernetes form and create the canonical keys described by
`create-k8-credential`.

For a `USER_PASSWORD` source:

```bash
export NAMESPACE="${NAMESPACE:-demo1}"
export SOURCE_SECRET="<normalized-model-credential-name>"

kubectl create secret generic "$SOURCE_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=USER="$SOURCE_DB_USER" \
  --from-literal=PASSWORD="$SOURCE_DB_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

The local, AWS, and Azure starters use direct Kubernetes Secrets by default. Run ESO checks only
when the selected RTE explicitly configures an external secret provider.

Verify names and keys without decoding values:

```bash
kubectl describe secret "$SOURCE_SECRET" -n "$NAMESPACE"
```

## 3. Check Airflow before model merge

Use the Airflow 3 scheduler container:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list --output json
```

Resolve import errors before continuing.

## 4. Trigger infrastructure/model merge

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags unpause demo-psp_infrastructure
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger demo-psp_infrastructure
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
```

Wait for the new run to reach `success`. Use the Airflow UI task logs for failures. The merge task
loads the model release and the factory-creation task refreshes the model-derived DAG set.

## 5. Discover the generated DAG IDs

Wait for a scheduler parse cycle, then list DAGs:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list --output json
```

Identify the ingestion DAG for the desired datastore/workspace from the output. Also confirm the
expected reconcile, CQRS, and DataTransformer DAGs for the released model. Do not hard-code old
example IDs: platform names, model names, and sharding affect them.

## 6. Start the ingestion DAG

```bash
export INGESTION_DAG_ID="<discovered-dag-id>"

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags unpause "$INGESTION_DAG_ID"
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger "$INGESTION_DAG_ID"
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs "$INGESTION_DAG_ID" --output json
```

Wait for the run to succeed. If the DAG never appears, rerun and inspect
`demo-psp_infrastructure`; do not trigger a historical fixed-name factory DAG.

## 7. Verify data

Use the Airflow task log plus `check-system-health` and `verify-data-fidelity`. Require:

- the ingestion run reached `success`;
- its Kubernetes work pod completed without warning events;
- the SCD4 current table contains the expected live rows;
- the history table records changes across simulator updates;
- batch metrics advanced;
- downstream reconcile/CQRS work completed when the model requests it.

Discover physical table names from the model and database metadata rather than assuming the old
`CustomerDB` sample names.

Useful cluster checks:

```bash
kubectl get pods,jobs -n "$NAMESPACE" -o wide
kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning --sort-by=.lastTimestamp
```

Report the model release, source credential name/type, infrastructure run state, discovered
ingestion DAG ID, ingestion run state, SCD4 row/history checks, and any verification that could not
run.
