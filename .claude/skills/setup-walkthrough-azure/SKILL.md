---
name: DataSurface Azure AKS Setup Walkthrough
description: Interactive walkthrough for setting up a DataSurface Yellow environment on Azure AKS with Azure Database for PostgreSQL, Azure SQL Database, Helm Airflow 3.x, Azure Key Vault, and Workload Identity. Use this skill to guide users through the complete Azure installation process step-by-step.
---

# DataSurface Azure AKS Setup Walkthrough

This skill guides you through deploying a DataSurface Yellow environment on Azure AKS (Azure Kubernetes Service). It uses `az` CLI commands for infrastructure, Azure Database for PostgreSQL Flexible Server for the Airflow metadata database, Azure SQL Database for the merge engine, Azure Files NFS for shared storage, Azure Key Vault for credentials, and Workload Identity for pod-level Azure access. Follow each step in order and verify completion before proceeding.

## IMPORTANT: Execution Rules

1. **Execute steps sequentially** - Do not skip ahead or combine steps
2. **Verify each step** - Confirm success before proceeding to the next step
3. **Ask for missing information** - If environment variables or credentials are not provided, ask the user
4. **Report failures immediately** - If any step fails, stop and troubleshoot before continuing

## Pre-Flight Checklist

Before starting, verify the user has:

- [ ] Docker Desktop running (for image builds and bootstrap generation)
- [ ] Azure CLI installed and logged in (`az account show` succeeds)
- [ ] `kubectl` CLI installed
- [ ] `helm` CLI installed
- [ ] GitHub Personal Access Token (needs repo access)
- [ ] GitLab credentials for DataSurface images

Ask the user for these environment variables if not already set:

```bash
AZURE_SUBSCRIPTION_ID    # Azure subscription ID
AZURE_REGION             # Azure region (recommend westus2 - see Region Selection note below)
RESOURCE_GROUP           # Resource group name (e.g., ds-demo-rg)
CLUSTER_NAME             # AKS cluster name (e.g., ds-demo-aks)
VNET_NAME                # VNet name (e.g., ds-vnet)
PG_ADMIN_USER            # PostgreSQL admin username (NOT 'admin' - reserved by Azure)
PG_ADMIN_PASSWORD        # PostgreSQL admin password (see password rules below)
SQL_ADMIN_USER           # Azure SQL admin username
SQL_ADMIN_PASSWORD       # Azure SQL admin password (see password rules below)
GITHUB_USERNAME          # GitHub username
GITHUB_TOKEN             # GitHub Personal Access Token (repo access)
GITLAB_CUSTOMER_USER     # GitLab deploy token username
GITLAB_CUSTOMER_TOKEN    # GitLab deploy token
DATASURFACE_VERSION      # DataSurface version (default: 1.1.0)
MODEL_REPO               # Target model repo (e.g., yourorg/demo1)
AIRFLOW_REPO             # Target DAG repo (e.g., yourorg/demo1_airflow)
NAMESPACE                # K8s namespace (default: demo1-azure)
KEY_VAULT_NAME           # Globally unique Key Vault name (3-24 chars, alphanumeric + hyphens, no consecutive hyphens, e.g., dsdemokv<random>)
MANAGED_IDENTITY_NAME    # Managed identity name (e.g., ds-airflow-identity)
```

**CRITICAL: Password Character Restrictions.** Database passwords must **NOT** contain `!`, `\`, `$`, backticks, or other shell metacharacters. The macOS default shell (zsh) escapes `!` even inside single quotes when used with `kubectl create secret --from-literal`, silently corrupting passwords (e.g., `DsDemo2024pg!` becomes `DsDemo2024pg\!` in the stored secret). This causes persistent "password authentication failed" errors that are extremely difficult to diagnose because the password *looks* correct in the `az` CLI but doesn't match what's stored in the K8s secret. **Use only alphanumeric characters and simple symbols like `-` or `_` in all passwords.** Minimum 8 characters with uppercase + lowercase + number to satisfy Azure complexity requirements.

Verify Azure CLI is configured:

```bash
az account show --query "{subscriptionId:id, name:name, state:state}" -o table
```

Set the active subscription:

```bash
az account set --subscription $AZURE_SUBSCRIPTION_ID
```

**IMPORTANT: Region Selection.** Azure periodically restricts new database provisioning in popular regions (especially eastus). Both PostgreSQL Flexible Server and Azure SQL Database can be blocked simultaneously. **Recommend `westus2` as the default region** -- it has broad service availability and fewer provisioning restrictions. If your chosen region fails with `RegionDoesNotAllowProvisioning` or "location is restricted for provisioning", you must tear down and recreate everything in a different region. All resources (VNet, AKS, PostgreSQL, SQL) must be in the same region for VNet integration to work. Cross-region VNet rules and VNet-integrated PostgreSQL are not supported.

**IMPORTANT: Pre-register Azure resource providers.** New subscriptions often lack provider registrations, which causes `MissingSubscriptionRegistration` errors during resource creation. Register all needed providers upfront (takes 1-2 minutes):

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.DBforPostgreSQL
az provider register --namespace Microsoft.Sql
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.ManagedIdentity
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Network

# Wait for the critical one (AKS)
while [ "$(az provider show -n Microsoft.ContainerService --query registrationState -o tsv)" != "Registered" ]; do sleep 10; done
echo "ContainerService registered"
```

**IMPORTANT: Check vCPU quota.** New Azure subscriptions typically have a 10 vCPU regional quota. Our default config (3 x Standard_D2s_v3 = 6 cores) fits within this. If you need larger VMs, check your quota first:

```bash
az vm list-usage --location $AZURE_REGION -o table | grep "Total Regional"
```

If your quota is less than the cores you need, request an increase via the Azure Portal before proceeding.

---

## Phase 1: Azure Infrastructure

### Step 0: Clean Up Previous Installation (If Exists)

**Always run this step, even for "fresh" installations.** Previous resource groups, namespaces, or Key Vault soft-deleted secrets can cause conflicts.

#### 0a. Delete existing Kubernetes namespace (if it exists)

```bash
kubectl get namespace $NAMESPACE 2>/dev/null && \
  kubectl delete namespace $NAMESPACE

# If namespace is stuck in Terminating state (wait 30 seconds, then check):
kubectl get namespace $NAMESPACE -o json 2>/dev/null | jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
```

#### 0b. Delete existing resource group (if it exists)

**WARNING:** This deletes ALL resources in the group (AKS, databases, Key Vault, VNet). Only do this if you want a completely fresh start.

```bash
az group exists --name $RESOURCE_GROUP && \
  az group delete --name $RESOURCE_GROUP --yes --no-wait
```

Wait for the resource group to be fully deleted before proceeding (can take 5-10 minutes):

```bash
while az group exists --name $RESOURCE_GROUP 2>/dev/null | grep -q true; do
  echo "Waiting for resource group deletion..."
  sleep 30
done
echo "Resource group deleted"
```

#### 0c. Purge soft-deleted Key Vault (if it exists)

Azure Key Vault has soft-delete enabled by default. If you previously deleted a Key Vault with the same name, you must purge it before recreating:

```bash
az keyvault purge --name $KEY_VAULT_NAME 2>/dev/null || true
```

#### 0d. Clean up Azure Key Vault secrets (if reusing Key Vault)

If you are reusing an existing Key Vault rather than deleting the resource group:

```bash
az keyvault secret delete --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials" 2>/dev/null || true
az keyvault secret delete --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--git--credentials" 2>/dev/null || true

# Purge deleted secrets (required before re-creating with same name)
az keyvault secret purge --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials" 2>/dev/null || true
az keyvault secret purge --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--git--credentials" 2>/dev/null || true
```

**Checkpoint:**
- `az group exists --name $RESOURCE_GROUP` returns `false`
- `kubectl get namespace $NAMESPACE` returns "not found"
- `az keyvault show --name $KEY_VAULT_NAME` returns "not found" or has been purged
- No lingering soft-deleted secrets in Key Vault

---

### Step 1: Create Resource Group

```bash
az group create --name $RESOURCE_GROUP --location $AZURE_REGION
```

**Checkpoint:**

```bash
az group show --name $RESOURCE_GROUP --query "{name:name, location:location, state:properties.provisioningState}" -o table
```

Provisioning state must be `Succeeded`.

---

### Step 2: Create VNet and Subnets

Create a VNet with three subnets: one for AKS, one delegated to PostgreSQL Flexible Server, and one for Azure SQL private endpoints.

```bash
# Create VNet
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefix 10.0.0.0/16 \
  --location $AZURE_REGION

# AKS subnet (large - AKS needs IPs for nodes + pods)
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aks-subnet \
  --address-prefix 10.0.0.0/20

# PostgreSQL delegated subnet (required for VNet-integrated Flex Server)
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name pg-subnet \
  --address-prefix 10.0.16.0/24 \
  --delegations Microsoft.DBforPostgreSQL/flexibleServers

# Azure SQL private endpoint subnet
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name sql-subnet \
  --address-prefix 10.0.17.0/24
```

**Checkpoint:**

```bash
az network vnet subnet list --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME -o table
```

Should show three subnets: `aks-subnet`, `pg-subnet`, `sql-subnet`.

---

### Step 3: Create AKS Cluster

```bash
AKS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aks-subnet \
  --query id -o tsv)

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --node-count 3 \
  --node-vm-size Standard_D2s_v3 \
  --vnet-subnet-id $AKS_SUBNET_ID \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys \
  --location $AZURE_REGION \
  --service-cidr 172.16.0.0/16 \
  --dns-service-ip 172.16.0.10
```

**Note:** We use `Standard_D2s_v3` (2 vCPU, 8 GB RAM) by default because most new Azure subscriptions have a 10 vCPU regional quota. 3 x D2s_v3 = 6 cores fits comfortably. Use `Standard_D4s_v3` (4 vCPU) if you have quota for 12+ cores.

**Note:** The `--service-cidr 172.16.0.0/16` and `--dns-service-ip 172.16.0.10` flags are required because the default AKS service CIDR (10.0.0.0/16) overlaps with our VNet address space (10.0.0.0/16). Using 172.16.0.0/16 avoids the conflict.

This takes approximately 5-10 minutes.

**Checkpoint:**

```bash
az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
  --query "{name:name, state:provisioningState, k8sVersion:kubernetesVersion, nodeCount:agentPoolProfiles[0].count}" -o table
```

Provisioning state must be `Succeeded`. Verify OIDC issuer is enabled:

```bash
az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
  --query "oidcIssuerProfile.enabled" -o tsv
```

Must return `true`.

---

### Step 4: Create Azure Database for PostgreSQL Flexible Server

This PostgreSQL instance is used **only for the Airflow metadata database**. The merge engine uses Azure SQL Database (Step 5).

**Note:** If this fails with "location is restricted for provisioning of flexible servers", your chosen region is blocking new PostgreSQL Flex Server creation. You must tear down ALL resources and start over in a different region (e.g., westus2). PostgreSQL Flex Server with VNet integration requires the server and VNet to be in the same region -- there is no cross-region workaround.

```bash
az postgres flexible-server create \
  --resource-group $RESOURCE_GROUP \
  --name ${RESOURCE_GROUP}-pgflex \
  --location $AZURE_REGION \
  --admin-user $PG_ADMIN_USER \
  --admin-password "$PG_ADMIN_PASSWORD" \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --version 16 \
  --vnet $VNET_NAME \
  --subnet pg-subnet \
  --yes
```

This takes approximately 5-10 minutes. The `--vnet` and `--subnet` flags create the server with VNet integration, so it is only accessible from within the VNet (including AKS pods).

Get the PostgreSQL FQDN:

```bash
PG_FQDN=$(az postgres flexible-server show \
  --resource-group $RESOURCE_GROUP \
  --name ${RESOURCE_GROUP}-pgflex \
  --query fullyQualifiedDomainName -o tsv)
echo "PostgreSQL FQDN: $PG_FQDN"
```

**IMPORTANT: Create the Airflow database.** The Flexible Server is created with a default `postgres` database, but Airflow needs its own database. We will create it after configuring kubeconfig (Step 7), since the PostgreSQL server is only accessible from within the VNet.

**Checkpoint:**

```bash
az postgres flexible-server show \
  --resource-group $RESOURCE_GROUP \
  --name ${RESOURCE_GROUP}-pgflex \
  --query "{name:name, state:state, fqdn:fullyQualifiedDomainName, version:version}" -o table
```

State must be `Ready`.

---

### Step 5: Create Azure SQL Database

This Azure SQL Database is used as the **merge engine** (SQL Server). DataSurface's merge jobs connect here to perform SCD2 operations.

**Note:** Some Azure regions periodically stop accepting new SQL Database server provisioning. If eastus fails with `RegionDoesNotAllowProvisioning`, try eastus2 or another nearby region. When using a different region than the VNet, you cannot use VNet rules for firewall -- instead use the "Allow Azure services" firewall rule (`0.0.0.0` to `0.0.0.0`) or create a cross-region private endpoint.

```bash
SQL_SERVER_NAME="${RESOURCE_GROUP}-sqlserver"

# Create the logical SQL server
az sql server create \
  --resource-group $RESOURCE_GROUP \
  --name $SQL_SERVER_NAME \
  --location $AZURE_REGION \
  --admin-user $SQL_ADMIN_USER \
  --admin-password "$SQL_ADMIN_PASSWORD"

# Create the merge_db database
az sql db create \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME \
  --name merge_db \
  --service-objective S1

# Get the SQL Server FQDN
SQL_SERVER_FQDN="${SQL_SERVER_NAME}.database.windows.net"
echo "SQL Server FQDN: $SQL_SERVER_FQDN"
```

#### 5a. Create Private Endpoint for Azure SQL

To allow AKS pods to reach Azure SQL over the VNet (without public internet):

```bash
# Disable public network access (security best practice)
az sql server update \
  --resource-group $RESOURCE_GROUP \
  --name $SQL_SERVER_NAME \
  --set publicNetworkAccess=Disabled

# Get SQL Server resource ID
SQL_SERVER_ID=$(az sql server show \
  --resource-group $RESOURCE_GROUP \
  --name $SQL_SERVER_NAME \
  --query id -o tsv)

# Create private endpoint
az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name "${SQL_SERVER_NAME}-pe" \
  --vnet-name $VNET_NAME \
  --subnet sql-subnet \
  --private-connection-resource-id $SQL_SERVER_ID \
  --group-id sqlServer \
  --connection-name "${SQL_SERVER_NAME}-pe-conn"

# Create private DNS zone for SQL Server
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name "privatelink.database.windows.net"

# Link DNS zone to VNet
az network private-dns zone vnet-link create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.database.windows.net" \
  --name "${VNET_NAME}-sql-link" \
  --virtual-network $VNET_NAME \
  --registration-enabled false

# Create DNS records for the private endpoint
PE_NIC_ID=$(az network private-endpoint show \
  --resource-group $RESOURCE_GROUP \
  --name "${SQL_SERVER_NAME}-pe" \
  --query "networkInterfaces[0].id" -o tsv)

PE_IP=$(az network nic show --ids $PE_NIC_ID \
  --query "ipConfigurations[0].privateIpAddress" -o tsv)

az network private-dns record-set a create \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.database.windows.net" \
  --name $SQL_SERVER_NAME

az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name "privatelink.database.windows.net" \
  --record-set-name $SQL_SERVER_NAME \
  --ipv4-address $PE_IP
```

**Alternative (simpler but less secure):** If you prefer public access during setup, skip the private endpoint and instead add a VNet firewall rule:

```bash
# Only if NOT using private endpoint:
AKS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aks-subnet \
  --query id -o tsv)

az sql server vnet-rule create \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME \
  --name aks-access \
  --vnet-name $VNET_NAME \
  --subnet aks-subnet

# Also enable the service endpoint on the AKS subnet
az network vnet subnet update \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aks-subnet \
  --service-endpoints Microsoft.Sql
```

**Checkpoint:**

```bash
az sql db show --resource-group $RESOURCE_GROUP --server $SQL_SERVER_NAME --name merge_db \
  --query "{name:name, status:status, serviceObjective:currentServiceObjectiveName}" -o table
```

Status must be `Online`.

If using private endpoint, verify:

```bash
az network private-endpoint show --resource-group $RESOURCE_GROUP \
  --name "${SQL_SERVER_NAME}-pe" \
  --query "{name:name, state:provisioningState, status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table
```

State must be `Succeeded` and status must be `Approved`.

---

### Step 6: Create Key Vault

```bash
az keyvault create \
  --resource-group $RESOURCE_GROUP \
  --name $KEY_VAULT_NAME \
  --location $AZURE_REGION \
  --enable-rbac-authorization true
```

**IMPORTANT:** We use `--enable-rbac-authorization true` so that access is controlled via Azure RBAC roles (specifically "Key Vault Secrets User") rather than vault access policies. This integrates cleanly with Workload Identity.

Grant yourself access to manage secrets during setup:

```bash
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id $CURRENT_USER_ID \
  --scope $(az keyvault show --name $KEY_VAULT_NAME --query id -o tsv)
```

**Checkpoint:**

```bash
az keyvault show --name $KEY_VAULT_NAME \
  --query "{name:name, state:properties.provisioningState, rbac:properties.enableRbacAuthorization, uri:properties.vaultUri}" -o table
```

State must be `Succeeded`, RBAC must be `True`.

---

## Phase 2: AKS Configuration

### Step 7: Configure kubeconfig

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --overwrite-existing

kubectl get nodes
```

**Checkpoint:** All nodes should be in `Ready` status:

```bash
kubectl get nodes -o wide
```

**IMPORTANT: Create the Airflow database now.** The PostgreSQL Flexible Server is only accessible from within the VNet, so we must create the `airflow_db` database from inside the AKS cluster:

```bash
kubectl run db-setup --rm -i --restart=Never \
  --image=postgres:16 \
  --env="PGPASSWORD=$PG_ADMIN_PASSWORD" \
  -- bash -c "psql -h $PG_FQDN -U $PG_ADMIN_USER -d postgres -c 'CREATE DATABASE airflow_db;'"
```

**Note:** This runs in the `default` namespace since our application namespace does not exist yet.

**Checkpoint:** Test PostgreSQL connectivity from a pod:

```bash
kubectl run db-test --rm -i --restart=Never \
  --image=postgres:16 \
  --env="PGPASSWORD=$PG_ADMIN_PASSWORD" \
  -- psql -h $PG_FQDN -U $PG_ADMIN_USER -d airflow_db -c "SELECT 1;"
```

---

### Step 8: Install Secrets Store CSI Driver and Azure Provider

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system

# Install Azure Key Vault provider for the CSI driver
kubectl apply -f https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/deployment/provider-azure-installer.yaml

# Wait for provider pods
kubectl wait --for=condition=ready pod -l app=csi-secrets-store-provider-azure -n kube-system --timeout=60s
```

**Checkpoint:**

```bash
kubectl get pods -n kube-system -l app=csi-secrets-store-provider-azure
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
```

Both CSI driver and Azure provider pods should be `Running`.

---

### Step 9: Verify Azure Files NFS StorageClass

Azure Files NFS is built-in to AKS and does **not** require installing any additional CSI drivers or addons. The `azurefile-csi-nfs` StorageClass is available by default.

```bash
kubectl get storageclass azurefile-csi-nfs
```

If the StorageClass exists, test it with a temporary PVC:

```bash
cat > /tmp/test-azurefile-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-azurefile-pvc
  namespace: default
spec:
  storageClassName: azurefile-csi-nfs
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF
kubectl apply -f /tmp/test-azurefile-pvc.yaml
sleep 60

PVC_STATUS=$(kubectl get pvc test-azurefile-pvc -o jsonpath='{.status.phase}')
if [ "$PVC_STATUS" = "Bound" ]; then
    echo "Azure Files NFS provisioning test successful"
    kubectl delete pvc test-azurefile-pvc
    rm /tmp/test-azurefile-pvc.yaml
else
    echo "Azure Files NFS provisioning FAILED - check troubleshooting section"
    kubectl describe pvc test-azurefile-pvc
fi
```

**Checkpoint:** Test PVC status is `Bound`. If it fails, see the Azure Files NFS troubleshooting section below.

**Note:** If the `azurefile-csi-nfs` StorageClass does not exist (rare on modern AKS), you can create it manually:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
mountOptions:
  - nconnect=4
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
```

---

### Step 10: Workload Identity Setup

Workload Identity is the Azure equivalent of AWS IRSA. It allows AKS pods to authenticate to Azure services (Key Vault) using a managed identity without storing credentials.

#### 10a. Create Managed Identity

```bash
az identity create \
  --resource-group $RESOURCE_GROUP \
  --name $MANAGED_IDENTITY_NAME \
  --location $AZURE_REGION

# Capture identity details
IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $MANAGED_IDENTITY_NAME \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $MANAGED_IDENTITY_NAME \
  --query principalId -o tsv)

echo "Client ID: $IDENTITY_CLIENT_ID"
echo "Principal ID: $IDENTITY_PRINCIPAL_ID"
```

#### 10b. Assign Key Vault Secrets User Role

```bash
KV_RESOURCE_ID=$(az keyvault show --name $KEY_VAULT_NAME --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --scope $KV_RESOURCE_ID
```

#### 10c. Create Federated Credentials

Each Airflow service account needs a federated credential so its pods can assume the managed identity. The infrastructure DAG reads secrets at parse time in the dag-processor/scheduler pods, not just the worker, so **all** Airflow SAs need access.

```bash
OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "OIDC Issuer: $OIDC_ISSUER"

for SA in airflow-worker airflow-dag-processor airflow-scheduler airflow-triggerer; do
  az identity federated-credential create \
    --name "fc-${SA}" \
    --identity-name $MANAGED_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --issuer "$OIDC_ISSUER" \
    --subject "system:serviceaccount:${NAMESPACE}:${SA}" \
    --audiences "api://AzureADTokenExchange"
done
```

**Checkpoint:**

```bash
az identity federated-credential list \
  --identity-name $MANAGED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "[].{name:name, issuer:issuer, subject:subject}" -o table
```

Should show 4 federated credentials, one for each Airflow service account.

Verify the role assignment:

```bash
az role assignment list \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --scope $KV_RESOURCE_ID \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

Should show `Key Vault Secrets User` role.

---

## Phase 3: Model Preparation

### Step 11: Build and Push Custom Airflow Image

The custom image includes `pymssql` and `pyodbc` for SQL Server connectivity (Azure SQL merge DB), plus `azure-identity` and `azure-keyvault-secrets` for Workload Identity and Key Vault access at DAG parse time.

```bash
cd /path/to/datasurface
docker buildx build --platform linux/amd64,linux/arm64 \
  -f src/datasurface/platforms/yellow/docker/Docker.airflow3x_with_drivers \
  -t <your-registry>/airflow:3.1.7-azure \
  --push .
```

Replace `<your-registry>` with your container registry (e.g., GitLab, ACR, or Docker Hub).

**Alternative: Use Azure Container Registry (ACR):**

```bash
# Create ACR (if not already existing)
ACR_NAME=$(echo "${RESOURCE_GROUP}acr" | tr -d '-')  # Must be globally unique, alphanumeric only (no hyphens!)
az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Basic

# Attach ACR to AKS (enables pull without imagePullSecrets)
az aks update --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --attach-acr $ACR_NAME

# Login and push
az acr login --name $ACR_NAME
docker buildx build --platform linux/amd64 \
  -f src/datasurface/platforms/yellow/docker/Docker.airflow3x_with_drivers \
  -t ${ACR_NAME}.azurecr.io/airflow:3.1.7-azure \
  --push .
```

Verify the image contains required Azure dependencies:

```bash
docker run --rm <your-registry>/airflow:3.1.7-azure pip list | grep -E "(pymssql|azure-identity|azure-keyvault)"
```

**Checkpoint:** Image is pushed and contains:
- `pymssql`
- `azure-identity`
- `azure-keyvault-secrets`

---

### Step 12: Verify rte_azure.py Exists

```bash
ls -la rte_azure.py
```

The file should already exist in the repository. It contains the Azure-specific runtime environment configuration (Azure SQL merge endpoint, Azure Files NFS storage class, Workload Identity service account, Key Vault references). If missing, see the plan documentation for the full file content.

**Checkpoint:** File exists and contains Azure-specific configuration (SQLServerDatabase, `azurefile-csi-nfs`, `YellowAzureExternalAirflow3AndMergeDatabase`).

---

### Step 13: Verify eco.py Has RTE_TARGET Dispatch

```bash
grep -A5 "RTE_TARGET" eco.py
```

This should show the import dispatch logic that selects between `rte_demo` (local), `rte_aws` (AWS), and `rte_azure` (Azure) based on the `RTE_TARGET` environment variable. If missing, add the dispatch:

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

**Checkpoint:** `eco.py` imports from `rte_azure` when `RTE_TARGET=azure`.

---

### Step 14: Customize Model and Helm Values

Replace all PLACEHOLDER values in `rte_azure.py` and the Helm values file with actual Azure resource endpoints:

```bash
# Get Azure resource FQDNs
PG_FQDN=$(az postgres flexible-server show \
  --resource-group $RESOURCE_GROUP \
  --name ${RESOURCE_GROUP}-pgflex \
  --query fullyQualifiedDomainName -o tsv)

SQL_SERVER_FQDN="${RESOURCE_GROUP}-sqlserver.database.windows.net"

IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name $MANAGED_IDENTITY_NAME \
  --query clientId -o tsv)

# Switch eco.py to use the Azure RTE instead of local
sed -i.bak "s|from rte_demo import createDemoRTE|from rte_azure import createDemoRTE|g" eco.py
rm -f eco.py.bak

# Replace placeholders in rte_azure.py (model configuration)
sed -i.bak "s|PLACEHOLDER_SQL_SERVER_FQDN|$SQL_SERVER_FQDN|g" rte_azure.py
sed -i.bak "s|PLACEHOLDER_PG_FQDN|$PG_FQDN|g" rte_azure.py
sed -i.bak "s|PLACEHOLDER_NAMESPACE|$NAMESPACE|g" rte_azure.py
rm -f rte_azure.py.bak

# Replace placeholders in Helm values (work on temp copy to preserve template)
cp helm/airflow-values-azure.yaml /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_PG_FQDN|$PG_FQDN|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_PG_ADMIN_USER|$PG_ADMIN_USER|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_PG_ADMIN_PASSWORD|$PG_ADMIN_PASSWORD|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_AIRFLOW_REPO|$AIRFLOW_REPO|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_MANAGED_IDENTITY_CLIENT_ID|$IDENTITY_CLIENT_ID|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_KEY_VAULT_URL|https://${KEY_VAULT_NAME}.vault.azure.net|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_AIRFLOW_IMAGE_REPO|<your-registry>/airflow|g" /tmp/airflow-values-azure.yaml
sed -i.bak "s|PLACEHOLDER_AIRFLOW_IMAGE_TAG|3.1.7-azure|g" /tmp/airflow-values-azure.yaml
rm -f /tmp/airflow-values-azure.yaml.bak
```

**Note:** Replace `<your-registry>/airflow` with your actual container registry path (e.g., `${ACR_NAME}.azurecr.io/airflow` or your GitLab registry).

**Note:** On macOS, `sed -i` requires a backup extension. Use `sed -i.bak` then remove the `.bak` file.

**IMPORTANT:** The `rte_azure.py` values are baked into the model and committed to the repository. Task pods spawned by the infrastructure DAG load the model from git at runtime and do NOT have access to environment variables like `MERGE_HOST` or `SQL_SERVER_FQDN`. All deployment-specific values must be string literals in the committed file, not `os.environ` lookups.

**Note:** The Helm values file includes `sslmode: require` in the `metadataConnection` block. This is required for Azure Database for PostgreSQL Flexible Server connections and should not be removed.

**Note:** The Helm values file includes an `env` section that sets `AZURE_KEY_VAULT_URL` on all Airflow pods. This is required because the infrastructure DAG uses `AzureKeyVaultSecretManager` at parse time.

**Checkpoint:**

```bash
grep PLACEHOLDER rte_azure.py /tmp/airflow-values-azure.yaml
grep rte_demo eco.py
```

Both should return no matches (all PLACEHOLDERs replaced, eco.py imports rte_azure).

---

### Step 15: Push Model to Repository and Tag

```bash
git remote set-url origin https://github.com/$MODEL_REPO.git

git add eco.py rte_azure.py helm/airflow-values-azure.yaml
git commit -m "Configure model for Azure AKS deployment"
git push -u origin main --force

git tag v1.0.0-demo
git push origin v1.0.0-demo
```

**IMPORTANT: Create a GitHub Release (not just a tag).** The infrastructure DAG uses `VersionPatternReleaseSelector` with `ReleaseType.STABLE_ONLY`, which queries the GitHub **Releases API** -- git tags alone are not sufficient. You must create a GitHub Release from the tag:

1. Go to `https://github.com/$MODEL_REPO/releases/new`
2. Select the `v1.0.0-demo` tag
3. Set the release title to `v1.0.0-demo`
4. Ensure **"Set as a pre-release"** is **unchecked** (must be a stable release)
5. Click **"Publish release"**

**Checkpoint:**
- `git remote -v` shows the target model repository
- `git log -1` shows the configure commit
- `git tag` shows `v1.0.0-demo`
- Verify on GitHub that the repository has the tag AND a **published Release** (not pre-release) for `v1.0.0-demo`

---

## Phase 4: Secrets & Bootstrap

### Step 16: Create Key Vault Secrets

Azure Key Vault secret names cannot contain slashes. DataSurface uses `--` (double-dash) as the separator. The `AzureKeyVaultSecretManager` in the generated DAG reads secrets using the naming pattern: `datasurface--{namespace}--{ecosystem_name}--{credential_name}--credentials`.

```bash
# Merge DB credentials (Azure SQL Database)
az keyvault secret set --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials" \
  --value "{\"USER\":\"${SQL_ADMIN_USER}\",\"PASSWORD\":\"${SQL_ADMIN_PASSWORD}\"}"

# Git credentials (for model repo access at runtime)
az keyvault secret set --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--git--credentials" \
  --value "{\"token\":\"${GITHUB_TOKEN}\",\"TOKEN\":\"${GITHUB_TOKEN}\"}"
```

Verify all secrets were created:

```bash
az keyvault secret list --vault-name $KEY_VAULT_NAME \
  --query "[].{name:name, enabled:attributes.enabled}" -o table
```

**Checkpoint:** Both secrets are listed:
- `datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials`
- `datasurface--${NAMESPACE}--Demo--git--credentials`

Verify you can read them back:

```bash
az keyvault secret show --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials" \
  --query value -o tsv | python3 -c "import sys,json; d=json.load(sys.stdin); print('USER:', d.get('USER','MISSING'))"
```

---

### Step 17: Generate Bootstrap Artifacts

```bash
docker login registry.gitlab.com -u "$GITLAB_CUSTOMER_USER" -p "$GITLAB_CUSTOMER_TOKEN"
docker pull registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}

docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  -e RTE_TARGET=azure \
  -e MERGE_HOST="$SQL_SERVER_FQDN" \
  -e AZURE_KEY_VAULT_URL="https://${KEY_VAULT_NAME}.vault.azure.net" \
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

## Phase 5: Deploy to AKS

### Step 18: Create Namespace and Registry Secrets

```bash
kubectl create namespace $NAMESPACE

# GitLab registry credentials for pulling DataSurface images
kubectl create secret docker-registry datasurface-registry \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  -n $NAMESPACE

# Attach image pull secret to default and airflow-worker service accounts.
# The airflow-worker SA is used by generated job pods (ring1-init, model-merge, reconcile-views)
# which need to pull DataSurface images from the GitLab registry.
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "datasurface-registry"}]}'
```

**IMPORTANT: Creating K8s Secrets with Special Characters.** If you must create K8s secrets containing passwords with special characters, do NOT use `kubectl create secret --from-literal` in zsh. Instead, write the value to a file and use `--from-file`:

```bash
printf '%s' "$PASSWORD_WITH_SPECIAL_CHARS" > /tmp/password.txt
kubectl create secret generic my-secret --from-file=PASSWORD=/tmp/password.txt -n $NAMESPACE
rm /tmp/password.txt
```

This avoids zsh shell escaping issues. Better yet, follow the password guidance in the Pre-Flight section and avoid special characters entirely.

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

### Step 19: Initialize DAG Repository (BEFORE Helm Install)

**CRITICAL: This must happen BEFORE Helm install (Step 20).** The Airflow Helm chart uses git-sync init containers that will fail with `couldn't find remote ref main` if the DAG repository is empty or missing the `main` branch. This causes pods to enter `Init:Error` state.

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

### Step 20: Install Airflow via Helm

**IMPORTANT: Verify Helm values BEFORE installing.** The Helm values file (`/tmp/airflow-values-azure.yaml`) must include these sections or the deployment will fail silently or with confusing errors:

**1. Pod-Level Workload Identity Labels (CRITICAL).** The Workload Identity mutating webhook uses a Kubernetes `objectSelector` that matches on **pod** labels, NOT service account labels. Without a top-level `labels:` block, the webhook will NOT inject `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` environment variables into any pods -- even if the service account has the correct annotation and label. The Helm values file MUST include at the root level:

```yaml
# Top-level labels block - applied to ALL pods by the Helm chart
labels:
  azure.workload.identity/use: "true"
```

Without this, Workload Identity will appear to be configured correctly (SA has the right annotation and label) but pods will silently lack the Azure credentials.

**2. Complete webserver.defaultUser.** The `webserver.defaultUser` section must include ALL required fields or the `create-user` hook job will fail:

```yaml
webserver:
  defaultUser:
    enabled: true
    role: Admin
    username: admin
    firstName: Admin
    lastName: User
    email: admin@example.com
    password: admin
```

The `role` field is particularly important -- omitting it causes the hook to fail with an empty role error.

**3. Environment variables for Azure services.** All Airflow pods need `AZURE_KEY_VAULT_URL` set via the `env:` section in the values file, since the infrastructure DAG uses `AzureKeyVaultSecretManager` at parse time.

Now install:

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  -f /tmp/airflow-values-azure.yaml \
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

**Note:** If pods are stuck in `Init:Error`, the DAG repository was not initialized before this step (Step 19).

**Note:** If the Helm install times out but pods are still progressing (creating, pulling images), the release may be left in `pending-install` state. See the "Helm Release Stuck in Pending State" troubleshooting section.

---

### Step 21: Annotate All Airflow Service Accounts with Workload Identity

The Helm chart's `serviceAccount` block only creates the `airflow-worker` SA with the Workload Identity annotation. The dag-processor, scheduler, and triggerer also need Key Vault access because the infrastructure DAG reads secrets at parse time via `AzureKeyVaultSecretManager`. Annotate and label all Airflow SAs:

```bash
# Annotate all Airflow service accounts with Workload Identity client ID
for SA in airflow-worker airflow-dag-processor airflow-scheduler airflow-triggerer; do
  kubectl annotate serviceaccount $SA -n $NAMESPACE \
    azure.workload.identity/client-id=$IDENTITY_CLIENT_ID --overwrite
  kubectl label serviceaccount $SA -n $NAMESPACE \
    azure.workload.identity/use=true --overwrite
done

# IMPORTANT: Restart ALL Airflow pods to pick up Workload Identity annotations.
# Deployments can use rollout restart, but StatefulSets (worker, triggerer) require pod deletion.
kubectl rollout restart deployment/airflow-dag-processor deployment/airflow-scheduler deployment/airflow-api-server -n $NAMESPACE
kubectl delete pod -n $NAMESPACE -l component=worker
kubectl delete pod -n $NAMESPACE -l component=triggerer

# Wait for all pods to be ready
kubectl rollout status deployment/airflow-dag-processor -n $NAMESPACE
kubectl rollout status deployment/airflow-scheduler -n $NAMESPACE
kubectl rollout status deployment/airflow-api-server -n $NAMESPACE
kubectl wait --for=condition=ready pod -l component=worker -n $NAMESPACE --timeout=120s
kubectl wait --for=condition=ready pod -l component=triggerer -n $NAMESPACE --timeout=120s
```

**Checkpoint:**

```bash
for SA in airflow-worker airflow-dag-processor airflow-scheduler airflow-triggerer; do
  CLIENT_ID=$(kubectl get sa $SA -n $NAMESPACE -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}')
  USE_LABEL=$(kubectl get sa $SA -n $NAMESPACE -o jsonpath='{.metadata.labels.azure\.workload\.identity/use}')
  echo "$SA: client-id=$CLIENT_ID, use=$USE_LABEL"
done
```

All four service accounts should show the managed identity client ID and `use=true`.

**CRITICAL: Verify Workload Identity is actually injected into the worker pod** (not just the SA annotation):

```bash
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- env | grep -E "AZURE_CLIENT_ID|AZURE_TENANT_ID|AZURE_FEDERATED_TOKEN_FILE"
```

This must show three environment variables:
- `AZURE_CLIENT_ID` - the managed identity client ID
- `AZURE_TENANT_ID` - your Azure AD tenant ID
- `AZURE_FEDERATED_TOKEN_FILE` - path to the projected service account token

If these are missing, the pod was not restarted after annotation -- delete it again with `kubectl delete pod airflow-worker-0 -n $NAMESPACE`.

---

### Step 22: Create RBAC for Airflow Secret Access

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

### Step 23: Create Kubernetes Secrets for Job Pods

**CRITICAL:** The generated job YAMLs (ring1-init, model-merge, reconcile-views) reference Kubernetes secrets via `secretKeyRef`. These are **separate** from the Key Vault secrets created in Step 16 and from the registry/git-dags secrets created in Step 18. You must create these K8s secrets before running the jobs.

The jobs expect two secrets:
- `git` - with key `TOKEN` (GitHub PAT for model repo access)
- `sqlserver-demo-merge` - with keys `USER` and `PASSWORD` (Azure SQL credentials)

```bash
# Git credentials for model repo access at runtime
kubectl create secret generic git \
  --from-literal=TOKEN=$GITHUB_TOKEN \
  -n $NAMESPACE

# Azure SQL merge database credentials
kubectl create secret generic sqlserver-demo-merge \
  --from-literal=USER=$SQL_ADMIN_USER \
  --from-literal=PASSWORD="$SQL_ADMIN_PASSWORD" \
  -n $NAMESPACE
```

**Checkpoint:**

```bash
kubectl get secrets git sqlserver-demo-merge -n $NAMESPACE
```

Both secrets should exist. Verify the keys are correct:

```bash
kubectl get secret git -n $NAMESPACE -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print('TOKEN:', 'present' if 'TOKEN' in d else 'MISSING')"
kubectl get secret sqlserver-demo-merge -n $NAMESPACE -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print('USER:', 'present' if 'USER' in d else 'MISSING', 'PASSWORD:', 'present' if 'PASSWORD' in d else 'MISSING')"
```

---

### Step 24: Deploy Bootstrap and Run Jobs

**IMPORTANT:** Jobs must run sequentially. The ring1-init job creates database tables that model-merge depends on. Running them simultaneously causes a race condition where model-merge fails trying to access non-existent tables.

#### 24a. Validate Generated YAML

The bootstrap generator (v1.1.0+) produces correct Azure YAML out of the box, including the correct `storageClassName`, `serviceAccountName`, `imagePullSecrets`, environment variables, and credential handling. No manual edits should be needed.

Validate all job YAMLs parse correctly before applying:

```bash
for f in generated_output/Demo_PSP/*job*.yaml generated_output/Demo_PSP/kubernetes-bootstrap.yaml; do
  kubectl apply --dry-run=client -f "$f" && echo "$f: OK" || echo "$f: FAILED"
done
```

If any YAML fails validation, inspect the file and fix the specific issue.

#### 24b. Deploy Bootstrap and Run Jobs

```bash
# Apply Kubernetes bootstrap (creates PVCs, ConfigMaps, NetworkPolicy, MCP server)
kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml

# Ensure Airflow service account has Workload Identity annotation (safety net)
kubectl annotate serviceaccount airflow-worker \
  -n $NAMESPACE \
  azure.workload.identity/client-id=$IDENTITY_CLIENT_ID \
  --overwrite
kubectl label serviceaccount airflow-worker \
  -n $NAMESPACE \
  azure.workload.identity/use=true \
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

### Step 25: Verify Jobs Complete

```bash
kubectl get jobs -n $NAMESPACE -o wide
```

If either job failed, inspect the pod logs:

```bash
# Get the pod name for the failed job
kubectl get pods -n $NAMESPACE -l job-name=demo-psp-ring1-init
kubectl get pods -n $NAMESPACE -l job-name=demo-psp-model-merge-job

# Check logs
kubectl logs -n $NAMESPACE -l job-name=demo-psp-ring1-init --tail=100
kubectl logs -n $NAMESPACE -l job-name=demo-psp-model-merge-job --tail=100
```

**Common failure causes:**
- **Azure SQL connectivity**: Verify private endpoint DNS resolution, or check firewall rules
- **Key Vault access denied**: Workload Identity not injected (check Step 21)
- **Missing K8s secrets**: Verify `git` and `sqlserver-demo-merge` secrets exist (check Step 23)
- **ImagePullBackOff**: Verify `datasurface-registry` secret exists and `airflow-worker` SA has `imagePullSecrets`

**Checkpoint:** Both jobs show `1/1 COMPLETIONS` and `0` failures.

---

## Phase 6: Verify & Access

### Step 26: Create Airflow Admin User

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

### Step 27: Verify DAGs Registered

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

### Step 28: Port-Forward and Access UI

```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n $NAMESPACE
```

Open <http://localhost:8080> in your browser:
- Username: `admin`
- Password: `admin123`

**Checkpoint:** Airflow UI loads and all 5 DAGs are visible in the DAGs list.

---

## Troubleshooting

### Password Special Characters Cause Authentication Failures

**Symptoms:** "password authentication failed for user" (PostgreSQL) or "Login failed for user" error 18456 (SQL Server), even though the password appears correct in `az` CLI output.

**Root cause:** The macOS default shell (zsh) performs history expansion on `!` even inside single quotes when the string is passed as a command argument. This means `kubectl create secret --from-literal=password='DsDemo2024pg!'` silently stores `DsDemo2024pg\!` (with backslash) in the Kubernetes secret. The Azure database has the correct password (`DsDemo2024pg!`), but the K8s secret has the corrupted version, causing authentication failures.

**Diagnosis:**

```bash
# Check what's actually stored in the K8s secret
kubectl get secret <secret-name> -n $NAMESPACE -o jsonpath='{.data.PASSWORD}' | base64 -d
```

If you see a backslash before `!`, the password was corrupted by shell escaping.

**Fix:** Reset the database password to one without special characters, then recreate the K8s secret:

```bash
# Reset PostgreSQL password
az postgres flexible-server update \
  --resource-group $RESOURCE_GROUP \
  --name ${RESOURCE_GROUP}-pgflex \
  --admin-password "NewPasswordNoSpecialChars"

# Reset SQL Server password
az sql server update \
  --resource-group $RESOURCE_GROUP \
  --name $SQL_SERVER_NAME \
  --admin-password "NewPasswordNoSpecialChars"

# Also update the Key Vault secret if using Azure Key Vault
az keyvault secret set --vault-name $KEY_VAULT_NAME \
  --name "datasurface--${NAMESPACE}--Demo--sqlserver-demo-merge--credentials" \
  --value "{\"USER\":\"${SQL_ADMIN_USER}\",\"PASSWORD\":\"NewPasswordNoSpecialChars\"}"
```

**Prevention:** Use only alphanumeric characters and simple symbols (`-`, `_`) in all passwords. This is documented in the Pre-Flight Checklist.

---

### Helm Release Stuck in Pending State

**Symptoms:** `helm install` or `helm upgrade` fails or times out, leaving the release in `pending-install` or `pending-upgrade` state. Subsequent `helm install` fails with "cannot re-use a name that is still in use", and `helm upgrade` fails with "another operation (install/upgrade/rollback) is in progress".

**Diagnosis:**

```bash
helm list -n $NAMESPACE -a
```

Shows release status as `pending-install` or `pending-upgrade`.

**Fix:** Uninstall with `--no-hooks` (hooks may be the cause of the failure), then reinstall:

```bash
helm uninstall airflow -n $NAMESPACE --no-hooks
# Wait for resources to be cleaned up
kubectl get pods -n $NAMESPACE -w  # Watch until all airflow pods are gone
# Then reinstall
helm install airflow apache-airflow/airflow \
  -f /tmp/airflow-values-azure.yaml \
  -n $NAMESPACE \
  --timeout 10m
```

**Note:** `helm uninstall` will delete all Airflow pods, PVCs (if not using `--keep-history`), and services. This is safe because all persistent data is in external databases (PostgreSQL, Azure SQL) and Azure Files NFS volumes. The `--no-hooks` flag is important because hook jobs (like `create-user`) may be what caused the failure in the first place.

**Prevention:** Ensure the `webserver.defaultUser` section in Helm values includes all required fields (especially `role: Admin`) before the first install. Missing fields cause the `create-user` hook job to fail, which leaves the release in a pending state.

---

### PostgreSQL Flexible Server Connectivity

**Symptoms:** Jobs or Airflow pods fail with "could not connect to server" or "timeout expired" when connecting to PostgreSQL.

Test database connectivity from inside a pod:

```bash
kubectl run db-test --rm -i --restart=Never \
  --image=postgres:16 \
  --env="PGPASSWORD=$PG_ADMIN_PASSWORD" \
  -n $NAMESPACE \
  -- psql -h $PG_FQDN -U $PG_ADMIN_USER -d airflow_db -c "SELECT version();"
```

**Common causes and fixes:**

1. **VNet delegation not configured:** The PostgreSQL subnet must be delegated to `Microsoft.DBforPostgreSQL/flexibleServers`. Verify:
   ```bash
   az network vnet subnet show --resource-group $RESOURCE_GROUP \
     --vnet-name $VNET_NAME --name pg-subnet \
     --query "delegations[0].serviceName" -o tsv
   ```
   Must show `Microsoft.DBforPostgreSQL/flexibleServers`.

2. **DNS resolution failing:** VNet-integrated Flex Server uses Azure private DNS. Verify:
   ```bash
   kubectl run dns-test --rm -i --restart=Never \
     --image=busybox -- nslookup $PG_FQDN
   ```
   Must resolve to a private IP (10.x.x.x).

3. **Flex Server not in Ready state:**
   ```bash
   az postgres flexible-server show --resource-group $RESOURCE_GROUP \
     --name ${RESOURCE_GROUP}-pgflex --query state -o tsv
   ```
   Must be `Ready`.

4. **SSL mode mismatch:** Azure PostgreSQL Flexible Server enforces SSL by default. The Helm values include `sslmode: require` which is correct. Do not set `sslmode: disable`.

---

### Azure SQL Connectivity

**Symptoms:** Merge jobs fail with "Login timeout expired", "Cannot open server", or ODBC connection errors.

Test connectivity from inside a pod:

```bash
kubectl run sql-test --rm -i --restart=Never \
  --image=mcr.microsoft.com/mssql-tools:latest \
  --env="ACCEPT_EULA=Y" \
  -n $NAMESPACE \
  -- /opt/mssql-tools/bin/sqlcmd -S $SQL_SERVER_FQDN -U $SQL_ADMIN_USER -P "$SQL_ADMIN_PASSWORD" -d merge_db -Q "SELECT 1"
```

**Common causes and fixes:**

1. **Private endpoint DNS not resolving:** If using private endpoint, verify DNS:
   ```bash
   kubectl run dns-test --rm -i --restart=Never \
     --image=busybox -n $NAMESPACE \
     -- nslookup ${SQL_SERVER_NAME}.database.windows.net
   ```
   Must resolve to a private IP (10.0.17.x), NOT a public IP.

   If it resolves to a public IP, the private DNS zone VNet link is missing:
   ```bash
   az network private-dns zone vnet-link list \
     --resource-group $RESOURCE_GROUP \
     --zone-name "privatelink.database.windows.net" -o table
   ```

2. **Firewall rules blocking access:** If NOT using private endpoint, verify VNet rule:
   ```bash
   az sql server vnet-rule list --resource-group $RESOURCE_GROUP \
     --server $SQL_SERVER_NAME -o table
   ```

3. **Public network access disabled without private endpoint:**
   ```bash
   az sql server show --resource-group $RESOURCE_GROUP --name $SQL_SERVER_NAME \
     --query publicNetworkAccess -o tsv
   ```
   If `Disabled` and no private endpoint exists, either enable public access or create a private endpoint (Step 5a).

4. **ODBC driver missing in custom image:** The `Docker.airflow3x_with_drivers` Dockerfile installs ODBC Driver 18. Verify:
   ```bash
   kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- odbcinst -q -d
   ```
   Must show `[ODBC Driver 18 for SQL Server]`.

---

### Workload Identity Not Injecting

**Symptoms:** Pods fail with "DefaultAzureCredential failed", "ManagedIdentityCredential authentication unavailable", or `AZURE_CLIENT_ID` environment variable is missing.

```bash
kubectl exec -n $NAMESPACE airflow-worker-0 -c worker -- env | grep AZURE
```

**Common causes and fixes:**

1. **Missing pod-level Workload Identity label (MOST COMMON):** The Workload Identity mutating webhook uses a Kubernetes `objectSelector` that matches on **pod** labels, not just service account labels. Even if the SA has the correct annotation and label, the webhook won't inject credentials unless the **pod itself** has `azure.workload.identity/use: "true"`. The Helm values file must include a top-level `labels:` block:
   ```yaml
   labels:
     azure.workload.identity/use: "true"
   ```
   After adding this, run `helm upgrade` and restart pods. Verify with:
   ```bash
   kubectl get pod airflow-worker-0 -n $NAMESPACE -o jsonpath='{.metadata.labels}' | python3 -m json.tool | grep workload
   ```

2. **Missing label on service account:** Workload Identity also requires BOTH the annotation AND the label on the SA:
   ```bash
   kubectl get sa airflow-worker -n $NAMESPACE -o yaml | grep -A2 "workload.identity"
   ```
   Must show:
   - `azure.workload.identity/client-id: <client-id>` (annotation)
   - `azure.workload.identity/use: "true"` (label)

   Fix:
   ```bash
   kubectl label serviceaccount airflow-worker -n $NAMESPACE \
     azure.workload.identity/use=true --overwrite
   kubectl delete pod airflow-worker-0 -n $NAMESPACE
   ```

3. **Federated credential mismatch:** The subject in the federated credential must exactly match the service account name and namespace:
   ```bash
   az identity federated-credential list \
     --identity-name $MANAGED_IDENTITY_NAME \
     --resource-group $RESOURCE_GROUP \
     --query "[].{name:name, subject:subject}" -o table
   ```
   Each subject must be `system:serviceaccount:${NAMESPACE}:<sa-name>`.

4. **OIDC issuer URL mismatch:** The issuer in federated credentials must match the AKS cluster's OIDC issuer:
   ```bash
   az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
     --query "oidcIssuerProfile.issuerUrl" -o tsv
   ```
   Compare with:
   ```bash
   az identity federated-credential show \
     --identity-name $MANAGED_IDENTITY_NAME \
     --resource-group $RESOURCE_GROUP \
     --name fc-airflow-worker \
     --query issuer -o tsv
   ```
   Both must be identical.

5. **Pod not restarted after annotation:** Workload Identity is injected at pod creation time via a mutating webhook. If you annotated the SA after the pod was created, you must delete and recreate the pod:
   ```bash
   kubectl delete pod -n $NAMESPACE -l component=worker
   kubectl delete pod -n $NAMESPACE -l component=dag-processor
   kubectl delete pod -n $NAMESPACE -l component=scheduler
   kubectl delete pod -n $NAMESPACE -l component=triggerer
   ```

---

### Azure Files NFS PVC Stuck Pending

**Symptoms:** PersistentVolumeClaims using `azurefile-csi-nfs` stuck in `Pending` state.

```bash
kubectl describe pvc <pvc-name> -n $NAMESPACE
```

**Common causes and fixes:**

1. **StorageClass does not exist:**
   ```bash
   kubectl get storageclass azurefile-csi-nfs
   ```
   If missing, create it manually (see Step 9).

2. **Azure Files CSI driver not running:**
   ```bash
   kubectl get pods -n kube-system -l app=csi-azurefile-node
   ```
   Pods should be `Running` on each node.

3. **Storage account creation failing:** Azure Files NFS requires a Premium storage account. Check events:
   ```bash
   kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep -i pvc
   ```

4. **NFS not supported in region:** Azure Files NFS with Premium tier may not be available in all regions. Verify your region supports it.

5. **Quota exceeded:** Check your subscription's storage account quota:
   ```bash
   az storage account list --resource-group $RESOURCE_GROUP -o table
   ```

---

### Key Vault Access Denied

**Symptoms:** Pods fail with "Access denied" or "Forbidden" when reading Key Vault secrets.

```bash
kubectl logs -n $NAMESPACE deployment/airflow-dag-processor -c dag-processor | grep -i "vault\|secret\|denied\|forbidden"
```

**Common causes and fixes:**

1. **RBAC role not assigned:** Verify the managed identity has the "Key Vault Secrets User" role:
   ```bash
   IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP \
     --name $MANAGED_IDENTITY_NAME --query principalId -o tsv)
   KV_RESOURCE_ID=$(az keyvault show --name $KEY_VAULT_NAME --query id -o tsv)

   az role assignment list \
     --assignee $IDENTITY_PRINCIPAL_ID \
     --scope $KV_RESOURCE_ID \
     --query "[].roleDefinitionName" -o tsv
   ```
   Must show `Key Vault Secrets User`.

2. **RBAC authorization not enabled on Key Vault:**
   ```bash
   az keyvault show --name $KEY_VAULT_NAME \
     --query "properties.enableRbacAuthorization" -o tsv
   ```
   Must be `true`. If `false`, the Key Vault is using access policies instead of RBAC. Either switch to RBAC or add an access policy for the managed identity.

3. **Identity mismatch:** The client ID in the SA annotation must match the managed identity:
   ```bash
   # SA annotation
   kubectl get sa airflow-worker -n $NAMESPACE -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'

   # Managed identity client ID
   az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query clientId -o tsv
   ```
   Both must be identical.

4. **Secret name mismatch:** Azure Key Vault secret names use `--` separators (not `/`). Verify:
   ```bash
   az keyvault secret list --vault-name $KEY_VAULT_NAME --query "[].name" -o tsv
   ```
   Names should follow pattern: `datasurface--{namespace}--Demo--{credential}--credentials`

---

### Custom Airflow Image Pull Failures

**Symptoms:** Pods stuck in `ImagePullBackOff` or `ErrImagePull`.

```bash
kubectl describe pod <pod-name> -n $NAMESPACE | grep -A5 "Events:"
```

**Common causes and fixes:**

1. **ACR not attached to AKS:**
   ```bash
   az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
     --query "identityProfile.kubeletidentity.clientId" -o tsv
   ```
   Attach ACR: `az aks update --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --attach-acr $ACR_NAME`

2. **GitLab registry secret missing or expired:**
   ```bash
   kubectl get secret datasurface-registry -n $NAMESPACE
   ```
   If missing, re-create it (Step 18).

3. **Image tag does not exist:** Verify the image exists in the registry:
   ```bash
   # For ACR:
   az acr repository show-tags --name $ACR_NAME --repository airflow -o table
   # For GitLab:
   docker manifest inspect <your-registry>/airflow:3.1.7-azure
   ```

---

### Worker OOMKilled

**Symptoms:** Worker pod killed with `OOMKilled` status, DAG tasks appear stuck/hung in the UI with no logs.

The default worker memory limit of 2Gi is insufficient when workers execute KubernetesPodOperator tasks. The Helm values template already sets 4Gi limits, but if you used lower values, increase them:

```bash
helm upgrade airflow apache-airflow/airflow \
  -f /tmp/airflow-values-azure.yaml \
  --set workers.resources.requests.memory=2Gi \
  --set workers.resources.limits.memory=4Gi \
  --set workers.resources.limits.cpu=2000m \
  -n $NAMESPACE

# Force pod recreation (Helm upgrade may not recreate StatefulSet pods)
kubectl delete pod airflow-worker-0 -n $NAMESPACE
```

**Checkpoint:** Worker pod restarts with `3/3` containers ready:

```bash
kubectl get pod airflow-worker-0 -n $NAMESPACE
kubectl describe pod airflow-worker-0 -n $NAMESPACE | grep -A2 "Limits:"
```

---

### Git-Sync Init Containers Fail

**Symptoms:** Airflow pods stuck in `Init:Error` or `Init:CrashLoopBackOff`.

```bash
kubectl logs -n $NAMESPACE <pod-name> -c git-sync-init
```

**Common cause:** The DAG repository is empty or missing the `main` branch. The DAG repo MUST be initialized with at least one commit on the `main` branch BEFORE Helm install (Step 19).

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

If the secret or imagePullSecrets binding is missing, re-run Step 18.

---

### Region Provisioning Restrictions

**Symptoms:** `RegionDoesNotAllowProvisioning` for Azure SQL Database, or "location is restricted for provisioning of flexible servers" for PostgreSQL Flexible Server.

**Root cause:** Azure periodically restricts new database provisioning in high-demand regions (especially `eastus`). Both PostgreSQL Flex Server and Azure SQL Database can be blocked simultaneously. This is common on new/demo subscriptions and is not something you can fix -- you must change regions.

**Why you can't work around it:**
- **PostgreSQL Flexible Server with VNet integration** requires the server and VNet to be in the **exact same region**. Cross-region VNet integration is not supported.
- **Azure SQL VNet rules** also require the SQL server and VNet to be in the same region. Cross-region VNet firewall rules fail with `VirtualNetworkRuleBadRequest`.
- While you *can* create databases in a different region and use public access + firewall rules, this defeats the security benefits and adds latency.

**Fix:** Tear down all resources and recreate everything in a different region:

```bash
# Delete the resource group (removes all resources)
az group delete --name $RESOURCE_GROUP --yes --no-wait

# Wait for deletion
while az group exists --name $RESOURCE_GROUP 2>/dev/null | grep -q true; do sleep 30; done

# Purge soft-deleted Key Vault
az keyvault purge --name $KEY_VAULT_NAME 2>/dev/null || true

# Change region and restart from Step 1
export AZURE_REGION="westus2"  # or centralus, westeurope, etc.
```

**Recommended fallback regions:** `westus2`, `centralus`, `westeurope`, `northeurope`

---

### vCPU Quota Exceeded

**Symptoms:** `QuotaExceeded` error during AKS cluster creation mentioning "Total Regional Cores quota".

**Root cause:** New Azure subscriptions typically have a 10 vCPU regional core limit. `Standard_D4s_v3` (4 vCPU) x 3 nodes = 12 cores, which exceeds the default 10-core quota.

**Fix options:**
1. **Use smaller VMs** (recommended): `Standard_D2s_v3` (2 vCPU) x 3 = 6 cores. This is the default in this skill.
2. **Use fewer nodes**: 2 x `Standard_D4s_v3` = 8 cores.
3. **Request quota increase**: Azure Portal > Subscriptions > Usage + quotas > Request increase.

**Note:** If AKS creation fails partway through, it may leave a partially-created cluster in `Failed` state. Delete it before retrying:

```bash
az aks delete --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --yes --no-wait
# Wait for deletion (check periodically)
while az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME 2>/dev/null; do sleep 15; done
```

---

### Service CIDR Overlap

**Symptoms:** AKS creation fails with `ServiceCidrOverlapExistingSubnetsCidr`.

**Root cause:** The default AKS service CIDR (`10.0.0.0/16`) overlaps with the VNet address space (`10.0.0.0/16`).

**Fix:** Add `--service-cidr 172.16.0.0/16 --dns-service-ip 172.16.0.10` to the `az aks create` command (already included in this skill's Step 3).

---

## Key Differences: Local vs Azure

| Aspect | Local (Docker Desktop) | Azure (AKS) |
|--------|----------------------|-----------|
| Database (Airflow) | Docker Compose PostgreSQL | Azure Database for PostgreSQL Flexible Server |
| Database (Merge) | Docker Compose PostgreSQL | Azure SQL Database (SQL Server) |
| Secrets | Kubernetes secrets | Azure Key Vault (via Workload Identity) |
| Storage | standard/hostpath | Azure Files NFS (azurefile-csi-nfs) |
| Infrastructure | None | `az` CLI commands (Resource Group, VNet, AKS, etc.) |
| Auth | None | Workload Identity (Managed Identity + Federated Credentials) |
| Airflow image | apache/airflow:3.1.7 | Custom with pymssql + azure-identity + azure-keyvault-secrets |
| Git cache | ReadWriteOnce | ReadWriteMany |
| Network | localhost | VNet + private endpoints + private DNS zones |
| Node type | Docker Desktop | Standard_D2s_v3 (2 vCPU, 8 GB RAM) |
| Cost | Free | ~$233-310/month (AKS + VMs + PostgreSQL Flex + Azure SQL + storage) |

## Cost Breakdown (Approximate)

| Resource | SKU | Monthly Cost |
|----------|-----|-------------|
| AKS cluster | Free tier (control plane) | $0 |
| 3x Standard_D2s_v3 nodes | 2 vCPU, 8 GB RAM each | ~$150 |
| PostgreSQL Flexible Server | Standard_B1ms (Burstable) | ~$25 |
| Azure SQL Database | S1 (20 DTUs) | ~$30 |
| Azure Files NFS | Premium, ~50 GB | ~$20 |
| Azure Key Vault | Standard | ~$1 |
| Private DNS zones | 2 zones | ~$2 |
| Managed Identity | Free | $0 |
| Bandwidth | Minimal for setup | ~$5 |
| **Total** | | **~$233-310** |

**Cost savings tips:**
- Use `Standard_B2s` Burstable VMs for dev/test -- saves ~$100/month
- Scale down to 1-2 nodes when not actively testing
- Stop the AKS cluster when not in use: `az aks stop --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME`
- Resume: `az aks start --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME`
