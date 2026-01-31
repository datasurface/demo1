# Introduction

This file details how to setup the project initially.

## Setup PIP

The python module for datasurface is distributed using a private gitlab module repository which you should have been given a username and PAT for. We need to setup pip to use these credentials when installing the project requirements. Edit your ~/.pip/pip.conf file to have the following lines

```ini
[global]
extra-index-url = https://YOUR_USERNAME:YOUR_TOKEN@gitlab.com/api/v4/projects/77796931/packages/pypi/simple
```

## Setup a .venv

```bash

python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
code .
```

You will now be in vscode with the start project open.
