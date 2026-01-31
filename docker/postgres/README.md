# PostgreSQL for DataSurface Bootstrap

## Quick Start

```bash
cd docker/postgres
docker compose up -d
```

## Databases

- `airflow_db` - Airflow metadata
- `merge_db` - DataSurface merge database

## Credentials

- User: `postgres`
- Password: `password`

## Kubernetes Access

From Docker Desktop K8s pods: `host.docker.internal:5432`
