# AWS Setup Walkthrough Skill Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a setup-walkthrough-aws skill and supporting model files that guide deployment of DataSurface Yellow on AWS EKS with Aurora, Helm Airflow 3.x, AWS Secrets Manager, and EFS.

**Architecture:** Single demo1 repo with env-var driven `rte_aws.py` alongside existing `rte_demo.py`. `eco.py` dispatches RTE based on `RTE_TARGET` env var. New `helm/airflow-values-aws.yaml` for AWS-specific Helm config. Skill file follows the pattern of existing `setup-walkthrough` and `remote-setup-walkthrough` skills.

**Tech Stack:** Python (DataSurface model), YAML (Helm values), Markdown (skill), AWS CloudFormation, EKS, Aurora, EFS, IRSA, Helm, Airflow 3.x

**Reference files:**
- Design: `docs/plans/2026-02-16-aws-setup-walkthrough-design.md`
- Existing local skill: `.claude/skills/setup-walkthrough/SKILL.md`
- Existing remote skill: `.claude/skills/remote-setup-walkthrough/SKILL.md`
- AWS HOWTO: `/Users/billy/Documents/Code/datasurface/docs/yellow_dp/HOWTO_AWS_SetupYellow.md`
- Assembly class: `/Users/billy/Documents/Code/datasurface/src/datasurface/platforms/yellow/aws_assembly.py` lines 411-540 (`YellowAWSExternalAirflow3AndMergeDatabase`)
- Old AWS repo for reference: `/Users/billy/Documents/Code/demos/demo1_session/yellow_aws_dual_aurora/`

---

## Task 1: Create rte_aws.py

**Files:**
- Create: `rte_aws.py`

**Step 1: Create `rte_aws.py` with env-var driven AWS configuration**

This file mirrors `rte_demo.py` but uses `YellowAWSExternalAirflow3AndMergeDatabase` assembly with values from environment variables. It defines the same `createDemoRTE` function signature so `eco.py` can dispatch to it.

```python
"""
Copyright (c) 2026 DataSurface Inc. All Rights Reserved.
Proprietary Software - See LICENSE.txt for terms.

AWS EKS runtime environment configuration for DataSurface Yellow.
All AWS-specific values are read from environment variables so the same
file works across different AWS deployments without modification.

Required environment variables:
  MERGE_HOST       - Aurora/RDS endpoint for merge database
  AWS_ACCOUNT_ID   - 12-digit AWS account ID

Optional environment variables:
  NAMESPACE              - K8s namespace (default: demo1-aws)
  AIRFLOW_HOST           - Aurora/RDS endpoint for Airflow DB (default: same as MERGE_HOST)
  AIRFLOW_PORT           - Airflow DB port (default: 5432)
  MERGE_PORT             - Merge DB port (default: 5432)
  MERGE_DBNAME           - Merge database name (default: merge_db)
  AIRFLOW_SERVICE_ACCOUNT - Helm Airflow worker service account (default: airflow-worker)
  DATASURFACE_VERSION    - DataSurface image version (default: 1.1.0)
"""

import os

from datasurface.dsl import ProductionStatus, \
    RuntimeEnvironment, Ecosystem, PSPDeclaration, \
    DataMilestoningStrategy
from datasurface.keys import LocationKey
from datasurface.containers import HostPortPair, PostgresDatabase
from datasurface.security import Credential, CredentialType
from datasurface.documentation import PlainTextDocumentation
from datasurface.platforms.yellow import YellowDataPlatform, YellowPlatformServiceProvider
from datasurface.platforms.yellow.aws_assembly import YellowAWSExternalAirflow3AndMergeDatabase
from datasurface.platforms.yellow.assembly import GitCacheConfig
from datasurface.repos import VersionPatternReleaseSelector, GitHubRepository, ReleaseType, VersionPatterns

# AWS configuration from environment variables
KUB_NAME_SPACE: str = os.environ.get("NAMESPACE", "demo1-aws")
AIRFLOW_SERVICE_ACCOUNT: str = os.environ.get("AIRFLOW_SERVICE_ACCOUNT", "airflow-worker")
MERGE_HOST: str = os.environ["MERGE_HOST"]
MERGE_PORT: int = int(os.environ.get("MERGE_PORT", "5432"))
MERGE_DBNAME: str = os.environ.get("MERGE_DBNAME", "merge_db")
AIRFLOW_HOST: str = os.environ.get("AIRFLOW_HOST", MERGE_HOST)
AIRFLOW_PORT: int = int(os.environ.get("AIRFLOW_PORT", "5432"))
AWS_ACCOUNT_ID: str = os.environ["AWS_ACCOUNT_ID"]
DATASURFACE_VERSION: str = os.environ.get("DATASURFACE_VERSION", "1.1.0")


def createDemoPSP() -> YellowPlatformServiceProvider:
    # Aurora merge database
    k8s_merge_datacontainer: PostgresDatabase = PostgresDatabase(
        "K8sMergeDB",
        hostPort=HostPortPair(MERGE_HOST, MERGE_PORT),
        locations={LocationKey("MyCorp:USA/NY_1")},
        productionStatus=ProductionStatus.NOT_PRODUCTION,
        databaseName=MERGE_DBNAME
    )

    git_config: GitCacheConfig = GitCacheConfig(
        enabled=True,
        access_mode="ReadWriteMany",
        storageClass="efs-sc"
    )

    yp_assembly: YellowAWSExternalAirflow3AndMergeDatabase = YellowAWSExternalAirflow3AndMergeDatabase(
        name="Demo",
        namespace=KUB_NAME_SPACE,
        git_cache_config=git_config,
        afHostPortPair=HostPortPair(AIRFLOW_HOST, AIRFLOW_PORT),
        airflowServiceAccount=AIRFLOW_SERVICE_ACCOUNT,
        aws_account_id=AWS_ACCOUNT_ID
    )

    psp: YellowPlatformServiceProvider = YellowPlatformServiceProvider(
        "Demo_PSP",
        {LocationKey("MyCorp:USA/NY_1")},
        PlainTextDocumentation("Demo PSP"),
        gitCredential=Credential("git", CredentialType.API_TOKEN),
        mergeRW_Credential=Credential("postgres-demo-merge", CredentialType.USER_PASSWORD),
        yp_assembly=yp_assembly,
        merge_datacontainer=k8s_merge_datacontainer,
        pv_storage_class="efs-sc",
        datasurfaceDockerImage=f"registry.gitlab.com/datasurface-inc/datasurface/datasurface:v{DATASURFACE_VERSION}",
        dataPlatforms=[
            YellowDataPlatform(
                "SCD2",
                doc=PlainTextDocumentation("SCD2 Yellow DataPlatform"),
                milestoneStrategy=DataMilestoningStrategy.SCD2,
                stagingBatchesToKeep=5
            )
        ]
    )
    return psp


def createDemoRTE(ecosys: Ecosystem) -> RuntimeEnvironment:
    assert isinstance(ecosys.owningRepo, GitHubRepository)

    psp: YellowPlatformServiceProvider = createDemoPSP()
    rte: RuntimeEnvironment = ecosys.getRuntimeEnvironmentOrThrow("demo")
    rte.configure(VersionPatternReleaseSelector(
        VersionPatterns.VN_N_N + "-demo", ReleaseType.STABLE_ONLY),
        [PSPDeclaration(psp.name, rte.owningRepo)],
        productionStatus=ProductionStatus.NOT_PRODUCTION)
    rte.setPSP(psp)
    return rte
```

**Step 2: Verify the file compiles**

Run from the demo1 directory:
```bash
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  -e RTE_TARGET=aws \
  -e MERGE_HOST=test-aurora.us-east-1.rds.amazonaws.com \
  -e AWS_ACCOUNT_ID=123456789012 \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.1.0 \
  python -c "from rte_aws import createDemoPSP; print('rte_aws.py compiles OK')"
```

Expected: `rte_aws.py compiles OK`

**Step 3: Commit**

```bash
git add rte_aws.py
git commit -m "feat: add AWS EKS runtime environment configuration

Env-var driven rte_aws.py using YellowAWSExternalAirflow3AndMergeDatabase
assembly for Aurora, EFS, IRSA, and AWS Secrets Manager."
```

---

## Task 2: Modify eco.py for RTE_TARGET dispatch

**Files:**
- Modify: `eco.py:9-13`

**Step 1: Add RTE_TARGET env var dispatch**

Replace the current import line (line 13):
```python
from rte_demo import createDemoRTE
```

With:
```python
import os

_RTE_TARGET = os.environ.get("RTE_TARGET", "local")

if _RTE_TARGET == "aws":
    from rte_aws import createDemoRTE
elif _RTE_TARGET == "azure":
    from rte_azure import createDemoRTE  # type: ignore[no-redef]
else:
    from rte_demo import createDemoRTE  # type: ignore[no-redef]
```

Note: The `# type: ignore[no-redef]` comments suppress mypy warnings about conditional redefinition, which is intentional here.

**Step 2: Verify local mode still works (default)**

```bash
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.1.0 \
  python -c "import eco; e = eco.createEcosystem(); print(f'Local mode: {e.name}')"
```

Expected: `Local mode: Demo`

**Step 3: Verify AWS mode works**

```bash
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  -e RTE_TARGET=aws \
  -e MERGE_HOST=test-aurora.us-east-1.rds.amazonaws.com \
  -e AWS_ACCOUNT_ID=123456789012 \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.1.0 \
  python -c "import eco; e = eco.createEcosystem(); print(f'AWS mode: {e.name}')"
```

Expected: `AWS mode: Demo`

**Step 4: Commit**

```bash
git add eco.py
git commit -m "feat: add RTE_TARGET env var dispatch for multi-environment support

eco.py now imports rte_demo (default), rte_aws, or rte_azure based on
the RTE_TARGET environment variable."
```

---

## Task 3: Create helm/airflow-values-aws.yaml

**Files:**
- Create: `helm/airflow-values-aws.yaml`

**Step 1: Create AWS-specific Helm values**

This file adapts `helm/airflow-values.yaml` for AWS EKS with:
- Custom Airflow image with AWS dependencies
- Secrets Store CSI driver volume for DB connection
- EFS storage class
- IRSA service account annotations (placeholder - skill fills in actual ARN)
- Production-appropriate resource limits

```yaml
# Airflow Helm Values for AWS EKS
# Used with: helm install airflow apache-airflow/airflow -f helm/airflow-values-aws.yaml

executor: CeleryExecutor

# Custom Airflow image with AWS dependencies (boto3, providers-amazon, providers-cncf-kubernetes)
images:
  airflow:
    repository: datasurface/airflow
    tag: "3.1.7"

# External Aurora PostgreSQL
postgresql:
  enabled: false

data:
  metadataConnection:
    user: postgres
    pass: PLACEHOLDER_DB_PASSWORD  # Skill replaces with actual password
    protocol: postgresql
    host: PLACEHOLDER_AURORA_ENDPOINT  # Skill replaces with CloudFormation output
    port: 5432
    db: airflow_db

# Redis for Celery broker
redis:
  enabled: true
  persistence:
    enabled: true
    storageClassName: efs-sc

# Scheduler
scheduler:
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi

# Workers
workers:
  replicas: 1
  persistence:
    enabled: true
    storageClassName: efs-sc
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi

# API server
apiServer:
  service:
    type: ClusterIP

# DAG processor
dagProcessor:
  enabled: true

# Triggerer
triggerer:
  enabled: true

# GitSync for DAGs
dags:
  persistence:
    enabled: false
  gitSync:
    enabled: true
    repo: https://github.com/PLACEHOLDER_AIRFLOW_REPO.git  # Skill replaces
    branch: main
    subPath: dags
    wait: 60
    credentialsSecret: git-dags

# Logs
logs:
  persistence:
    enabled: true
    storageClassName: efs-sc
    size: 5Gi

config:
  logging:
    delete_local_logs: "False"
  scheduler:
    dag_dir_list_interval: "60"

# Service account with IRSA annotation
serviceAccount:
  create: true
  name: airflow-worker
  annotations:
    eks.amazonaws.com/role-arn: PLACEHOLDER_AIRFLOW_ROLE_ARN  # Skill replaces with CloudFormation output

# Secrets Store CSI volume for Airflow DB connection (mounted from AWS Secrets Manager)
extraVolumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: airflow-secrets

extraVolumeMounts:
  - name: secrets-store
    mountPath: /mnt/secrets
    readOnly: true

# Web UI credentials
webserver:
  defaultUser:
    enabled: true
    username: admin
    password: admin
```

**Step 2: Commit**

```bash
git add helm/airflow-values-aws.yaml
git commit -m "feat: add AWS EKS Helm values for Airflow

Custom image, EFS storage, IRSA annotations, Secrets Store CSI volume.
Placeholder values are replaced by the setup-walkthrough-aws skill."
```

---

## Task 4: Create the setup-walkthrough-aws skill (Phase 1-2: Infrastructure)

**Files:**
- Create: `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Create skill directory**

```bash
mkdir -p .claude/skills/setup-walkthrough-aws
```

**Step 2: Write the skill file - opening section and Phases 1-2**

Write the first portion of the skill covering:
- YAML frontmatter (name, description)
- Execution rules
- Pre-flight checklist with required env vars
- Phase 1: AWS Infrastructure (CloudFormation Stage 1+2, OIDC fix)
- Phase 2: EKS Configuration (kubeconfig, EFS CSI, Secrets Store CSI, StorageClass, PVC test)

Reference material:
- HOWTO Phase 1 Steps 1-2: `/Users/billy/Documents/Code/datasurface/docs/yellow_dp/HOWTO_AWS_SetupYellow.md` lines 116-438
- HOWTO OIDC trust policy fix: same file lines 181-242
- Existing skill pattern: `.claude/skills/setup-walkthrough/SKILL.md` (execution rules, checkpoint format)
- Existing remote skill: `.claude/skills/remote-setup-walkthrough/SKILL.md` (external DB pattern)

The CloudFormation templates are at:
- EKS stack: `aws-marketplace/cloudformation/datasurface-eks-stack.yaml` (in datasurface repo)
- IAM roles: `aws-marketplace/cloudformation/iam-roles-for-eks.yaml` (in datasurface repo)

Key details to include from HOWTO:
- Two-stage CloudFormation: first EKS cluster, then IAM roles that depend on OIDC provider
- OIDC trust policy fix is PROACTIVE (Step 3, not troubleshooting) - extract actual OIDC issuer, update both EFS and Airflow role trust policies
- EFS StorageClass with `provisioningMode: efs-ap`, `uid/gid: 50000`
- Test PVC to verify EFS provisioning before proceeding
- `STACK_NAME` should be short to avoid S3 63-char limit issues

**Step 3: Commit partial skill**

```bash
git add .claude/skills/setup-walkthrough-aws/SKILL.md
git commit -m "feat: add AWS setup skill phases 1-2 (infrastructure + EKS config)"
```

---

## Task 5: Extend skill with Phase 3 (Model Preparation)

**Files:**
- Modify: `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Add Phase 3 to the skill**

Phase 3 covers:
- Step 8: Verify `rte_aws.py` exists (it was created in Task 1)
- Step 9: Verify `eco.py` has RTE_TARGET dispatch (modified in Task 2)
- Step 10: Customize `helm/airflow-values-aws.yaml` - replace PLACEHOLDERs with actual CloudFormation outputs:
  - `PLACEHOLDER_AURORA_ENDPOINT` -> `$AURORA_ENDPOINT`
  - `PLACEHOLDER_DB_PASSWORD` -> `$DATABASE_PASSWORD`
  - `PLACEHOLDER_AIRFLOW_REPO` -> user's airflow repo
  - `PLACEHOLDER_AIRFLOW_ROLE_ARN` -> `$AIRFLOW_ROLE_ARN` from CloudFormation
- Step 11: Build + push custom Airflow image with `docker buildx` for `linux/amd64,linux/arm64`
  - Dockerfile: `src/datasurface/platforms/yellow/docker/Docker.airflow_with_drivers` (in datasurface repo)
  - Tag: `datasurface/airflow:3.1.7`
  - Verify image has boto3, providers-amazon, providers-cncf-kubernetes
- Step 12: Push model to repo + create tag `v1.0.0-demo`

**Step 2: Commit**

```bash
git add .claude/skills/setup-walkthrough-aws/SKILL.md
git commit -m "feat: add AWS setup skill phase 3 (model preparation)"
```

---

## Task 6: Extend skill with Phase 4 (Secrets & Bootstrap)

**Files:**
- Modify: `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Add Phase 4 to the skill**

Phase 4 covers:
- Step 13: Create AWS Secrets Manager secrets
  - `airflow/connections/postgres_default` - PostgreSQL URI format for CSI driver: `postgresql://postgres:$DATABASE_PASSWORD@$AURORA_ENDPOINT:5432/airflow_db`
  - `datasurface/merge/credentials` - JSON: `{"postgres_USER":"postgres","postgres_PASSWORD":"$DATABASE_PASSWORD"}`
  - `datasurface/git/credentials` - JSON: `{"token":"$GITHUB_TOKEN"}`
  - Checkpoint: `aws secretsmanager list-secrets` shows all 3

- Step 14: Generate bootstrap artifacts
  ```bash
  docker run --rm \
    -v "$(pwd)":/workspace/model \
    -w /workspace/model \
    -e RTE_TARGET=aws \
    -e MERGE_HOST="$AURORA_ENDPOINT" \
    -e AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
    -e NAMESPACE="$NAMESPACE" \
    registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION} \
    python -m datasurface.cmd.platform generatePlatformBootstrap \
    --ringLevel 0 \
    --model /workspace/model \
    --output /workspace/model/generated_output \
    --psp Demo_PSP \
    --rte-name demo
  ```
  Checkpoint: `ls generated_output/Demo_PSP/` shows 5 expected files

- Step 15: Fix IAM role ARN in generated YAML (proactive)
  - Get actual ARN: `aws cloudformation describe-stacks --stack-name "${STACK_NAME}-iam-roles" --query 'Stacks[0].Outputs[?OutputKey==\`AirflowSecretsRoleArn\`].OutputValue' --output text`
  - `sed` replace in `generated_output/Demo_PSP/kubernetes-bootstrap.yaml`
  - Checkpoint: `grep "role-arn" generated_output/Demo_PSP/kubernetes-bootstrap.yaml` shows actual ARN

**Step 2: Commit**

```bash
git add .claude/skills/setup-walkthrough-aws/SKILL.md
git commit -m "feat: add AWS setup skill phase 4 (secrets + bootstrap)"
```

---

## Task 7: Extend skill with Phase 5 (Deploy to EKS)

**Files:**
- Modify: `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Add Phase 5 to the skill**

Phase 5 covers:
- Step 16: Create namespace + GitLab registry secret + patch service account
- Step 17: Initialize DAG repo (BEFORE Helm install - same as remote skill pattern)
  - Clone airflow repo, create `dags/` dir, copy infrastructure DAG, push to main
- Step 18: Install Airflow via Helm
  ```bash
  helm repo add apache-airflow https://airflow.apache.org
  helm repo update
  helm install airflow apache-airflow/airflow \
    -f helm/airflow-values-aws.yaml \
    -n $NAMESPACE \
    --timeout 10m
  ```
  Checkpoint: All Airflow pods reaching Running state
- Step 19: Create RBAC for Airflow secret access (same Role/RoleBinding pattern as existing skills)
- Step 20: Apply kubernetes-bootstrap.yaml + annotate Airflow SA with IAM role
  ```bash
  kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml
  kubectl annotate serviceaccount airflow-worker \
    -n $NAMESPACE \
    eks.amazonaws.com/role-arn=$AIRFLOW_ROLE_ARN \
    --overwrite
  ```
- Step 21: Run ring1-init then model-merge jobs (sequential, with `kubectl wait`)
  Checkpoint: Both jobs show Complete (1/1)

**Step 2: Commit**

```bash
git add .claude/skills/setup-walkthrough-aws/SKILL.md
git commit -m "feat: add AWS setup skill phase 5 (deploy to EKS)"
```

---

## Task 8: Extend skill with Phase 6 (Verify) and Troubleshooting

**Files:**
- Modify: `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Add Phase 6 to the skill**

Phase 6 covers:
- Step 22: Create Airflow admin user (`airflow users create` via kubectl exec)
- Step 23: Push DAG to airflow repo (if not already done in Step 17)
- Step 24: Verify DAGs registered (wait 60-90s for git-sync, `airflow dags list`)
  Expected DAGs: same 5 as Docker Desktop skill
- Step 25: Port-forward + access UI
  ```bash
  kubectl port-forward svc/airflow-api-server 8080:8080 -n $NAMESPACE
  ```
  Open http://localhost:8080 - admin/admin

**Step 2: Add Troubleshooting section**

Cover these issues from the HOWTO (lines 1694-1970):
- **Insufficient CPU**: Instance type recommendations (m5.large insufficient, m5.xlarge recommended), `kubectl patch` to reduce resource requests
- **Secrets Manager access denied**: Verify IRSA annotation, test role assumption from pod, check OIDC trust policy
- **Init container OOMKilled**: Add resource limits to init containers in generated YAML
- **PVC stuck Pending**: Check EFS CSI driver status, verify SA annotation, restart controller
- **Aurora connectivity from pods**: Run postgres:16 test pod with `psql` command
- **Custom image missing AWS deps**: Verify boto3/providers with `pip list | grep`

**Step 3: Add Key Differences table**

| Aspect | Local (Docker Desktop) | AWS (EKS) |
|--------|----------------------|-----------|
| Database | Docker Compose PostgreSQL | Aurora RDS |
| Secrets | Kubernetes secrets | AWS Secrets Manager + CSI driver |
| Storage | standard/hostpath | EFS (efs-sc) |
| Infrastructure | None | CloudFormation (2 stacks) |
| Auth | None | IRSA (IAM Roles for Service Accounts) |
| Airflow image | apache/airflow:3.1.7 | datasurface/airflow:3.1.7 (custom, with AWS deps) |
| Git cache | ReadWriteOnce | ReadWriteMany |
| Network | localhost | VPC + security groups |

**Step 4: Commit**

```bash
git add .claude/skills/setup-walkthrough-aws/SKILL.md
git commit -m "feat: complete AWS setup skill with verification and troubleshooting"
```

---

## Task 9: Final Review and Integration Commit

**Files:**
- Review: `rte_aws.py`, `eco.py`, `helm/airflow-values-aws.yaml`, `.claude/skills/setup-walkthrough-aws/SKILL.md`

**Step 1: Verify all files are consistent**

Check:
- `rte_aws.py` env var names match what the skill tells users to set
- `helm/airflow-values-aws.yaml` PLACEHOLDER names match what the skill replaces
- Assembly class name and import path are correct
- Namespace default (`demo1-aws`) is consistent across all files
- Storage class (`efs-sc`) is consistent across all files
- Airflow image tag (`3.1.7`) is consistent across all files
- Service account name (`airflow-worker`) is consistent across all files

**Step 2: Verify local mode is not broken**

```bash
docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.1.0 \
  python -c "import eco; e = eco.createEcosystem(); print(f'Local mode OK: {e.name}')"
```

Expected: `Local mode OK: Demo` (proves the eco.py change defaults to rte_demo correctly)

**Step 3: Final commit if any adjustments needed**

```bash
git add -A
git commit -m "fix: address review findings from AWS setup skill integration"
```

---

## Known Issues to Note

1. **Assembly storage class mismatch**: `YellowAWSExternalAirflow3AndMergeDatabase.createAssembly()` hardcodes `"gp3"` for the git-cache PVC storage class (line 522 of aws_assembly.py), but `rte_aws.py` sets `GitCacheConfig(storageClass="efs-sc")`. The `storageClass` from GitCacheConfig may be ignored by the assembly. If PVCs fail to bind, the generated `kubernetes-bootstrap.yaml` may need manual `sed` fix from `gp3` to `efs-sc`. Document this in the skill's troubleshooting section.

2. **Custom Airflow image**: The skill assumes `datasurface/airflow:3.1.7` exists on Docker Hub (or ECR). The user must build and push this image as a prerequisite step. The Dockerfile is in the datasurface repo, not in demo1.

3. **Secrets Store CSI SecretProviderClass**: The Helm values reference `secretProviderClass: airflow-secrets` but this Kubernetes resource must be created separately. The skill should include a step to create this resource defining which AWS Secrets Manager secrets to mount.
