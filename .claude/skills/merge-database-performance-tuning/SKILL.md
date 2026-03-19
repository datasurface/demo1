---
name: Merge Database Performance Tuning
description: Tune the DataSurface Yellow merge database for production workloads. Covers PostgreSQL configuration for connection limits, memory, and write-heavy SCD2 ingestion patterns.
---
# Merge Database Performance Tuning

The merge database is where all ingestion and merge jobs write data. Under load, it handles high volumes of INSERTs and DELETEs on SCD2 staging tables, concurrent batch operations across many streams, and periodic CQRS sync reads. Without tuning, the default PostgreSQL configuration can become a bottleneck.

This guide covers tuning by database engine. Additional engines will be added as they are tested.

## PostgreSQL

### Sizing Tier: Small System (< 100 DAGs/Streams)

Reference environment: 50 CDC ingestion streams on 1-minute schedules, 3 CQRS jobs, single PostgreSQL host with 16 GB RAM and 8 CPU cores.

### postgresql.conf

| Parameter | Value | Notes |
|-----------|-------|-------|
| `max_connections` | 200 | Ingestion and merge jobs connect directly (not through pgbouncer). Each concurrent DAG run can hold 1-2 connections during its batch |
| `shared_buffers` | 4 GB | ~25% of system RAM. SCD2 staging tables are heavily churned (insert + delete each cycle), so buffer cache is critical |
| `effective_cache_size` | 12 GB | ~75% of system RAM. Tells the query planner how much OS page cache to expect |
| `work_mem` | 64 MB | Per-operation sort/hash memory. Merge queries join staging to main tables and benefit from in-memory sorts |
| `maintenance_work_mem` | 512 MB | For VACUUM and CREATE INDEX. Staging table churn generates dead tuples rapidly |
| `wal_buffers` | 64 MB | Write-heavy workloads benefit from larger WAL buffers |
| `max_wal_size` | 2 GB | Higher than the Airflow DB — the merge DB generates more WAL due to bulk inserts/deletes |
| `checkpoint_completion_target` | 0.9 | Spread checkpoint I/O to avoid latency spikes during batch operations |
| `random_page_cost` | 1.1 | Appropriate for SSD storage |
| `effective_io_concurrency` | 16 | SSD-appropriate |
| `huge_pages` | try | Use if OS supports it |

Changes to `max_connections`, `shared_buffers`, and `huge_pages` require a PostgreSQL restart. Other parameters can be applied with `SELECT pg_reload_conf();`.

### pg_hba.conf

Allow connections from the Kubernetes pod network. Merge jobs run as Kubernetes pods and connect directly to PostgreSQL (not through pgbouncer):

```text
# Kubernetes pod/node network (adjust CIDR to match your cluster)
host    all    all    192.168.4.0/24    scram-sha-256

# Tailscale / overlay network (if applicable)
host    all    all    100.64.0.0/10     scram-sha-256

# Kubernetes pod CIDR (common defaults - adjust to your cluster)
host    all    all    10.244.0.0/16     scram-sha-256
```

Always use `scram-sha-256` for network connections.

### Autovacuum Tuning

SCD2 staging tables (`*_s` suffix) are high-churn: every batch cycle inserts rows, then the merge job deletes them after merging into the main table (`*_m` suffix). This creates dead tuples rapidly. The default autovacuum settings may not keep up:

```sql
-- Check dead tuple buildup on staging tables
SELECT relname, n_live_tup, n_dead_tup,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname LIKE '%_s'
ORDER BY n_dead_tup DESC;
```

If `n_dead_tup` is consistently high relative to `n_live_tup`, consider more aggressive autovacuum for the merge database:

```text
# In postgresql.conf (or per-table with ALTER TABLE ... SET)
autovacuum_vacuum_scale_factor = 0.05    # default 0.2 — vacuum sooner on high-churn tables
autovacuum_analyze_scale_factor = 0.02   # default 0.1 — re-analyze more often
autovacuum_vacuum_cost_delay = 2ms       # default 2ms — reduce if I/O headroom exists
```

### Monitoring

```sql
-- Buffer hit ratio (should be > 99%)
SELECT
  sum(blks_hit) * 100.0 / nullif(sum(blks_hit) + sum(blks_read), 0) AS hit_ratio
FROM pg_stat_database
WHERE datname = 'merge_db';

-- Temp file usage (should be 0 for normal operation)
SELECT temp_files, temp_bytes
FROM pg_stat_database WHERE datname = 'merge_db';

-- Table bloat from staging churn
SELECT relname, n_live_tup, n_dead_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname LIKE '%_s' OR relname LIKE '%_m'
ORDER BY pg_total_relation_size(relid) DESC;

-- Connection count (should be well under max_connections)
SELECT count(*) FROM pg_stat_activity WHERE datname = 'merge_db';
```

### Key Differences from Airflow Metadata DB

| | Airflow Metadata DB | Merge DB |
|---|---|---|
| Access pattern | Read-heavy (UI queries), frequent small updates | Write-heavy (bulk inserts/deletes per batch) |
| Connection pooling | Through PgBouncer (transaction mode with `server_reset_query = DISCARD ALL`) | Direct connections from K8s job pods |
| Deadlock risk | High (scheduler vs UI on `dag` table) | Low (jobs operate on separate stream tables) |
| Autovacuum pressure | Moderate | High (staging table churn) |
| WAL volume | Moderate | High |
