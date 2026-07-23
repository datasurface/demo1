---
name: deploy-model-change
description: Deploy and verify a model change on an already-running demo1 environment. Use after adding or changing datastores, workspaces, schemas, policies, or DataTransformers; use upgrade-datasurface-version for runtime image changes.
---

# Deploy a model change

Use the governed Git/release path, trigger the current infrastructure DAG, and verify the
model-derived DAGs and data. Do not edit generated cluster resources by hand.

## 1. Validate locally

Use `validate-model-locally`. At minimum:

```bash
python -c "from eco import createEcosystem; createEcosystem()"
```

Run `test_loads.py` with the repository virtual environment when available. Fix all construction
and lint failures before pushing.

## 2. Publish the model

Use `edit-model-fragment` for the normal branch and PR workflow. After the PR is merged to `main`,
publish the next monotonically newer `vN.N.N-demo` tag as a stable, non-draft GitHub Release.

The Yellow Git loader selects a release, not an arbitrary local checkout. Do not move an existing
tag or delete older releases to force selection.

## 3. Run infrastructure/model merge

Current DataSurface does not create a standalone model-merge Kubernetes Job. The
`demo-psp_infrastructure` DAG loads the released model, performs model merge, refreshes the
factory/CQRS configuration, and publishes the desired dynamic DAG set.

Use the Airflow 3 scheduler container for CLI commands:

```bash
export NAMESPACE="${NAMESPACE:-demo1}"

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger demo-psp_infrastructure

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
```

Wait for the new run to reach `success`. Inspect failed Airflow task logs if it does not; do not
search for `demo-psp-model-merge-job`.

## 4. Confirm reconciliation

List current DAGs after the infrastructure run:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list --output json
```

Discover model-derived DAG IDs from this output. Do not assume a fixed historical list because
IDs and sharding can change with the model and runtime.

Verify the exact effect:

- new or changed datastore/workspace: expected ingestion and CQRS DAGs exist;
- new DataTransformer: its generated DAG exists;
- schema addition: the merge/current/history structures contain the new column;
- removed object: its generated DAG is absent after reconciliation;
- credential change: referenced Kubernetes Secret exists with canonical keys.

Unpause or trigger a newly created data DAG only after confirming its source credential and
destination are ready:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags unpause "<dag-id>"
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  airflow dags trigger "<dag-id>"
```

## 5. Verify behavior

Presence is not success. Use:

- `check-system-health` for task state, restart counts, warnings, and throughput;
- `verify-data-fidelity` for source → merge → CQRS and SCD4 checks;
- `troubleshoot-airflow` for failed infrastructure or dynamic DAG tasks.

## Roll back

Revert the model through another reviewed PR, publish a newer model release, and rerun the
infrastructure DAG. Never patch the reconciled objects directly:

```bash
git switch main
git pull --ff-only origin main
git switch -c revert-<change>
git revert <bad-commit-sha>
git push -u origin revert-<change>
```

Report the merged commit, published model release, infrastructure run ID/state, expected DAG or
schema change, health result, and data-fidelity result. Any missing verification means the change
is not yet confirmed live.
