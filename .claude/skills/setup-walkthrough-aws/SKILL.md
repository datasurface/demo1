---
name: DataSurface AWS EKS Setup Walkthrough
description: Interactive walkthrough for setting up a DataSurface Yellow environment on AWS EKS with Aurora, Helm Airflow 3.x, AWS Secrets Manager, EFS, and IRSA. Use this skill to guide users through the complete AWS installation process step-by-step.
---

# DataSurface AWS EKS Setup Walkthrough

This skill guides you through deploying a DataSurface Yellow environment on AWS EKS (Elastic Kubernetes Service). It uses CloudFormation for infrastructure, Aurora PostgreSQL for databases, EFS for shared storage, AWS Secrets Manager for credentials, and IRSA (IAM Roles for Service Accounts) for pod-level AWS access. Follow each step in order and verify completion before proceeding.

## IMPORTANT: Execution Rules

1. **Execute steps sequentially** - Do not skip ahead or combine steps
2. **Verify each step** - Confirm success before proceeding to the next step
3. **Ask for missing information** - If environment variables or credentials are not provided, ask the user
4. **Report failures immediately** - If any step fails, stop and troubleshoot before continuing

## Pre-Flight Checklist

Before starting, verify the user has:

- [ ] Docker Desktop running (for image builds and bootstrap generation)
- [ ] AWS CLI installed and configured (`aws sts get-caller-identity` succeeds)
- [ ] `kubectl` CLI installed
- [ ] `helm` CLI installed
- [ ] GitHub Personal Access Token (needs repo access)
- [ ] GitLab credentials for DataSurface images

Ask the user for these environment variables if not already set:

```bash
AWS_ACCOUNT_ID          # 12-digit AWS account ID
AWS_REGION              # AWS region (default: us-east-1)
KEY_PAIR_NAME           # EC2 key pair for node SSH access
STACK_NAME              # CloudFormation stack name (short, unique, e.g., "ds-eks-v1")
DATABASE_PASSWORD       # Aurora PostgreSQL password
GITHUB_USERNAME         # GitHub username
GITHUB_TOKEN            # GitHub Personal Access Token (repo access)
GITLAB_CUSTOMER_USER    # GitLab deploy token username
GITLAB_CUSTOMER_TOKEN   # GitLab deploy token
DATASURFACE_VERSION     # DataSurface version (default: 1.1.0)
MODEL_REPO              # Target model repo (e.g., yourorg/demo1_actual)
AIRFLOW_REPO            # Target DAG repo (e.g., yourorg/demo1_airflow)
NAMESPACE               # K8s namespace (default: demo1-aws)
```

Verify AWS CLI is configured:

```bash
aws sts get-caller-identity
```

---

## Phase 1: AWS Infrastructure

### Step 0: Clean Up Previous Installation (If Exists)

**Always run this step, even for "fresh" installations.** Previous CloudFormation stacks, namespaces, or secrets can cause conflicts.

#### 0a. Delete existing CloudFormation stacks (if they exist)

```bash
# Check for existing stacks
aws cloudformation describe-stacks --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION 2>/dev/null && \
  aws cloudformation delete-stack --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION && \
  aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION

aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION 2>/dev/null && \
  aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION && \
  aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $AWS_REGION
```

#### 0b. Delete existing namespace (if it exists)

```bash
kubectl get namespace $NAMESPACE 2>/dev/null && \
  kubectl delete namespace $NAMESPACE

# If namespace is stuck in Terminating state (wait 30 seconds, then check):
kubectl get namespace $NAMESPACE -o json 2>/dev/null | jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
```

#### 0c. Clean up AWS Secrets Manager secrets (if they exist)

```bash
aws secretsmanager delete-secret --secret-id "airflow/connections/postgres_default" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "datasurface/merge/credentials" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "datasurface/git/credentials" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
```

**Checkpoint:**
- `aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION` returns "does not exist"
- `kubectl get namespace $NAMESPACE` returns "not found"
- No lingering secrets in Secrets Manager

---

### Step 1: Deploy EKS Cluster (CloudFormation Stage 1)

This creates the VPC, EKS cluster, node group, Aurora PostgreSQL, and EFS file system.

**IMPORTANT:** `STACK_NAME` should be short to avoid S3 bucket name 63-character limit issues.

```bash
aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://aws-marketplace/cloudformation/datasurface-eks-stack.yaml \
  --parameters \
    ParameterKey=KeyPairName,ParameterValue=$KEY_PAIR_NAME \
    ParameterKey=DatabasePassword,ParameterValue=$DATABASE_PASSWORD \
    ParameterKey=GitHubToken,ParameterValue=$GITHUB_TOKEN \
    ParameterKey=CreateDatabase,ParameterValue=true \
    ParameterKey=KubernetesDeploymentType,ParameterValue=EKS-EC2 \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

# Wait for stack creation (~15 minutes)
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $AWS_REGION
```

**Checkpoint:**

```bash
aws cloudformation describe-stacks --stack-name $STACK_NAME \
  --query 'Stacks[0].StackStatus' --output text --region $AWS_REGION
```

Stack status must be `CREATE_COMPLETE`.

---

### Step 2: Deploy IAM Roles (CloudFormation Stage 2)

This creates IRSA roles for EFS CSI driver and Airflow secrets access.

```bash
export OIDC_PROVIDER_ARN=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='EKSOIDCProviderArn'].OutputValue" \
  --output text --region $AWS_REGION)

aws cloudformation create-stack \
  --stack-name "${STACK_NAME}-iam-roles" \
  --template-body file://aws-marketplace/cloudformation/iam-roles-for-eks.yaml \
  --parameters \
    ParameterKey=EKSOIDCProviderArn,ParameterValue=$OIDC_PROVIDER_ARN \
    ParameterKey=StackName,ParameterValue=$STACK_NAME \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

aws cloudformation wait stack-create-complete --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION
```

**Checkpoint:**

```bash
aws cloudformation describe-stacks --stack-name "${STACK_NAME}-iam-roles" \
  --query 'Stacks[0].StackStatus' --output text --region $AWS_REGION
```

Both stacks must be `CREATE_COMPLETE`.

---

### Step 3: Fix OIDC Trust Policies (PROACTIVE)

**This is a KNOWN ISSUE with the CloudFormation template** - it has hardcoded OIDC IDs that do not match your actual cluster. This step fixes both the EFS CSI driver role AND the Airflow secrets role. Skipping this step causes "Access Denied" errors later.

```bash
OIDC_ISSUER=$(echo $OIDC_PROVIDER_ARN | cut -d'/' -f2-)

# Fix EFS CSI driver role
EFS_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" \
  --query 'Stacks[0].Outputs[?OutputKey==`EFSCSIDriverRoleArn`].OutputValue' \
  --output text --region $AWS_REGION)
EFS_ROLE_NAME=$(echo $EFS_ROLE_ARN | cut -d'/' -f2)

cat > efs-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Federated": "$OIDC_PROVIDER_ARN"},
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${OIDC_ISSUER}:sub": "system:serviceaccount:kube-system:efs-csi-controller-sa",
                "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
            }
        }
    }]
}
EOF
aws iam update-assume-role-policy --role-name $EFS_ROLE_NAME --policy-document file://efs-trust-policy.json

# Fix Airflow secrets role
cat > airflow-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Federated": "$OIDC_PROVIDER_ARN"},
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${OIDC_ISSUER}:sub": "system:serviceaccount:${NAMESPACE}:airflow-worker",
                "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
            }
        }
    }]
}
EOF
AIRFLOW_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" \
  --query 'Stacks[0].Outputs[?OutputKey==`AirflowSecretsRoleArn`].OutputValue' \
  --output text --region $AWS_REGION)
AIRFLOW_ROLE_NAME=$(echo $AIRFLOW_ROLE_ARN | cut -d'/' -f2)
aws iam update-assume-role-policy --role-name $AIRFLOW_ROLE_NAME --policy-document file://airflow-trust-policy.json

# Clean up temp files
rm -f efs-trust-policy.json airflow-trust-policy.json
```

**Checkpoint:**
- Both `aws iam update-assume-role-policy` commands complete without error
- Verify with: `aws iam get-role --role-name $EFS_ROLE_NAME --query 'Role.AssumeRolePolicyDocument'`

---

## Phase 2: EKS Configuration

### Step 4: Configure kubeconfig

```bash
export CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' \
  --output text --region $AWS_REGION)

aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
kubectl get nodes
```

**Checkpoint:** All nodes should be in `Ready` status:

```bash
kubectl get nodes -o wide
```

---

### Step 5: Install EFS CSI Driver

```bash
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-efs-csi-driver \
  --region $AWS_REGION

aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-efs-csi-driver \
  --region $AWS_REGION

# Annotate service account with IAM role for IRSA
kubectl annotate serviceaccount efs-csi-controller-sa \
  -n kube-system \
  eks.amazonaws.com/role-arn=$EFS_ROLE_ARN \
  --overwrite

# Restart controller to pick up the annotation
kubectl rollout restart deployment/efs-csi-controller -n kube-system
kubectl rollout status deployment/efs-csi-controller -n kube-system
```

**Checkpoint:**

```bash
kubectl get pods -n kube-system -l app=efs-csi-controller
```

EFS CSI controller pods should be `Running`.

---

### Step 6: Install Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --namespace kube-system

# Install AWS provider
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

# Wait for provider pods
kubectl wait --for=condition=ready pod -l app=csi-secrets-store-provider-aws -n kube-system --timeout=60s
```

**Checkpoint:**

```bash
kubectl get pods -n kube-system -l app=csi-secrets-store-provider-aws
```

Provider pods should be `Running`.

---

### Step 7: Create EFS StorageClass and Test

```bash
export EFS_FILE_SYSTEM_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' \
  --output text --region $AWS_REGION)

cat > efs-storageclass.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS_FILE_SYSTEM_ID
  directoryPerms: "0755"
  uid: "50000"
  gid: "50000"
volumeBindingMode: Immediate
EOF
kubectl apply -f efs-storageclass.yaml
rm efs-storageclass.yaml
```

Test EFS provisioning with a temporary PVC:

```bash
cat > test-efs-pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-efs-pvc
  namespace: default
spec:
  storageClassName: efs-sc
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF
kubectl apply -f test-efs-pvc.yaml
sleep 30

PVC_STATUS=$(kubectl get pvc test-efs-pvc -o jsonpath='{.status.phase}')
if [ "$PVC_STATUS" = "Bound" ]; then
    echo "EFS provisioning test successful"
    kubectl delete pvc test-efs-pvc
    rm test-efs-pvc.yaml
else
    echo "EFS provisioning FAILED - check troubleshooting section"
    kubectl describe pvc test-efs-pvc
fi
```

**Checkpoint:** Test PVC status is `Bound`. If it fails, see the EFS troubleshooting section below.

---

## Phase 3: Model Preparation

### Step 8: Verify rte_aws.py Exists

```bash
ls -la rte_aws.py
```

The file should already exist in the repository. It contains the AWS-specific runtime environment configuration (Aurora endpoints, EFS storage class, IRSA annotations, Secrets Manager references). If missing, see the plan documentation for the full file content.

**Checkpoint:** File exists and contains AWS-specific configuration.

---

### Step 9: Verify eco.py Has RTE_TARGET Dispatch

```bash
grep -A5 "RTE_TARGET" eco.py
```

This should show the import dispatch logic that selects between `rte_demo` (local) and `rte_aws` (AWS) based on the `RTE_TARGET` environment variable. If missing, add the dispatch:

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

**Checkpoint:** `eco.py` imports from `rte_aws` when `RTE_TARGET=aws`.

---

### Step 10: Customize helm/airflow-values-aws.yaml

Get CloudFormation outputs and replace PLACEHOLDERs in the Helm values file:

```bash
export AURORA_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`AuroraClusterEndpoint`].OutputValue' \
  --output text --region $AWS_REGION)

export AIRFLOW_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" \
  --query 'Stacks[0].Outputs[?OutputKey==`AirflowSecretsRoleArn`].OutputValue' \
  --output text --region $AWS_REGION)

# Replace placeholders in Helm values
sed -i.bak "s|PLACEHOLDER_AURORA_ENDPOINT|$AURORA_ENDPOINT|g" helm/airflow-values-aws.yaml
sed -i.bak "s|PLACEHOLDER_DB_PASSWORD|$DATABASE_PASSWORD|g" helm/airflow-values-aws.yaml
sed -i.bak "s|PLACEHOLDER_AIRFLOW_REPO|$AIRFLOW_REPO|g" helm/airflow-values-aws.yaml
sed -i.bak "s|PLACEHOLDER_AIRFLOW_ROLE_ARN|$AIRFLOW_ROLE_ARN|g" helm/airflow-values-aws.yaml
rm -f helm/airflow-values-aws.yaml.bak
```

**Note:** On macOS, `sed -i` requires a backup extension. Use `sed -i.bak` then remove the `.bak` file.

**Checkpoint:**

```bash
grep PLACEHOLDER helm/airflow-values-aws.yaml
```

Should return no matches (all PLACEHOLDERs replaced).

---

### Step 11: Build and Push Custom Airflow Image

The custom image includes PostgreSQL, MSSQL, Oracle, DB2 drivers plus boto3 and AWS providers needed for AWS deployments.

```bash
cd /path/to/datasurface
docker buildx build --platform linux/amd64,linux/arm64 \
  -f src/datasurface/platforms/yellow/docker/Docker.airflow_with_drivers \
  -t datasurface/airflow:3.1.7 \
  --push .
```

Verify the image contains required AWS dependencies:

```bash
docker run --rm datasurface/airflow:3.1.7 pip list | grep -E "(boto3|apache-airflow-providers-amazon|apache-airflow-providers-cncf-kubernetes)"
```

**Checkpoint:** Image is pushed and contains:
- `boto3`
- `apache-airflow-providers-amazon`
- `apache-airflow-providers-cncf-kubernetes`

---

### Step 12: Push Model to Repository and Tag

```bash
git remote set-url origin https://github.com/$MODEL_REPO.git

git add eco.py rte_aws.py helm/airflow-values-aws.yaml
git commit -m "Configure model for AWS EKS deployment"
git push -u origin main --force

git tag v1.0.0-demo
git push origin v1.0.0-demo
```

**Checkpoint:**
- `git remote -v` shows the target model repository
- `git log -1` shows the configure commit
- `git tag` shows `v1.0.0-demo`
- Verify on GitHub that the repository has updated files AND the tag exists

---

## Phase 4: Secrets & Bootstrap

### Step 13: Create AWS Secrets Manager Secrets

```bash
# Airflow DB connection (URI format for CSI driver file mounting)
aws secretsmanager create-secret \
  --name "airflow/connections/postgres_default" \
  --description "Airflow database connection for Aurora (CSI mounted)" \
  --secret-string "postgresql://postgres:${DATABASE_PASSWORD}@${AURORA_ENDPOINT}:5432/airflow_db" \
  --region $AWS_REGION

# Merge database credentials (JSON format for boto3 access in DAGs)
aws secretsmanager create-secret \
  --name "datasurface/merge/credentials" \
  --description "DataSurface merge database credentials" \
  --secret-string "{\"postgres_USER\":\"postgres\",\"postgres_PASSWORD\":\"${DATABASE_PASSWORD}\"}" \
  --region $AWS_REGION

# Git credentials
aws secretsmanager create-secret \
  --name "datasurface/git/credentials" \
  --description "DataSurface Git repository credentials" \
  --secret-string "{\"token\":\"${GITHUB_TOKEN}\"}" \
  --region $AWS_REGION
```

Verify all secrets were created:

```bash
aws secretsmanager list-secrets \
  --query 'SecretList[?contains(Name, `datasurface`) || contains(Name, `airflow`)].Name' \
  --output table --region $AWS_REGION
```

**Checkpoint:** All 3 secrets are listed:
- `airflow/connections/postgres_default`
- `datasurface/merge/credentials`
- `datasurface/git/credentials`

---

### Step 14: Generate Bootstrap Artifacts

```bash
docker login registry.gitlab.com -u "$GITLAB_CUSTOMER_USER" -p "$GITLAB_CUSTOMER_TOKEN"
docker pull registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}

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

**Checkpoint:**

```bash
ls generated_output/Demo_PSP/
```

Should contain:
- kubernetes-bootstrap.yaml
- infrastructure_dag.py (or demo_psp_infrastructure_dag.py)
- ring1_init_job.yaml (or demo_psp_ring1_init_job.yaml)
- model_merge_job.yaml (or demo_psp_model_merge_job.yaml)
- reconcile_views_job.yaml (or demo_psp_reconcile_views_job.yaml)

---

### Step 15: Fix IAM Role ARN in Generated YAML (PROACTIVE)

The generated YAML may contain a hardcoded role name that does not match CloudFormation's auto-generated name. This step ensures the correct ARN is used.

```bash
# Get actual role ARN from CloudFormation
ACTUAL_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" \
  --query 'Stacks[0].Outputs[?OutputKey==`AirflowSecretsRoleArn`].OutputValue' \
  --output text --region $AWS_REGION)

# Replace any hardcoded role references in generated YAML
sed -i.bak "s|arn:aws:iam::${AWS_ACCOUNT_ID}:role/airflow-secrets-role|${ACTUAL_ROLE_ARN}|g" \
  generated_output/Demo_PSP/kubernetes-bootstrap.yaml
rm -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml.bak
```

**Checkpoint:**

```bash
grep "role-arn" generated_output/Demo_PSP/kubernetes-bootstrap.yaml
```

The role ARN in the YAML should match the actual CloudFormation output (`$ACTUAL_ROLE_ARN`).

---

## Phase 5: Deploy to EKS

### Step 16: Create Namespace and Registry Secret

```bash
kubectl create namespace $NAMESPACE

# GitLab registry credentials for pulling DataSurface images
kubectl create secret docker-registry datasurface-registry \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  -n $NAMESPACE

# Attach image pull secret to default service account
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "datasurface-registry"}]}'
```

Create git-dags secret for Helm git-sync:

```bash
kubectl create secret generic git-dags \
  --from-literal=GIT_SYNC_USERNAME=$GITHUB_USERNAME \
  --from-literal=GIT_SYNC_PASSWORD=$GITHUB_TOKEN \
  --from-literal=GITSYNC_USERNAME=$GITHUB_USERNAME \
  --from-literal=GITSYNC_PASSWORD=$GITHUB_TOKEN \
  -n $NAMESPACE
```

**Checkpoint:**

```bash
kubectl get secrets -n $NAMESPACE
```

Should show:
- `datasurface-registry`
- `git-dags`

---

### Step 17: Initialize DAG Repository (BEFORE Helm Install)

**CRITICAL: This must happen BEFORE Helm install (Step 19).** The Airflow Helm chart uses git-sync init containers that will fail with `couldn't find remote ref main` if the DAG repository is empty or missing the `main` branch. This causes pods to enter `Init:Error` state.

```bash
cd /tmp
rm -rf $(basename $AIRFLOW_REPO)
git clone https://github.com/$AIRFLOW_REPO.git
cd $(basename $AIRFLOW_REPO)
git checkout -b main 2>/dev/null || git checkout main

mkdir -p dags
cp <path-to-model>/generated_output/Demo_PSP/*infrastructure_dag*.py dags/

git add dags/
git commit -m "Add infrastructure DAG"
git push -u origin main

cd <path-to-model>
```

Replace `<path-to-model>` with the actual path to your model repository.

**Checkpoint:** DAG file exists on GitHub under `dags/` on the `main` branch. Verify at `https://github.com/$AIRFLOW_REPO`.

---

### Step 18: Create SecretProviderClass for AWS Secrets Store CSI

```bash
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: airflow-secrets
  namespace: $NAMESPACE
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "airflow/connections/postgres_default"
        objectType: "secretsmanager"
        objectAlias: "airflow-db-connection"
EOF
```

**Checkpoint:**

```bash
kubectl get secretproviderclass -n $NAMESPACE
```

Should show `airflow-secrets`.

---

### Step 19: Install Airflow via Helm

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  -f helm/airflow-values-aws.yaml \
  -n $NAMESPACE \
  --timeout 10m
```

**Checkpoint:**

```bash
kubectl get pods -n $NAMESPACE
```

All Airflow pods should reach `Running` state:
- airflow-api-server
- airflow-scheduler
- airflow-dag-processor
- airflow-triggerer
- airflow-worker
- airflow-redis
- airflow-statsd

**Note:** If pods are stuck in `Init:Error`, the DAG repository was not initialized before this step (Step 17).

---

### Step 20: Create RBAC for Airflow Secret Access

**CRITICAL: The infrastructure DAG needs to read Kubernetes secrets. Without this, DAGs will fail to import.**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: airflow-secret-reader
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: airflow-secret-reader-binding
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: airflow-dag-processor
  namespace: $NAMESPACE
- kind: ServiceAccount
  name: airflow-worker
  namespace: $NAMESPACE
- kind: ServiceAccount
  name: airflow-scheduler
  namespace: $NAMESPACE
- kind: ServiceAccount
  name: airflow-triggerer
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: airflow-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

**Checkpoint:**

```bash
kubectl get role,rolebinding -n $NAMESPACE
```

Should show:
- `role.rbac.authorization.k8s.io/airflow-secret-reader`
- `rolebinding.rbac.authorization.k8s.io/airflow-secret-reader-binding`

---

### Step 21: Deploy Bootstrap and Run Jobs

**IMPORTANT:** Jobs must run sequentially. The ring1-init job creates database tables that model-merge depends on. Running them simultaneously causes a race condition where model-merge fails trying to access non-existent tables.

```bash
# Apply Kubernetes bootstrap (creates PVCs, ConfigMaps, NetworkPolicy, MCP server)
kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml

# Ensure Airflow service account has IRSA annotation (safety net - Helm should set this too)
kubectl annotate serviceaccount airflow-worker \
  -n $NAMESPACE \
  eks.amazonaws.com/role-arn=$AIRFLOW_ROLE_ARN \
  --overwrite

# Delete existing jobs if redeploying
kubectl delete job demo-psp-ring1-init demo-psp-model-merge-job -n $NAMESPACE --ignore-not-found

# Run ring1-init (creates tables) - must complete before model-merge
kubectl apply -f generated_output/Demo_PSP/*ring1_init_job*.yaml
kubectl wait --for=condition=complete --timeout=180s job/demo-psp-ring1-init -n $NAMESPACE

# Run model-merge (populates DAG configs) - depends on tables created by ring1-init
kubectl apply -f generated_output/Demo_PSP/*model_merge_job*.yaml
kubectl wait --for=condition=complete --timeout=180s job/demo-psp-model-merge-job -n $NAMESPACE
```

**Checkpoint:**

```bash
kubectl get jobs -n $NAMESPACE
```

Both jobs should show `Complete` with `1/1` completions:
- `demo-psp-ring1-init`: Complete
- `demo-psp-model-merge-job`: Complete

If jobs fail, check logs:

```bash
kubectl logs job/demo-psp-ring1-init -n $NAMESPACE
kubectl logs job/demo-psp-model-merge-job -n $NAMESPACE
```

**Key success indicators in model-merge logs:**
- `"Cleared existing factory DAG configurations"` - tables exist
- `"Populated factory DAG configurations"` with `config_count: 2` (or more)
- `"Populated CQRS DAG configurations"` with `config_count: 1` (or more)
- No ERROR level messages (WARNING about event publishing is normal)

---

## Phase 6: Verify & Access

### Step 22: Create Airflow Admin User

```bash
kubectl exec deployment/airflow-scheduler -n $NAMESPACE -- \
  airflow users create \
  --username admin \
  --firstname Admin \
  --lastname User \
  --role Admin \
  --email admin@example.com \
  --password admin123
```

**Checkpoint:** Command completes with "Admin user admin created".

---

### Step 23: Verify DAGs Registered

Wait 60-90 seconds for git-sync to pull the DAG files, then verify:

```bash
kubectl exec -n $NAMESPACE deployment/airflow-dag-processor -c dag-processor -- \
  airflow dags list 2>&1 | grep -v "DeprecationWarning\|RemovedInAirflow\|permissions.py"
```

Expected DAGs (5 total):

| DAG ID | Description |
|--------|-------------|
| `scd2_factory_dag` | Factory DAG for SCD2 pipelines |
| `Demo_PSP_K8sMergeDB_reconcile` | DataContainer reconciliation |
| `Demo_PSP_default_K8sMergeDB_cqrs` | CQRS DAG |
| `demo-psp_infrastructure` | Infrastructure management |
| `scd2_datatransformer_factory` | DataTransformer factory |

Check for import errors:

```bash
kubectl exec -n $NAMESPACE deployment/airflow-dag-processor -c dag-processor -- \
  airflow dags list-import-errors
```

**Checkpoint:** All 5 DAGs appear in the list with no import errors.

---

### Step 24: Port-Forward and Access UI

```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n $NAMESPACE
```

Open <http://localhost:8080> in your browser:
- Username: `admin`
- Password: `admin123`

**Checkpoint:** Airflow UI loads and all 5 DAGs are visible in the DAGs list.

---

## Troubleshooting

### PVCs Stuck Pending (EFS)

**Symptoms:** PersistentVolumeClaims stuck in `Pending` state.

```bash
kubectl describe pvc <pvc-name> -n $NAMESPACE
```

**Common causes and fixes:**

1. **EFS CSI driver not running:**
   ```bash
   kubectl get pods -n kube-system -l app=efs-csi-controller
   ```

2. **Service account missing IAM role annotation:**
   ```bash
   kubectl get sa efs-csi-controller-sa -n kube-system -o yaml | grep eks.amazonaws.com
   ```
   If missing, re-run the annotation from Step 5.

3. **OIDC trust policy mismatch (most common):**
   This should have been fixed in Step 3. Verify:
   ```bash
   aws iam get-role --role-name $EFS_ROLE_NAME \
     --query 'Role.AssumeRolePolicyDocument' --output json
   ```
   The OIDC issuer in the trust policy must match your cluster's actual OIDC provider.

4. **Restart the EFS CSI controller:**
   ```bash
   kubectl rollout restart deployment/efs-csi-controller -n kube-system
   kubectl rollout status deployment/efs-csi-controller -n kube-system
   ```

---

### Insufficient CPU

**Symptoms:** Pods stuck in `Pending` with "Insufficient cpu" events.

Default `m5.large` instances have 2 vCPU which may be insufficient for all Airflow components. Recommend `m5.xlarge` (4 vCPU).

**Temporary fix** - reduce resource requests:

```bash
kubectl patch deployment airflow-scheduler -n $NAMESPACE \
  --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "500m"}]'

kubectl patch deployment airflow-dag-processor -n $NAMESPACE \
  --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "500m"}]'
```

**Permanent fix:** Update the CloudFormation template or node group to use `m5.xlarge` instances.

---

### Secrets Manager Access Denied

**Symptoms:** Pods fail with "AccessDeniedException" when reading secrets from AWS Secrets Manager.

Verify IRSA annotation on the airflow-worker service account:

```bash
kubectl get sa airflow-worker -n $NAMESPACE -o yaml | grep eks.amazonaws.com
```

Test with a temporary pod:

```bash
kubectl run test --rm -i --restart=Never \
  --image=amazon/aws-cli \
  --serviceaccount=airflow-worker \
  -n $NAMESPACE \
  -- aws sts get-caller-identity
```

The output should show the Airflow secrets role ARN, not the node instance role.

---

### Init Container OOMKilled

**Symptoms:** Init containers killed with `OOMKilled` status.

Add resource limits to init containers in the Helm values:

```yaml
resources:
  requests:
    memory: 2Gi
    cpu: 500m
  limits:
    memory: 4Gi
    cpu: 1000m
```

---

### Aurora Connectivity From Pods

**Symptoms:** Jobs fail with "could not connect to server" or "connection refused" errors.

Test database connectivity from inside a pod:

```bash
kubectl run db-test --rm -i --restart=Never \
  --image=postgres:16 \
  --env="PGPASSWORD=$DATABASE_PASSWORD" \
  -n $NAMESPACE \
  -- psql -h $AURORA_ENDPOINT -U postgres -c "SELECT version();"
```

If this fails, check:
- Aurora security group allows inbound from EKS node security group on port 5432
- Aurora is in the same VPC or has VPC peering configured
- Aurora cluster is in `available` state

---

### Custom Image Missing AWS Dependencies

**Symptoms:** DAGs fail with `ModuleNotFoundError: No module named 'boto3'` or similar.

Verify the custom Airflow image has required packages:

```bash
docker run --rm datasurface/airflow:3.1.7 pip list | grep -E "(boto3|apache-airflow-providers-amazon)"
```

If missing, rebuild the image (Step 11) and update the Helm values to use the custom image.

---

### Git-Sync Init Containers Fail

**Symptoms:** Airflow pods stuck in `Init:Error` or `Init:CrashLoopBackOff`.

```bash
kubectl logs -n $NAMESPACE <pod-name> -c git-sync-init
```

**Common cause:** The DAG repository is empty or missing the `main` branch. The DAG repo MUST be initialized with at least one commit on the `main` branch BEFORE Helm install (Step 17).

**Fix:** Initialize the DAG repository, then restart the failed pods:

```bash
kubectl delete pods -n $NAMESPACE -l component=dag-processor
kubectl delete pods -n $NAMESPACE -l component=scheduler
```

---

### Namespace Stuck in Terminating

```bash
kubectl get namespace $NAMESPACE -o json | jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
```

---

### ImagePullBackOff

```bash
kubectl get secret datasurface-registry -n $NAMESPACE
kubectl get sa default -n $NAMESPACE -o yaml | grep imagePullSecrets
```

If the secret or imagePullSecrets binding is missing, re-run Step 16.

---

## Key Differences: Local vs AWS

| Aspect | Local (Docker Desktop) | AWS (EKS) |
|--------|----------------------|-----------|
| Database | Docker Compose PostgreSQL | Aurora RDS |
| Secrets | Kubernetes secrets | AWS Secrets Manager + CSI driver |
| Storage | standard/hostpath | EFS (efs-sc) |
| Infrastructure | None | CloudFormation (2 stacks) |
| Auth | None | IRSA (IAM Roles for Service Accounts) |
| Airflow image | apache/airflow:3.1.7 | datasurface/airflow:3.1.7 (custom) |
| Git cache | ReadWriteOnce | ReadWriteMany |
| Network | localhost | VPC + security groups |
| Node type | Docker Desktop | EC2 (m5.xlarge recommended) |
| Cost | Free | ~$200-400/month (EKS + EC2 + Aurora + EFS) |
