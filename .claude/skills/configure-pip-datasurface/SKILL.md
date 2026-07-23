---
name: configure-pip-datasurface
description: Configure authenticated pip access to the DataSurface GitLab package registry. Use when a local demo1 environment or CI job needs safe, repeatable package installation.
---

# Configure pip for DataSurface

Use deploy-token credentials:

```bash
export DATASURFACE_USER="<deploy-token-username>"
export DATASURFACE_TOKEN="<deploy-token-value>"
```

Never commit an authenticated package URL. The username and token must be URL-encoded before they
are placed in a URL; shell interpolation alone does not encode special characters.

## Recommended: per-process environment

Build the URL without echoing it:

```bash
export PIP_EXTRA_INDEX_URL=$(
  DATASURFACE_USER="$DATASURFACE_USER" DATASURFACE_TOKEN="$DATASURFACE_TOKEN" \
  python3 -c \
  'import os; from urllib.parse import quote; print("https://" + quote(os.environ["DATASURFACE_USER"], safe="") + ":" + quote(os.environ["DATASURFACE_TOKEN"], safe="") + "@gitlab.com/api/v4/projects/77796931/packages/pypi/simple")'
)
```

Install the repository's pin:

```bash
python -m pip install -r requirements.txt
unset PIP_EXTRA_INDEX_URL
```

Use `PIP_EXTRA_INDEX_URL` so public dependencies still resolve from pip's primary index. Do not
use an authenticated URL as the only `index-url` unless the private registry mirrors every public
dependency.

## CI

Store `DATASURFACE_USER` and `DATASURFACE_TOKEN` in the CI system's protected secret store. Build
`PIP_EXTRA_INDEX_URL` at runtime using the same encoding snippet, install, then unset it. Disable
shell tracing for that step and do not run `pip config list`, which may print the authenticated
URL.

## Optional persistent configuration

Persistent pip configuration stores the token in plaintext. Use it only on a single-user
development machine after explicit approval:

```bash
python -m pip config --user set global.extra-index-url "$PIP_EXTRA_INDEX_URL"
chmod 600 "${PIP_CONFIG_FILE:-$HOME/.config/pip/pip.conf}" 2>/dev/null || true
```

The actual user config path varies by platform; inspect it with `python -m pip config debug`
without sharing the output. Remove only the DataSurface setting:

```bash
python -m pip config --user unset global.extra-index-url
```

## Verify without exposing credentials

```bash
python -m pip index versions datasurface >/dev/null
python -m pip show datasurface
```

On `401 Unauthorized`, check token scope/expiry and rebuild the encoded URL. On package-not-found,
confirm project `77796931`, the requested version, and Python compatibility. Never paste the
authenticated URL into logs or an issue.
