---
name: troubleshoot-k8s-jobs
description: Diagnose DataSurface Yellow Kubernetes Job and Airflow KubernetesPodOperator failures. Use for ring-1 initialization, reconcile-views, infrastructure/model-merge pods, image pulls, credentials, databases, Git access, or immutable Job reruns.
---

# Troubleshoot Yellow Kubernetes work

Current bootstrap output has ring-1 and reconcile-views Job manifests. Model merge is no longer a
standalone Job; it runs as tasks in `demo-psp_infrastructure`.

## Capture state first

```bash
export NAMESPACE="${NAMESPACE:-demo1}"

kubectl get jobs,pods -n "$NAMESPACE" -o wide
kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning --sort-by=.lastTimestamp
kubectl describe job demo-psp-ring1-init -n "$NAMESPACE"
kubectl logs job/demo-psp-ring1-init -n "$NAMESPACE" --all-containers --tail=200
```

For infrastructure/model-merge failures, inspect Airflow rather than looking for a
`demo-psp-model-merge-job`:

```bash
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-runs demo-psp_infrastructure --output json
kubectl exec -n "$NAMESPACE" airflow-scheduler-0 -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow dags list-import-errors --output json
```

Use the Airflow UI task log or identify the KubernetesPodOperator pod by run/task labels:

```bash
kubectl get pods -n "$NAMESPACE" --show-labels |
  rg 'infrastructure|ring1|reconcile'
kubectl logs -n "$NAMESPACE" "<pod-name>" --all-containers --tail=200
kubectl describe pod -n "$NAMESPACE" "<pod-name>"
```

## Credential failures

The default local, AWS, and Azure configurations use administrator-managed Kubernetes Secrets.
Confirm names and keys without decoding values:

```bash
kubectl get secrets -n "$NAMESPACE"
kubectl describe secret "<secret-name>" -n "$NAMESPACE"
kubectl get pod "<pod-name>" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[*].envFrom[*].secretRef.name}{"\n"}'
```

Use `create-k8-credential` for canonical keys. Do not install or troubleshoot ESO unless the RTE
explicitly configures an external secret provider. For an opt-in ESO deployment, inspect the
`ExternalSecret`, its `SecretStore`/`ClusterSecretStore`, and the operator logs separately.

## Database failures

Read the exact host, port, database, and driver from the selected RTE and Secret. Test DNS and TCP
reachability from a disposable pod:

```bash
kubectl run network-check --rm -it --restart=Never \
  -n "$NAMESPACE" --image=busybox:1.36 -- \
  sh -c 'nslookup "<db-host>" && nc -vz "<db-host>" "<db-port>"'
```

Then check:

- database and schema exist;
- Secret keys match the `CredentialType`;
- network policies, security groups, or firewalls allow pod traffic;
- TLS mode and CA material match the database endpoint;
- Airflow metadata and DataSurface merge databases are not accidentally interchanged.

Never print passwords or decoded Secret content in diagnostics.

## ImagePullBackOff

Inspect the event message and service-account pull secrets:

```bash
kubectl describe pod "<pod-name>" -n "$NAMESPACE" |
  sed -n '/Events:/,$p'
kubectl get serviceaccount default -n "$NAMESPACE" -o yaml
kubectl get secret datasurface-registry -n "$NAMESPACE"
```

Recreate the registry Secret with `setup-k8s-registry-secret` when authentication is wrong.
Confirm the exact pinned image exists:

```bash
export IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.8.4"
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
docker pull --platform linux/amd64 "$IMAGE"
```

## CreateContainerConfigError

This usually means a referenced Secret, ConfigMap, PVC, or service account is absent:

```bash
kubectl describe pod "<pod-name>" -n "$NAMESPACE" |
  sed -n '/Events:/,$p'
kubectl get secret,configmap,pvc,serviceaccount -n "$NAMESPACE"
```

Fix the missing dependency at its declared source. Do not hand-edit the pod; it will be recreated.

## Git loader failures

Check only repository identity and Secret key names:

```bash
kubectl describe secret git -n "$NAMESPACE"
kubectl get pvc -n "$NAMESPACE"
kubectl logs -n "$NAMESPACE" "<pod-name>" --all-containers --tail=200 |
  rg -i 'git|release|tag|clone|credential'
```

Confirm a stable, non-draft `vN.N.N-demo` GitHub Release exists and is newer than previous model
releases. Do not delete release history to force selection.

## Rerun safely

Kubernetes Job pod templates are immutable. Delete only the known failed/completed Job, then
reapply its freshly generated manifest:

```bash
kubectl delete job demo-psp-ring1-init \
  -n "$NAMESPACE" --ignore-not-found --wait=true
kubectl apply -f generated_output/Demo_PSP/demo_psp_ring1_init_job.yaml
kubectl wait --for=condition=complete \
  job/demo-psp-ring1-init -n "$NAMESPACE" --timeout=300s
kubectl logs job/demo-psp-ring1-init -n "$NAMESPACE" --all-containers --tail=200
```

Rerun model merge by triggering `demo-psp_infrastructure`, not by applying a retired manifest.

Before reporting success, require the relevant Job or DAG run to succeed, warnings to be
understood, pods to be Ready, and downstream DAGs to appear without import errors. Include the
failing resource, reason/event, safe fix, rerun result, and any verification that could not run.
