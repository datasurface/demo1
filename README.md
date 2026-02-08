# DataSurface Bootstrap

A template for bootstrapping a DataSurface Yellow environment with Kubernetes.

## Prerequisites

- Docker Desktop with Kubernetes enabled (local) or access to a remote Kubernetes cluster
- `kubectl` and `helm` CLI tools
- GitHub Personal Access Token (for GitSync and model repository access)
- GitLab credentials for DataSurface Docker images (see [ARTIFACTS.md](ARTIFACTS.md))

## Environment Variables

Set these before starting:

```bash
export NAMESPACE="demo1"
export GITHUB_USERNAME="your-github-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
export GITLAB_CUSTOMER_USER="gitlab+deploy-token-xxxxx"
export GITLAB_CUSTOMER_TOKEN="your-gitlab-deploy-token"
export DATASURFACE_VERSION="1.1.0"
```

## Setup

Clone the template repository:

```bash
git clone https://github.com/datasurface/demo1.git
cd demo1
```

Then follow one of the guided walkthroughs below using [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview). Each walkthrough is an interactive skill that walks you through the full setup process step-by-step, with verification at each stage and built-in troubleshooting.

### Local Docker Desktop

Use the **setup-walkthrough** skill for deploying on Docker Desktop with local PostgreSQL:

```
/setup-walkthrough
```

This covers: PostgreSQL setup, model customization, Kubernetes secrets, Airflow installation, bootstrap generation, deployment, and verification.

### Remote Kubernetes Cluster

Use the **setup-walkthrough** skill (remote variant) for deploying on a remote Kubernetes cluster with external PostgreSQL:

```
/remote-setup-walkthrough
```

This covers everything in the local walkthrough plus: CoreDNS configuration, SSH-based access, external database setup, Longhorn storage, and SSH tunnel access to Airflow.

## Project Structure

```text
.
├── docker/
│   └── postgres/            # PostgreSQL compose setup
├── helm/
│   └── airflow-values.yaml  # Airflow Helm values for Docker Desktop
├── generated_output/        # Generated after running bootstrap (gitignored)
│   └── Demo_PSP/
│       ├── kubernetes-bootstrap.yaml
│       ├── demo_psp_infrastructure_dag.py
│       ├── demo_psp_ring1_init_job.yaml
│       ├── demo_psp_model_merge_job.yaml
│       └── demo_psp_reconcile_views_job.yaml
├── eco.py                   # Ecosystem definition
├── rte_demo.py              # Runtime environment configuration
└── README.md
```

## Secrets Reference

For detailed information on how Yellow converts model credential names to Kubernetes secrets and the expected environment variable format, see the [credential creation guide](.claude/skills/create-k8-credential/SKILLS.md).

| Secret Name | Keys | Purpose |
| ------------- | ------ | --------- |
| `postgres` | `USER`, `PASSWORD` | Airflow metadata database |
| `postgres-demo-merge` | `USER`, `PASSWORD` | DataSurface merge database |
| `git` | `TOKEN` | Model repository access |
| `git-dags` | `GITSYNC_USERNAME`, `GITSYNC_PASSWORD` | Airflow DAG sync |
| `datasurface-registry` | Docker registry auth | Pull DataSurface images |

## DataSurface Artifacts

See [ARTIFACTS.md](ARTIFACTS.md) for accessing DataSurface Docker images and Python modules.
