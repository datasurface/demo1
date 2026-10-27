---
name: pull-datasurface-image
description: Authenticate to the GitLab container registry and pull a pinned DataSurface image. Use before local validation, bootstrap generation, or an image upgrade.
---
# Pull DataSurface Docker Image

Get the DataSurface runtime image onto your local machine. There are two sources:

- **Option A (default): pre-built image.** Pull the DataSurface release image from the GitLab
  container registry with your deploy token (the rest of this skill).
- **Option B: build your own.** Build with `datasurface_image_builder` on your approved base image
  and push to your own registry; skip the login/pull below. See "Option B" at the end.

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
export DATASURFACE_VERSION="1.40.6"
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
registry.gitlab.com/datasurface-inc/datasurface/datasurface   v1.40.6  abc123def456   2 days ago   1.2GB
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
export DATASURFACE_VERSION="1.40.6"
```

### Pulling Latest Version

To get the most recent image after a fix:

```bash
# Docker checks the registry and updates the local tag when needed.
docker pull --platform linux/amd64 registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

## Option B: build your own image

Use this instead of the pull above when policy requires your own base image or registry. It needs
only the read-only GitLab package token (no DataSurface registry access).

```bash
git clone https://github.com/datasurface/datasurface_image_builder.git
cd datasurface_image_builder
export DATASURFACE_VERSION="1.40.6"
export BASE_IMAGE="registry.customer.example/approved/python-java:3.12-25"
export GITLAB_PACKAGE_TOKEN="<read-only-package-token>"   # never echo or commit
export IMAGE_NAME="registry.customer.example/data-platform/datasurface"
export IMAGE_TAG="${DATASURFACE_VERSION}-company.1"
./build-image.sh
```

Push with `docker login <your registry>`, `PLATFORMS=linux/amd64`, `PUSH_IMAGE=true`, then re-run
`./build-image.sh`. The finished image must meet the DataSurface image contract (non-root uid/gid
1000, `git` on `PATH`, ODBC drivers, writable `HOME` and `/tmp`). Set `datasurfaceDockerImage` in
`rte_*.py`, the CI validator image, and the pull secret to your registry and tag.
