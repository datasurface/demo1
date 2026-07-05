---
name: Deploy Model Change
description: Ship a model change on an ALREADY-RUNNING DataSurface environment and confirm it took effect end to end — new datastore, new workspace, schema change, or new DataTransformer. Use when the user says "deploy my model change", "ship this change", "I edited my model, now what", "promote my change", or "did my change take effect". Not for the first-ever deployment (see start-initial-ingestion) or a runtime image upgrade (see upgrade-datasurface-version).
---
# Deploy Model Change

Use this skill for the steady-state loop: you already have a running DataSurface environment (infrastructure DAG, factory DAGs, and at least one ingestion stream exist) and you've made a model change — adding a datastore, adding a workspace, changing a schema, adding a DataTransformer — that you now need to get onto the cluster and verify actually landed. This skill ties together the git mechanics (`edit-model-fragment`) and the factory reconciliation loop, then adds the verification steps neither of those cover.

## How this differs from adjacent skills

- **`edit-model-fragment`** — the git mechanics only: pull main, edit, branch, commit, push to open the PR. This skill starts where that one ends (PR merged) and continues through cluster reconciliation and verification.
- **`start-initial-ingestion`** — first-time activation of a brand-new deployment: tagging the first release, creating the first secrets, unpausing the base DAGs for the first time. Use that skill only if nothing is running yet.
- **`upgrade-datasurface-version`** — changes the DataSurface **runtime image** (the platform code itself), which needs a bootstrap regen. That's an infrastructure upgrade, not a model change.
- **This skill** — the model (your `.py` fragments) changes on an environment that is already up. No image change, no bootstrap regen, no first-time secrets/tagging — just: edit, merge, reconcile, verify.

## Step 1: Validate locally before pushing anything

Catch schema/reference errors in seconds instead of waiting for a PR round-trip. See `validate-model-locally` for the full local-validation flow. At minimum:

```bash
python -c "from eco import createEcosystem; createEcosystem()"
```

Fix any errors here before proceeding — a model that doesn't construct locally won't pass PR validation either.

## Step 2: Push the change

Use `edit-model-fragment` to do the actual git work: checkout `main`, pull latest, edit your GCO's file(s), switch to the correct `owningRepo` branch, commit, and push. The push opens a PR to `main`.

The PR triggers DataSurface's model validation (consistency, authorization, backward compatibility). Once it's approved and merged:
- `main` now has your change.
- The release/tag that the cluster's loader consumes needs to include your merged commit (see the tagging step in `start-initial-ingestion` if this environment gates on `v*.*.*-demo` tags — most steady-state environments auto-track `main` or a schedule instead; check which applies to yours before assuming a tag push is required).

## Step 3: Confirm model-merge picked up the change

After merge (and after any required tag push), the model-merge job reloads the model on its own schedule, or you can trigger it:

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger demo-psp_infrastructure
```

Wait ~20 seconds, then confirm the job actually loaded your new version:

```bash
kubectl logs -n demo1 job/<model-merge-job> --tail=100 | grep -iE "version|release|ingestion|datatransformer"
```

(Find the exact job/pod name with `kubectl get jobs -n demo1` if `<model-merge-job>` isn't already known.)

The two factory DAGs then reconcile the running DAG set against the newly-loaded model:
- `scd4_factory_dag` — creates, updates, or removes **ingestion** DAGs (one per datastore/workspace pairing).
- `scd4_datatransformer_factory` — does the same for **DataTransformer** DAGs.

Trigger them if you don't want to wait for their schedule:

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd4_factory_dag
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd4_datatransformer_factory
```

## Step 4: Confirm the change materialized

Check the specific thing you changed:

**New or changed datastore/workspace → new ingestion DAG:**
```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list | grep scd4__
```
The new store's `scd4__<Store>_ingestion` DAG should now be listed. If it's a brand-new stream it will be paused — unpause and trigger it (cross-reference `start-initial-ingestion` for the secret/tagging/unpause sequence if this is genuinely the first run for that stream):
```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd4__<Store>_ingestion
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd4__<Store>_ingestion
```

**New DataTransformer → new DT DAG:**
```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list | grep -i datatransformer
```

**Schema change (added/changed column) → merge tables reflect it:**
```sql
-- On the merge DB, schema ds_dp_scd4
\d ds_dp_scd4.<name>_m
```
A backwards-**incompatible** schema change (e.g. dropping/narrowing a column, changing a type) would have been rejected at PR validation rather than reaching this point — there's a governed override label for genuine breaking changes, but that's a deliberate, reviewed exception, not something to reach for to get a PR through.

**Removed object → its DAG disappears:**
```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list | grep <removed-name>
```
Should return nothing once the relevant factory DAG has run.

## Step 5: Verify data is actually flowing correctly

Deployed is not the same as working. Confirm the change is moving data, not just present as a DAG:

- `check-system-health` — batch throughput for the new/changed stream, confirms it's not stuck or degraded.
- `verify-data-fidelity` — confirms source → merge → CQRS values match for the new/changed dataset, not just that rows arrived.

## Step 6: Rollback if the change is bad

If the deployed change is wrong, **never hand-edit the cluster** — the infra reconciler will revert any manual kubectl patch back to what the model says on the next reconcile pass. Instead, revert through the same PR flow used to ship it:

```bash
git checkout main
git pull origin main
git checkout -b revert-<change>
git revert <bad-commit-sha>   # or hand-edit the file back and commit
git push -u origin revert-<change>
```
Push opens a PR the same way; once merged, Step 3's model-merge/factory reconciliation removes or reverts the DAGs automatically.

## Did it work? — checklist

```
Deploy Model Change Report
===========================
Change:            <what you changed — new store / workspace / schema / DT>
PR:                ✅ merged (<PR link/sha>)
Model-merge:       ✅ loaded new version (<version/release string from logs>)
Factory reconcile: ✅ scd4_factory_dag / scd4_datatransformer_factory ran
DAG present:       ✅ <dag-name> listed, unpaused
Schema (if any):   ✅ ds_dp_scd4.<name>_m has expected columns
Removed (if any):  ✅ old DAG no longer listed
Data flowing:      ✅ HEALTHY per check-system-health
Fidelity:          ✅ source/merge/CQRS match per verify-data-fidelity

Issues Found:
  - <issue> → see <skill>
```

Use ✅/⚠️/❌ per row. Any ❌ means the change is not actually live — go back to the corresponding step rather than declaring done.
