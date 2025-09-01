export LLMD_NAMESPACE=hrl-test

export HF_TOKEN_NAME=llm-d-hf-token
export HF_TOKEN=$(oc get secrets llm-d-hf-token -o jsonpath='{.data.*}' | base64 -d)  # FIXME
export LLMDBENCH_HF_TOKEN=${HF_TOKEN}


# LLMDBENCH stable version
export LLMDBENCH_IMAGE_TAG=v0.2.2_fix
export LLMDBENCH_IMAGE_REPO=dpikus
export LLMDBENCH_IMAGE_NAME=llm-d-benchmark
export LLMDBENCH_IMAGE_REGISTRY=quay.io

# DEV INFRA stable version
# export LLMDBENCH_INFRA_GIT_REPO=git@github.com:deanlorenz/llm-d-infra.git
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
export WORK_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"  # Use script dir
export LLMDBENCH_HARNESS_DIR=${LLMDBENCH_HARNESS_DIR:-$TMPDIR}
export LLMDBENCH_CONTROL_WORK_DIR=${LLMDBENCH_CONTROL_WORK_DIR:-${WORK_DIR}/${LLMD_NAMESPACE}}


# STORAGE
# =======
if [[ ! -v LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS ]]; then
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-pokprod
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ocs-storagecluster-cephfs
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=nfs-client-simplenfs
  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ibm-spectrum-scale-fileset
#  export LLMDBENCH_VLLM_COMMON_PVC_STORAGE_CLASS=ocs-storagecluster-cephfs
fi

