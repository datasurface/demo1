---
name: setup-k8s-registry-secret
description: Configure a namespace to pull DataSurface images from the GitLab container registry. Use while setting up or repairing local, AWS, or Azure demo1 image pulls.
---
# Setup Kubernetes Registry Secret

Configure your Kubernetes cluster to pull DataSurface Docker images from the GitLab container registry.

## Prerequisites

- `kubectl` configured and connected to your cluster
- Kubernetes namespace created
- GitLab registry credentials:
  - `GITLAB_CUSTOMER_USER` - Your deploy token username
  - `GITLAB_CUSTOMER_TOKEN` - Your deploy token value

## Steps

### 1. Set Environment Variables

```bash
export NAMESPACE="demo1"
export GITLAB_CUSTOMER_USER="your-deploy-token-username"
export GITLAB_CUSTOMER_TOKEN="your-deploy-token"
```

### 2. Create or rotate the Docker Registry Secret

```bash
kubectl create secret docker-registry datasurface-registry \
  --namespace "$NAMESPACE" \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

### 3. Attach Secret to Default Service Account

This allows all pods in the namespace to use the secret automatically:

```bash
kubectl patch serviceaccount default -n "$NAMESPACE" \
  -p '{"imagePullSecrets": [{"name": "datasurface-registry"}]}'
```

Expected output:

```text
serviceaccount/default patched
```

### 4. Verify Configuration

```bash
# Check secret exists
kubectl get secret datasurface-registry -n "$NAMESPACE"

# Verify service account has imagePullSecrets
kubectl get sa default -n "$NAMESPACE" \
  -o jsonpath='{.imagePullSecrets[*].name}{"\n"}'
```

Expected output:

```text
imagePullSecrets:
- name: datasurface-registry
```

## Using in Pod Specs

If not using the default service account, reference the secret directly:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: datasurface-pod
  namespace: demo1
spec:
  imagePullSecrets:
    - name: datasurface-registry
  containers:
    - name: datasurface
      image: registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.8.4
```

## Using in Helm Charts

Add to your Helm values:

```yaml
imagePullSecrets:
  - name: datasurface-registry

image:
  repository: registry.gitlab.com/datasurface-inc/datasurface/datasurface
  tag: v1.8.4
```

## Updating the Secret

Repeat Step 2. The apply pattern rotates the Secret without a delete window. Restart only pods
that are currently failing to pull; healthy running containers do not need a registry credential
until their next image pull.

## Troubleshooting

### ImagePullBackOff

If pods show `ImagePullBackOff`:

```bash
# Check pod events
kubectl describe pod <pod-name> -n "$NAMESPACE" | sed -n '/Events:/,$p'

# Verify secret exists
kubectl get secret datasurface-registry -n "$NAMESPACE"

# Verify service account configuration
kubectl get sa default -n "$NAMESPACE" -o yaml
```

### Secret Not Found in Pod

Ensure the pod is using the default service account, or explicitly reference the secret:

```yaml
spec:
  imagePullSecrets:
    - name: datasurface-registry
```

### Invalid Credentials

Test credentials locally first:

```bash
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
```

If local login fails, the credentials are invalid.
