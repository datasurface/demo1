# DataSurface Bootstrap

A template for bootstrapping a DataSurface Yellow environment on Docker Desktop with Kubernetes.

## Prerequisites

- Docker Desktop with Kubernetes enabled
- Python 3.12+
- `kubectl` and `helm` CLI tools
- GitHub account with access to create repositories

## Quick Start

### Step 1: Start PostgreSQL

```bash
cd docker/postgres
docker compose up -d
```

This creates `airflow_db` and `merge_db` databases.

### Step 2: Fork This Repository

Fork this template to your own GitHub repository (e.g., `https://github.com/yourorg/demo1.git`).

### Step 3: Clone Your Fork

```bash
git clone https://github.com/yourorg/demo1.git
cd demo1
```

### Step 4: Customize the Model

Edit `eco.py` to set your GitHub organization and repository names.

Edit `rte_demo.py` to configure:
- Namespace name
- Database host (`host.docker.internal` for Docker Desktop)
- Storage class (`standard` for Docker Desktop)

### Step 5: Create Kubernetes Namespace and Secrets

```bash
export NAMESPACE="demo1"
kubectl create namespace $NAMESPACE

# PostgreSQL credentials
kubectl create secret generic postgres \
  --from-literal=USER=postgres \
  --from-literal=PASSWORD=password \
  -n $NAMESPACE

# Git credentials for model repository
kubectl create secret generic git \
  --from-literal=TOKEN=$GITHUB_TOKEN \
  -n $NAMESPACE
```

### Step 6: Install Airflow

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  -f helm/airflow-values.yaml \
  -n $NAMESPACE \
  --timeout 10m
```

### Step 7: Generate and Deploy Bootstrap

```bash
# Generate bootstrap artifacts
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  datasurface/datasurface:latest \
  python -m datasurface.cmd.platform generatePlatformBootstrap \
  --ringLevel 0 \
  --model /workspace/model \
  --output /workspace/model/generated_output \
  --psp Demo_PSP \
  --rte-name demo

# Deploy DAG and run init jobs
# (see generated_output/Demo_PSP/ for artifacts)
```

## Project Structure

```
.
├── docker/
│   └── postgres/          # PostgreSQL compose setup
├── helm/
│   └── airflow-values.yaml  # Airflow Helm values for Docker Desktop
├── eco.py                 # Ecosystem definition
├── rte_demo.py           # Runtime environment configuration
└── README.md
```

## DataSurface Artifacts

See [ARTIFACTS.md](ARTIFACTS.md) for accessing DataSurface Docker images and Python modules.
