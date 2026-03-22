---
name: Driver Performance Guide
description: Database driver selection and bulk insert optimization for DataSurface. Covers psycopg2 vs psycopg3, pyodbc fast_executemany, SQLAlchemy bypasses, and the execute_fast_insert pattern. Includes measured benchmarks.
---
# Driver Performance Guide

Database driver choice and insert method have a dramatic impact on DataSurface throughput. The wrong combination can be 10-25x slower. This guide covers what we measured, what we chose, and why.

## Summary of Benchmarks

All benchmarks measured on the same hardware, inserting 10,000 rows into a staging table:

| Database | Driver | Method | Rows/sec | Notes |
|----------|--------|--------|----------|-------|
| PostgreSQL | psycopg2 | SA `executemany` | 5,500 | One round-trip per row |
| PostgreSQL | psycopg3 | SA `executemany` | 51,700 | Proper batching via pipeline |
| PostgreSQL | psycopg3 | Multi-row VALUES | 169,000 | Fastest but requires string formatting |
| SQL Server | pyodbc | SA `text()` executemany | 3,263 | SA bypasses fast_executemany |
| SQL Server | pyodbc | Raw cursor `fast_executemany=True` | 85,235 | Must drop to raw DBAPI cursor |
| MySQL | pymysql | SA `executemany` | ~2,000 | Pure Python driver, inherently slow |
| MySQL | pymysql | Multi-row VALUES | ~15,000 | Only DB still using VALUES path |

## PostgreSQL: psycopg3

### Why psycopg3

psycopg2's `executemany` sends one `INSERT` per row — one network round-trip each. At 5,500 rows/sec over a LAN, this is the bottleneck for any batch larger than a few hundred rows.

psycopg3 uses pipelining: it batches multiple operations into a single network round-trip. SQLAlchemy's `executemany` with psycopg3 achieves 51,700 rows/sec with no code changes.

### Configuration

```python
# In PostgresDatabase adapter
def get_driver_name(self) -> str:
    return "postgresql+psycopg"  # NOT "postgresql" (psycopg2)
```

Requirements:
```
psycopg[binary]==3.2.9   # NOT psycopg2-binary
```

### Airflow Worker Image

psycopg3 must be available in the Airflow worker image because DataSurface code is imported at DAG parse time. If using the community Airflow Helm chart, build a custom image:

```dockerfile
FROM apache/airflow:3.1.8
RUN pip install psycopg[binary]==3.2.9
```

## SQL Server: pyodbc fast_executemany

### The Problem

pyodbc has a `fast_executemany` flag that batches parameter sets into a single round-trip. However, **SQLAlchemy's `text()` executemany does not use it** — even when `fast_executemany=True` is set in `connect_args`.

SQLAlchemy's `text().executemany()` path calls the DBAPI cursor's `executemany` without the optimization. You must drop to the raw DBAPI cursor to get the fast path.

### The Pattern: execute_fast_insert

DataSurface uses a shared utility `execute_fast_insert()` in `database_operations.py` that:

1. Detects if the connection is pyodbc
2. If yes: drops to raw `dbapi_connection.cursor()`, sets `fast_executemany = True`, executes
3. If no: uses SQLAlchemy's `connection.execute(text(...), params)`

```python
from datasurface.platforms.yellow.database_operations import execute_fast_insert, is_pyodbc_connection

# Usage in merge/ingestion code:
execute_fast_insert(
    connection=connection,
    sql=insert_sql,          # INSERT INTO ... VALUES (:col1, :col2, ...)
    params=list_of_dicts,    # [{"col1": v1, "col2": v2}, ...]
    logger=logger
)
```

### Why Not Multi-Row VALUES for SQL Server?

Multi-row VALUES (`INSERT INTO t VALUES (1,'a'),(2,'b'),...`) requires converting Python values to SQL string literals. This is:
- Error-prone (quoting, escaping, NULL handling, Unicode)
- A potential SQL injection vector
- Slower than `fast_executemany` for pyodbc (85K vs ~40K rows/sec)

pyodbc's `fast_executemany` sends binary parameter arrays — no string conversion needed.

## MySQL: Multi-Row VALUES (Exception)

pymysql is a pure-Python driver with no `fast_executemany` equivalent. Its `executemany` is extremely slow (~2,000 rows/sec). For MySQL, DataSurface uses the multi-row VALUES path via `format_sql_value()`:

```python
# MySQL adapter signals this:
def supports_batch_values_insert(self) -> bool:
    return True  # Use VALUES string building
```

All other database adapters return `False` (use native driver executemany).

### format_sql_value

The `format_sql_value()` function in `database_operations.py` converts Python types to SQL string literals. It handles:
- `None` → `NULL`
- `str` → escaped and quoted
- `datetime` → ISO format quoted
- `Decimal`, `int`, `float` → numeric literal
- `bytes` → hex literal
- `uuid.UUID` → string quoted
- `bool` → `1`/`0`

This function is **only used for MySQL**. All other databases use parameterized queries via their native driver.

## DB-Specific Driver Summary

| Database | SQLAlchemy Driver | Bulk Insert Method | Adapter Flag |
|----------|------------------|--------------------|-------------|
| PostgreSQL | `postgresql+psycopg` | Native executemany (psycopg3 pipeline) | `supports_batch_values_insert = False` |
| SQL Server | `mssql+pyodbc` | Raw cursor `fast_executemany=True` | `supports_batch_values_insert = False` |
| MySQL | `mysql+pymysql` | Multi-row VALUES via `format_sql_value` | `supports_batch_values_insert = True` |
| Oracle | `oracle+oracledb` | Native executemany | `supports_batch_values_insert = False` |
| DB2 | `db2+ibm_db` | Native executemany | `supports_batch_values_insert = False` |
| Snowflake | `snowflake` | Native executemany | `supports_batch_values_insert = False` |

## Key Takeaways

1. **Never assume SQLAlchemy passes through driver optimizations.** SA's `text().executemany()` bypasses pyodbc's `fast_executemany`. Always benchmark.
2. **Avoid string-building SQL** unless the driver has no bulk alternative (MySQL/pymysql). Parameterized queries are safer and usually faster.
3. **psycopg3 is a drop-in replacement** for psycopg2 in SQLAlchemy. Change the driver name and the dependency — no code changes needed.
4. **Measure, don't guess.** The difference between the slow path and the fast path is 10-25x. A "working" insert that's 10x slower than it should be won't show up until you scale.
