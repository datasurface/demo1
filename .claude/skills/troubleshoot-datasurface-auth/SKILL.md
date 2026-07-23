---
name: troubleshoot-datasurface-auth
description: Diagnose authentication failures for DataSurface GitLab container and Python package registries. Use when docker pull, bootstrap generation, CI validation, Kubernetes image pulls, or pip installation is denied.
---

# Troubleshoot DataSurface registry authentication

Do not print tokens, authenticated URLs, Docker config, decoded Kubernetes Secrets, or shell
traces. Diagnose the failing layer independently.

## Container registry

Authenticate safely:

```bash
printf '%s' "$GITLAB_CUSTOMER_TOKEN" |
  docker login registry.gitlab.com \
    --username "$GITLAB_CUSTOMER_USER" --password-stdin
```

Then request the exact tested image:

```bash
export IMAGE="registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.8.4"
docker pull --platform linux/amd64 "$IMAGE"
docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}'
```

- `denied` or `401`: token expired, wrong username, or missing registry-read scope;
- `manifest unknown`: authentication worked but the tag/path is wrong;
- architecture warning: keep `--platform linux/amd64` for the current published image.

Log out after testing on a shared machine:

```bash
docker logout registry.gitlab.com
```

## Python package registry

Use `configure-pip-datasurface` to URL-encode the deploy-token username/token into a temporary
`PIP_EXTRA_INDEX_URL`. Raw string interpolation does not safely encode `@`, `:`, `/`, or other
reserved characters.

```bash
python -m pip index versions datasurface >/dev/null
python -m pip install "datasurface==1.8.4"
unset PIP_EXTRA_INDEX_URL
```

- `401`: bad/expired token or missing package-registry read scope;
- no matching distribution: verify Python 3.12+, project `77796931`, platform, and exact version;
- TLS error: fix the machine trust store; do not bypass certificate verification.

Do not run or share `pip config list` when it contains an authenticated URL.

## Kubernetes ImagePullBackOff

First determine whether the pod references the right image and pull Secret:

```bash
kubectl describe pod "<pod-name>" -n "$NAMESPACE" |
  sed -n '/Events:/,$p'
kubectl get pod "<pod-name>" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[*].image}{"\n"}{.spec.imagePullSecrets[*].name}{"\n"}'
kubectl get serviceaccount default -n "$NAMESPACE" \
  -o jsonpath='{.imagePullSecrets[*].name}{"\n"}'
kubectl get secret datasurface-registry -n "$NAMESPACE"
```

Reapply the Secret without a delete window:

```bash
kubectl create secret docker-registry datasurface-registry \
  --namespace "$NAMESPACE" \
  --docker-server=registry.gitlab.com \
  --docker-username="$GITLAB_CUSTOMER_USER" \
  --docker-password="$GITLAB_CUSTOMER_TOKEN" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl patch serviceaccount default -n "$NAMESPACE" \
  -p '{"imagePullSecrets":[{"name":"datasurface-registry"}]}'
```

Delete only a known failed pod after the Secret is fixed; its owning controller will recreate it.
Do not restart unrelated healthy workloads.

## CI validation

The checked-in workflows expect:

- GitHub: `GITLAB_USERNAME`, `GITLAB_ACCESS_TOKEN`;
- GitLab: `GITLAB_USERNAME`, `GITLAB_ACCESS_TOKEN` plus the repository token used by that runner.

They run the `v1.8.4` validator with:

```text
python -m datasurface.entrypoints.action
```

Confirm secret names and protected-branch/fork availability in the CI UI. Never add a secret to
workflow YAML or print it for debugging.

Report which layer failed, the redacted error category/status, the exact image/package version,
the corrective action, and the successful retry. Escalate token renewal to the issuer without
sharing the token itself.
