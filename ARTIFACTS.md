# DataSurface Artifacts

## Credentials

You will receive the following from DataSurface:

- **Username**: Your deploy token username (e.g., `customer-acme`)
- **Token**: Your deploy token value
- **Project ID**: `77796931`

## Docker Images

| Image | Description |
| ----- | ----------- |
| `registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}` | Core DataSurface image |
| `registry.gitlab.com/datasurface-inc/datasurface/datasurface-dbt:v${DATASURFACE_VERSION}` | DataSurface with dbt support |

```bash
docker login registry.gitlab.com -u <username> -p <token>
docker pull registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

For Kubernetes configuration, use the Claude Code skills:

- `/pull-datasurface-image` — Pull images to your local machine
- `/setup-k8s-registry-secret` — Configure Kubernetes image pull secrets
- `/troubleshoot-datasurface-auth` — Debug authentication failures

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
