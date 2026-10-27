# DataSurface Artifacts

This starter is pinned to DataSurface **1.40.6** (`requirements.txt`; `DATASURFACE_VERSION` in `rte_*.py`).
Set `DATASURFACE_VERSION=1.40.6` for the commands below.

## Container image: two options

Jobs and Airflow pods need a DataSurface runtime image. You choose how to get it. The model
(`rte_*.py` -> `datasurfaceDockerImage`, pinned to `1.40.6` here) and the CI validators only need
the final image reference.

### Option A: pre-built DataSurface image (this starter's default)

Use the image DataSurface builds and validates for each release (the "release image"). It is
pulled from the DataSurface GitLab container registry with a read-only deploy token that
DataSurface gives you.

- **Username**: your deploy token username (e.g., `customer-acme`)
- **Token**: your deploy token value
- **Project ID**: `77796931`

| Image | Description |
| ----- | ----------- |
| `registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}` | Core DataSurface image |
| `registry.gitlab.com/datasurface-inc/datasurface/datasurface-dbt:v${DATASURFACE_VERSION}` | DataSurface with dbt support |

```bash
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

### Option B: build your own image

Build the image yourself from the versioned `datasurface` PyPI/Maven packages with the public
[`datasurface_image_builder`](https://github.com/datasurface/datasurface_image_builder), on your
own approved base image, and push it to your own container registry. Use this when policy
requires images to derive from an approved corporate base, or to keep image pulls inside your own
registry. DataSurface's documentation describes its published images as build-validation
artifacts, not a required customer dependency, so building your own is a supported path.

```bash
git clone https://github.com/datasurface/datasurface_image_builder.git
cd datasurface_image_builder

export DATASURFACE_VERSION="1.40.6"
export BASE_IMAGE="registry.customer.example/approved/python-java:3.12-25"
export GITLAB_PACKAGE_TOKEN="<read-only-package-token>"
export IMAGE_NAME="registry.customer.example/data-platform/datasurface"
export IMAGE_TAG="${DATASURFACE_VERSION}-company.1"

./build-image.sh   # set PUSH_IMAGE=true (and docker login to your registry) to push
```

- The build needs only the read-only GitLab package token (the same credential as the Python
  module below). It does not need DataSurface container-registry access.
- Your finished image must meet the DataSurface image contract (Yellow Operations Guide, "DataSurface
  image contract"): runs as non-root uid/gid 1000 by default, a `git` binary on `PATH`, unixODBC and
  Microsoft ODBC Driver 18 for SQL Server, Java 25 for Java DataTransformers, and the IBM i Access
  ODBC driver (amd64) for DB2 for i.
- Then point the model at it: set `datasurfaceDockerImage` in your `rte_*.py` (replace the
  `registry.gitlab.com/...` string; keep the tag in step with `requirements.txt`), the image in
  `.github/workflows/pull-request.yml` / `.gitlab-ci.yml`, and create the Kubernetes pull secret
  for your registry instead of `registry.gitlab.com` (`/setup-k8s-registry-secret`).

For Kubernetes configuration and image handling, use the Claude Code skills:

- `/pull-datasurface-image` - Pull the pre-built image (Option A) or build your own (Option B)
- `/setup-k8s-registry-secret` - Configure Kubernetes image pull secrets for either registry
- `/troubleshoot-datasurface-auth` - Debug authentication failures

## Python Module

- **PyPI URL**: `https://gitlab.com/api/v4/projects/77796931/packages/pypi/simple`
- **Python**: >= 3.12 (required by sqlserver and snowflake dependencies)
- **Optional extras**: `datasurface[db2]` for DB2 support (AMD64 only)

For installation and pip configuration, use the Claude Code skills:

- `/install-datasurface-python` — Install the DataSurface Python package
- `/configure-pip-datasurface` — Set up persistent pip.conf

## Security Notes

- Do not commit tokens to version control
- Use environment variables or secrets management in CI/CD
- Rotate tokens periodically
- Report any suspected token compromise immediately
