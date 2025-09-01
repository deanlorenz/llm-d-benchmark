#!/usr/bin/env bash

trap 'kill -9 $(jobs -p)' EXIT INT TERM

function usage {
  cat <<EOF
  USAGE:
  $0 [destination directory] [delay] [loader]

  Default destination dir is current directory
  Deafult delay is 60 seconds
EOF
}

delay=60
launcher=inference-perf
dest=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
        usage
        exit 0
        ;;
        -d |--destination)
        dest="${2}"
        shift 2
        ;;
        -t|--delay)
        delay="${2}"
        shift 2
	      ;;
        -l|--loader)
        loader="${2}"
        shift 2
	      ;;
        *)
        echo "Unknown option: $1"
	usage
        exit 1
        ;;
    esac
done

if [[ -z "$dest" ]]; then
  usage
  exit 1
fi

pushd $dest
echo "Parameters: -t $delay, -d $dest, -l $launcher" 

# Delayed start to allow run to setup epp and create the launcher
since_vllm=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
since_epp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
sleep $delay

oc get pod -l app=endpoint-picker -o yaml > epp_pod.yaml
oc get cm epp-config -o yaml | yq '.data["epp-config.yaml"]' > epp_config.yaml
oc get deployment -l 'app.kubernetes.io/component=vllm' -o yaml > vllm_deployment.yaml

echo "Loader: " $loader
harness=$(oc get pod llmdbench-$loader-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_HARNESS_NAME")]}{.value}{end}')
profile=$(oc get pod llmdbench-$loader-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME")]}{.value}{end}')
name=$(oc get pod llmdbench-$loader-launcher -o=jsonpath='{range .spec.containers[0].env[?(@.name == "LLMDBENCH_RUN_EXPERIMENT_HARNESS")]}{.value}{end}')

oc get cm ${harness}-profiles -o=jsonpath='{.data}' | jq '.["'$profile.yaml'"]' > ${harness}.yaml 

log_vllm=vllm.log
log_epp=epp.log

touch ${log_vllm}
touch ${log_epp}

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

while true; do
  echo __________________________________________________________ >> ${log_epp}
  echo capturing run for $harness, $profile, $name at $(date) >> ${log_epp}
  echo __________________________________________________________ >> ${log_epp}
  oc logs -l app=endpoint-picker --tail=-1 >> "${log_epp}" 2>/dev/stderr
  oc logs -f -l app=endpoint-picker >> "${log_epp}" 2>/dev/stderr
  echo epp log capture failed. restarting.
  sleep 2
done
kill $(jobs -p)
