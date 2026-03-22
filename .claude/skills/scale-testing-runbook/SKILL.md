---
name: Scale Testing Runbook
description: Step-by-step procedure for ramping DataSurface stream counts and diagnosing throughput bottlenecks. Covers monitoring queries, expected baselines, and common failure modes at each scale tier.
---
# Scale Testing Runbook

This runbook covers how to ramp DataSurface ingestion streams from a baseline to production scale, what to monitor at each tier, and how to diagnose throughput problems.

## Prerequisites

Before scale testing:
- Merge database tuned per the `merge-database-performance-tuning` skill
- SQL Server databases configured per the `sqlserver-prerequisites` skill
- VM disk flags verified per the `proxmox-vm-tuning` skill (if running on Proxmox)
- Airflow scheduler tuned per the `troubleshoot-airflow` skill
- Data simulator running and generating changes

## Ramp Schedule

Ramp in stages. Do not jump straight to target — each tier reveals different bottlenecks:

| Tier | Streams | Soak time | What it tests |
|------|---------|-----------|---------------|
| 1 | 50 | 30 min | Baseline — should be trivial |
| 2 | 75 | 30 min | Connection pool sizing |
| 3 | 100 | 30 min | Scheduler throughput, autovacuum pressure |
| 4 | 150 | 60 min | PG shared_buffers, WAL volume, K8s pod distribution |
| 5 | 200+ | 60 min | PgBouncer limits, node resource exhaustion |

Stay at each tier until the batch chart is stable before ramping up.

## Primary Health Indicator: Batch Chart

The batch chart is the single most important diagnostic. Query it from the merge database:

```sql
-- Batches committed per 10-minute window (last 6 hours)
SELECT
  to_char(
    date_trunc('hour', batch_end_time) +
    (EXTRACT(minute FROM batch_end_time)::int / 10) * interval '10 minutes',
    'HH24:MI'
  ) as time_slot,
  count(*) as batches,
  count(DISTINCT key) as active_streams
FROM scd2_batch_metrics
WHERE batch_end_time > now() - interval '6 hours'
  AND batch_status = 'committed'
GROUP BY date_trunc('hour', batch_end_time) +
  (EXTRACT(minute FROM batch_end_time)::int / 10) * interval '10 minutes'
ORDER BY 1;
```

### Expected Baselines

For streams on 1-minute schedules, the target is `streams × 10` batches per 10-minute window:

| Streams | Target/10min | Healthy range | Concerning |
|---------|-------------|---------------|------------|
| 50 | 500 | 480-500 | < 450 |
| 75 | 750 | 700-750 | < 650 |
| 100 | 1000 | 900-1000 | < 800 |
| 150 | 1500 | 1200-1500 | < 1000 |

If throughput is consistently below 80% of target, there is a bottleneck.

### Reading the Chart

- **Flat line at target**: Healthy. System keeping up.
- **Oscillating high/low**: Normal batch cycle alignment. Average should be near target.
- **Sudden drop then slow recovery**: Something broke (PG restart, node failure, scheduler stall). Check events at the drop time.
- **Gradual decline**: Resource exhaustion (dead tuples, connection limits, disk space).
- **Never reaches target**: Fundamental bottleneck — check the diagnosis section below.

## Monitoring Queries

Run these on the merge database during scale testing:

### PostgreSQL Load

```sql
-- Active connections and their states
SELECT state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state;

-- Wait events (what's blocking)
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'active'
GROUP BY 1, 2
ORDER BY 3 DESC;
```

Also check OS load: `uptime` on the PG host. Load should be well under CPU count.

| PG Host CPUs | Load OK | Load Warning | Load Critical |
|-------------|---------|-------------|---------------|
| 4 | < 3 | 3-6 | > 6 |
| 8 | < 6 | 6-12 | > 12 |
| 12 | < 9 | 9-18 | > 18 |

### Dead Tuple Buildup

```sql
-- Staging tables with high dead tuple counts
SELECT relname, n_live_tup, n_dead_tup,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname LIKE '%_s'
ORDER BY n_dead_tup DESC
LIMIT 20;
```

If `n_dead_tup` is consistently > 10× `n_live_tup`, autovacuum is not keeping up.

### Buffer Hit Ratio

```sql
SELECT
  sum(blks_hit) * 100.0 / nullif(sum(blks_hit) + sum(blks_read), 0) AS hit_ratio
FROM pg_stat_database
WHERE datname = current_database();
```

Should be > 99%. Below 95% means `shared_buffers` is too small.

### Temp File Usage

```sql
SELECT temp_files, temp_bytes
FROM pg_stat_database WHERE datname = current_database();
```

Should be 0 during normal operation. Non-zero means `work_mem` is too small.

## Common Bottlenecks by Tier

### 50 streams — should just work
If this tier has problems, something is fundamentally broken (wrong database, misconfigured connections, PG not started).

### 75-100 streams
- **Airflow scheduling delay**: Gap between DAG trigger and first task > 10 seconds. Fix: `max_tis_per_query = 512`
- **Connection pool exhaustion**: `max_connections` too low. Check `SELECT count(*) FROM pg_stat_activity`
- **PgBouncer mode**: Must be `transaction` mode with `server_reset_query = DISCARD ALL`. Session mode causes `PendingRollbackError` after PG restarts

### 100-150 streams
- **PG shared_buffers too small**: Default 128MB causes BufferMapping LWLock contention. Set to 25% of RAM
- **WAL volume**: `max_wal_size` too small causes frequent checkpoints. Set to 2-4GB
- **K8s pod imbalance**: All pods scheduled on one node. Check with `kubectl get pods -o wide`. Equalize node resources
- **Autovacuum falling behind**: Staging table churn overwhelms defaults. Lower `autovacuum_vacuum_scale_factor` to 0.05

### 150+ streams
- **PG load spikes**: If load exceeds 2× CPU count, system is CPU or I/O bound
- **Airflow logs inode exhaustion**: 150 DAGs × 1-min = 216K dirs/day. Need 25Gi+ PVC
- **DAG parsing timeout**: `dagbag_import_timeout` may need increasing to 120+
- **Scheduler throughput**: May need DAG sharding (`numShards=2`)

## After Scale Testing

Document results:
1. Maximum stable stream count achieved
2. PG load at each tier
3. Any bottlenecks hit and how they were resolved
4. Final configuration values that worked
