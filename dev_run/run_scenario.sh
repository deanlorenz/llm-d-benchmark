#!/usr/bin/env bash

# trap 'echo -ne "\033[32m${BASH_SOURCE}:${LINENO}  \033[0m${BASH_COMMAND}"; read' DEBUG
# set -x

# assuming installed under util/
pushd "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null; cd ..

function usage {
  cat <<EOF
  USAGE:
    $0 -w WORKLOAD -e EPP [-c CONFIG_FILE] -l LOADER

  - WORKLOAD in: ${workloads//$NL/ })  (workload/profiles/inference-perf/workload_*.yaml.in)
  - EPP in: ${epps//$NL/ } (experiments/epp_*.yaml)
  - Optional CONFIG_FILE sourced to set LLMDBENCH ENV (e.g., LLMDBENCH_HF_TOKEN, LLMDBENCH_VLLM_COMMON_PVC_NAME).
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--workload)
        workload="workload_${2}"
        shift 2
        ;;
        -e|--epp)
        epp="epp_${2}"
        shift 2
        ;;
        -c|--config)
        config_file="${2:-/dev/null}"
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

workloads=$(find workload/profiles/$loader/ -name 'workload_*.yaml.in' | sed 's|.*/||' | sed 's|\.yaml.in||' | sed 's|workload_||')
epps=$(find experiments/ -name 'epp_*.yaml' | sed 's|.*/||' | sed 's|\.yaml||' | sed 's|epp_||')
NL=$'\n'

if [[ -z $workload ]]; then
  echo "Workload not specified."
  usage
  exit 1
fi
[ -f ./workload/profiles/$loader/${workload}.yaml.in ] || {
  echo "Workload file ./workload/profiles/inference-perf/${workload}.yaml.in does not exist."
  usage
  exit 1
}
if [[ -z $epp ]]; then
  echo "EPP not specified."
  usage
  exit 1
fi
[ -f ./experiments/${epp}.yaml ] || {
  echo "EPP file ./experiments/${epp}.yaml does not exist."
  usage
  exit 1
}
[ -f util/get_logs.sh ] || {
  echo "get_logs.sh script does not exist in the util directory."
  exit 1
}
[ -f "${config_file}" ] || {
  echo "${config_file} does not exist."
  exit 1
}
#source <(sed '/^export/!d' "${config_file}")

source "${config_file}"

echo running workload $workload with epp $epp

: {LLMDBENCH_CONTROL_WORK_DIR:=/tmp}
id=$(date +%s)
export LLMDBENCH_CONTROL_WORK_DIR=${LLMDBENCH_CONTROL_WORK_DIR}/${workload}-${epp}-${id}
mkdir -p -v $LLMDBENCH_CONTROL_WORK_DIR

echo applying workload from ./workload/profiles/$loader/${workload}.yaml.in
yq -C . <./workload/profiles/$loader/${workload}.yaml.in
read -t 30 -p "Press enter to continue or Ctrl-C to cancel"

echo applying epp config from ./experiments/${epp}.yaml
yq -C . <./experiments/${epp}.yaml
read -t 30 -p "Press enter to continue or Ctrl-C to cancel"
# apply and restart
kubectl create configmap epp-config --from-file=epp-config.yaml=./experiments/${epp}.yaml --dry-run=client -o yaml | 
	yq '.metadata.annotations.id="'$id'"' |
	kubectl apply -f -
kubectl delete pod -l app=endpoint-picker
if ! kubectl wait --for=condition=Ready pod -l app=endpoint-picker --timeout=60s; then
  echo "❌ Timeout reached: endpoint-picker did not become Ready."
  exit 1
fi
echo endpoint-picker is restarted!

echo Starting logging into $LLMDBENCH_CONTROL_WORK_DIR
trap 'kill -9 $(jobs -p)' EXIT TERM INT
chmod +x util/get_logs.sh
util/get_logs.sh -d $LLMDBENCH_CONTROL_WORK_DIR -l $loader 2>&1 >$LLMDBENCH_CONTROL_WORK_DIR/log.log &

cat <<EOF
=======> Calling run.sh with
   -p e2e-solution2 \
   -t inference-gateway \
   -k vllm-p2p-70b-chart-llama-3-70b-instruct-storage-claim \
   -m 'meta-llama/Llama-3.1-70B-Instruct' \
   -l $loader \
   -s 1000000 \
   -w $workload
EOF

./run.sh \
    -p e2e-solution2 \
    -t inference-gateway \
    -k vllm-p2p-70b-chart-llama-3-70b-instruct-storage-claim \
    -m 'meta-llama/Llama-3.1-70B-Instruct' \
    -l $loader \
    -s 1000000 \
    -w $workload

read -t 30 -p "Run finished. Press enter to kill log capture"
kill -9 $(jobs -p)
popd
