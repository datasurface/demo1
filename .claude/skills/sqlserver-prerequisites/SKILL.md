---
name: SQL Server Prerequisites
description: Mandatory SQL Server database configuration before use with DataSurface. Covers READ_COMMITTED_SNAPSHOT (RCSI), lock escalation, delayed durability, and ODBC driver setup. Without these settings, concurrent operations WILL deadlock.
---
# SQL Server Prerequisites

These settings are **mandatory** before DataSurface uses a SQL Server database as a merge store, CQRS target, or CDC source. They are not performance tuning — they are correctness requirements. Without them, concurrent operations will deadlock.

## 1. READ_COMMITTED_SNAPSHOT (RCSI) — MANDATORY

SQL Server defaults to pessimistic locking: readers block writers, writers block readers. This causes deadlocks when multiple ingestion jobs or CQRS sync threads access the same database concurrently.

RCSI enables MVCC (Multi-Version Concurrency Control), the same model PostgreSQL uses by default. Readers see a snapshot and never block writers.

```sql
-- Enable on EVERY database DataSurface will use
-- This requires exclusive access — disconnect all other sessions first
ALTER DATABASE [your_merge_db] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [your_cqrs_db] SET READ_COMMITTED_SNAPSHOT ON;
```

**Important:**
- Requires exclusive database access (no other connections). If it hangs, check `sys.dm_exec_sessions` for other connections
- Takes effect immediately, no restart required
- Does NOT change application code — existing `READ COMMITTED` isolation level now uses row versioning automatically
- Increases tempdb usage slightly (version store)

### Verification

```sql
SELECT name, is_read_committed_snapshot_on
FROM sys.databases
WHERE name IN ('your_merge_db', 'your_cqrs_db');
```

Both should show `1`. If `0`, RCSI is not enabled and deadlocks will occur.

### What Happens Without RCSI

Symptoms:
- `ERROR 1205: Transaction was deadlocked on lock resources`
- Random job failures under concurrent load
- Jobs succeed when run one at a time but fail in parallel
- Deadlocks on `scd2_batch_metrics` or staging tables (`*_s`)

The deadlocks appear random because they depend on timing — which threads happen to access which rows in which order. They are not transient; they are a fundamental locking conflict.

## 2. Lock Escalation — Set by DataSurface Automatically

SQL Server escalates row locks to table locks when a transaction acquires more than ~5,000 row locks. This causes deadlocks when multiple jobs update different rows in the same table.

DataSurface sets `LOCK_ESCALATION = DISABLE` on each table via the `post_table_create` adapter hook. You do not need to set this manually for new tables.

**For existing tables** that were created before the hook was added:

```sql
-- Find tables without DISABLE lock escalation
SELECT t.name, t.lock_escalation_desc
FROM sys.tables t
WHERE t.lock_escalation_desc != 'DISABLE'
ORDER BY t.name;

-- Fix them
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + 'ALTER TABLE [' + name + '] SET (LOCK_ESCALATION = DISABLE);' + CHAR(13)
FROM sys.tables
WHERE lock_escalation_desc != 'DISABLE';
EXEC sp_executesql @sql;
```

### Verification

```sql
-- All tables should show DISABLE
SELECT name, lock_escalation_desc
FROM sys.tables
ORDER BY name;
```

## 3. Delayed Durability — CQRS Targets Only

For CQRS target databases (not CDC source databases), delayed durability batches transaction log writes for higher throughput. This trades a small risk of losing the last few milliseconds of data on crash — acceptable for CQRS because the data can be re-synced from the source.

```sql
-- ONLY on CQRS target databases, NOT on CDC source databases
ALTER DATABASE [your_cqrs_db] SET DELAYED_DURABILITY = FORCED;
```

**Do NOT enable on:**
- CDC source databases (incompatible with Change Data Capture)
- Any database where data loss on crash is unacceptable

### Verification

```sql
SELECT name, delayed_durability_desc
FROM sys.databases
WHERE name = 'your_cqrs_db';
-- Should show FORCED for CQRS targets, DISABLED for CDC sources
```

## 4. ODBC Driver

DataSurface uses `ODBC Driver 18 for SQL Server`. This must be installed on:
- The machine or container running DataSurface jobs
- The Airflow worker image (if using custom image)

### Linux (Ubuntu/Debian)

```bash
curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
sudo add-apt-repository "$(curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list)"
sudo apt-get update
sudo apt-get install -y msodbcsql18
```

### Verification

```bash
odbcinst -q -d
# Should list: [ODBC Driver 18 for SQL Server]
```

### Docker / Kubernetes

The DataSurface Docker image includes the ODBC driver. If building a custom Airflow image, include the ODBC driver installation in your Dockerfile.

## 5. Database Permissions

DataSurface needs these permissions on each SQL Server database:

| Operation | Required Permission |
|-----------|-------------------|
| Merge store | `db_owner` or `CREATE TABLE`, `ALTER`, `INSERT`, `DELETE`, `SELECT` |
| CQRS target | Same as merge store |
| CDC source | `SELECT` on CDC tables, `EXECUTE` on CDC functions |

**Note:** DataSurface does NOT automatically run `ALTER DATABASE`. The RCSI and delayed durability settings must be applied by a DBA before DataSurface connects. DataSurface may not have `ALTER DATABASE` permission, and these are one-time setup steps that should be reviewed by the database administrator.

## Quick Setup Checklist

```sql
-- Run this on each SQL Server database before DataSurface uses it

-- 1. RCSI (mandatory for all databases)
ALTER DATABASE [your_database] SET READ_COMMITTED_SNAPSHOT ON;

-- 2. Delayed durability (CQRS targets only)
-- ALTER DATABASE [your_cqrs_db] SET DELAYED_DURABILITY = FORCED;

-- 3. Verify
SELECT name, is_read_committed_snapshot_on, delayed_durability_desc
FROM sys.databases WHERE name = 'your_database';
```
