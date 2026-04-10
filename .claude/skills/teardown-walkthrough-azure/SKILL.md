---
name: DataSurface Azure AKS Teardown Walkthrough
description: Interactive walkthrough for completely tearing down a DataSurface Yellow environment on Azure AKS. Removes all Kubernetes resources, Azure infrastructure, Key Vault secrets, and GitHub releases. Use this skill to clean up an Azure installation.
---

# DataSurface Azure AKS Teardown Walkthrough

This skill guides you through completely tearing down a DataSurface Yellow environment on Azure AKS. It removes all Kubernetes resources, Helm releases, Azure infrastructure, Key Vault secrets, and GitHub repo artifacts. Follow each step in order — dependencies exist between teardown steps.

## IMPORTANT: Execution Rules

1. **Execute steps sequentially** - Dependencies exist between teardown steps
2. **Verify each step** - Confirm completion before proceeding
3. **Ask for missing information** - If environment variables are not set, ask the user
4. **Report failures immediately** - Teardown failures can leave orphaned resources that cost money

## Required Environment Variables

Ask the user for these if not already set:

```bash
RESOURCE_GROUP           # Azure resource group name (e.g., ds-demo-rg)
CLUSTER_NAME             # AKS cluster name (e.g., ds-demo-aks)
NAMESPACE                # Kubernetes namespace (e.g., demo1-azure)
KEY_VAULT_NAME           # Key Vault name (e.g., dsdemokv1234)
MODEL_REPO               # GitHub model repo (e.g., yourorg/demo1)
AIRFLOW_REPO             # GitHub DAG repo (e.g., yourorg/demo1_airflow)
```

Verify Azure CLI is configured:

```bash
az account show --query "{subscriptionId:id, name:name}" -o table
```

---

## Step 1: Uninstall Helm Releases

Remove Airflow and any CSI driver Helm releases before deleting the namespace. This ensures PVCs and services are cleaned up properly.

```bash
# Get AKS credentials if not already configured
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing 2>/dev/null || true

helm uninstall airflow -n $NAMESPACE --no-hooks 2>/dev/null || echo "Airflow Helm release not found"
helm uninstall csi-azure -n kube-system 2>/dev/null || echo "CSI Azure provider not found"
helm uninstall csi-secrets-store -n kube-system 2>/dev/null || echo "CSI Secrets Store not found"
```

**Note:** Use `--no-hooks` for Airflow because hook jobs (like `create-user`) can hang during teardown if the metadata DB is unreachable.

**Checkpoint:** `helm list -n $NAMESPACE -a` and `helm list -n kube-system -a` show no DataSurface-related releases.

---

## Step 2: Delete Kubernetes Namespace

```bash
kubectl delete namespace $NAMESPACE --timeout=120s
```

**If the namespace gets stuck in `Terminating` state (common with Azure Files NFS PVCs):**

Azure Files NFS PVCs can take a long time to release because the Azure Files share must be deleted first. The PVC finalizer blocks namespace deletion.

```bash
# Check what's blocking
kubectl get namespace $NAMESPACE -o json | jq '.status.conditions'

# Check for stuck PVCs
kubectl get pvc -n $NAMESPACE

# Force-remove finalizers from stuck PVCs
for pvc in $(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "Removing finalizer from PVC: $pvc"
  kubectl patch pvc $pvc -n $NAMESPACE -p '{"metadata":{"finalizers":null}}' --type=merge
done

# Force-delete remaining pods (job pods from failed runs can accumulate)
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

## Step 3: Clean Up GitHub Releases and Tags

Remove all tags and releases from the model and DAG repositories to prevent stale artifacts from interfering with future deployments.

```bash
# Delete all releases and tags from the model repo
for tag in $(gh release list --repo $MODEL_REPO --json tagName -q '.[].tagName' 2>/dev/null); do
  echo "Deleting release: $tag from $MODEL_REPO"
  gh release delete "$tag" --repo $MODEL_REPO --yes 2>/dev/null || true
  git push https://github.com/$MODEL_REPO.git ":refs/tags/$tag" 2>/dev/null || true
done

# Delete all releases and tags from the DAG repo
for tag in $(gh release list --repo $AIRFLOW_REPO --json tagName -q '.[].tagName' 2>/dev/null); do
  echo "Deleting release: $tag from $AIRFLOW_REPO"
  gh release delete "$tag" --repo $AIRFLOW_REPO --yes 2>/dev/null || true
  git push https://github.com/$AIRFLOW_REPO.git ":refs/tags/$tag" 2>/dev/null || true
done
```

**Checkpoint:**
- `gh release list --repo $MODEL_REPO` returns empty
- `gh release list --repo $AIRFLOW_REPO` returns empty

---

## Step 4: Delete Azure Resource Group

This deletes ALL Azure resources in the group: AKS cluster, PostgreSQL Flexible Server, Azure SQL Server and databases, Key Vault (soft-deleted), VNet, managed identity, private endpoints, and all associated resources.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
echo "Resource group deletion started (takes 5-10 minutes)..."
```

Wait for the resource group to be fully deleted:

```bash
while az group exists --name $RESOURCE_GROUP 2>/dev/null | grep -q true; do
  echo "Waiting for resource group deletion..."
  sleep 30
done
echo "Resource group deleted"
```

**If deletion hangs for more than 15 minutes**, check for stuck resources:

```bash
az resource list --resource-group $RESOURCE_GROUP -o table
```

Common blockers:
- **AKS cluster**: Can take 10+ minutes if node pools are large
- **Private endpoints**: May block VNet deletion if not fully cleaned up
- **Azure Files NFS shares**: Created dynamically by PVC provisioning, may have delete locks

If a specific resource is blocking, delete it manually:

```bash
# Force-delete a stuck resource
az resource delete --ids <resource-id> --no-wait
```

**Checkpoint:** `az group exists --name $RESOURCE_GROUP` returns `false`.

---

## Step 5: Purge Soft-Deleted Key Vault

Azure Key Vault has soft-delete enabled by default (and it cannot be disabled). When the resource group is deleted, the Key Vault enters a soft-deleted state for 90 days. You **must** purge it if you want to reuse the same vault name.

```bash
# Check if the vault is in soft-deleted state
az keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME']" -o table

# Purge it
az keyvault purge --name $KEY_VAULT_NAME
echo "Key Vault purged"
```

**Note:** If you don't purge and later try to create a vault with the same name, you'll get a conflict error. The soft-deleted vault retains all secrets for 90 days.

**Checkpoint:** `az keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME']"` returns empty.

---

## Step 6: Clean Up Local kubectl Context

The AKS cluster credentials are still in your local kubeconfig after deletion. Remove them to avoid confusing errors.

```bash
kubectl config delete-context $CLUSTER_NAME 2>/dev/null || true
kubectl config delete-cluster $CLUSTER_NAME 2>/dev/null || true
kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME}" 2>/dev/null || true
echo "kubectl context cleaned up"
```

**Checkpoint:** `kubectl config get-contexts` does not show the deleted cluster.

---

## Step 7: Final Verification

Confirm all resources are cleaned up:

```bash
# Resource group gone
az group exists --name $RESOURCE_GROUP 2>/dev/null | grep -q false && \
  echo "Resource group: GONE" || echo "Resource group: STILL EXISTS"

# Key Vault purged
az keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME'].name" -o tsv 2>/dev/null | \
  grep -q "$KEY_VAULT_NAME" && echo "Key Vault: SOFT-DELETED (needs purge)" || echo "Key Vault: CLEAN"

# No lingering AKS clusters
az aks list --query "[?name=='$CLUSTER_NAME'].name" -o tsv 2>/dev/null | \
  grep -q "$CLUSTER_NAME" && echo "AKS: STILL EXISTS" || echo "AKS: CLEAN"

# Namespace gone (will fail gracefully if kubectl context was cleaned)
kubectl get namespace $NAMESPACE 2>&1 | grep -q "not found\|refused\|no configuration" && \
  echo "Namespace: GONE" || echo "Namespace: STILL EXISTS"

# GitHub releases cleaned
gh release list --repo $MODEL_REPO 2>/dev/null | grep -q . && \
  echo "Model releases: STILL EXIST" || echo "Model releases: CLEAN"
gh release list --repo $AIRFLOW_REPO 2>/dev/null | grep -q . && \
  echo "DAG releases: STILL EXIST" || echo "DAG releases: CLEAN"
```

**All checks should show GONE/CLEAN.**

---

## Cost Verification

After teardown, verify no ongoing charges from:

| Resource | Approximate Cost | How to Check |
|----------|-----------------|--------------|
| AKS cluster | $0.10/hour (control plane) | `az aks list -o table` |
| VM nodes | ~$0.10/hour each (D2s_v3) | `az vm list -o table` |
| PostgreSQL Flex | ~$0.03/hour (B1ms) | `az postgres flexible-server list -o table` |
| Azure SQL | ~$0.04/hour (S1) | `az sql server list -o table` |
| Azure Files NFS | ~$0.10/GB/month | Deleted with resource group |
| Key Vault | Negligible | Soft-deleted for 90 days (no charge) |
| Public IPs | ~$0.005/hour if unattached | `az network public-ip list -o table` |

**Tip:** Check the Azure Cost Analysis portal (`portal.azure.com` > Cost Management) filtered by the resource group name to verify no lingering charges.
