---
name: teardown-walkthrough-azure
description: Safely tear down a demo1 Azure AKS environment and verify cost-bearing resources are gone. Use when removing an Azure demo1 deployment; remove optional Key Vault or ESO state only when configured.
---

# Azure AKS teardown

This procedure is destructive. Confirm the exact subscription, resource group, cluster, and
namespace before deleting anything. The `demo1` starter uses namespace-local Kubernetes Secrets by
default and does not require Key Vault cleanup.

## Preflight and authorization

```bash
RESOURCE_GROUP=<resource-group>
CLUSTER_NAME=<aks-name>
NAMESPACE=<namespace>

az account show --query '{subscription:id,tenant:tenantId,user:user.name}' -o table
az group show --name "$RESOURCE_GROUP" \
  --query '{name:name,location:location,id:id}' -o table
az resource list --resource-group "$RESOURCE_GROUP" \
  --query '[].{name:name,type:type,location:location}' -o table
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" --overwrite-existing
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

If the namespace remains `Terminating`, inspect resources and finalizers:

```bash
kubectl get all,pvc -n "$NAMESPACE"
kubectl get namespace "$NAMESPACE" -o yaml
```

Force-removing finalizers can orphan Azure disks/files. Use it only after the responsible
controllers have had a chance to clean up and the remaining targets are understood.

Namespace deletion removes the starter's Git, merge, DAG-sync, and registry Secrets.

## 2. Optional ESO/Key Vault cleanup

Skip this section when `rte_azure.py` used `externalSecretProvider=None`.

If the customer enabled ESO, identify the exact Key Vault and only this environment's keys:

```bash
KEY_VAULT_NAME=<vault-name>
PREFIX="datasurface--${NAMESPACE}--demo--"
az keyvault secret list --vault-name "$KEY_VAULT_NAME" \
  --query "[?starts_with(name, '${PREFIX}')].name" -o tsv
```

Delete only confirmed names under the exact prefix. Key Vault soft-delete makes deletion
recoverable; do not purge unless immediate, irreversible removal was explicitly requested.

If External Secrets Operator is shared, leave it installed. Delete a dedicated operator release
or managed identity only after checking other `ExternalSecret` and `SecretStore` users.

## 3. Delete the resource group

Review one last time:

```bash
az resource list --resource-group "$RESOURCE_GROUP" \
  --query '[].{name:name,type:type}' -o table
```

Then:

```bash
az group delete --name "$RESOURCE_GROUP" --yes
```

Wait until it is gone:

```bash
while az group exists --name "$RESOURCE_GROUP" | grep -q true; do
  sleep 15
done
```

Do not start recreating the same names until deletion has completed.

## 4. Optional Key Vault purge

If the vault belonged exclusively to the deleted resource group, it may remain soft-deleted:

```bash
az keyvault list-deleted \
  --query "[?name=='${KEY_VAULT_NAME}'].{name:name,location:properties.location}" -o table
```

Preserve it for recovery by default. Purge only when the user explicitly wants irreversible
removal or immediate name reuse:

```bash
export AZURE_REGION=$(az keyvault list-deleted \
  --query "[?name=='${KEY_VAULT_NAME}'].properties.location | [0]" -o tsv)
az keyvault purge --name "$KEY_VAULT_NAME" --location "$AZURE_REGION"
```

## 5. Verify cost-bearing resources are gone

```bash
az group exists --name "$RESOURCE_GROUP"
az aks list --query "[?resourceGroup=='${RESOURCE_GROUP}'].{name:name,state:powerState.code}" -o table
az postgres flexible-server list \
  --query "[?resourceGroup=='${RESOURCE_GROUP}'].{name:name,state:state}" -o table
az sql server list \
  --query "[?resourceGroup=='${RESOURCE_GROUP}'].{name:name,state:state}" -o table
az network public-ip list \
  --query "[?resourceGroup=='${RESOURCE_GROUP}'].{name:name,ip:ipAddress}" -o table
az disk list \
  --query "[?resourceGroup=='${RESOURCE_GROUP}'].{name:name,state:diskState}" -o table
```

Also inspect the AKS node resource group if it still exists; Azure normally deletes it with the
cluster. Check for orphaned private endpoints, public IPs, disks, snapshots, and Log Analytics
workspaces tagged for this environment.

Model and DAG repositories, tags, and releases are not infrastructure teardown targets. Preserve
them unless the user separately requests repository cleanup.
