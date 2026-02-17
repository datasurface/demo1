# DataSurface AWS EKS Teardown Walkthrough

This skill guides you through completely tearing down a DataSurface Yellow environment on AWS EKS. It removes all Kubernetes resources, CloudFormation stacks, Secrets Manager secrets, and any lingering AWS resources. Follow each step in order.

## IMPORTANT: Execution Rules

1. **Execute steps sequentially** - Dependencies exist between teardown steps
2. **Verify each step** - Confirm completion before proceeding
3. **Ask for missing information** - If environment variables are not set, ask the user
4. **Report failures immediately** - Teardown failures can leave orphaned resources that cost money

## Required Environment Variables

Ask the user for these if not already set:

```bash
STACK_NAME              # CloudFormation stack name used during setup (e.g., "ds-eks-v1")
AWS_REGION              # AWS region (default: us-east-1)
NAMESPACE               # Kubernetes namespace (e.g., "demo1-aws")
```

Verify AWS CLI is configured:

```bash
aws sts get-caller-identity
```

---

## Step 1: Uninstall Helm Releases

Remove Airflow and any other Helm releases in the namespace first, before deleting the namespace.

```bash
helm uninstall airflow -n $NAMESPACE 2>/dev/null || echo "Airflow Helm release not found"
helm uninstall csi-secrets-store --namespace kube-system 2>/dev/null || echo "Secrets Store CSI not found"
```

**Checkpoint:** `helm list -n $NAMESPACE` returns no releases.

---

## Step 2: Delete Kubernetes Namespace

```bash
kubectl delete namespace $NAMESPACE --timeout=60s
```

**If the namespace gets stuck in `Terminating` state (common):**

```bash
# Check what's blocking
kubectl get namespace $NAMESPACE -o json | jq '.status.conditions'

# Force-remove finalizers from stuck PVCs
for pvc in $(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch pvc $pvc -n $NAMESPACE -p '{"metadata":{"finalizers":null}}' --type=merge
done

# Force-delete remaining pods
for pod in $(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl delete pod $pod -n $NAMESPACE --force --grace-period=0
done

# Force-finalize the namespace
kubectl get namespace $NAMESPACE -o json > /tmp/ns-finalize.json
jq '.spec.finalizers = []' /tmp/ns-finalize.json > /tmp/ns-finalize-clean.json
kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f /tmp/ns-finalize-clean.json
rm -f /tmp/ns-finalize.json /tmp/ns-finalize-clean.json
```

**Checkpoint:** `kubectl get namespace $NAMESPACE` returns "not found".

---

## Step 3: Remove EFS CSI Driver Addon

```bash
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' \
  --output text --region $AWS_REGION)

aws eks delete-addon --cluster-name $CLUSTER_NAME --addon-name aws-efs-csi-driver --region $AWS_REGION
```

**Checkpoint:** Addon deletion initiated (or already removed).

---

## Step 4: Delete AWS Secrets Manager Secrets

Delete all DataSurface-related secrets. There are typically 5 secrets:

```bash
# Secrets created during setup Step 13
aws secretsmanager delete-secret --secret-id "airflow/connections/postgres_default" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "datasurface/merge/credentials" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "datasurface/git/credentials" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true

# Secrets created by DataSurface bootstrap/runtime (namespace-specific)
aws secretsmanager delete-secret --secret-id "datasurface/${NAMESPACE}/Demo/postgres-demo-merge" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "datasurface/${NAMESPACE}/Demo/git" \
  --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
```

**Also check for any other DataSurface/Airflow secrets:**

```bash
aws secretsmanager list-secrets \
  --query 'SecretList[?contains(Name, `datasurface`) || contains(Name, `airflow`)].Name' \
  --output table --region $AWS_REGION
```

Delete any remaining secrets found. The output should be empty after cleanup.

**Checkpoint:** No DataSurface or Airflow secrets remain.

---

## Step 5: Delete IAM Roles Stack (CloudFormation Stage 2)

Delete the IAM roles stack first since it was created second:

```bash
aws cloudformation delete-stack --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION
```

**Checkpoint:** `aws cloudformation describe-stacks --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION` returns "does not exist".

---

## Step 6: Disable RDS Deletion Protection

**CRITICAL:** The CloudFormation template enables deletion protection on the RDS instance. You must disable it before the main stack can be deleted, otherwise CloudFormation will fail with `DELETE_FAILED`.

```bash
# Find the RDS instance
DB_INSTANCE=$(aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${STACK_NAME}')].DBInstanceIdentifier" \
  --output text --region $AWS_REGION)

echo "Disabling deletion protection on: $DB_INSTANCE"

aws rds modify-db-instance \
  --db-instance-identifier $DB_INSTANCE \
  --no-deletion-protection \
  --apply-immediately \
  --region $AWS_REGION \
  --query 'DBInstance.DeletionProtection' --output text
```

**Wait for the modification to take effect** (usually 1-2 minutes):

```bash
aws rds wait db-instance-available --db-instance-identifier $DB_INSTANCE --region $AWS_REGION
```

**Checkpoint:** Output shows `False`.

---

## Step 7: Delete Main Stack (CloudFormation Stage 1)

This deletes the VPC, EKS cluster, node group, Aurora RDS, EFS, NAT gateways, and all networking resources. Takes 15-20 minutes.

```bash
aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION
echo "Waiting for stack deletion (~15-20 minutes)..."
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $AWS_REGION
```

### If the stack enters DELETE_FAILED state

This is common due to resource dependencies. Check what failed:

```bash
aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $AWS_REGION \
  --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

**Common failures and fixes:**

#### RDS deletion protection still enabled

```text
Cannot delete protected DB Instance, please disable deletion protection
```

Go back to Step 6 and ensure the modification completed.

#### Node group security group dependency

```text
DependencyViolation - resource has a dependent object, ResourceIds=[sg-xxxxx]
```

The EKS-managed security group has cross-references from other security groups:

```bash
# Find what references the blocking SG
SG_ID="sg-xxxxx"  # From the error message

# Find SGs that reference it
aws ec2 describe-security-groups --region $AWS_REGION \
  --filters "Name=ip-permission.group-id,Values=$SG_ID" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output table

# Remove the cross-reference rule (usually from the RDS SG)
REFERENCING_SG="sg-yyyyy"  # From the output above
aws ec2 revoke-security-group-ingress --group-id $REFERENCING_SG \
  --source-group $SG_ID --protocol tcp --port 5432 --region $AWS_REGION

# Delete the blocking SG
aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION
```

#### EKS cluster security group lingering after cluster deletion

If the VPC won't delete because an EKS cluster security group remains:

```bash
# Find the VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
  --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)

# List non-default security groups
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output table --region $AWS_REGION

# Delete any non-default security groups (the 'default' SG is auto-deleted with the VPC)
aws ec2 delete-security-group --group-id sg-xxxxx --region $AWS_REGION
```

**After fixing the blocker, retry the stack deletion:**

```bash
aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $AWS_REGION
```

**Checkpoint:**

```bash
aws cloudformation list-stacks --stack-status-filter DELETE_COMPLETE \
  --query 'StackSummaries[?StackName==`'$STACK_NAME'`].[StackName,StackStatus]' \
  --output table --region $AWS_REGION
```

Should show `DELETE_COMPLETE`.

---

## Step 8: Final Verification

Confirm all resources are cleaned up:

```bash
# Both stacks gone
aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION 2>&1 | grep -q "does not exist" && echo "Main stack: GONE" || echo "Main stack: STILL EXISTS"
aws cloudformation describe-stacks --stack-name "${STACK_NAME}-iam-roles" --region $AWS_REGION 2>&1 | grep -q "does not exist" && echo "IAM stack: GONE" || echo "IAM stack: STILL EXISTS"

# No DataSurface secrets
aws secretsmanager list-secrets \
  --query 'SecretList[?contains(Name, `datasurface`) || contains(Name, `airflow`)].Name' \
  --output text --region $AWS_REGION | wc -w | xargs -I{} sh -c '[ {} -eq 0 ] && echo "Secrets: CLEAN" || echo "Secrets: {} REMAINING"'

# No RDS instances from this stack
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${STACK_NAME}')].DBInstanceIdentifier" \
  --output text --region $AWS_REGION | wc -w | xargs -I{} sh -c '[ {} -eq 0 ] && echo "RDS: CLEAN" || echo "RDS: {} REMAINING"'

# No VPCs from this stack
aws ec2 describe-vpcs \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
  --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION | grep -q "None" && echo "VPC: CLEAN" || echo "VPC: STILL EXISTS"

# Namespace gone
kubectl get namespace $NAMESPACE 2>&1 | grep -q "not found" && echo "Namespace: GONE" || echo "Namespace: STILL EXISTS"
```

**All checks should show GONE/CLEAN.**

---

## Troubleshooting

### Stack stuck in DELETE_IN_PROGRESS for over 30 minutes

Check for resources that CloudFormation can't delete:

```bash
aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $AWS_REGION \
  --query 'StackEvents[?ResourceStatus==`DELETE_IN_PROGRESS`].[LogicalResourceId,ResourceType]' \
  --output table
```

Common blockers:
- **NAT Gateways**: Take 5-10 minutes to release their Elastic IPs
- **VPC**: Waits for all ENIs, security groups, and subnets to clear
- **Node Group**: Waits for EC2 instances to terminate and security groups to clear

### Orphaned Elastic IPs

If you see charges for Elastic IPs after teardown:

```bash
aws ec2 describe-addresses --region $AWS_REGION \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output table

# Release unassociated EIPs
aws ec2 release-address --allocation-id eipalloc-xxxxx --region $AWS_REGION
```

### Cost verification

After teardown, check the AWS Cost Explorer or Billing dashboard to confirm no ongoing charges from:
- EKS cluster ($0.10/hour)
- EC2 instances (node group)
- Aurora RDS
- NAT Gateways ($0.045/hour each, usually 2)
- Elastic IPs (if unattached)
- EFS storage
- S3 storage
