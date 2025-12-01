#!/usr/bin/env bash

# Copyright 2025 The llm-d Authors.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "This script should be executed not sourced"
  return 1
fi

set -euo pipefail

if [[ $0 != "-bash" ]]; then
    pushd `dirname "$(realpath $0)"` > /dev/null 2>&1
fi

_script_name=$(echo $0 | rev | cut -d '/' -f 1 | rev)

if [ $0 != "-bash" ] ; then
    popd  > /dev/null 2>&1
fi

function show_usage {
cat <<EOF
Usage: ${_script_name}
  -c/--config path to configuration file
  -v/--verbose print the command being executed, and result
  -d/--debug execute harness in "debug-mode"
  -n/--dry-run do not execute commands, just print what would be executed
  -h/--help show this help
EOF
}

function read_config {
  eval $(yq 'del(.workload)' -o shell "$1")
}

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -c=*|--config=*)
        _config_file=$(echo $key | cut -d '=' -f 2)
        ;;
        -c|--config)
        _config_file="$2"
        shift
        ;;
        -n|--dry-run)
        export $kubectl=1
        ;;
        -d|--debug)
        export LLMDBENCH_HARNESS_DEBUG=1
        ;;
        -v|--verbose)
        export LLMDBENCH_VERBOSE=1
        ;;
        -h|--help)
        show_usage
        if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
        then
            exit 0
        else
            return 0
        fi
        ;;
        *)
        echo "ERROR: unknown option \"$key\""
        show_usage
        exit 1
        ;;
        esac
        shift
done

#source ${_control_dir}/env.sh #@TODO WE NEED THIS????

# Read configuration file
# ========================================================
announce "📄 Reading configuration file $_config_file"
if ! [[ -f $_config_file  ]]; then
  echo "❌ ERROR: could not find config file \"$_config_file\""
  exit 1
fi
read_config "$_config_file"

_inference_url="${endpoint_base_url}/v1/chat/completions"
_model_url="${endpoint_base_url}/v1/models" # @TODO check if needed
_harness_pod_name=llmdbench-${harness_name}-launcher
_uid=$(date +%s)  # @TODO consider calling this _experiment_uid

announce "ℹ️ Using endpoint_stack_name=$endpoint_stack_name on endpoint_namespace=$endpoint_namespace running model=${endpoint_model} at endpoint_base_url=$endpoint_base_url"
announce "ℹ️ Using harness_name=$harness_name, with _harness_pod_name=$_harness_pod_name on harness_namespace=$harness_namespace"
announce "ℹ️ Using experiment prefix ${harness_experiment_prefix}_${_uid}_<workload_key>_"


mkdir -p ${control_work_dir}/setup/commands #@TODO do we need this?


# Ensure harness namespace is prepared @TODO enable python script
# ========================================================
announce "🔧 Ensuring harness namespace is prepared"
_control_dir=$(realpath $(pwd)/) #@TODO check if needed
_steps_dir="$_control_dir/steps"
#python3 ${_steps_dir}/05_ensureharness_namespace_prepared.py 2> ${control_work_dir}/setup/commands/05_ensureharness_namespace_prepare_stderr.log 1> ${control_work_dir}/setup/commands/05_ensureharness_namespace_prepare_stdout.log
if [[ $? -ne 0 ]]; then
  announce "❌ Error while attempting to setup the harness namespace"
  cat ${control_work_dir}/setup/commands/05_ensureharness_namespace_prepare_stderr.log
  echo "---------------------------"
  cat ${control_work_dir}/setup/commands/05_ensureharness_namespace_prepare_stdout.log
  exit 1
fi

# Verify HF token secret exists
# ========================================================
announce "🔧 Verifying HF token secret $endpoint_hf_token_secret in namespace $endpoint"
if $control_kubectl --namespace "$endpoint_namespace" get secret "$endpoint_hf_token_secret" 2>&1 > /dev/null; then 
  announce "ℹ️ Using HF token secret $endpoint_hf_token_secret"
else    
  announce "❌ ERROR: could not fetch HF token secret $endpoint_hf_token_secret"
  exit 1
fi

# Verify model is deployed and endpoint is reachable
# ========================================================
announce "🔍 Verifying model and endpoint"
httpCode=$($control_kubectl -n $endpoint_namespace run --rm -it --image=alpine/curl --restart=Never model-list-${_uid} \
    -- curl -s -o /dev/null -w "%{http_code}\n" "${endpoint_base_url}/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": $_model_name,
        "prompt": "Hello"
    }')

if [[ $? != 0 ]]; then
  announce "❌ Error while sending completion request to the model (kubectl failed)"
  exit 1
fi
# @TODO Open the command below after stack is set
# if [[ $httpCode != 200 ]]; then
#   announce "❌ Error while sending completion request to the model(bad HTTP code)"
#   exit 1
# fi

# @TODO return actual error od the test above!!!

# rm -rf ${control_work_dir}/workload/profiles/*
# mkdir -p ${control_work_dir}/workload/profiles/${harness_name}


# Prepare ConfigMap with workload profiles
# ========================================================
announce "🔧 Preparing ConfigMap with workload profiles"
$control_kubectl --namespace "${harness_namespace}" delete configmap ${harness_name}-profiles --ignore-not-found

cmd=($control_kubectl create cm ${harness_name}-profiles)
cmd+=(--namespace "${harness_namespace}")
for key in $(yq '.workload | keys | .[]' $_config_file); do
  cmd+=( --from-file=${key}.yaml='<(yq ".workload.'$key' | explode(.)" '$_config_file')')
done
eval ${cmd[@]}
announce "ℹ️ ConfigMap '${harness_name}-profiles' created"


announce "ℹ️ Checking results PVC"
if ! $control_kubectl --namespace=${harness_namespace} describe pvc ${results_pvc}; then # @TODO Verify status and RWX 
  announce "❌ Error checking PVC ${results_pvc}"
fi
  
_pod_name=llmdbench-${harness_name}-launcher
create_harness_pod ${_pod_name} "${control_work_dir}/${_pod_name}" ${harness_image}



      for treatment in $(ls ${control_work_dir}/workload/profiles/${workload_type}/*.yaml); do


        # Assemble the pod specifications and build the workload

        for i in $(seq 1 $LLMDBENCH_HARNESS_LOAD_PARALLELISM); do
          _pod_name="${LLMDBENCH_RUN_HARNESS_LAUNCHER_NAME}-${i}-of-${LLMDBENCH_HARNESS_LOAD_PARALLELISM}"

          export LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX=${harness_name}_${LLMDBENCH_RUN_EXPERIMENT_ID}_${endpoint_stack_name}
          export LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR=${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_PREFIX}/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}_${i}

          local_results_dir=${control_work_dir}/results/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}
          local_analysis_dir=${control_work_dir}/analysis/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}
          llmdbench_execute_cmd "mkdir -p ${local_results_dir}_${i} && mkdir -p ${local_analysis_dir}_${i}" \
                ${$kubectl} \
                ${LLMDBENCH_CONTROL_VERBOSE}


          if [[ -f ${local_analysis_dir}_{i}/summary.txt ]]; then
            announce "⏭️  This particular workload profile was already executed against this stack. Please remove \"${local_analysis_dir}_{i}/summary.txt\" to re-execute".
            continue
          fi

          if [[ $$kubectl -eq 1 ]]; then
            announce "ℹ️ Skipping \"${_pod_name}\" creation"
          else
            if [[ "$LLMDBENCH_VLLM_MODELSERVICE_GAIE_PLUGINS_CONFIGFILE" == /* ]]; then
              potential_gaie_path=$(echo $LLMDBENCH_VLLM_MODELSERVICE_GAIE_PLUGINS_CONFIGFILE'.yaml' | $LLMDBENCH_CONTROL_SCMD 's^.yaml.yaml^.yaml^g')
            else
              potential_gaie_path=$(echo ${LLMDBENCH_MAIN_DIR}/setup/presets/gaie/$LLMDBENCH_VLLM_MODELSERVICE_GAIE_PLUGINS_CONFIGFILE'.yaml' | $LLMDBENCH_CONTROL_SCMD 's^.yaml.yaml^.yaml^g')
            fi

            if [[ -f $potential_gaie_path ]]; then
              export LLMDBENCH_VLLM_MODELSERVICE_GAIE_PRESETS_CONFIG=$potential_gaie_path
            fi

            if [[ -f $potential_gaie_path ]]; then
              export LLMDBENCH_VLLM_MODELSERVICE_GAIE_PRESETS_CONFIG=$potential_gaie_path
            fi
            export LLMDBENCH_CONTROL_ENV_VAR_LIST_TO_POD="^$(echo $LLMDBENCH_HARNESS_ENVVARS_TO_YAML | $LLMDBENCH_CONTROL_SCMD -e 's/,/|^/g' -e 's/$/|^/g')$LLMDBENCH_CONTROL_ENV_VAR_LIST_TO_POD"
            create_harness_pod ${_pod_name} "${control_work_dir}/${_pod_name}"
          fi
        done

        _combined_pod_config="${control_work_dir}/setup/yamls/${harness_name}_${LLMDBENCH_RUN_EXPERIMENT_ID}_${endpoint_stack_name}.yaml"
        rm -rf ${_combined_pod_config}
        touch ${_combined_pod_config}
        for i in $(seq 1 "$LLMDBENCH_HARNESS_LOAD_PARALLELISM"); do
            _pod_name="${LLMDBENCH_RUN_HARNESS_LAUNCHER_NAME}-${i}-of-${LLMDBENCH_HARNESS_LOAD_PARALLELISM}"
            _yaml_path="${control_work_dir}/${_pod_name}/setup/yamls/pod_benchmark-launcher.yaml"

            if [[ ! -f "$_combined_pod_config" ]]; then
                announce  "⚠️  WARNING: YAML not found: $_yaml_path" >&2
                continue
            fi

            echo "---" >> "$_combined_pod_config"
            cat "$_yaml_path" >> "$_combined_pod_config"
            echo >> "$_combined_pod_config"
        done

        deploy_harness_config ${LLMDBENCH_DEPLOY_CURRENT_MODEL} ${LLMDBENCH_DEPLOY_CURRENT_MODELID} ${local_results_dir} ${local_analysis_dir} ${_combined_pod_config}

        if [[ $LLMDBENCH_HARNESS_DEBUG -eq 1 ]]; then
          exit 0
        fi
      done
    fi

    if [[ $LLMDBENCH_RUN_EXPERIMENT_ANALYZE_LOCALLY -eq 1 ]]; then
      announce "🔍 Analyzing collected data..."
      conda_root="$(conda info --all --json | jq -r '.root_prefix'  2>/dev/null)"
      if [ "$LLMDBENCH_CONTROL_DEPLOY_HOST_OS" = "mac" ]; then
        conda_sh="${conda_root}/base/etc/profile.d/conda.sh"
      else
        conda_sh="${conda_root}/etc/profile.d/conda.sh"
      fi
      if [ -f "${conda_sh}" ]; then
        llmdbench_execute_cmd "source \"${conda_sh}\"" ${$kubectl} ${LLMDBENCH_CONTROL_VERBOSE}
      else
        announce "❌ Could not find conda.sh for $LLMDBENCH_CONTROL_DEPLOY_HOST_OS. Please verify your Anaconda installation."
        exit 1
      fi

      llmdbench_execute_cmd "conda activate \"$LLMDBENCH_HARNESS_CONDA_ENV_NAME\"" ${$kubectl} ${LLMDBENCH_CONTROL_VERBOSE}
      llmdbench_execute_cmd "${LLMDBENCH_CONTROL_PCMD} $LLMDBENCH_MAIN_DIR/analysis/analyze_results.py" ${$kubectl} ${LLMDBENCH_CONTROL_VERBOSE}
      announce "✅ Data analysis done."
    fi
    unset LLMDBENCH_DEPLOY_CURRENT_MODEL

  done
done
