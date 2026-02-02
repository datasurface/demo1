---
name: This runs the datasurface customer data simulator
description: This runs a simulator that generates data for customers and their addresses for testing purposes.
---

# Create source tables and initial test data using the data simulator

The simulator uses a database called customer_db. This needs to be created first. You can do this using psql or any other Postgres client. The simulator itself will create the 2 tables and then start populating them with data and simulating changes.

## This creates the customers and addresses tables with initial data and simulates some changes and leaves it running continuously

```bash
kubectl run data-simulator --restart=Never \
  --image=registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION} \
  --env="POSTGRES_USER=$PG_USER" \
  --env="POSTGRES_PASSWORD=$PG_PASSWORD" \
  -n "$NAMESPACE" \
  -- python src/tests/data_change_simulator.py \
  --host "$PG_HOST" \
  --port "$PG_PORT" \
  --database customer_db \
  --user "$PG_USER" \
  --password "$PG_PASSWORD" \
  --create-tables \
  --max-changes 1000000 \
  --verbose &
```

Wait a moment for the data simulator to start creating tables, then continue
