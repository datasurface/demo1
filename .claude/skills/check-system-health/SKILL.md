---
name: Check System Health
description: Diagnose DataSurface system health when user asks "how's it doing?", "what's wrong?", "does it look ok?", or any variation of system status inquiry. Runs batch throughput analysis, database health checks, and compares against expected baselines.
---
# Check System Health

Use this skill when the user asks about system health, throughput, performance, or status. Examples: "how's it doing?", "what's wrong?", "does it look ok?", "is it healthy?", "show me the batch chart".

## Step 1: Discover the Merge Database Connection

The merge database connection is defined in the model files. Find it:

```bash
# Look for the merge database configuration in the model
grep -r "PostgresDatabase\|SQLServerDatabase\|mergeStore\|merge_datacontainer" rte_*.py eco.py *.py 2>/dev/null
```

Extract:
- **Host** (e.g., `host.docker.internal`, an IP, or a DNS name)
- **Port** (5432 for Postgres, 1433 for SQL Server)
- **Database name** (e.g., `merge_db`, `merge_large`)
- **Database type** (PostgresDatabase or SQLServerDatabase)

The credential name is in the `mergeRW_Credential` parameter. Look up the actual username/password from K8s secrets:

```bash
# Get the credential secret (adjust namespace and secret name from model)
kubectl get secret <credential-name> -n <namespace> -o jsonpath='{.data.USER}' | base64 -d
kubectl get secret <credential-name> -n <namespace> -o jsonpath='{.data.PASSWORD}' | base64 -d
```

If K8s access is not available, ask the user for the merge database credentials.

**Important:** There may be multiple merge databases (e.g., `merge_db` for small tests, `merge_large` for scale tests). If unsure, list all databases on the host:

```sql
-- PostgreSQL
SELECT datname FROM pg_database WHERE datistemplate = false;

-- SQL Server
SELECT name FROM sys.databases WHERE database_id > 4;
```

Check which one has recent batch activity:
```sql
SELECT current_database(), max(batch_end_time), count(DISTINCT key) as streams
FROM scd2_batch_metrics;
```

## Step 2: Batch Throughput Chart

This is the primary health indicator. Run on the merge database:

```sql
-- Batches committed per 10-minute window (last 2 hours)
-- Adjust time range as needed: '2 hours', '6 hours', '24 hours'
SELECT
  to_char(
    date_trunc('hour', batch_end_time) +
    (EXTRACT(minute FROM batch_end_time)::int / 10) * interval '10 minutes',
    'HH24:MI'
  ) as time_slot,
  count(*) as batches,
  count(DISTINCT key) as active_streams
FROM scd2_batch_metrics
WHERE batch_end_time > now() - interval '2 hours'
  AND batch_status = 'committed'
GROUP BY date_trunc('hour', batch_end_time) +
  (EXTRACT(minute FROM batch_end_time)::int / 10) * interval '10 minutes'
ORDER BY 1;
```

### Interpret Results

For streams on 1-minute schedules, the target is **streams x 10** batches per 10-minute window:

| Active Streams | Target/10min | Healthy (>80%) | Degraded (60-80%) | Unhealthy (<60%) |
|---------------|-------------|----------------|-------------------|-----------------|
| 50 | 500 | > 400 | 300-400 | < 300 |
| 75 | 750 | > 600 | 450-600 | < 450 |
| 100 | 1000 | > 800 | 600-800 | < 600 |
| 150 | 1500 | > 1200 | 900-1200 | < 900 |

Present the chart visually using bar characters (█). Flag any windows that fall below the healthy threshold.

**Patterns to flag:**
- Sudden drop → something broke (check PG/K8s events at that time)
- Gradual decline → resource exhaustion (dead tuples, connections, disk)
- Never reaches target → fundamental bottleneck (proceed to Step 3)
- Oscillating high/low → normal batch alignment, check the average

## Step 3: Database Health Checks (PostgreSQL)

Run these if throughput is below target or the user wants a full health check:

### 3a. Connection Count
```sql
SELECT state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state
ORDER BY 2 DESC;
```
- **Healthy**: total connections well under `max_connections` (check with `SHOW max_connections`)
- **Warning**: > 50% of max_connections in use
- **Critical**: approaching max_connections — jobs will fail to connect

### 3b. Buffer Hit Ratio
```sql
SELECT
  sum(blks_hit) * 100.0 / nullif(sum(blks_hit) + sum(blks_read), 0) AS hit_ratio
FROM pg_stat_database
WHERE datname = current_database();
```
- **Healthy**: > 99%
- **Warning**: 95-99% — consider increasing `shared_buffers`
- **Critical**: < 95% — `shared_buffers` is too small, see `merge-database-performance-tuning` skill

### 3c. Dead Tuple Buildup (Autovacuum Health)
```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0), 1) as dead_ratio,
       last_autovacuum
FROM pg_stat_user_tables
WHERE relname LIKE '%_s'
ORDER BY n_dead_tup DESC
LIMIT 10;
```
- **Healthy**: `dead_ratio` < 2
- **Warning**: `dead_ratio` 2-10 — autovacuum is slow but keeping up
- **Critical**: `dead_ratio` > 10 — autovacuum can't keep up, see `merge-database-performance-tuning` skill

### 3d. Temp File Usage
```sql
SELECT temp_files, temp_bytes,
       pg_size_pretty(temp_bytes) as temp_size
FROM pg_stat_database
WHERE datname = current_database();
```
- **Healthy**: 0 temp files
- **Warning**: any temp files — `work_mem` may be too small

### 3e. Table Sizes (Top 10)
```sql
SELECT relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       n_live_tup
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;
```

### 3f. Host Load (if SSH access available)
```bash
# Check CPU load on the database host
ssh <db-host> uptime
```
Load should be well under CPU core count. Load > 2x cores means the system is overloaded.

## Step 4: Database Health Checks (SQL Server)

If the merge database is SQL Server, run these instead:

### 4a. RCSI Verification (CRITICAL)
```sql
SELECT name, is_read_committed_snapshot_on, delayed_durability_desc
FROM sys.databases WHERE name = DB_NAME();
```
- `is_read_committed_snapshot_on` MUST be `1`. If `0`, deadlocks will occur — see `sqlserver-prerequisites` skill.

### 4b. I/O Latency
```sql
SELECT
    db_name(database_id) AS db,
    file_id,
    io_stall_write_ms / NULLIF(num_of_writes, 0) AS avg_write_ms,
    io_stall_read_ms / NULLIF(num_of_reads, 0) AS avg_read_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL)
WHERE database_id = DB_ID()
ORDER BY avg_write_ms DESC;
```
- **Healthy**: avg_write_ms < 10
- **Warning**: 10-50ms — check VM disk flags (see `proxmox-vm-tuning` skill)
- **Critical**: > 50ms — almost certainly missing SSD flags on the VM

### 4c. Lock Escalation Check
```sql
SELECT name, lock_escalation_desc
FROM sys.tables
WHERE lock_escalation_desc != 'DISABLE';
```
- Should return 0 rows. Any table without `DISABLE` can cause deadlocks under concurrent load.

## Step 5: Airflow Health (if accessible)

```bash
# Check for failed/stuck DAG runs
kubectl exec -n <namespace> <scheduler-pod> -- airflow dags list-runs -s failed --limit 20

# Check scheduler heartbeat
kubectl logs -n <namespace> <scheduler-pod> --tail=20
```

If Airflow UI is available (port-forward or ingress), check for:
- Red/failed DAG runs
- DAGs stuck in "queued" state (scheduler bottleneck)
- 500 errors on the UI (PgBouncer or auth issues — see `troubleshoot-airflow` skill)

## Step 6: Report

Present findings as a health report:

```
System Health Report
====================
Merge DB: <host>:<port>/<dbname> (<type>)
Active Streams: <N>
Time Range: last <X> hours

Throughput:   ✅ HEALTHY | ⚠️ DEGRADED | ❌ UNHEALTHY
  Current: <N>/10min (target: <M>/10min, <P>%)
  Trend: stable | declining | recovering

Connections:  ✅ <N>/<max> (<P>%)
Buffer Hit:   ✅ <N>%
Dead Tuples:  ✅ max ratio <N> on <table>
Temp Files:   ✅ none
Host Load:    ✅ <N> on <cores> cores

Issues Found:
  - <issue 1> → see <skill> skill
  - <issue 2> → see <skill> skill
```

Use ✅ for healthy, ⚠️ for warning, ❌ for critical. Reference the appropriate skill for each issue found.
