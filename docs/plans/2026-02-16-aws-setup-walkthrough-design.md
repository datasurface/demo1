# Design: AWS Setup Walkthrough Skill

**Date**: 2026-02-16
**Status**: Approved

## Summary

Create a `setup-walkthrough-aws` skill that guides users through deploying a DataSurface Yellow environment on AWS EKS with Aurora, Helm-managed Airflow 3.x, AWS Secrets Manager, and EFS storage. The skill follows the same sequential, checkpoint-verified pattern as the existing `setup-walkthrough` (Docker Desktop) and `remote-setup-walkthrough` skills.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Database | Aurora only | Simpler flow, CloudFormation creates Aurora, credentials auto-created |
| Infrastructure | Full CloudFormation included | End-to-end skill, matches HOWTO experience |
| Known fixes | Proactive steps in main flow | Prevents the 3 most common blockers rather than reacting |
| Airflow deployment | Helm chart | Matches Docker Desktop skill pattern, cleaner than raw YAML |
| Starter repo | Single demo1 repo with RTE_TARGET env var | One source of truth, avoids repo proliferation |
| Model config | Separate rte_aws.py with env var driven values | Coexists with rte_demo.py (local) and future rte_azure.py |
| Default namespace | demo1-aws | Must be valid DNS label (hyphens, no underscores) |

## Assembly Class

Uses `YellowAWSExternalAirflow3AndMergeDatabase` from `datasurface.platforms.yellow.aws_assembly`:
- Airflow 3.x installed via Helm (external, not managed by DataSurface)
- RDS/Aurora PostgreSQL for merge database
- AWS Secrets Manager for credential management
- IRSA (IAM Roles for Service Accounts) support

## Architecture

### Environment Variable Driven Model

The model files use `os.environ` to pick up deployment-specific values at bootstrap generation time. No hardcoded endpoints or account IDs.

**eco.py** dispatches RTE based on `RTE_TARGET` env var:
```python
import os
RTE_TARGET = os.environ.get("RTE_TARGET", "local")
if RTE_TARGET == "aws":
    from rte_aws import createDemoRTE
elif RTE_TARGET == "azure":
    from rte_azure import createDemoRTE
else:
    from rte_demo import createDemoRTE
```

**rte_aws.py** reads AWS-specific config from environment:
```python
import os
KUB_NAME_SPACE = os.environ.get("NAMESPACE", "demo1-aws")
MERGE_HOST = os.environ["MERGE_HOST"]        # Aurora endpoint, required
AWS_ACCOUNT_ID = os.environ["AWS_ACCOUNT_ID"] # Required
AIRFLOW_HOST = os.environ.get("AIRFLOW_HOST", MERGE_HOST)  # Same Aurora by default
```

**Bootstrap generation** passes env vars to Docker:
```bash
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  -e RTE_TARGET=aws \
  -e MERGE_HOST="$AURORA_ENDPOINT" \
  -e AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
  -e NAMESPACE="$NAMESPACE" \
  datasurface/datasurface:latest \
  python -m datasurface.cmd.platform generatePlatformBootstrap ...
```

### Helm Values

AWS-specific `helm/airflow-values-aws.yaml` differs from local:

| Concern | Local | AWS |
|---------|-------|-----|
| Image | Default Airflow | Custom with AWS deps (boto3, providers) |
| DB connection | K8s secret | File mount via Secrets Store CSI |
| Storage class | standard/hostpath | efs-sc |
| Service account | Default | IRSA-annotated |
| Extra volumes | None | Secrets Store CSI for Airflow DB connection |

### Proactive Known Fixes

Three issues from the HOWTO are built directly into the main flow as steps:

1. **OIDC trust policy fix** (Phase 1) - CloudFormation template has hardcoded OIDC IDs that don't match the actual EKS cluster. Skill extracts real OIDC issuer and updates both EFS and Airflow role trust policies immediately after IAM roles stack deploys.

2. **IAM role ARN fixup** (Phase 4) - Generated bootstrap YAML contains `airflow-secrets-role` but CloudFormation creates auto-named roles like `ds-eks-m5-v5-iam-roles-AirflowSecretsRole-6PRSTdC9kgcr`. Skill uses `sed` to replace with actual ARN from CloudFormation outputs.

3. **EFS PVC test** (Phase 2) - Creates a test PVC and verifies it binds before proceeding. Catches trust policy issues early before they block the deployment.

## Skill Phase Structure

### Phase 1: AWS Infrastructure (~200 lines)
- Step 0: Clean up previous installation (if exists)
- Step 1: Deploy EKS cluster (CloudFormation Stage 1, ~15 min wait)
- Step 2: Deploy IAM roles (CloudFormation Stage 2)
- Step 3: Fix OIDC trust policies (proactive)

### Phase 2: EKS Configuration (~150 lines)
- Step 4: Configure kubeconfig + verify nodes
- Step 5: Install EFS CSI driver + annotate SA + restart controller
- Step 6: Install Secrets Store CSI driver (Helm)
- Step 7: Create EFS StorageClass + test PVC bind

### Phase 3: Model Preparation (~150 lines)
- Step 8: Create rte_aws.py (env-var driven)
- Step 9: Edit eco.py (add RTE_TARGET dispatch)
- Step 10: Create helm/airflow-values-aws.yaml
- Step 11: Build + push custom Airflow image (docker buildx multiplatform)
- Step 12: Push model to repo + tag

### Phase 4: Secrets & Bootstrap (~100 lines)
- Step 13: Create AWS Secrets Manager secrets (Aurora URI, merge creds, git token)
- Step 14: Generate bootstrap artifacts (docker run with env vars)
- Step 15: Fix IAM role ARN in generated YAML (proactive)

### Phase 5: Deploy to EKS (~200 lines)
- Step 16: Create namespace + GitLab registry secret
- Step 17: Initialize DAG repo (BEFORE Helm install)
- Step 18: Install Airflow via Helm
- Step 19: Create RBAC for secret access
- Step 20: Apply kubernetes-bootstrap.yaml + annotate Airflow SA with IAM role
- Step 21: Run ring1-init then model-merge jobs (sequential)

### Phase 6: Verify & Access (~100 lines)
- Step 22: Create Airflow admin user
- Step 23: Push DAG to airflow repo
- Step 24: Verify DAGs registered (wait for git-sync)
- Step 25: Port-forward + access UI

### Troubleshooting (~200 lines)
- Insufficient CPU / instance type recommendations
- Secrets Manager access denied / IRSA verification
- Init container OOMKilled
- PVC stuck pending
- Aurora connectivity from pods
- Custom image missing AWS deps

## Deliverables

1. `.claude/skills/setup-walkthrough-aws/SKILL.md` - The skill (~1000-1200 lines)
2. `rte_aws.py` - AWS runtime environment (env-var driven)
3. `helm/airflow-values-aws.yaml` - AWS Helm values for Airflow
4. `eco.py` modification - RTE_TARGET env var dispatch

## Reference Documents

- Existing HOWTO: `/Users/billy/Documents/Code/datasurface/docs/yellow_dp/HOWTO_AWS_SetupYellow.md`
- Assembly class: `datasurface/platforms/yellow/aws_assembly.py` (`YellowAWSExternalAirflow3AndMergeDatabase`)
- Docker Desktop skill: `.claude/skills/setup-walkthrough/SKILL.md`
- Remote cluster skill: `.claude/skills/remote-setup-walkthrough/SKILL.md`
