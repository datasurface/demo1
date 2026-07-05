---
name: Upgrade DataSurface Version
description: Upgrade the DataSurface runtime image on an already-running environment to a new version. Use when the user says "upgrade DataSurface", "new DataSurface version", "bump the image", "update the runtime", or "upgrade to vX.Y.Z". Covers bumping the pin, regenerating bootstrap DAGs/jobs, and redeploying safely.
---
# Upgrade DataSurface Version

Use this skill when moving a running DataSurface Yellow environment to a new runtime image version. This is **not** just a tag bump: the bootstrap DAG templates, job specs, and pod-naming conventions ship *inside* the image and can change between versions, so the ring-0/bootstrap artifacts must be regenerated with the new image and redeployed — a plain image swap without regeneration leaves stale generated DAGs/jobs behind.

## IMPORTANT: Execution Rules

- This changes a **running environment**. Do not patch the live cluster directly with ad-hoc `kubectl edit`/`kubectl set image` commands — the infra reconciler will revert local patches back to whatever the model/generated artifacts say.
- Take the version bump through the **normal PR flow**: edit the model pin, validate locally, push via `edit-model-fragment` so it lands on `main` and gets tagged, then regenerate and redeploy from the new tagged release.
- Regenerate bootstrap **every time**, even for a patch version bump. Skipping regeneration is the specific mistake this skill exists to prevent.
- Read `.claude/skills/generate-bootstrap/SKILL.md` and `.claude/skills/edit-model-fragment/SKILL.md` before starting — this skill sequences them, it doesn't replace them.

## Step 1: Pick the Target Image Tag

Confirm the target tag exists in the registry before pinning anything to it. See `.claude/skills/pull-datasurface-image/SKILL.md`.

```bash
export DATASURFACE_VERSION="1.4.0"   # target version
docker login registry.gitlab.com -u "$GITLAB_CUSTOMER_USER" -p "$GITLAB_CUSTOMER_TOKEN"
docker pull registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION}
```

## Step 2: Bump the Image Pin in the Model

The pin is the single source of truth for which image every generated job/DAG uses. Find every place it's set:

```bash
grep -rn "datasurfaceDockerImage" rte_*.py
```

Typically this appears in `rte_demo.py` (and `rte_aws.py` / `rte_azure.py` if those RTEs are also in use). Update each one, e.g.:

```python
# Before
datasurfaceDockerImage="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.3.7"
# After
datasurfaceDockerImage="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.4.0"
```

Edit every RTE file that's actually deployed — a partial bump (e.g. `rte_demo.py` updated but `rte_aws.py` left stale) means that RTE keeps running the old image and its bootstrap artifacts won't match the new one.

## Step 3: Validate Locally, Then Push Through the Normal PR Flow

Validate the model imports and constructs cleanly before pushing:

```bash
python -c "from eco import createEcosystem; createEcosystem()"
```

Then push the change via `.claude/skills/edit-model-fragment/SKILL.md` (fresh branch off `main`, commit, push — this opens the PR). Once merged to `main`, tag the release so the loader picks it up (see `.claude/skills/start-initial-ingestion/SKILL.md` for the tag pattern, typically `v*.*.*-demo`):

```bash
git checkout main && git pull origin main
git tag v1.4.0-demo
git push origin v1.4.0-demo
```

Do not skip the PR/tag step and generate bootstrap from a local uncommitted pin — the running infrastructure DAG reads the model from git at a tagged release, not from your working tree.

## Step 4: Regenerate Bootstrap With the New Image

This is the step a plain image bump misses. Dynamically-generated ingestion/CQRS DAGs are rebuilt automatically by the factory DAGs on the next model-merge, but the **bootstrap/infra DAGs and jobs are templates baked into the image** — they only get regenerated when you explicitly re-run ring-0 generation with the new image.

Follow `.claude/skills/generate-bootstrap/SKILL.md` in full, pointed at the new version:

```bash
rm -rf generated_output/

docker run --rm \
  -v "$(pwd)":/workspace/model \
  -w /workspace/model \
  registry.gitlab.com/datasurface-inc/datasurface/datasurface:v${DATASURFACE_VERSION} \
  python -m datasurface.cmd.platform generatePlatformBootstrap \
  --ringLevel 0 \
  --model /workspace/model \
  --output /workspace/model/generated_output \
  --psp Demo_PSP \
  --rte-name demo
```

Diff the new artifacts against the previous ones if you want to see what changed before applying:

```bash
cp -r generated_output/Demo_PSP generated_output/Demo_PSP_old   # save before re-running, if not already done
diff -r generated_output/Demo_PSP_old generated_output/Demo_PSP
```

## Step 5: Redeploy the Regenerated Manifests

```bash
kubectl apply -f generated_output/Demo_PSP/kubernetes-bootstrap.yaml
```

Bootstrap Jobs are immutable in Kubernetes. If a prior completed Job of the same name still exists (older images may lack `ttlSecondsAfterFinished`), `kubectl apply` on the Job manifests will fail — delete the completed Jobs first:

```bash
kubectl delete job demo-psp-ring1-init -n demo1 --ignore-not-found
kubectl delete job demo-psp-model-merge-job -n demo1 --ignore-not-found

kubectl apply -f generated_output/Demo_PSP/demo_psp_ring1_init_job.yaml
kubectl apply -f generated_output/Demo_PSP/demo_psp_model_merge_job.yaml
```

If the infrastructure DAG file changed, copy it to the GitSync repo the same way `generate-bootstrap` describes:

```bash
cp generated_output/Demo_PSP/demo_psp_infrastructure_dag.py /path/to/demo1_airflow/dags/
cd /path/to/demo1_airflow && git add dags/ && git commit -m "Bump to DataSurface v${DATASURFACE_VERSION}" && git push
```

## Step 6: Verify

Confirm pods are actually running the new image (a stale scheduler cache can leave old pods running even after apply):

```bash
kubectl get pods -n demo1 -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[*].image}{"\n"}{end}'
```

Confirm the model-merge job succeeded on the new version:

```bash
kubectl logs -n demo1 job/demo-psp-model-merge-job --tail=50
```

Then confirm DAGs are present, unpaused, and running, and that data still flows correctly — use `.claude/skills/check-system-health/SKILL.md` for throughput/health, and cross-check row counts/fidelity between source, merge, and CQRS the way that skill and `.claude/skills/start-initial-ingestion/SKILL.md` describe.

## Step 7: Version-Skew Notes

Certain upgrades change more than the image tag:

- Generated pod names may gain/lose a hash suffix.
- DAG result signaling may move between mechanisms (e.g. log-parsing vs XCom) — old log-grep-based health checks can silently stop matching.
- Job/DAG control-flow shape (task ordering, task IDs) may change between versions.

A full bootstrap regeneration (Step 4) handles all of these because the new templates are authoritative. If a health check or troubleshooting command elsewhere in this skill set stops matching what you see after an upgrade, suspect a template change before suspecting a bug — compare against the freshly generated artifacts rather than assuming the old command is still correct.

## Report

```
DataSurface Upgrade Report
===========================
From: v<old>  →  To: v<new>
Model pin updated: rte_demo.py [rte_aws.py / rte_azure.py if applicable]
PR merged: <link/commit>   Tag: v<new>-demo

Bootstrap regenerated:   ✅ / ❌
Old jobs deleted+reapplied: ✅ / ❌ / N/A (had TTL)
Infra DAG copied to GitSync: ✅ / ❌ / N/A (unchanged)

Pods on new image:      ✅ <N>/<N>  |  ⚠️ partial  |  ❌ still old
Model-merge job:        ✅ succeeded  |  ❌ failed
DAGs unpaused/running:  ✅ / ⚠️ / ❌
Data flowing (health):  ✅ / ⚠️ / ❌

Issues Found:
  - <issue> → see <skill>
```
