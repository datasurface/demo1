# DataSurface Bootstrap

A template for bootstrapping a DataSurface Yellow environment on Docker Desktop with Kubernetes.

## Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl` and `helm` CLI tools
- GitHub Personal Access Token (for GitSync)

## Quick Start

This guide walks you through the following:

* Setup a postgres database container for datasurface to use
* Clone this repository containing the bootstrap model and modify it as needed, then push the customized model to a new repository, lets call it 'demo_actual'.
* Create a gitsync repository called demo_gitsync which is just for DAGs for our future airflow

* Create the database server and databases
* Install helm with correct values and use gitsync against demo_gitsync

* Use demo_actual's customized model to generate the bootstrap artifacts
* Push the generated DAG files to demo_gitsync


### Step 1: Start PostgreSQL

```bash
cd docker/postgres
docker compose up -d
```

This creates `airflow_db` and `merge_db` databases.

### Step 2: Clone the Repository

```bash
git clone https://github.com/datasurface/demo1.git
cd demo1
```

### Step 3: Create Kubernetes Namespace and Secrets

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

# Git credentials for DAG sync (both v3 and v4 key formats)
kubectl create secret generic git-dags \
  --from-literal=GIT_SYNC_USERNAME=$GITHUB_USERNAME \
  --from-literal=GIT_SYNC_PASSWORD=$GITHUB_TOKEN \
  --from-literal=GITSYNC_USERNAME=$GITHUB_USERNAME \
  --from-literal=GITSYNC_PASSWORD=$GITHUB_TOKEN \
  -n $NAMESPACE
```

### Step 4: Install Airflow

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  -f helm/airflow-values.yaml \
  -n $NAMESPACE \
  --timeout 10m
```

### Step 5: Generate and Deploy Bootstrap

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

# Push DAG to your gitsync repository
cd /path/to/demo_gitsync
mkdir -p dags
cp /path/to/demo_actual/generated_output/Demo_PSP/*_infrastructure_dag.py dags/
git add dags/
git commit -m "Add infrastructure DAG"
git push

# Apply init jobs
kubectl apply -f generated_output/Demo_PSP/*_ring1_init_job.yaml
kubectl apply -f generated_output/Demo_PSP/*_model_merge_job.yaml
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
