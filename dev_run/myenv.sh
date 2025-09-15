# Main Namespace  !! make sure you are logged in to the cluster in the correct namespace/project
# ==============
if [[ -z "${LLMDBENCH_VLLM_COMMON_NAMESPACE:-}" ]]; then
  export LLMDBENCH_VLLM_COMMON_NAMESPACE=${LLMDBENCH_VLLM_HARNESS_NAMESPACE:-$(oc config current-context | awk -F / '{print $1}')}
fi
# derived NSs
# ===========
export LLMDBENCH_FMPERF_NAMESPACE=${LLMDBENCH_VLLM_COMMON_NAMESPACE}
export LLMDBENCH_VLLM_HARNESS_NAMESPACE=${LLMDBENCH_VLLM_COMMON_NAMESPACE}
echo "==> Using namespace $LLMDBENCH_VLLM_COMMON_NAMESPACE. Use -p to override."

# HF TOKEN
# ========
export HF_TOKEN_NAME=llm-d-hf-token  # change this if your secret is under another name
#export HF_TOKEN=<_your HuggingFace Token_>
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo
  echo "HF_TOKEN not set."
  echo "Please modify $(grep -Hn '^#export HF_TOKEN=' ${BASH_SOURCE[0]})"
  echo "==> Fetching token from current namespace (secret $HF_TOKEN_NAME)."
  export HF_TOKEN=$(oc get secrets "${HF_TOKEN_NAME}" -o jsonpath='{.data.*}' | base64 -d)
fi
export LLMDBENCH_HF_TOKEN=${HF_TOKEN}

# LLMDBENCH frozen version (image uses specific versions of fmperf and inference-perf)
# ========================
export LLMDBENCH_IMAGE_TAG=v0.2.2_fix
export LLMDBENCH_IMAGE_REPO=dpikus
export LLMDBENCH_IMAGE_NAME=llm-d-benchmark
export LLMDBENCH_IMAGE_REGISTRY=quay.io

# DEV INFRA frozen version
# ========================
export LLMDBENCH_INFRA_GIT_REPO=https://github.com/deanlorenz/llm-d-infra.git
export LLMDBENCH_INFRA_GIT_BRANCH=dev

# DIRECTORIES
# ===========
export TMPDIR=/tmp
base_dir="$(cd $(dirname $(readlink -f ${BASH_SOURCE[0]})) && pwd)"  # Use script dir
export LLMDBENCH_HARNESS_DIR="${LLMDBENCH_HARNESS_DIR:-$TMPDIR}"
# This is the benchmark work directory:
export LLMDBENCH_CONTROL_WORK_DIR="${LLMDBENCH_CONTROL_WORK_DIR:-${base_dir}/${LLMD_NAMESPACE}}"
export LLMDBENCH_INFRA_DIR="${LLMDBENCH_INFRA_DIR:-$TMPDIR}"
echo "==> Using work directory $LLMDBENCH_CONTROL_WORK_DIR"

# STORAGE
# =======
if [[ -z "${LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS:-}" ]]; then
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-pokprod
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-simplenfs
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ibm-spectrum-scale-fileset  # pokprod
  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ocs-storagecluster-cephfs  # fusionv6, fmaas-vllm-d
fi
# Persistent Volume Claim where benchmark results will be stored 
# (if omitted will attempt to create PVC named "workload-pvc" using the storage class)
#export LLMDBENCH_HARNESS_PVC_NAME="<_name of your Harness PVC_>"
if [ -z "${LLMDBENCH_HARNESS_PVC_NAME:-}" ]; then
  echo
  echo "Missing harness PVC name."
  echo "Please modify $(grep -Hn '^#export LLMDBENCH_HARNESS_PVC_NAME=' ${BASH_SOURCE[0]})"
  # echo "==> Will use/create 'workload-pvc'."
  oc get pvc 
  read -p "Enter harness PVC name (for benchmark results collection): " LLMDBENCH_HARNESS_PVC_NAME
  export LLMDBENCH_HARNESS_PVC_NAME
  echo "export LLMDBENCH_HARNESS_PVC_NAME=$LLMDBENCH_HARNESS_PVC_NAME"
fi

# Persistent Volume Claim where model is downloaded
# (if omitted will attempt to create PVC named "model-pvc" using the storage class)
#export LLMDBENCH_VLLM_COMMON_PVC_NAME="<_name of your model PVC_>"
if [ -z "${LLMDBENCH_VLLM_COMMON_PVC_NAME:-}" ]; then
  echo
  echo "Missing common PVC name."
  echo "Please modify $(grep -Hn '^#export LLMDBENCH_VLLM_COMMON_PVC_NAME=' ${BASH_SOURCE[0]})"
  # echo "==> Will use 'model-pvc'."
  oc get pvc 
  read -p "Enter common PVC name (for cache and model): " LLMDBENCH_VLLM_COMMON_PVC_NAME
  export LLMDBENCH_VLLM_COMMON_PVC_NAME
  echo "export LLMDBENCH_VLLM_COMMON_PVC_NAME=$LLMDBENCH_VLLM_COMMON_PVC_NAME"
fi

# HARNESS
# =======
export LLMDBENCH_HARNESS_NAME="inference-perf"
echo "==> Using harness $LLMDBENCH_HARNESS_NAME. Use -l to override."

# ENDPOINT and MODEL
# ==================
# servicename="$(oc get service -l gateway.networking.k8s.io/gateway-name -o name)"
servicename="$(oc get service -l gateway.networking.k8s.io/gateway-name -o=jsonpath='{.items[].metadata.name}')"
export LLMDBENCH_DEPLOY_METHODS="${servicename}"  # alternatively, can use vLLM name
echo "==> Running benchmark to service $servicename. Use -t to override"

endpoint=$(
  oc get route -l gateway.networking.k8s.io/gateway-name \
    -o custom-columns='SERVICE:{.spec.to.name},HOST:{.spec.host},PORT:{.spec.port.targetPort}' |
  awk -v service="$servicename" '$1==service  {gsub(":default$", ":80", $2); print "http://" $2; exit}'
)
modelname="$(curl -s ${endpoint}/v1/models | jq -r '.data[].id')"

export LLMDBENCH_DEPLOY_MODEL_LIST="${modelname}"  # use your <_full model name_>
echo "==> Using model $modelname. Use -m to override."

# TIMEOUT
# =======
# This is a timeout (seconds) for running a full test
# If time expires the benchmark will still run but results will not be collected to local computer.
export LLMDBENCH_HARNESS_WAIT_TIMEOUT=3600
echo "==> Timeout set to $LLMDBENCH_HARNESS_WAIT_TIMEOUT. Use -s to override"

