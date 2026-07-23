---
name: create-customer-data-simulator
description: Run the packaged DataSurface customer and address simulator locally or as a restartable Kubernetes Deployment. Use to generate PostgreSQL, SQL Server, or Snowflake source changes for a demo1 environment.
---

# Run the customer data simulator

The supported entry point is:

```text
datasurface-data-simulator
```

It is packaged in current DataSurface wheels and images. Do not use the removed
`src/tests/data_change_simulator.py` path or invoke the compiled implementation with `python -m`.

The simulator creates `customers` and `addresses` with `--create-tables`, then generates inserts,
updates, and deletes. PostgreSQL and SQL Server support bulk seed and rate-based churn. Snowflake
supports interval mode and either key-pair or SPCS file-token authentication.

## Inputs

```bash
NAMESPACE=demo1
DATASURFACE_VERSION=1.8.4
DB_TYPE=postgres                 # postgres, sqlserver, or snowflake
DB_HOST=host.docker.internal
DB_PORT=5432
DB_DATABASE=customer_db
CREDENTIAL_SECRET=customer-source-credential
```

Create the database itself before the first PostgreSQL or SQL Server run. The simulator creates
tables, not the database. Keep the source identity separate from merge/CQRS/transformer identities.

## Verify the image entry point

```bash
IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}"
docker run --rm --platform linux/amd64 "$IMAGE" datasurface-data-simulator --help
```

## Short local connectivity test

PostgreSQL:

```bash
docker run --rm --platform linux/amd64 \
  "$IMAGE" \
  datasurface-data-simulator \
  --db-type postgres \
  --host "$DB_HOST" \
  --port "$DB_PORT" \
  --database "$DB_DATABASE" \
  --user "$DB_USER" \
  --password "$DB_PASSWORD" \
  --create-tables \
  --max-changes 10
```

SQL Server uses the same command with `--db-type sqlserver` and port `1433`. When a Docker
container cannot resolve a private hostname, use a reachable IP or an explicit `--add-host`
mapping after verifying the address. Do not copy historical dolly hostnames into a new environment.

For Snowflake key-pair auth, mount the key read-only and pass its container path:

```bash
docker run --rm --platform linux/amd64 \
  -v /secure/path/rsa_key.p8:/run/secrets/snowflake-key:ro \
  "$IMAGE" \
  datasurface-data-simulator \
  --db-type snowflake \
  --account "$DB_ACCOUNT" \
  --database "$DB_DATABASE" \
  --user "$DB_USER" \
  --warehouse "$DB_WAREHOUSE" \
  --private-key-path /run/secrets/snowflake-key \
  --passphrase "$SNOWFLAKE_PASSPHRASE" \
  --create-tables \
  --max-changes 10
```

## Kubernetes: use a Deployment and Secret refs

A Deployment is preferable to a one-shot `kubectl run` pod: it restarts after node or process
failure and can be frozen with `replicas=0` during resets.

PostgreSQL example:

```bash
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-simulator-pg
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: source-simulator-pg
  template:
    metadata:
      labels:
        app: source-simulator-pg
    spec:
      imagePullSecrets:
        - name: datasurface-registry
      containers:
        - name: simulator
          image: ${IMAGE}
          command: ["datasurface-data-simulator"]
          args:
            - --db-type
            - postgres
            - --host
            - ${DB_HOST}
            - --port
            - "${DB_PORT}"
            - --database
            - ${DB_DATABASE}
            - --user
            - \$(DB_USER)
            - --password
            - \$(DB_PASSWORD)
            - --create-tables
            - --min-interval
            - "1"
            - --max-interval
            - "3"
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: ${CREDENTIAL_SECRET}
                  key: USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${CREDENTIAL_SECRET}
                  key: PASSWORD
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 2Gi
YAML

kubectl rollout status deployment/source-simulator-pg \
  -n "$NAMESPACE" --timeout=420s
kubectl logs deployment/source-simulator-pg -n "$NAMESPACE" --tail=30
```

For SQL Server, use a distinct Deployment such as `source-simulator-sql`, `--db-type sqlserver`,
port `1433`, and its own credential Secret.

Never merge-patch a container list with only `name`, `image`, or `command`; Kubernetes replaces the
list entry and drops `args` and credential `env` refs. Use `kubectl set image`, a JSON patch for one
field, or reapply the complete manifest.

## Scale mode

PostgreSQL and SQL Server can seed and drive sustained churn:

```text
--seed-rows 1000000
--target-rate 5000
--batch-size 500
--heartbeat-interval 10
```

Use `--seed-only` to provision then exit. Do not combine high `--target-rate` with `--verbose`;
per-operation logging can overwhelm the pod. Size memory from measured source volume—the simulator
keeps a compact ID cache and large sources still need more than a tiny default pod.

## Operate safely

```bash
# Freeze writes during a reset.
kubectl scale deployment/source-simulator-pg -n "$NAMESPACE" --replicas=0

# Resume after source tables, CDC, and credentials are ready.
kubectl scale deployment/source-simulator-pg -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment/source-simulator-pg -n "$NAMESPACE"

# Remove it.
kubectl delete deployment/source-simulator-pg -n "$NAMESPACE"
```

If source tables are preserved, leave the simulator deployed unless the reset procedure explicitly
requires a write freeze. If source tables are dropped, stop it first, recreate the tables, restore
SQL Server CDC after table creation, verify access, and only then resume writes.

## Verify

```bash
kubectl get deployment,pod -n "$NAMESPACE" -l app=source-simulator-pg
kubectl logs deployment/source-simulator-pg -n "$NAMESPACE" --tail=50
```

Interval mode logs individual operations. Rate mode emits heartbeat lines with achieved rate and
counts. Confirm database row counts independently before treating the simulator as healthy.

Common failures:

- `command not found`: the image is stale or incomplete; inspect `datasurface-data-simulator --help`.
- authentication failure: verify the Secret has `USER` and `PASSWORD` keys without decoding them.
- connection timeout: test DNS and TCP reachability from the namespace.
- Snowflake key-pair failure: verify PEM mounting and optional passphrase; SPCS uses
  `--snowflake-auth spcs-token` and its runtime-mounted token instead of a Kubernetes credential.
