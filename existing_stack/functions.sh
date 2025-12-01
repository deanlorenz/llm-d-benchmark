
HARNESS_POD_LABEL="llmdbench-harness-launcher"
HARNESS_EXECUTABLE="llm-d-benchmark.sh"
HARNESS_CPU_NR=16
HARNESS_CPU_MEM=32Gi
RUN_EXPERIMENT_RESULTS_DIR_PREFIX=/requests

function announce {
    # 1 - MESSAGE
    # 2 - LOGFILE
    echo ">>>>>>--------------------"
    local message=$(echo ${1})
    local logfile=${2:-1}

    if [[ ! -z ${logfile} ]]
    then
        if [[ ${logfile} == "silent" || ${logfile} -eq 0 ]]
        then
            echo -e "==> $(date) - ${0} - $message" >> /dev/null
        elif [[ ${logfile} -eq 1 ]]
        then
            echo -e "==> $(date) - ${0} - $message"
        else
            echo -e "==> $(date) - ${0} - $message" >> ${logfile}
        fi
    else
        echo -e "==> $(date) - ${0} - $message"
    fi
    echo "<<<<<<<<--------------------"
}
export -f announce


function create_harness_pod {

  local _podname=$1

  harness_dataset_file=${harness_dataset_path##*/}
  harness_dataset_dir=${harness_dataset_path%/$harness_dataset_file}

  mkdir -p "${control_work_dir}/setup/yamls"
  cat <<EOF > ${control_work_dir}/setup/yamls/pod_benchmark-launcher.yaml #@TODO Change file name (may be to pod name)
apiVersion: v1
kind: Pod
metadata:
  name: ${_podname}
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
    - "${HARNESS_EXECUTABLE}"
    resources:
      limits:
        cpu: "${HARNESS_CPU_NR}"
        memory: ${HARNESS_CPU_MEM}
      requests:
        cpu: "${HARNESS_CPU_NR}"
        memory: ${HARNESS_CPU_MEM}
    env:
    # - name: LLMDBENCH_RUN_DATASET_URL
    #   value: "${harness_dataset_url}"
    # - name: LLMDBENCH_RUN_WORKSPACE_DIR
    #   value: "${harness_dataset_dir}"
    # - name: LLMDBENCH_HARNESS_NAME
    #   value: "${harness_name}"
    # - name: LLMDBENCH_CONTROL_WORK_DIR
    #   value: "${RUN_EXPERIMENT_RESULTS_DIR_PREFIX}/${harness_name}"
    # - name: LLMDBENCH_HARNESS_NAMESPACE
    #   value: "${harness_namespace}"
    # - name: LLMDBENCH_HARNESS_STACK_ENDPOINT_URL
    #   value: "${endpoint_base_url}"
    # - name: LLMDBENCH_HARNESS_STACK_NAME
    #   value: "${endpoint_stack_name}"
    # - name: LLMDBENCH_HARNESS_LOAD_PARALLELISM
    #   value: "${harness_parallelism}"
    # - name: LLMDBENCH_MAGIC_ENVAR
    #   value: "harness_pod"
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
      mountPath: ${RUN_EXPERIMENT_RESULTS_DIR_PREFIX}
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
}
export -f create_harness_pod
