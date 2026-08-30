#!/usr/bin/env bash

set -euo pipefail
umask 077

release_name="${AIRFLOW_RELEASE:-airflow}"
namespace_name="${NAMESPACE:?Set NAMESPACE to the target Airflow namespace}"
values_path="${AIRFLOW_VALUES:?Set AIRFLOW_VALUES to the rendered Helm values file}"
chart_name="${AIRFLOW_CHART:-apache-airflow/airflow}"
chart_version="${AIRFLOW_CHART_VERSION:-1.22.0}"
worker_replicas="${AIRFLOW_WORKER_REPLICAS:-1}"
worker_concurrency="${AIRFLOW_WORKER_CONCURRENCY:-4}"
api_source_secret="${AIRFLOW_API_SOURCE_SECRET:-${release_name}-api-secret-key}"
api_external_secret="${AIRFLOW_API_EXTERNAL_SECRET:-${release_name}-api-secret-key-external}"
redis_password_secret="${AIRFLOW_REDIS_PASSWORD_SECRET:-${release_name}-redis-password}"
broker_url_secret="${AIRFLOW_BROKER_URL_SECRET:-${release_name}-broker-url}"
redis_service="${AIRFLOW_REDIS_SERVICE:-${release_name}-redis}"

for required_command in helm kubectl python3 openssl; do
  command -v "${required_command}" >/dev/null
done

test -f "${values_path}"
kubectl get namespace "${namespace_name}" >/dev/null

case "${worker_replicas}" in
  ''|*[!0-9]*) echo "AIRFLOW_WORKER_REPLICAS must be a positive integer" >&2; exit 1 ;;
esac
case "${worker_concurrency}" in
  ''|*[!0-9]*) echo "AIRFLOW_WORKER_CONCURRENCY must be a positive integer" >&2; exit 1 ;;
esac
if (( worker_replicas < 1 || worker_concurrency < 1 )); then
  echo "Airflow worker replicas and concurrency must both be at least 1" >&2
  exit 1
fi

parallelism="${AIRFLOW_PARALLELISM:-$((worker_replicas * worker_concurrency))}"
max_active_tasks_per_dag="${AIRFLOW_MAX_ACTIVE_TASKS_PER_DAG:-8}"
default_pool_slots="${AIRFLOW_DEFAULT_POOL_SLOTS:-${parallelism}}"
require_distinct_worker_nodes="${AIRFLOW_REQUIRE_DISTINCT_WORKER_NODES:-true}"
for integer_value in "${parallelism}" "${max_active_tasks_per_dag}" "${default_pool_slots}"; do
  case "${integer_value}" in
    ''|*[!0-9]*) echo "Airflow concurrency settings must be positive integers" >&2; exit 1 ;;
  esac
  if (( integer_value < 1 )); then
    echo "Airflow concurrency settings must be at least 1" >&2
    exit 1
  fi
done
if (( max_active_tasks_per_dag > parallelism )); then
  max_active_tasks_per_dag="${parallelism}"
fi
if [[ "${require_distinct_worker_nodes}" != true && "${require_distinct_worker_nodes}" != false ]]; then
  echo "AIRFLOW_REQUIRE_DISTINCT_WORKER_NODES must be true or false" >&2
  exit 1
fi

# Keep the Airflow API signing key outside Helm ownership. On the first upgrade
# from an older chart-managed key, copy the existing value before Helm can
# remove the old Secret. Fresh installs receive a new random key.
if ! kubectl get secret "${api_external_secret}" -n "${namespace_name}" >/dev/null 2>&1; then
  if kubectl get secret "${api_source_secret}" -n "${namespace_name}" >/dev/null 2>&1; then
    kubectl get secret "${api_source_secret}" -n "${namespace_name}" -o json |
      TARGET_SECRET="${api_external_secret}" TARGET_NAMESPACE="${namespace_name}" python3 -c '
import json
import os
import sys

source = json.load(sys.stdin)
document = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": os.environ["TARGET_SECRET"],
        "namespace": os.environ["TARGET_NAMESPACE"],
    },
    "type": "Opaque",
    "data": {"api-secret-key": source["data"]["api-secret-key"]},
}
json.dump(document, sys.stdout)
' | kubectl apply -f - >/dev/null
  else
    generated_api_key="$(openssl rand -hex 32)"
    API_SECRET_VALUE="${generated_api_key}" TARGET_SECRET="${api_external_secret}" \
      TARGET_NAMESPACE="${namespace_name}" python3 -c '
import json
import os
import sys

document = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": os.environ["TARGET_SECRET"],
        "namespace": os.environ["TARGET_NAMESPACE"],
    },
    "type": "Opaque",
    "stringData": {"api-secret-key": os.environ["API_SECRET_VALUE"]},
}
json.dump(document, sys.stdout)
' | kubectl apply -f - >/dev/null
    unset generated_api_key
  fi
fi

# Chart 1.22 expects the Redis password and Celery broker URL to agree. Make
# both explicit so fresh installs and upgrades follow the same path.
redis_exists=false
broker_exists=false
kubectl get secret "${redis_password_secret}" -n "${namespace_name}" >/dev/null 2>&1 && redis_exists=true
kubectl get secret "${broker_url_secret}" -n "${namespace_name}" >/dev/null 2>&1 && broker_exists=true

if [[ "${redis_exists}" == false && "${broker_exists}" == false ]]; then
  generated_redis_password="$(openssl rand -hex 32)"
  REDIS_PASSWORD="${generated_redis_password}" REDIS_SECRET="${redis_password_secret}" \
    BROKER_SECRET="${broker_url_secret}" REDIS_SERVICE="${redis_service}" \
    TARGET_NAMESPACE="${namespace_name}" python3 -c '
import json
import os
import sys

password = os.environ["REDIS_PASSWORD"]
namespace = os.environ["TARGET_NAMESPACE"]
items = [
    {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": os.environ["REDIS_SECRET"], "namespace": namespace},
        "type": "Opaque",
        "stringData": {"password": password},
    },
    {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": os.environ["BROKER_SECRET"], "namespace": namespace},
        "type": "Opaque",
        "stringData": {
            "connection": "redis://:" + password + "@" + os.environ["REDIS_SERVICE"] + ":6379/0"
        },
    },
]
json.dump({"apiVersion": "v1", "kind": "List", "items": items}, sys.stdout)
' | kubectl apply -f - >/dev/null
  unset generated_redis_password
elif [[ "${redis_exists}" == true && "${broker_exists}" == false ]]; then
  kubectl get secret "${redis_password_secret}" -n "${namespace_name}" -o json |
    BROKER_SECRET="${broker_url_secret}" REDIS_SERVICE="${redis_service}" \
      TARGET_NAMESPACE="${namespace_name}" python3 -c '
import base64
import json
import os
import sys

source = json.load(sys.stdin)
password = base64.b64decode(source["data"]["password"]).decode()
document = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": os.environ["BROKER_SECRET"], "namespace": os.environ["TARGET_NAMESPACE"]},
    "type": "Opaque",
    "stringData": {
        "connection": "redis://:" + password + "@" + os.environ["REDIS_SERVICE"] + ":6379/0"
    },
}
json.dump(document, sys.stdout)
' | kubectl apply -f - >/dev/null
elif [[ "${redis_exists}" == false && "${broker_exists}" == true ]]; then
  kubectl get secret "${broker_url_secret}" -n "${namespace_name}" -o json |
    REDIS_SECRET="${redis_password_secret}" TARGET_NAMESPACE="${namespace_name}" python3 -c '
import base64
import json
import os
import sys
import urllib.parse

source = json.load(sys.stdin)
connection = base64.b64decode(source["data"]["connection"]).decode()
password = urllib.parse.unquote(urllib.parse.urlsplit(connection).password or "")
if not password:
    raise SystemExit("Broker URL does not contain a Redis password")
document = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": os.environ["REDIS_SECRET"], "namespace": os.environ["TARGET_NAMESPACE"]},
    "type": "Opaque",
    "stringData": {"password": password},
}
json.dump(document, sys.stdout)
' | kubectl apply -f - >/dev/null
fi

kubectl get secret "${redis_password_secret}" "${broker_url_secret}" -n "${namespace_name}" -o json |
  REDIS_SECRET="${redis_password_secret}" BROKER_SECRET="${broker_url_secret}" \
    REDIS_SERVICE="${redis_service}" python3 -c '
import base64
import json
import os
import sys
import urllib.parse

items = {item["metadata"]["name"]: item for item in json.load(sys.stdin)["items"]}
password = base64.b64decode(items[os.environ["REDIS_SECRET"]]["data"]["password"]).decode()
connection = base64.b64decode(items[os.environ["BROKER_SECRET"]]["data"]["connection"]).decode()
parsed = urllib.parse.urlsplit(connection)
broker_password = urllib.parse.unquote(parsed.password or "")
if password != broker_password:
    raise SystemExit("Redis password and Airflow broker URL secrets do not match")
if parsed.hostname != os.environ["REDIS_SERVICE"]:
    raise SystemExit("Airflow broker URL points to an unexpected Redis service")
'

helm repo add apache-airflow https://airflow.apache.org --force-update >/dev/null
helm repo update apache-airflow >/dev/null

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT

helm template "${release_name}" "${chart_name}" \
  -n "${namespace_name}" \
  --version "${chart_version}" \
  -f "${values_path}" \
  --set apiSecretKeySecretName="${api_external_secret}" \
  --set data.brokerUrlSecretName="${broker_url_secret}" \
  --set redis.passwordSecretName="${redis_password_secret}" \
  --set workers.celery.replicas="${worker_replicas}" \
  --set-string config.core.parallelism="${parallelism}" \
  --set-string config.core.max_active_tasks_per_dag="${max_active_tasks_per_dag}" \
  --set-string config.celery.worker_concurrency="${worker_concurrency}" \
  --set-string config.scheduler.max_tis_per_query="${parallelism}" \
  >"${temporary_dir}/airflow-rendered.yaml"

helm upgrade --install "${release_name}" "${chart_name}" \
  -n "${namespace_name}" \
  --version "${chart_version}" \
  --reset-values \
  -f "${values_path}" \
  --set apiSecretKeySecretName="${api_external_secret}" \
  --set data.brokerUrlSecretName="${broker_url_secret}" \
  --set redis.passwordSecretName="${redis_password_secret}" \
  --set workers.celery.replicas="${worker_replicas}" \
  --set-string config.core.parallelism="${parallelism}" \
  --set-string config.core.max_active_tasks_per_dag="${max_active_tasks_per_dag}" \
  --set-string config.celery.worker_concurrency="${worker_concurrency}" \
  --set-string config.scheduler.max_tis_per_query="${parallelism}" \
  --atomic \
  --timeout 20m

kubectl rollout status deployment/"${release_name}"-scheduler -n "${namespace_name}" --timeout=10m
kubectl rollout status statefulset/"${release_name}"-worker -n "${namespace_name}" --timeout=15m
kubectl exec deployment/"${release_name}"-scheduler -n "${namespace_name}" -c scheduler -- \
  env AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR \
  airflow pools set default_pool "${default_pool_slots}" \
  "DataSurface starter executor concurrency cap" >/dev/null

executor_name="$(kubectl exec deployment/"${release_name}"-scheduler -n "${namespace_name}" \
  -c scheduler -- airflow config get-value core executor 2>/dev/null)"
if [[ "${executor_name}" != *CeleryExecutor* ]]; then
  echo "Expected CeleryExecutor, found: ${executor_name}" >&2
  exit 1
fi

kubectl get pods -n "${namespace_name}" -l component=worker -o json |
  EXPECTED_WORKERS="${worker_replicas}" REQUIRE_DISTINCT="${require_distinct_worker_nodes}" \
    python3 -c '
import json
import os
import sys

items = json.load(sys.stdin)["items"]
ready = [
    pod
    for pod in items
    if pod.get("status", {}).get("phase") == "Running"
    and pod.get("status", {}).get("containerStatuses")
    and all(status.get("ready") for status in pod["status"]["containerStatuses"])
]
expected = int(os.environ["EXPECTED_WORKERS"])
if len(ready) != expected:
    raise SystemExit(f"Expected {expected} Ready Airflow workers, found {len(ready)}")
nodes = {pod.get("spec", {}).get("nodeName") for pod in ready}
nodes.discard(None)
if os.environ["REQUIRE_DISTINCT"] == "true" and len(nodes) != expected:
    raise SystemExit(
        f"Expected {expected} distinct worker nodes, found {len(nodes)}; "
        "check node eligibility, capacity, selectors, and tolerations"
    )
'

kubectl get pods -n "${namespace_name}" -l app.kubernetes.io/name=airflow -o json |
  python3 -c '
import json
import sys

items = json.load(sys.stdin)["items"]
running = [pod for pod in items if pod.get("status", {}).get("phase") == "Running"]
best_effort = [
    pod["metadata"]["name"]
    for pod in running
    if pod.get("status", {}).get("qosClass") == "BestEffort"
]
oom = []
for pod in running:
    for status in pod.get("status", {}).get("containerStatuses", []):
        if status.get("lastState", {}).get("terminated", {}).get("reason") == "OOMKilled":
            oom.append("{}/{}".format(pod["metadata"]["name"], status["name"]))
if best_effort:
    raise SystemExit("Running Airflow pods are BestEffort: " + ", ".join(best_effort))
if oom:
    raise SystemExit("Running Airflow containers have new OOM history: " + ", ".join(oom))
'

kubectl get pods -n "${namespace_name}" -l component=worker \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
echo "Airflow ${chart_version} applied with ${worker_replicas} Celery workers and parallelism ${parallelism}"
