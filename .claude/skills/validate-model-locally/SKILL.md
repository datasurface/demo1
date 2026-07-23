---
name: Validate Model Locally
description: Lint and validate the DataSurface model locally in seconds, before pushing. Use when the user asks to "validate my model", "lint the model", "check my model before I push", "did my model change break anything", or "will this pass CI".
---
# Validate Model Locally

`edit-model-fragment` pushes to create a PR where DataSurface validates the model — but that round trip takes minutes. Run the same validation locally first; catching DSL/lint errors this way is seconds, not minutes. Do this before every push.

## Prereq

The `datasurface` package must be installed locally (matching the version in `requirements.txt`). If `import datasurface` fails, see `install-datasurface-python` / `configure-pip-datasurface` first.

## Step 1: Quick lint one-liner

Run from the repo root:

```bash
python -c "
from datasurface.model import loadEcosystemFromEcoModule
eco, tree = loadEcosystemFromEcoModule('.', 'demo')  # 2nd arg = RTE name: demo, aws, or azure
if tree is None or eco is None:
    print('MODEL FAILED TO LOAD')
    raise SystemExit(1)
if tree.hasErrors():
    print('MODEL HAS ERRORS -- fix before pushing:')
    tree.printTree()
    raise SystemExit(1)
if tree.hasWarnings():
    print('lint OK with warnings:')
    tree.printTree()
else:
    print('lint OK -- model is valid')
"
```

Swap the second argument for the RTE you changed: `demo`, `aws`, or `azure` (see `rte_demo.py` / `rte_aws.py` / `rte_azure.py`). Omit the second argument (call with just `'.'`) to load the top-level Ecosystem only, without hydrating a specific RTE's platform graph — useful for a fast syntax-only check.

## Step 2: Run the repo's own test as the fuller check

```bash
python -m unittest test_loads
```

`test_loads.py` loads the ecosystem twice (once bare, once against the `demo` RTE), calls `ecosys.lintAndHydrateCaches()`, and asserts no errors in the resulting `ValidationTree`. This is the same check CI runs on PR validation, so a green `test_loads.py` locally should mean a green PR check — barring branch/permission issues on the CI side.

## Step 3: Reading the validation tree

`tree.printTree()` prints a nested tree of `Problem` entries by severity:
- **ERROR** — blocks the merge. Must be fixed before pushing.
- **WARNING** — does not block, but review it; it often points at a real gap (e.g. missing collation).

Each entry shows the object path in the model where the problem was found (e.g. `Ecosystem/Team_X/DataStore_Y/Dataset_Z`). Go to that object in the `.py` fragment that defines it — usually the datastore/workspace/dataset file the customer team owns, not `eco.py` itself.

## Common errors and fixes

| Error looks like | Cause | Fix |
|---|---|---|
| `GIT_REPO_OWNER` / `GIT_REPO_NAME` placeholder still set | Template repo vars never filled in | Set them in the repo config / model source — see `setup-walkthrough` |
| Datastore references a container with no location | A `DataContainer` used by a datastore isn't registered with a `Location`/`RTE` | Add the container to the RTE's platform in `rte_*.py` |
| "Backwards-incompatible schema change" | A dataset column type/nullability changed in a way existing merge data can't absorb | Add a new column instead of mutating, or bump the schema version per the model's compat rules |
| DataTransformer attached to an SCD1 platform | DataTransformers require SCD-with-history (e.g. SCD4); lint rejects them on SCD1 | Move the DataTransformer's workspace to run against the SCD4 platform — see `wire-datatransformer-model` |
| Dangling reference (workspace/DSG points at a dataset that doesn't exist) | Typo in a dataset/datastore name, or the referenced object was renamed/removed elsewhere | Fix the name, or add the missing object |

For anything not in this table, read the `Problem` message text closely — it names the object and the specific constraint violated.

## When it's green

Once both the one-liner and `python -m unittest test_loads` pass, proceed to `edit-model-fragment` to commit and push. CI runs the same validation path, so a locally-green model should pass CI (barring branch protection or permission issues unrelated to model content).
