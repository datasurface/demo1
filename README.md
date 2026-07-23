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
export DATASURFACE_VERSION="1.8.4"
```

## Setup

Clone the template repository:

```bash
git clone https://github.com/datasurface/demo1.git
cd demo1
```

Then follow the guided walkthrough for the target environment. Each walkthrough verifies the
current Airflow 3.3/SCD4 bootstrap sequence and uses administrator-managed Kubernetes Secrets by
default.

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

This covers everything in the local walkthrough plus SSH-based access, external database/private
DNS verification, RWX storage such as Longhorn, and SSH tunnel access to Airflow.

### AWS EKS

Use `/setup-walkthrough-aws` for EKS with RDS PostgreSQL and EFS.

### Azure AKS

Use `/setup-walkthrough-azure` for AKS with PostgreSQL Flexible Server, Azure SQL, and Azure Files
NFS.

The AWS and Azure starters set `externalSecretProvider=None`. Customers can opt into External
Secrets Operator later; it is not required for the baseline setup.

## Working with your model (day-2 operations)

The starter model uses **SCD4 milestoning** (a current-snapshot table plus a separate history table). Once your environment is running, these interactive skills cover the day-to-day loop of changing, transforming, deploying, verifying, and operating it:

| Skill | Use it to |
| ----- | --------- |
| `/validate-model-locally` | Lint your model against the installed DataSurface in seconds, **before** you push (fast inner loop). |
| `/edit-model-fragment` | Check out, edit, and push a model change as a PR. |
| `/deploy-model-change` | Ship a model change to an already-running environment and confirm it took effect. |
| `/wire-datatransformer` | Add a DataTransformer — mask PII, run dbt, or derive datasets — and verify its output. |
| `/verify-data-fidelity` | Prove your data moved faithfully: compare source → merge → CQRS, check SCD4 per-key integrity and hash consistency. |
| `/check-system-health` | "How's it doing?" — throughput, database, and Airflow health with baselines. |
| `/upgrade-datasurface-version` | Move to a new DataSurface runtime version (bumps the image and regenerates bootstrap DAGs). |
| `/troubleshoot-airflow`, `/troubleshoot-k8s-jobs` | Diagnose failed DAGs, stuck tasks, and job errors. |

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
│       └── demo_psp_reconcile_views_job.yaml
├── eco.py                   # Ecosystem definition
├── rte_demo.py              # Runtime environment configuration
└── README.md
```

## Secrets Reference

For detailed information on credential-name normalization, canonical Secret keys, direct
Kubernetes Secrets, and optional ESO integration, see the
[credential creation guide](.claude/skills/create-k8-credential/SKILL.md).

| Secret Name | Keys | Purpose |
| ------------- | ------ | --------- |
| `airflow-metadata` | `connection` | Airflow metadata SQLAlchemy URI |
| `postgres-demo-merge` | `USER`, `PASSWORD` | DataSurface merge database |
| `git` | `TOKEN` | Model repository access |
| `git-dags` | `GITSYNC_USERNAME`, `GITSYNC_PASSWORD` | Airflow DAG sync |
| `datasurface-registry` | Docker registry auth | Pull DataSurface images |

## CI/CD Validation Secrets

This repository includes CI/CD workflow files that automatically validate pull requests (GitHub) and merge requests (GitLab) against the DataSurface model. These workflows pull the DataSurface validator Docker image from the GitLab Container Registry and require authentication secrets to be configured **before** validation will work.

### GitHub Actions — `.github/workflows/pull-request.yml`

Configure these as **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Purpose |
| ------ | ------- |
| `GITLAB_USERNAME` | GitLab deploy token username (for pulling the DataSurface image) |
| `GITLAB_ACCESS_TOKEN` | GitLab deploy token value |

### GitLab CI/CD — `.gitlab-ci.yml`

Configure these as **CI/CD variables** (Settings → CI/CD → Variables):

| Variable | Purpose |
| -------- | ------- |
| `GITLAB_REPO_TOKEN` | Token for cloning repositories |
| `GITLAB_USERNAME` | GitLab deploy token username (for pulling the DataSurface image) |
| `GITLAB_ACCESS_TOKEN` | GitLab deploy token value |
| `GITLAB_CLONE_HOST` | Your GitLab hostname (defaults to `gitlab.local`) |

Your GitLab deploy token credentials are the same ones described in [ARTIFACTS.md](ARTIFACTS.md). Without these secrets, the Docker image pull will fail and PR/MR validation will not run.

## DataSurface Artifacts

See [ARTIFACTS.md](ARTIFACTS.md) for accessing DataSurface Docker images and Python modules.
