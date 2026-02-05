---
name: Start Initial Ingestion
description: Guide for starting the initial data ingestion pipeline after deploying a new DataSurface Yellow model. Covers tagging, secrets, and DAG activation.
---
# Starting Initial Ingestion

This guide walks through the steps to get the data ingestion pipeline running after deploying a new DataSurface Yellow model.

## Context

This is a demo project for customers doing their first DataSurface setup. Before using this skill, ensure:

1. **Environment is set up** - Use `/setup-walkthrough` to create the DataSurface Yellow environment on Docker Desktop with Kubernetes
2. **Test data is available** - Use `/create-customer-data-simulator` to start a simulator that generates customer and address data in the source database

Once the environment is running and test data is being generated, use this skill to start the ingestion pipeline.

## Pipeline Flow Overview

Understanding the pipeline flow helps diagnose where issues occur:

```
Infrastructure → Factory → Ingestion → Reconcile/CQRS
```

### DAG Descriptions

| DAG | Purpose |
|-----|---------|
| **demo-psp_infrastructure** | Main orchestrator. Loads model from git (tagged releases only), writes DAG configs to database, creates factory and system DAGs. |
| **scd2_factory_dag** | Factory pattern. Reads ingestion configs from DB, dynamically creates/updates/removes ingestion DAGs. |
| **scd2_datatransformer_factory** | Factory for DataTransformer jobs (masking, aggregation, derived columns). Creates transformer DAGs from DB configs. |
| **scd2__CustomerDB_ingestion** | Dynamic ingestion DAG. Runs on cron schedule, snapshots source tables, writes to staging, performs SCD2 merge (tracks inserts/updates/deletes with history). |
| **Demo_PSP_K8sMergeDB_reconcile** | Creates workspace views for consumers after ingestion tables exist. Maps DSG assignments to database views. |
| **Demo_PSP_default_K8sMergeDB_cqrs** | CQRS replication. Copies merged data to target databases for querying. Separates write path (merge DB) from read paths. |

### Key Concepts

- **Factory DAGs**: Don't process data themselves - they create other DAGs based on database configurations
- **SCD2 Merge**: Slowly Changing Dimension Type 2 - tracks historical changes with insert/update/delete tracking
- **Reconcile**: Only works after ingestion has created the merge tables
- **Tagged Releases**: System only picks up model versions matching `v*.*.*-demo` pattern

## Step 1: Verify Model is Tagged

The reconcile and ingestion jobs only pick up **tagged releases** matching the pattern `v*.*.*-demo`.

### Check existing tags

```bash
git fetch --tags
git tag -l "v*-demo" --sort=-version:refname | head -5
```

### Check what tag the system is using

```bash
kubectl logs -n demo1 deployment/demo-psp-mcp-server --tail=50 | grep -E "tag:|commit:"
```

### Create a new tag if needed

```bash
# Tag current commit
git tag v1.0.1-demo
git push origin v1.0.1-demo

# Or tag a specific commit
git tag v1.0.1-demo <commit-hash>
git push origin v1.0.1-demo
```

## Step 2: Create Required Secrets

**REQUIRED**: The ingestion DAG needs credentials to access the source database. Create this secret before proceeding.

### Check if secret already exists

```bash
kubectl get secret customer-source-credential -n demo1 2>/dev/null && echo "Secret exists" || echo "Secret MISSING - create it below"
```

### Create the customer-source-credential secret

```bash
kubectl create secret generic customer-source-credential \
  --from-literal=USER=postgres \
  --from-literal=PASSWORD=password \
  -n demo1
```

**Naming rules for secrets:**
- Lowercase
- Underscores (`_`) become hyphens (`-`)
- Keys are uppercase: `USER`, `PASSWORD`, `TOKEN`

See `/create-k8-credential` skill for detailed credential creation.

## Step 3: Unpause DAGs

**IMPORTANT**: DAGs are paused by default. You MUST unpause them BEFORE triggering, otherwise triggers will be ignored.

```bash
# Unpause all key DAGs FIRST
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause demo-psp_infrastructure
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2_factory_dag
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2_datatransformer_factory
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause Demo_PSP_K8sMergeDB_reconcile
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause Demo_PSP_default_K8sMergeDB_cqrs
```

Verify DAGs are unpaused (is_paused should be False):

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list 2>/dev/null
```

## Step 4: Trigger the Pipeline

After secrets are created and DAGs are unpaused, trigger the pipeline in order:

### 4a. Trigger Infrastructure DAG

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger demo-psp_infrastructure
```

Wait ~20 seconds for completion.

### 4b. Verify factory and system DAGs were created

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list 2>/dev/null | grep -E "(factory|reconcile|cqrs|infrastructure)"
```

Expected DAGs:
```
demo-psp_infrastructure          - Main infrastructure DAG (triggers model merge)
Demo_PSP_K8sMergeDB_reconcile    - Creates workspace views after tables exist
Demo_PSP_default_K8sMergeDB_cqrs - CQRS replication DAG
scd2_datatransformer_factory     - Factory for data transformer DAGs
scd2_factory_dag                 - Factory that creates ingestion DAGs
```

### 4c. Trigger Factory DAG to create ingestion DAGs

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd2_factory_dag
```

Wait ~15 seconds, then verify:

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list | grep ingestion
```

Expected output:
```
scd2__CustomerDB_ingestion
```

### 4d. Unpause and trigger the ingestion DAG

```bash
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2__CustomerDB_ingestion
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd2__CustomerDB_ingestion
```

## Step 5: Verify Ingestion is Running

### Check ingestion DAG runs

```bash
kubectl exec -n demo1 airflow-worker-0 -c worker -- \
  ls -lt "/opt/airflow/logs/dag_id=scd2__CustomerDB_ingestion/" | head -5
```

### Check ingestion logs for success

```bash
# Get the latest run
LATEST_RUN=$(kubectl exec -n demo1 airflow-worker-0 -c worker -- \
  ls -t "/opt/airflow/logs/dag_id=scd2__CustomerDB_ingestion/" | head -1)

# Check for success
kubectl exec -n demo1 airflow-worker-0 -c worker -- \
  cat "/opt/airflow/logs/dag_id=scd2__CustomerDB_ingestion/$LATEST_RUN/task_id=snapshot_merge_job/attempt=1.log" | \
  grep -E "(RESULT_CODE|completed|Ingested|total_records)"
```

Expected output:
```
"Job completed successfully"
"total_records_ingested": 354
"DATASURFACE_RESULT_CODE=0"
```

## Troubleshooting Checklist

| Issue | Check | Solution |
|-------|-------|----------|
| No dynamic DAGs | Model not tagged | Create and push tag `v*.*.*-demo` |
| DAG creation failed | Missing secret | Create K8s secret (see Step 2) |
| Trigger ignored / DAG not running | DAGs paused | Unpause BEFORE triggering (see Step 3) |
| Factory finds 0 configs | Infrastructure hasn't run | Unpause and trigger `demo-psp_infrastructure` first |
| Reconcile finds no tables | Ingestion hasn't run | Wait for ingestion DAG to complete |

## Quick Start Commands

Run these in sequence to start initial ingestion:

```bash
# 1. Ensure model is tagged and pushed (use appropriate version)
git tag v1.0.1-demo && git push origin v1.0.1-demo

# 2. Create the required customer-source-credential secret
kubectl create secret generic customer-source-credential \
  --from-literal=USER=postgres \
  --from-literal=PASSWORD=password \
  -n demo1

# 3. Unpause all DAGs FIRST (triggers are ignored on paused DAGs)
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause demo-psp_infrastructure
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2_factory_dag
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2_datatransformer_factory
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause Demo_PSP_K8sMergeDB_reconcile
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause Demo_PSP_default_K8sMergeDB_cqrs

# 4. Trigger infrastructure DAG to load model and create factory DAGs
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger demo-psp_infrastructure
sleep 20

# 5. Trigger factory DAG to create ingestion DAGs
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd2_factory_dag
sleep 15

# 6. Unpause and trigger ingestion DAG (created by factory in step 5)
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags unpause scd2__CustomerDB_ingestion
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags trigger scd2__CustomerDB_ingestion
```

## Verifying Everything is Working

```bash
# Check all DAGs are unpaused (is_paused should be False)
kubectl exec -n demo1 deployment/airflow-api-server -- airflow dags list 2>/dev/null

# Check recent ingestion logs for success
kubectl exec -n demo1 airflow-worker-0 -c worker -- \
  ls -lt "/opt/airflow/logs/dag_id=scd2__CustomerDB_ingestion/" | head -3
```
