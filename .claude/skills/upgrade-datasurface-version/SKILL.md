---
name: upgrade-datasurface-version
description: Upgrade the DataSurface package and runtime image on an existing demo1 environment. Use when bumping DataSurface, regenerating bootstrap artifacts, publishing a new model release, and rolling local, AWS, or Azure workloads safely.
---

# Upgrade DataSurface

Treat the package, model image pins, CI validators, generated artifacts, and published model
release as one versioned change. Do not patch running pods with `kubectl set image`; generated
infrastructure is authoritative.

Read `generate-bootstrap/SKILL.md` and `edit-model-fragment/SKILL.md` before starting.

## 1. Confirm the target

```bash
export DATASURFACE_VERSION="<target-version>"
export IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}"

printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 "$IMAGE"
docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}'
```

Do not update the repository until the exact tag can be pulled.

## 2. Move all repository pins together

Search first:

```bash
rg -n 'datasurface==|datasurfaceDockerImage|datasurface/datasurface:v' \
  requirements.txt rte_*.py .github .gitlab-ci.yml
```

Update:

- `requirements.txt`;
- `datasurfaceDockerImage` in every deployed `rte_*.py`;
- `.github/workflows/pull-request.yml`;
- `.gitlab-ci.yml`, when GitLab CI is used.

Do not change the Airflow image merely because the DataSurface version changed. Airflow has its
own tested tag and should move only when the release requires it.

Confirm the pins agree:

```bash
rg -n 'datasurface==|datasurfaceDockerImage|datasurface/datasurface:v' \
  requirements.txt rte_*.py .github .gitlab-ci.yml
```

## 3. Validate before publishing

Validate with the demo1 virtual environment:

```bash
.venv/bin/python -m unittest test_loads
git diff --check
```

The `.venv` created from the pinned `requirements.txt` runs `test_loads` under `unittest`
(no extra test dependencies required). Fix model construction or lint errors before pushing.

Render each RTE that is actually deployed with the target image:

```bash
docker run --rm --platform linux/amd64 \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  "$IMAGE" \
  python -m datasurface.entrypoints.platform generatePlatformBootstrap \
    --ringLevel 0 \
    --model /workspace/model \
    --output /workspace/model/generated_output \
    --psp Demo_PSP \
    --rte-name demo
```

For cloud variants, configure `eco.py` to import `rte_aws` or `rte_azure` and render again with
`--rte-name demo`; demo1 uses the same runtime declaration name for every provider.

## 4. Publish the model

Use the normal PR flow. After the change reaches `main`, create the next monotonically newer
`vN.N.N-demo` tag and a stable, non-draft GitHub Release for it. The model release number is
independent of the DataSurface package version.

Do not generate production bootstrap artifacts from uncommitted changes, delete old releases, or
move an existing tag.

## 5. Regenerate and deploy

Follow `generate-bootstrap/SKILL.md` in full with the target image and the environment's actual
RTE. It will:

1. regenerate only the selected PSP output;
2. require the current four ring-0 artifacts;
3. publish every generated `*_dag.py`;
4. apply `kubernetes-bootstrap.yaml`;
5. recreate and wait for ring 1;
6. trigger `demo-psp_infrastructure`.

Current versions do not generate `demo_psp_model_merge_job.yaml`. Model merge runs within the
infrastructure DAG.

## 6. Verify the rollout

Check image digests on live pods, not tags alone:

```bash
kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[*].imageID}{"\n"}{end}'
```

Then verify:

```bash
kubectl get jobs -n "$NAMESPACE"
kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning --sort-by=.lastTimestamp

kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
```

Require a completed ring-1 Job, no DAG import errors, a successful new infrastructure run, and
healthy model-derived DAGs. Use `check-system-health` and `verify-data-fidelity` before declaring
the upgrade complete.

Report the old and new versions, model release, registry digest, environments rendered,
infrastructure run status, live pod image IDs, and any test or verification that could not run.
