---
name: install-datasurface-python
description: Install the pinned DataSurface Python package from the GitLab package registry. Use when preparing a local demo1 development, lint, or validation environment.
---

# Install DataSurface

Use Python 3.12 or newer and an isolated virtual environment:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
```

Read `configure-pip-datasurface` and create the URL-encoded `PIP_EXTRA_INDEX_URL` from protected
`DATASURFACE_USER` and `DATASURFACE_TOKEN` variables. Do not pass a raw token in a command-line URL.

Install the repository pin:

```bash
python -m pip install -r requirements.txt
unset PIP_EXTRA_INDEX_URL
```

For this revision, `requirements.txt` pins:

```text
datasurface==1.8.4
```

Do not install an unpinned “latest” release while validating demo1; the package, runtime image,
and CI validator versions must agree.

Verify:

```bash
python -m pip show datasurface
python -c 'from importlib.metadata import version; print(version("datasurface"))'
python -m unittest test_loads
```

DB2 support is AMD64-only:

```bash
export PIP_EXTRA_INDEX_URL="<rebuild with configure-pip-datasurface>"
python -m pip install "datasurface[db2]==1.8.4"
unset PIP_EXTRA_INDEX_URL
```

On authentication failure, rotate or correct the deploy token. On package-not-found, confirm
project `77796931`, the exact pin, and the Python version. Do not log `pip config` output or an
authenticated index URL.
