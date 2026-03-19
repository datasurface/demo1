---
name: Troubleshoot Airflow
description: Diagnose and fix common Airflow issues in DataSurface Yellow deployments. Use when DAGs fail, the UI returns errors, tasks never start, or Airflow components are unhealthy.
---

# Troubleshoot Airflow

This skill provides a systematic approach to diagnosing Airflow issues in DataSurface Yellow environments. Work through the relevant section based on the symptom.

## IMPORTANT: Diagnostic Rules

1. **Check infrastructure basics first** - disk, inodes, auth, network before investigating application logic
2. **Check worker logs for task failures**, not scheduler logs - the scheduler only reports what workers tell it
3. **Get concrete data before theorizing** - timestamps, error messages, `df -hi`, pod status
4. **Never directly modify Airflow's metadata database** - use `airflow db clean` CLI or helm cleanup

---

## Symptom: ALL DAGs Failing Simultaneously

When every DAG fails at once, it's infrastructure — not a code bug.

### Step 1: Check worker logs for the root cause

```bash
for i in 0 1 2 3 4; do
  echo "=== worker-$i ==="
  kubectl logs -n $NAMESPACE airflow-worker-$i -c worker --tail=5 2>&1 | \
    grep -E "error|Error|ERROR|No space|OSError|Signature|auth" | head -3
done
```

### Step 2: Identify which infrastructure issue

| Worker error | Root cause | Fix |
|-------------|------------|-----|
| `OSError: No space left on device` | Logs volume full (disk or **inodes**) | See "Logs Volume Full" below |
| `Invalid auth token: Signature verification failed` | JWT secret mismatch after helm upgrade | See "JWT Auth Failure" below |
| `PendingRollbackError` | Stale PgBouncer connections after DB restart | See "PgBouncer Stale Connections" below |
| `SSL connection has been closed unexpectedly` | Database was restarted while jobs were running | Transient — jobs recover on retry |

### Step 3: Verify with scheduler logs

```bash
kubectl logs -n $NAMESPACE $(kubectl get pods -n $NAMESPACE --no-headers | \
  grep airflow-scheduler | grep Running | head -1 | awk '{print $1}') \
  -c scheduler --tail=30 2>&1 | \
  grep -E "executor_state=failed|Marking.*failed"
```

If scheduler shows `executor_state=failed` with `run_start_date=None` — tasks never started. The problem is in the workers, not the scheduler.

---

## Logs Volume Full

The most common cause of all-DAGs-failing. With many DAGs on frequent schedules, each run creates directories and log files. Inode exhaustion happens before disk space runs out.

### Diagnose

```bash
# Check BOTH disk space AND inodes
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- df -h /opt/airflow/logs
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- df -hi /opt/airflow/logs
```

**Key insight:** `df -h` can show space available while `df -hi` shows 100% inodes used. Inodes exhaustion causes the same `No space left on device` error.

### Fix: Emergency cleanup

```bash
# Delete old log directories to free inodes
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- \
  bash -c 'find /opt/airflow/logs -mindepth 2 -maxdepth 2 -type d -mmin +360 | xargs rm -rf'

# Verify inodes freed
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- df -hi /opt/airflow/logs
```

### Fix: Prevent recurrence

Verify the helm values include cleanup settings:

```yaml
# In helm/airflow-values.yaml
cleanup:
  enabled: true
  schedule: "*/30 * * * *"

workers:
  logGroomerSidecar:
    retentionDays: 2
scheduler:
  logGroomerSidecar:
    retentionDays: 2
triggerer:
  logGroomerSidecar:
    retentionDays: 2
dagProcessor:
  logGroomerSidecar:
    retentionDays: 2

logs:
  persistence:
    size: 25Gi   # NOT 5Gi — too small for frequent schedules
```

### Sizing guide

Formula: `(number of DAGs) x (runs per day) x (log files per run) = inodes per day`

| DAGs | Schedule | Inodes/day | 5Gi PVC (320K inodes) lasts | 25Gi PVC (1.6M inodes) lasts |
|------|----------|------------|----------------------------|------------------------------|
| 50 | 1 min | ~150K | ~2 days | ~10 days |
| 200 | 1 min | ~600K | <1 day | ~2.5 days |
| 50 | 5 min | ~30K | ~10 days | ~53 days |

With 2-day log retention, the groomer sidecar prevents unbounded growth.

---

## JWT Auth Failure

Symptoms: Workers log `Invalid auth token: Signature verification failed`. Tasks are queued but immediately fail.

### Cause

Helm upgrades regenerate the JWT secret (`airflow-jwt-secret`). If components restart at different times, they have different secrets and can't authenticate with each other.

### Fix

Restart all components so they all read the same secret:

```bash
kubectl rollout restart deployment airflow-api-server airflow-scheduler airflow-dag-processor -n $NAMESPACE
kubectl rollout restart statefulset airflow-worker airflow-triggerer -n $NAMESPACE
```

### Prevent

Set a static webserver secret key in helm values to avoid regeneration on upgrades:

```yaml
webserverSecretKeySecretName: airflow-api-secret-key
```

---

## PgBouncer Stale Connections

Symptoms: API server returns HTTP 500, logs show `PendingRollbackError: Can't reconnect until invalid transaction is rolled back`.

### Cause

After a PostgreSQL restart, PgBouncer holds stale server connections. In session mode, these persist for the entire client session lifetime. New API server requests get assigned these poisoned sessions.

### Fix

```bash
kubectl rollout restart deployment airflow-api-server airflow-pgbouncer -n $NAMESPACE
```

### Prevent

Use transaction mode (not session mode) in helm values:

```yaml
pgbouncer:
  enabled: true
  extraIni: |
    pool_mode = transaction
    server_reset_query = DISCARD ALL
```

Transaction mode returns connections to the pool after each transaction, so stale connections are detected and discarded on the next health check.

**Check current mode:**

```bash
kubectl get secret -n $NAMESPACE airflow-pgbouncer-config \
  -o jsonpath="{.data.pgbouncer\.ini}" | base64 -d | grep pool_mode
```

If it shows `pool_mode = session` (or `pool_mode` appears twice), fix the helm values and upgrade.

---

## Airflow Web UI Returns 500

### Quick fix — ALWAYS restart ALL components together

Restarting only api-server + pgbouncer causes JWT secret mismatch with workers/scheduler, leading to recurring 500s. Always restart everything:

```bash
kubectl rollout restart deployment airflow-api-server airflow-pgbouncer airflow-scheduler airflow-dag-processor -n $NAMESPACE
kubectl rollout restart statefulset airflow-worker airflow-triggerer -n $NAMESPACE
```

### If 500 persists after full restart

Check the api-server logs for the specific error:

```bash
kubectl logs -n $NAMESPACE $(kubectl get pods -n $NAMESPACE --no-headers | \
  grep airflow-api-server | grep Running | head -1 | awk '{print $1}') \
  -c api-server --tail=20 2>&1 | \
  grep -iE "error|traceback|500|PendingRollback|Signature"
```

| Error in logs | Cause | Fix |
|--------------|-------|-----|
| `Signature verification failed` | JWT secret mismatch — some components have old secret | Restart ALL components (above) |
| `PendingRollbackError` | Stale PgBouncer connections after DB restart | Covered by full restart above |
| No errors in api-server | Browser caching old port or stale session | Clear browser cache, check current NodePort |

### After helm upgrade, UI port may change

The NodePort is not fixed. Check the current port:

```bash
kubectl get svc -n $NAMESPACE airflow-api-server -o jsonpath="{.spec.ports[0].nodePort}"
```

---

## Metadata DB Bloat (Scheduler Slowdown)

Symptoms: DAG runs take longer to start, scheduler loop time increases, `dag_run` table has millions of rows.

### Diagnose

```bash
# Connect to Airflow metadata DB and check table sizes
PGPASSWORD=<password> psql -U <user> -h <host> -d <airflow_db> -c \
  "SELECT count(*) as dag_runs FROM dag_run;"

PGPASSWORD=<password> psql -U <user> -h <host> -d <airflow_db> -c \
  "SELECT count(*) as task_instances FROM task_instance;"
```

With 50 DAGs on 1-minute schedule: ~72K dag_runs/day, ~360K task_instances/day.

### Fix

Run cleanup manually:

```bash
kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE --no-headers | \
  grep airflow-scheduler | grep Running | head -1 | awk '{print $1}') \
  -c scheduler -- airflow db clean \
  --clean-before-timestamp "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S)" \
  --skip-archive -y \
  -t celery_taskmeta -t dag_run -t task_instance -t task_instance_history -t job -t log
```

**Note:** Airflow 3.x `db clean` has a known FK constraint bug with the `dag_version` table. Use the `-t` flag to specify individual tables and skip `dag_version`.

### Prevent

Ensure the cleanup CronJob is enabled in helm values (see "Logs Volume Full" section).

---

## Merge Database Performance

Symptoms: Merge jobs slow down, queries stuck on `BufferMapping` LWLock, high CPU on merge DB host.

### Diagnose

```bash
# On the merge database host
# Check load and active queries
PGPASSWORD=<pw> psql -U postgres -h localhost -d <merge_db> -c \
  "SELECT pid, state, wait_event_type, wait_event, left(query, 120) as query, \
   now() - query_start as duration \
   FROM pg_stat_activity WHERE datname='<merge_db>' AND state <> 'idle' \
   ORDER BY duration DESC;"

# Check table bloat
PGPASSWORD=<pw> psql -U postgres -h localhost -d <merge_db> -c \
  "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum \
   FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;"
```

### Common causes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `BufferMapping` LWLock contention | `shared_buffers` too small (default 128MB) | Set to 25% of RAM |
| High dead tuples on `_s` tables | Autovacuum can't keep up | Lower `autovacuum_vacuum_scale_factor` to 0.05 |
| Load average >> CPU count | Too many concurrent queries | Check connection count, tune `work_mem` |

See the `merge-database-performance-tuning` skill for full PostgreSQL tuning parameters.

---

## CQRS Jobs Failing

### Check pod logs

```bash
kubectl logs -n $NAMESPACE $(kubectl get pods -n $NAMESPACE --no-headers | \
  grep sqlservercqrs | grep -v Completed | tail -1 | awk '{print $1}') --tail=20
```

### Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Invalid object name 'scd2_batch_metrics'` | Shared infra tables missing on CQRS target | Run infra-merge (creates tables via `createCommonTablesOnContainer`) |
| `SSL connection has been closed unexpectedly` | Source DB restarted during sync | Transient — retries will succeed |
| `Login timeout expired` (SQL Server) | Network/firewall issue to CQRS target | Check connectivity from K8s pod to target DB |

---

## Helm Upgrade Safety

Helm upgrades can cause cascading issues. Follow this checklist:

1. **Before upgrading:** Check if secrets are static or dynamic
   ```bash
   kubectl get secret -n $NAMESPACE | grep airflow
   ```

2. **Batch changes:** Don't do multiple helm upgrades in a debugging session. Combine changes into one upgrade.

3. **After upgrading:** Verify all components can communicate
   ```bash
   # Check for auth errors
   kubectl logs -n $NAMESPACE airflow-worker-0 -c worker --tail=5 | grep -i "auth\|signature"

   # Check API server responds
   PORT=$(kubectl get svc -n $NAMESPACE airflow-api-server -o jsonpath="{.spec.ports[0].nodePort}")
   curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/
   ```

4. **If things break:** Restart everything to sync secrets
   ```bash
   kubectl rollout restart deployment airflow-api-server airflow-scheduler airflow-dag-processor -n $NAMESPACE
   kubectl rollout restart statefulset airflow-worker airflow-triggerer -n $NAMESPACE
   ```

---

## Executor / Queue Backpressure

Symptoms: Tasks take a long time to start, DAG runs queue up, `celery_task_timeout_error` counter increases.

### Diagnose

Pull metrics from the statsd exporter:

```bash
curl -s http://$(kubectl get svc -n $NAMESPACE airflow-statsd -o jsonpath="{.spec.clusterIP}"):9102/metrics | \
  grep -E "^airflow_executor|^airflow_pool_running|^airflow_pool_queued|^airflow_pool_scheduled|^airflow_celery_task_timeout"
```

| Metric | Healthy | Backpressured |
|--------|---------|---------------|
| `executor_open_slots` | >> 0 | Near 0 |
| `executor_queued_tasks` | Low | Growing |
| `pool_scheduled_slots` | 0 | > 0 (tasks waiting) |
| `celery_task_timeout_error` | Stable | Increasing |

### Fix

The bottleneck is usually `parallelism` (global max concurrent tasks) and/or `worker_concurrency` (tasks per Celery worker).

**Formula:** Effective capacity = `worker_concurrency` x `number of workers`

This must be <= `parallelism`, and both must exceed your peak concurrent task count.

```bash
# Check current settings
helm get values airflow -n $NAMESPACE | grep -A2 "parallelism\|worker_concurrency"

# Update via helm
helm upgrade airflow apache-airflow/airflow -n $NAMESPACE \
  -f <(helm get values airflow -n $NAMESPACE) \
  --set config.core.parallelism=128 \
  --set config.celery.worker_concurrency=8
```

**Sizing guide:**

| DAGs | Schedule | Recommended parallelism | worker_concurrency x workers |
|------|----------|------------------------|------------------------------|
| 50 | 1 min | 64 | 4 x 5 = 20 |
| 200 | 1 min | 256 | 8 x 10 = 80 |
| 50 | 5 min | 32 | 2 x 5 = 10 |

---

## Quick Health Check

Run this to get a quick overview of Airflow health:

```bash
# Component status
kubectl get pods -n $NAMESPACE | grep airflow

# Recent DAG run success rate (last 10 minutes)
kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE --no-headers | \
  grep airflow-scheduler | grep Running | head -1 | awk '{print $1}') \
  -c scheduler -- python -c "
from airflow.models import DagRun
from airflow.utils.session import create_session
from datetime import datetime, timedelta, timezone
with create_session() as session:
    recent = session.query(DagRun).filter(
        DagRun.start_date > datetime.now(timezone.utc) - timedelta(minutes=10)
    ).all()
    states = {}
    for r in recent:
        states[r.state] = states.get(r.state, 0) + 1
    print(f'Last 10 min: {states}')
" 2>&1 | tail -1

# Logs volume health
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- df -hi /opt/airflow/logs

# Cleanup CronJob status
kubectl get cronjobs -n $NAMESPACE
```
