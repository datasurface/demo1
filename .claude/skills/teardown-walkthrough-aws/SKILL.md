---
name: teardown-walkthrough-aws
description: Safely tear down a demo1 AWS EKS environment, including Airflow, the namespace, CloudFormation stacks, and cost-bearing leftovers. Use when removing an AWS demo1 deployment; clean optional ESO secrets only when configured.
---

# AWS EKS teardown

This procedure is destructive. Confirm the exact account, region, stack, cluster, and namespace
before deleting anything. The `demo1` starter uses namespace-local Kubernetes Secrets by default;
it does not require AWS Secrets Manager cleanup.

## Preflight and authorization

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=<region>
STACK_NAME=<main-stack>
NAMESPACE=<namespace>

aws sts get-caller-identity
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].{name:StackName,status:StackStatus}' --output table
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" --region "$AWS_REGION" \
  --query 'Stacks[0].{name:StackName,status:StackStatus}' --output table
kubectl config current-context
kubectl get namespace "$NAMESPACE"
helm list -n "$NAMESPACE"
```

Stop unless all targets are the intended environment and full teardown is authorized.

## 1. Remove in-cluster workloads

```bash
helm uninstall airflow -n "$NAMESPACE" --ignore-not-found
kubectl delete namespace "$NAMESPACE" --wait=true
```

If the namespace remains `Terminating`, inspect remaining resources and finalizers first:

```bash
kubectl get all,pvc -n "$NAMESPACE"
kubectl get namespace "$NAMESPACE" -o yaml
```

Force-removing finalizers can orphan cloud volumes. Use it only after the controllers have had a
chance to clean up and the remaining targets are understood.

Namespace deletion removes the starter's `git`, merge, DAG-sync, and registry Secrets.

## 2. Remove the EFS add-on

Resolve the cluster name before deleting:

```bash
CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' --output text)

aws eks delete-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION" 2>/dev/null || true
```

Wait for the add-on to disappear before deleting its IAM role stack.

## 3. Optional ESO cleanup

Skip this section when `rte_aws.py` used `externalSecretProvider=None`.

If the customer enabled ESO, identify only this environment's remote keys:

```bash
PREFIX="datasurface/${NAMESPACE}/demo/"
aws secretsmanager list-secrets --region "$AWS_REGION" \
  --query "SecretList[?starts_with(Name, \`${PREFIX}\`)].Name" --output text
```

Delete only confirmed keys under that exact prefix. Do not delete shared secrets, unrelated
namespaces, or every `datasurface/*` secret. Removing a secret with
`--force-delete-without-recovery` is irreversible; use a recovery window unless immediate purge was
explicitly requested.

If External Secrets Operator is shared by other namespaces, leave the operator installed. Remove a
dedicated operator release only after checking `helm list -A` and remaining `ExternalSecret`
resources.

## 4. Delete CloudFormation stacks

Delete the IAM roles stack first:

```bash
aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}-iam-roles" --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}-iam-roles" --region "$AWS_REGION"
```

Before deleting the main stack, resolve its exact RDS PostgreSQL physical ID:

```bash
DB_INSTANCE_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "$STACK_NAME" \
  --logical-resource-id PostgreSQLDatabase \
  --region "$AWS_REGION" \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].{id:DBInstanceIdentifier,protected:DeletionProtection}' \
  --output table
```

If and only if this exact instance reports protection enabled, disable it and wait:

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --no-deletion-protection \
  --apply-immediately \
  --region "$AWS_REGION"
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Then delete the main stack:

```bash
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" --region "$AWS_REGION"
```

If deletion fails, inspect stack events and remove only the named dependency. Do not bulk-delete
security groups or network interfaces by pattern.

## 5. Verify cost-bearing resources are gone

```bash
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" 2>&1 || true
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-iam-roles" --region "$AWS_REGION" 2>&1 || true

aws eks list-clusters --region "$AWS_REGION"
aws rds describe-db-instances --region "$AWS_REGION" \
  --query "DBInstances[?contains(DBInstanceIdentifier, \`${STACK_NAME}\`)].DBInstanceIdentifier"
aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Name==\`${STACK_NAME}-efs\`].FileSystemId"
aws ec2 describe-nat-gateways --region "$AWS_REGION" \
  --filter Name=state,Values=available,pending,deleting
aws ec2 describe-addresses --region "$AWS_REGION" \
  --query 'Addresses[?AssociationId==null].AllocationId'
```

Also check CloudFormation `DELETE_FAILED` events, load balancers, orphaned EBS volumes, and
unassociated Elastic IPs associated with this stack's tags.

Model and DAG repositories, tags, and releases are not infrastructure teardown targets. Preserve
them unless the user separately requests repository cleanup.
