if uname -s | grep -qi darwin; then
  alias sed=gsed  
fi

# Constants
HARNESS_POD_LABEL="llmdbench-harness-launcher"
HARNESS_EXECUTABLE="llm-d-benchmark.sh"
HARNESS_CPU_NR=16
HARNESS_CPU_MEM=32Gi
RESULTS_DIR_PREFIX=/requests
CONTROL_WAIT_TIMEOUT=180

# Log announcement function
function announce {
    # 1 - MESSAGE
    # 2 - LOGFILE

    local message=$(echo ${1})
    local logfile=${2:-none}

    case ${logfile} in
        none|""|"1")
            echo -e "==> $(date) - ${0} - $message"
            ;;
        silent|"0")
            ;;
        *)
            echo -e "==> $(date) - ${0} - $message" >> ${logfile}
            ;;  
    esac
}
export -f announce

# Sanitize pod name to conform to Kubernetes naming conventions
function sanitize_pod_name {
  sed -e 's/[^0-9A-Za-z-][^0-9A-Za-z-]*/./g' <<<"$1"
}
export -f sanitize_pod_name

# Sanitize directory name to conform to filesystem naming conventions
function sanitize_dir_name {
  sed -e 's/[^0-9A-Za-z-_][^0-9A-Za-z-_]*/_/g' <<<"$1"
}
export -f sanitize_dir_name

# Generate results directory name
function results_dir_name {
  local stack_name="$1"
  local harness_name="$2"
  local experiment_id="$3"
  local workload_name="${4:+_$4}"

  sanitize_dir_name "${RESULTS_DIR_PREFIX}/${harness_name}_${experiment_id}${workload_name}_${stack_name}"
} 
export -f results_dir_name  

# Retrieve full image name with tag
function get_image {
  local image_registry=$1
  local image_repo=$2
  local image_name=$3
  local image_tag=$4
  local tag_only=${5:-0}

  is_latest_tag=$image_tag
  if [[ $image_tag == "auto" ]]; then
    if [[ $LLMDBENCH_CONTROL_CCMD == "podman" ]]; then
      is_latest_tag=$($LLMDBENCH_CONTROL_CCMD search --list-tags --limit 1000 ${image_registry}/${image_repo}/${image_name} | tail -1 | awk '{ print $2 }' || true)
    else
      is_latest_tag=$(skopeo list-tags docker://${image_registry}/${image_repo}/${image_name} | jq -r .Tags[] | tail -1)
    fi
    if [[ -z ${is_latest_tag} ]]; then
      announce "❌ Unable to find latest tag for image \"${image_registry}/${image_repo}/${image_name}\"" >&2
      exit 1
    fi
  fi
  if [[ $tag_only -eq 1 ]]; then
    echo ${is_latest_tag}
  else
    echo $image_registry/$image_repo/${image_name}:${is_latest_tag}
  fi
}
export -f get_image

# Retrieve list of available harnesses
function get_harness_list {
  ls ${LLMDBENCH_MAIN_DIR}/workload/harnesses | $LLMDBENCH_CONTROL_SCMD -e 's^inference-perf^inference_perf^' -e 's^vllm-benchmark^vllm_benchmark^' | cut -d '-' -f 1 | $LLMDBENCH_CONTROL_SCMD -n -e 's^inference_perf^inference-perf^' -e 's^vllm_benchmark^vllm-benchmark^' -e 'H;${x;s/\n/,/g;s/^,//;p;}'
}
export -f get_harness_list

function create_harness_pod {

  local pod_name=$1
  local harness_dataset_file=${harness_dataset_path##*/}
  local harness_dataset_dir=${harness_dataset_path%/$harness_dataset_file}
  # run_experiment_results_dir=${RESULTS_DIR_PREFIX}/"${harness_name}_${_uid}_${endpoint_stack_name}"
  # run_experiment_results_dir=$(results_dir_name "${endpoint_stack_name}" "${harness_name}" "${_uid}")
  experiment_analyzer=$(find ${_root_dir}/analysis/ -name ${harness_name}* | rev | cut -d '/' -f1 | rev)

  ${control_kubectl} --namespace ${harness_namespace} delete pod ${pod_name} --ignore-not-found

# mkdir -p "${control_work_dir}/setup/yamls"

  cat <<EOF | ${control_kubectl} apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${harness_namespace}
  labels:
    app: ${HARNESS_POD_LABEL}
spec:
  containers:
  - name: harness
    image: ${harness_image}
    imagePullPolicy: Always
    securityContext:
      runAsUser: 0
    command: ["sh", "-c"]
    args:
    - "sleep 1000000"
    resources:
      limits:
        cpu: "${HARNESS_CPU_NR}"
        memory: ${HARNESS_CPU_MEM}
      requests:
        cpu: "${HARNESS_CPU_NR}"
        memory: ${HARNESS_CPU_MEM}
    env:
    # - name: LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR
    #   value: "NOT USING AUTO"
    - name: LLMDBENCH_RUN_WORKSPACE_DIR
      value: "/workspace"
    # - name: LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME
    #   value: "NOT USING AUTO"
    # - name: LLMDBENCH_RUN_EXPERIMENT_HARNESS
    #   value: "NOT USING AUTO"
    # - name: LLMDBENCH_RUN_EXPERIMENT_ANALYZER
    #   value: "NOT USING AUTO"
    - name: LLMDBENCH_MAGIC_ENVAR
      value: "harness_pod"
    # - name: LLMDBENCH_DEPLOY_METHODS
    #   value: ""
    - name: LLMDBENCH_HARNESS_NAME
      value: "${harness_name}"
    # - name: LLMDBENCH_RUN_EXPERIMENT_ID
    #   value: "${_uid}"
    - name: LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_PREFIX
      value: "${RESULTS_DIR_PREFIX}"
    # - name: LLMDBENCH_BASE64_CONTEXT_CONTENTS
    #   value: "DO NOT TRANSFER FOR NOW"
    # - name: LLMDBENCH_RUN_DATASET_DIR
    #   value: "DO NOT TRANSFER FOR NOW"
    # - name: LLMDBENCH_RUN_DATASET_URL
    #   value: "DO NOT TRANSFER FOR NOW"
    - name: LLMDBENCH_HARNESS_STACK_NAME
      value: "${endpoint_stack_name}"  
    # - name: HF_TOKEN_SECRET
    #   value: "${endpoint_hf_token_secret}"
    # - name: HUGGING_FACE_HUB_TOKEN
    #   valueFrom:
    #     secretKeyRef:
    #       name: ${endpoint_hf_token_secret}
    #       key: HF_TOKEN
    # - name: POD_NAME
    #   valueFrom:
    #     fieldRef:
    #       fieldPath: metadata.name
    volumeMounts:
    - name: results
      mountPath: ${RESULTS_DIR_PREFIX}
    - name: "${harness_name}-profiles"
      mountPath: /workspace/profiles/${harness_name}  
  volumes:
  - name: results
    persistentVolumeClaim:
      claimName: $harness_results_pvc
  - name: ${harness_name}-profiles    
    configMap:
      name: ${harness_name}-profiles
  restartPolicy: Never    
EOF

  echo ${control_kubectl} wait --for=condition=Ready=True pod ${pod_name} -n ${harness_namespace} --timeout="${CONTROL_WAIT_TIMEOUT}s"

  ${control_kubectl} wait --for=condition=Ready=True pod ${pod_name} -n ${harness_namespace} --timeout="${CONTROL_WAIT_TIMEOUT}s"
  if [[ $? != 0 ]]; then
    announce "❌ Timeout waiting for pod ${pod_name} to get ready"
    exit 1
  fi
  announce "ℹ️ Harness pod ${pod_name} started"
  ${control_kubectl} describe pod ${pod_name} -n ${harness_namespace}
}
export -f create_harness_pod

#@TODO delete launcher if exists!!!

function deploy_harness_config {
    local model=$1
    local modelid=$2
    local local_results_dir=$3
    local local_analysis_dir=$4
    local config=$5

    announce "🚀 Starting ${LLMDBENCH_HARNESS_LOAD_PARALLELISM} pod(s) labeled with \"${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" ($modelid)..."
    llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} apply -f $config" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
    announce "✅ ${LLMDBENCH_HARNESS_LOAD_PARALLELISM} pod(s) \"${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" started"

    announce "⏳ Waiting for ${LLMDBENCH_HARNESS_LOAD_PARALLELISM} pod(s) \"${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" to be Running (timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s)..."
    llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} wait --for=condition=Ready=True pod -l app=${LLMDBENCH_HARNESS_POD_LABEL} -n ${LLMDBENCH_HARNESS_NAMESPACE} --timeout=${LLMDBENCH_CONTROL_WAIT_TIMEOUT}s" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
    announce "ℹ️ You can follow the execution's output with \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} logs ${LLMDBENCH_HARNESS_POD_LABEL}_<PARALLEL_NUMBER> -f\"..."

    # Identify the shared data-access pod
    LLMDBENCH_HARNESS_ACCESS_RESULTS_POD_NAME=$(${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} get pod -l role=llm-d-benchmark-data-access --no-headers -o name | $LLMDBENCH_CONTROL_SCMD 's|^pod/||g')

    # Only perform completion checks if debug mode is off and timeout is non-zero
    if [[ $LLMDBENCH_HARNESS_DEBUG -eq 0 && ${LLMDBENCH_HARNESS_WAIT_TIMEOUT} -ne 0 ]]; then
        announce "⏳ Waiting for pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\" to complete (timeout=${LLMDBENCH_HARNESS_WAIT_TIMEOUT}s)..."
        llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} wait \
            --timeout=${LLMDBENCH_HARNESS_WAIT_TIMEOUT}s --for=condition=ready=False pod -l app=${LLMDBENCH_HARNESS_POD_LABEL}" \
            ${LLMDBENCH_CONTROL_DRY_RUN} \
            ${LLMDBENCH_CONTROL_VERBOSE}
        if ${LLMDBENCH_CONTROL_KCMD} --namespace "${LLMDBENCH_HARNESS_NAMESPACE}" get pods \
                -l "app=${LLMDBENCH_HARNESS_POD_LABEL}" \
                --no-headers | grep -Eq "CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull"
        then
            announce "❌ Found some pods are in an error state. To list pods \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} get pods -l app=${LLMDBENCH_HARNESS_POD_LABEL}\""
            exit 1
        fi
        announce "✅ All benchmark pods completed"

        announce "🏗️ Collecting results for pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\"..."
        for i in $(seq 1 "$LLMDBENCH_HARNESS_LOAD_PARALLELISM"); do
            # Per-pod directories
            pod_results_dir="${local_results_dir}_${i}"
            pod_analysis_dir="${local_analysis_dir}_${i}"

            # Path inside the pod for this workload
            _results_dir="${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_PREFIX}/${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR_SUFFIX}_${i}"

            # Copy results from data-access pod to local results directory
            copy_results_cmd="${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} cp --retries=5 \
                ${LLMDBENCH_HARNESS_ACCESS_RESULTS_POD_NAME}:${_results_dir} ${pod_results_dir}"

            # Sync 'analysis' folder to analysis dir and clean up
            copy_analysis_cmd="rsync -az --inplace --delete \
                ${pod_results_dir}/analysis/ ${pod_analysis_dir}/ && rm -rf ${pod_results_dir}/analysis"

            llmdbench_execute_cmd "${copy_results_cmd}" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
            if [[ -d ${pod_results_dir}/analysis && $LLMDBENCH_HARNESS_DEBUG -eq 0 && ${LLMDBENCH_HARNESS_WAIT_TIMEOUT} -ne 0 ]]; then
                llmdbench_execute_cmd "$copy_analysis_cmd" ${LLMDBENCH_CONTROL_DRY_RUN} ${LLMDBENCH_CONTROL_VERBOSE}
            fi
        done
        announce "✅ Collected results for pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\" at: \"${LLMDBENCH_CONTROL_WORK_DIR}/results/\""
        announce "✅ Collected analysis for pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\" at: \"${LLMDBENCH_CONTROL_WORK_DIR}/analysis/\""

        announce "🗑️ Deleting pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" ..."
        llmdbench_execute_cmd "${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} delete pod -l app=${LLMDBENCH_HARNESS_POD_LABEL}" \
            ${LLMDBENCH_CONTROL_DRY_RUN} \
            ${LLMDBENCH_CONTROL_VERBOSE}
        announce "✅ Pods with label \"app=${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" deleted"
    elif [[ $LLMDBENCH_HARNESS_WAIT_TIMEOUT -eq 0 ]]; then
      announce "ℹ️ Harness was started with LLMDBENCH_HARNESS_WAIT_TIMEOUT=0. Will NOT wait for pod \"${LLMDBENCH_HARNESS_POD_LABEL}\" for model \"$model\" to be in \"Completed\" state. The pod can be accessed through \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} exec -it pod/<POD_NAME> -- bash\""
      announce "ℹ️ To list pod names \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} get pods -l app=${LLMDBENCH_HARNESS_POD_LABEL}\""
    else
      announce "ℹ️ Harness was started in \"debug mode\". The pod can be accessed through \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} exec -it pod/<POD_NAME> -- bash\""
      announce "ℹ️ To list pod names \"${LLMDBENCH_CONTROL_KCMD} --namespace ${LLMDBENCH_HARNESS_NAMESPACE} get pods -l app=${LLMDBENCH_HARNESS_POD_LABEL}\""
      announce "ℹ️ In order to execute a given workload profile, run \"llm-d-benchmark.sh -l <[$(get_harness_list)]> -w [WORKLOAD FILE NAME]\" (all inside the pod <POD_NAME>)"
    fi

    return 0
}
export -f deploy_harness_config
