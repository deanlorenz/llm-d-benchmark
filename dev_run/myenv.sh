# Main Namespace  !! make sure you are logged in to the cluster in the correct namespace/project
# ==============
export LLMD_NAMESPACE=$(oc config current-context | awk -F / '{print $1}')

# HF TOKEN
# ========
export HF_TOKEN_NAME=llm-d-hf-token  # change this if your secret is under another name
export HF_TOKEN=${HF_TOKEN:-$(oc get secrets "${HF_TOKEN_NAME}" -o jsonpath='{.data.*}' | base64 -d)}  # or set to your own
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

# derived NSs
# ===========
export LLMDBENCH_FMPERF_NAMESPACE=${LLMD_NAMESPACE}
export LLMDBENCH_VLLM_COMMON_NAMESPACE=${LLMD_NAMESPACE}
export LLMDBENCH_VLLM_HARNESS_NAMESPACE=${LLMD_NAMESPACE}

# DIRECTORIES
# ===========
export TMPDIR=/tmp
base_dir="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"  # Use script dir
export LLMDBENCH_HARNESS_DIR=${LLMDBENCH_HARNESS_DIR:-$TMPDIR}
# This is the benchmark work directory:
export LLMDBENCH_CONTROL_WORK_DIR=${LLMDBENCH_CONTROL_WORK_DIR:-${base_dir}/${LLMD_NAMESPACE}}

# STORAGE
# =======
if [[ ! -v LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS ]]; then
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-pokprod
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-simplenfs
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ibm-spectrum-scale-fileset  # pokprod
  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ocs-storagecluster-cephfs  # fusionv6, fmaas-vllm-d
fi
# Persistent Volume Claim where benchmark results will be stored 
# (if omitted will attempt to create PVC named "workload-pvc" using the storage class)
export LLMDBENCH_HARNESS_PVC_NAME="<_name of your Harness PVC_>"  # Optional
# Persistent Volume Claim where model is downloaded
# (if omitted will attempt to create PVC named "model-pvc" using the storage class)
export LLMDBENCH_VLLM_COMMON_PVC_NAME="<_name of your model PVC_>"  # Optional

# HARNESS
# =======
export LLMDBENCH_HARNESS_NAME="inference-perf"

# ENDPOINT and MODEL
# ==================
endpoint=$(
  oc get route -l gateway.networking.k8s.io/gateway-name \
    -o custom-columns='NAME:{.metadata.name},HOST:{.spec.host},PORT:{.spec.port.targetPort}' |
  awk '$1 ~ /inference-gateway/ {gsub(":default$", ":80", $2); print "http://" $2; exit}'
)
modelname="$(curl -s ${endpoint}/v1/models | jq -r '.data[].id')"

export LLMDBENCH_DEPLOY_METHODS="${modelname}"  # use your <_full model name_>

# TIMEOUT
# =======
# This is a timeout (seconds) for running a full test
# If time expires the benchmark will still run but results will not be collected to local computer.
export LLMDBENCH_HARNESS_WAIT_TIMEOUT=3600

