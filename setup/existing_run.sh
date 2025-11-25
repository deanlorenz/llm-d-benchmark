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

LLMD_HF_TOKEN_NAME=llm-d-hf-token

set -euo pipefail

if [[ $0 != "-bash" ]]; then
    pushd `dirname "$(realpath $0)"` > /dev/null 2>&1
fi

#-- export LLMDBENCH_ENV_VAR_LIST=$(env | grep ^LLMDBENCH | cut -d '=' -f 1)
_contorl_dir=$(realpath $(pwd)/)
_script_name=$(echo $0 | rev | cut -d '/' -f 1 | rev)
_steps_dir="$_contorl_dir/steps"

if [ $0 != "-bash" ] ; then
    popd  > /dev/null 2>&1
fi

#++ control.root_dir ++ export LLMDBENCH_MAIN_DIR=$(realpath ${_contorl_dir}/../)

#-- export $kubectl=${$kubectl:-0}
#-- export LLMDBENCH_CONTROL_VERBOSE=${LLMDBENCH_CONTROL_VERBOSE:-0}
#-- export LLMDBENCH_DEPLOY_SCENARIO=
#-- export LLMDBENCH_CLIOVERRIDE_DEPLOY_SCENARIO=
#-- export LLMDBENCH_HARNESS_SKIP_RUN=${LLMDBENCH_HARNESS_SKIP_RUN:-0}
#-- export LLMDBENCH_HARNESS_DEBUG=${LLMDBENCH_HARNESS_DEBUG:-0}
# --export LLMDBENCH_CURRENT_STEP=99

function show_usage {
    cat <<-EOF
    Usage: ${_scrip_name}
        -c/--config path to configuration file
        -v/--verbose print the command being executed, and result
        -d/--debug execute harness in "debug-mode"
        -n/--dry-run do not execute commands, just print what would be executed
        -h/--help show this help
	EOF     # note the tab before EOF to preserve indentation. Do not change to spaces.
}


while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -c=*|--config=*)
        _config_file=$(echo $key | cut -d '=' -f 2)
        ;;
        -c|--config)
        _config_file=="$2"
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

read_config_file $_config_file  # DO WE NEED THIS????

#-- export LLMDBENCH_CONTROL_CLI_OPTS_PROCESSED=1

#-- DO WE NEED THIS????

source ${_control_dir}/env.sh
kubectl=oc      # @TODO FIXME


#-- export LLMDBENCH_BASE64_CONTEXT_CONTENTS=$_work_dir/environment/context.ctx

#-- set +euo pipefail     @TODO check if we isolate some code
#-- export LLMDBENCH_CURRENT_STEP=05
#-- if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_STANDALONE_ACTIVE -eq 0 && $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 0 ]]; then
#--   export LLMDBENCH_VLLM_MODELSERVICE_URI_PROTOCOL="NA"
#-- 
#--   if [[ -z $LLMDBENCH_CONTROL_CLUSTER_NAMESPACE ]]; then
#--     announce "❌ Unable automatically detect namespace. Environment variable \"LLMDBENCH_CONTROL_CLUSTER_NAMESPACE\". Specifiy namespace via CLI option \"-p\--namespace\" or environment variable \"_harness_nameSPACE\""
#--     exit 1
#--   fi
#-- fi

_work_dir="$(get_config control.work_dir)"
mkdir -p ${_work_dir}/setup/commands

python3 ${_steps_dir}/05_ensure_harness_namespace_prepared.py 2> ${_work_dir}/setup/commands/05_ensure_harness_namespace_prepare_stderr.log 1> ${_work_dir}/setup/commands/05_ensure_harness_namespace_prepare_stdout.log
if [[ $? -ne 0 ]]; then
  announce "❌ Error while attempting to setup the harness namespace"
  cat ${_work_dir}/setup/commands/05_ensure_harness_namespace_prepare_stderr.log
  echo "---------------------------"
  cat ${_work_dir}/setup/commands/05_ensure_harness_namespace_prepare_stdout.log
  exit 1
fi
set -euo pipefail

_namespace="$(get_config endpoint.namespace)"
_stack_name="$(get_config endpoint.stack_name)"
_base_url="$(get_config endpoint.base_url)"
_inference_url="${_base_url}/v1/chat/completions"
_model_url="${_base_url}/v1/models"
_model="$(get_config endpoint.model)"
announce "ℹ️ Using _stack_name=$_stack_name on _namespace=$_namespace running model=$_model at _base_url=$_base_url"
_harness_name="$(get_config harness.name)"
_harness_namespace="$(get_config harness.namespace)"
_harness_pod_name=llmdbench-${_harness_name}-launcher
announce "ℹ️ Using _harness_name=$_harness_name, with _harness_pod_name=$_harness_pod_name on _harness_namespace=$_harness_namespace"


#--    export LLMDBENCH_DEPLOY_CURRENT_TOKENIZER=$(model_attribute $model model)

#--     if [[ $LLMDBENCH_HARNESS_SKIP_RUN -eq 1 ]]; then
#--       announce "⏭️ Command line option \"-z\--skip\" invoked. Will skip experiment execution (and move straight to analysis)"
#--     else
#--       cleanup_pre_execution

#--       export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=
#--       export LLMDBENCH_VLLM_FQDN=".${_namespace}${LLMDBENCH_VLLM_COMMON_FQDN}"

#-- #   if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_STANDALONE_ACTIVE -eq 1 ]]; then
    #     export LLMDBENCH_CONTROL_ENV_VAR_LIST_TO_POD="LLMDBENCH_BASE64_CONTEXT_CONTENTS|^LLMDBENCH_VLLM_COMMON|^LLMDBENCH_VLLM_STANDALONE|^LLMDBENCH_DEPLOY"
    #     export LLMDBENCH_HARNESS_STACK_TYPE=vllm-prod
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=$(${$kubectl} --namespace "$_namespace" get service --no-headers -l stood-up-via=${LLMDBENCH_DEPLOY_METHODS} | awk '{print $1}' || true)
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=80
    #   fi

    #   if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 1 ]]; then
    #     export LLMDBENCH_CONTROL_ENV_VAR_LIST_TO_POD="LLMDBENCH_BASE64_CONTEXT_CONTENTS|^LLMDBENCH_VLLM_COMMON|^LLMDBENCH_VLLM_MODELSERVICE|^LLMDBENCH_DEPLOY|^LLMDBENCH_VLLM_INFRA|^LLMDBENCH_VLLM_GAIE|^LLMDBENCH_LLMD_IMAGE"
    #     export LLMDBENCH_HARNESS_STACK_TYPE=llm-d
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=$(${$kubectl} --namespace "$_namespace" get gateway --no-headers -l stood-up-via=${LLMDBENCH_DEPLOY_METHODS} | awk '{print $1}')
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=80
    #   fi

    #   if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_STANDALONE_ACTIVE -eq 0 && $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 0 ]]; then
    #     export LLMDBENCH_CONTROL_ENV_VAR_LIST_TO_POD="LLMDBENCH_BASE64_CONTEXT_CONTENTS|^_namespace|^LLMDBENCH_DEPLOY_CURRENT"
    #     announce "⚠️ Deployment method - $LLMDBENCH_DEPLOY_METHODS - is neither \"standalone\" nor \"modelservice\". "

    #     announce "🔍 Trying to find a matching endpoint name..."

    #     export LLMDBENCH_HARNESS_STACK_TYPE=vllm-prod
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=$(${$kubectl} --namespace "$_namespace" get service --no-headers | awk '{print $1}' | grep ${LLMDBENCH_DEPLOY_METHODS} || true)
    #     if [[ ! -z $LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME ]]; then
    #       for i in default http; do
    #         export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=$(${$kubectl} --namespace "$_namespace" get service/$LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME --no-headers -o json | jq -r ".spec.ports[] | select(.name == \"$i\") | .port")
    #         if [[ ! -z $LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT ]]; then
    #           break
    #         fi
    #       done
    #       if [[ -z $LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT ]]; then
    #         announce "❌ ERROR: could not find a port for endpoint name \"$$LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME\""
    #         exit 1
    #       fi
    #     else
    #       export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=$(${$kubectl} --namespace "$_namespace" get pod --no-headers | awk '{print $1}' | grep ${LLMDBENCH_DEPLOY_METHODS} | head -n 1 || true)
    #       export LLMDBENCH_VLLM_FQDN=
    #       if [[ ! -z $LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME ]]; then
    #         announce "ℹ️ Stack Endpoint name detected is \"$LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME\""
    #         export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=$(${$kubectl} --namespace "$_namespace" get pod/$LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME --no-headers -o json | jq -r ".spec.containers[0].ports[0].containerPort")
    #         export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=$(${$kubectl} --namespace "$_namespace" get pod/$LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME --no-headers -o json | jq -r ".status.podIP")
    #       fi
    #     fi
    #     export LLMDBENCH_DEPLOY_CURRENT_MODEL="auto"
    #   fi

#-- #   if [[ $$kubectl -eq 1 ]]; then
    #     export LLMDBENCH_HARNESS_STACK_TYPE=mock
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME=mock
    #     export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT=1234
    #   fi

#-- #   if [[ -z $LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME ]]; then
    #     announce "❌ ERROR: could not find an endpoint name for a stack deployed via method \"$LLMDBENCH_DEPLOY_METHODS\" (i.e., with label \"stood-up-via=$LLMDBENCH_DEPLOY_METHODS\")"
    #     announce "📌 Tip: If the llm-d stack you're trying to benchmark was NOT deployed via \"standup.sh\", just use \"run.sh -t <string that matches the service/gateway name>\""

    #     exit 1
    #   fi

#      if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 1 ]]; then
#        export LLMDBENCH_HARNESS_STACK_ENDPOINT_URL="http://${LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME}${LLMDBENCH_VLLM_FQDN}:${LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT}/${LLMDBENCH_DEPLOY_CURRENT_MODELID}"
#      else
        # export LLMDBENCH_HARNESS_STACK_ENDPOINT_URL="http://${LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME}${LLMDBENCH_VLLM_FQDN}:${LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT}"
#      fi
    #   announce "ℹ️ Stack Endpoint URL detected is \"$LLMDBENCH_HARNESS_STACK_ENDPOINT_URL\""

    #   if [[ $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_STANDALONE_ACTIVE -eq 0 && $LLMDBENCH_CONTROL_ENVIRONMENT_TYPE_MODELSERVICE_ACTIVE -eq 0 ]]; then


announce "🔍 Verifying hugging face token"
_hf_token="$(get_config endpoint.huggingface_token)"
stack_token="$(${$kubectl} --namespace "$_namespace" get secret "$LLMD_HF_TOKEN_NAME" -o jsonpath='{.data.*}' | base64 -d)"
if [[ ! "$_hf_token" == "$stack_token" ]]; then
    announce "❌ ERROR: hugging face token in configuration does not match the one in the stack"
    exit 1
fi

#--    #     if [[ ! -z $LLMDBENCH_VLLM_COMMON_HF_TOKEN_NAME ]]; then
    #       announce "ℹ️ Hugging face token detected is \"$LLMDBENCH_VLLM_COMMON_HF_TOKEN_NAME\""
    #     else
    #       announce "❌ ERROR: could not find a hugging face token"
    #       exit 1
    #     fi
    #   fi

    #   announce "🔍 Trying to detect the model name served by the stack ($LLMDBENCH_HARNESS_STACK_ENDPOINT_URL)..."
    #   if [[ $$kubectl -eq 1 ]]; then
    #     announce "ℹ️ Stack model detected is \"mock\""
    #   else

    #     set +euo pipefail

announce "🔍 Verifying model and endpoint"
_harness_image="$(get_config harness.image)"
received_model_name=$(get_model_name_from_pod "{$_namespace}" "{$_harness_image}" "${_base_url}" NA)  # @TODO check function and url
if [[ ${received_model_name} == ${_model} ]]; then
    announce "ℹ️ Detected stack model \"$received_model_name\" matches requested model \"$_model\""
else
    announce "❌ Detected Stack model \"$received_model_name\" does not match requested model \"$_model\""
    exit 1
fi

        # if [[ $LLMDBENCH_DEPLOY_CURRENT_MODEL == "auto" ]]; then
        #   if [[ -z $received_model_name ]]; then
        #     announce "❌ Unable to detect stack model!"
        #     exit 1
        #   fi

        #   export LLMDBENCH_DEPLOY_CURRENT_MODEL=$received_model_name
        #   export LLMDBENCH_DEPLOY_CURRENT_MODELID=$(model_attribute $LLMDBENCH_DEPLOY_CURRENT_MODEL modelid)
        #   export _stack_name=$(echo ${method} | $LLMDBENCH_CONTROL_SCMD 's^modelservice^llm-d^g')-$(model_attribute $LLMDBENCH_DEPLOY_CURRENT_MODEL parameters)-$(model_attribute $LLMDBENCH_DEPLOY_CURRENT_MODEL modeltype)
        #   export LLMDBENCH_DEPLOY_CURRENT_TOKENIZER=$(model_attribute $LLMDBENCH_DEPLOY_CURRENT_MODEL model)

        #   announce "ℹ️ Stack model detected is \"$received_model_name\""

rm -rf ${_work_dir}/workload/profiles/*
mkdir -p ${_work_dir}/workload/profiles/${_harness_name}



    #     generate_profile_parameter_treatments ${_harness_name} ${LLMDBENCH_HARNESS_EXPERIMENT_TREATMENTS}

    #     workload_template_full_path=$(find ${LLMDBENCH_MAIN_DIR}/workload/profiles/${_harness_name}/ | grep ${LLMDBENCH_HARNESS_EXPERIMENT_PROFILE} | head -n 1 || true)
    #     if [[ -z $workload_template_full_path ]]; then
    #       announce "❌ Could not find workload template \"$LLMDBENCH_HARNESS_EXPERIMENT_PROFILE\" inside directory \"${LLMDBENCH_MAIN_DIR}/workload/profiles/${_harness_name}/\" (variable $LLMDBENCH_HARNESS_EXPERIMENT_PROFILE)"
    #       exit 1
    #     fi

    #     render_workload_templates ${LLMDBENCH_HARNESS_EXPERIMENT_PROFILE}
    #     export LLMDBENCH_HARNESS_PROFILE_HARNESS_LIST=$_harness_name

    #     export LLMDBENCH_RUN_EXPERIMENT_HARNESS=$(find ${LLMDBENCH_MAIN_DIR}/workload/harnesses -name ${_harness_name}* | rev | cut -d '/' -f1 | rev)
    #     export LLMDBENCH_RUN_EXPERIMENT_ANALYZER=$(find ${LLMDBENCH_MAIN_DIR}/analysis/ -name ${_harness_name}* | rev | cut -d '/' -f1 | rev)

    #   fi

$kubectl 


      for workload_type in ${LLMDBENCH_HARNESS_PROFILE_HARNESS_LIST}; do
        llmdbench_execute_cmd "${$kubectl} --namespace ${_harness_nameSPACE} delete configmap $workload_type-profiles --ignore-not-found" ${$kubectl} ${LLMDBENCH_CONTROL_VERBOSE}
        llmdbench_execute_cmd "${$kubectl} --namespace ${_harness_nameSPACE} create configmap $workload_type-profiles --from-file=${_work_dir}/workload/profiles/${workload_type}" ${$kubectl} ${LLMDBENCH_CONTROL_VERBOSE}
      done

      export LLMDBENCH_RUN_EXPERIMENT_ID_PREFIX=""

      for treatment in $(ls ${_work_dir}/workload/profiles/${workload_type}/*.yaml); do

        export LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME=$(echo $treatment | rev | cut -d '/' -f 1 | rev)
        export LLMDBENCH_HARNESS_EXPERIMENT_PROFILE=$(echo $treatment | rev | cut -d '/' -f 1 | rev)

        tf=$(cat ${treatment} | grep "#treatment" | tail -1 | $LLMDBENCH_CONTROL_SCMD 's/^#//' || true)
        if [[ -f ${_work_dir}/workload/profiles/${workload_type}/treatment_list/$tf ]]; then
          tid=$(sed -e 's/[^[:alnum:]][^[:alnum:]]*/_/g' <<<"${tf%.txt}")   # remove non alphanumeric and .txt
          tid=${tid#treatment_}
          if [ -z "${LLMDBENCH_RUN_EXPERIMENT_ID}" ]; then
            export LLMDBENCH_RUN_EXPERIMENT_ID=$(date +%s)-${tid}
          else
            if [[ -z $LLMDBENCH_RUN_EXPERIMENT_ID_PREFIX ]]; then
              export LLMDBENCH_RUN_EXPERIMENT_ID_PREFIX=$LLMDBENCH_RUN_EXPERIMENT_ID
            fi
            export LLMDBENCH_RUN_EXPERIMENT_ID=${LLMDBENCH_RUN_EXPERIMENT_ID_PREFIX}-${tid}
          fi

          echo
          cat ${_work_dir}/workload/profiles/${workload_type}/treatment_list/$tf | grep -v ^1i# | cut -d '^' -f 3
          echo
        fi

        # Assemble the pod specifications and build the workload

        for i in $(seq 1 $LLMDBENCH_HARNESS_LOAD_PARALLELISM); do
          _pod_name="${LLMDBENCH_RUN_HARNESS_LAUNCHER_NAME}-${i}-of-${LLMDBENCH_HARNESS_LOAD_PARALLELISM}"

          export LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX=${_harness_name}_${LLMDBENCH_RUN_EXPERIMENT_ID}_${_stack_name}
          export LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR=${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_PREFIX}/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}_${i}

          local_results_dir=${_work_dir}/results/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}
          local_analysis_dir=${_work_dir}/analysis/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}
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
            create_harness_pod ${_pod_name} "${_work_dir}/${_pod_name}"
          fi
        done

        _combined_pod_config="${_work_dir}/setup/yamls/${_harness_name}_${LLMDBENCH_RUN_EXPERIMENT_ID}_${_stack_name}.yaml"
        rm -rf ${_combined_pod_config}
        touch ${_combined_pod_config}
        for i in $(seq 1 "$LLMDBENCH_HARNESS_LOAD_PARALLELISM"); do
            _pod_name="${LLMDBENCH_RUN_HARNESS_LAUNCHER_NAME}-${i}-of-${LLMDBENCH_HARNESS_LOAD_PARALLELISM}"
            _yaml_path="${_work_dir}/${_pod_name}/setup/yamls/pod_benchmark-launcher.yaml"

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
