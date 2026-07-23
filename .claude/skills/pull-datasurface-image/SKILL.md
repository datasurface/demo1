---
name: pull-datasurface-image
description: Authenticate to the GitLab container registry and pull a pinned DataSurface image. Use before local validation, bootstrap generation, or an image upgrade.
---
# Pull DataSurface Docker Image

Pull DataSurface Docker images from the GitLab container registry to your local machine.

## Prerequisites

You need GitLab registry credentials:

- `GITLAB_CUSTOMER_USER` - Your deploy token username
- `GITLAB_CUSTOMER_TOKEN` - Your deploy token value

## Available Images

| Image | Description |
|-------|-------------|
| `datasurface` | Core DataSurface image |
| `datasurface-dbt` | DataSurface with dbt support |

## Steps

### 1. Set Environment Variables

```bash
export GITLAB_CUSTOMER_USER="your-deploy-token-username"
export GITLAB_CUSTOMER_TOKEN="your-deploy-token"
export DATASURFACE_VERSION="1.8.4"
```

### 2. Login to GitLab Registry

```bash
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
```

Expected output:

```text
Login Succeeded
```

### 3. Pull the Image

**Core image:**

```bash
docker pull --platform linux/amd64 registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

**With dbt support:**

```bash
docker pull --platform linux/amd64 registry.gitlab.com/datasurface-inc/datasurface/datasurface-dbt:v${DATASURFACE_VERSION}
```

### 4. Verify the Image

```bash
docker images | grep datasurface
```

Expected output:

```text
registry.gitlab.com/datasurface-inc/datasurface/datasurface   v1.8.4   abc123def456   2 days ago   1.2GB
```

## Quick One-Liner

```bash
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

## Troubleshooting

### Authentication Failed

```text
Error response from daemon: Get "https://registry.gitlab.com/v2/": denied: access forbidden
```

**Solution:** Verify credentials are correct:

Re-run login with `--password-stdin`. If it still fails, confirm the deploy token is active and has
container-registry read access without printing any part of the token.

### Image Not Found

```text
Error response from daemon: manifest for ... not found
```

**Solution:** Check available versions or verify the version number:

```bash
# Use the repository's tested version
export DATASURFACE_VERSION="1.8.4"
```

### Pulling Latest Version

To get the most recent image after a fix:

```bash
# Docker checks the registry and updates the local tag when needed.
docker pull --platform linux/amd64 registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```
