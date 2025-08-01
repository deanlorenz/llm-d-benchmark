#!/usr/bin/env bash

if [[ $# -gt 0 ]]; then
  pushd "$1"
fi

oc get pod -l app=endpoint-picker -o yaml > epp_pod.yaml
oc get cm epp-config -o yaml | yq '.data["epp-config.yaml"]' > epp_config.yaml
oc get deployment -l 'app.kubernetes.io/component=vllm' -o yaml > vllm_deployment.yaml

harness=$(oc get pod llmdbench-inference-perf-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_HARNESS_NAME")]}{.value}{end}')
profile=$(oc get pod llmdbench-inference-perf-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME")]}{.value}{end}')
name=$(oc get pod llmdbench-inference-perf-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_RUN_EXPERIMENT_HARNESS")]}{.value}{end}')

sleep 60 & oc get cm ${harness}-profiles -o=jsonpath='{.data}' | jq '.["'$profile.yaml'"]' > ${harness}.yaml & 

log_vllm=vllm.log
log_epp=epp.log

touch ${log_vllm}
touch ${log_epp}

trap 'kill $(jobs -p)' EXIT
since_vllm=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
while true; do
  echo __________________________________________________________ >> ${log_vllm}
  echo capturing run for $harness, $profile, $name at $(date) >> ${log_vllm}
  echo __________________________________________________________ >> ${log_vllm}
  oc logs -f -l 'app.kubernetes.io/component=vllm' --prefix --since-time $since_vllm | grep -v -f <(cat <<EOF
"GET /health HTTP/1.1" 200 OK
"GET /metrics HTTP/1.1" 200 OK
"POST /v1/completions HTTP/1.1" 200 OK
EOF
  ) | sed 's|^\[[^]]*\(.....\)/vllm\]|\1|' | cut -c 1-250 >> ${log_vllm} 2>/dev/stderr
  since_vllm=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo vllm log capture failed. restarting.
  sleep 2
done &

since_epp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
while true; do
  echo __________________________________________________________ >> ${log_epp}
  echo capturing run for $harness, $profile, $name at $(date) >> ${log_epp}
  echo __________________________________________________________ >> ${log_epp}
  oc logs -f -l app=endpoint-picker --since-time $since_epp  >> ${log_epp} 2>/dev/stderr
  since_epp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo epp log capture failed. restarting.
  sleep 2
done
