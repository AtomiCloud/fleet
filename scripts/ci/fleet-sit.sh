#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2153
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/../.." && pwd)"
validation_dir="${root}/scripts/validate/fleet-sit"
script_path="${root}/scripts/ci/fleet-sit.sh"

# shellcheck source=scripts/validate/fleet-sit/pins.env
source "${validation_dir}/pins.env"
# shellcheck source=scripts/validate/fleet-sit/assert.sh
source "${validation_dir}/assert.sh"

mode='full'
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--prepare-only]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  case "$1" in
  --prepare-only) mode='prepare' ;;
  --full) mode='full' ;;
  *)
    echo "usage: $0 [--prepare-only]" >&2
    exit 2
    ;;
  esac
fi

cd "${root}"

# Keep the hard deadline outside the stateful worker so TERM still runs the
# worker's evidence and cleanup traps.
#
# Short options only. This line runs on the instance, whose timeout is not
# guaranteed to accept the GNU long spellings; BusyBox documents `-s` and `-k`
# but not `--signal`/`--kill-after`, and the generation-11 history already lost
# one live attempt to exactly that class of assumption with `sha256sum --check`.
# `-k 30` and the bare `4200` keep the same 30-second TERM-to-KILL allowance and
# 4200-second deadline as the long form they replace.
if [ "${mode}" = 'full' ] && [ "${FLEET_SIT_UNDER_TIMEOUT:-0}" != '1' ]; then
  export FLEET_SIT_UNDER_TIMEOUT=1
  exec timeout -s TERM -k 30 4200 "${script_path}" --full
fi

# The direct inputs this SIT reads or copies, as fixed pathspec ROOTS. The
# inventory is derived from the recorded git tree under these roots - never
# from live `find` output and never as a hand-maintained file list, so an input
# added under a root is bound automatically.
SIT_DIRECT_INPUT_ROOTS=(
  'platforms/canary'
  'registry/argocd-webhook-secret.yaml'
  'registry/charts/diene-platform'
  'registry/fixtures/clusters'
  'registry/fixtures/negative'
  'registry/machinery-stable.yaml'
  'registry/platforms-appset.yaml'
  'scripts/ci/fleet-sit-proof.sh'
  'scripts/ci/fleet-sit.sh'
  'scripts/validate/fleet-sit'
)

work=''
sit_tmp_root="${TMPDIR:-/tmp}"
report=''
namespace_platform_ready=0
namespace_instance_id=''
namespace_node_name=''
namespace_node_internal_ip=''
namespace_installed_packages='[]'
report_active=0
cleanup_started=0
# Harness-log FIFO state. Every one of these is finalizer-visible on purpose:
# finalization must close and remove whatever setup managed to initialize, even
# if it failed before a reader was ever launched.
SIT_LOG_FIFO=''
SIT_LOG_TEE_PID=''
SIT_LOG_BOOT_FD=''
SIT_LOG_WRITER_FD=''
SIT_LOG_SAVED_OUT=''
SIT_LOG_SAVED_ERR=''
SIT_LOG_ARMED=0
SIT_LOG_FINALIZED=0
final_evidence_collected=0
GIT_SERVER_PID=''
PF_SERVER_PID=''
PF_APPSET_PID=''
GIT_SERVER_PORT=''
PF_SERVER_PORT=''
PF_APPSET_PORT=''
FLEET_REPO_URL=''
FLEET_SERVICES_REPO_URL=''
CANARY_REPO_URL=''
SITOTHER_REPO_URL=''
SIT_SECRET=''
FLEET_SOURCE=''
FLEET_BARE=''
FLEET_LAST_COMMIT=''
COMMIT_SEQUENCE=1
HARNESS_SHA256=''
HARNESS_FILE_COUNT=''
DIRECT_INPUT_SHA256=''
DIRECT_INPUT_FILE_COUNT=''
SIT_SOURCE_HEAD=''
SIT_CHECKOUT=''
SIT_SNAPSHOT_TREE=''
KARGO_CRD_DIR=''
KARGO_RUNTIME_IMAGE_REF="${KARGO_IMAGE_REPOSITORY}:${KARGO_IMAGE_TAG}@${KARGO_IMAGE_DIGEST}"
ROLLOUTS_RUNTIME_IMAGE_REF="${ROLLOUTS_IMAGE_REPOSITORY}:${ROLLOUTS_IMAGE_TAG}@${ROLLOUTS_IMAGE_DIGEST}"
ANALYSIS_RUNTIME_IMAGE_REF="${ANALYSIS_IMAGE_REPOSITORY}:${ANALYSIS_IMAGE_TAG}@${ANALYSIS_IMAGE_DIGEST}"
KARGO_RUNTIME_DIR=''
KARGO_RUNTIME_IMAGE_REPO='registry.sit.invalid/canary/dummy'
KARGO_RUNTIME_CHART_REPO='oci://registry.sit.invalid/canary-dummy'
KARGO_RUNTIME_GIT_BASELINE=''

make_sit_scratch() {
  case "${sit_tmp_root}" in
  /*) ;;
  *)
    sit_fail "TMPDIR must be absolute: ${sit_tmp_root}"
    return 1
    ;;
  esac
  [ -d "${sit_tmp_root}" ] && [ -w "${sit_tmp_root}" ] || {
    sit_fail "TMPDIR is not a writable directory: ${sit_tmp_root}"
    return 1
  }
  mktemp -d "${sit_tmp_root%/}/fleet-sit.XXXXXX"
}

remove_sit_scratch() {
  local target="${1:-}"
  [ -n "${target}" ] && [ -d "${target}" ] || return 0
  if [[ ${target} == "${sit_tmp_root%/}"/fleet-sit.* ]]; then
    rm -rf -- "${target}"
    return 0
  fi
  echo "warning: declining to remove unrecognized fleet SIT scratch path: ${target}" >&2
  return 1
}

validate_inputs() {
  local command
  for command in bash bun curl docker git go helm jq kubectl openssl rg sha256sum timeout yq; do
    sit_require_command "${command}"
  done

  [ "${ARGOCD_VERSION}" = 'v3.4.5' ] || sit_fail 'ARGOCD_VERSION must remain v3.4.5'
  [[ ${ARGOCD_SOURCE_COMMIT} =~ ^[0-9a-f]{40}$ ]] || sit_fail 'invalid Argo CD source commit pin'
  [[ ${ARGOCD_MANIFEST_SHA256} =~ ^[0-9a-f]{64}$ ]] || sit_fail 'invalid Argo CD install-manifest checksum'
  [ "${NSC_CLI_VERSION}" = 'v0.0.532' ] || sit_fail 'nsc client version pin must remain v0.0.532'
  [[ ${NSC_CLI_COMMIT} =~ ^[0-9a-f]{40}$ ]] || sit_fail 'invalid nsc client commit pin'
  [ "${NSC_INSTANCE_ID_PATTERN}" = '^[a-z0-9]{13}$' ] ||
    sit_fail 'Namespace instance ids must remain exactly 13 lowercase alphanumeric characters'
  [ "${NSC_DURATION}" = '2h' ] && [ "${NSC_DURATION_SECONDS}" -eq 7200 ] ||
    sit_fail 'Namespace duration pin must remain exactly 2h'
  [ "${NSC_MACHINE_TYPE}" = '16x32' ] &&
    [ "${NSC_VCPU}" -eq 16 ] && [ "${NSC_MEMORY_MEGABYTES}" -eq 32768 ] ||
    sit_fail 'Namespace shape pin must remain exactly 16x32'
  [ "${NSC_KUBERNETES_VERSION}" = '1.33' ] ||
    sit_fail 'Namespace Kubernetes version pin must remain 1.33'
  [ "${NSC_K3S_VERSION}" = 'v1.33.1+k3s1' ] ||
    sit_fail 'built-in k3s version pin must remain v1.33.1+k3s1'
  [ "${NSC_BUSYBOX_PACKAGE}" = 'busybox' ] &&
    [ "${NSC_BUSYBOX_CANONICAL}" = '/usr/bin/busybox' ] ||
    sit_fail 'Namespace BusyBox package and canonical-path pins changed'
  [ "${NSC_GNU_BOOTSTRAP_PACKAGES}" = 'coreutils findutils sed grep gawk' ] ||
    sit_fail 'Namespace GNU bootstrap package pin changed'
  [ "${NSC_GIT_HTTP_BACKEND_PACKAGE}" = 'git-daemon' ] &&
    [ "${NSC_GIT_HTTP_BACKEND_CANONICAL}" = '/usr/libexec/git-core/git-http-backend' ] ||
    sit_fail 'Namespace Git smart-HTTP backend package and canonical-path pins changed'
  [ "${NSC_CONTAINERD_CTR}" = '/vendor/containerd/ctr' ] &&
    [ "${NSC_CONTAINERD_ADDRESS}" = '/var/run/containerd/containerd.sock' ] &&
    [ "${NSC_CONTAINERD_NAMESPACE}" = 'k8s.io' ] ||
    sit_fail 'Namespace platform containerd pins changed'
  [ "${KARGO_CHART_VERSION}" = '1.9.10' ] || sit_fail 'Kargo chart version must remain 1.9.10'
  [[ ${KARGO_CHART_DIGEST} =~ ^sha256:[0-9a-f]{64}$ ]] || sit_fail 'invalid Kargo chart OCI digest'
  [[ ${KARGO_CHART_ARCHIVE_SHA256} =~ ^[0-9a-f]{64}$ ]] || sit_fail 'invalid Kargo chart archive checksum'
  [[ ${KARGO_RUNTIME_IMAGE_REF} =~ @sha256:[0-9a-f]{64}$ ]] || sit_fail 'invalid Kargo runtime image reference'
  [[ ${ROLLOUTS_RUNTIME_IMAGE_REF} =~ @sha256:[0-9a-f]{64}$ ]] || sit_fail 'invalid Rollouts runtime image reference'
  [[ ${ANALYSIS_RUNTIME_IMAGE_REF} =~ @sha256:[0-9a-f]{64}$ ]] || sit_fail 'invalid analysis runtime image reference'
  [[ ${ROLLOUTS_MANIFEST_SHA256} =~ ^[0-9a-f]{64}$ ]] || sit_fail 'invalid Rollouts manifest checksum'
  [[ ${ARGOCD_MANIFEST_URL} == *"/${ARGOCD_VERSION}/manifests/install.yaml" ]] ||
    sit_fail 'Argo CD manifest URL and version pin disagree'
  [ -f registry/platforms-appset.yaml ] || sit_fail 'registry/platforms-appset.yaml is missing'
  [ -f registry/argocd-webhook-secret.yaml ] || sit_fail 'registry/argocd-webhook-secret.yaml is missing'
  [ -d registry/charts/diene-platform ] || sit_fail 'diene-platform compiler chart is missing'
  [ -d registry/fixtures/clusters ] || sit_fail 'registry/fixtures/clusters is missing'
  [ -f registry/machinery-stable.yaml ] || sit_fail 'registry/machinery-stable.yaml pointer file is missing'
}

# --- Namespace built-in-k3s substrate -------------------------------------

namespace_validate_instance_id() {
  local value="$1"
  [ -n "${value}" ] && [[ ${value} =~ ${NSC_INSTANCE_ID_PATTERN} ]] || {
    sit_fail "invalid Namespace instance id: ${value:-<missing>}"
    return 1
  }
}

namespace_prepare_tools() {
  [ "${FLEET_SIT_NAMESPACE_INNER:-}" = 'namespace-k3s-v1' ] ||
    sit_fail 'full mode is inner-only and requires the explicit Namespace recursion marker'
  namespace_instance_id="${FLEET_SIT_INSTANCE_ID:-}"
  namespace_validate_instance_id "${namespace_instance_id}"
  [ "$(hostname)" = "${namespace_instance_id}" ] ||
    sit_fail 'Namespace hostname does not equal the exact instance id'
  [ -r /etc/os-release ] || sit_fail 'Namespace instance has no readable /etc/os-release'
  local os_id
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  [ "${os_id}" = "${NSC_INSTANCE_OS_ID}" ] ||
    sit_fail "Namespace instance OS must be ${NSC_INSTANCE_OS_ID}, found ${os_id:-unknown}"

  local bootstrap
  for bootstrap in apk awk bash busybox curl docker git gzip head jq kubectl mkfifo nproc sed sha256sum tar tee timeout tr grep readlink; do
    sit_require_command "${bootstrap}"
  done
  [ -x "${NSC_CONTAINERD_CTR}" ] ||
    sit_fail "platform containerd client is missing: ${NSC_CONTAINERD_CTR}"
  sit_require_command k3s

  # The outer snapshot-setup command must install this exact GNU toolchain
  # before the climb worker starts. Prove every reviewed command is already
  # owned by its expected package family; never repair a missing bootstrap
  # here, where a partial climb would already be running.
  local -a gnu_packages=()
  read -r -a gnu_packages <<<"${NSC_GNU_BOOTSTRAP_PACKAGES}"
  [ "${#gnu_packages[@]}" -eq 5 ] ||
    sit_fail 'Namespace GNU bootstrap package list has unexpected cardinality'
  local gnu_entry gnu_command gnu_package gnu_path
  for gnu_entry in \
    'sed sed' \
    'grep grep' \
    'awk gawk' \
    'sha256sum coreutils' \
    'find findutils' \
    'date coreutils' \
    'stat coreutils' \
    'xargs findutils' \
    'cut coreutils' \
    'sort coreutils' \
    'head coreutils' \
    'timeout coreutils'; do
    gnu_command="${gnu_entry%% *}"
    gnu_package="${gnu_entry##* }"
    gnu_path="$(command -v "${gnu_command}" 2>/dev/null || true)"
    namespace_apk_owned_tool_receipt "${gnu_path}" "${gnu_package}" >/dev/null ||
      sit_fail "Namespace GNU bootstrap ownership failed: ${gnu_command} -> ${gnu_package}"
  done
  namespace_installed_packages="$(printf '%s\n' "${gnu_packages[@]}" |
    jq -Rsc 'split("\n")[:-1]')"

  local -a packages=()
  local entry command package
  for entry in \
    'bun bun' \
    'go go' \
    'helm helm' \
    'openssl openssl' \
    'rg ripgrep' \
    'yq yq'; do
    command="${entry%% *}"
    package="${entry##* }"
    command -v "${command}" >/dev/null 2>&1 || packages+=("${package}")
  done
  [ -x "${NSC_GIT_HTTP_BACKEND_CANONICAL}" ] ||
    packages+=("${NSC_GIT_HTTP_BACKEND_PACKAGE}")
  if [ "${#packages[@]}" -gt 0 ]; then
    apk add --no-cache "${packages[@]}"
    local prepared_packages
    prepared_packages="$(printf '%s\n' "${packages[@]}" | jq -Rsc 'split("\n")[:-1]')"
    namespace_installed_packages="$(jq -cn \
      --argjson bootstrap "${namespace_installed_packages}" \
      --argjson prepared "${prepared_packages}" '$bootstrap + $prepared')"
  fi
  [ -x "${NSC_GIT_HTTP_BACKEND_CANONICAL}" ] ||
    sit_fail "Git smart-HTTP backend is missing after tool preparation: ${NSC_GIT_HTTP_BACKEND_CANONICAL}"

  local observed_k3s
  observed_k3s="$(k3s --version | awk 'NR == 1 {print $3}')"
  [ "${observed_k3s}" = "${NSC_K3S_VERSION}" ] ||
    sit_fail "built-in k3s version must be ${NSC_K3S_VERSION}, found ${observed_k3s:-unknown}"
  [ "$(nproc)" -eq "${NSC_VCPU}" ] ||
    sit_fail "Namespace instance CPU count disagrees with ${NSC_MACHINE_TYPE}"
}

namespace_tool_record() {
  local name="$1" path="$2" version="$3"
  [ -n "${name}" ] && [ -n "${path}" ] && [ -n "${version}" ] || {
    sit_fail "tool receipt is incomplete: ${name:-<missing-name>}"
    return 1
  }
  version="${version//$'\t'/ }"
  version="${version//$'\n'/ }"
  printf '%s\t%s\t%s\n' "${name}" "${path}" "${version}" >>"${work}/namespace-tools.tsv"
}

namespace_first_line_receipt() {
  local output
  output="$("$@" 2>&1)" || {
    sit_fail "tool receipt command failed: $*: ${output}"
    return 1
  }
  output="${output%%$'\n'*}"
  [ -n "${output}" ] || {
    sit_fail "tool receipt command returned no version or ownership line: $*"
    return 1
  }
  printf '%s\n' "${output}"
}

namespace_tool_command_record() {
  local name="$1" path="$2" version
  shift 2
  version="$(namespace_first_line_receipt "$@")" || return 1
  namespace_tool_record "${name}" "${path}" "${version}"
}

namespace_apk_owned_tool_receipt() {
  local path="$1" package="$2" canonical owner expected_prefix
  [ -x "${path}" ] || {
    sit_fail "APK-owned tool path is not executable: ${path:-<missing>}"
    return 1
  }
  canonical="$(readlink -f -- "${path}")" || {
    sit_fail "APK-owned tool path cannot be canonicalized: ${path}"
    return 1
  }
  owner="$(namespace_first_line_receipt apk info --who-owns "${canonical}")" || return 1
  expected_prefix="${canonical} is owned by ${package}-"
  [[ ${owner} == "${expected_prefix}"* ]] || {
    sit_fail "tool has unexpected APK ownership (${path} -> ${package}): ${owner}"
    return 1
  }
  printf '%s\n' "${owner}"
}

namespace_apk_owned_tool_record() {
  local name="$1" path="$2" package="$3" owner
  owner="$(namespace_apk_owned_tool_receipt "${path}" "${package}")" || return 1
  namespace_tool_record "${name}" "${path}" "${owner}"
}

namespace_git_http_backend_record() {
  namespace_apk_owned_tool_record git-http-backend \
    "${NSC_GIT_HTTP_BACKEND_CANONICAL}" "${NSC_GIT_HTTP_BACKEND_PACKAGE}"
}

# BusyBox applets such as gzip and tar are materialised by the busybox package
# trigger rather than listed in its file manifest. Bind the
# PATH BusyBox and each applet to the reviewed canonical binary by device and
# inode, then ask apk for that canonical path's exact package attribution.
# Symlinked and hardlinked applets pass; unrelated files, byte-identical copies,
# dangling links and PATH shadows fail. Bash captures and validates both APK
# streams without adding a new success-path dependency.
namespace_wolfi_tool_receipt() {
  local path="$1" busybox_path apk_stdout_file apk_stderr_file apk_status
  local apk_output apk_error owner_line owner_prefix owner_token
  local owner_without_release owner_release owner_name owner_version
  local -a owner_rows=()
  busybox_path="$(command -v busybox 2>/dev/null || true)"
  [ -n "${busybox_path}" ] || {
    sit_fail "busybox is not on PATH for the applet ownership receipt: ${path}"
    return 1
  }
  case "${NSC_BUSYBOX_CANONICAL}" in
  /*) ;;
  *)
    sit_fail "canonical busybox pin is not an absolute executable path: ${NSC_BUSYBOX_CANONICAL}"
    return 1
    ;;
  esac
  [ -x "${NSC_BUSYBOX_CANONICAL}" ] || {
    sit_fail "canonical busybox pin is not an absolute executable path: ${NSC_BUSYBOX_CANONICAL}"
    return 1
  }
  [ "${busybox_path}" -ef "${NSC_BUSYBOX_CANONICAL}" ] || {
    sit_fail "PATH busybox is not the canonical busybox binary: ${busybox_path} vs ${NSC_BUSYBOX_CANONICAL}"
    return 1
  }
  [ "${path}" -ef "${NSC_BUSYBOX_CANONICAL}" ] || {
    sit_fail "applet is not the canonical busybox binary: ${path} vs ${NSC_BUSYBOX_CANONICAL}"
    return 1
  }

  apk_stdout_file="${work}/namespace-apk-who-owns.stdout"
  apk_stderr_file="${work}/namespace-apk-who-owns.stderr"
  apk_status=0
  apk info --who-owns "${NSC_BUSYBOX_CANONICAL}" >"${apk_stdout_file}" \
    2>"${apk_stderr_file}" || apk_status=$?
  apk_output="$(<"${apk_stdout_file}")"
  apk_error="$(<"${apk_stderr_file}")"
  [ "${apk_status}" -eq 0 ] || {
    sit_fail "canonical busybox ownership query exited ${apk_status}; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  [ -z "${apk_error}" ] || {
    sit_fail "canonical busybox ownership query wrote stderr; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  [ -n "${apk_output}" ] || {
    sit_fail "canonical busybox ownership query returned empty stdout; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  mapfile -t owner_rows <"${apk_stdout_file}"
  [ "${#owner_rows[@]}" -eq 1 ] || {
    sit_fail "canonical busybox ownership query returned ${#owner_rows[@]} rows; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }

  owner_line="${owner_rows[0]}"
  owner_prefix="${NSC_BUSYBOX_CANONICAL} is owned by "
  [[ ${owner_line} == "${owner_prefix}"* ]] || {
    sit_fail "canonical busybox ownership row has the wrong path or shape; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  owner_token="${owner_line#"${owner_prefix}"}"
  [ -n "${owner_token}" ] && [[ ${owner_token} != *[[:space:]]* ]] || {
    sit_fail "canonical busybox ownership row has a malformed package token; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  owner_without_release="${owner_token%-*}"
  owner_release="${owner_token##*-}"
  [ "${owner_without_release}" != "${owner_token}" ] &&
    [[ ${owner_release} =~ ^r[0-9]+$ ]] || {
    sit_fail "canonical busybox ownership row has a malformed release field; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  owner_name="${owner_without_release%-*}"
  owner_version="${owner_without_release##*-}"
  [ "${owner_name}" != "${owner_without_release}" ] &&
    [ -n "${owner_version}" ] || {
    sit_fail "canonical busybox ownership row has a malformed version field; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  [ "${owner_name}" = "${NSC_BUSYBOX_PACKAGE}" ] || {
    sit_fail "canonical busybox ownership row names the wrong package family: ${owner_name}; stdout: ${apk_output:-<empty>}; stderr: ${apk_error:-<empty>}"
    return 1
  }
  printf '%s\n' "${owner_line}"
}

namespace_wolfi_tool_record() {
  local name="$1" path="$2" version
  version="$(namespace_wolfi_tool_receipt "${path}")" || return 1
  namespace_tool_record "${name}" "${path}" "${version}"
}

namespace_capture_platform() {
  local node_json="${work}/namespace-node.json"
  kubectl get nodes -o json >"${node_json}"
  jq -e \
    --arg id "${namespace_instance_id}" \
    --arg k3s "${NSC_K3S_VERSION}" \
    --arg os "${NSC_INSTANCE_OS_ID}" \
    --argjson count "${NSC_NODE_COUNT}" '
      (.items | length) == $count and
      .items[0].metadata.name == $id and
      .items[0].status.nodeInfo.kubeletVersion == $k3s and
      (.items[0].status.nodeInfo.osImage | ascii_downcase | contains($os)) and
      any(.items[0].status.conditions[]?; .type == "Ready" and .status == "True") and
      ([.items[0].status.addresses[]? | select(.type == "InternalIP") | .address] | length) == 1
    ' "${node_json}" >/dev/null ||
    sit_fail 'Namespace must expose the exact Ready single-node built-in-k3s topology'
  namespace_node_name="$(jq -r '.items[0].metadata.name' "${node_json}")"
  namespace_node_internal_ip="$(jq -r '.items[0].status.addresses[] | select(.type == "InternalIP") | .address' "${node_json}")"
  [[ ${namespace_node_internal_ip} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
    sit_fail "Ready node InternalIP is not IPv4: ${namespace_node_internal_ip}"

  : >"${work}/namespace-tools.tsv"
  local apk_path apk_version
  apk_path="$(command -v apk)"
  apk_version="$(namespace_first_line_receipt apk --version)" || return 1
  printf 'Namespace apk version: %s\n' "${apk_version}"
  namespace_tool_record apk "${apk_path}" "${apk_version}"
  namespace_apk_owned_tool_record awk "$(command -v awk)" gawk
  namespace_tool_command_record bash "$(command -v bash)" bash --version
  namespace_tool_command_record bun "$(command -v bun)" bun --version
  namespace_apk_owned_tool_record cut "$(command -v cut)" coreutils
  namespace_tool_command_record curl "$(command -v curl)" curl --version
  namespace_apk_owned_tool_record date "$(command -v date)" coreutils
  namespace_tool_command_record docker "$(command -v docker)" docker --version
  namespace_apk_owned_tool_record find "$(command -v find)" findutils
  namespace_tool_command_record git "$(command -v git)" git --version
  namespace_git_http_backend_record
  namespace_apk_owned_tool_record grep "$(command -v grep)" grep
  namespace_tool_command_record go "$(command -v go)" go version
  namespace_tool_command_record helm "$(command -v helm)" helm version --short
  namespace_apk_owned_tool_record head "$(command -v head)" coreutils
  namespace_tool_command_record jq "$(command -v jq)" jq --version
  namespace_tool_command_record k3s "$(command -v k3s)" k3s --version
  namespace_tool_command_record crictl "$(command -v k3s) crictl" k3s crictl --version
  local kubectl_version ctr_version
  kubectl_version="$(kubectl version --client -o json | jq -c '.clientVersion')" || {
    sit_fail 'kubectl client version receipt failed'
    return 1
  }
  namespace_tool_record kubectl "$(command -v kubectl)" "${kubectl_version}"
  namespace_tool_command_record openssl "$(command -v openssl)" openssl version
  namespace_tool_command_record rg "$(command -v rg)" rg --version
  namespace_apk_owned_tool_record sed "$(command -v sed)" sed
  namespace_apk_owned_tool_record sort "$(command -v sort)" coreutils
  namespace_apk_owned_tool_record stat "$(command -v stat)" coreutils
  namespace_wolfi_tool_record gzip "$(command -v gzip)"
  namespace_apk_owned_tool_record sha256sum "$(command -v sha256sum)" coreutils
  namespace_wolfi_tool_record tar "$(command -v tar)"
  namespace_apk_owned_tool_record timeout "$(command -v timeout)" coreutils
  namespace_apk_owned_tool_record xargs "$(command -v xargs)" findutils
  namespace_tool_command_record yq "$(command -v yq)" yq --version
  ctr_version="$("${NSC_CONTAINERD_CTR}" --address "${NSC_CONTAINERD_ADDRESS}" version 2>&1)" || {
    sit_fail 'platform containerd version receipt failed'
    return 1
  }
  ctr_version="${ctr_version//$'\n'/ }"
  namespace_tool_record ctr "${NSC_CONTAINERD_CTR}" "${ctr_version}"

  jq -Rn \
    --arg instanceId "${namespace_instance_id}" \
    --arg os "${NSC_INSTANCE_OS_ID}" \
    --arg machineType "${NSC_MACHINE_TYPE}" \
    --arg kubernetes "${NSC_KUBERNETES_VERSION}" \
    --arg k3s "${NSC_K3S_VERSION}" \
    --arg node "${namespace_node_name}" \
    --arg internalIP "${namespace_node_internal_ip}" \
    --argjson installedPackages "${namespace_installed_packages}" \
    --slurpfile topology "${node_json}" '
      [inputs | split("\t") | {name:.[0],path:.[1],version:.[2]}] as $tools |
      {
        instanceId:$instanceId,hostname:$instanceId,os:$os,machineType:$machineType,
        requestedKubernetes:$kubernetes,k3sVersion:$k3s,nodeName:$node,nodeInternalIP:$internalIP,
        topology:$topology[0],installedPackages:$installedPackages,tools:$tools,
        checkedBeforeApplicationMutation:true
      }
    ' <"${work}/namespace-tools.tsv" >"${report}/namespace-platform.json"
  namespace_platform_ready=1
}

# The harness digest. It pins ONLY this script plus scripts/validate/fleet-sit,
# and is retained as narrow provenance. It is NOT the direct-input inventory and
# the report says so at the field.
write_harness_inventory() {
  local output="$1"
  local paths="${output}.paths.$$"
  {
    printf '%s\n' 'scripts/ci/fleet-sit.sh'
    printf '%s\n' 'scripts/ci/fleet-sit-proof.sh'
    find scripts/validate/fleet-sit -type f -print
  } | LC_ALL=C sort >"${paths}"
  : >"${output}"
  local path
  while IFS= read -r path; do
    [ -f "${path}" ] || sit_fail "harness inventory contains a non-regular file: ${path}"
    sha256sum -- "${path}" >>"${output}"
  done <"${paths}"
  rm -f "${paths}"
  HARNESS_SHA256="$(sha256sum -- "${output}" | awk '{print $1}')"
  HARNESS_FILE_COUNT="$(wc -l <"${output}" | tr -d ' ')"
  [[ ${HARNESS_SHA256} =~ ^[0-9a-f]{64}$ ]] || sit_fail 'could not digest harness inventory'
  [ "${HARNESS_FILE_COUNT}" -gt 1 ] || sit_fail 'harness inventory is unexpectedly small'
}

# The direct-input inventory: every tracked blob under the fixed roots, taken
# from the RECORDED GIT TREE. Each record is
#   <mode>,<type>,<git-blob-sha>,<content-sha256>,<path>
# sorted bytewise by path. Every entry is additionally re-hashed from the bytes
# on disk, so an inventory can only agree with the tree it is actually running
# against.
# mode 'strict' (the default, and the only mode a full run uses) additionally
# requires the bytes on disk to equal the recorded blobs and the roots to carry
# no untracked or modified file. Mode 'advisory' derives the same inventory from
# the recorded tree without those two checks, so --prepare-only stays runnable
# during development on a dirty checkout.
write_direct_input_inventory() {
  local output="$1"
  local commit="$2"
  local strictness="${3:-strict}"
  local records="${output}.records.$$"
  : >"${records}"

  # Process substitution needs an openable /dev/fd, which the instance shell
  # does not reliably provide. Produce into an explicit listing keyed off
  # ${output} — this function also runs on the prepare-only path, where ${work}
  # is not the applicable scratch root — and status-check the producer at its
  # source, since a process substitution silently turns a failed producer into a
  # successful empty loop.
  local listing="${output}.ls-tree.$$"
  git ls-tree -r -z "${commit}" -- "${SIT_DIRECT_INPUT_ROOTS[@]}" >"${listing}" ||
    sit_fail "could not enumerate the direct-input roots at ${commit}"

  local mode type object path blob_sha content_sha disk_sha record
  while IFS= read -r -d '' record; do
    mode="${record%% *}"
    type="$(printf '%s' "${record}" | cut -d' ' -f2)"
    object="$(printf '%s' "${record}" | cut -d' ' -f3 | cut -f1)"
    path="${record#*$'\t'}"
    [ "${type}" = 'blob' ] || sit_fail "direct input is not a regular blob: ${path} (${type})"
    case "${mode}" in
    100644 | 100755) ;;
    *) sit_fail "direct input has an unexpected git mode: ${path} (${mode})" ;;
    esac
    blob_sha="${object}"
    content_sha="$(git cat-file blob "${blob_sha}" | sha256sum | awk '{print $1}')"
    if [ "${strictness}" = 'strict' ]; then
      [ -f "${path}" ] ||
        sit_fail "direct input recorded at ${commit} is absent from the execution root: ${path}"
      disk_sha="$(git hash-object -- "${path}")"
      [ "${disk_sha}" = "${blob_sha}" ] ||
        sit_fail "direct input on disk differs from the recorded commit: ${path}"
    fi
    printf '%s,%s,%s,%s,%s\n' "${mode}" "${type}" "${blob_sha}" "${content_sha}" "${path}" >>"${records}"
  done <"${listing}"
  rm -f "${listing}"

  LC_ALL=C sort -t, -k5 "${records}" >"${output}"
  rm -f "${records}"

  # Every declared root must resolve, so a renamed or deleted input fails closed
  # instead of silently shrinking the inventory.
  local root
  for root in "${SIT_DIRECT_INPUT_ROOTS[@]}"; do
    if ! grep -q -- ",${root}\(/\|$\)" "${output}"; then
      [ "${strictness}" = 'advisory' ] ||
        sit_fail "direct-input root resolved to no tracked entry at ${commit}: ${root}"
      # Advisory: the root may be present but not yet committed on a
      # work-in-progress checkout. It must still exist, so a typo still fails.
      [ -e "${root}" ] || sit_fail "direct-input root does not exist: ${root}"
      echo "note: direct-input root is not tracked at ${commit} yet: ${root}"
    fi
  done
  # No untracked or modified byte may exist under any root in the execution
  # root: the snapshot must contain exactly the recorded tree.
  if [ "${strictness}" = 'strict' ]; then
    [ -z "$(git status --porcelain --untracked-files=all -- "${SIT_DIRECT_INPUT_ROOTS[@]}")" ] ||
      sit_fail 'the execution root carries untracked or modified bytes under a direct-input root'
  fi

  DIRECT_INPUT_SHA256="$(sha256sum -- "${output}" | awk '{print $1}')"
  DIRECT_INPUT_FILE_COUNT="$(wc -l <"${output}" | tr -d ' ')"
  [[ ${DIRECT_INPUT_SHA256} =~ ^[0-9a-f]{64}$ ]] || sit_fail 'could not digest the direct-input inventory'
  [ "${DIRECT_INPUT_FILE_COUNT}" -gt "${HARNESS_FILE_COUNT:-0}" ] ||
    sit_fail 'the direct-input inventory must be strictly larger than the harness inventory'
}

checkout_clean() {
  local checkout="$1"
  if [ -n "$(git -C "${checkout}" status --porcelain --untracked-files=all)" ]; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

# Checks the ORIGINAL checkout the wrapper validated, not the snapshot the SIT
# executes from. Both halves are recorded; neither is inferred from the other.
assert_clean_unchanged_checkout() {
  local checkout="$1"
  local expected_head="$2"
  local actual_head
  actual_head="$(git -C "${checkout}" rev-parse HEAD)"
  [ "${actual_head}" = "${expected_head}" ] ||
    sit_fail "checkout HEAD changed during SIT: expected ${expected_head}, found ${actual_head}"
  if [ "$(checkout_clean "${checkout}")" != 'true' ]; then
    git -C "${checkout}" status --short >&2
    sit_fail 'full SIT requires a clean checkout so every consumed byte belongs to the recorded commit'
  fi
}

# The snapshot the SIT executes from must be the recorded commit, byte for byte.
assert_verified_snapshot() {
  local expected_head="$1"
  local actual_head actual_tree
  actual_head="$(git rev-parse HEAD)"
  [ "${actual_head}" = "${expected_head}" ] ||
    sit_fail "input snapshot is at ${actual_head}, not the recorded commit ${expected_head}"
  [ -z "$(git status --porcelain --untracked-files=all)" ] ||
    sit_fail 'input snapshot is not clean; it must be a pristine checkout of the recorded commit'
  actual_tree="$(git rev-parse "${expected_head}^{tree}")"
  [[ ${actual_tree} =~ ^[0-9a-f]{40}$ ]] || sit_fail 'could not resolve the input snapshot tree'
  SIT_SNAPSHOT_TREE="${actual_tree}"
}

require_empty_report_directory() {
  local directory="$1"
  if [ -L "${directory}" ]; then
    sit_fail "SIT report path must not be a symlink: ${directory}"
    return 1
  fi
  if [ -e "${directory}" ] && [ ! -d "${directory}" ]; then
    sit_fail "SIT report path exists and is not a directory: ${directory}"
    return 1
  fi
  if [ -d "${directory}" ] && [ -n "$(find "${directory}" -mindepth 1 -print -quit)" ]; then
    sit_fail "SIT report directory must be absent or empty; preserve prior evidence elsewhere: ${directory}"
    return 1
  fi
}

git_commit_at() {
  local repo="$1"
  local message="$2"
  local sequence="$3"
  local stamp
  stamp="$(printf '2026-01-01T00:00:%02dZ' "${sequence}")"
  GIT_AUTHOR_NAME='fleet-sit' \
    GIT_AUTHOR_EMAIL='fleet-sit@invalid.example' \
    GIT_AUTHOR_DATE="${stamp}" \
    GIT_COMMITTER_NAME='fleet-sit' \
    GIT_COMMITTER_EMAIL='fleet-sit@invalid.example' \
    GIT_COMMITTER_DATE="${stamp}" \
    git -C "${repo}" commit --quiet -m "${message}"
}

make_bare_remote() {
  local source_repo="$1"
  local bare_repo="$2"
  git clone --quiet --bare "${source_repo}" "${bare_repo}"
  git -C "${source_repo}" remote add sit "${bare_repo}"
}

relax_fleet_repo_url_schema() {
  local schema="$1"
  jq --indent 4 \
    '.properties.fleet.properties.repoURL.pattern = "^https?://"' \
    "${schema}" >"${schema}.next" || return 1
  mv -- "${schema}.next" "${schema}"
}

prepare_repositories() {
  local src_root="${work}/src"
  local repos_root="${work}/repos"
  mkdir -p "${src_root}" "${repos_root}"

  FLEET_SOURCE="${src_root}/fleet"
  FLEET_BARE="${repos_root}/fleet.git"
  mkdir -p \
    "${FLEET_SOURCE}/registry/charts" \
    "${FLEET_SOURCE}/platforms" \
    "${FLEET_SOURCE}/platforms/sitother/landscapes/pichu"
  cp -R registry/charts/diene-platform "${FLEET_SOURCE}/registry/charts/diene-platform"
  local mirror_schema="${FLEET_SOURCE}/registry/charts/diene-platform/values.schema.json"
  cp "${mirror_schema}" "${work}/values.schema.before.json"
  jq -e '.properties.fleet.properties.repoURL.pattern == "^https://"' "${mirror_schema}" >/dev/null
  relax_fleet_repo_url_schema "${mirror_schema}" ||
    sit_fail 'could not apply the portable fleet.repoURL runtime schema correction'
  jq -e '
    .properties.fleet.properties.repoURL.pattern == "^https?://" and
    .properties.primordial.properties.server.pattern == "^https://"
  ' "${mirror_schema}" >/dev/null
  diff -u "${work}/values.schema.before.json" "${mirror_schema}" \
    >"${work}/runtime-chart-schema-relaxation.diff" || true
  [ "$(rg -c '^[+-] *"pattern"' "${work}/runtime-chart-schema-relaxation.diff")" -eq 2 ] ||
    sit_fail 'runtime chart schema correction changed more than the fleet.repoURL pattern'
  cp -R platforms/canary "${FLEET_SOURCE}/platforms/canary"
  local soak_landscape soak_row
  for soak_landscape in pichu pikachu raichu ampharos; do
    soak_row="${FLEET_SOURCE}/platforms/canary-sitsoak/landscapes/${soak_landscape}/dummy.yaml"
    mkdir -p "$(dirname "${soak_row}")"
    LANDSCAPE="${soak_landscape}" yq '.landscape = strenv(LANDSCAPE)' \
      "${validation_dir}/fixtures/kargo-runtime/soak-row.yaml" >"${soak_row}"
  done
  cp "${validation_dir}/fixtures/sitother.services.yaml" "${FLEET_SOURCE}/platforms/sitother/services.yaml"
  cp "${validation_dir}/fixtures/sitother-row.yaml" "${FLEET_SOURCE}/platforms/sitother/landscapes/pichu/dummy.yaml"

  git init --quiet --initial-branch=main "${FLEET_SOURCE}"
  git -C "${FLEET_SOURCE}" config core.autocrlf false
  git -C "${FLEET_SOURCE}" config core.filemode false
  git -C "${FLEET_SOURCE}" add registry platforms
  git_commit_at "${FLEET_SOURCE}" 'C1 deterministic fleet fixture' 1
  C1_SHA="$(git -C "${FLEET_SOURCE}" rev-parse HEAD)"
  git -C "${FLEET_SOURCE}" tag machinery-stable "${C1_SHA}"
  # The reviewed pointer file, in the committed product format, naming the
  # commit the tag already points at. Every later move is a pointer edit.
  write_machinery_pointer "${FLEET_SOURCE}/registry/machinery-stable.yaml" "${C1_SHA}"
  git -C "${FLEET_SOURCE}" add registry/machinery-stable.yaml
  git_commit_at "${FLEET_SOURCE}" 'C1b machinery-stable pointer at C1' 1
  make_bare_remote "${FLEET_SOURCE}" "${FLEET_BARE}"
  ln -s 'fleet.git' "${repos_root}/fleet-services.git"
  [ "$(readlink "${repos_root}/fleet-services.git")" = 'fleet.git' ] ||
    sit_fail 'fleet services repository alias does not target fleet.git'

  local carbon platform
  for platform in canary sitother; do
    carbon="${src_root}/${platform}.carbon"
    mkdir -p "${carbon}"
    if [ "${platform}" = 'canary' ]; then
      cp registry/charts/diene-platform/tests/fixtures/canary.platform.yaml "${carbon}/platform.yaml"
    else
      yq '(.. | select(tag == "!!str")) |= sub("canary", "sitother")' \
        registry/charts/diene-platform/tests/fixtures/canary.platform.yaml >"${carbon}/platform.yaml"
    fi
    git init --quiet --initial-branch=main "${carbon}"
    git -C "${carbon}" config core.autocrlf false
    git -C "${carbon}" config core.filemode false
    git -C "${carbon}" add platform.yaml
    git_commit_at "${carbon}" "${platform} carbon fixture" 1
    make_bare_remote "${carbon}" "${repos_root}/${platform}.carbon.git"
  done
}

check_git_server_started() {
  kill -0 "${GIT_SERVER_PID}" 2>/dev/null || return 1
  jq -e '.port > 0 and .port < 65536' "${GIT_SERVER_STDOUT}" >/dev/null 2>&1 || return 1
}

start_git_server() {
  local evidence_dir="$1"
  GIT_SERVER_STDOUT="${evidence_dir}/git-server.stdout"
  bun "${validation_dir}/git-server.ts" --root "${work}/repos" --port 0 \
    >"${GIT_SERVER_STDOUT}" 2>"${evidence_dir}/git-server.stderr" &
  GIT_SERVER_PID=$!
  sit_wait_for 15 'Bun smart-HTTP git server to bind' check_git_server_started
  GIT_SERVER_PORT="$(jq -r '.port' "${GIT_SERVER_STDOUT}")"
  git ls-remote "http://127.0.0.1:${GIT_SERVER_PORT}/fleet.git" \
    >"${evidence_dir}/git-ls-remote.txt"
  git ls-remote "http://127.0.0.1:${GIT_SERVER_PORT}/fleet-services.git" \
    >"${evidence_dir}/git-services-ls-remote.txt"
  cmp -s "${evidence_dir}/git-ls-remote.txt" "${evidence_dir}/git-services-ls-remote.txt" ||
    sit_fail 'fleet services repository alias advertised different refs from fleet.git'
  jq -n \
    --arg alias 'fleet-services.git' \
    --arg target "$(readlink "${work}/repos/fleet-services.git")" \
    '{alias:$alias,target:$target,sameAdvertisedRefs:true}' \
    >"${evidence_dir}/git-services-alias.json"
  curl --silent --show-error --dump-header "${evidence_dir}/git-smart-http.headers" \
    --output /dev/null \
    "http://127.0.0.1:${GIT_SERVER_PORT}/fleet.git/info/refs?service=git-upload-pack"
  rg -qi '^content-type: application/x-git-upload-pack-advertisement' \
    "${evidence_dir}/git-smart-http.headers" ||
    sit_fail 'git server did not advertise the smart HTTP upload-pack service'

  local git_host='127.0.0.1'
  if [ "${mode}" = 'full' ]; then
    [ -n "${namespace_node_internal_ip}" ] ||
      sit_fail 'Ready node InternalIP was not established before starting the git server'
    git_host="${namespace_node_internal_ip}"
  fi
  FLEET_REPO_URL="http://${git_host}:${GIT_SERVER_PORT}/fleet.git"
  FLEET_SERVICES_REPO_URL="http://${git_host}:${GIT_SERVER_PORT}/fleet-services.git"
  CANARY_REPO_URL="http://${git_host}:${GIT_SERVER_PORT}/canary.carbon.git"
  SITOTHER_REPO_URL="http://${git_host}:${GIT_SERVER_PORT}/sitother.carbon.git"
}

fleet_commit() {
  local message="$1"
  local evidence="$2"
  shift 2
  COMMIT_SEQUENCE=$((COMMIT_SEQUENCE + 1))
  {
    git -C "${FLEET_SOURCE}" add -- "$@"
    git_commit_at "${FLEET_SOURCE}" "${message}" "${COMMIT_SEQUENCE}"
    git -C "${FLEET_SOURCE}" push --quiet sit main
    git -C "${FLEET_SOURCE}" show --stat --oneline --decorate=short HEAD
    git -C "${FLEET_SOURCE}" show --format= --name-only HEAD
  } >"${evidence}" 2>&1
  FLEET_LAST_COMMIT="$(git -C "${FLEET_SOURCE}" rev-parse HEAD)"
}

fleet_revert() {
  local commit="$1"
  local message="$2"
  local evidence="$3"
  COMMIT_SEQUENCE=$((COMMIT_SEQUENCE + 1))
  {
    git -C "${FLEET_SOURCE}" revert --no-edit --no-commit "${commit}"
    git_commit_at "${FLEET_SOURCE}" "${message}" "${COMMIT_SEQUENCE}"
    git -C "${FLEET_SOURCE}" push --quiet sit main
    git -C "${FLEET_SOURCE}" show --stat --oneline --decorate=short HEAD
  } >"${evidence}" 2>&1
  FLEET_LAST_COMMIT="$(git -C "${FLEET_SOURCE}" rev-parse HEAD)"
}

check_port_forward() {
  local pid="$1"
  local log="$2"
  kill -0 "${pid}" 2>/dev/null || return 1
  rg -q 'Forwarding from 127\.0\.0\.1:[0-9]+' "${log}" 2>/dev/null
}

port_from_log() {
  rg -o 'Forwarding from 127\.0\.0\.1:[0-9]+' "$1" | head -n1 | sed 's/.*://'
}

check_webhook_endpoint() {
  local port="$1"
  local status
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 3 "http://127.0.0.1:${port}/api/webhook" || true)"
  case "${status}" in
  200 | 400 | 405) return 0 ;;
  *) return 1 ;;
  esac
}

start_applicationset_port_forward() {
  local appset_log="${report}/port-forward-appset.log"
  kubectl -n argocd port-forward --address 127.0.0.1 service/argocd-applicationset-controller :7000 \
    >"${appset_log}" 2>&1 &
  PF_APPSET_PID=$!
  sit_wait_for 20 'ApplicationSet webhook port-forward' check_port_forward "${PF_APPSET_PID}" "${appset_log}"
  PF_APPSET_PORT="$(port_from_log "${appset_log}")"
  sit_wait_for 20 'ApplicationSet webhook endpoint' check_webhook_endpoint "${PF_APPSET_PORT}"
}

start_port_forwards() {
  local server_log="${report}/port-forward-server.log"
  kubectl -n argocd port-forward --address 127.0.0.1 service/argocd-server :80 \
    >"${server_log}" 2>&1 &
  PF_SERVER_PID=$!
  sit_wait_for 20 'argocd-server port-forward' check_port_forward "${PF_SERVER_PID}" "${server_log}"
  PF_SERVER_PORT="$(port_from_log "${server_log}")"
  sit_wait_for 20 'argocd-server webhook endpoint' check_webhook_endpoint "${PF_SERVER_PORT}"
  start_applicationset_port_forward
}

wait_argo_rollouts() {
  local resource
  # No process substitution on an instance-executed path. Each list gets its own
  # file and its own refusal, so a failure names which list could not be
  # produced. pipefail is global, so a failure in either pipeline member is
  # observed here rather than becoming a successful empty wait.
  local deployments="${work}/argo-deployments.txt"
  local statefulsets="${work}/argo-statefulsets.txt"
  kubectl -n argocd get deployments -o name | sort >"${deployments}" ||
    sit_fail 'could not list argocd deployments for the rollout wait'
  while IFS= read -r resource; do
    kubectl -n argocd rollout status "${resource}" --timeout=300s
  done <"${deployments}"
  kubectl -n argocd get statefulsets -o name | sort >"${statefulsets}" ||
    sit_fail 'could not list argocd statefulsets for the rollout wait'
  while IFS= read -r resource; do
    kubectl -n argocd rollout status "${resource}" --timeout=300s
  done <"${statefulsets}"
}

configure_clocks() {
  local interval="$1"
  local revision_cache_expiration='30s'
  kubectl -n argocd patch configmap argocd-cm --type merge \
    -p "$(jq -cn --arg interval "${interval}" '{data:{"timeout.reconciliation":$interval,"timeout.reconciliation.jitter":"0s"}}')"
  kubectl -n argocd set env deployment/argocd-applicationset-controller \
    "ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER=${interval}"
  kubectl -n argocd set env deployment/argocd-repo-server \
    "ARGOCD_RECONCILIATION_TIMEOUT=${revision_cache_expiration}"
  kubectl -n argocd rollout restart deployment/argocd-applicationset-controller
  kubectl -n argocd rollout restart deployment/argocd-repo-server
  kubectl -n argocd rollout restart statefulset/argocd-application-controller
  wait_argo_rollouts
}

# SIT-local synthetic coordinates. The committed fixtures carry `<mark>` /
# `<provider>` placeholders because the v1 serving roster is UNRATIFIED and
# guessing provider coordinates is forbidden; the substitution below happens
# only inside the throwaway proof, never in the repository, and is recorded so
# the report shows the SIT consumed fixtures rather than live rows.
SIT_SYNTHETIC_MARK='sit'
SIT_SYNTHETIC_PROVIDER='sit-provider'

substitute_fixture_placeholder() {
  local value="$1"
  value="${value//<mark>/${SIT_SYNTHETIC_MARK}}"
  value="${value//<provider>/${SIT_SYNTHETIC_PROVIDER}}"
  printf '%s' "${value}"
}

seed_one_cluster_secret() {
  local name="$1"
  local landscape="$2"
  local server="$3"
  local role="$4"
  kubectl -n argocd create secret generic "${name}" \
    --from-literal="name=${name}" \
    --from-literal="server=${server}" \
    --from-literal='config={"tlsClientConfig":{"insecure":true}}' \
    --dry-run=client -o yaml |
    LANDSCAPE="${landscape}" ROLE="${role}" yq '
      .metadata.labels."argocd.argoproj.io/secret-type" = "cluster" |
      .metadata.labels."atomi.cloud/landscape" = strenv(LANDSCAPE) |
      .metadata.labels."atomi.cloud/cluster-role" = strenv(ROLE)
    ' |
    kubectl apply -f -
}

seed_cluster_secrets() {
  # The live serving path must be EMPTY at the recorded commit: the encoded
  # refusal is what forces this seeding onto fixtures.
  local live_rows
  live_rows="$(git ls-tree -r --name-only "${SIT_SOURCE_HEAD}" -- registry/clusters | wc -l | tr -d ' ')"
  [ "${live_rows}" -eq 0 ] ||
    sit_fail "registry/clusters carries ${live_rows} live serving row(s); the v1 roster is unratified and the SIT must seed from fixtures"

  local tsv="${work}/cluster-inputs.tsv"
  local substitutions="${work}/cluster-substitutions.tsv"
  : >"${tsv}"
  : >"${substitutions}"

  local record name landscape label mark provider host_role traffic role server
  local serving=0
  local infrastructure=0
  for record in \
    registry/fixtures/clusters/*.yaml \
    registry/fixtures/negative/second-infrastructure-cluster.yaml \
    "${validation_dir}/fixtures/infrastructure-only-serving-landscape.yaml"; do
    [ -f "${record}" ] || sit_fail "expected cluster fixture is missing: ${record}"
    [ "$(yq -r '.kind' "${record}")" = 'ClusterRegistration' ] ||
      sit_fail "cluster fixture is not a ClusterRegistration: ${record}"
    name="$(yq -r '.metadata.name' "${record}")"
    landscape="$(yq -r '.spec.landscape' "${record}")"
    label="$(yq -r '.metadata.labels["atomi.cloud/landscape"]' "${record}")"
    mark="$(yq -r '.spec.mark' "${record}")"
    provider="$(yq -r '.spec.provider' "${record}")"
    host_role="$(yq -r '.spec.hostRole // ""' "${record}")"
    traffic="$(yq -r '.spec.traffic' "${record}")"
    [ -n "${name}" ] && [ "${name}" != 'null' ] || sit_fail "cluster fixture has no metadata.name: ${record}"
    [ -n "${landscape}" ] && [ "${landscape}" != 'null' ] || sit_fail "cluster fixture has no spec.landscape: ${record}"
    [ "${label}" = "${landscape}" ] || sit_fail "cluster fixture label/spec landscape mismatch: ${record}"

    if [ -n "${host_role}" ]; then
      role='infrastructure-only'
      [ "${traffic}" = 'false' ] ||
        sit_fail "infrastructure-only fixture must keep traffic:false: ${record}"
      infrastructure=$((infrastructure + 1))
    else
      role='serving'
      [ "${traffic}" = 'true' ] || sit_fail "serving fixture must declare traffic:true: ${record}"
      serving=$((serving + 1))
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "${record}" "${name}" "${mark}" "${provider}" "${role}" >>"${substitutions}"
    name="$(substitute_fixture_placeholder "${name}")"
    mark="$(substitute_fixture_placeholder "${mark}")"
    provider="$(substitute_fixture_placeholder "${provider}")"
    case "${name}${mark}${provider}" in
    *'<'* | *'>'*) sit_fail "unsubstituted placeholder token survived seeding: ${record}" ;;
    esac

    server="https://${name}.sit.invalid:6443"
    seed_one_cluster_secret "${name}" "${landscape}" "${server}" "${role}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${record}" "${name}" "${landscape}" "${server}" "${role}" "${mark}" "${provider}" >>"${tsv}"
  done

  # Derived, never hard-coded: the serving count IS the serving fixture count.
  [ "${serving}" -gt 0 ] || sit_fail 'no serving cluster fixture was seeded'
  [ "${infrastructure}" -ge 2 ] ||
    sit_fail 'the exclusion proof needs at least two differently named infrastructure-only fixtures'

  jq -Rn '
    [inputs | split("\t") |
      {fixture:.[0],name:.[1],landscape:.[2],server:.[3],role:.[4],mark:.[5],provider:.[6]}] |
    sort_by(.name)
  ' <"${tsv}" >"${report}/cluster-secret-inputs.json"
  jq -Rn \
    --arg mark "${SIT_SYNTHETIC_MARK}" \
    --arg provider "${SIT_SYNTHETIC_PROVIDER}" \
    --argjson serving "${serving}" \
    --argjson infrastructure "${infrastructure}" '
    {
      source: "registry cluster fixtures plus the committed SIT-only discriminating infrastructure fixture",
      liveServingRowsAtCommit: 0,
      servingCount: $serving,
      infrastructureOnlyCount: $infrastructure,
      substitution: {
        scope: "throwaway SIT cluster Secrets only; the repository keeps the placeholders",
        mark: {from: "<mark>", to: $mark},
        provider: {from: "<provider>", to: $provider}
      },
      fixtures: [inputs | split("\t") |
        {fixture:.[0],committedName:.[1],committedMark:.[2],committedProvider:.[3],role:.[4]}]
    }
  ' <"${substitutions}" >"${report}/cluster-fixture-substitution.json"

  jq -e --argjson serving "${serving}" '
    ([.[] | select(.role == "serving")] | length) == $serving and
    all(.[]; (.name | test("[<>]")) | not)
  ' "${report}/cluster-secret-inputs.json" >/dev/null
}

# The exclusion law at the LIVE generator: infrastructure-only cluster Secrets
# are seeded, labelled, and selectable, yet no canary Application destination
# lands on their servers. The oracle reads the actual Secret role labels and
# decoded server fields; landscape/name text is evidence only, never a veto.
assert_infrastructure_only_excluded() {
  local applications_snapshot="$1"
  local secrets_snapshot="$2"
  local output="$3"
  local seeded_clusters="${4:-${report}/cluster-secret-inputs.json}"
  local synthetic_fixture="${validation_dir}/fixtures/infrastructure-only-serving-landscape.yaml"
  jq -n \
    --arg syntheticFixture "${synthetic_fixture}" \
    --slurpfile seeded "${seeded_clusters}" \
    --slurpfile secrets "${secrets_snapshot}" \
    --slurpfile apps "${applications_snapshot}" '
    ($seeded[0] | map(select(.role == "infrastructure-only"))) as $seededInfra |
    ($secrets[0].items // [] |
      map(
        select(.metadata.labels["argocd.argoproj.io/secret-type"] == "cluster") |
        {
          name: .metadata.name,
          landscapeLabel: .metadata.labels["atomi.cloud/landscape"],
          clusterRoleLabel: .metadata.labels["atomi.cloud/cluster-role"],
          secretTypeLabel: .metadata.labels["argocd.argoproj.io/secret-type"],
          server: (try (.data.server | @base64d) catch null)
        }
      )
    ) as $actualClusters |
    ($actualClusters | map(select(.clusterRoleLabel == "infrastructure-only"))) as $actualInfra |
    ($actualClusters |
      map(select(.clusterRoleLabel == "serving" and .landscapeLabel == "ampharos"))) as $servingAmpharos |
    ($seededInfra | map(select(.fixture == $syntheticFixture))) as $syntheticSeed |
    ([$seededInfra[] as $expected |
      $actualInfra[] |
      select(
        .name == $expected.name and
        .landscapeLabel == $expected.landscape and
        .server == $expected.server
      ) |
      . + {fixture: $expected.fixture, recordedRole: $expected.role}
    ]) as $observedSeededInfra |
    ([$syntheticSeed[] as $expected |
      $actualInfra[] |
      select(
        .name == $expected.name and
        .landscapeLabel == $expected.landscape and
        .server == $expected.server
      ) |
      . + {fixture: $expected.fixture, recordedRole: $expected.role}
    ]) as $syntheticActual |
    ($apps[0].items // []) as $items |
    {
      seededInfrastructureOnlyFixtures: ($seededInfra | map({fixture,name,landscape,server,recordedRole:.role})),
      observedSeededInfrastructureOnlySecrets: $observedSeededInfra,
      distinctInfrastructureNames: ($seededInfra | map(.name) | unique),
      distinctInfrastructureLandscapes: ($seededInfra | map(.landscape) | unique),
      syntheticAmpharosInfrastructureSecret: {
        seedRecord: ($syntheticSeed[0] // null),
        actualSecret: ($syntheticActual[0] // null)
      },
      applicationDestinations: ($items | map(.spec.destination.server) | unique),
      applicationsOnInfrastructureOnly: [
        $items[] as $app |
        $actualInfra[] as $secret |
        select($app.spec.destination.server == $secret.server) |
        {
          application: $app.metadata.name,
          destinationServer: $app.spec.destination.server,
          secretName: $secret.name,
          secretRole: $secret.clusterRoleLabel,
          secretLandscape: $secret.landscapeLabel
        }
      ],
      applicationsOnServingAmpharos: [
        $items[] as $app |
        $servingAmpharos[] as $secret |
        select($app.spec.destination.server == $secret.server) |
        {
          application: $app.metadata.name,
          destinationServer: $app.spec.destination.server,
          secretName: $secret.name,
          secretRole: $secret.clusterRoleLabel,
          secretLandscape: $secret.landscapeLabel
        }
      ],
      exclusionKeyedOn: "actual Application spec.destination.server matched against actual cluster Secret atomi.cloud/cluster-role labels"
    }
  ' >"${output}"
  if ! jq -e '
    (.seededInfrastructureOnlyFixtures | length) >= 2 and
    (.distinctInfrastructureNames | length) >= 2 and
    (.observedSeededInfrastructureOnlySecrets | length) == (.seededInfrastructureOnlyFixtures | length) and
    .syntheticAmpharosInfrastructureSecret.seedRecord.landscape == "ampharos" and
    .syntheticAmpharosInfrastructureSecret.seedRecord.role == "infrastructure-only" and
    .syntheticAmpharosInfrastructureSecret.actualSecret.landscapeLabel == "ampharos" and
    .syntheticAmpharosInfrastructureSecret.actualSecret.clusterRoleLabel == "infrastructure-only" and
    .syntheticAmpharosInfrastructureSecret.actualSecret.secretTypeLabel == "cluster" and
    (.applicationsOnServingAmpharos | length) >= 1
  ' "${output}" >/dev/null; then
    sit_fail 'infrastructure exclusion oracle prerequisites did not prove the seeded and labelled Secret roles'
    return 1
  fi
  if ! jq -e '(.applicationsOnInfrastructureOnly | length) == 0' "${output}" >/dev/null; then
    sit_fail 'an Application targeted an infrastructure-only cluster Secret destination'
    return 1
  fi
}

# Cheap construction test for the same destination/Secret-role oracle used by
# L1. It deliberately keeps a serving-Ampharos Application present in both red
# cases, so each negative can fail only because its added destination is an
# infrastructure-only Secret server.
infrastructure_exclusion_self_test() {
  local lab="$1"
  local output="$2"
  local seeded="${lab}/cluster-secret-inputs.json"
  local secrets="${lab}/cluster-secrets.json"
  local positive_apps="${lab}/apps-serving-ampharos.json"
  local ampharos_negative_apps="${lab}/apps-ampharos-infrastructure.json"
  local second_negative_apps="${lab}/apps-second-infrastructure.json"
  local positive_result="${lab}/positive.json"
  local ampharos_negative_result="${lab}/ampharos-negative.json"
  local second_negative_result="${lab}/second-negative.json"
  local ampharos_negative_log="${lab}/ampharos-negative.log"
  local second_negative_log="${lab}/second-negative.log"
  local serving_server='https://ampharos-serving.sit.invalid:6443'
  local ampharos_infra_server='https://ampharos-infrastructure-sit.sit.invalid:6443'
  local second_infra_server='https://suicune-sit.sit.invalid:6443'
  local synthetic_fixture="${validation_dir}/fixtures/infrastructure-only-serving-landscape.yaml"
  mkdir -p "${lab}"

  jq -n \
    --arg syntheticFixture "${synthetic_fixture}" \
    --arg servingServer "${serving_server}" \
    --arg ampharosInfraServer "${ampharos_infra_server}" \
    --arg secondInfraServer "${second_infra_server}" '[
      {fixture:"registry/fixtures/clusters/ampharos-mark.yaml",name:"ampharos-serving",landscape:"ampharos",server:$servingServer,role:"serving"},
      {fixture:$syntheticFixture,name:"ampharos-infrastructure-sit",landscape:"ampharos",server:$ampharosInfraServer,role:"infrastructure-only"},
      {fixture:"registry/fixtures/negative/second-infrastructure-cluster.yaml",name:"suicune-sit",landscape:"suicune",server:$secondInfraServer,role:"infrastructure-only"}
    ]' >"${seeded}"
  jq -n \
    --arg servingServer "${serving_server}" \
    --arg ampharosInfraServer "${ampharos_infra_server}" \
    --arg secondInfraServer "${second_infra_server}" '{items:[
      {
        metadata:{name:"ampharos-serving",labels:{
          "argocd.argoproj.io/secret-type":"cluster",
          "atomi.cloud/landscape":"ampharos",
          "atomi.cloud/cluster-role":"serving"
        }},
        data:{server:($servingServer | @base64)}
      },
      {
        metadata:{name:"ampharos-infrastructure-sit",labels:{
          "argocd.argoproj.io/secret-type":"cluster",
          "atomi.cloud/landscape":"ampharos",
          "atomi.cloud/cluster-role":"infrastructure-only"
        }},
        data:{server:($ampharosInfraServer | @base64)}
      },
      {
        metadata:{name:"suicune-sit",labels:{
          "argocd.argoproj.io/secret-type":"cluster",
          "atomi.cloud/landscape":"suicune",
          "atomi.cloud/cluster-role":"infrastructure-only"
        }},
        data:{server:($secondInfraServer | @base64)}
      }
    ]}' >"${secrets}"
  jq -n --arg servingServer "${serving_server}" '{items:[{
    metadata:{name:"canary-ampharos-dummy-ampharos-serving"},
    spec:{destination:{server:$servingServer}}
  }]}' >"${positive_apps}"

  assert_infrastructure_only_excluded \
    "${positive_apps}" "${secrets}" "${positive_result}" "${seeded}" || {
    sit_fail 'the destination oracle rejected a legitimate serving-Ampharos Application'
    return 1
  }
  jq -e '
    (.applicationsOnServingAmpharos | length) == 1 and
    (.applicationsOnInfrastructureOnly | length) == 0 and
    .syntheticAmpharosInfrastructureSecret.actualSecret.clusterRoleLabel == "infrastructure-only"
  ' "${positive_result}" >/dev/null ||
    sit_fail 'the positive infrastructure exclusion construction was not discriminating'

  jq --arg server "${ampharos_infra_server}" '.items += [{
    metadata:{name:"canary-ampharos-dummy-illegal-infrastructure"},
    spec:{destination:{server:$server}}
  }]' "${positive_apps}" >"${ampharos_negative_apps}"
  if assert_infrastructure_only_excluded \
    "${ampharos_negative_apps}" "${secrets}" "${ampharos_negative_result}" "${seeded}" \
    2>"${ampharos_negative_log}"; then
    sit_fail 'the destination oracle accepted an Application on the Ampharos infrastructure-only server'
    return 1
  fi
  rg -F 'an Application targeted an infrastructure-only cluster Secret destination' \
    "${ampharos_negative_log}" >/dev/null ||
    sit_fail 'the Ampharos infrastructure-only negative failed for the wrong cause'
  jq -e --arg server "${ampharos_infra_server}" '
    (.applicationsOnServingAmpharos | length) == 1 and
    .applicationsOnInfrastructureOnly == [{
      application:"canary-ampharos-dummy-illegal-infrastructure",
      destinationServer:$server,
      secretName:"ampharos-infrastructure-sit",
      secretRole:"infrastructure-only",
      secretLandscape:"ampharos"
    }]
  ' "${ampharos_negative_result}" >/dev/null ||
    sit_fail 'the Ampharos negative did not isolate its infrastructure-only destination'

  jq --arg server "${second_infra_server}" '.items += [{
    metadata:{name:"canary-suicune-dummy-illegal-infrastructure"},
    spec:{destination:{server:$server}}
  }]' "${positive_apps}" >"${second_negative_apps}"
  if assert_infrastructure_only_excluded \
    "${second_negative_apps}" "${secrets}" "${second_negative_result}" "${seeded}" \
    2>"${second_negative_log}"; then
    sit_fail 'the destination oracle accepted an Application on the second infrastructure-only server'
    return 1
  fi
  rg -F 'an Application targeted an infrastructure-only cluster Secret destination' \
    "${second_negative_log}" >/dev/null ||
    sit_fail 'the second infrastructure-only negative failed for the wrong cause'
  jq -e --arg server "${second_infra_server}" '
    (.applicationsOnServingAmpharos | length) == 1 and
    .applicationsOnInfrastructureOnly == [{
      application:"canary-suicune-dummy-illegal-infrastructure",
      destinationServer:$server,
      secretName:"suicune-sit",
      secretRole:"infrastructure-only",
      secretLandscape:"suicune"
    }]
  ' "${second_negative_result}" >/dev/null ||
    sit_fail 'the second negative did not isolate its infrastructure-only destination'

  jq -n \
    --slurpfile positive "${positive_result}" \
    --slurpfile ampharosNegative "${ampharos_negative_result}" \
    --slurpfile secondNegative "${second_negative_result}" '{
      status:"pass",
      oracle:"actual Application destination server matched to actual Secret role label",
      servingAmpharosAccepted:$positive[0],
      ampharosInfrastructureRejected:$ampharosNegative[0].applicationsOnInfrastructureOnly,
      differentlyNamedInfrastructureRejected:$secondNegative[0].applicationsOnInfrastructureOnly,
      liveRunClaimed:false
    }' >"${output}"
}

render_and_apply_appsets() {
  "${validation_dir}/derive-appset.sh" \
    registry/platforms-appset.yaml \
    "${work}/platforms-appset.sit.yaml" \
    "${FLEET_REPO_URL}" \
    "${FLEET_SERVICES_REPO_URL}" \
    "${CANARY_REPO_URL}" \
    "${SITOTHER_REPO_URL}" \
    "${report}"

  helm template canary "${FLEET_SOURCE}/registry/charts/diene-platform" \
    --namespace canary \
    --values "${FLEET_SOURCE}/platforms/canary/services.yaml" \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml \
    --set-string "fleet.repoURL=${FLEET_REPO_URL}" \
    --set-string 'fleet.revision=main' >"${work}/canary-rendered.yaml"
  yq 'select(.kind == "ApplicationSet")' "${work}/canary-rendered.yaml" >"${work}/canary-appset.yaml"
  yq -e '.kind == "ApplicationSet" and .metadata.name == "canary"' \
    "${work}/canary-appset.yaml" >/dev/null
  cp "${work}/canary-appset.yaml" "${report}/canary-appset.yaml"
  cp "${work}/platforms-appset.sit.yaml" "${report}/platforms-appset.sit.yaml"
  kubectl apply -f "${work}/platforms-appset.sit.yaml"
  kubectl apply -f "${work}/canary-appset.yaml"
}

build_expected_child_apps() {
  local output="$1"
  local tsv="${work}/expected-child-apps.tsv"
  : >"${tsv}"
  # No process substitution on an instance-executed path; the producer is
  # status-checked so a failed find or sort cannot become an empty expectation.
  local landscape_files="${work}/landscape-files.txt"
  find "${FLEET_SOURCE}/platforms/canary/landscapes" \
    -mindepth 2 -maxdepth 2 -type f -name '*.yaml' | sort >"${landscape_files}" ||
    sit_fail 'could not enumerate the canary landscape files'
  local row platform landscape service tag cluster_name_value server matches
  while IFS= read -r row; do
    platform="$(yq -r '.platform' "${row}")"
    landscape="$(yq -r '.landscape' "${row}")"
    service="$(yq -r '.service' "${row}")"
    tag="$(yq -r '.pin.tag' "${row}")"
    printf '%s\t%s\t%s\t%s\n' \
      "${platform}-${landscape}-${service}-primordial" \
      'https://kubernetes.default.svc' "${tag}" "${landscape}" >>"${tsv}"
    matches="$(jq --arg landscape "${landscape}" \
      '[.[] | select(.role == "serving" and .landscape == $landscape)] | length' \
      "${report}/cluster-secret-inputs.json")"
    [ "${matches}" -eq 1 ] || sit_fail "row ${row} must match exactly one ephemeral serving cluster Secret"
    cluster_name_value="$(jq -r --arg landscape "${landscape}" \
      '.[] | select(.role == "serving" and .landscape == $landscape) | .name' \
      "${report}/cluster-secret-inputs.json")"
    server="$(jq -r --arg landscape "${landscape}" \
      '.[] | select(.role == "serving" and .landscape == $landscape) | .server' \
      "${report}/cluster-secret-inputs.json")"
    printf '%s\t%s\t%s\t%s\n' \
      "${platform}-${landscape}-${service}-${cluster_name_value}" \
      "${server}" "${tag}" "${landscape}" >>"${tsv}"
  done <"${landscape_files}"
  jq -Rn '
    [inputs | split("\t") | {name:.[0],server:.[1],targetRevision:.[2],landscape:.[3]}] |
    sort_by(.name)
  ' <"${tsv}" >"${output}"
}

check_baseline_apps() {
  local snapshot="${work}/baseline-check.json"
  local actual="${work}/baseline-actual.json"
  sit_snapshot_apps "${snapshot}" || return 1
  jq '
    [.items[] |
      select(any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and .name == "canary")) |
      {name:.metadata.name,server:.spec.destination.server,targetRevision:.spec.sources[0].targetRevision,
       landscape:(.metadata.name | capture("^canary-(?<landscape>[^-]+)-").landscape)}
    ] | sort_by(.name)
  ' "${snapshot}" >"${actual}"
  cmp -s "${report}/expected-child-apps.json" "${actual}" || return 1
  jq -e '
    ([.items[] | select(.metadata.name == "platform-canary" or .metadata.name == "platform-sitother")] | length) == 2 and
    (.items[] | select(.metadata.name == "platform-canary") |
      .spec.sources[0].targetRevision == "main" and .spec.syncPolicy.automated == null) and
    (.items[] | select(.metadata.name == "platform-sitother") |
      .spec.sources[0].targetRevision == "machinery-stable" and
      .spec.syncPolicy.automated.prune == true and .spec.syncPolicy.automated.selfHeal == true)
  ' "${snapshot}" >/dev/null
}

check_child_revision() {
  local landscape="$1"
  local revision="$2"
  kubectl -n argocd get applications.argoproj.io -o json |
    jq -e --arg landscape "${landscape}" --arg revision "${revision}" '
      [.items[] |
        select(any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and .name == "canary")) |
        select(.metadata.name | startswith("canary-" + $landscape + "-"))
      ] as $apps |
      ($apps | length) == 2 and all($apps[]; .spec.sources[0].targetRevision == $revision)
    ' >/dev/null 2>&1
}

capture_child_specs() {
  local label="$1"
  sit_snapshot_apps "${report}/apps-${label}.json"
  sit_child_specs "${report}/apps-${label}.json" "${report}/child-specs-${label}.json"
}

expected_changed_names() {
  local output="$1"
  shift
  local landscape name
  local tsv="${work}/changed-names.tsv"
  : >"${tsv}"
  # No process substitution on an instance-executed path; a failed jq must
  # refuse rather than contribute nothing and look like a landscape with no
  # changed names.
  local names="${work}/changed-names.src.txt"
  for landscape in "$@"; do
    jq -r --arg landscape "${landscape}" '.[] | select(.landscape == $landscape) | .name' \
      "${report}/expected-child-apps.json" >"${names}" ||
      sit_fail "could not read expected child-app names for landscape ${landscape}"
    while IFS= read -r name; do
      printf '%s\n' "${name}" >>"${tsv}"
    done <"${names}"
  done
  rm -f "${names}"
  jq -Rn '[inputs] | sort' <"${tsv}" >"${output}"
}

assert_changed_landscapes() {
  local before="$1"
  local after="$2"
  local label="$3"
  shift 3
  sit_changed_names "${before}" "${after}" "${report}/changed-${label}.json"
  expected_changed_names "${work}/expected-changed-${label}.json" "$@"
  sit_assert_json_equal "${work}/expected-changed-${label}.json" "${report}/changed-${label}.json" \
    "${label} changed an unexpected generated Application spec"
}

send_webhook() {
  local endpoint="$1"
  local signature_mode="$2"
  local output="$3"
  local ref="$4"
  local before="$5"
  local after="$6"
  shift 6
  local args=(
    "${validation_dir}/github-webhook.ts"
    --url "${endpoint}"
    --repo-url "${FLEET_REPO_URL}"
    --secret "${SIT_SECRET}"
    --ref "${ref}"
    --before "${before}"
    --after "${after}"
  )
  local changed
  for changed in "$@"; do
    args+=(--changed "${changed}")
  done
  case "${signature_mode}" in
  correct) ;;
  wrong) args+=(--wrong-secret) ;;
  missing) args+=(--no-signature) ;;
  *) sit_fail "unknown signature mode: ${signature_mode}" ;;
  esac
  bun "${args[@]}" >"${output}"
}

check_platform_source_revision() {
  local application="$1"
  local expected="$2"
  kubectl -n argocd get application.argoproj.io "${application}" -o json |
    jq -e --arg expected "${expected}" '.status.sync.revisions[0] == $expected' >/dev/null 2>&1
}

check_application_controller_replicas() {
  local expected="$1"
  kubectl -n argocd get statefulset argocd-application-controller -o json |
    jq -e --argjson expected "${expected}" '(.status.replicas // 0) == $expected' >/dev/null 2>&1
}

scale_application_controller() {
  local replicas="$1"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas="${replicas}"
  if [ "${replicas}" -eq 0 ]; then
    sit_wait_for 60 'Application controller to stop' check_application_controller_replicas 0
  else
    kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
  fi
}

check_applicationset_controller_replicas() {
  local expected="$1"
  kubectl -n argocd get deployment argocd-applicationset-controller -o json |
    jq -e --argjson expected "${expected}" '
      (.status.replicas // 0) == $expected and
      (.status.readyReplicas // 0) == $expected and
      (.status.availableReplicas // 0) == $expected
    ' >/dev/null 2>&1
}

scale_applicationset_controller() {
  local replicas="$1"
  kubectl -n argocd scale deployment argocd-applicationset-controller --replicas="${replicas}"
  if [ "${replicas}" -eq 0 ]; then
    sit_wait_for 60 'ApplicationSet controller to stop' check_applicationset_controller_replicas 0
  else
    kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
  fi
}

check_application_absent() {
  local application="$1"
  ! kubectl -n argocd get application.argoproj.io "${application}" >/dev/null 2>&1
}

check_sitother_recreated_without_operation() {
  local old_uid="$1"
  local owner_uid="$2"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json |
    jq -e --arg oldUid "${old_uid}" --arg ownerUid "${owner_uid}" '
      .metadata.uid != $oldUid and
      any(.metadata.ownerReferences[]?;
        .apiVersion == "argoproj.io/v1alpha1" and
        .kind == "ApplicationSet" and
        .name == "platforms" and
        .uid == $ownerUid and
        .controller == true) and
      .spec.sources[0].targetRevision == "machinery-stable" and
      .spec.syncPolicy.automated.prune == true and
      .spec.syncPolicy.automated.selfHeal == true and
      .operation == null and
      .status.operationState == null
    ' >/dev/null 2>&1
}

check_sitother_automation_live() {
  local expected_revision="$1"
  local expected_uid="$2"
  local not_before="$3"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json |
    jq -e \
      --arg expected "${expected_revision}" \
      --arg uid "${expected_uid}" \
      --arg notBefore "${not_before}" '
      .metadata.uid == $uid and
      .spec.sources[0].targetRevision == "machinery-stable" and
      .spec.syncPolicy.automated.prune == true and
      .spec.syncPolicy.automated.selfHeal == true and
      .status.sync.revisions[0] == $expected and
      .operation.initiatedBy.automated == true and
      .operation.sync.revisions[0] == $expected and
      .status.operationState.startedAt >= $notBefore and
      .status.operationState.operation.initiatedBy.automated == true and
      .status.operationState.operation.sync.revisions[0] == $expected
    ' >/dev/null 2>&1
}

# --- machinery-stable pointer: forward-only semantics -----------------------
#
# The product path is a reviewed pointer file on main plus a protected workflow
# that PATCHes refs/tags/machinery-stable with force:false after a descendant
# precheck. This venue has no GitHub API, so the write is modelled by an
# explicit old->new compare-and-swap on the serving repository. Nothing here
# ever force-pushes, and the backward case is refused twice: by the descendant
# precheck and by the transport's own refusal to update an existing tag without
# force.

read_machinery_pointer_target() {
  local pointer="$1"
  [ -s "${pointer}" ] || sit_fail "machinery-stable pointer file is missing: ${pointer}"
  local line
  line="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${pointer}")"
  [[ ${line} =~ ^target:[[:space:]]([0-9a-f]{40})$ ]] ||
    sit_fail "pointer must contain exactly: target: <40-lowercase-hex-main-commit> (${pointer})"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

write_machinery_pointer() {
  local pointer="$1"
  local target="$2"
  printf '%s\n' \
    '# Reviewed pointer consumed only by the protected machinery-stable workflow.' \
    '# Promotion and rollback both select a descendant commit on main.' \
    "target: ${target}" >"${pointer}"
}

machinery_pointer_ref() {
  git -C "${FLEET_BARE}" rev-parse 'refs/tags/machinery-stable'
}

sync_local_machinery_tag() {
  git -C "${FLEET_SOURCE}" tag -d machinery-stable >/dev/null 2>&1 || true
  git -C "${FLEET_SOURCE}" fetch --quiet sit 'refs/tags/machinery-stable:refs/tags/machinery-stable'
}

# Advance the pointer to a commit on main and move the tag forward only.
advance_machinery_pointer() {
  local target="$1"
  local reason="$2"
  local commit_evidence="$3"
  local advance_evidence="$4"
  local current pointer_target main_tip verified
  current="$(machinery_pointer_ref)"

  write_machinery_pointer "${FLEET_SOURCE}/registry/machinery-stable.yaml" "${target}"
  fleet_commit "pointer PR: ${reason}" "${commit_evidence}" 'registry/machinery-stable.yaml'
  pointer_target="$(read_machinery_pointer_target "${FLEET_SOURCE}/registry/machinery-stable.yaml")"
  [ "${pointer_target}" = "${target}" ] || sit_fail 'pointer file does not name the requested target'

  # These three guards stand immediately before a destructive ref write, so they
  # return explicitly instead of relying on errexit being active at the call
  # site: a caller that suppresses errexit must still never reach the write.
  main_tip="$(git -C "${FLEET_SOURCE}" rev-parse main)"
  if ! git -C "${FLEET_SOURCE}" merge-base --is-ancestor "${pointer_target}" "${main_tip}"; then
    sit_fail "pointer ${pointer_target} is not on main"
    return 1
  fi
  if [ "${current}" = "${pointer_target}" ]; then
    sit_fail 'pointer advance requested no movement'
    return 1
  fi
  if ! git -C "${FLEET_SOURCE}" merge-base --is-ancestor "${current}" "${pointer_target}"; then
    sit_fail "pointer ${pointer_target} would backtrack machinery-stable from ${current}"
    return 1
  fi

  # force:false, expressed as an explicit old->new compare-and-swap.
  git -C "${FLEET_BARE}" update-ref 'refs/tags/machinery-stable' "${pointer_target}" "${current}"
  verified="$(machinery_pointer_ref)"
  [ "${verified}" = "${pointer_target}" ] ||
    sit_fail "post-write machinery-stable target ${verified} differs from ${pointer_target}"
  sync_local_machinery_tag

  jq -n \
    --arg reason "${reason}" \
    --arg old "${current}" \
    --arg new "${pointer_target}" \
    --arg verified "${verified}" \
    --arg pointerCommit "${FLEET_LAST_COMMIT}" \
    --arg mainTip "${main_tip}" \
    '{
      reason:$reason,
      mechanism:"pointer file on main + descendant precheck + explicit old->new compare-and-swap",
      force:false,
      forcePushUsed:false,
      oldRef:$old,
      newRef:$new,
      verifiedRef:$verified,
      descendantOfOld:true,
      pointerCommitOnMain:$pointerCommit,
      mainTip:$mainTip
    }' >"${advance_evidence}"
}

# The backward case, refused twice and proven not to have moved the ref.
reject_backward_machinery_pointer() {
  local backward="$1"
  local evidence="$2"
  local push_log="$3"
  local current precheck push_status after
  current="$(machinery_pointer_ref)"

  precheck='rejected'
  if git -C "${FLEET_SOURCE}" merge-base --is-ancestor "${current}" "${backward}"; then
    precheck='accepted'
  fi
  if [ "${precheck}" != 'rejected' ]; then
    sit_fail 'the descendant precheck accepted a backward machinery-stable pointer'
    return 1
  fi

  git -C "${FLEET_SOURCE}" tag -d machinery-stable >/dev/null 2>&1 || true
  git -C "${FLEET_SOURCE}" tag machinery-stable "${backward}"
  push_status=0
  git -C "${FLEET_SOURCE}" push sit 'refs/tags/machinery-stable' >"${push_log}" 2>&1 || push_status=$?
  sync_local_machinery_tag
  [ "${push_status}" -ne 0 ] ||
    sit_fail 'the transport accepted a non-forced backward update of an existing tag'

  after="$(machinery_pointer_ref)"
  [ "${after}" = "${current}" ] ||
    sit_fail "machinery-stable moved during the rejected backward attempt: ${current} -> ${after}"

  jq -n \
    --arg current "${current}" \
    --arg backward "${backward}" \
    --arg after "${after}" \
    --argjson pushStatus "${push_status}" \
    --rawfile pushOutput "${push_log}" \
    '{
      attemptedTarget:$backward,
      refBefore:$current,
      refAfter:$after,
      descendantPrecheck:"rejected",
      nonForcedPushExitStatus:$pushStatus,
      nonForcedPushOutput:($pushOutput | .[0:2048]),
      tagMovedBackward:false
    }' >"${evidence}"
}

# Deterministic self-test of the forward-only pointer semantics, on throwaway
# repositories, with no cluster and no network. It runs the SAME functions L5
# runs, so the L5 leg is never the first place they execute.
machinery_pointer_self_test() {
  local lab="$1"
  local output="$2"
  local saved_source="${FLEET_SOURCE}"
  local saved_bare="${FLEET_BARE}"
  local saved_sequence="${COMMIT_SEQUENCE}"
  local c1 c4 revert status

  mkdir -p "${lab}"
  FLEET_SOURCE="${lab}/fleet"
  FLEET_BARE="${lab}/fleet.git"
  COMMIT_SEQUENCE=1
  mkdir -p "${FLEET_SOURCE}/registry"
  printf 'seed\n' >"${FLEET_SOURCE}/registry/seed.txt"
  git init --quiet --initial-branch=main "${FLEET_SOURCE}"
  git -C "${FLEET_SOURCE}" add registry
  git_commit_at "${FLEET_SOURCE}" 'C1 pointer self-test seed' 1
  c1="$(git -C "${FLEET_SOURCE}" rev-parse HEAD)"
  git -C "${FLEET_SOURCE}" tag machinery-stable "${c1}"
  write_machinery_pointer "${FLEET_SOURCE}/registry/machinery-stable.yaml" "${c1}"
  git -C "${FLEET_SOURCE}" add registry/machinery-stable.yaml
  git_commit_at "${FLEET_SOURCE}" 'C1b pointer self-test pointer' 1
  make_bare_remote "${FLEET_SOURCE}" "${FLEET_BARE}"

  printf 'marker\n' >"${FLEET_SOURCE}/registry/marker.txt"
  fleet_commit 'C4 pointer self-test marker' "${lab}/git-C4.txt" 'registry/marker.txt'
  c4="${FLEET_LAST_COMMIT}"
  advance_machinery_pointer "${c4}" 'self-test forward advance' \
    "${lab}/git-C5-pointer.txt" "${lab}/advance-forward.json"
  [ "$(machinery_pointer_ref)" = "${c4}" ] || sit_fail 'self-test forward advance did not move the ref'

  reject_backward_machinery_pointer "${c1}" "${lab}/backward.json" "${lab}/backward-push.log"

  fleet_revert "${c4}" 'C8 pointer self-test revert' "${lab}/git-C8-revert.txt"
  revert="${FLEET_LAST_COMMIT}"
  [ ! -f "${FLEET_SOURCE}/registry/marker.txt" ] || sit_fail 'the self-test revert did not undo its change'
  advance_machinery_pointer "${revert}" 'self-test rollback advance' \
    "${lab}/git-C8-pointer.txt" "${lab}/advance-rollback.json"

  status=0
  (advance_machinery_pointer "${c1}" 'self-test illegal backward advance' \
    "${lab}/git-bad-pointer.txt" "${lab}/advance-bad.json") >/dev/null 2>&1 || status=$?
  [ "${status}" -ne 0 ] || sit_fail 'the pointer advance accepted a backward target'
  [ "$(machinery_pointer_ref)" = "${revert}" ] ||
    sit_fail 'the rejected backward advance still moved the ref'

  status=0
  printf 'target: not-a-sha\n' >"${lab}/bad-pointer.yaml"
  (read_machinery_pointer_target "${lab}/bad-pointer.yaml") >/dev/null 2>&1 || status=$?
  [ "${status}" -ne 0 ] || sit_fail 'a malformed pointer file was accepted'
  status=0
  printf 'target: %s\ntarget: %s\n' "${c1}" "${c4}" >"${lab}/two-pointer.yaml"
  (read_machinery_pointer_target "${lab}/two-pointer.yaml") >/dev/null 2>&1 || status=$?
  [ "${status}" -ne 0 ] || sit_fail 'a pointer file with a second target line was accepted'

  jq -n \
    --arg c1 "${c1}" \
    --arg c4 "${c4}" \
    --arg revert "${revert}" \
    --slurpfile forward "${lab}/advance-forward.json" \
    --slurpfile backward "${lab}/backward.json" \
    --slurpfile rollback "${lab}/advance-rollback.json" \
    '{
      status:"pass",
      check:"machinery-pointer-forward-only",
      seed:$c1,promoted:$c4,revert:$revert,
      forwardAdvance:$forward[0],
      backwardRejected:$backward[0],
      rollbackAdvance:$rollback[0]
    }' >"${output}"

  FLEET_SOURCE="${saved_source}"
  FLEET_BARE="${saved_bare}"
  COMMIT_SEQUENCE="${saved_sequence}"
}

# --- L8: the exact v1 Kargo mapping against the pinned Kargo CRDs -----------
#
# What this leg proves: the committed compiler chart renders the ratified
# fields; a live API server carrying the REAL pinned Kargo v1.9.10 CRDs admits
# them; the persisted objects still carry every asserted field (so none was
# pruned as unknown); and the pinned CRDs reject the enum/pattern negatives.
# What it does NOT prove: any Kargo CONTROLLER behaviour. See kargo-residuals.

fetch_kargo_crds() {
  KARGO_CRD_DIR="${work}/kargo-crds"
  mkdir -p "${KARGO_CRD_DIR}"
  local entry file digest
  : >"${work}/kargo-crds.sha256"
  for entry in \
    "kargo.akuity.io_projects.yaml ${KARGO_CRD_PROJECTS_SHA256}" \
    "kargo.akuity.io_projectconfigs.yaml ${KARGO_CRD_PROJECTCONFIGS_SHA256}" \
    "kargo.akuity.io_stages.yaml ${KARGO_CRD_STAGES_SHA256}" \
    "kargo.akuity.io_warehouses.yaml ${KARGO_CRD_WAREHOUSES_SHA256}"; do
    file="${entry%% *}"
    digest="${entry##* }"
    [[ ${digest} =~ ^[0-9a-f]{64}$ ]] || sit_fail "invalid Kargo CRD checksum pin for ${file}"
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
      "${KARGO_CRD_BASE_URL}/${file}" --output "${KARGO_CRD_DIR}/${file}"
    printf '%s  %s\n' "${digest}" "${KARGO_CRD_DIR}/${file}" >>"${work}/kargo-crds.sha256"
  done
  sha256sum --check "${work}/kargo-crds.sha256" | tee "${report}/kargo-crds-verified.txt"
}

kargo_negative_rejected() {
  local label="$1"
  local manifest="$2"
  local log="$3"
  local status=0
  kubectl apply --dry-run=server -f "${manifest}" >"${log}" 2>&1 || status=$?
  [ "${status}" -ne 0 ] ||
    sit_fail "the pinned Kargo CRDs accepted the ${label} negative"
  jq -n \
    --arg label "${label}" \
    --argjson exitStatus "${status}" \
    --rawfile output "${log}" \
    '{negative:$label,rejected:true,exitStatus:$exitStatus,apiServerMessage:($output | .[0:1024])}'
}

run_kargo_contract_leg() {
  fetch_kargo_crds
  kubectl apply --server-side --force-conflicts --field-manager=fleet-sit -f "${KARGO_CRD_DIR}"
  local crd
  for crd in projects projectconfigs stages warehouses; do
    kubectl wait --for=condition=Established "crd/${crd}.kargo.akuity.io" --timeout=120s
  done
  yq ea -o=json '[.]' "${KARGO_CRD_DIR}"/*.yaml >"${work}/kargo-crds.json"

  helm template canary registry/charts/diene-platform \
    --namespace canary \
    --values platforms/canary/services.yaml \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml |
    yq 'select(.apiVersion == "kargo.akuity.io/v1alpha1")' >"${report}/kargo-rendered.yaml"
  yq ea -o=json '[.] | map(select(.apiVersion == "kargo.akuity.io/v1alpha1"))' \
    "${report}/kargo-rendered.yaml" >"${work}/kargo-rendered.json"
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${work}/kargo-rendered.json" \
    --crds "${work}/kargo-crds.json" \
    --out "${report}/kargo-rendered-contract.json" \
    --source 'rendered from the committed compiler chart at the recorded commit'
  local rendered_expression
  rendered_expression="$(yq -r '
    select(.kind == "Stage" and .metadata.name == "canary-dummy-pichu") |
    .spec.promotionTemplate.spec.steps[] | select(.uses == "yaml-update") |
    .config.updates[0].value
  ' "${report}/kargo-rendered.yaml")"
  # The dollar braces are literal Kargo expr-lang input, not shell expansion.
  # shellcheck disable=SC2016
  local expected_expression='${{ imageFrom("registry.atomi.cloud/canary/dummy").Tag }}'
  [ "${rendered_expression}" = "${expected_expression}" ] ||
    sit_fail 'the rendered yaml-update expression is not the exact pinned expr-lang call form'
  (
    cd "${validation_dir}/fixtures/kargo-expression"
    KARGO_EXPRESSION_UNDER_TEST="${rendered_expression}" go test ./...
  ) >"${report}/kargo-expression-engine.txt" 2>&1

  kubectl create namespace canary
  kubectl apply --server-side --field-manager=fleet-sit -f "${report}/kargo-rendered.yaml"
  kubectl get projects.kargo.akuity.io canary -o json >"${work}/kargo-project.json"
  kubectl -n canary get projectconfigs.kargo.akuity.io,warehouses.kargo.akuity.io,stages.kargo.akuity.io \
    -o json >"${work}/kargo-namespaced.json"
  jq -n \
    --slurpfile project "${work}/kargo-project.json" \
    --slurpfile namespaced "${work}/kargo-namespaced.json" \
    '[$project[0]] + $namespaced[0].items' >"${report}/kargo-persisted.json"
  # The pruning oracle: the SAME field-exact contract, re-run over what the API
  # server actually stored. A field the CRD does not declare is gone by now.
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${report}/kargo-persisted.json" \
    --crds "${work}/kargo-crds.json" \
    --out "${report}/kargo-persisted-contract.json" \
    --source 'read back from an API server carrying the pinned Kargo v1.9.10 CRDs'
  jq -e '.ok == true and .crdSemantics != null' "${report}/kargo-persisted-contract.json" >/dev/null
  jq '.crdSemantics' "${report}/kargo-persisted-contract.json" >"${report}/kargo-crd-semantics.json"
  jq '.preserveUnknownFieldsBlindSpots' "${report}/kargo-persisted-contract.json" \
    >"${report}/kargo-crd-preserve-unknown-blind-spots.json"
  jq -e '
    type == "array" and length > 0 and
    any(.[]; .path | test("promotionTemplate.*steps.*config")) and
    all(.[]; .qualification | test("persistence, not field-level schema declaration or expression validity"))
  ' "${report}/kargo-crd-preserve-unknown-blind-spots.json" >/dev/null
  # Exact key-set equality, not a count: a claim keyed only by kind.field would
  # collide with its sibling claim on the same field and shrink the set, so
  # missing, extra AND colliding records all fail here. The enum/pattern checks
  # then apply to EVERY claim entry on that field, not just one of them.
  jq -e '
    (keys | sort) == [
      "ProjectConfig.autoPromotionEnabled.defaults-to-false",
      "Stage.availabilityStrategy.all-requires-every-upstream",
      "Stage.availabilityStrategy.omitted-defaults-to-oneof",
      "Stage.requiredSoakTime.soak-additional-to-verification",
      "Stage.requiredSoakTime.soak-clock-is-upstream-residency"
    ] and
    all(.[]; .present == true) and
    all(to_entries[] | select(.key | startswith("Stage.availabilityStrategy.")) | .value;
        (.enum | index("All")) != null and (.enum | index("OneOf")) != null) and
    all(to_entries[] | select(.key | startswith("Stage.requiredSoakTime.")) | .value;
        (.pattern | length) > 0)
  ' "${report}/kargo-crd-semantics.json" >/dev/null

  # Negatives at the real API server: the ratified values are constrained by the
  # pinned CRDs, so `All` and `15m` are checked vocabulary rather than free text.
  yq '(select(.kind == "Stage" and .metadata.name == "canary-dummy-ampharos") |
       .spec.requestedFreight[0].sources.availabilityStrategy) = "Sometimes"' \
    "${report}/kargo-rendered.yaml" |
    yq 'select(.kind == "Stage" and .metadata.name == "canary-dummy-ampharos")' \
      >"${work}/kargo-negative-strategy.yaml"
  yq '(select(.kind == "Stage" and .metadata.name == "canary-dummy-ampharos") |
       .spec.requestedFreight[0].sources.requiredSoakTime) = "15minutes"' \
    "${report}/kargo-rendered.yaml" |
    yq 'select(.kind == "Stage" and .metadata.name == "canary-dummy-ampharos")' \
      >"${work}/kargo-negative-soak.yaml"
  local strategy_negative soak_negative
  strategy_negative="$(kargo_negative_rejected 'availabilityStrategy outside the pinned CRD enum' \
    "${work}/kargo-negative-strategy.yaml" "${work}/kargo-negative-strategy.log")"
  soak_negative="$(kargo_negative_rejected 'requiredSoakTime outside the pinned CRD duration pattern' \
    "${work}/kargo-negative-soak.yaml" "${work}/kargo-negative-soak.log")"

  # And the offline oracle must be non-vacuous: dropping the rendezvous
  # strategy is admitted by the CRD (it is merely optional) yet must fail the
  # ratified contract, because the omission silently means OneOf.
  jq 'map(if .kind == "Stage" and .metadata.name == "canary-dummy-ampharos"
          then del(.spec.requestedFreight[0].sources.availabilityStrategy) else . end)' \
    "${work}/kargo-rendered.json" >"${work}/kargo-rendezvous-mutation.json"
  local mutation_status=0
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${work}/kargo-rendezvous-mutation.json" \
    --crds "${work}/kargo-crds.json" \
    --out "${work}/kargo-rendezvous-mutation-contract.json" \
    --source 'rendezvous mutation' >/dev/null 2>&1 || mutation_status=$?
  [ "${mutation_status}" -ne 0 ] ||
    sit_fail 'the Kargo field oracle accepted a rendezvous with no availabilityStrategy'

  jq -n \
    --argjson strategy "${strategy_negative}" \
    --argjson soak "${soak_negative}" \
    --slurpfile mutation "${work}/kargo-rendezvous-mutation-contract.json" \
    '{
      apiServerNegatives: [$strategy, $soak],
      renderMutationNegative: {
        negative: "rendezvous loses availabilityStrategy: All",
        crdAdmits: true,
        ratifiedContractRejects: true,
        failedChecks: ($mutation[0].failed | map(.name))
      }
    }' >"${report}/kargo-negatives.json"

  jq -n \
    --arg version "${KARGO_VERSION}" \
    --arg commit "${KARGO_SOURCE_COMMIT}" \
    '{
      pinnedKargo: {version:$version, sourceCommit:$commit, artefact:"upstream CRDs, applied to a live API server"},
      proven: [
        "the committed compiler chart renders the exact ratified v1 fields for all four canary Stages",
        "a live API server carrying the pinned Kargo CRDs admits every rendered object",
        "every asserted field survives admission unpruned, so each is a real field of the pinned Kargo API",
        "ProjectConfig enables auto-promotion for exactly pichu/raichu/ampharos and carries NO policy for the manual pikachu Stage",
        "the ampharos rendezvous requests freight from BOTH pikachu and raichu with availabilityStrategy All and requiredSoakTime 15m",
        "canary-smoke verifies pikachu and canary-analysis verifies the ampharos rendezvous",
        "the pinned CRDs reject an availabilityStrategy outside their enum and a requiredSoakTime outside their duration pattern",
        "the pinned CRD text itself states that All requires all upstream Stages, that omission means OneOf, and that requiredSoakTime measures continuous occupancy of the upstream Stage in ADDITION to upstream verification"
      ],
      notProven: [
        "L8 alone does not execute any Kargo controller, Freight, Promotion, AnalysisRun, gate, or soak decision; those are proved separately and explicitly in L9",
        "read-back is not a field-schema oracle below x-kubernetes-preserve-unknown-fields; the emitted blind-spot list identifies those paths and the yaml-update expression is instead bound by the exact contract check, pinned evaluator test, and L9 execution"
      ],
      residual: "this artifact is deliberately the static contract layer. Runtime behavior is neither claimed nor inferred here; the ordered L9 artifact carries that proof."
    }' >"${report}/kargo-residuals.json"
}

# --- L9: real pinned Kargo controller runtime ------------------------------

namespace_ctr() {
  /vendor/containerd/ctr --address /var/run/containerd/containerd.sock \
    --namespace k8s.io "$@"
}

namespace_crictl() {
  k3s crictl "$@"
}

kargo_runtime_verify_host_image() {
  local image_ref="$1"
  local digest_ref="$2"
  local output="$3"
  local digest="${digest_ref#*@}"
  local tag_ref="${image_ref%@*}"
  docker pull "${image_ref}" >>"${report}/kargo-runtime-image-pulls.txt" 2>&1
  docker image inspect "${image_ref}" >"${output}"
  # Docker may abbreviate docker.io/library repositories in RepoDigests. The
  # inspected reference itself is digest-qualified, so match the immutable
  # digest here and separately require the tag that docker save will stream.
  jq -e --arg digest "${digest}" '
    length == 1 and
    any(.[0].RepoDigests[]?; endswith("@" + $digest))
  ' "${output}" >/dev/null ||
    sit_fail "host image does not carry the pinned digest: ${image_ref}"
  # The save->import digest chain below depends on this daemon running the
  # CONTAINERD image store, where .Id is the image's root descriptor digest -
  # here the pinned multi-platform index. Under the classic graph-driver store
  # .Id is the config blob digest and can never equal the pin. Asserting it at
  # the source turns a store-type mismatch into an immediate, precise failure
  # instead of a late, ambiguous node-digest mismatch three steps later. All
  # six inspection objects the SIT retains satisfy this today.
  jq -e --arg digest "${digest}" '.[0].Id == $digest' "${output}" >/dev/null ||
    sit_fail "the daemon does not expose the pinned index digest as the image id, so it is not running the containerd image store: ${image_ref}"
  # A digest-qualified pull stores the image under its digest ONLY and never
  # creates name:tag (classic and containerd stores alike), so the save input
  # has to be bound explicitly - and bound FROM the verified digest
  # reference, so the pin, not the registry tag, decides the content. `docker
  # image tag` also overwrites any stale binding a warm daemon carried in.
  docker image tag "${digest_ref}" "${tag_ref}" ||
    sit_fail "could not bind the export tag to the pinned digest: ${tag_ref}"
  docker image inspect "${tag_ref}" >"${output%.json}-tag.json" 2>/dev/null ||
    sit_fail "the digest-qualified pull did not bind its export tag: ${tag_ref}"
  # Existence alone would be vacuous: a stale cached tag would satisfy it. The
  # tag must resolve to the same immutable digest asserted above.
  jq -e --arg digest "${digest}" '
    length == 1 and
    any(.[0].RepoDigests[]?; endswith("@" + $digest))
  ' "${output%.json}-tag.json" >/dev/null ||
    sit_fail "the export tag does not resolve to the pinned digest: ${tag_ref}"
}

kargo_runtime_canonical_image_tag() {
  local ref="$1"
  ref="${ref#docker.io/library/}"
  ref="${ref#docker.io/}"
  ref="${ref#library/}"
  printf '%s' "${ref}"
}

kargo_runtime_ctr_saved_display_tag() {
  local ref
  ref="$(kargo_runtime_canonical_image_tag "$1")"
  # containerd's transfer progress renderer turns hyphens in an imported image
  # name into spaces (for example, `argo-rollouts` is displayed as
  # `argo rollouts`). Spaces are not legal in an OCI image reference, so this
  # is an injective comparison against ctr's evidence surface, not acceptance
  # of an alternate image name.
  printf '%s' "${ref//-/ }"
}

kargo_runtime_import_node_image() {
  local tag_ref="$1"
  local digest="$2"
  # Streaming the save directly into the platform containerd keeps the
  # digest-qualified proof independent of wrapper-specific import behavior. The
  # save stays UNFILTERED so the archive root remains the original pinned index
  # digest - that is what keeps the node record's target digest equal to the
  # immutable pin, so the tag+digest assertion below is unchanged. The platform
  # scope belongs on the IMPORT side, where it confines containerd's traversal
  # and unpack to the one child this host actually holds. Under the global
  # pipefail either half failing fails the leg immediately.
  {
    printf '== import %s (%s)\n' "${tag_ref}" "${digest}"
    docker image save "${tag_ref}" |
      namespace_ctr images import --platform linux/amd64 -
  } >>"${report}/kargo-runtime-image-imports.txt" 2>&1 ||
    sit_fail "streaming the pinned image into platform containerd failed: ${tag_ref}"
}

kargo_runtime_assert_import_transcript() {
  local transcript="$1"
  shift
  [ -s "${transcript}" ] ||
    sit_fail "the node image import transcript is missing or empty: ${transcript}"
  # The transcript is now ours, so it is gated on BOTH sides. First: no
  # error-shaped line may appear at all. A historical wrapper-import failure
  # such a line - `ctr: content digest sha256:...: not found` - inside an
  # exit-0 run, and that shape can never be accepted again.
  if grep -nEi 'ctr:|ERRO|error|failed|not found' "${transcript}" >&2; then
    sit_fail "the node image import transcript carries an error marker: ${transcript}"
  fi
  # Second: absence of errors is not presence of imports. Each image must carry
  # a positive ctr marker binding its canonical tag to the PINNED digest, so an
  # empty, truncated, or silently short transcript is red too. Containerd 1.7
  # prints a one-line `unpacking TAG (DIGEST)...done` marker. The current Wolfi
  # ctr prints an adjacent `DISPLAYED-TAG saved` line followed by
  # `MEDIA-TYPE DIGEST`; its transfer renderer displays hyphens as spaces.
  # Accept both exact shapes, but never infer a binding across intervening
  # output or from the harness's own `== import` marker.
  local expected_tag expected_saved_tag digest ref actual_digest pair bound
  # No process substitution on an instance-executed path. Extract once, with the
  # producer status-checked, so a failed sed cannot read as "no unpack markers"
  # and be blamed on the transcript.
  local import_pairs="${transcript}.import-pairs.$$"
  sed -n 's/^unpacking \(.*\) (\(sha256:[0-9a-f]\{64\}\))\.*done.*$/\1 \2/p' \
    "${transcript}" >"${import_pairs}" ||
    sit_fail "could not extract unpack markers from the import transcript: ${transcript}"
  awk -v fleet_import_pairs=1 '
    BEGIN { if (fleet_import_pairs != 1) exit 2 }
    /[[:space:]]saved[[:space:]]*$/ {
      saved = $0
      sub(/[[:space:]]+saved[[:space:]]*$/, "", saved)
      next
    }
    saved != "" {
      if (NF == 2 && $1 ~ /^application\// && $2 ~ /^sha256:[0-9a-f]+$/) {
        print saved, $2
      }
      saved = ""
    }
  ' "${transcript}" >>"${import_pairs}" ||
    sit_fail "could not extract saved markers from the import transcript: ${transcript}"
  while [ "$#" -ge 2 ]; do
    expected_tag="$(kargo_runtime_canonical_image_tag "$1")"
    expected_saved_tag="$(kargo_runtime_ctr_saved_display_tag "$1")"
    digest="$2"
    shift 2
    bound=0
    while IFS= read -r pair; do
      actual_digest="${pair##* }"
      ref="${pair% "${actual_digest}"}"
      ref="${ref% }"
      [ -n "${actual_digest}" ] || continue
      if { [ "$(kargo_runtime_canonical_image_tag "${ref}")" = "${expected_tag}" ] ||
        [ "${ref}" = "${expected_saved_tag}" ]; } &&
        [ "${actual_digest}" = "${digest}" ]; then
        bound=1
        break
      fi
    done <"${import_pairs}"
    [ "${bound}" -eq 1 ] ||
      sit_fail "the node import transcript does not bind ${expected_tag} to pinned digest ${digest}"
  done
  rm -f "${import_pairs}"
  [ "$#" -eq 0 ] ||
    sit_fail 'kargo_runtime_assert_import_transcript takes <tag> <digest> pairs'
}

kargo_runtime_verify_node_image() {
  local inventory="$1"
  local tag_ref="$2"
  local digest="$3"
  local expected_tag ref media_type actual_digest _remainder bound
  expected_tag="$(kargo_runtime_canonical_image_tag "${tag_ref}")"
  # No process substitution on an instance-executed path, and a failed sed must
  # refuse rather than present as an inventory with no matching entry. The loop
  # keeps its unquoted word splitting, which a pipeline would break by running it
  # in a subshell. The listing is keyed off the input rather than ${work}: this
  # function is also driven standalone by extracted-bytes regressions where that
  # global is not in scope, and depending on it would trade a portability defect
  # for an unbound variable. Because the listing no longer lives in the
  # cleanup-managed scratch root, the match sets a flag and breaks instead of
  # returning from inside the loop, so removal is unconditional on every path.
  local rows="${inventory}.rows.$$"
  sed '1d' "${inventory}" >"${rows}" ||
    sit_fail "could not read the platform containerd image inventory: ${inventory}"
  bound=0
  while read -r ref media_type actual_digest _remainder; do
    [ -n "${media_type}" ] || continue
    if [ "$(kargo_runtime_canonical_image_tag "${ref}")" = "${expected_tag}" ] &&
      [ "${actual_digest}" = "${digest}" ]; then
      bound=1
      break
    fi
  done <"${rows}"
  rm -f "${rows}"
  [ "${bound}" -eq 1 ] ||
    sit_fail "platform containerd does not bind ${tag_ref} to pinned digest ${digest}"
}

# The name a `repo:tag@digest` reference actually resolves to inside the CRI.
# kubelet passes the pod reference verbatim to CRI ImageStatus; containerd 1.7
# normalizes it through distribution/reference.ParseDockerRef, which DROPS the
# tag whenever a digest is present, and resolves the remainder by EXACT match
# against stored containerd image names. So the lookup key is `repo@digest` -
# never the combined string, and never the tag.
kargo_runtime_alias_image_ref() {
  local tag_ref="$1"
  local digest="$2"
  case "${tag_ref##*/}" in
  *:*) ;;
  *)
    sit_fail "cannot derive a digest alias from an untagged reference: ${tag_ref}"
    return 1
    ;;
  esac
  [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || {
    sit_fail "cannot derive a digest alias from a non-immutable digest: ${digest}"
    return 1
  }
  printf '%s@%s' "${tag_ref%:*}" "${digest}"
}

kargo_runtime_image_slug() {
  local name="${1##*/}"
  printf '%s' "${name%%:*}"
}

# Bind the digest-shaped NAME the CRI lookup above needs. The import creates
# only the tag record, and CRI derives `repoDigests` from digest-shaped stored
# NAMES - never from a record's target descriptor - so a pinned `Never` workload
# whose reference carries a digest could not resolve at all (run
# 20260729T135154Z-ade9451: ErrImageNeverPull on content that was present and
# correct). This adds a second name to the already-verified content; it neither
# pulls nor relaxes the pin.
#
# No `--force`. At the pin its semantics are delete-then-recreate the existing
# target record, and this cluster is created fresh per run, so an already
# present name is an anomaly that must fail loudly rather than be replaced.
# `ctr images tag` output is never parsed - it only echoes the new name - so the
# proof rests on the exit status plus the state re-read below.
kargo_runtime_alias_node_image() {
  local tag_ref="$1"
  local digest="$2"
  local alias_ref
  alias_ref="$(kargo_runtime_alias_image_ref "${tag_ref}" "${digest}")"
  {
    printf '== alias %s -> %s\n' "${tag_ref}" "${alias_ref}"
    namespace_ctr images tag "${tag_ref}" "${alias_ref}"
  } >>"${report}/kargo-runtime-image-aliases.txt" 2>&1 ||
    sit_fail "could not bind the pinned digest alias in platform containerd: ${alias_ref}"
}

# The CRI must hold the canonical tag and the canonical `repo@pin` name on ONE
# entry. A tag-only predicate is exactly the false green the failed run passed;
# and asserting the two names independently would accept split brain - a stale
# tag adopted as one CRI image and a fresh alias as another - which is the shape
# a wrong tag plus a correct alias produces.
kargo_runtime_verify_cri_image() {
  local inventory="$1"
  local tag_ref="$2"
  local alias_ref="$3"
  # COUNTED, not merely existential. `any(...)` would accept a second entry that
  # also carries the tag, or a repeated element inside one array, and either
  # shape means the CRI store is not the unambiguous one a pinned `Never` lookup
  # depends on. The rule is therefore: the canonical tag occurs EXACTLY ONCE
  # across the whole inventory, the canonical repo@pin alias occurs EXACTLY
  # ONCE, and both of those single occurrences are on the SAME entry.
  jq -e --arg tag "${tag_ref}" --arg alias "${alias_ref}" '
    def canonical:
      sub("^docker.io/library/"; "") |
      sub("^docker.io/"; "") |
      sub("^library/"; "");
    [ .images[]? |
      {
        tags: ([ .repoTags[]? | select(canonical == ($tag | canonical)) ] | length),
        digests: ([ .repoDigests[]? | select(canonical == ($alias | canonical)) ] | length)
      }
    ] as $rows |
    (([ $rows[].tags ] | add) // 0) == 1 and
    (([ $rows[].digests ] | add) // 0) == 1 and
    ([ $rows[] | select(.tags == 1 and .digests == 1) ] | length) == 1
  ' "${inventory}" >/dev/null ||
    sit_fail "the built-in k3s CRI does not carry ${tag_ref} and ${alias_ref} exactly once each on one and the same image entry"
}

kargo_runtime_probe_cri_reference() {
  local combined_ref="$1"
  local tag_ref="$2"
  local alias_ref="$3"
  local output="$4"
  local stderr_log="$5"
  # `crictl inspecti` reports not-found with a non-zero exit and version-varying
  # text, so the gate is the exit status plus `jq -e` predicates - never the
  # message bytes. Its stderr goes to a caller-owned TRANSIENT file outside the
  # report: a per-probe log inside ${report} would be an undeclared retained
  # artifact, and one that is empty whenever the first probe succeeds.
  namespace_crictl inspecti -o json "${combined_ref}" \
    >"${output}" 2>>"${stderr_log}" || return 1
  # Counted for the same reason the inventory join is: the status the pinned
  # workload will be served must name its tag once and its pinned repoDigest
  # once, not "at least once among repeats".
  jq -e --arg tag "${tag_ref}" --arg alias "${alias_ref}" '
    def canonical:
      sub("^docker.io/library/"; "") |
      sub("^docker.io/"; "") |
      sub("^library/"; "");
    ([ (.status.repoTags // [])[] | select(canonical == ($tag | canonical)) ] | length) == 1 and
    ([ (.status.repoDigests // [])[] | select(canonical == ($alias | canonical)) ] | length) == 1
  ' "${output}" >/dev/null || return 1
}

# Ask the CRI for the EXACT reference the pinned workloads carry. This runs the
# same normalize-then-resolve path kubelet triggers, so success here is the
# direct functional proof that an `imagePullPolicy: Never` pod will find its
# image. CRI's in-memory store is updated by an asynchronous event monitor, so
# the probe retries - bounded by a fixed attempt ceiling and fail-closed, never
# open-ended.
kargo_runtime_assert_cri_reference() {
  local combined_ref="$1"
  local output="$2"
  local tag_ref="${combined_ref%@*}"
  local digest="${combined_ref##*@}"
  local alias_ref
  alias_ref="$(kargo_runtime_alias_image_ref "${tag_ref}" "${digest}")"
  # Probe stderr is TRANSIENT and lives in the SIT scratch root, never in the
  # report: on a clean first attempt it would otherwise retain an empty file
  # nothing declares, and on a retry its bytes are diagnostics, not evidence.
  # They are printed on the fail-closed path and the file is then removed, so no
  # assertion can come to depend on them.
  local stderr_log
  stderr_log="$(mktemp "${sit_tmp_root%/}/fleet-sit-cri.XXXXXX")"
  local attempt=1
  while ! kargo_runtime_probe_cri_reference \
    "${combined_ref}" "${tag_ref}" "${alias_ref}" "${output}" "${stderr_log}"; do
    if [ "${attempt}" -ge 30 ]; then
      cat "${stderr_log}" >&2 || true
      rm -f "${stderr_log}"
      sit_fail "the built-in k3s CRI did not resolve the exact pinned workload reference to its tag and pinned repoDigest after ${attempt} attempts: ${combined_ref}"
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  rm -f "${stderr_log}"
}

# The whole node-image leg, orchestration included, so the offline regression
# runs THESE bytes rather than a transcription of them: import each pinned
# image, accept the transcript at its own step, bind the digest alias, then
# re-read node and CRI state and assert every layer separately.
#   ctr row (tag)   - kills a tag pointing at other content
#   ctr row (alias) - kills a wrong digest alias; `ctr images tag` accepts any
#                     name string and never checks that a digest-shaped name
#                     matches the target, so this is the only place that lands
#   CRI join        - kills adoption failure and split brain
#   CRI resolution  - kills a regression of the actual pod lookup
kargo_runtime_bind_node_images() {
  local transcript="${report}/kargo-runtime-image-imports.txt"
  local inventory="${report}/kargo-runtime-node-ctr-images.txt"
  local cri_images="${report}/kargo-runtime-node-images.json"
  local pairs=("$@")
  { [ "${#pairs[@]}" -ge 2 ] && [ $((${#pairs[@]} % 2)) -eq 0 ]; } ||
    sit_fail 'kargo_runtime_bind_node_images takes <tag> <digest> pairs'
  : >"${transcript}"
  : >"${report}/kargo-runtime-image-aliases.txt"
  local i tag_ref digest alias_ref evidence
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    kargo_runtime_import_node_image "${pairs[i]}" "${pairs[i + 1]}"
  done
  # Accept the transcript BEFORE anything reads node state, so a hidden
  # import-side error is reported at its own step rather than surfacing later as
  # an ambiguous absence.
  kargo_runtime_assert_import_transcript "${transcript}" "${pairs[@]}"
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    kargo_runtime_alias_node_image "${pairs[i]}" "${pairs[i + 1]}"
  done
  # containerd's own store is updated synchronously by `ctr images tag`, so the
  # ctr inventory is race-free the moment the aliases exist.
  namespace_ctr images list >"${inventory}"
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    tag_ref="${pairs[i]}"
    digest="${pairs[i + 1]}"
    alias_ref="$(kargo_runtime_alias_image_ref "${tag_ref}" "${digest}")"
    evidence="${report}/kargo-runtime-cri-$(kargo_runtime_image_slug "${tag_ref}").json"
    kargo_runtime_verify_node_image "${inventory}" "${tag_ref}" "${digest}"
    kargo_runtime_verify_node_image "${inventory}" "${alias_ref}" "${digest}"
    kargo_runtime_assert_cri_reference "${tag_ref}@${digest}" "${evidence}"
  done
  # The CRI store, by contrast, is populated by an asynchronous event monitor.
  # Capturing and joining its inventory only AFTER every exact-reference
  # resolution has succeeded removes that race in the only correct direction:
  # the retained listing is then the verified final state, not a snapshot taken
  # while adoption was still in flight. The join adds what a per-reference
  # resolution cannot see - that the tag and the pinned repoDigest live on
  # EXACTLY ONE entry, killing the split brain a stale tag plus a fresh alias
  # would otherwise present.
  namespace_crictl images -o json >"${cri_images}"
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    tag_ref="${pairs[i]}"
    digest="${pairs[i + 1]}"
    alias_ref="$(kargo_runtime_alias_image_ref "${tag_ref}" "${digest}")"
    kargo_runtime_verify_cri_image "${cri_images}" "${tag_ref}" "${alias_ref}"
  done
}

kargo_runtime_prepare_artifacts() {
  KARGO_RUNTIME_DIR="${work}/kargo-runtime"
  mkdir -p "${KARGO_RUNTIME_DIR}/chart" "${KARGO_RUNTIME_DIR}/images"
  : >"${report}/kargo-runtime-image-pulls.txt"

  local chart_log="${report}/kargo-runtime-chart-pull.txt"
  helm pull "${KARGO_CHART_REF}" \
    --version "${KARGO_CHART_VERSION}" \
    --destination "${KARGO_RUNTIME_DIR}" >"${chart_log}" 2>&1
  rg -F "Digest: ${KARGO_CHART_DIGEST}" "${chart_log}" >/dev/null ||
    sit_fail 'Helm did not report the pinned Kargo OCI chart digest'
  local chart_archive="${KARGO_RUNTIME_DIR}/kargo-${KARGO_CHART_VERSION}.tgz"
  [ -s "${chart_archive}" ] || sit_fail 'the pinned Kargo chart archive was not downloaded'
  printf '%s  %s\n' "${KARGO_CHART_ARCHIVE_SHA256}" "${chart_archive}" \
    >"${KARGO_RUNTIME_DIR}/kargo-chart.sha256"
  sha256sum --check "${KARGO_RUNTIME_DIR}/kargo-chart.sha256" \
    >"${report}/kargo-runtime-chart-sha256.txt"
  tar -xzf "${chart_archive}" -C "${KARGO_RUNTIME_DIR}/chart"
  helm show chart "${chart_archive}" >"${report}/kargo-runtime-chart-metadata.yaml"
  CHART_VERSION="${KARGO_CHART_VERSION}" yq -e \
    '.version == strenv(CHART_VERSION) and .appVersion == "v1.9.10"' \
    "${report}/kargo-runtime-chart-metadata.yaml" >/dev/null

  curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
    "${ROLLOUTS_MANIFEST_URL}" --output "${KARGO_RUNTIME_DIR}/argo-rollouts-install.source.yaml"
  printf '%s  %s\n' "${ROLLOUTS_MANIFEST_SHA256}" \
    "${KARGO_RUNTIME_DIR}/argo-rollouts-install.source.yaml" \
    >"${KARGO_RUNTIME_DIR}/argo-rollouts.sha256"
  sha256sum --check "${KARGO_RUNTIME_DIR}/argo-rollouts.sha256" \
    >"${report}/kargo-runtime-rollouts-sha256.txt"

  local kargo_digest_ref="${KARGO_IMAGE_REPOSITORY}@${KARGO_IMAGE_DIGEST}"
  local rollouts_digest_ref="${ROLLOUTS_IMAGE_REPOSITORY}@${ROLLOUTS_IMAGE_DIGEST}"
  local analysis_digest_ref="${ANALYSIS_IMAGE_REPOSITORY}@${ANALYSIS_IMAGE_DIGEST}"
  kargo_runtime_verify_host_image "${KARGO_RUNTIME_IMAGE_REF}" "${kargo_digest_ref}" \
    "${KARGO_RUNTIME_DIR}/images/kargo.json"
  kargo_runtime_verify_host_image "${ROLLOUTS_RUNTIME_IMAGE_REF}" "${rollouts_digest_ref}" \
    "${KARGO_RUNTIME_DIR}/images/rollouts.json"
  kargo_runtime_verify_host_image "${ANALYSIS_RUNTIME_IMAGE_REF}" "${analysis_digest_ref}" \
    "${KARGO_RUNTIME_DIR}/images/analysis.json"
  # The retained artifact carries BOTH halves of the host-side proof: the three
  # digest-qualified inspections first, then the three export-tag inspections
  # that must resolve to the same pinned digests. Existing consumers only
  # require this file to be present and non-empty, so the addition weakens
  # nothing while making the tag<->digest binding visible in the evidence.
  jq -s 'add' "${KARGO_RUNTIME_DIR}/images/kargo.json" \
    "${KARGO_RUNTIME_DIR}/images/rollouts.json" \
    "${KARGO_RUNTIME_DIR}/images/analysis.json" \
    "${KARGO_RUNTIME_DIR}/images/kargo-tag.json" \
    "${KARGO_RUNTIME_DIR}/images/rollouts-tag.json" \
    "${KARGO_RUNTIME_DIR}/images/analysis-tag.json" \
    >"${report}/kargo-runtime-host-images.json"

  # The export input is the tag established by the verified digest pull: the
  # daemon exports by name, and the imported content is checked against the
  # digest again inside the platform containerd and built-in k3s CRI.
  kargo_runtime_bind_node_images \
    "${KARGO_RUNTIME_IMAGE_REF%@*}" "${KARGO_IMAGE_DIGEST}" \
    "${ROLLOUTS_RUNTIME_IMAGE_REF%@*}" "${ROLLOUTS_IMAGE_DIGEST}" \
    "${ANALYSIS_RUNTIME_IMAGE_REF%@*}" "${ANALYSIS_IMAGE_DIGEST}"
}

kargo_runtime_install_rollouts() {
  ROLLOUTS_RUNTIME_IMAGE_REF="${ROLLOUTS_RUNTIME_IMAGE_REF}" yq '
    (select(.kind == "Deployment" and .metadata.name == "argo-rollouts") |
      .spec.template.spec.containers[] | select(.name == "argo-rollouts") | .image) =
      strenv(ROLLOUTS_RUNTIME_IMAGE_REF) |
    (select(.kind == "Deployment" and .metadata.name == "argo-rollouts") |
      .spec.template.spec.containers[] | select(.name == "argo-rollouts") | .imagePullPolicy) = "Never"
  ' "${KARGO_RUNTIME_DIR}/argo-rollouts-install.source.yaml" \
    >"${report}/kargo-runtime-rollouts-install.yaml"
  yq ea -o=json '[.]' "${report}/kargo-runtime-rollouts-install.yaml" \
    >"${KARGO_RUNTIME_DIR}/argo-rollouts-install.json"
  jq -e --arg image "${ROLLOUTS_RUNTIME_IMAGE_REF}" '
    [ .[] | select(.kind == "Deployment" and .metadata.name == "argo-rollouts") ] as $deployments |
    ($deployments | length) == 1 and
    ($deployments[0].spec.template.spec.containers | length) == 1 and
    $deployments[0].spec.template.spec.containers[0].image == $image and
    $deployments[0].spec.template.spec.containers[0].imagePullPolicy == "Never"
  ' "${KARGO_RUNTIME_DIR}/argo-rollouts-install.json" >/dev/null

  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply --server-side --force-conflicts --field-manager=fleet-sit \
    -n argo-rollouts -f "${report}/kargo-runtime-rollouts-install.yaml"
  kubectl wait --for=condition=Established crd/analysisruns.argoproj.io --timeout=180s
  kubectl wait --for=condition=Established crd/analysistemplates.argoproj.io --timeout=180s
  kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=300s
  kubectl -n argo-rollouts get deployment argo-rollouts -o json \
    >"${report}/kargo-runtime-rollouts-deployment.json"
  jq -e --arg image "${ROLLOUTS_RUNTIME_IMAGE_REF}" '
    .spec.template.spec.containers[0].image == $image and
    .spec.template.spec.containers[0].imagePullPolicy == "Never" and
    .status.availableReplicas == 1
  ' "${report}/kargo-runtime-rollouts-deployment.json" >/dev/null
}

kargo_runtime_install_kargo() {
  local cert_dir="${KARGO_RUNTIME_DIR}/cert"
  mkdir -p "${cert_dir}"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=fleet-sit-kargo-ca' \
    -keyout "${cert_dir}/ca.key" -out "${cert_dir}/ca.crt" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -subj '/CN=kargo-webhooks-server.kargo.svc' \
    -addext 'subjectAltName=DNS:kargo-webhooks-server.kargo.svc,DNS:kargo-webhooks-server.kargo.svc.cluster.local' \
    -keyout "${cert_dir}/tls.key" -out "${cert_dir}/tls.csr" >/dev/null 2>&1
  printf '%s\n' \
    'basicConstraints=CA:FALSE' \
    'keyUsage=digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth' \
    'subjectAltName=DNS:kargo-webhooks-server.kargo.svc,DNS:kargo-webhooks-server.kargo.svc.cluster.local' \
    >"${cert_dir}/server.ext"
  openssl x509 -req -sha256 -days 1 \
    -in "${cert_dir}/tls.csr" \
    -CA "${cert_dir}/ca.crt" -CAkey "${cert_dir}/ca.key" -CAcreateserial \
    -extfile "${cert_dir}/server.ext" -out "${cert_dir}/tls.crt" >/dev/null 2>&1
  openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" \
    >"${report}/kargo-runtime-webhook-cert-verify.txt"

  kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kargo create secret tls kargo-webhooks-server-cert \
    --cert "${cert_dir}/tls.crt" --key "${cert_dir}/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply --server-side --force-conflicts --field-manager=fleet-sit \
    -f "${KARGO_RUNTIME_DIR}/chart/kargo/resources/crds"
  local crd
  for crd in \
    clusterconfigs clusterpromotiontasks freights projectconfigs projects \
    promotions promotiontasks stages warehouses; do
    kubectl wait --for=condition=Established "crd/${crd}.kargo.akuity.io" --timeout=180s
  done

  local chart_archive="${KARGO_RUNTIME_DIR}/kargo-${KARGO_CHART_VERSION}.tgz"
  helm upgrade --install kargo "${chart_archive}" \
    --namespace kargo \
    --set crds.install=false \
    --set api.enabled=false \
    --set externalWebhooksServer.enabled=false \
    --set garbageCollector.enabled=false \
    --set controller.enabled=true \
    --set controller.argocd.integrationEnabled=false \
    --set controller.rollouts.integrationEnabled=true \
    --set managementController.enabled=true \
    --set webhooksServer.enabled=true \
    --set webhooksServer.tls.selfSignedCert=false \
    --set-string webhooksServer.tls.secretName=kargo-webhooks-server-cert \
    --set-file webhooksServer.tls.caBundle="${cert_dir}/ca.crt" \
    --set-string image.repository="${KARGO_IMAGE_REPOSITORY}" \
    --set-string image.tag="${KARGO_IMAGE_TAG}@${KARGO_IMAGE_DIGEST}" \
    --set image.pullPolicy=Never \
    --wait --timeout 5m >"${report}/kargo-runtime-helm-install.txt"
  helm get manifest kargo -n kargo >"${report}/kargo-runtime-kargo-manifest.yaml"
  helm get values kargo -n kargo -o json >"${report}/kargo-runtime-kargo-values.json"
  kubectl -n kargo get deployments -o json >"${report}/kargo-runtime-kargo-deployments.json"
  jq -e --arg image "${KARGO_RUNTIME_IMAGE_REF}" '
    [.items[].metadata.name] | sort == [
      "kargo-controller", "kargo-management-controller", "kargo-webhooks-server"
    ]
  ' "${report}/kargo-runtime-kargo-deployments.json" >/dev/null
  jq -e --arg image "${KARGO_RUNTIME_IMAGE_REF}" '
    all(.items[];
      (.spec.template.spec.containers | length) == 1 and
      .spec.template.spec.containers[0].image == $image and
      .spec.template.spec.containers[0].imagePullPolicy == "Never"
    )
  ' "${report}/kargo-runtime-kargo-deployments.json" >/dev/null
  local deployment
  for deployment in kargo-controller kargo-management-controller kargo-webhooks-server; do
    kubectl -n kargo rollout status "deployment/${deployment}" --timeout=300s
  done
  kubectl get mutatingwebhookconfiguration/kargo validatingwebhookconfiguration/kargo -o json \
    >"${report}/kargo-runtime-webhooks.json"
  jq -e '
    .items | length == 2 and
    all(.[]; all(.webhooks[]; (.clientConfig.caBundle | length) > 0))
  ' "${report}/kargo-runtime-webhooks.json" >/dev/null
}

kargo_canonicalize_objects() {
  local source="$1"
  local output="$2"
  yq ea -o=json '[.] | map(select(type == "!!map"))' "${source}" |
    jq 'sort_by([.kind, (.metadata.namespace // ""), .metadata.name])' >"${output}"
}

kargo_render_analysis_fixture() {
  local namespace="$1"
  local output="$2"
  NAMESPACE="${namespace}" ANALYSIS_IMAGE="${ANALYSIS_RUNTIME_IMAGE_REF}" yq '
    (select(.metadata.namespace == "<namespace>") | .metadata.namespace) = strenv(NAMESPACE) |
    (.. | select(tag == "!!str" and . == "<analysis-image>")) = strenv(ANALYSIS_IMAGE)
  ' "${validation_dir}/fixtures/kargo-runtime/analysis.yaml" >"${output}"
}

kargo_runtime_render_and_apply_primary() {
  git -C "${FLEET_BARE}" config http.receivepack true
  [ "$(git -C "${FLEET_BARE}" config --bool http.receivepack)" = 'true' ] ||
    sit_fail 'HTTP receive-pack was not enabled on the throwaway fleet bare repository'
  jq -n --arg repository "${FLEET_BARE}" \
    '{repository:$repository,httpReceivePack:true,scope:"throwaway bare repository only"}' \
    >"${report}/kargo-runtime-git-receive-pack.json"

  local chart="${FLEET_SOURCE}/registry/charts/diene-platform"
  helm template canary "${chart}" \
    --namespace canary \
    --values "${FLEET_SOURCE}/platforms/canary/services.yaml" \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml |
    yq 'select(.apiVersion == "kargo.akuity.io/v1alpha1")' \
      >"${KARGO_RUNTIME_DIR}/kargo-runtime-reversed.yaml"
  kargo_canonicalize_objects "${report}/kargo-rendered.yaml" \
    "${KARGO_RUNTIME_DIR}/kargo-static-canonical.json"
  kargo_canonicalize_objects "${KARGO_RUNTIME_DIR}/kargo-runtime-reversed.yaml" \
    "${KARGO_RUNTIME_DIR}/kargo-reversed-canonical.json"
  cmp -s "${KARGO_RUNTIME_DIR}/kargo-static-canonical.json" \
    "${KARGO_RUNTIME_DIR}/kargo-reversed-canonical.json" || {
    diff -u "${KARGO_RUNTIME_DIR}/kargo-static-canonical.json" \
      "${KARGO_RUNTIME_DIR}/kargo-reversed-canonical.json" >&2 || true
    sit_fail 'the runtime chart mirror does not reverse to the committed static Kargo render'
  }

  helm template canary "${chart}" \
    --namespace canary \
    --values "${FLEET_SOURCE}/platforms/canary/services.yaml" \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml \
    --set-string "fleet.repoURL=${FLEET_REPO_URL}" \
    --set-string 'oci.registry=registry.sit.invalid' |
    yq 'select(.apiVersion == "kargo.akuity.io/v1alpha1")' \
      >"${report}/kargo-runtime-rendered.yaml"
  kargo_canonicalize_objects "${report}/kargo-runtime-rendered.yaml" \
    "${KARGO_RUNTIME_DIR}/kargo-runtime-canonical.json"
  jq \
    --arg runtimeFleet "${FLEET_REPO_URL}" \
    --arg productionFleet 'https://github.com/AtomiCloud/fleet' \
    --arg runtimeRegistry 'registry.sit.invalid' \
    --arg productionRegistry 'registry.atomi.cloud' '
      def literal_replace($from; $to): split($from) | join($to);
      walk(
        if type == "string" then
          literal_replace($runtimeFleet; $productionFleet) |
          literal_replace($runtimeRegistry; $productionRegistry)
        else . end
      ) |
      sort_by([.kind, (.metadata.namespace // ""), .metadata.name])
    ' "${KARGO_RUNTIME_DIR}/kargo-runtime-canonical.json" \
    >"${KARGO_RUNTIME_DIR}/kargo-runtime-normalized.json"
  cmp -s "${KARGO_RUNTIME_DIR}/kargo-static-canonical.json" \
    "${KARGO_RUNTIME_DIR}/kargo-runtime-normalized.json" || {
    diff -u "${KARGO_RUNTIME_DIR}/kargo-static-canonical.json" \
      "${KARGO_RUNTIME_DIR}/kargo-runtime-normalized.json" >&2 || true
    sit_fail 'runtime Kargo render differs by more than the two consumer repository coordinates'
  }
  jq \
    --arg runtimeFleet "${FLEET_REPO_URL}" \
    --arg runtimeRegistry 'registry.sit.invalid' '
      [ .[] as $object |
        ($object | paths(type == "string")) as $path |
        ($object | getpath($path)) as $value |
        select(($value | contains($runtimeFleet)) or ($value | contains($runtimeRegistry))) |
        {
          object: ($object.kind + "/" + $object.metadata.name),
          path: ($path | map(tostring) | join(".")),
          value: $value
        }
      ]
    ' "${KARGO_RUNTIME_DIR}/kargo-runtime-canonical.json" \
    >"${KARGO_RUNTIME_DIR}/kargo-runtime-coordinate-paths.json"
  jq -n \
    --arg productionFleet 'https://github.com/AtomiCloud/fleet' \
    --arg runtimeFleet "${FLEET_REPO_URL}" \
    --arg productionRegistry 'registry.atomi.cloud' \
    --arg runtimeRegistry 'registry.sit.invalid' \
    --slurpfile paths "${KARGO_RUNTIME_DIR}/kargo-runtime-coordinate-paths.json" '
      {
        status:"pass",
        canonicalReverseEqual:true,
        onlyConsumerCoordinatesChanged:true,
        coordinates:{
          fleet:{production:$productionFleet,runtime:$runtimeFleet},
          ociRegistry:{production:$productionRegistry,runtime:$runtimeRegistry}
        },
        changedStringPaths:$paths[0]
      }
    ' >"${report}/kargo-runtime-delta-oracle.json"
  jq -e '.onlyConsumerCoordinatesChanged == true and (.changedStringPaths | length) > 0' \
    "${report}/kargo-runtime-delta-oracle.json" >/dev/null

  yq ea -o=json '[.]' "${report}/kargo-runtime-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/kargo-runtime-rendered.json"
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${KARGO_RUNTIME_DIR}/kargo-runtime-rendered.json" \
    --crds "${work}/kargo-crds.json" \
    --out "${report}/kargo-runtime-rendered-contract.json" \
    --source 'runtime render with exactly two consumer repository-coordinate overrides' \
    --image-repo "${KARGO_RUNTIME_IMAGE_REPO}" \
    --chart-repo "${KARGO_RUNTIME_CHART_REPO}" \
    --fleet-repo "${FLEET_REPO_URL}"

  yq 'select(.kind == "Project")' "${report}/kargo-runtime-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/canary-project.yaml"
  yq 'select(.kind != "Project")' "${report}/kargo-runtime-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/canary-namespaced.yaml"
  kubectl apply -f "${KARGO_RUNTIME_DIR}/canary-project.yaml"
  kubectl wait --for=condition=Ready project.kargo.akuity.io/canary --timeout=180s
  kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/canary --timeout=180s
  kargo_render_analysis_fixture canary "${report}/kargo-runtime-analysis-canary.yaml"
  kubectl apply -f "${report}/kargo-runtime-analysis-canary.yaml"
  kubectl apply -f "${KARGO_RUNTIME_DIR}/canary-namespaced.yaml"

  kubectl get projects.kargo.akuity.io canary -o json >"${KARGO_RUNTIME_DIR}/runtime-project.json"
  kubectl -n canary get projectconfigs.kargo.akuity.io,warehouses.kargo.akuity.io,stages.kargo.akuity.io \
    -o json >"${KARGO_RUNTIME_DIR}/runtime-namespaced.json"
  jq -n \
    --slurpfile project "${KARGO_RUNTIME_DIR}/runtime-project.json" \
    --slurpfile namespaced "${KARGO_RUNTIME_DIR}/runtime-namespaced.json" \
    '[$project[0]] + $namespaced[0].items' >"${report}/kargo-runtime-persisted.json"
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${report}/kargo-runtime-persisted.json" \
    --crds "${work}/kargo-crds.json" \
    --out "${report}/kargo-runtime-persisted-contract.json" \
    --source 'objects admitted through the live pinned Kargo webhooks and read back' \
    --image-repo "${KARGO_RUNTIME_IMAGE_REPO}" \
    --chart-repo "${KARGO_RUNTIME_CHART_REPO}" \
    --fleet-repo "${FLEET_REPO_URL}" \
    --kargo-webhook-persisted
  jq -e '
    .ok == true and
    .expectedRepositories == {
      image:"registry.sit.invalid/canary/dummy",
      chart:"oci://registry.sit.invalid/canary-dummy",
      fleet:.expectedRepositories.fleet
    } and
    (.preserveUnknownFieldsBlindSpots | length) > 0
  ' "${report}/kargo-runtime-persisted-contract.json" >/dev/null

  KARGO_RUNTIME_GIT_BASELINE="$(git -C "${FLEET_BARE}" rev-parse refs/heads/main)"
  git -C "${FLEET_BARE}" show \
    "${KARGO_RUNTIME_GIT_BASELINE}:platforms/canary/landscapes/raichu/dummy.yaml" |
    sed -n '/^values:/,$p' >"${report}/kargo-runtime-raichu-values-before.yaml"
}

kargo_stage_name() {
  printf '%s-dummy-%s' "$1" "$2"
}

kargo_check_refresh_handled() {
  local project="$1"
  local stage="$2"
  local token="$3"
  [ "$(kubectl -n "${project}" get stage "${stage}" -o jsonpath='{.status.lastHandledRefresh}' 2>/dev/null)" = "${token}" ]
}

# Driver decisions use Bash's monotonic SECONDS clock. Keeping the read behind
# one function lets the daemon-free production-byte gate replace the clock
# deterministically without making the public 180-second budget configurable.
kargo_monotonic_now() {
  printf '%s\n' "${SECONDS}"
}

# Return a kubectl request timeout capped by both ten seconds and the remaining
# absolute driver budget. A caller at (or beyond) the deadline must not start a
# new API request.
kargo_driver_request_timeout() {
  local deadline="$1"
  local output_name="$2"
  local now remaining
  local -n output_ref="${output_name}"
  now="$(kargo_monotonic_now)"
  remaining=$((deadline - now))
  [ "${remaining}" -gt 0 ] || return 1
  [ "${remaining}" -le 10 ] || remaining=10
  output_ref="${remaining}s"
}

kargo_check_refresh_handled_bounded() {
  local project="$1"
  local stage="$2"
  local token="$3"
  local deadline="$4"
  local request_timeout
  kargo_driver_request_timeout "${deadline}" request_timeout || return 1
  [ "$(kubectl -n "${project}" get stage "${stage}" \
    -o jsonpath='{.status.lastHandledRefresh}' \
    --request-timeout="${request_timeout}" 2>/dev/null)" = "${token}" ]
}

kargo_refresh_stage() {
  local project="$1"
  local stage="$2"
  local token
  token="fleet-sit-$(sit_epoch)-$$-${RANDOM}"
  kubectl -n "${project}" annotate stage "${stage}" \
    "kargo.akuity.io/refresh=${token}" --overwrite >/dev/null
  sit_wait_for 90 "Kargo Stage ${project}/${stage} to handle refresh ${token}" \
    kargo_check_refresh_handled "${project}" "${stage}" "${token}"
}

# Same refresh-token annotate-and-wait as kargo_refresh_stage, bounded by an
# absolute deadline instead of a fixed 90s. Used only from inside a bounded
# retry driver where an acknowledgement timeout is an expected, retried condition
# rather than a terminal failure: unlike kargo_refresh_stage, it never routes
# through sit_wait_for/sit_fail, so a retry that later succeeds leaves no
# misleading "assertion failed" text behind.
kargo_refresh_stage_quiet() {
  local project="$1"
  local stage="$2"
  local deadline="$3"
  local token_output="$4"
  local refresh_token remaining sleep_s now request_timeout
  local -n token_ref="${token_output}"
  refresh_token="fleet-sit-$(sit_epoch)-$$-${RANDOM}"
  # shellcheck disable=SC2034 # assignment returns through the caller's nameref
  token_ref="${refresh_token}"
  kargo_driver_request_timeout "${deadline}" request_timeout || return 1
  kubectl -n "${project}" annotate stage "${stage}" \
    "kargo.akuity.io/refresh=${refresh_token}" --overwrite \
    --request-timeout="${request_timeout}" >/dev/null
  while ! kargo_check_refresh_handled_bounded \
    "${project}" "${stage}" "${refresh_token}" "${deadline}"; do
    now="$(kargo_monotonic_now)"
    remaining=$((deadline - now))
    [ "${remaining}" -gt 0 ] || return 1
    sleep_s="${FLEET_SIT_POLL_SECONDS:-3}"
    [ "${sleep_s}" -le "${remaining}" ] || sleep_s="${remaining}"
    sleep "${sleep_s}"
  done
}

# Record both sides of the supported Stage refresh contract: the unique
# annotation token written by the driver and the same token acknowledged in
# status.lastHandledRefresh by the released controller.
kargo_refresh_stage_recorded() {
  local project="$1"
  local stage="$2"
  local output="$3"
  local token previous_token annotated_at annotated_epoch
  local acknowledged_at acknowledged_epoch last_handled_refresh
  token="fleet-sit-$(sit_epoch)-$$-${RANDOM}"
  previous_token="$(kubectl -n "${project}" get stage "${stage}" \
    -o jsonpath='{.status.lastHandledRefresh}')"
  annotated_at="$(sit_now)"
  annotated_epoch="$(date -u -d "${annotated_at}" +%s)"
  kubectl -n "${project}" annotate stage "${stage}" \
    "kargo.akuity.io/refresh=${token}" --overwrite >/dev/null
  sit_wait_for 90 "Kargo Stage ${project}/${stage} to handle refresh ${token}" \
    kargo_check_refresh_handled "${project}" "${stage}" "${token}"
  last_handled_refresh="$(kubectl -n "${project}" get stage "${stage}" \
    -o jsonpath='{.status.lastHandledRefresh}')"
  [ "${last_handled_refresh}" = "${token}" ] ||
    sit_fail "Kargo Stage ${project}/${stage} did not persist refresh acknowledgement ${token}"
  acknowledged_at="$(sit_now)"
  acknowledged_epoch="$(date -u -d "${acknowledged_at}" +%s)"
  [ "${acknowledged_epoch}" -ge "${annotated_epoch}" ] ||
    sit_fail "Kargo Stage ${project}/${stage} refresh acknowledgement predates its annotation"
  jq -n \
    --arg project "${project}" \
    --arg stage "${stage}" \
    --arg token "${token}" \
    --arg previousToken "${previous_token}" \
    --arg annotatedAt "${annotated_at}" \
    --argjson annotatedEpoch "${annotated_epoch}" \
    --arg acknowledgedAt "${acknowledged_at}" \
    --argjson acknowledgedEpoch "${acknowledged_epoch}" \
    --arg lastHandledRefresh "${last_handled_refresh}" '
      {
        schemaVersion:1,project:$project,stage:$stage,
        token:$token,previousToken:$previousToken,
        annotatedAt:$annotatedAt,annotatedEpoch:$annotatedEpoch,
        acknowledgedAt:$acknowledgedAt,acknowledgedEpoch:$acknowledgedEpoch,
        lastHandledRefresh:$lastHandledRefresh
      }
    ' >"${output}"
}

kargo_check_promotion_succeeded() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  kubectl -n "${project}" get promotions.kargo.akuity.io -o json 2>/dev/null |
    jq -e --arg stage "${stage}" --arg freight "${freight}" '
      any(.items[]?;
        .spec.stage == $stage and
        .spec.freight == $freight and
        .status.phase == "Succeeded")
    ' >/dev/null
}

kargo_wait_promotion_succeeded() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  if ! sit_wait_for 240 "Promotion of ${freight} to ${project}/${stage} to succeed" \
    kargo_check_promotion_succeeded "${project}" "${stage}" "${freight}"; then
    # The outer lifecycle retains this combined inner log even when the inner
    # report cannot be collected. Print the exact decision surfaces before the
    # instance is destroyed so a timeout is diagnosable rather than merely
    # repeatable.
    {
      echo "== Promotion wait diagnostics: ${project}/${stage} freight ${freight} =="
      kubectl -n "${project}" get stage "${stage}" -o json || true
      kubectl -n "${project}" get freight "${freight}" -o json || true
      kubectl -n "${project}" get promotions.kargo.akuity.io -o json || true
      kubectl -n "${project}" get events --sort-by=.metadata.creationTimestamp || true
      kubectl -n kargo logs deployment/kargo-controller --tail=500 || true
      kubectl -n kargo logs deployment/kargo-management-controller --tail=200 || true
      echo '== end Promotion wait diagnostics =='
    } >&2
    return 1
  fi
  kubectl -n "${project}" get promotions.kargo.akuity.io -o json |
    jq --arg stage "${stage}" --arg freight "${freight}" '
      [.items[] |
        select(.spec.stage == $stage and .spec.freight == $freight)] |
      sort_by(.metadata.creationTimestamp)
    ' >"${output}"
  jq -e 'length >= 1 and .[-1].status.phase == "Succeeded"' "${output}" >/dev/null
}

kargo_check_freight_verified() {
  local project="$1"
  local freight="$2"
  local stage="$3"
  kubectl -n "${project}" get freight "${freight}" -o json 2>/dev/null |
    jq -e --arg stage "${stage}" '.status.verifiedIn[$stage].verifiedAt != null' >/dev/null
}

# Shared jq preamble for every Stage status predicate. It binds $collection to
# the Freight-history collection carrying the EXACT $freight - never
# freightHistory[0], which the controller re-orders as new Freight arrives -
# then $verification (that collection's current verification) and $coherent
# (the post-terminal Stage state the pinned controller must reach before it can
# verify that Freight at all: no current Promotion, a Succeeded last Promotion
# for this Freight, a matching collection, and Healthy health).
#
# The dollar references are jq variables, not shell expansions.
# shellcheck disable=SC2016
KARGO_STAGE_PREDICATE_PREAMBLE='
  ((.status.freightHistory // []) |
    map(select(.items["Warehouse/dummy"].name == $freight)) | first) as $collection |
  ((($collection.verificationHistory // [])[0]) // null) as $verification |
  (
    (.status.currentPromotion // null) == null and
    (.status.lastPromotion.status.phase // "") == "Succeeded" and
    (.status.lastPromotion.freight.name // "") == $freight and
    $collection != null and
    (.status.health.status // "") == "Healthy"
  ) as $coherent |
'

# Exact post-Promotion selector. Unlike the general exact-Freight selector
# above, this binds the Stage to the terminal Promotion object which opened the
# verification edge. Reused Stage names and histories therefore cannot satisfy
# a later wait with an older collection or Promotion.
# shellcheck disable=SC2016
KARGO_POST_PROMOTION_PREDICATE_PREAMBLE='
  ((.status.freightHistory // []) |
    map(select(
      .id == $collection_id and
      .items["Warehouse/dummy"].name == $freight
    ))) as $collections |
  (if ($collections | length) == 1 then $collections[0] else null end) as $collection |
  ((($collection.verificationHistory // [])[0]) // null) as $verification |
  (
    (.status.currentPromotion // null) == null and
    (.status.lastPromotion.name // "") == $promotion and
    (.status.lastPromotion.status.phase // "") == "Succeeded" and
    (.status.lastPromotion.freight.name // "") == $freight and
    (.status.lastPromotion.status.freightCollection.id // "") == $collection_id and
    $collection != null and
    (.status.health.status // "") == "Healthy"
  ) as $coherent |
'

kargo_check_stage_success() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  kubectl -n "${project}" get stage "${stage}" -o json 2>/dev/null |
    jq -e --arg freight "${freight}" \
      "${KARGO_STAGE_PREDICATE_PREAMBLE}"'
      $coherent and ($verification.phase // "") == "Successful"
    ' >/dev/null
}

# Everything needed to tell a health failure from a verification failure from a
# Freight-projection failure, captured on the terminal failure itself rather
# than reconstructed later from controller logs.
#
# The AnalysisRun filter must join on the exact Freight collection, not just
# the Stage: F1/F2 already leave successful AnalysisRuns behind for the same
# Stage name, and a Stage-only label filter would surface those stale runs as
# if they belonged to this failure. Post-Promotion callers supply the terminal
# Promotion's collection id directly; reverify-only callers fall back to the
# exact-Freight selector. The Stage and collection labels are both required.
#
# Every path written here is appended to SIT_LEG_EVIDENCE (report-relative)
# so a terminal L9 failure records these diagnostics as structured evidence
# instead of leaving them undeclared on disk.
kargo_capture_json_evidence() {
  local namespace="$1"
  local resource="$2"
  local output="$3"
  local tmp="${output}.tmp.$$"
  local error="${output}.error.$$"
  if kubectl -n "${namespace}" get "${resource}" -o json >"${tmp}" 2>"${error}" &&
    jq -e . "${tmp}" >/dev/null 2>&1; then
    mv "${tmp}" "${output}"
    rm -f "${error}"
    return 0
  fi
  jq -n \
    --arg namespace "${namespace}" \
    --arg resource "${resource}" \
    --rawfile error "${error}" \
    '{captureAvailable:false,namespace:$namespace,resource:$resource,error:$error}' \
    >"${output}"
  rm -f "${tmp}" "${error}"
  return 1
}

kargo_capture_stage_failure_diagnostics() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local prefix="$4"
  local collection_id="${5:-}"
  local collection_source='supplied' relative
  local analysisrun_capture_attempted=false
  local analysisrun_capture_available=false
  local promotions_raw="${prefix}-promotions-raw.json"
  local analysisruns_raw="${prefix}-analysisruns-raw.json"
  kargo_capture_json_evidence "${project}" "stage/${stage}" \
    "${prefix}-stage.json" || true
  kargo_capture_json_evidence "${project}" "freight/${freight}" \
    "${prefix}-freight.json" || true
  if kargo_capture_json_evidence "${project}" promotions.kargo.akuity.io \
    "${promotions_raw}"; then
    jq --arg stage "${stage}" --arg freight "${freight}" '
        [.items[]? | select(.spec.stage == $stage and .spec.freight == $freight)] |
        sort_by(.metadata.creationTimestamp)
      ' "${promotions_raw}" >"${prefix}-promotions.json"
  else
    cp "${promotions_raw}" "${prefix}-promotions.json"
  fi
  rm -f "${promotions_raw}"
  if [ -z "${collection_id}" ]; then
    collection_source='derived'
    collection_id="$(jq -r --arg freight "${freight}" \
      "${KARGO_STAGE_PREDICATE_PREAMBLE}"'$collection.id // empty' \
      "${prefix}-stage.json" 2>/dev/null)" || true
    [ -n "${collection_id}" ] || collection_source='unavailable'
  fi
  if [ -n "${collection_id}" ]; then
    analysisrun_capture_attempted=true
  fi
  if [ "${analysisrun_capture_attempted}" = true ] &&
    kargo_capture_json_evidence "${project}" analysisruns.argoproj.io \
      "${analysisruns_raw}"; then
    analysisrun_capture_available=true
    jq --arg stage "${stage}" --arg collection "${collection_id}" '
        [.items[]? |
          select(.metadata.labels["kargo.akuity.io/stage"] == $stage and
            .metadata.labels["kargo.akuity.io/freight-collection"] == $collection)] |
        sort_by(.metadata.creationTimestamp)
      ' "${analysisruns_raw}" >"${prefix}-analysisruns.json"
  else
    printf '[]\n' >"${prefix}-analysisruns.json"
  fi
  if [ ! -s "${analysisruns_raw}" ]; then
    printf '{}\n' >"${analysisruns_raw}"
  fi
  jq -n \
    --arg collectionId "${collection_id}" \
    --arg collectionSource "${collection_source}" \
    --argjson captureAttempted "${analysisrun_capture_attempted}" \
    --argjson captureAvailable "${analysisrun_capture_available}" \
    --slurpfile capture "${analysisruns_raw}" '
      {
        schemaVersion:1,
        collectionId:(if $collectionId == "" then null else $collectionId end),
        collectionSource:$collectionSource,
        analysisRunCapture:{
          attempted:$captureAttempted,
          captureAvailable:$captureAvailable,
          requiredLabels:[
            "kargo.akuity.io/stage",
            "kargo.akuity.io/freight-collection"
          ],
          error:(if $captureAvailable then null else ($capture[0].error // null) end)
        }
      }
    ' >"${prefix}-analysisruns-join.json"
  rm -f "${analysisruns_raw}"
  relative="${prefix#"${report}/"}"
  SIT_LEG_EVIDENCE+=(
    "${relative}-stage.json" "${relative}-freight.json"
    "${relative}-promotions.json" "${relative}-analysisruns.json"
    "${relative}-analysisruns-join.json"
  )
}

kargo_wait_verified() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  local diagnostics="${output%.json}-verification-failure"
  # Coherent Stage success is the FIRST gate. The global Freight projection
  # cannot say whether promotion completion, Stage health, or the AnalysisRun
  # is the blocked prerequisite, so it must never be the sole first predicate.
  if ! sit_wait_for 180 "coherent verified Stage ${project}/${stage} for ${freight}" \
    kargo_check_stage_success "${project}" "${stage}" "${freight}"; then
    kargo_capture_stage_failure_diagnostics "${project}" "${stage}" "${freight}" \
      "${diagnostics}"
    sit_fail "Stage ${project}/${stage} did not reach coherent verified success for ${freight}"
    return 1
  fi
  if ! sit_wait_for 60 "Freight ${freight} verification projection in ${project}/${stage}" \
    kargo_check_freight_verified "${project}" "${freight}" "${stage}"; then
    kargo_capture_stage_failure_diagnostics "${project}" "${stage}" "${freight}" \
      "${diagnostics}"
    sit_fail "Freight ${freight} was never projected as verified in ${project}/${stage}"
    return 1
  fi
  kubectl -n "${project}" get stage "${stage}" -o json >"${output}"
}

# Sleep without crossing an absolute SECONDS deadline. Every post-Promotion
# wait uses this helper, including the final Freight projection wait.
kargo_sleep_before_deadline() {
  local deadline="$1"
  local now remaining sleep_s
  now="$(kargo_monotonic_now)"
  remaining=$((deadline - now))
  [ "${remaining}" -gt 0 ] || return 1
  sleep_s="${FLEET_SIT_POLL_SECONDS:-3}"
  [ "${sleep_s}" -le "${remaining}" ] || sleep_s="${remaining}"
  sleep "${sleep_s}"
}

kargo_post_promotion_deadline_reason() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local collection_id="$4"
  local expected_phase="$5"
  local current_phase="$6"
  local last_phase="$7"
  local last_message="$8"
  local capture_available="$9"
  local collection_match_count="${10}"
  local coherent="${11}"
  local projection_checked="${12}"
  local freight_capture_available="${13}"
  local context="${14}"
  local message_suffix=''
  if [ -n "${last_message}" ]; then
    message_suffix=": ${last_message}"
  fi

  if [ "${capture_available}" != true ] && [ -n "${last_phase}" ]; then
    printf 'Stage capture became unavailable after observing %s verification for exact collection %s%s in %s/%s %s' \
      "${last_phase}" "${collection_id}" "${message_suffix}" \
      "${project}" "${stage}" "${context}"
  elif [ "${capture_available}" != true ]; then
    printf 'Stage capture was unavailable before exact collection %s could be assessed in %s/%s %s' \
      "${collection_id}" "${project}" "${stage}" "${context}"
  elif [[ ${collection_match_count} =~ ^[0-9]+$ ]] &&
    [ "${collection_match_count}" -gt 1 ]; then
    printf 'Stage %s/%s contained %s ambiguous entries for exact collection %s %s' \
      "${project}" "${stage}" "${collection_match_count}" \
      "${collection_id}" "${context}"
  elif [ "${collection_match_count}" = 0 ]; then
    printf 'terminal Promotion collection %s was absent from Stage freightHistory in %s/%s %s' \
      "${collection_id}" "${project}" "${stage}" "${context}"
  elif [ -n "${current_phase}" ] && [ "${current_phase}" = "${expected_phase}" ] &&
    [ "${coherent}" != true ]; then
    printf 'Stage %s/%s reached terminal %s verification for exact collection %s%s but remained incoherent %s' \
      "${project}" "${stage}" "${current_phase}" "${collection_id}" \
      "${message_suffix}" "${context}"
  elif [ "${current_phase}" = Successful ] &&
    [ "${expected_phase}" = Successful ] && [ "${coherent}" = true ] &&
    [ "${projection_checked}" -eq 1 ]; then
    if [ "${freight_capture_available}" = true ]; then
      printf 'Freight %s was not projected verified in %s/%s %s' \
        "${freight}" "${project}" "${stage}" "${context}"
    else
      printf 'Freight %s projection could not be read in %s/%s %s' \
        "${freight}" "${project}" "${stage}" "${context}"
    fi
  elif [ -z "${current_phase}" ] && [ -n "${last_phase}" ]; then
    printf 'exact verification became unavailable after observing %s for collection %s%s in %s/%s %s' \
      "${last_phase}" "${collection_id}" "${message_suffix}" \
      "${project}" "${stage}" "${context}"
  elif [ -z "${current_phase}" ]; then
    printf 'verification for exact collection %s was never scheduled in %s/%s %s' \
      "${collection_id}" "${project}" "${stage}" "${context}"
  else
    printf 'verification for exact collection %s remained %s%s in %s/%s %s' \
      "${collection_id}" "${current_phase}" "${message_suffix}" \
      "${project}" "${stage}" "${context}"
  fi
}

kargo_capture_post_promotion_observation() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local promotion="$4"
  local collection_id="$5"
  local state="$6"
  local observation="$7"
  local deadline="$8"
  local request_timeout
  local state_tmp="${state}.tmp.$$"
  if ! kargo_driver_request_timeout "${deadline}" request_timeout; then
    jq -n \
      '{captureAvailable:false,captureError:"decision deadline exhausted before Stage read",coherent:false,collectionMatchCount:0,verificationPhase:null}' \
      >"${observation}"
    return 1
  fi
  if ! kubectl -n "${project}" get stage "${stage}" -o json \
    --request-timeout="${request_timeout}" >"${state_tmp}" 2>/dev/null; then
    rm -f "${state_tmp}"
    jq -n \
      '{captureAvailable:false,captureError:"bounded Stage read failed",coherent:false,collectionMatchCount:0,verificationPhase:null}' \
      >"${observation}"
    return 1
  fi
  if ! jq \
    --arg freight "${freight}" \
    --arg promotion "${promotion}" \
    --arg collection_id "${collection_id}" \
    "${KARGO_POST_PROMOTION_PREDICATE_PREAMBLE}"'
      {
        captureAvailable:true,
        collectionMatchCount:($collections | length),
        coherent:$coherent,
        currentPromotion:(.status.currentPromotion // null),
        lastPromotionName:(.status.lastPromotion.name // null),
        lastPromotionPhase:(.status.lastPromotion.status.phase // null),
        lastPromotionFreight:(.status.lastPromotion.freight.name // null),
        lastPromotionCollectionId:(.status.lastPromotion.status.freightCollection.id // null),
        health:(.status.health.status // null),
        lastHandledRefresh:(.status.lastHandledRefresh // null),
        verificationId:($verification.id // null),
        verificationPhase:($verification.phase // null),
        verificationMessage:($verification.message // null),
        verificationStartedAt:($verification.startTime // null),
        verificationFinishedAt:($verification.finishTime // null),
        analysisRunName:($verification.analysisRun.name // null),
        analysisRunPhase:($verification.analysisRun.phase // null)
      }
    ' "${state_tmp}" >"${observation}"; then
    rm -f "${state_tmp}"
    jq -n \
      '{captureAvailable:false,captureError:"Stage predicate evaluation failed",coherent:false,collectionMatchCount:0,verificationPhase:null}' \
      >"${observation}"
    return 1
  fi
  mv "${state_tmp}" "${state}"
}

kargo_write_post_promotion_record() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local promotion="$4"
  local collection_id="$5"
  local expected_phase="$6"
  local started_at="$7"
  local started_seconds="$8"
  local attempts="$9"
  local first_phase="${10}"
  local first_phase_at="${11}"
  local result="${12}"
  local failure_reason="${13}"
  local observation="${14}"
  local freight_state="${15}"
  local refresh_log="${16}"
  local output="${17}"
  local budget_seconds="${18}"
  local elapsed_seconds="${19}"
  local decision_at="${20}"
  local last_phase="${21}"
  local last_message="${22}"
  jq -n \
    --arg project "${project}" \
    --arg stage "${stage}" \
    --arg freight "${freight}" \
    --arg promotion "${promotion}" \
    --arg collectionId "${collection_id}" \
    --arg expectedPhase "${expected_phase}" \
    --arg startedAt "${started_at}" \
    --arg decisionAt "${decision_at}" \
    --arg recordedAt "$(sit_now)" \
    --arg firstPhase "${first_phase}" \
    --arg firstPhaseAt "${first_phase_at}" \
    --arg lastPhase "${last_phase}" \
    --arg lastMessage "${last_message}" \
    --arg result "${result}" \
    --arg failureReason "${failure_reason}" \
    --argjson attempts "${attempts}" \
    --argjson elapsed "${elapsed_seconds}" \
    --argjson budget "${budget_seconds}" \
    --argjson decisionSeconds "$((started_seconds + elapsed_seconds))" \
    --slurpfile observed "${observation}" \
    --slurpfile freightState "${freight_state}" \
    --slurpfile refreshes "${refresh_log}" '
      ($observed[0] // {}) as $o |
      ($freightState[0] // {}) as $f |
      {
        schemaVersion:1,
        project:$project,stage:$stage,freight:$freight,
        promotionName:$promotion,freightCollectionId:$collectionId,
        expectedPhase:$expectedPhase,result:$result,
        failureReason:(if $failureReason == "" then null else $failureReason end),
        trigger:"kargo.akuity.io/refresh",
        budget_s:$budget,elapsed_s:$elapsed,
        budgetScope:{
          decisionDeadline:"absolute monotonic deadline for controller observation, refresh scheduling and acknowledgement, exact terminal decision, and successful Freight projection",
          apiRequests:"each driver-path kubectl request uses --request-timeout capped by the remaining decision budget",
          excluded:[
            "post-decision Stage copy and evidence serialization",
            "failure diagnostic capture"
          ]
        },
        startedAt:$startedAt,finishedAt:$decisionAt,recordedAt:$recordedAt,
        decisionMonotonic_s:$decisionSeconds,
        refreshAttempts:$attempts,refreshes:$refreshes,
        firstObservedScheduledPhase:(if $firstPhase == "" then null else $firstPhase end),
        firstObservedScheduledAt:(if $firstPhaseAt == "" then null else $firstPhaseAt end),
        finalPhase:(if $lastPhase == "" then ($o.verificationPhase // null) else $lastPhase end),
        verification:{
          id:($o.verificationId // null),
          phase:(if $lastPhase == "" then ($o.verificationPhase // null) else $lastPhase end),
          message:(if $lastMessage == "" then ($o.verificationMessage // null) else $lastMessage end),
          startedAt:($o.verificationStartedAt // null),
          finishedAt:($o.verificationFinishedAt // null),
          analysisRunName:($o.analysisRunName // null),
          analysisRunPhase:($o.analysisRunPhase // null)
        },
        coherentStage:{
          captureAvailable:($o.captureAvailable // false),
          captureError:($o.captureError // null),
          coherent:($o.coherent // false),
          collectionMatchCount:($o.collectionMatchCount // 0),
          currentPromotion:($o.currentPromotion // null),
          lastPromotionName:($o.lastPromotionName // null),
          lastPromotionPhase:($o.lastPromotionPhase // null),
          lastPromotionFreight:($o.lastPromotionFreight // null),
          lastPromotionCollectionId:($o.lastPromotionCollectionId // null),
          health:($o.health // null),
          lastHandledRefresh:($o.lastHandledRefresh // null)
        },
        freightProjectionCaptureAvailable:($f.captureAvailable // false),
        freightVerifiedAt:($f.status.verifiedIn[$stage].verifiedAt // null)
      }
    ' >"${output}"
}

# Internal worker accepts an absolute deadline so the daemon-free regression
# gate can exercise expiry instantly. Production callers use only the public
# wrapper below, whose one fixed budget is 180 seconds.
_kargo_drive_post_promotion_verification() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local promotion="$4"
  local collection_id="$5"
  local expected_phase="$6"
  local stage_output="$7"
  local reconciliation_output="$8"
  local started_at="$9"
  local started_seconds="${10}"
  local overall_deadline="${11}"
  local diagnostics="${reconciliation_output%.json}-failure"
  local slug="${project}-${stage}-$$-${RANDOM}"
  local state="${KARGO_RUNTIME_DIR}/post-promotion-${slug}-stage.json"
  local observation="${KARGO_RUNTIME_DIR}/post-promotion-${slug}-observation.json"
  local freight_state="${KARGO_RUNTIME_DIR}/post-promotion-${slug}-freight.json"
  local refresh_log="${KARGO_RUNTIME_DIR}/post-promotion-${slug}-refreshes.jsonl"
  local freight_tmp="${freight_state}.tmp.$$"
  local max_attempts=8 refresh_timeout=90 observation_window=20
  local attempts=0 next_refresh_at=0 observation_only=0 succeeded=0
  local current_phase='' current_message='' last_phase='' last_message=''
  local coherent=false capture_available=false collection_match_count=0
  local verified_at='' first_phase='' first_phase_at=''
  local projection_checked=0 freight_capture_available=false
  local budget_seconds=$((overall_deadline - started_seconds))
  local now decision_seconds='' elapsed_seconds=0 decision_at context
  local remaining refresh_deadline token handled request_timeout failure_reason=''
  printf '{}\n' >"${state}"
  jq -n '{captureAvailable:false,coherent:false,collectionMatchCount:0,verificationPhase:null}' \
    >"${observation}"
  jq -n '{captureAvailable:false}' >"${freight_state}"
  : >"${refresh_log}"

  while true; do
    now="$(kargo_monotonic_now)"
    if [ "${now}" -ge "${overall_deadline}" ]; then
      context="at the shared ${budget_seconds}s decision deadline"
      failure_reason="$(kargo_post_promotion_deadline_reason \
        "${project}" "${stage}" "${freight}" "${collection_id}" \
        "${expected_phase}" "${current_phase}" "${last_phase}" "${last_message}" \
        "${capture_available}" "${collection_match_count}" "${coherent}" \
        "${projection_checked}" "${freight_capture_available}" "${context}")"
      decision_seconds="${now}"
      break
    fi
    kargo_capture_post_promotion_observation \
      "${project}" "${stage}" "${freight}" "${promotion}" "${collection_id}" \
      "${state}" "${observation}" "${overall_deadline}" || true
    capture_available="$(jq -r '.captureAvailable // false' "${observation}")"
    collection_match_count="$(jq -r '.collectionMatchCount // 0' "${observation}")"
    current_phase="$(jq -r '.verificationPhase // empty' "${observation}")"
    current_message="$(jq -r '.verificationMessage // empty' "${observation}")"
    coherent="$(jq -r '.coherent // false' "${observation}")"
    if [ -n "${current_phase}" ]; then
      last_phase="${current_phase}"
      last_message="${current_message}"
      observation_only=1
      if [ -z "${first_phase}" ]; then
        first_phase="${current_phase}"
        first_phase_at="$(sit_now)"
      fi
    fi
    now="$(kargo_monotonic_now)"
    if [ "${now}" -gt "${overall_deadline}" ]; then
      context="at the shared ${budget_seconds}s decision deadline"
      failure_reason="$(kargo_post_promotion_deadline_reason \
        "${project}" "${stage}" "${freight}" "${collection_id}" \
        "${expected_phase}" "${current_phase}" "${last_phase}" "${last_message}" \
        "${capture_available}" "${collection_match_count}" "${coherent}" \
        "${projection_checked}" "${freight_capture_available}" "${context}")"
      decision_seconds="${now}"
      break
    fi

    if [ -n "${current_phase}" ]; then
      case "${current_phase}" in
      Pending | Running) ;;
      Successful | Failed)
        if [ "${current_phase}" != "${expected_phase}" ]; then
          failure_reason="expected ${expected_phase} verification for ${project}/${stage} but observed ${current_phase}: ${current_message:-no message}"
          decision_seconds="${now}"
          break
        fi
        if [ "${coherent}" = true ]; then
          if [ "${expected_phase}" = Failed ] && [ "${now}" -le "${overall_deadline}" ]; then
            succeeded=1
            decision_seconds="${now}"
            break
          fi
          projection_checked=1
          freight_capture_available=false
          if kargo_driver_request_timeout "${overall_deadline}" request_timeout &&
            kubectl -n "${project}" get freight "${freight}" -o json \
              --request-timeout="${request_timeout}" >"${freight_tmp}" 2>/dev/null &&
            jq -e . "${freight_tmp}" >/dev/null 2>&1; then
            jq '. + {captureAvailable:true}' "${freight_tmp}" >"${freight_state}"
            freight_capture_available=true
          else
            jq -n '{captureAvailable:false,captureError:"bounded Freight projection read failed"}' \
              >"${freight_state}"
          fi
          rm -f "${freight_tmp}"
          now="$(kargo_monotonic_now)"
          verified_at="$(jq -r --arg stage "${stage}" \
            '.status.verifiedIn[$stage].verifiedAt // empty' "${freight_state}")"
          if [ -n "${verified_at}" ]; then
            if [ "${now}" -le "${overall_deadline}" ]; then
              succeeded=1
              decision_seconds="${now}"
              break
            fi
            failure_reason="Freight ${freight} projection in ${project}/${stage} was observed only after the shared ${budget_seconds}s decision deadline"
            decision_seconds="${now}"
            break
          fi
        fi
        ;;
      Error | Aborted | Inconclusive)
        failure_reason="expected ${expected_phase} verification for ${project}/${stage} but observed terminal ${current_phase}: ${current_message:-no message}"
        decision_seconds="${now}"
        break
        ;;
      *)
        failure_reason="unknown verification phase ${current_phase} for exact collection ${collection_id} in ${project}/${stage}: ${current_message:-no message}"
        decision_seconds="${now}"
        break
        ;;
      esac
    fi

    now="$(kargo_monotonic_now)"
    if [ "${now}" -ge "${overall_deadline}" ]; then
      context="at the shared ${budget_seconds}s decision deadline"
      failure_reason="$(kargo_post_promotion_deadline_reason \
        "${project}" "${stage}" "${freight}" "${collection_id}" \
        "${expected_phase}" "${current_phase}" "${last_phase}" "${last_message}" \
        "${capture_available}" "${collection_match_count}" "${coherent}" \
        "${projection_checked}" "${freight_capture_available}" "${context}")"
      decision_seconds="${now}"
      break
    fi

    if [ "${observation_only}" -eq 1 ]; then
      kargo_sleep_before_deadline "${overall_deadline}" || true
      continue
    fi

    if [ "${now}" -lt "${next_refresh_at}" ]; then
      kargo_sleep_before_deadline "${overall_deadline}" || true
      continue
    fi
    if [ "${attempts}" -ge "${max_attempts}" ]; then
      context="after ${attempts} refresh attempts within the shared ${budget_seconds}s decision budget"
      failure_reason="$(kargo_post_promotion_deadline_reason \
        "${project}" "${stage}" "${freight}" "${collection_id}" \
        "${expected_phase}" "${current_phase}" "${last_phase}" "${last_message}" \
        "${capture_available}" "${collection_match_count}" "${coherent}" \
        "${projection_checked}" "${freight_capture_available}" "${context}")"
      decision_seconds="${now}"
      break
    fi

    remaining=$((overall_deadline - now))
    [ "${remaining}" -gt 0 ] || continue
    attempts=$((attempts + 1))
    token=''
    handled=false
    refresh_deadline=$((now + refresh_timeout))
    [ "${refresh_deadline}" -le "${overall_deadline}" ] || refresh_deadline="${overall_deadline}"
    if kargo_refresh_stage_quiet "${project}" "${stage}" \
      "${refresh_deadline}" token; then
      handled=true
    fi
    jq -cn \
      --arg token "${token}" \
      --argjson handled "${handled}" \
      --arg observedAt "$(sit_now)" \
      '{token:$token,handled:$handled,observedAt:$observedAt}' >>"${refresh_log}"
    now="$(kargo_monotonic_now)"
    remaining=$((overall_deadline - now))
    next_refresh_at=$((now + (remaining < observation_window ? remaining : observation_window)))
  done

  if [ -z "${decision_seconds}" ]; then
    decision_seconds="$(kargo_monotonic_now)"
  fi
  elapsed_seconds=$((decision_seconds - started_seconds))
  [ "${elapsed_seconds}" -ge 0 ] || elapsed_seconds=0
  decision_at="$(sit_now)"

  if [ "${succeeded}" -eq 1 ]; then
    cp "${state}" "${stage_output}"
    kargo_write_post_promotion_record \
      "${project}" "${stage}" "${freight}" "${promotion}" "${collection_id}" \
      "${expected_phase}" "${started_at}" "${started_seconds}" "${attempts}" \
      "${first_phase}" "${first_phase_at}" success '' \
      "${observation}" "${freight_state}" "${refresh_log}" "${reconciliation_output}" \
      "${budget_seconds}" "${elapsed_seconds}" "${decision_at}" \
      "${last_phase}" "${last_message}"
    jq -e \
      --arg promotion "${promotion}" \
      --arg freight "${freight}" \
      --arg collection "${collection_id}" \
      --arg phase "${expected_phase}" \
      --argjson budget "${budget_seconds}" '
        .budget_s == $budget and .elapsed_s <= .budget_s and
        .promotionName == $promotion and .freight == $freight and
        .freightCollectionId == $collection and .finalPhase == $phase and
        .coherentStage.coherent == true and
        (if $phase == "Successful" then .freightVerifiedAt != null else true end)
      ' "${reconciliation_output}" >/dev/null || {
      failure_reason="post-Promotion evidence contract failed for ${project}/${stage}"
      succeeded=0
    }
  fi

  if [ "${succeeded}" -ne 1 ]; then
    kargo_write_post_promotion_record \
      "${project}" "${stage}" "${freight}" "${promotion}" "${collection_id}" \
      "${expected_phase}" "${started_at}" "${started_seconds}" "${attempts}" \
      "${first_phase}" "${first_phase_at}" failure "${failure_reason}" \
      "${observation}" "${freight_state}" "${refresh_log}" "${reconciliation_output}" \
      "${budget_seconds}" "${elapsed_seconds}" "${decision_at}" \
      "${last_phase}" "${last_message}"
    kargo_capture_stage_failure_diagnostics \
      "${project}" "${stage}" "${freight}" "${diagnostics}" "${collection_id}"
    sit_fail "${failure_reason}"
    return 1
  fi
}

kargo_drive_post_promotion_verification() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local promotion_capture="$4"
  local expected_phase="$5"
  local stage_output="$6"
  local reconciliation_output="$7"
  local promotion='' collection_id='' relative
  local started_at started_seconds overall_deadline diagnostics
  started_at="$(sit_now)"
  started_seconds="$(kargo_monotonic_now)"
  overall_deadline=$((started_seconds + 180))
  diagnostics="${reconciliation_output%.json}-failure"
  relative="${reconciliation_output#"${report}/"}"
  SIT_LEG_EVIDENCE+=("${relative}")

  case "${expected_phase}" in
  Successful | Failed) ;;
  *)
    jq -n \
      --arg project "${project}" --arg stage "${stage}" --arg freight "${freight}" \
      --arg expectedPhase "${expected_phase}" --arg startedAt "${started_at}" '
        {schemaVersion:1,project:$project,stage:$stage,freight:$freight,
         promotionName:null,freightCollectionId:null,expectedPhase:$expectedPhase,
         result:"failure",failureReason:"invalid expected phase",
         trigger:"none",budget_s:180,elapsed_s:0,startedAt:$startedAt,
         finishedAt:$startedAt,refreshAttempts:0,refreshes:[]}
      ' >"${reconciliation_output}"
    sit_fail "post-Promotion verification expected phase must be Successful or Failed, got ${expected_phase}"
    return 1
    ;;
  esac

  if ! jq -e --arg stage "${stage}" --arg freight "${freight}" '
    length >= 1 and
    (.[-1].metadata.name // "") != "" and
    .[-1].spec.stage == $stage and
    .[-1].spec.freight == $freight and
    .[-1].status.phase == "Succeeded" and
    .[-1].status.freight.name == $freight and
    ((.[-1].status.freightCollection.id // "") | type) == "string" and
    (.[-1].status.freightCollection.id // "") != ""
  ' "${promotion_capture}" >/dev/null; then
    jq -n \
      --arg project "${project}" --arg stage "${stage}" --arg freight "${freight}" \
      --arg expectedPhase "${expected_phase}" --arg startedAt "${started_at}" '
        {schemaVersion:1,project:$project,stage:$stage,freight:$freight,
         promotionName:null,freightCollectionId:null,expectedPhase:$expectedPhase,
         result:"failure",failureReason:"invalid terminal Promotion capture",
         trigger:"none",budget_s:180,elapsed_s:0,startedAt:$startedAt,
         finishedAt:$startedAt,refreshAttempts:0,refreshes:[]}
      ' >"${reconciliation_output}"
    kargo_capture_stage_failure_diagnostics \
      "${project}" "${stage}" "${freight}" "${diagnostics}" ''
    sit_fail "terminal Promotion capture does not bind ${project}/${stage} to exact Freight ${freight}"
    return 1
  fi
  promotion="$(jq -r '.[-1].metadata.name' "${promotion_capture}")"
  collection_id="$(jq -r '.[-1].status.freightCollection.id' "${promotion_capture}")"

  _kargo_drive_post_promotion_verification \
    "${project}" "${stage}" "${freight}" "${promotion}" "${collection_id}" \
    "${expected_phase}" "${stage_output}" "${reconciliation_output}" \
    "${started_at}" "${started_seconds}" "${overall_deadline}"
}

kargo_check_auto_enabled() {
  local project="$1"
  local stage="$2"
  local expected="$3"
  kubectl -n "${project}" get stage "${stage}" -o json 2>/dev/null |
    jq -e --argjson expected "${expected}" \
      '(.status.autoPromotionEnabled // false) == $expected' >/dev/null
}

kargo_promotion_count() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  kubectl -n "${project}" get promotions.kargo.akuity.io -o json |
    jq --arg stage "${stage}" --arg freight "${freight}" '
      [.items[]? | select(.spec.stage == $stage and .spec.freight == $freight)] | length
    '
}

kargo_assert_no_promotion_for() {
  local duration_s="$1"
  local project="$2"
  local stage="$3"
  local freight="$4"
  local reason="$5"
  local output="$6"
  local started_at started_epoch deadline count
  started_at="$(sit_now)"
  started_epoch="$(sit_epoch)"
  deadline=$((SECONDS + duration_s))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    count="$(kargo_promotion_count "${project}" "${stage}" "${freight}")"
    if [ "${count}" -ne 0 ]; then
      kubectl -n "${project}" get promotions.kargo.akuity.io -o json >"${output}"
      sit_fail "unexpected Promotion of ${freight} to ${project}/${stage}: ${reason}"
      return 1
    fi
    sleep 2
  done
  jq -n \
    --arg project "${project}" \
    --arg stage "${stage}" \
    --arg freight "${freight}" \
    --arg reason "${reason}" \
    --arg startedAt "${started_at}" \
    --arg finishedAt "$(sit_now)" \
    --argjson duration "$(($(sit_epoch) - started_epoch))" '
      {
        project:$project,stage:$stage,freight:$freight,reason:$reason,
        startedAt:$startedAt,finishedAt:$finishedAt,duration_s:$duration,
        promotionCount:0
      }
    ' >"${output}"
}

# Wait for the boundary derived from a persisted Freight residency timestamp.
# The real UTC clock is the gate; the monotonic deadline only prevents a clock
# anomaly from hanging the leg indefinitely.
kargo_wait_wall_clock_boundary() {
  local since="$1"
  local lower_bound="$2"
  local reason="$3"
  local output="$4"
  local started_at started_epoch started_monotonic remaining deadline
  local current_epoch now_monotonic sleep_s finished_at finished_epoch
  [[ ${lower_bound} =~ ^[0-9]+$ ]] || {
    sit_fail "wall-clock lower bound is not an unsigned epoch: ${lower_bound}"
    return 1
  }
  started_at="$(sit_now)"
  started_epoch="$(date -u -d "${started_at}" +%s)"
  started_monotonic="$(kargo_monotonic_now)"
  remaining=$((lower_bound - started_epoch))
  [ "${remaining}" -gt 0 ] || remaining=0
  deadline=$((started_monotonic + remaining + 30))
  current_epoch="${started_epoch}"
  while [ "${current_epoch}" -lt "${lower_bound}" ]; do
    now_monotonic="$(kargo_monotonic_now)"
    if [ "${now_monotonic}" -ge "${deadline}" ]; then
      sit_fail "timed out waiting for ${reason} at epoch ${lower_bound}"
      return 1
    fi
    sleep_s=$((lower_bound - current_epoch))
    [ "${sleep_s}" -le 2 ] || sleep_s=2
    sleep "${sleep_s}"
    current_epoch="$(sit_epoch)"
  done
  finished_at="$(sit_now)"
  finished_epoch="$(date -u -d "${finished_at}" +%s)"
  [ "${finished_epoch}" -ge "${lower_bound}" ] ||
    sit_fail "wall clock moved behind ${reason} after reaching epoch ${lower_bound}"
  jq -n \
    --arg promotionTimeSince "${since}" \
    --arg reason "${reason}" \
    --arg startedAt "${started_at}" \
    --argjson startedEpoch "${started_epoch}" \
    --arg finishedAt "${finished_at}" \
    --argjson finishedEpoch "${finished_epoch}" \
    --argjson lowerBoundEpoch "${lower_bound}" \
    --argjson waitedSeconds "$((finished_epoch - started_epoch))" '
      {
        schemaVersion:1,promotionTimeSince:$promotionTimeSince,reason:$reason,
        lowerBoundEpoch:$lowerBoundEpoch,
        startedAt:$startedAt,startedEpoch:$startedEpoch,
        finishedAt:$finishedAt,finishedEpoch:$finishedEpoch,
        waitedSeconds:$waitedSeconds
      }
    ' >"${output}"
}

# Take the last mutation-free read before probing admission and issuing the
# post-boundary wake-up. The snapshot binds the original residency clock, both
# upstream memberships/verifications, policy, Promotion absence, and the
# previously acknowledged refresh token into one artifact.
kargo_capture_soak_pre_stimulus() {
  local project="$1"
  local ampharos="$2"
  local pikachu="$3"
  local raichu="$4"
  local freight="$5"
  local expected_since="$6"
  local lower_bound="$7"
  local pre_boundary_token="$8"
  local output="$9"
  local freight_snapshot="${KARGO_RUNTIME_DIR}/soak-pre-stimulus-freight.json"
  local stage_snapshot="${KARGO_RUNTIME_DIR}/soak-pre-stimulus-stage.json"
  local promotions_snapshot="${KARGO_RUNTIME_DIR}/soak-pre-stimulus-promotions.json"
  local captured_at captured_epoch
  kubectl -n "${project}" get freight "${freight}" -o json >"${freight_snapshot}"
  kubectl -n "${project}" get stage "${ampharos}" -o json >"${stage_snapshot}"
  kubectl -n "${project}" get promotions.kargo.akuity.io -o json \
    >"${promotions_snapshot}"
  captured_at="$(sit_now)"
  captured_epoch="$(date -u -d "${captured_at}" +%s)"
  jq -n \
    --arg project "${project}" \
    --arg stage "${ampharos}" \
    --arg freightName "${freight}" \
    --arg pikachu "${pikachu}" \
    --arg raichu "${raichu}" \
    --arg expectedSince "${expected_since}" \
    --arg preBoundaryRefreshToken "${pre_boundary_token}" \
    --arg capturedAt "${captured_at}" \
    --argjson capturedEpoch "${captured_epoch}" \
    --argjson lowerBoundEpoch "${lower_bound}" \
    --slurpfile freight "${freight_snapshot}" \
    --slurpfile ampharosStage "${stage_snapshot}" \
    --slurpfile promotions "${promotions_snapshot}" '
      ($freight[0]) as $freightObject |
      ($ampharosStage[0]) as $stageObject |
      ([$promotions[0].items[]? | select(.spec.stage == $stage)]) as $ampharosPromotions |
      {
        schemaVersion:1,project:$project,stage:$stage,freight:$freightName,
        capturedAt:$capturedAt,capturedEpoch:$capturedEpoch,
        lowerBoundEpoch:$lowerBoundEpoch,expectedPikachuSince:$expectedSince,
        persistedPikachuSince:($freightObject.status.currentlyIn[$pikachu].since // null),
        residency:{
          pikachu:($freightObject.status.currentlyIn[$pikachu] // null),
          raichu:($freightObject.status.currentlyIn[$raichu] // null)
        },
        verification:{
          pikachu:($freightObject.status.verifiedIn[$pikachu] // null),
          raichu:($freightObject.status.verifiedIn[$raichu] // null)
        },
        autoPromotionEnabled:($stageObject.status.autoPromotionEnabled // false),
        preBoundaryRefreshToken:$preBoundaryRefreshToken,
        lastHandledRefresh:($stageObject.status.lastHandledRefresh // null),
        promotionCount:($ampharosPromotions | length),
        ampharosPromotions:$ampharosPromotions,
        freightObject:$freightObject,
        ampharosStageObject:$stageObject
      }
    ' >"${output}"
  jq -e --arg since "${expected_since}" --arg token "${pre_boundary_token}" '
    .capturedEpoch >= .lowerBoundEpoch and
    .expectedPikachuSince == $since and .persistedPikachuSince == $since and
    (.residency.pikachu.since // "") == $since and
    (.residency.raichu.since // "") != "" and
    (.verification.pikachu.verifiedAt // "") != "" and
    (.verification.raichu.verifiedAt // "") != "" and
    .autoPromotionEnabled == true and
    $token != "" and .preBoundaryRefreshToken == $token and
    .lastHandledRefresh == $token and
    .promotionCount == 0 and (.ampharosPromotions | length) == 0
  ' "${output}" >/dev/null ||
    sit_fail 'the soak pre-stimulus snapshot did not preserve the causal boundary state'
}

# Encode a real millisecond timestamp plus 80 bits of cryptographic entropy as
# a lowercase ULID. This is the same 26-character ordering component used by
# pinned Kargo v1.9.10 Promotion names.
kargo_promotion_ulid() {
  local timestamp_ms="$1"
  local output_name="$2"
  local generated_ulid
  local -n output_ref="${output_name}"
  [[ ${timestamp_ms} =~ ^[0-9]+$ ]] || {
    sit_fail "Promotion ULID timestamp is not an unsigned millisecond value: ${timestamp_ms}"
    return 1
  }
  if ! generated_ulid="$(bun -e '
    const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
    const timestamp = BigInt(process.argv[1]);
    if (timestamp < 0n || timestamp >= (1n << 48n)) process.exit(2);
    const encode = (input, length) => {
      let value = input;
      let result = "";
      for (let index = 0; index < length; index += 1) {
        result = alphabet[Number(value & 31n)] + result;
        value >>= 5n;
      }
      if (value !== 0n) process.exit(3);
      return result;
    };
    let entropy = 0n;
    for (const byte of crypto.getRandomValues(new Uint8Array(10))) {
      entropy = (entropy << 8n) | BigInt(byte);
    }
    process.stdout.write(encode(timestamp, 10) + encode(entropy, 16));
  ' -- "${timestamp_ms}")"; then
    sit_fail "Promotion ULID timestamp is outside the 48-bit ULID range: ${timestamp_ms}"
    return 1
  fi
  [[ ${generated_ulid} =~ ^[0-9a-hjkmnp-tv-z]{26}$ ]] || {
    sit_fail "generated Promotion ULID is not lowercase Crockford base32: ${generated_ulid}"
    return 1
  }
  output_ref="${generated_ulid}"
}

kargo_promotion_name_timestamp_ms() {
  local name="$1"
  local output_name="$2"
  local without_hash ulid decoded_ms
  local -n output_ref="${output_name}"
  without_hash="${name%.*}"
  ulid="${without_hash##*.}"
  [[ ${ulid} =~ ^[0-9a-hjkmnp-tv-z]{26}$ ]] || {
    sit_fail "Promotion name has no valid lowercase ULID component: ${name}"
    return 1
  }
  if ! decoded_ms="$(bun -e '
    const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
    let decoded = 0n;
    for (const character of process.argv[1].slice(0, 10)) {
      const digit = alphabet.indexOf(character);
      if (digit < 0) process.exit(2);
      decoded = decoded * 32n + BigInt(digit);
    }
    if (decoded >= (1n << 48n)) process.exit(3);
    process.stdout.write(decoded.toString());
  ' -- "${ulid}")"; then
    sit_fail "Promotion name has an invalid 48-bit ULID timestamp: ${name}"
    return 1
  fi
  # shellcheck disable=SC2034 # assignment returns through the caller's nameref
  output_ref="${decoded_ms}"
}

kargo_manual_promotion_ordering_floor_reached() {
  local name="$1"
  local controller_clock_ms="$2"
  local name_timestamp_ms
  [[ ${controller_clock_ms} =~ ^[0-9]+$ ]] || return 1
  kargo_promotion_name_timestamp_ms "${name}" name_timestamp_ms || return 1
  [ "${controller_clock_ms}" -gt "${name_timestamp_ms}" ]
}

# The pinned controller runs on this Namespace VM and shares
# the host kernel's realtime clock with the harness. Kargo's ulid.Make() reads
# that clock. Fail closed unless the shared realtime is strictly beyond the
# manual name's timestamp before the Promotion can exist; any later Kargo name
# must then have a greater ten-character timestamp prefix regardless of entropy.
kargo_wait_manual_promotion_ordering_floor() {
  local name="$1"
  local attempt controller_clock_ms name_timestamp_ms
  kargo_promotion_name_timestamp_ms "${name}" name_timestamp_ms || return 1
  for ((attempt = 0; attempt < 5000; attempt++)); do
    controller_clock_ms="$(date -u +%s%3N)"
    if [[ ${controller_clock_ms} =~ ^[0-9]+$ ]] &&
      [ "${controller_clock_ms}" -gt "${name_timestamp_ms}" ]; then
      return 0
    fi
    sleep 0.001
  done
  sit_fail "shared controller clock did not advance beyond manual Promotion timestamp ${name_timestamp_ms}"
  return 1
}

kargo_validate_manual_promotion_name() {
  local name="$1"
  local stage="$2"
  local freight="$3"
  local without_hash ulid stage_prefix short_hash expected label timestamp_ms
  local -a labels
  stage_prefix="${stage:0:218}"
  short_hash="${freight:0:7}"
  [ "${name}" = "${name,,}" ] && [ "${#name}" -le 253 ] &&
    [[ ${name} =~ ^([a-z0-9]([-a-z0-9]*[a-z0-9])?)([.]([a-z0-9]([-a-z0-9]*[a-z0-9])?))*$ ]] || {
    sit_fail "manual Promotion name is not a lowercase DNS subdomain of at most 253 characters: ${name}"
    return 1
  }
  without_hash="${name%.*}"
  ulid="${without_hash##*.}"
  expected="${stage_prefix}.${ulid}.${short_hash}"
  [ "${name}" = "${expected}" ] &&
    [[ ${ulid} =~ ^[0-9a-hjkmnp-tv-z]{26}$ ]] || {
    sit_fail "manual Promotion name does not match <stage>.<lowercase-ulid>.<freight-short-hash>: ${name}"
    return 1
  }
  kargo_promotion_name_timestamp_ms "${name}" timestamp_ms || return 1
  IFS='.' read -r -a labels <<<"${name}"
  for label in "${labels[@]}"; do
    [ "${#label}" -le 63 ] || {
      sit_fail "manual Promotion name contains a DNS label longer than 63 characters: ${name}"
      return 1
    }
  done
}

kargo_generate_manual_promotion_name() {
  local stage="$1"
  local freight="$2"
  local timestamp_ms="$3"
  local output_name="$4"
  local ulid generated
  local -n output_ref="${output_name}"
  kargo_promotion_ulid "${timestamp_ms}" ulid || return 1
  generated="${stage:0:218}.${ulid}.${freight:0:7}"
  generated="${generated,,}"
  kargo_validate_manual_promotion_name "${generated}" "${stage}" "${freight}" || return 1
  output_ref="${generated}"
}

# Stamp each manual Promotion one millisecond behind shared realtime, then
# require that realtime floor again immediately before creation. Manual names
# also remain strictly increasing: if two calls see the same millisecond, wait
# for the clock instead of substituting an unordered Kubernetes random suffix.
kargo_next_manual_promotion_timestamp() {
  local output_name="$1"
  local attempt now_ms candidate_ms
  local last_ms="${KARGO_MANUAL_PROMOTION_LAST_MS:-0}"
  local -n output_ref="${output_name}"
  for ((attempt = 0; attempt < 1000; attempt++)); do
    now_ms="$(date -u +%s%3N)"
    if [[ ${now_ms} =~ ^[0-9]+$ ]] && [ "${now_ms}" -gt 0 ]; then
      candidate_ms=$((now_ms - 1))
    else
      candidate_ms=0
    fi
    if [ "${candidate_ms}" -gt "${last_ms}" ]; then
      KARGO_MANUAL_PROMOTION_LAST_MS="${candidate_ms}"
      # shellcheck disable=SC2034 # assignment returns through the caller's nameref
      output_ref="${candidate_ms}"
      return 0
    fi
    sleep 0.001
  done
  sit_fail 'real millisecond ordering floor did not advance for a monotonic manual Promotion ULID'
  return 1
}

kargo_write_promotion_manifest() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  local promotion_template promotion_timestamp_ms promotion_name
  kargo_next_manual_promotion_timestamp promotion_timestamp_ms
  kargo_generate_manual_promotion_name \
    "${stage}" "${freight}" "${promotion_timestamp_ms}" promotion_name
  promotion_template="$(kubectl -n "${project}" get stage "${stage}" -o json |
    jq -c '{
      steps:(.spec.promotionTemplate.spec.steps // []),
      vars:((.spec.vars // []) + (.spec.promotionTemplate.spec.vars // []))
    }')"
  jq -e '.steps | type == "array" and length > 0' <<<"${promotion_template}" >/dev/null ||
    sit_fail "Stage ${project}/${stage} has no promotion steps to build into a Promotion"
  # The dollar reference is a yq variable, not shell expansion.
  # shellcheck disable=SC2016
  NAME="${promotion_name}" NAMESPACE="${project}" STAGE="${stage}" FREIGHT="${freight}" \
    PROMOTION_TEMPLATE="${promotion_template}" yq '
    (strenv(PROMOTION_TEMPLATE) | from_json) as $template |
    .metadata.name = strenv(NAME) |
    .metadata.namespace = strenv(NAMESPACE) |
    .spec.stage = strenv(STAGE) |
    .spec.freight = strenv(FREIGHT) |
    .spec.steps = $template.steps |
    .spec.vars = $template.vars
  ' "${validation_dir}/fixtures/kargo-runtime/promotion.yaml" >"${output}"
}

kargo_capture_missing_promotion_steps_denial() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  local manifest="${KARGO_RUNTIME_DIR}/missing-steps-${project}-${stage}-${freight}.yaml"
  local log="${output}.response.txt"
  local promotion_timestamp_ms promotion_name
  local status=0
  kargo_next_manual_promotion_timestamp promotion_timestamp_ms
  kargo_generate_manual_promotion_name \
    "${stage}" "${freight}" "${promotion_timestamp_ms}" promotion_name
  NAME="${promotion_name}" NAMESPACE="${project}" STAGE="${stage}" FREIGHT="${freight}" yq '
    .metadata.name = strenv(NAME) |
    .metadata.namespace = strenv(NAMESPACE) |
    .spec.stage = strenv(STAGE) |
    .spec.freight = strenv(FREIGHT)
  ' "${validation_dir}/fixtures/kargo-runtime/promotion.yaml" >"${manifest}"
  kubectl create --dry-run=server -f "${manifest}" -o json >"${log}" 2>&1 || status=$?
  [ "${status}" -ne 0 ] ||
    sit_fail 'the live Kargo webhook admitted a manual Promotion with no materialized steps'
  rg -F 'defines no promotion steps' "${log}" >/dev/null ||
    sit_fail 'the missing-step Promotion denial did not carry the pinned webhook text'
  jq -n \
    --arg project "${project}" \
    --arg stage "${stage}" \
    --arg freight "${freight}" \
    --argjson exitStatus "${status}" \
    --rawfile response "${log}" '
      {
        project:$project,stage:$stage,freight:$freight,
        admitted:false,exitStatus:$exitStatus,
        expectedText:"defines no promotion steps",
        response:($response | .[0:4096])
      }
    ' >"${output}"
}

kargo_create_manual_promotion() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  local manifest="${KARGO_RUNTIME_DIR}/promotion-${project}-${stage}-${freight}.yaml"
  local promotion_name
  kargo_write_promotion_manifest "${project}" "${stage}" "${freight}" "${manifest}"
  promotion_name="$(yq -r '.metadata.name' "${manifest}")"
  kargo_validate_manual_promotion_name \
    "${promotion_name}" "${stage}" "${freight}"
  kargo_wait_manual_promotion_ordering_floor "${promotion_name}"
  kubectl create -f "${manifest}" -o json >"${output}"
  jq -e --arg name "${promotion_name}" --arg stage "${stage}" --arg freight "${freight}" '
    .metadata.name == $name and
    (.metadata | has("generateName") | not) and
    .spec.stage == $stage and .spec.freight == $freight and
    (.spec.steps | length) == 4
  ' "${output}" >/dev/null
}

kargo_capture_promotion_denial() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local reason="$4"
  local output="$5"
  local manifest="${KARGO_RUNTIME_DIR}/denied-${project}-${stage}-${freight}-${RANDOM}.yaml"
  local log="${output}.response.txt"
  local status=0
  kargo_write_promotion_manifest "${project}" "${stage}" "${freight}" "${manifest}"
  kubectl create -f "${manifest}" -o json >"${log}" 2>&1 || status=$?
  [ "${status}" -ne 0 ] ||
    sit_fail "the live Kargo webhook admitted an unavailable Promotion: ${reason}"
  rg -F 'Freight is not available to this Stage' "${log}" >/dev/null ||
    sit_fail "the unavailable Promotion denial did not carry the pinned webhook text: ${reason}"
  jq -n \
    --arg project "${project}" \
    --arg stage "${stage}" \
    --arg freight "${freight}" \
    --arg reason "${reason}" \
    --argjson exitStatus "${status}" \
    --rawfile response "${log}" '
      {
        project:$project,stage:$stage,freight:$freight,reason:$reason,
        admitted:false,exitStatus:$exitStatus,
        expectedText:"Freight is not available to this Stage",
        response:($response | .[0:4096])
      }
    ' >"${output}"
}

kargo_capture_promotion_dry_run_acceptance() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local output="$4"
  local manifest="${KARGO_RUNTIME_DIR}/available-${project}-${stage}-${freight}.yaml"
  local enriched="${output}.captured"
  local requested_at requested_epoch admitted_at admitted_epoch
  kargo_write_promotion_manifest "${project}" "${stage}" "${freight}" "${manifest}"
  requested_at="$(sit_now)"
  requested_epoch="$(date -u -d "${requested_at}" +%s)"
  kubectl create --dry-run=server -f "${manifest}" -o json >"${output}"
  jq -e --arg stage "${stage}" --arg freight "${freight}" '
    .spec.stage == $stage and .spec.freight == $freight and
    (.spec.steps | length) == 4
  ' "${output}" >/dev/null
  admitted_at="$(sit_now)"
  admitted_epoch="$(date -u -d "${admitted_at}" +%s)"
  jq \
    --arg requestedAt "${requested_at}" \
    --argjson requestedEpoch "${requested_epoch}" \
    --arg admittedAt "${admitted_at}" \
    --argjson admittedEpoch "${admitted_epoch}" '
      . + {
        fleetSitDryRun:{
          admitted:true,serverSide:true,
          requestedAt:$requestedAt,requestedEpoch:$requestedEpoch,
          admittedAt:$admittedAt,admittedEpoch:$admittedEpoch
        }
      }
    ' "${output}" >"${enriched}"
  mv "${enriched}" "${output}"
}

kargo_seed_freight() {
  local project="$1"
  local alias="$2"
  local tag="$3"
  local output="$4"
  NAMESPACE="${project}" ALIAS="${alias}" TAG="${tag}" \
    IMAGE_REPO="registry.sit.invalid/${project}/dummy" \
    CHART_REPO="oci://registry.sit.invalid/${project}-dummy" yq '
      .metadata.namespace = strenv(NAMESPACE) |
      .alias = strenv(ALIAS) |
      .images[0].repoURL = strenv(IMAGE_REPO) |
      .images[0].tag = strenv(TAG) |
      .charts[0].repoURL = strenv(CHART_REPO) |
      .charts[0].version = strenv(TAG)
    ' "${validation_dir}/fixtures/kargo-runtime/freight.yaml" |
    kubectl create -f - -o json >"${output}"
  local freight
  freight="$(jq -r '.metadata.name' "${output}")"
  [ -n "${freight}" ] && [ "${freight}" != 'seed' ] ||
    sit_fail 'the pinned Freight mutating webhook did not calculate the content-derived name'
  kubectl -n "${project}" get freight \
    --selector "kargo.akuity.io/alias=${alias}" -o json \
    >"${output%.json}-alias-discovery.json"
  jq -e --arg freight "${freight}" --arg alias "${alias}" '
    (.items | length) == 1 and
    .items[0].metadata.name == $freight and
    .items[0].alias == $alias and
    .items[0].metadata.labels["kargo.akuity.io/alias"] == $alias
  ' "${output%.json}-alias-discovery.json" >/dev/null
}

kargo_set_analysis_outcome() {
  local project="$1"
  local key="$2"
  local value="$3"
  local output="$4"
  local relative="${output#"${report}/"}"
  SIT_LEG_EVIDENCE+=("${relative}")
  kubectl -n "${project}" patch configmap kargo-analysis-outcomes --type merge \
    -p "$(jq -cn --arg key "${key}" --arg value "${value}" '{data:{($key):$value}}')" \
    -o json >"${output}"
  jq -e --arg key "${key}" --arg value "${value}" \
    '.data[$key] == $value' "${output}" >/dev/null ||
    sit_fail "analysis outcome ${project}/${key}=${value} did not persist"
}

kargo_backdate_freight_stage() {
  local project="$1"
  local freight="$2"
  local stage="$3"
  local seconds="$4"
  local output="$5"
  local before target body after
  before="$(kubectl -n "${project}" get freight "${freight}" -o json |
    jq -r --arg stage "${stage}" '.status.currentlyIn[$stage].since // empty')"
  [ -n "${before}" ] || sit_fail "Freight ${freight} is not currently in ${project}/${stage}"
  target="$(date -u -d "@$(($(sit_epoch) - seconds))" +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -cn --arg stage "${stage}" --arg since "${target}" \
    '{status:{currentlyIn:{($stage):{since:$since}}}}')"
  kubectl -n "${project}" patch freight "${freight}" --subresource=status \
    --type merge -p "${body}" -o json >"${KARGO_RUNTIME_DIR}/freight-backdate.json"
  after="$(kubectl -n "${project}" get freight "${freight}" -o json |
    jq -r --arg stage "${stage}" '.status.currentlyIn[$stage].since // empty')"
  [ "${after}" = "${target}" ] ||
    sit_fail "backdated since did not persist for ${project}/${stage}"
  jq -n \
    --arg project "${project}" \
    --arg freight "${freight}" \
    --arg stage "${stage}" \
    --arg before "${before}" \
    --arg after "${after}" \
    --argjson seconds "${seconds}" '
      {project:$project,freight:$freight,stage:$stage,before:$before,after:$after,
       injectedAgeSeconds:$seconds,persisted:true}
    ' >"${output}"
}

kargo_capture_current_analysis_run() {
  local project="$1"
  local stage="$2"
  local freight="$3"
  local expected_phase="$4"
  local output="$5"
  local collection_id="$6"
  local analysis_run
  analysis_run="$(kubectl -n "${project}" get stage "${stage}" -o json |
    jq -r --arg freight "${freight}" --arg collection_id "${collection_id}" '
      ((.status.freightHistory // []) |
        map(select(
          .id == $collection_id and
          .items["Warehouse/dummy"].name == $freight
        ))) as $collections |
      if ($collections | length) == 1 then
        $collections[0].verificationHistory[0].analysisRun.name // empty
      else
        empty
      end
    ')"
  [ -n "${analysis_run}" ] ||
    sit_fail "Stage ${project}/${stage} has no AnalysisRun for exact collection ${collection_id}"
  kubectl -n "${project}" get analysisrun "${analysis_run}" -o json >"${output}"
  jq -e \
    --arg phase "${expected_phase}" \
    --arg stage "${stage}" \
    --arg collection "${collection_id}" '
      .status.phase == $phase and
      .metadata.labels["kargo.akuity.io/stage"] == $stage and
      .metadata.labels["kargo.akuity.io/freight-collection"] == $collection
    ' "${output}" >/dev/null
}

kargo_check_git_tag() {
  local project="$1"
  local landscape="$2"
  local expected_tag="$3"
  local path="platforms/${project}/landscapes/${landscape}/dummy.yaml"
  [ "$(git -C "${FLEET_BARE}" show "refs/heads/main:${path}" | yq -r '.pin.tag')" = "${expected_tag}" ]
}

kargo_wait_git_tag() {
  local project="$1"
  local landscape="$2"
  local expected_tag="$3"
  sit_wait_for 60 "Kargo git push to set ${project}/${landscape} pin.tag=${expected_tag}" \
    kargo_check_git_tag "${project}" "${landscape}" "${expected_tag}"
}

kargo_auto_promote_and_verify() {
  local project="$1"
  local landscape="$2"
  local freight="$3"
  local tag="$4"
  local prefix="$5"
  local stage
  stage="$(kargo_stage_name "${project}" "${landscape}")"
  kargo_refresh_stage "${project}" "${stage}"
  kargo_wait_promotion_succeeded "${project}" "${stage}" "${freight}" \
    "${report}/${prefix}-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${stage}" "${freight}" "${report}/${prefix}-promotion.json" \
    Successful "${report}/${prefix}-stage.json" \
    "${report}/${prefix}-reconciliation.json"
  kargo_wait_git_tag "${project}" "${landscape}" "${tag}"
}

kargo_runtime_trace_f1() {
  local project='canary'
  local tag='1.1.1'
  local pichu pikachu raichu ampharos freight
  pichu="$(kargo_stage_name "${project}" pichu)"
  pikachu="$(kargo_stage_name "${project}" pikachu)"
  raichu="$(kargo_stage_name "${project}" raichu)"
  ampharos="$(kargo_stage_name "${project}" ampharos)"

  kargo_seed_freight "${project}" fleet-sit-f1 "${tag}" \
    "${report}/kargo-runtime-f1-freight-created.json"
  freight="$(jq -r '.metadata.name' "${report}/kargo-runtime-f1-freight-created.json")"

  kargo_auto_promote_and_verify "${project}" pichu "${freight}" "${tag}" kargo-runtime-f1-pichu
  jq -e --arg freight "${freight}" \
    "${KARGO_STAGE_PREDICATE_PREAMBLE}"'
    $collection != null and
    $verification.phase == "Successful" and
    $verification.analysisRun == null
  ' "${report}/kargo-runtime-f1-pichu-stage.json" >/dev/null
  kargo_auto_promote_and_verify "${project}" raichu "${freight}" "${tag}" kargo-runtime-f1-raichu
  jq -e --arg freight "${freight}" \
    "${KARGO_STAGE_PREDICATE_PREAMBLE}"'
    $collection != null and
    $verification.phase == "Successful" and
    $verification.analysisRun == null
  ' "${report}/kargo-runtime-f1-raichu-stage.json" >/dev/null

  kargo_refresh_stage "${project}" "${pikachu}"
  sit_wait_for 60 'manual pikachu Stage to report auto-promotion disabled' \
    kargo_check_auto_enabled "${project}" "${pikachu}" false
  kargo_assert_no_promotion_for 15 "${project}" "${pikachu}" "${freight}" \
    'manual gate has no ProjectConfig policy' \
    "${report}/kargo-runtime-f1-pikachu-manual-hold.json"
  kargo_capture_missing_promotion_steps_denial "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f1-pikachu-missing-steps-denial.json"
  kargo_create_manual_promotion "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f1-pikachu-manual-promotion-created.json"
  kargo_wait_promotion_succeeded "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f1-pikachu-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f1-pikachu-promotion.json" Successful \
    "${report}/kargo-runtime-f1-pikachu-stage.json" \
    "${report}/kargo-runtime-f1-pikachu-reconciliation.json"
  kargo_wait_git_tag "${project}" pikachu "${tag}"
  kargo_capture_current_analysis_run "${project}" "${pikachu}" "${freight}" Successful \
    "${report}/kargo-runtime-f1-canary-smoke-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-f1-pikachu-reconciliation.json")"

  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_assert_no_promotion_for 12 "${project}" "${ampharos}" "${freight}" \
    'verification succeeded but the 15m upstream soak is not satisfied' \
    "${report}/kargo-runtime-f1-early-hold.json"
  kargo_capture_promotion_denial "${project}" "${ampharos}" "${freight}" \
    'early ampharos request before upstream soak' \
    "${report}/kargo-runtime-f1-early-denial.json"

  kargo_backdate_freight_stage "${project}" "${freight}" "${pikachu}" 960 \
    "${report}/kargo-runtime-f1-pikachu-backdate.json"
  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_assert_no_promotion_for 12 "${project}" "${ampharos}" "${freight}" \
    'availabilityStrategy All still lacks raichu soak' \
    "${report}/kargo-runtime-f1-one-member-hold.json"
  kargo_capture_promotion_denial "${project}" "${ampharos}" "${freight}" \
    'only pikachu has satisfied the per-upstream soak under All' \
    "${report}/kargo-runtime-f1-one-member-denial.json"

  kargo_backdate_freight_stage "${project}" "${freight}" "${raichu}" 960 \
    "${report}/kargo-runtime-f1-raichu-backdate.json"
  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_wait_promotion_succeeded "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-f1-ampharos-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-f1-ampharos-promotion.json" Successful \
    "${report}/kargo-runtime-f1-ampharos-stage.json" \
    "${report}/kargo-runtime-f1-ampharos-reconciliation.json"
  kargo_wait_git_tag "${project}" ampharos "${tag}"
  kargo_capture_current_analysis_run "${project}" "${ampharos}" "${freight}" Successful \
    "${report}/kargo-runtime-f1-canary-analysis-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-f1-ampharos-reconciliation.json")"
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f1-freight-final.json"
  jq -e \
    --arg pichu "${pichu}" --arg pikachu "${pikachu}" \
    --arg raichu "${raichu}" --arg ampharos "${ampharos}" '
      .status.verifiedIn[$pichu].verifiedAt != null and
      .status.verifiedIn[$pikachu].verifiedAt != null and
      .status.verifiedIn[$raichu].verifiedAt != null and
      .status.verifiedIn[$ampharos].verifiedAt != null
    ' "${report}/kargo-runtime-f1-freight-final.json" >/dev/null

  jq -n \
    --arg freight "${freight}" --arg tag "${tag}" \
    --slurpfile hold "${report}/kargo-runtime-f1-pikachu-manual-hold.json" \
    --slurpfile missingSteps "${report}/kargo-runtime-f1-pikachu-missing-steps-denial.json" \
    --slurpfile early "${report}/kargo-runtime-f1-early-denial.json" \
    --slurpfile oneMember "${report}/kargo-runtime-f1-one-member-denial.json" \
    --slurpfile pikachuBackdate "${report}/kargo-runtime-f1-pikachu-backdate.json" \
    --slurpfile raichuBackdate "${report}/kargo-runtime-f1-raichu-backdate.json" \
    --slurpfile final "${report}/kargo-runtime-f1-freight-final.json" '
      {
        trace:"f1-verification-before-soak",freight:$freight,tag:$tag,
        pichuAuto:true,raichuAuto:true,pikachuManualHold:$hold[0],
        missingManualStepsDenial:$missingSteps[0],
        explicitPikachuPromotion:true,canarySmoke:"Successful",
        earlyDenial:$early[0],singleBackdateDenial:$oneMember[0],
        backdates:[$pikachuBackdate[0],$raichuBackdate[0]],
        ampharosAutoAfterBothUpstreams:true,canaryAnalysis:"Successful",
        finalFreightStatus:$final[0].status
      }
    ' >"${report}/kargo-runtime-f1-trace.json"
}

kargo_runtime_trace_f2() {
  local project='canary'
  local tag='2.2.2'
  local pikachu raichu ampharos freight old_verification_id f2_collection_id
  local since_after_backdate since_after_reverify reverify_finished_at
  local reverify_succeeded_epoch ampharos_created_epoch immediate_elapsed
  pikachu="$(kargo_stage_name "${project}" pikachu)"
  raichu="$(kargo_stage_name "${project}" raichu)"
  ampharos="$(kargo_stage_name "${project}" ampharos)"

  kargo_seed_freight "${project}" fleet-sit-f2 "${tag}" \
    "${report}/kargo-runtime-f2-freight-created.json"
  freight="$(jq -r '.metadata.name' "${report}/kargo-runtime-f2-freight-created.json")"
  kargo_auto_promote_and_verify "${project}" pichu "${freight}" "${tag}" kargo-runtime-f2-pichu
  kargo_auto_promote_and_verify "${project}" raichu "${freight}" "${tag}" kargo-runtime-f2-raichu

  kargo_set_analysis_outcome "${project}" canary-smoke fail \
    "${report}/kargo-runtime-f2-analysis-outcome-fail.json"
  kargo_create_manual_promotion "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f2-pikachu-manual-promotion-created.json"
  kargo_wait_promotion_succeeded "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f2-pikachu-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f2-pikachu-promotion.json" Failed \
    "${report}/kargo-runtime-f2-pikachu-failed-stage.json" \
    "${report}/kargo-runtime-f2-pikachu-failed-reconciliation.json"
  kargo_wait_git_tag "${project}" pikachu "${tag}"
  f2_collection_id="$(jq -r '.freightCollectionId' \
    "${report}/kargo-runtime-f2-pikachu-failed-reconciliation.json")"
  kargo_capture_current_analysis_run "${project}" "${pikachu}" "${freight}" Failed \
    "${report}/kargo-runtime-f2-canary-smoke-failed-analysisrun.json" \
    "${f2_collection_id}"
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f2-freight-after-failure.json"
  jq -e --arg stage "${pikachu}" '.status.verifiedIn[$stage] == null' \
    "${report}/kargo-runtime-f2-freight-after-failure.json" >/dev/null

  kargo_backdate_freight_stage "${project}" "${freight}" "${pikachu}" 1200 \
    "${report}/kargo-runtime-f2-pikachu-backdate.json"
  kargo_backdate_freight_stage "${project}" "${freight}" "${raichu}" 1200 \
    "${report}/kargo-runtime-f2-raichu-backdate.json"
  since_after_backdate="$(jq -r '.after' "${report}/kargo-runtime-f2-pikachu-backdate.json")"
  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_assert_no_promotion_for 12 "${project}" "${ampharos}" "${freight}" \
    'full residency cannot substitute for failed canary-smoke verification' \
    "${report}/kargo-runtime-f2-failed-analysis-hold.json"
  kargo_capture_promotion_denial "${project}" "${ampharos}" "${freight}" \
    'failed analysis remains an independent availability gate after full residency' \
    "${report}/kargo-runtime-f2-failed-analysis-denial.json"

  kargo_set_analysis_outcome "${project}" canary-smoke pass \
    "${report}/kargo-runtime-f2-analysis-outcome-pass.json"
  old_verification_id="$(jq -er \
    --arg freight "${freight}" --arg collection_id "${f2_collection_id}" '
      ((.status.freightHistory // []) |
        map(select(
          .id == $collection_id and
          .items["Warehouse/dummy"].name == $freight
        ))) as $collections |
      $collections | select(length == 1) | .[0].verificationHistory[0] |
      select(.phase == "Failed") | .id |
      select(type == "string" and length > 0)
    ' "${report}/kargo-runtime-f2-pikachu-failed-stage.json")"
  [ -n "${old_verification_id}" ] && [ "${old_verification_id}" != 'null' ] ||
    sit_fail 'failed f2 verification has no ID for reverify'
  kubectl -n "${project}" annotate stage "${pikachu}" \
    "kargo.akuity.io/reverify=${old_verification_id}" --overwrite \
    >"${report}/kargo-runtime-f2-reverify-request.txt"
  kargo_wait_verified "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f2-pikachu-reverified-stage.json"
  kargo_capture_current_analysis_run "${project}" "${pikachu}" "${freight}" Successful \
    "${report}/kargo-runtime-f2-canary-smoke-reverified-analysisrun.json" \
    "${f2_collection_id}"
  reverify_finished_at="$(jq -er \
    --arg freight "${freight}" --arg collection_id "${f2_collection_id}" '
      ((.status.freightHistory // []) |
        map(select(
          .id == $collection_id and
          .items["Warehouse/dummy"].name == $freight
        ))) as $collections |
      $collections | select(length == 1) | .[0].verificationHistory[0] |
      select(.phase == "Successful") | .finishTime |
      select(type == "string" and length > 0)
    ' "${report}/kargo-runtime-f2-pikachu-reverified-stage.json")"
  reverify_succeeded_epoch="$(date -u -d "${reverify_finished_at}" +%s)"
  since_after_reverify="$(kubectl -n "${project}" get freight "${freight}" -o json |
    jq -r --arg stage "${pikachu}" '.status.currentlyIn[$stage].since')"
  [ "${since_after_reverify}" = "${since_after_backdate}" ] ||
    sit_fail 'successful re-verification reset the persisted promotion-time soak clock'

  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_wait_promotion_succeeded "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-f2-ampharos-promotion.json"
  ampharos_created_epoch="$(date -u -d \
    "$(jq -r '.[-1].metadata.creationTimestamp' "${report}/kargo-runtime-f2-ampharos-promotion.json")" +%s)"
  immediate_elapsed=$((ampharos_created_epoch - reverify_succeeded_epoch))
  [ "${immediate_elapsed}" -ge 0 ] && [ "${immediate_elapsed}" -le 90 ] ||
    sit_fail "ampharos did not become immediately eligible after re-verification (${immediate_elapsed}s)"
  kargo_drive_post_promotion_verification \
    "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-f2-ampharos-promotion.json" Successful \
    "${report}/kargo-runtime-f2-ampharos-stage.json" \
    "${report}/kargo-runtime-f2-ampharos-reconciliation.json"
  kargo_wait_git_tag "${project}" ampharos "${tag}"
  kargo_capture_current_analysis_run "${project}" "${ampharos}" "${freight}" Successful \
    "${report}/kargo-runtime-f2-canary-analysis-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-f2-ampharos-reconciliation.json")"
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f2-freight-final.json"

  jq -n \
    --arg freight "${freight}" --arg tag "${tag}" \
    --arg failedVerificationID "${old_verification_id}" \
    --arg sinceBeforeReverify "${since_after_backdate}" \
    --arg sinceAfterReverify "${since_after_reverify}" \
    --argjson immediateEligibilitySeconds "${immediate_elapsed}" \
    --slurpfile denial "${report}/kargo-runtime-f2-failed-analysis-denial.json" \
    --slurpfile final "${report}/kargo-runtime-f2-freight-final.json" '
      {
        trace:"f2-verification-after-soak",freight:$freight,tag:$tag,
        canarySmokeInitialPhase:"Failed",failedVerificationID:$failedVerificationID,
        residencySatisfiedBeforeVerification:true,failedAnalysisDenial:$denial[0],
        canarySmokeReverifiedPhase:"Successful",
        sinceBeforeReverify:$sinceBeforeReverify,
        sinceAfterReverify:$sinceAfterReverify,
        soakClockUnchanged:($sinceBeforeReverify == $sinceAfterReverify),
        immediateAmpharosEligibilitySeconds:$immediateEligibilitySeconds,
        canaryAnalysis:"Successful",finalFreightStatus:$final[0].status
      }
    ' >"${report}/kargo-runtime-f2-trace.json"
}

kargo_runtime_trace_f3() {
  local project='canary'
  local tag='3.3.3'
  local pichu pikachu raichu ampharos freight policy_patch
  local pikachu_since raichu_since
  pichu="$(kargo_stage_name "${project}" pichu)"
  pikachu="$(kargo_stage_name "${project}" pikachu)"
  raichu="$(kargo_stage_name "${project}" raichu)"
  ampharos="$(kargo_stage_name "${project}" ampharos)"

  kargo_seed_freight "${project}" fleet-sit-f3 "${tag}" \
    "${report}/kargo-runtime-f3-freight-created.json"
  freight="$(jq -r '.metadata.name' "${report}/kargo-runtime-f3-freight-created.json")"
  kargo_auto_promote_and_verify "${project}" pichu "${freight}" "${tag}" kargo-runtime-f3-pichu
  kargo_auto_promote_and_verify "${project}" raichu "${freight}" "${tag}" kargo-runtime-f3-raichu
  kargo_backdate_freight_stage "${project}" "${freight}" "${raichu}" 1200 \
    "${report}/kargo-runtime-f3-raichu-backdate.json"
  raichu_since="$(jq -r '.after' "${report}/kargo-runtime-f3-raichu-backdate.json")"
  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_assert_no_promotion_for 12 "${project}" "${ampharos}" "${freight}" \
    'only the raichu rendezvous member carries the Freight' \
    "${report}/kargo-runtime-f3-single-member-hold.json"
  # Bind the refusal to `availabilityStrategy: All` rather than to a generic
  # controller delay: the exact Freight must be verified AND soaked since the
  # backdated timestamp in raichu (not merely newly resident with a non-null
  # since), and absent from pikachu, at the moment the live webhook refuses.
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f3-single-member-freight.json"
  jq -e --arg pikachu "${pikachu}" --arg raichu "${raichu}" \
    --arg raichuSince "${raichu_since}" '
    .status.verifiedIn[$raichu].verifiedAt != null and
    .status.currentlyIn[$raichu].since == $raichuSince and
    (.status.verifiedIn[$pikachu] // null) == null and
    (.status.currentlyIn[$pikachu] // null) == null
  ' "${report}/kargo-runtime-f3-single-member-freight.json" >/dev/null ||
    sit_fail 'the f3 single-member refusal is not causally bound to a soaked, backdated raichu residency with pikachu absent'
  kargo_capture_promotion_denial "${project}" "${ampharos}" "${freight}" \
    'availabilityStrategy All rejects Freight present in only raichu' \
    "${report}/kargo-runtime-f3-single-member-denial.json"

  policy_patch="$(jq -cn \
    --arg pichu "${pichu}" \
    --arg raichu "${raichu}" \
    --arg pikachu "${pikachu}" '
      {spec:{promotionPolicies:[
        {autoPromotionEnabled:true,stageSelector:{name:$pichu}},
        {autoPromotionEnabled:true,stageSelector:{name:$raichu}},
        {autoPromotionEnabled:true,stageSelector:{name:$pikachu}}
      ]}}
    ')"
  kubectl -n "${project}" patch projectconfig "${project}" --type merge \
    -p "${policy_patch}" -o json >"${report}/kargo-runtime-f3-policy-flip.json"
  # Exactly the three enabled selectors and nothing else. A superset, a
  # disabled entry, or a surviving ampharos policy would silently weaken the
  # atomic flip into a partial one.
  jq -e \
    --arg pichu "${pichu}" --arg pikachu "${pikachu}" \
    --arg raichu "${raichu}" --arg ampharos "${ampharos}" '
    (.spec.promotionPolicies // []) as $policies |
    ($policies | map(.stageSelector.name) | sort) as $selectors |
    ($policies |
      map(select(.autoPromotionEnabled == true) | .stageSelector.name) | sort) as $enabled |
    ($policies | length) == 3 and
    $selectors == ([$pichu,$pikachu,$raichu] | sort) and
    $enabled == $selectors and
    ($selectors | index($ampharos)) == null
  ' "${report}/kargo-runtime-f3-policy-flip.json" >/dev/null ||
    sit_fail 'the atomic f3 ProjectConfig patch is not exactly the three enabled pichu/pikachu/raichu selectors with no ampharos policy'

  kargo_refresh_stage "${project}" "${pikachu}"
  kargo_refresh_stage "${project}" "${ampharos}"
  sit_wait_for 60 'flipped pikachu policy to become active' \
    kargo_check_auto_enabled "${project}" "${pikachu}" true
  sit_wait_for 60 'removed ampharos policy to become inactive' \
    kargo_check_auto_enabled "${project}" "${ampharos}" false
  kargo_wait_promotion_succeeded "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f3-pikachu-auto-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-f3-pikachu-auto-promotion.json" Successful \
    "${report}/kargo-runtime-f3-pikachu-stage.json" \
    "${report}/kargo-runtime-f3-pikachu-reconciliation.json"
  kargo_wait_git_tag "${project}" pikachu "${tag}"
  kargo_capture_current_analysis_run "${project}" "${pikachu}" "${freight}" Successful \
    "${report}/kargo-runtime-f3-canary-smoke-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-f3-pikachu-reconciliation.json")"
  kargo_backdate_freight_stage "${project}" "${freight}" "${pikachu}" 1200 \
    "${report}/kargo-runtime-f3-pikachu-backdate.json"

  # Destroying path. Prove availability FIRST: a no-Promotion hold taken before
  # the webhook has admitted the Freight would be vacuously true because
  # pikachu might simply not be verified yet.
  pikachu_since="$(jq -r '.after' "${report}/kargo-runtime-f3-pikachu-backdate.json")"
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f3-rendezvous-membership.json"
  jq -e \
    --arg pikachu "${pikachu}" --arg raichu "${raichu}" \
    --arg pikachuSince "${pikachu_since}" --arg raichuSince "${raichu_since}" '
    .status.verifiedIn[$pikachu].verifiedAt != null and
    .status.verifiedIn[$raichu].verifiedAt != null and
    .status.currentlyIn[$pikachu].since == $pikachuSince and
    .status.currentlyIn[$raichu].since == $raichuSince
  ' "${report}/kargo-runtime-f3-rendezvous-membership.json" >/dev/null ||
    sit_fail 'both f3 rendezvous members are not verified and aged for the exact Freight'
  kargo_capture_promotion_dry_run_acceptance "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-f3-ampharos-available-dry-run.json"
  [ "$(kargo_promotion_count "${project}" "${ampharos}" "${freight}")" -eq 0 ] ||
    sit_fail 'the admitted ampharos dry run persisted a Promotion'
  kargo_refresh_stage "${project}" "${ampharos}"
  kargo_check_auto_enabled "${project}" "${ampharos}" false ||
    sit_fail 'ampharos auto-promotion was enabled at the start of the policy-removal hold'
  kargo_assert_no_promotion_for 15 "${project}" "${ampharos}" "${freight}" \
    'Freight is available but the ampharos auto-promotion policy was removed' \
    "${report}/kargo-runtime-f3-ampharos-policy-hold.json"
  kargo_check_auto_enabled "${project}" "${ampharos}" false ||
    sit_fail 'ampharos auto-promotion was re-enabled during the policy-removal hold'
  [ "$(kargo_promotion_count "${project}" "${ampharos}" "${freight}")" -eq 0 ] ||
    sit_fail 'ampharos auto-promoted after its policy was removed'
  kubectl -n "${project}" get freight "${freight}" -o json \
    >"${report}/kargo-runtime-f3-freight-final.json"

  jq -n \
    --arg freight "${freight}" --arg tag "${tag}" \
    --arg pikachu "${pikachu}" --arg raichu "${raichu}" \
    --slurpfile singleMemberFreight "${report}/kargo-runtime-f3-single-member-freight.json" \
    --slurpfile denial "${report}/kargo-runtime-f3-single-member-denial.json" \
    --slurpfile policy "${report}/kargo-runtime-f3-policy-flip.json" \
    --slurpfile reconciliation "${report}/kargo-runtime-f3-pikachu-reconciliation.json" \
    --slurpfile membership "${report}/kargo-runtime-f3-rendezvous-membership.json" \
    --slurpfile hold "${report}/kargo-runtime-f3-ampharos-policy-hold.json" \
    --slurpfile available "${report}/kargo-runtime-f3-ampharos-available-dry-run.json" '
      ($singleMemberFreight[0].status) as $singleMember |
      {
        trace:"f3-single-member-and-policy-flip",freight:$freight,tag:$tag,
        singleMemberFreightState:{
          verifiedInRaichuAt:($singleMember.verifiedIn[$raichu].verifiedAt),
          residentInRaichuSince:($singleMember.currentlyIn[$raichu].since),
          verifiedInPikachu:($singleMember.verifiedIn[$pikachu] // null),
          residentInPikachu:($singleMember.currentlyIn[$pikachu] // null)
        },
        singleMemberDenial:$denial[0],
        atomicPolicyMutation:$policy[0].spec.promotionPolicies,
        pikachuAutoAfterPolicyAddition:true,
        pikachuPostPromotionReconciliation:$reconciliation[0],
        rendezvousMembership:$membership[0].status,
        ampharosAvailableByLiveWebhook:true,
        ampharosDryRunPromotion:$available[0],
        ampharosAdmissionProvenBeforeHold:true,
        ampharosHeldAfterPolicyRemoval:$hold[0]
      }
    ' >"${report}/kargo-runtime-f3-trace.json"
}

kargo_runtime_install_soak_project() {
  local project='canary-sitsoak'
  local chart="${FLEET_SOURCE}/registry/charts/diene-platform"
  helm template "${project}" "${chart}" \
    --namespace "${project}" \
    --values "${validation_dir}/fixtures/kargo-runtime/soak.platform.yaml" \
    --set-string "fleet.repoURL=${FLEET_REPO_URL}" \
    --set-string 'oci.registry=registry.sit.invalid' |
    yq 'select(.apiVersion == "kargo.akuity.io/v1alpha1")' \
      >"${report}/kargo-runtime-soak-rendered.yaml"
  yq ea -o=json '[.]' "${report}/kargo-runtime-soak-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/kargo-runtime-soak-rendered.json"
  jq -e '
    ([.[] | select(.kind == "Stage")] | length) == 3 and
    ([.[] | select(.kind == "Stage" and .metadata.name == "canary-sitsoak-dummy-ampharos")][0] |
      .spec.requestedFreight[0].sources.stages == [
        "canary-sitsoak-dummy-pikachu", "canary-sitsoak-dummy-raichu"
      ] and
      .spec.requestedFreight[0].sources.availabilityStrategy == "All" and
      .spec.requestedFreight[0].sources.requiredSoakTime == "90s" and
      .spec.verification.analysisTemplates == [{name:"canary-analysis"}]) and
    ([.[] | select(.kind == "ProjectConfig")][0].spec.promotionPolicies |
      map(select(.autoPromotionEnabled == true).stageSelector.name) | sort) == [
        "canary-sitsoak-dummy-ampharos",
        "canary-sitsoak-dummy-raichu"
      ]
  ' "${KARGO_RUNTIME_DIR}/kargo-runtime-soak-rendered.json" >/dev/null

  yq 'select(.kind == "Project")' "${report}/kargo-runtime-soak-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/soak-project.yaml"
  yq 'select(.kind != "Project")' "${report}/kargo-runtime-soak-rendered.yaml" \
    >"${KARGO_RUNTIME_DIR}/soak-namespaced.yaml"
  kubectl apply -f "${KARGO_RUNTIME_DIR}/soak-project.yaml"
  kubectl wait --for=condition=Ready \
    project.kargo.akuity.io/${project} --timeout=180s
  kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/${project} --timeout=180s
  kargo_render_analysis_fixture "${project}" "${report}/kargo-runtime-analysis-soak.yaml"
  kubectl apply -f "${report}/kargo-runtime-analysis-soak.yaml"
  kubectl apply -f "${KARGO_RUNTIME_DIR}/soak-namespaced.yaml"
}

kargo_runtime_trace_wall_clock_soak() {
  local project='canary-sitsoak'
  local tag='4.4.4'
  local pikachu raichu ampharos freight since since_epoch promotion_epoch lower_bound elapsed
  local pre_boundary_token
  pikachu="$(kargo_stage_name "${project}" pikachu)"
  raichu="$(kargo_stage_name "${project}" raichu)"
  ampharos="$(kargo_stage_name "${project}" ampharos)"
  kargo_seed_freight "${project}" fleet-sit-f4 "${tag}" \
    "${report}/kargo-runtime-soak-freight-created.json"
  freight="$(jq -r '.metadata.name' "${report}/kargo-runtime-soak-freight-created.json")"
  kargo_auto_promote_and_verify "${project}" raichu "${freight}" "${tag}" kargo-runtime-soak-raichu
  kargo_refresh_stage "${project}" "${pikachu}"
  sit_wait_for 60 '90s fixture pikachu Stage to remain manual' \
    kargo_check_auto_enabled "${project}" "${pikachu}" false
  kargo_create_manual_promotion "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-soak-pikachu-manual-promotion-created.json"
  kargo_wait_promotion_succeeded "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-soak-pikachu-promotion.json"
  kargo_drive_post_promotion_verification \
    "${project}" "${pikachu}" "${freight}" \
    "${report}/kargo-runtime-soak-pikachu-promotion.json" Successful \
    "${report}/kargo-runtime-soak-pikachu-stage.json" \
    "${report}/kargo-runtime-soak-pikachu-reconciliation.json"
  kargo_wait_git_tag "${project}" pikachu "${tag}"
  kargo_capture_current_analysis_run "${project}" "${pikachu}" "${freight}" Successful \
    "${report}/kargo-runtime-soak-canary-smoke-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-soak-pikachu-reconciliation.json")"
  since="$(kubectl -n "${project}" get freight "${freight}" -o json |
    jq -r --arg stage "${pikachu}" '.status.currentlyIn[$stage].since')"
  since_epoch="$(date -u -d "${since}" +%s)"
  lower_bound=$((since_epoch + 90))
  kargo_refresh_stage_recorded "${project}" "${ampharos}" \
    "${report}/kargo-runtime-soak-pre-boundary-refresh.json"
  pre_boundary_token="$(jq -r '.token' \
    "${report}/kargo-runtime-soak-pre-boundary-refresh.json")"
  kargo_assert_no_promotion_for 12 "${project}" "${ampharos}" "${freight}" \
    'real 90s wall-clock soak has not elapsed from promotion-time since' \
    "${report}/kargo-runtime-soak-early-hold.json"
  kargo_capture_promotion_denial "${project}" "${ampharos}" "${freight}" \
    'real wall-clock lower bound before 90s' \
    "${report}/kargo-runtime-soak-early-denial.json"

  # Kargo v1.9.10 emits no soak-expiry event and requeues a settled Stage every
  # five minutes. Cross the persisted boundary on the real clock, prove the
  # webhook admits before any mutation, then issue one supported wake-up.
  kargo_wait_wall_clock_boundary "${since}" "${lower_bound}" \
    'persisted Pikachu residency plus the real 90s soak' \
    "${report}/kargo-runtime-soak-boundary-wait.json"
  kargo_capture_soak_pre_stimulus \
    "${project}" "${ampharos}" "${pikachu}" "${raichu}" "${freight}" \
    "${since}" "${lower_bound}" "${pre_boundary_token}" \
    "${report}/kargo-runtime-soak-pre-stimulus.json"
  kargo_capture_promotion_dry_run_acceptance \
    "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-soak-ampharos-available-dry-run.json"
  kargo_refresh_stage_recorded "${project}" "${ampharos}" \
    "${report}/kargo-runtime-soak-post-boundary-refresh.json"
  jq -e \
    --arg previousToken "${pre_boundary_token}" \
    --argjson lowerBoundEpoch "${lower_bound}" \
    --slurpfile dryRun \
    "${report}/kargo-runtime-soak-ampharos-available-dry-run.json" '
      .token != $previousToken and .previousToken == $previousToken and
      .lastHandledRefresh == .token and
      (.annotatedAt | fromdateiso8601) == .annotatedEpoch and
      (.acknowledgedAt | fromdateiso8601) == .acknowledgedEpoch and
      .annotatedEpoch >= $lowerBoundEpoch and
      .acknowledgedEpoch >= $lowerBoundEpoch and
      .acknowledgedEpoch >= .annotatedEpoch and
      $dryRun[0].fleetSitDryRun.admitted == true and
      $dryRun[0].fleetSitDryRun.serverSide == true and
      $dryRun[0].fleetSitDryRun.admittedEpoch <= .annotatedEpoch
    ' "${report}/kargo-runtime-soak-post-boundary-refresh.json" >/dev/null ||
    sit_fail 'the distinct post-boundary refresh was early, unacknowledged, or preceded admission'
  kargo_wait_promotion_succeeded "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-soak-ampharos-promotion.json"
  promotion_epoch="$(date -u -d \
    "$(jq -r '.[-1].metadata.creationTimestamp' "${report}/kargo-runtime-soak-ampharos-promotion.json")" +%s)"
  elapsed=$((promotion_epoch - since_epoch))
  [ "${promotion_epoch}" -ge "${lower_bound}" ] ||
    sit_fail "the real controller promoted before the 90s promotion-time lower bound (${elapsed}s)"
  [ "${elapsed}" -le 180 ] ||
    sit_fail "the 90s wall-clock strengthener exceeded its bounded 180s upper window (${elapsed}s)"
  kargo_drive_post_promotion_verification \
    "${project}" "${ampharos}" "${freight}" \
    "${report}/kargo-runtime-soak-ampharos-promotion.json" Successful \
    "${report}/kargo-runtime-soak-ampharos-stage.json" \
    "${report}/kargo-runtime-soak-ampharos-reconciliation.json"
  kargo_wait_git_tag "${project}" ampharos "${tag}"
  kargo_capture_current_analysis_run "${project}" "${ampharos}" "${freight}" Successful \
    "${report}/kargo-runtime-soak-canary-analysis-analysisrun.json" \
    "$(jq -r '.freightCollectionId' "${report}/kargo-runtime-soak-ampharos-reconciliation.json")"

  jq -n \
    --arg freight "${freight}" --arg tag "${tag}" \
    --arg promotionTimeSince "${since}" \
    --argjson requiredSoakSeconds 90 \
    --argjson lowerBoundEpoch "${lower_bound}" \
    --argjson observedPromotionAfterSeconds "${elapsed}" \
    --slurpfile early "${report}/kargo-runtime-soak-early-denial.json" \
    --slurpfile earlyHold "${report}/kargo-runtime-soak-early-hold.json" \
    --slurpfile boundaryWait "${report}/kargo-runtime-soak-boundary-wait.json" \
    --slurpfile preStimulus "${report}/kargo-runtime-soak-pre-stimulus.json" \
    --slurpfile preBoundaryRefresh \
    "${report}/kargo-runtime-soak-pre-boundary-refresh.json" \
    --slurpfile dryRun \
    "${report}/kargo-runtime-soak-ampharos-available-dry-run.json" \
    --slurpfile postBoundaryRefresh \
    "${report}/kargo-runtime-soak-post-boundary-refresh.json" '
      {
        trace:"real-wall-clock-90s-strengthener",freight:$freight,tag:$tag,
        promotionTimeSince:$promotionTimeSince,
        requiredSoakSeconds:$requiredSoakSeconds,
        lowerBoundEpoch:$lowerBoundEpoch,
        observedPromotionAfterSeconds:$observedPromotionAfterSeconds,
        earlyWebhookDenial:$early[0],
        earlyNoPromotionHold:$earlyHold[0],
        boundaryWait:$boundaryWait[0],
        preStimulus:$preStimulus[0],
        preBoundaryRefresh:$preBoundaryRefresh[0],
        postBoundaryDryRunAdmitted:$dryRun[0].fleetSitDryRun.admitted,
        postBoundaryDryRunPromotion:$dryRun[0],
        postBoundaryRefresh:$postBoundaryRefresh[0],
        lowerBoundSatisfied:($observedPromotionAfterSeconds >= $requiredSoakSeconds),
        controllerClockWasNotPatched:true,
        stimulusAfterLowerBound:
          ($postBoundaryRefresh[0].annotatedEpoch >= $lowerBoundEpoch),
        earlyRefreshDidNotPromote:
          ($earlyHold[0].promotionCount == 0 and $early[0].admitted == false)
      }
    ' >"${report}/kargo-runtime-soak-trace.json"
}

kargo_runtime_finalize_git_oracle() {
  local final_sha
  final_sha="$(git -C "${FLEET_BARE}" rev-parse refs/heads/main)"
  git -C "${FLEET_BARE}" diff --no-ext-diff --unified=0 \
    "${KARGO_RUNTIME_GIT_BASELINE}" "${final_sha}" -- \
    platforms/canary/landscapes \
    platforms/canary-sitsoak/landscapes \
    >"${report}/kargo-runtime-git.diff"
  [ -s "${report}/kargo-runtime-git.diff" ] || sit_fail 'Kargo runtime produced no git row delta'
  if rg '^[+-]' "${report}/kargo-runtime-git.diff" |
    rg -v '^(---|\+\+\+|[-+]  tag: )' >"${KARGO_RUNTIME_DIR}/unexpected-git-delta.txt"; then
    sed -n '1,200p' "${KARGO_RUNTIME_DIR}/unexpected-git-delta.txt" >&2
    sit_fail 'Kargo promotion changed row bytes outside pin.tag'
  fi
  git -C "${FLEET_BARE}" diff --name-only \
    "${KARGO_RUNTIME_GIT_BASELINE}" "${final_sha}" -- \
    platforms/canary/landscapes platforms/canary-sitsoak/landscapes |
    LC_ALL=C sort >"${KARGO_RUNTIME_DIR}/kargo-runtime-changed-paths.txt"
  printf '%s\n' \
    platforms/canary/landscapes/ampharos/dummy.yaml \
    platforms/canary/landscapes/pichu/dummy.yaml \
    platforms/canary/landscapes/pikachu/dummy.yaml \
    platforms/canary/landscapes/raichu/dummy.yaml \
    platforms/canary-sitsoak/landscapes/ampharos/dummy.yaml \
    platforms/canary-sitsoak/landscapes/pikachu/dummy.yaml \
    platforms/canary-sitsoak/landscapes/raichu/dummy.yaml |
    LC_ALL=C sort >"${KARGO_RUNTIME_DIR}/kargo-runtime-expected-paths.txt"
  cmp -s "${KARGO_RUNTIME_DIR}/kargo-runtime-expected-paths.txt" \
    "${KARGO_RUNTIME_DIR}/kargo-runtime-changed-paths.txt" ||
    sit_fail 'Kargo runtime did not change exactly the seven expected row files'
  git -C "${FLEET_BARE}" show \
    "${final_sha}:platforms/canary/landscapes/raichu/dummy.yaml" |
    sed -n '/^values:/,$p' >"${report}/kargo-runtime-raichu-values-after.yaml"
  cmp -s "${report}/kargo-runtime-raichu-values-before.yaml" \
    "${report}/kargo-runtime-raichu-values-after.yaml" ||
    sit_fail 'the human raichu values block changed during real Kargo promotions'
  git -C "${FLEET_BARE}" log --reverse --format='%H%x09%an%x09%ae%x09%s' \
    "${KARGO_RUNTIME_GIT_BASELINE}..${final_sha}" >"${report}/kargo-runtime-git-log.tsv"
  jq -n \
    --arg baseline "${KARGO_RUNTIME_GIT_BASELINE}" \
    --arg final "${final_sha}" \
    --rawfile paths "${KARGO_RUNTIME_DIR}/kargo-runtime-changed-paths.txt" \
    --rawfile diff "${report}/kargo-runtime-git.diff" '
      {
        baseline:$baseline,final:$final,
        changedPaths:($paths | split("\n") | map(select(length > 0))),
        onlyPinTagLinesChanged:true,
        raichuValuesBlockByteIdentical:true,
        diff:$diff
      }
    ' >"${report}/kargo-runtime-git-oracle.json"
}

kargo_runtime_collect_logs() {
  kubectl -n kargo get pods -o wide >"${report}/kargo-runtime-kargo-pods.txt"
  kubectl -n argo-rollouts get pods -o wide >"${report}/kargo-runtime-rollouts-pods.txt"
  kubectl -n canary get \
    freight,promotions,stages,warehouses,analysistemplates,analysisruns -o json \
    >"${report}/kargo-runtime-canary-objects.json"
  kubectl -n canary-sitsoak get \
    freight,promotions,stages,warehouses,analysistemplates,analysisruns -o json \
    >"${report}/kargo-runtime-soak-objects.json"
  kubectl -n kargo logs deployment/kargo-controller --all-containers --tail=-1 \
    >"${report}/kargo-runtime-controller.log" 2>&1
  kubectl -n kargo logs deployment/kargo-management-controller --all-containers --tail=-1 \
    >"${report}/kargo-runtime-management-controller.log" 2>&1
  kubectl -n kargo logs deployment/kargo-webhooks-server --all-containers --tail=-1 \
    >"${report}/kargo-runtime-webhooks-server.log" 2>&1
  kubectl -n argo-rollouts logs deployment/argo-rollouts --all-containers --tail=-1 \
    >"${report}/kargo-runtime-rollouts-controller.log" 2>&1
}

run_kargo_runtime_leg() {
  # L8 intentionally owns static objects only. Remove its Project and namespace
  # before installing the management controller so ownership is deterministic.
  kubectl delete project.kargo.akuity.io canary --ignore-not-found --wait=true --timeout=120s
  kubectl delete namespace canary --ignore-not-found --wait=true --timeout=180s
  kargo_runtime_prepare_artifacts
  kargo_runtime_install_rollouts
  kargo_runtime_install_kargo
  kargo_runtime_render_and_apply_primary
  kargo_runtime_trace_f1
  kargo_runtime_trace_f2
  kargo_runtime_trace_f3
  kargo_runtime_install_soak_project
  kargo_runtime_trace_wall_clock_soak
  kargo_runtime_finalize_git_oracle
  kargo_runtime_collect_logs

  jq -n \
    --arg kargoVersion "${KARGO_VERSION}" \
    --arg kargoImage "${KARGO_RUNTIME_IMAGE_REF}" \
    --arg chartDigest "${KARGO_CHART_DIGEST}" \
    --arg rolloutsVersion "${ROLLOUTS_VERSION}" \
    --arg rolloutsImage "${ROLLOUTS_RUNTIME_IMAGE_REF}" \
    --arg analysisImage "${ANALYSIS_RUNTIME_IMAGE_REF}" \
    --slurpfile f1 "${report}/kargo-runtime-f1-trace.json" \
    --slurpfile f2 "${report}/kargo-runtime-f2-trace.json" \
    --slurpfile f3 "${report}/kargo-runtime-f3-trace.json" \
    --slurpfile soak "${report}/kargo-runtime-soak-trace.json" \
    --slurpfile gitOracle "${report}/kargo-runtime-git-oracle.json" '
      {
        pinnedRuntime:{
          kargoVersion:$kargoVersion,kargoImage:$kargoImage,chartDigest:$chartDigest,
          rolloutsVersion:$rolloutsVersion,rolloutsImage:$rolloutsImage,
          analysisJobImage:$analysisImage
        },
        controllerClasses:[
          "Kargo controller","Kargo management-controller",
          "Kargo kubernetes-webhooks-server","Argo Rollouts controller"
        ],
        traces:{f1:$f1[0],f2:$f2[0],f3:$f3[0],wallClock:$soak[0]},
        gitPromotionOracle:$gitOracle[0],
        proven:[
          "pichu and raichu auto-promote under matching ProjectConfig policies",
          "pikachu holds with no policy and promotes only after an explicit webhook-admitted Promotion CR",
          "real git-clone/yaml-update/git-commit/git-push steps change only pin.tag and preserve the human values block byte-for-byte",
          "canary-smoke and canary-analysis execute as real Argo Rollouts Job-provider AnalysisRuns",
          "ampharos availabilityStrategy All rejects early and single-member Freight and admits only after pikachu plus raichu are verified and soaked",
          "failed analysis remains an independent gate after residency is satisfied",
          "verification does not reset Freight.status.currentlyIn[stage].since and eligibility is immediate when late verification succeeds",
          "adding the pikachu auto policy and removing the ampharos policy in one ProjectConfig patch flips their real runtime behavior",
          "the otherwise-identical 90s project respects a genuine promotion-time wall-clock lower bound, proved by pre-boundary webhook denial and post-boundary webhook admission before any new stimulus"
        ],
        residuals:[
          "literal passage of the production 15m duration remains unrun; persisted 15m-clock backdating proves both orderings and per-upstream comparison, and the same released controller code is wall-clock-strengthened at 90s",
          "Kargo v1.9.10 emits no soak-expiry event and requeues a settled Stage every five minutes, so the SIT wakes the Stage with one supported refresh after the boundary instead of measuring controller polling latency",
          "the Kargo API/UI approval surface is disabled; explicit Promotion CR creation exercises the Kubernetes admission and SubjectAccessReview surface",
          "Warehouse discovery against a reachable registry is unrun; Freight is seeded through the real webhook against subscriptions whose consumer-only runtime host is registry.sit.invalid"
        ],
        fallbackUsed:false
      }
    ' >"${report}/kargo-runtime-proof.json"
}

collect_final_evidence() {
  [ "${namespace_platform_ready}" -eq 1 ] || return 0
  [ -n "${report}" ] || return 0
  [ "${final_evidence_collected}" -eq 0 ] || return 0
  final_evidence_collected=1
  kubectl -n argocd get applications.argoproj.io -o json >"${report}/apps-final.json" 2>&1 || true
  kubectl -n argocd get applicationsets.argoproj.io -o yaml >"${report}/appsets-final.yaml" 2>&1 || true
  kubectl -n argocd get pods -o wide >"${report}/pods-final.txt" 2>&1 || true
  kubectl -n argocd get events --sort-by=.lastTimestamp >"${report}/events-final.txt" 2>&1 || true
  local workload
  for workload in \
    deployment/argocd-applicationset-controller \
    deployment/argocd-repo-server \
    deployment/argocd-server \
    statefulset/argocd-application-controller; do
    kubectl -n argocd logs "${workload}" --all-containers --tail=-1 \
      >"${report}/$(tr '/' '-' <<<"${workload}").log" 2>&1 || true
  done
  kubectl -n kargo logs deployment/kargo-controller --all-containers --tail=-1 \
    >"${report}/kargo-runtime-controller.log" 2>&1 || true
  kubectl -n kargo logs deployment/kargo-management-controller --all-containers --tail=-1 \
    >"${report}/kargo-runtime-management-controller.log" 2>&1 || true
  kubectl -n kargo logs deployment/kargo-webhooks-server --all-containers --tail=-1 \
    >"${report}/kargo-runtime-webhooks-server.log" 2>&1 || true
  kubectl -n argo-rollouts logs deployment/argo-rollouts --all-containers --tail=-1 \
    >"${report}/kargo-runtime-rollouts-controller.log" 2>&1 || true

  local -a kargo_final_paths=(
    'kargo-runtime-canary-stages-final.json'
    'kargo-runtime-canary-freight-final.json'
    'kargo-runtime-canary-promotions-final.json'
    'kargo-runtime-canary-analysisruns-final.json'
    'kargo-runtime-canary-events-final.json'
    'kargo-runtime-canary-analysis-outcomes-final.json'
    'kargo-runtime-canary-sitsoak-stages-final.json'
    'kargo-runtime-canary-sitsoak-freight-final.json'
    'kargo-runtime-canary-sitsoak-promotions-final.json'
    'kargo-runtime-canary-sitsoak-analysisruns-final.json'
    'kargo-runtime-canary-sitsoak-events-final.json'
    'kargo-runtime-canary-sitsoak-analysis-outcomes-final.json'
  )
  kargo_capture_json_evidence canary stages.kargo.akuity.io \
    "${report}/${kargo_final_paths[0]}" || true
  kargo_capture_json_evidence canary freight.kargo.akuity.io \
    "${report}/${kargo_final_paths[1]}" || true
  kargo_capture_json_evidence canary promotions.kargo.akuity.io \
    "${report}/${kargo_final_paths[2]}" || true
  kargo_capture_json_evidence canary analysisruns.argoproj.io \
    "${report}/${kargo_final_paths[3]}" || true
  kargo_capture_json_evidence canary events \
    "${report}/${kargo_final_paths[4]}" || true
  kargo_capture_json_evidence canary configmap/kargo-analysis-outcomes \
    "${report}/${kargo_final_paths[5]}" || true
  kargo_capture_json_evidence canary-sitsoak stages.kargo.akuity.io \
    "${report}/${kargo_final_paths[6]}" || true
  kargo_capture_json_evidence canary-sitsoak freight.kargo.akuity.io \
    "${report}/${kargo_final_paths[7]}" || true
  kargo_capture_json_evidence canary-sitsoak promotions.kargo.akuity.io \
    "${report}/${kargo_final_paths[8]}" || true
  kargo_capture_json_evidence canary-sitsoak analysisruns.argoproj.io \
    "${report}/${kargo_final_paths[9]}" || true
  kargo_capture_json_evidence canary-sitsoak events \
    "${report}/${kargo_final_paths[10]}" || true
  kargo_capture_json_evidence canary-sitsoak configmap/kargo-analysis-outcomes \
    "${report}/${kargo_final_paths[11]}" || true
  if [ "${SIT_CURRENT_LEG:-}" = 'L9-kargo-v1-runtime' ]; then
    SIT_LEG_EVIDENCE+=("${kargo_final_paths[@]}")
  fi
}

# The pass path remains strict in sit_leg_pass. On a failure, retain only files
# which actually exist and are non-empty, and preserve absent success-path
# expectations in one real evidence artifact instead of claiming them as files.
sit_prepare_failure_evidence() {
  local path missing_json
  local -a existing=() missing=() invalid=()
  for path in "${SIT_LEG_EVIDENCE[@]}"; do
    case "${path}" in
    /* | .. | ../* | */.. | */../*) invalid+=("${path}") ;;
    *)
      if [ -s "${report}/${path}" ]; then
        existing+=("${path}")
      else
        missing+=("${path}")
      fi
      ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ] || [ "${#invalid[@]}" -gt 0 ]; then
    if [ "${#missing[@]}" -gt 0 ]; then
      missing_json="$(printf '%s\n' "${missing[@]}" | jq -Rsc 'split("\n")[:-1]')"
    else
      missing_json='[]'
    fi
    local invalid_json='[]'
    if [ "${#invalid[@]}" -gt 0 ]; then
      invalid_json="$(printf '%s\n' "${invalid[@]}" | jq -Rsc 'split("\n")[:-1]')"
    fi
    jq -n \
      --argjson missingEvidence "${missing_json}" \
      --argjson invalidEvidence "${invalid_json}" \
      '{missingEvidence:$missingEvidence,invalidEvidence:$invalidEvidence}' \
      >"${report}/failure-evidence-gaps.json"
    existing+=('failure-evidence-gaps.json')
  fi
  SIT_LEG_EVIDENCE=("${existing[@]}")
}

stop_pid() {
  local pid="$1"
  if [[ ${pid} =~ ^[0-9]+$ ]]; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

# Duplicate the harness output to ${report}/harness.log while keeping the
# caller's copy, which is what the outer wrapper retains as inner-run.log. A
# process substitution would need an openable /dev/fd, which the instance shell
# does not reliably provide.
#
# The bootstrap descriptor is the load-bearing part. Opening the FIFO O_RDWR
# never blocks and keeps a reader attached for the whole of setup, so no later
# open can block and nothing depends on the background reader winning a race. If
# the reader dies instantly, the parent's writer open still succeeds instead of
# hanging forever.
start_harness_log() {
  local log_path="$1"
  # Preflight before mutating any descriptor state: a missing tool must refuse
  # here, not halfway through initialization.
  sit_require_command mkfifo
  sit_require_command tee

  # Arm finalization before anything can fail. From this point every partially
  # initialized surface below is owned by finish_harness_log, which must run
  # even if setup never reaches the reader launch.
  SIT_LOG_ARMED=1
  SIT_LOG_FIFO="${work}/harness-log.fifo"
  exec {SIT_LOG_SAVED_OUT}>&1 {SIT_LOG_SAVED_ERR}>&2
  mkfifo -m 600 "${SIT_LOG_FIFO}" ||
    sit_fail "could not create the harness log FIFO: ${SIT_LOG_FIFO}"
  exec {SIT_LOG_BOOT_FD}<>"${SIT_LOG_FIFO}"

  # The reader gets its own read-only open, writes explicitly to the saved
  # descriptors, and is denied the bootstrap fd. Without that close it would
  # retain a writer-capable descriptor and could never observe EOF.
  tee -a "${log_path}" \
    <"${SIT_LOG_FIFO}" >&"${SIT_LOG_SAVED_OUT}" 2>&"${SIT_LOG_SAVED_ERR}" \
    {SIT_LOG_BOOT_FD}>&- &
  SIT_LOG_TEE_PID=$!

  # Writer opened after the reader, so the reader can never inherit it.
  exec {SIT_LOG_WRITER_FD}>"${SIT_LOG_FIFO}"
  # Drop the bootstrap: EOF must depend only on the parent's writer descriptors.
  exec {SIT_LOG_BOOT_FD}>&-
  SIT_LOG_BOOT_FD=''

  exec >&"${SIT_LOG_WRITER_FD}" 2>&1
}

# Returns non-zero only when a launched reader failed. Closing and removing
# partially initialized state is unconditional: there is deliberately no early
# return on an empty reader PID, because setup can fail after saving descriptors
# or creating the FIFO and before ever launching one.
finish_harness_log() {
  [ "${SIT_LOG_FINALIZED}" -eq 0 ] || return 0
  SIT_LOG_FINALIZED=1
  [ "${SIT_LOG_ARMED}" -eq 1 ] || return 0
  local tee_status=0

  # Restore first, then close every writer-capable descriptor. Only then can the
  # reader see EOF; waiting before that would deadlock the parent against its
  # own reader.
  if [ -n "${SIT_LOG_SAVED_OUT}" ]; then
    exec 1>&"${SIT_LOG_SAVED_OUT}"
  fi
  if [ -n "${SIT_LOG_SAVED_ERR}" ]; then
    exec 2>&"${SIT_LOG_SAVED_ERR}"
  fi
  if [ -n "${SIT_LOG_WRITER_FD}" ]; then
    exec {SIT_LOG_WRITER_FD}>&-
    SIT_LOG_WRITER_FD=''
  fi
  if [ -n "${SIT_LOG_BOOT_FD}" ]; then
    exec {SIT_LOG_BOOT_FD}>&-
    SIT_LOG_BOOT_FD=''
  fi
  if [ -n "${SIT_LOG_TEE_PID}" ]; then
    wait "${SIT_LOG_TEE_PID}" || tee_status=$?
    SIT_LOG_TEE_PID=''
  fi
  if [ -n "${SIT_LOG_FIFO}" ]; then
    rm -f "${SIT_LOG_FIFO}"
    SIT_LOG_FIFO=''
  fi
  if [ -n "${SIT_LOG_SAVED_OUT}" ]; then
    exec {SIT_LOG_SAVED_OUT}>&-
    SIT_LOG_SAVED_OUT=''
  fi
  if [ -n "${SIT_LOG_SAVED_ERR}" ]; then
    exec {SIT_LOG_SAVED_ERR}>&-
    SIT_LOG_SAVED_ERR=''
  fi
  SIT_LOG_ARMED=0

  [ "${tee_status}" -eq 0 ] || {
    echo "the harness log writer exited with status ${tee_status}" >&2
    return 1
  }
}

cleanup() {
  local rc=$?
  [ "${cleanup_started}" -eq 0 ] || return
  cleanup_started=1
  trap - EXIT ERR TERM INT
  set +e
  collect_final_evidence
  stop_pid "${PF_SERVER_PID}"
  stop_pid "${PF_APPSET_PID}"
  stop_pid "${GIT_SERVER_PID}"
  # The platform-managed k3s service is never stopped or restarted here. The
  # outer proof wrapper owns exact-id instance destruction and absence proof.
  if [ "${report_active}" -eq 1 ] && [ -f "${SIT_REPORT_FILE}" ]; then
    if [ "$(jq -r '.status' "${SIT_REPORT_FILE}" 2>/dev/null)" = 'running' ]; then
      sit_report_finish fail || true
    fi
  fi
  # Finalize logging last, so every message above still reaches both the log and
  # the caller. Status precedence: a primary body or signal status is preserved
  # exactly; a log-writer-only failure still cannot produce success.
  local log_rc=0
  finish_harness_log || log_rc=1
  remove_sit_scratch "${work}" || rc=1
  if [ "${rc}" -eq 0 ] && [ "${log_rc}" -ne 0 ]; then
    rc=1
  fi
  exit "${rc}"
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local command="${BASH_COMMAND:-unknown}"
  local -a error_functions=("${FUNCNAME[@]}")
  local -a error_sources=("${BASH_SOURCE[@]}")
  local -a error_lines=("${BASH_LINENO[@]}")
  local frame
  trap - ERR
  set +e
  if [ "${report_active}" -eq 1 ]; then
    {
      printf 'exit_code=%s\nline=%s\ncommand=%s\n' "${rc}" "${line}" "${command}"
      for ((frame = 0; frame < ${#error_functions[@]}; frame++)); do
        printf 'frame[%d].function=%s\n' "${frame}" "${error_functions[$frame]:-unknown}"
        printf 'frame[%d].source=%s\n' "${frame}" "${error_sources[$frame]:-unknown}"
        printf 'frame[%d].line=%s\n' "${frame}" "${error_lines[$frame]:-unknown}"
      done
    } >"${report}/last-error.txt"
    SIT_LEG_EVIDENCE+=('last-error.txt')
    collect_final_evidence
    sit_prepare_failure_evidence
    sit_leg_fail "${rc}" "command failed at line ${line}"
    sit_report_finish fail
  fi
  exit "${rc}"
}

sit_pins_json() {
  jq -n \
    --arg argocd "${ARGOCD_VERSION}" \
    --arg argocdSourceCommit "${ARGOCD_SOURCE_COMMIT}" \
    --arg manifestSha256 "${ARGOCD_MANIFEST_SHA256}" \
    --arg nscVersion "${NSC_CLI_VERSION}" \
    --arg nscCommit "${NSC_CLI_COMMIT}" \
    --arg duration "${NSC_DURATION}" \
    --arg machineType "${NSC_MACHINE_TYPE}" \
    --arg kubernetes "${NSC_KUBERNETES_VERSION}" \
    --arg k3s "${NSC_K3S_VERSION}" \
    --arg ctr "${NSC_CONTAINERD_CTR}" \
    --arg containerdAddress "${NSC_CONTAINERD_ADDRESS}" \
    --arg containerdNamespace "${NSC_CONTAINERD_NAMESPACE}" \
    --arg kargoVersion "${KARGO_VERSION}" \
    --arg kargoSourceCommit "${KARGO_SOURCE_COMMIT}" \
    --arg kargoCrdBaseURL "${KARGO_CRD_BASE_URL}" \
    --arg projects "${KARGO_CRD_PROJECTS_SHA256}" \
    --arg projectConfigs "${KARGO_CRD_PROJECTCONFIGS_SHA256}" \
    --arg stages "${KARGO_CRD_STAGES_SHA256}" \
    --arg warehouses "${KARGO_CRD_WAREHOUSES_SHA256}" \
    --arg chartRef "${KARGO_CHART_REF}" \
    --arg chartVersion "${KARGO_CHART_VERSION}" \
    --arg chartDigest "${KARGO_CHART_DIGEST}" \
    --arg chartArchiveSha256 "${KARGO_CHART_ARCHIVE_SHA256}" \
    --arg kargoImage "${KARGO_RUNTIME_IMAGE_REF}" \
    --arg rolloutsVersion "${ROLLOUTS_VERSION}" \
    --arg rolloutsManifestUrl "${ROLLOUTS_MANIFEST_URL}" \
    --arg rolloutsManifestSha256 "${ROLLOUTS_MANIFEST_SHA256}" \
    --arg rolloutsImage "${ROLLOUTS_RUNTIME_IMAGE_REF}" \
    --arg analysisImage "${ANALYSIS_RUNTIME_IMAGE_REF}" \
    '{
      argocd:$argocd,
      argocdSourceCommit:$argocdSourceCommit,
      argocdManifestSha256:$manifestSha256,
      namespace:{
        cliVersion:$nscVersion,cliCommit:$nscCommit,duration:$duration,
        machineType:$machineType,kubernetes:$kubernetes,k3s:$k3s,
        containerd:{ctr:$ctr,address:$containerdAddress,namespace:$containerdNamespace}
      },
      kargo:{
        version:$kargoVersion,
        sourceCommit:$kargoSourceCommit,
        crdBaseURL:$kargoCrdBaseURL,
        crdSha256:{
          projects:$projects,
          projectconfigs:$projectConfigs,
          stages:$stages,
          warehouses:$warehouses
        },
        chart:{ref:$chartRef,version:$chartVersion,digest:$chartDigest,archiveSha256:$chartArchiveSha256},
        image:$kargoImage
      },
      rollouts:{
        version:$rolloutsVersion,
        manifestURL:$rolloutsManifestUrl,
        manifestSha256:$rolloutsManifestSha256,
        image:$rolloutsImage
      },
      analysisImage:$analysisImage
    }'
}

sit_provenance_json() {
  local checkout_clean_at_start="$1"
  jq -n \
    --arg commit "${SIT_SOURCE_HEAD}" \
    --arg tree "${SIT_SNAPSHOT_TREE}" \
    --argjson checkoutCleanAtStart "${checkout_clean_at_start}" \
    --argjson roots "$(printf '%s\n' "${SIT_DIRECT_INPUT_ROOTS[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    --arg directInputSha256 "${DIRECT_INPUT_SHA256}" \
    --argjson directInputFileCount "${DIRECT_INPUT_FILE_COUNT}" \
    --arg harnessSha256 "${HARNESS_SHA256}" \
    --argjson harnessFileCount "${HARNESS_FILE_COUNT}" \
    '{
      commit:$commit,
      checkoutHeadAtStart:$commit,
      checkoutCleanAtStart:$checkoutCleanAtStart,
      checkoutHeadAtFinish:null,
      checkoutCleanAtFinish:null,
      inputSnapshotCommit:$commit,
      inputSnapshotTree:$tree,
      inputSnapshotVerified:true,
      executionRoot:"a verified throwaway snapshot of the recorded commit; the live checkout is never read during execution",
      directInputRoots:$roots,
      directInputInventory:"direct-input-inventory.sha256",
      directInputInventoryFormat:"LF-delimited mode,type,git-blob-sha,content-sha256,path records sorted bytewise by path, derived from git ls-tree at the recorded commit",
      directInputSha256:$directInputSha256,
      directInputFileCount:$directInputFileCount,
      directInputRecheckedAtFinish:null,
      directInputSha256AtFinish:null,
      harnessInventory:"harness-inventory.sha256",
      harnessInventoryFormat:"sha256 of LF-delimited <file-sha256><two spaces><relative-path> lines sorted bytewise by path",
      harnessSha256:$harnessSha256,
      harnessFileCount:$harnessFileCount,
      harnessDigestScope:"the SIT harness only (scripts/ci/fleet-sit*.sh + scripts/validate/fleet-sit); it is NOT the direct-input inventory and binds none of the product inputs"
    }'
}

prepare_only() {
  validate_inputs
  local prepare_work
  prepare_work="$(make_sit_scratch)"
  work="${prepare_work}"
  SIT_SCRATCH_ROOT="${work}"
  export SIT_SCRATCH_ROOT
  local prepare_report="${prepare_work}/evidence"
  mkdir -p "${prepare_report}"
  trap 'stop_pid "${GIT_SERVER_PID}"; remove_sit_scratch "${work}"' EXIT

  write_harness_inventory "${prepare_report}/harness-inventory.sha256"

  bun "${validation_dir}/git-server.ts" --root "${prepare_work}" --self-test \
    >"${prepare_report}/git-server-self-test.json"
  bun "${validation_dir}/github-webhook.ts" --self-test \
    >"${prepare_report}/github-webhook-self-test.json"
  bun "${validation_dir}/kargo-contract.ts" --self-test \
    >"${prepare_report}/kargo-contract-self-test.json"
  (
    cd "${validation_dir}/fixtures/kargo-expression"
    go test ./...
  ) >"${prepare_report}/kargo-expression-engine.txt" 2>&1
  bun build "${validation_dir}/git-server.ts" --target=bun --outfile="${prepare_work}/git-server.js" >/dev/null
  bun build "${validation_dir}/github-webhook.ts" --target=bun --outfile="${prepare_work}/github-webhook.js" >/dev/null
  bun build "${validation_dir}/kargo-contract.ts" --target=bun --outfile="${prepare_work}/kargo-contract.js" >/dev/null

  # The committed pointer file must carry the exact product contract the SIT
  # models, and the live serving path must stay empty.
  read_machinery_pointer_target registry/machinery-stable.yaml >/dev/null
  machinery_pointer_self_test "${prepare_work}/pointer" \
    "${prepare_report}/machinery-pointer-self-test.json"
  [ ! -e registry/clusters ] || [ -z "$(find registry/clusters -name '*.yaml' -print -quit 2>/dev/null)" ] ||
    sit_fail 'registry/clusters carries a live serving row while the v1 roster is unratified'

  # The field-exact Kargo oracle over the committed chart, without a cluster.
  helm template canary registry/charts/diene-platform \
    --namespace canary \
    --values platforms/canary/services.yaml \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml |
    yq ea -o=json '[.] | map(select(.apiVersion == "kargo.akuity.io/v1alpha1"))' \
      >"${prepare_work}/kargo-objects.json"
  bun "${validation_dir}/kargo-contract.ts" \
    --objects "${prepare_work}/kargo-objects.json" \
    --out "${prepare_report}/kargo-rendered-contract.json" \
    --source 'prepare-only render of the committed compiler chart'
  # The oracle must be non-vacuous: the rendezvous mutation has to fail it.
  jq 'map(if .kind == "Stage" and .metadata.name == "canary-dummy-ampharos"
          then del(.spec.requestedFreight[0].sources.availabilityStrategy) else . end)' \
    "${prepare_work}/kargo-objects.json" >"${prepare_work}/kargo-objects-mutated.json"
  if bun "${validation_dir}/kargo-contract.ts" \
    --objects "${prepare_work}/kargo-objects-mutated.json" \
    --out "${prepare_work}/kargo-mutated-contract.json" \
    --source 'rendezvous mutation' >/dev/null 2>&1; then
    sit_fail 'the Kargo field oracle accepted a render with no rendezvous availabilityStrategy'
  fi

  prepare_repositories
  cp "${work}/runtime-chart-schema-relaxation.diff" "${prepare_report}/runtime-chart-schema-relaxation.diff"
  start_git_server "${prepare_report}"
  "${validation_dir}/derive-appset.sh" \
    registry/platforms-appset.yaml \
    "${prepare_work}/platforms-appset.sit.yaml" \
    "${FLEET_REPO_URL}" "${FLEET_SERVICES_REPO_URL}" \
    "${CANARY_REPO_URL}" "${SITOTHER_REPO_URL}" \
    "${prepare_report}"

  helm template canary "${FLEET_SOURCE}/registry/charts/diene-platform" \
    --namespace canary \
    --values "${FLEET_SOURCE}/platforms/canary/services.yaml" \
    --values registry/charts/diene-platform/tests/fixtures/canary.platform.yaml \
    --set-string "fleet.repoURL=${FLEET_REPO_URL}" \
    --set-string 'fleet.revision=main' |
    yq 'select(.kind == "ApplicationSet")' >"${prepare_work}/canary-appset.yaml"
  yq -o=json '.' "${prepare_work}/canary-appset.yaml" >"${prepare_work}/canary-appset.json"
  jq -e '
      .metadata.name == "canary" and
      .spec.generators[0].git.files[0].path == "platforms/canary/landscapes/*/*.yaml" and
      .spec.generators[1].matrix.generators[0].git.files[0].path == "platforms/canary/landscapes/*/*.yaml" and
      .spec.generators[1].matrix.generators[1].clusters.selector.matchLabels["atomi.cloud/landscape"] == "{{ .landscape }}" and
      .spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions == [{
        key:"atomi.cloud/cluster-role", operator:"NotIn", values:["infrastructure-only"]
      }]
    ' "${prepare_work}/canary-appset.json" >/dev/null
  jq 'del(.spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions)' \
    "${prepare_work}/canary-appset.json" >"${prepare_work}/canary-appset-without-infrastructure-exclusion.json"
  if jq -e '
    .spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions == [{
      key:"atomi.cloud/cluster-role", operator:"NotIn", values:["infrastructure-only"]
    }]
  ' "${prepare_work}/canary-appset-without-infrastructure-exclusion.json" >/dev/null; then
    sit_fail 'the ApplicationSet exclusion oracle accepted a render with no matchExpressions'
  fi
  infrastructure_exclusion_self_test \
    "${prepare_work}/infrastructure-exclusion-self-test" \
    "${prepare_report}/infrastructure-exclusion-self-test.json"

  # Report self-test: the schema-v2 provenance block is exercised end to end,
  # including the finish merge and every invariant the wrapper re-derives.
  SIT_SOURCE_HEAD="$(git rev-parse HEAD)"
  SIT_SNAPSHOT_TREE="$(git rev-parse 'HEAD^{tree}')"
  # Advisory here: prepare-only must stay runnable on a work-in-progress
  # checkout. Only the wrapped full run derives the inventory strictly, and only
  # that run's inventory is proof of anything.
  local inventory_strictness='strict'
  if [ -n "$(git status --porcelain --untracked-files=all -- "${SIT_DIRECT_INPUT_ROOTS[@]}")" ]; then
    inventory_strictness='advisory'
    echo 'note: direct-input roots are dirty; deriving the inventory in advisory mode (prepare-only)'
  fi
  write_direct_input_inventory "${prepare_report}/direct-input-inventory.sha256" \
    "${SIT_SOURCE_HEAD}" "${inventory_strictness}"
  sit_report_init "${prepare_work}/report-self-test" \
    "$(sit_pins_json)" "$(sit_provenance_json true)"
  jq -n '{fixture:true}' >"${SIT_REPORT_DIR}/fixture.json"
  sit_leg_begin 'self-test' 'fixture.json'
  sit_leg_pass 'report append helper'
  sit_report_finish pass "$(jq -n \
    --arg commit "${SIT_SOURCE_HEAD}" \
    --arg digest "${DIRECT_INPUT_SHA256}" \
    '{checkoutHeadAtFinish:$commit,checkoutCleanAtFinish:true,
      directInputRecheckedAtFinish:true,directInputSha256AtFinish:$digest}')"
  jq -e \
    --arg harness "${HARNESS_SHA256}" \
    --arg direct "${DIRECT_INPUT_SHA256}" \
    --arg commit "${SIT_SOURCE_HEAD}" '
    .status == "pass" and
    .schemaVersion == 2 and
    .commit == $commit and
    .inputSnapshotCommit == $commit and
    .harnessSha256 == $harness and
    .directInputSha256 == $direct and
    .directInputSha256AtFinish == $direct and
    .directInputFileCount > .harnessFileCount and
    (.directInputRoots | length) > 0 and
    (.legContract | length) == 10 and
    .legs == [{leg:"self-test",status:"pass",started:.legs[0].started,elapsed_s:.legs[0].elapsed_s,evidence:["fixture.json"],note:"report append helper"}]
  ' \
    "${SIT_REPORT_FILE}" >/dev/null
  sit_assert_provenance_bound "${SIT_SOURCE_HEAD}"
  # ... and the same assertion must refuse a report whose finish digest, head,
  # or leg set disagrees, so it is not a vacuous green.
  local tampered="${prepare_work}/report-tampered"
  mkdir -p "${tampered}"
  local mutation
  for mutation in \
    '.directInputSha256AtFinish = "0000000000000000000000000000000000000000000000000000000000000000"' \
    '.checkoutCleanAtFinish = false' \
    '.inputSnapshotVerified = false' \
    '.harnessFileCount = (.directInputFileCount + 1)'; do
    jq "${mutation}" "${SIT_REPORT_FILE}" >"${tampered}/sit-report.json"
    if SIT_REPORT_FILE="${tampered}/sit-report.json" \
      sit_assert_provenance_bound "${SIT_SOURCE_HEAD}" 2>/dev/null; then
      sit_fail "the provenance assertion accepted a tampered report: ${mutation}"
    fi
  done
  if (sit_assert_complete_pass_legs) 2>/dev/null; then
    sit_fail 'the leg-set assertion accepted a report that is not the ordered L0-L9 pass set'
  fi

  jq -n \
    --arg argocd "${ARGOCD_VERSION}" \
    --arg manifestSha256 "${ARGOCD_MANIFEST_SHA256}" \
    --arg nsc "${NSC_CLI_VERSION}" \
    --arg machineType "${NSC_MACHINE_TYPE}" \
    --arg kubernetes "${NSC_KUBERNETES_VERSION}" \
    --arg k3s "${NSC_K3S_VERSION}" \
    --arg kargo "${KARGO_VERSION}" \
    --arg c1 "${C1_SHA}" \
    --arg commit "${SIT_SOURCE_HEAD}" \
    --arg directInputSha256 "${DIRECT_INPUT_SHA256}" \
    --argjson directInputFileCount "${DIRECT_INPUT_FILE_COUNT}" \
    --arg harnessSha256 "${HARNESS_SHA256}" \
    --argjson harnessFileCount "${HARNESS_FILE_COUNT}" \
    '{status:"pass",argocd:$argocd,manifestSha256:$manifestSha256,
      namespace:{nsc:$nsc,machineType:$machineType,kubernetes:$kubernetes,k3s:$k3s},kargo:$kargo,
      fixtureHead:$c1,commit:$commit,
      directInputSha256:$directInputSha256,directInputFileCount:$directInputFileCount,
      harnessSha256:$harnessSha256,harnessFileCount:$harnessFileCount}' \
    >"${prepare_report}/prepare-only.json"
  echo 'fleet SIT prepare-only checks passed'
}

run_full() {
  # Fail closed unless the wrapper handed us a verified snapshot. Reading the
  # live checkout would leave the transient-consumption route open: a direct
  # input could change after the inventory and be restored before the final
  # cleanliness check.
  [ -n "${FLEET_SIT_CHECKOUT:-}" ] && [ -n "${FLEET_SIT_EXPECTED_HEAD:-}" ] ||
    sit_fail 'run scripts/ci/fleet-sit-proof.sh; a full SIT must execute from a verified snapshot, never from a live checkout'
  SIT_CHECKOUT="${FLEET_SIT_CHECKOUT}"
  SIT_SOURCE_HEAD="${FLEET_SIT_EXPECTED_HEAD}"
  [[ ${SIT_SOURCE_HEAD} =~ ^[0-9a-f]{40}$ ]] || sit_fail 'FLEET_SIT_EXPECTED_HEAD is not a 40-hex commit'
  [ -d "${SIT_CHECKOUT}/.git" ] || [ -f "${SIT_CHECKOUT}/.git" ] ||
    sit_fail "FLEET_SIT_CHECKOUT is not a git checkout: ${SIT_CHECKOUT}"
  [ "${SIT_CHECKOUT}" != "${root}" ] ||
    sit_fail 'the input snapshot must be a different directory from the original checkout'
  assert_verified_snapshot "${SIT_SOURCE_HEAD}"
  assert_clean_unchanged_checkout "${SIT_CHECKOUT}" "${SIT_SOURCE_HEAD}"

  # Only a verified wrapper handoff may mutate even the disposable instance's
  # toolchain. Namespace preflight then installs the allowlisted missing tools
  # and validate_inputs proves the complete driver surface before application
  # mutation begins.
  namespace_prepare_tools
  validate_inputs

  report="${FLEET_SIT_REPORT:-${SIT_CHECKOUT}/sit-report}"
  case "${report}" in
  "${root}" | "${root}"/*)
    sit_fail 'the report directory must live outside the input snapshot'
    ;;
  esac
  require_empty_report_directory "${report}"
  work="$(make_sit_scratch)"
  SIT_SCRATCH_ROOT="${work}"
  export SIT_SCRATCH_ROOT
  mkdir -p "${report}"
  namespace_capture_platform
  write_harness_inventory "${report}/harness-inventory.sha256"
  write_direct_input_inventory "${report}/direct-input-inventory.sha256" "${SIT_SOURCE_HEAD}"
  sit_report_init "${report}" "$(sit_pins_json)" "$(sit_provenance_json true)"
  report_active=1
  # Traps are installed before the harness log is armed, so a failure inside
  # start_harness_log is already covered by finalization and cannot leak a saved
  # descriptor, the bootstrap descriptor, the writer, or the FIFO.
  trap cleanup EXIT
  trap on_error ERR
  trap 'exit 124' TERM
  trap 'exit 130' INT
  start_harness_log "${report}/harness.log"

  sit_leg_begin 'L0-runtime-setup' \
    'namespace-platform.json' 'pins-verified.txt' 'manifest-contract.json' 'git-ls-remote.txt' \
    'git-services-ls-remote.txt' 'git-services-alias.json' 'git-smart-http.headers' \
    'platforms-appset.authorized-diff.json' 'canary-appset.yaml' 'cluster-secret-inputs.json' \
    'cluster-fixture-substitution.json' \
    'runtime-chart-schema-relaxation.diff' 'server-http-runtime.json' \
    'polling-clock-baseline.json' \
    'harness-inventory.sha256' 'direct-input-inventory.sha256'
  prepare_repositories
  cp "${work}/runtime-chart-schema-relaxation.diff" "${report}/runtime-chart-schema-relaxation.diff"
  start_git_server "${report}"
  kubectl wait --for=condition=Ready node --all --timeout=120s

  curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
    "${ARGOCD_MANIFEST_URL}" --output "${work}/argocd-install.yaml"
  printf '%s  %s\n' "${ARGOCD_MANIFEST_SHA256}" "${work}/argocd-install.yaml" |
    sha256sum --check | tee "${report}/pins-verified.txt"
  yq eval-all -o=json 'select(.kind == "Service" and .metadata.name == "argocd-applicationset-controller")' \
    "${work}/argocd-install.yaml" |
    jq -e '{applicationSetWebhookPort:.spec.ports[] | select(.name == "webhook") | .port}' \
      >"${report}/manifest-contract.json"
  jq -e '.applicationSetWebhookPort == 7000' "${report}/manifest-contract.json" >/dev/null
  yq eval-all -o=json 'select(.kind == "Service" and .metadata.name == "argocd-server")' \
    "${work}/argocd-install.yaml" |
    jq -e 'any(.spec.ports[]; .name == "http" and .port == 80)' >/dev/null
  yq eval-all -o=json 'select(.kind == "Deployment" and .metadata.name == "argocd-applicationset-controller")' \
    "${work}/argocd-install.yaml" |
    jq -e 'any(.spec.template.spec.containers[0].env[]; .name == "ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER")' >/dev/null

  kubectl create namespace argocd
  kubectl -n argocd apply --server-side --force-conflicts --field-manager=fleet-sit \
    -f "${work}/argocd-install.yaml"
  wait_argo_rollouts

  local webhook_key
  webhook_key="$(yq -r '.spec.data[0].secretKey' registry/argocd-webhook-secret.yaml)"
  [ "${webhook_key}" = 'webhook.github.secret' ] || sit_fail 'committed ESO webhook key changed unexpectedly'
  SIT_SECRET="$(bun -e "console.log(crypto.randomUUID() + crypto.randomUUID())")"
  kubectl -n argocd patch secret argocd-secret --type merge \
    -p "$(jq -cn --arg key "${webhook_key}" --arg secret "${SIT_SECRET}" '{stringData:{($key):$secret}}')"
  configure_clocks '24h'
  kubectl -n argocd get configmap argocd-cm -o json >"${work}/argocd-cm-L0.json"
  kubectl -n argocd get deployment argocd-applicationset-controller -o json \
    >"${work}/applicationset-controller-L0.json"
  kubectl -n argocd get deployment argocd-repo-server -o json \
    >"${work}/repo-server-L0.json"
  jq -n \
    --slurpfile config "${work}/argocd-cm-L0.json" \
    --slurpfile applicationSet "${work}/applicationset-controller-L0.json" \
    --slurpfile repoServer "${work}/repo-server-L0.json" '
    {
      applicationReconciliation: $config[0].data["timeout.reconciliation"],
      applicationSetRequeue: (
        $applicationSet[0].spec.template.spec.containers[0].env[] |
        select(.name == "ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER") |
        .value
      ),
      repoRevisionCacheExpiration: (
        $repoServer[0].spec.template.spec.containers[0].env[] |
        select(.name == "ARGOCD_RECONCILIATION_TIMEOUT") |
        .value
      )
    }
  ' >"${report}/polling-clock-baseline.json"
  jq -e '
    .applicationReconciliation == "24h" and
    .applicationSetRequeue == "24h" and
    .repoRevisionCacheExpiration == "30s"
  ' "${report}/polling-clock-baseline.json" >/dev/null
  kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.insecure":"true"}}' -o json |
    jq '{configMap:.metadata.name,serverInsecure:.data["server.insecure"],webhookTransport:"http"}' \
      >"${report}/server-http-runtime.json"
  jq -e '.configMap == "argocd-cmd-params-cm" and .serverInsecure == "true"' \
    "${report}/server-http-runtime.json" >/dev/null
  kubectl -n argocd rollout restart deployment/argocd-server
  wait_argo_rollouts

  seed_cluster_secrets
  start_port_forwards
  render_and_apply_appsets
  kubectl -n argocd get applicationsets.argoproj.io -o yaml >"${report}/appsets-initial.yaml"
  sit_leg_pass 'pinned Argo CD and k3s are live; webhook clocks are isolated at 24h'

  sit_leg_begin 'L1-baseline-generation' \
    'expected-child-apps.json' 'apps-S0.json' 'child-specs-S0.json' 'appsets-S0.yaml' \
    'infrastructure-exclusion.json'
  build_expected_child_apps "${report}/expected-child-apps.json"
  sit_wait_for 120 'eight canary row Applications and both platform Applications' check_baseline_apps
  capture_child_specs 'S0'
  kubectl -n argocd get applicationsets.argoproj.io -o yaml >"${report}/appsets-S0.yaml"
  jq -e 'length == 8' "${report}/child-specs-S0.json" >/dev/null
  kubectl -n argocd get secrets \
    -l 'argocd.argoproj.io/secret-type=cluster' -o json >"${work}/cluster-secrets-S0.json"
  assert_infrastructure_only_excluded \
    "${report}/apps-S0.json" \
    "${work}/cluster-secrets-S0.json" \
    "${report}/infrastructure-exclusion.json"
  sit_leg_pass '4 rows x (Primordial + one label-matched serving cluster Secret) plus committed platform policies; every seeded infrastructure-only cluster, including one on a serving landscape, received no Application'

  local row before_sha
  row="${FLEET_SOURCE}/platforms/canary/landscapes/raichu/dummy.yaml"
  sit_leg_begin 'L2-signed-webhook-one-row' \
    'webhook-L2.json' 'git-C2.txt' 'apps-S2.json' 'child-specs-S2.json' 'changed-L2.json'
  before_sha="$(git -C "${FLEET_SOURCE}" rev-parse HEAD)"
  yq -i '.pin.tag = "0.1.1-sit-l2"' "${row}"
  fleet_commit 'C2 raichu row pin' "${report}/git-C2.txt" 'platforms/canary/landscapes/raichu/dummy.yaml'
  C2_SHA="${FLEET_LAST_COMMIT}"
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" correct \
    "${report}/webhook-L2.json" 'refs/heads/main' "${before_sha}" "${C2_SHA}" \
    'platforms/canary/landscapes/raichu/dummy.yaml'
  sit_assert_http_success "${report}/webhook-L2.json"
  sit_wait_for 90 'signed webhook to update only the raichu row pair' \
    check_child_revision raichu '0.1.1-sit-l2'
  capture_child_specs 'S2'
  assert_changed_landscapes "${report}/child-specs-S0.json" "${report}/child-specs-S2.json" L2 raichu
  sit_leg_pass 'signed GitHub push refreshed one row; every other canary Application spec stayed deep-equal'

  sit_leg_begin 'L3-invalid-signatures-no-refresh' \
    'webhook-L3-wrong.json' 'webhook-L3-missing.json' 'webhook-L3-correct.json' \
    'git-C3.txt' 'apps-L3-negative-end.json' 'apps-S3.json' 'child-specs-S3.json' 'changed-L3.json'
  before_sha="${C2_SHA}"
  row="${FLEET_SOURCE}/platforms/canary/landscapes/pichu/dummy.yaml"
  yq -i '.pin.tag = "0.1.2-sit-l3"' "${row}"
  fleet_commit 'C3 pichu row pin' "${report}/git-C3.txt" 'platforms/canary/landscapes/pichu/dummy.yaml'
  C3_SHA="${FLEET_LAST_COMMIT}"
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" wrong \
    "${report}/webhook-L3-wrong.json" 'refs/heads/main' "${before_sha}" "${C3_SHA}" \
    'platforms/canary/landscapes/pichu/dummy.yaml'
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" missing \
    "${report}/webhook-L3-missing.json" 'refs/heads/main' "${before_sha}" "${C3_SHA}" \
    'platforms/canary/landscapes/pichu/dummy.yaml'
  sit_assert_http_rejected wrong 'HMAC verification failed' "${report}/webhook-L3-wrong.json"
  sit_assert_http_rejected missing 'missing X-Hub-Signature-256' "${report}/webhook-L3-missing.json"
  sit_assert_child_specs_stable_for 90 "${report}/child-specs-S2.json" \
    "${report}/apps-L3-negative-changed.json"
  capture_child_specs 'L3-negative-end'
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" correct \
    "${report}/webhook-L3-correct.json" 'refs/heads/main' "${before_sha}" "${C3_SHA}" \
    'platforms/canary/landscapes/pichu/dummy.yaml'
  sit_assert_http_success "${report}/webhook-L3-correct.json"
  sit_wait_for 90 'proof-of-life signed webhook to update the pichu pair' \
    check_child_revision pichu '0.1.2-sit-l3'
  capture_child_specs 'S3'
  assert_changed_landscapes "${report}/child-specs-S2.json" "${report}/child-specs-S3.json" L3 pichu
  sit_leg_pass 'wrong and missing signatures returned pinned HTTP 400 rejections and caused no refresh for 90s'

  sit_leg_begin 'L4-main-tag-and-manual-policy' \
    'webhook-L4-appset.json' 'webhook-L4-application.json' 'git-C4.txt' \
    'platform-canary-before-L4.json' 'platform-canary-after-L4.json' 'platform-sitother-after-L4.json'
  kubectl -n argocd get application.argoproj.io platform-canary -o json \
    >"${report}/platform-canary-before-L4.json"
  before_sha="${C3_SHA}"
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: ConfigMap' \
    'metadata:' \
    '  name: fleet-sit-compiler-proof' \
    '  namespace: {{ .Release.Namespace }}' \
    '  labels:' \
    '    app.kubernetes.io/part-of: diene-fleet' \
    'data:' \
    '  revision: c4' \
    >"${FLEET_SOURCE}/registry/charts/diene-platform/templates/fleet-sit-proof.yaml"
  fleet_commit 'C4 compiler chart render marker' "${report}/git-C4.txt" \
    'registry/charts/diene-platform/templates/fleet-sit-proof.yaml'
  C4_SHA="${FLEET_LAST_COMMIT}"
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" correct \
    "${report}/webhook-L4-appset.json" 'refs/heads/main' "${before_sha}" "${C4_SHA}" \
    'registry/charts/diene-platform/templates/fleet-sit-proof.yaml'
  send_webhook "http://127.0.0.1:${PF_SERVER_PORT}/api/webhook" correct \
    "${report}/webhook-L4-application.json" 'refs/heads/main' "${before_sha}" "${C4_SHA}" \
    'registry/charts/diene-platform/templates/fleet-sit-proof.yaml'
  sit_assert_http_success "${report}/webhook-L4-appset.json"
  sit_assert_http_success "${report}/webhook-L4-application.json"
  sit_wait_for 120 'platform-canary comparison to resolve C4 on main' \
    check_platform_source_revision platform-canary "${C4_SHA}"
  kubectl -n argocd get application.argoproj.io platform-canary -o json \
    >"${report}/platform-canary-after-L4.json"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json \
    >"${report}/platform-sitother-after-L4.json"
  jq -e --arg c4 "${C4_SHA}" '
    .spec.sources[0].targetRevision == "main" and
    .status.sync.revisions[0] == $c4 and
    .status.sync.status == "OutOfSync" and
    .spec.syncPolicy.automated == null and
    .operation == null and
    .status.operationState == null
  ' "${report}/platform-canary-after-L4.json" >/dev/null
  jq -e --arg c1 "${C1_SHA}" '
    .spec.sources[0].targetRevision == "machinery-stable" and
    .status.sync.revisions[0] == $c1 and
    .spec.syncPolicy.automated.prune == true and
    .spec.syncPolicy.automated.selfHeal == true
  ' "${report}/platform-sitother-after-L4.json" >/dev/null
  sit_leg_pass 'canary main moved to C4 and stayed manual/OutOfSync; sitother source A stayed at machinery-stable C1'

  sit_leg_begin 'L5-machinery-pointer-forward-only-and-automated-policy' \
    'webhook-L5-application.json' 'l5-reset-and-tag.json' \
    'machinery-pointer-contract.json' 'git-C5-pointer.txt' 'machinery-pointer-advance-C4.json' \
    'machinery-pointer-backward-rejected.json' 'machinery-pointer-backward-push.log' \
    'git-C8-revert.txt' 'git-C8-pointer.txt' 'machinery-pointer-advance-revert.json' \
    'webhook-L5-rollback.json' 'platform-sitother-after-rollback-L5.json' \
    'platform-sitother-before-L5.json' 'platform-sitother-finalizer-reset-L5.json' \
    'controllers-stopped-L5.json' 'platform-sitother-absence-check-L5.txt' \
    'applicationset-reset-trigger-L5.txt' 'platform-sitother-reset-L5.json' \
    'platform-sitother-after-L5.json' 'platform-canary-after-L5.json'
  cp "${report}/platform-sitother-after-L4.json" "${report}/platform-sitother-before-L5.json"
  local previous_uid recreated_uid platforms_appset_uid tag_moved_at
  previous_uid="$(jq -r '.metadata.uid' "${report}/platform-sitother-before-L5.json")"
  [ -n "${previous_uid}" ] && [ "${previous_uid}" != 'null' ] ||
    sit_fail 'platform-sitother had no UID before the L5 reset'
  platforms_appset_uid="$(kubectl -n argocd get applicationset.argoproj.io platforms -o jsonpath='{.metadata.uid}')"
  [ -n "${platforms_appset_uid}" ] || sit_fail 'ApplicationSet/platforms had no UID before the L5 reset'
  scale_application_controller 0
  stop_pid "${PF_APPSET_PID}"
  PF_APPSET_PID=''
  PF_APPSET_PORT=''
  scale_applicationset_controller 0
  kubectl -n argocd get statefulset argocd-application-controller -o json \
    >"${work}/application-controller-stopped-L5.json"
  kubectl -n argocd get deployment argocd-applicationset-controller -o json \
    >"${work}/applicationset-controller-stopped-L5.json"
  jq -n \
    --slurpfile application "${work}/application-controller-stopped-L5.json" \
    --slurpfile applicationSet "${work}/applicationset-controller-stopped-L5.json" '
    {
      applicationController: {
        kind: $application[0].kind,
        name: $application[0].metadata.name,
        specReplicas: ($application[0].spec.replicas // 0),
        statusReplicas: ($application[0].status.replicas // 0),
        readyReplicas: ($application[0].status.readyReplicas // 0),
        currentReplicas: ($application[0].status.currentReplicas // 0)
      },
      applicationSetController: {
        kind: $applicationSet[0].kind,
        name: $applicationSet[0].metadata.name,
        specReplicas: ($applicationSet[0].spec.replicas // 0),
        statusReplicas: ($applicationSet[0].status.replicas // 0),
        readyReplicas: ($applicationSet[0].status.readyReplicas // 0),
        availableReplicas: ($applicationSet[0].status.availableReplicas // 0)
      }
    }
  ' >"${report}/controllers-stopped-L5.json"
  jq -e '
    .applicationController |
      .kind == "StatefulSet" and
      .name == "argocd-application-controller" and
      .specReplicas == 0 and .statusReplicas == 0 and
      .readyReplicas == 0 and .currentReplicas == 0
  ' "${report}/controllers-stopped-L5.json" >/dev/null
  jq -e '
    .applicationSetController |
      .kind == "Deployment" and
      .name == "argocd-applicationset-controller" and
      .specReplicas == 0 and .statusReplicas == 0 and
      .readyReplicas == 0 and .availableReplicas == 0
  ' "${report}/controllers-stopped-L5.json" >/dev/null
  kubectl -n argocd patch application.argoproj.io platform-sitother --type merge \
    -p '{"metadata":{"finalizers":null}}' -o json \
    >"${report}/platform-sitother-finalizer-reset-L5.json"
  jq -e '(.metadata.finalizers // []) | length == 0' \
    "${report}/platform-sitother-finalizer-reset-L5.json" >/dev/null
  kubectl -n argocd delete application.argoproj.io platform-sitother --wait=true --timeout=30s
  sit_wait_for 30 'platform-sitother to remain absent with both owning controllers stopped' \
    check_application_absent platform-sitother
  if kubectl -n argocd get application.argoproj.io platform-sitother \
    >"${report}/platform-sitother-absence-check-L5.txt" 2>&1; then
    sit_fail 'platform-sitother unexpectedly existed after its bounded L5 deletion'
  fi
  rg -qi 'not found' "${report}/platform-sitother-absence-check-L5.txt" ||
    sit_fail 'platform-sitother absence check did not return the Kubernetes NotFound contract'
  scale_applicationset_controller 1
  start_applicationset_port_forward
  kubectl -n argocd annotate applicationset.argoproj.io platforms \
    'argocd.argoproj.io/application-set-refresh=true' --overwrite \
    >"${report}/applicationset-reset-trigger-L5.txt"
  sit_wait_for 90 'ApplicationSet controller to recreate platform-sitother without an operation' \
    check_sitother_recreated_without_operation "${previous_uid}" "${platforms_appset_uid}"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json \
    >"${report}/platform-sitother-reset-L5.json"
  recreated_uid="$(jq -r '.metadata.uid' "${report}/platform-sitother-reset-L5.json")"
  jq -e \
    --arg previousUid "${previous_uid}" \
    --arg ownerUid "${platforms_appset_uid}" '
    .metadata.uid != $previousUid and
    any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and
      .kind == "ApplicationSet" and
      .name == "platforms" and
      .uid == $ownerUid and
      .controller == true) and
    .spec.sources[0].targetRevision == "machinery-stable" and
    .spec.syncPolicy.automated.prune == true and
    .spec.syncPolicy.automated.selfHeal == true and
    .operation == null and
    .status.operationState == null
  ' "${report}/platform-sitother-reset-L5.json" >/dev/null
  # The committed product pointer contract, read from the direct input, is what
  # the throwaway pointer file models: exactly one `target: <40-hex>` line.
  local committed_pointer_target
  committed_pointer_target="$(read_machinery_pointer_target registry/machinery-stable.yaml)"
  jq -n \
    --arg committedTarget "${committed_pointer_target}" \
    --arg fixtureTarget "$(read_machinery_pointer_target "${FLEET_SOURCE}/registry/machinery-stable.yaml")" \
    --arg c1 "${C1_SHA}" \
    '{
      pointerFile:"registry/machinery-stable.yaml",
      format:"exactly one non-comment line: target: <40-lowercase-hex-main-commit>",
      committedTargetAtRecordedCommit:$committedTarget,
      throwawayPointerBeforeAdvance:$fixtureTarget,
      throwawayTagBeforeAdvance:$c1,
      productWriteMechanism:"protected workflow PATCH of refs/tags/machinery-stable with force:false after a descendant precheck",
      sitWriteMechanism:"explicit old->new compare-and-swap on the serving repository after the same descendant precheck"
    }' >"${report}/machinery-pointer-contract.json"
  advance_machinery_pointer "${C4_SHA}" 'promote machinery-stable to C4' \
    "${report}/git-C5-pointer.txt" "${report}/machinery-pointer-advance-C4.json"
  tag_moved_at="$(sit_now)"
  jq -n \
    --arg previousUid "${previous_uid}" \
    --arg recreatedUid "${recreated_uid}" \
    --arg platformsApplicationSetUid "${platforms_appset_uid}" \
    --arg tagMovedAt "${tag_moved_at}" \
    --arg c4 "${C4_SHA}" \
    --slurpfile controllersDuringDeletion "${report}/controllers-stopped-L5.json" \
    '{
      previousUid:$previousUid,
      recreatedUid:$recreatedUid,
      platformsApplicationSetUid:$platformsApplicationSetUid,
      applicationControllerReplicasDuringDeletion:$controllersDuringDeletion[0].applicationController.statusReplicas,
      applicationSetControllerReplicasDuringDeletion:$controllersDuringDeletion[0].applicationSetController.statusReplicas,
      controllersDuringDeletion:$controllersDuringDeletion[0],
      tagMovedAt:$tagMovedAt,
      machineryStableRevision:$c4
    }' \
    >"${report}/l5-reset-and-tag.json"
  send_webhook "http://127.0.0.1:${PF_SERVER_PORT}/api/webhook" correct \
    "${report}/webhook-L5-application.json" 'refs/tags/machinery-stable' "${C1_SHA}" "${C4_SHA}"
  sit_assert_http_success "${report}/webhook-L5-application.json"
  scale_application_controller 1
  sit_wait_for 120 'new post-tag C4 automatic operation on recreated platform-sitother' \
    check_sitother_automation_live "${C4_SHA}" "${recreated_uid}" "${tag_moved_at}"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json \
    >"${report}/platform-sitother-after-L5.json"
  kubectl -n argocd get application.argoproj.io platform-canary -o json \
    >"${report}/platform-canary-after-L5.json"
  jq -e \
    --arg c4 "${C4_SHA}" \
    --arg uid "${recreated_uid}" \
    --arg tagMovedAt "${tag_moved_at}" '
    .metadata.uid == $uid and
    .spec.sources[0].targetRevision == "machinery-stable" and
    .status.sync.revisions[0] == $c4 and
    .spec.syncPolicy.automated.prune == true and
    .spec.syncPolicy.automated.selfHeal == true and
    .operation.initiatedBy.automated == true and
    .operation.sync.revisions[0] == $c4 and
    .status.operationState.startedAt >= $tagMovedAt and
    .status.operationState.operation.initiatedBy.automated == true and
    .status.operationState.operation.sync.revisions[0] == $c4
  ' "${report}/platform-sitother-after-L5.json" >/dev/null
  jq -e '.operation == null and .status.operationState == null and .spec.syncPolicy.automated == null' \
    "${report}/platform-canary-after-L5.json" >/dev/null

  # Backward pointer: refused by the descendant precheck AND by the transport,
  # with the serving ref proven unmoved.
  reject_backward_machinery_pointer "${C1_SHA}" \
    "${report}/machinery-pointer-backward-rejected.json" \
    "${report}/machinery-pointer-backward-push.log"
  jq -e --arg c4 "${C4_SHA}" '.refBefore == $c4 and .refAfter == $c4 and .tagMovedBackward == false' \
    "${report}/machinery-pointer-backward-rejected.json" >/dev/null

  # Rollback the hardened way: revert the bad compiler-chart change onto a NEW
  # descendant commit on main, then advance the pointer FORWARD onto it.
  local revert_sha rollback_moved_at
  fleet_revert "${C4_SHA}" 'C8 revert the C4 compiler chart change' "${report}/git-C8-revert.txt"
  revert_sha="${FLEET_LAST_COMMIT}"
  git -C "${FLEET_SOURCE}" merge-base --is-ancestor "${C4_SHA}" "${revert_sha}" ||
    sit_fail 'the rollback revert is not a descendant of the commit it reverts'
  advance_machinery_pointer "${revert_sha}" 'rollback: advance machinery-stable onto the revert commit' \
    "${report}/git-C8-pointer.txt" "${report}/machinery-pointer-advance-revert.json"
  rollback_moved_at="$(sit_now)"
  send_webhook "http://127.0.0.1:${PF_SERVER_PORT}/api/webhook" correct \
    "${report}/webhook-L5-rollback.json" 'refs/tags/machinery-stable' "${C4_SHA}" "${revert_sha}"
  sit_assert_http_success "${report}/webhook-L5-rollback.json"
  # The preceding C4 auto-sync intentionally fails in this CRD-light venue and
  # enters a five-retry schedule. Pinned Argo v3.4.5 defaults to a 5s base,
  # factor 2, and 3m cap; this venue's captured effective cadence was
  # 10+20+40+80+160s, consuming 310s while Argo correctly refused another
  # operation. Waiting through that ordinary path instead of terminating C4 out
  # of band keeps this production-faithful; 110s remains for reconciliation.
  sit_wait_for 420 'automatic operation on the rolled-back machinery-stable revision' \
    check_sitother_automation_live "${revert_sha}" "${recreated_uid}" "${rollback_moved_at}"
  kubectl -n argocd get application.argoproj.io platform-sitother -o json \
    >"${report}/platform-sitother-after-rollback-L5.json"
  jq -e \
    --arg revert "${revert_sha}" \
    --arg uid "${recreated_uid}" \
    --arg rollbackMovedAt "${rollback_moved_at}" '
    .metadata.uid == $uid and
    .spec.sources[0].targetRevision == "machinery-stable" and
    .status.sync.revisions[0] == $revert and
    .operation.initiatedBy.automated == true and
    .status.operationState.startedAt >= $rollbackMovedAt and
    .status.operationState.operation.sync.revisions[0] == $revert
  ' "${report}/platform-sitother-after-rollback-L5.json" >/dev/null
  [ "$(machinery_pointer_ref)" = "${revert_sha}" ] ||
    sit_fail 'machinery-stable does not point at the revert commit after rollback'
  sit_leg_pass 'after an operation-free UID reset, the pointer advanced machinery-stable to C4 with force:false and the restored controller launched a new automatic C4 operation; a backward pointer was refused twice without moving the ref; rollback advanced the tag FORWARD onto a new descendant revert commit; canary stayed manual with no operation'

  sit_leg_begin 'L6-two-row-union-and-no-row' \
    'webhook-L6-two-row.json' 'webhook-L6-no-row.json' 'git-C6-two-row.txt' 'git-C6-no-row.txt' \
    'apps-S6-two-row.json' 'child-specs-S6-two-row.json' 'changed-L6.json' 'apps-L6-no-row-end.json'
  before_sha="${C4_SHA}"
  yq -i '.pin.tag = "0.1.3-sit-l6"' \
    "${FLEET_SOURCE}/platforms/canary/landscapes/pichu/dummy.yaml"
  yq -i '.pin.tag = "0.1.3-sit-l6"' \
    "${FLEET_SOURCE}/platforms/canary/landscapes/ampharos/dummy.yaml"
  printf '\n# SIT C6 roster-only companion change\n' >>"${FLEET_SOURCE}/platforms/canary/services.yaml"
  fleet_commit 'C6 two rows plus roster comment' "${report}/git-C6-two-row.txt" \
    'platforms/canary/landscapes/pichu/dummy.yaml' \
    'platforms/canary/landscapes/ampharos/dummy.yaml' \
    'platforms/canary/services.yaml'
  C6_SHA="${FLEET_LAST_COMMIT}"
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" correct \
    "${report}/webhook-L6-two-row.json" 'refs/heads/main' "${before_sha}" "${C6_SHA}" \
    'platforms/canary/landscapes/pichu/dummy.yaml' \
    'platforms/canary/landscapes/ampharos/dummy.yaml' \
    'platforms/canary/services.yaml'
  sit_assert_http_success "${report}/webhook-L6-two-row.json"
  sit_wait_for 90 'pichu half of the two-row union' check_child_revision pichu '0.1.3-sit-l6'
  sit_wait_for 90 'ampharos half of the two-row union' check_child_revision ampharos '0.1.3-sit-l6'
  capture_child_specs 'S6-two-row'
  assert_changed_landscapes "${report}/child-specs-S3.json" \
    "${report}/child-specs-S6-two-row.json" L6 pichu ampharos

  before_sha="${C6_SHA}"
  printf '# SIT C6 non-row-only change\n' >>"${FLEET_SOURCE}/platforms/canary/services.yaml"
  fleet_commit 'C6b roster-only no-row path' "${report}/git-C6-no-row.txt" 'platforms/canary/services.yaml'
  C6B_SHA="${FLEET_LAST_COMMIT}"
  send_webhook "http://127.0.0.1:${PF_APPSET_PORT}/api/webhook" correct \
    "${report}/webhook-L6-no-row.json" 'refs/heads/main' "${before_sha}" "${C6B_SHA}" \
    'platforms/canary/services.yaml'
  sit_assert_http_success "${report}/webhook-L6-no-row.json"
  sit_assert_child_specs_stable_for 90 "${report}/child-specs-S6-two-row.json" \
    "${report}/apps-L6-no-row-changed.json"
  capture_child_specs 'L6-no-row-end'
  sit_leg_pass 'two row files changed exactly their four-app union; a roster-only path changed zero specs for 90s'

  sit_leg_begin 'L7-polling-fallback' \
    'git-C7.txt' 'polling-runtime-L7.json' 'polling-L7.json' \
    'apps-S7.json' 'child-specs-S7.json' 'changed-L7.json'
  configure_clocks '30s'
  kubectl -n argocd get deployment argocd-applicationset-controller -o json \
    >"${work}/applicationset-controller-L7.json"
  kubectl -n argocd get deployment argocd-repo-server -o json \
    >"${work}/repo-server-L7.json"
  jq -n \
    --slurpfile applicationSet "${work}/applicationset-controller-L7.json" \
    --slurpfile repoServer "${work}/repo-server-L7.json" '
    {
      applicationSetRequeue: (
        $applicationSet[0].spec.template.spec.containers[0].env[] |
        select(.name == "ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER") |
        .value
      ),
      repoRevisionCacheExpiration: (
        $repoServer[0].spec.template.spec.containers[0].env[] |
        select(.name == "ARGOCD_RECONCILIATION_TIMEOUT") |
        .value
      )
    }
  ' >"${report}/polling-runtime-L7.json"
  jq -e '
    .applicationSetRequeue == "30s" and
    .repoRevisionCacheExpiration == "30s"
  ' "${report}/polling-runtime-L7.json" >/dev/null
  capture_child_specs 'S6-poll-baseline'
  before_sha="${C6B_SHA}"
  yq -i '.pin.tag = "0.1.4-sit-l7"' \
    "${FLEET_SOURCE}/platforms/canary/landscapes/raichu/dummy.yaml"
  local poll_started poll_elapsed
  poll_started="$(sit_epoch)"
  fleet_commit 'C7 raichu polling fallback' "${report}/git-C7.txt" \
    'platforms/canary/landscapes/raichu/dummy.yaml'
  C7_SHA="${FLEET_LAST_COMMIT}"
  sit_wait_for 180 '30s ApplicationSet polling fallback to update raichu' \
    check_child_revision raichu '0.1.4-sit-l7'
  poll_elapsed=$(($(sit_epoch) - poll_started))
  jq -n \
    --arg before "${before_sha}" \
    --arg after "${C7_SHA}" \
    --argjson elapsed "${poll_elapsed}" \
    --slurpfile runtime "${report}/polling-runtime-L7.json" \
    '{webhookSent:false,before:$before,after:$after,runtime:$runtime[0],elapsed_s:$elapsed}' \
    >"${report}/polling-L7.json"
  capture_child_specs 'S7'
  assert_changed_landscapes "${report}/child-specs-S6-poll-baseline.json" \
    "${report}/child-specs-S7.json" L7 raichu
  sit_leg_pass "polling fallback converged without a webhook in ${poll_elapsed}s"

  sit_leg_begin 'L8-kargo-v1-field-contract' \
    'kargo-crds-verified.txt' 'kargo-rendered.yaml' 'kargo-rendered-contract.json' \
    'kargo-persisted.json' 'kargo-persisted-contract.json' 'kargo-crd-semantics.json' \
    'kargo-crd-preserve-unknown-blind-spots.json' 'kargo-expression-engine.txt' \
    'kargo-negatives.json' 'kargo-residuals.json'
  run_kargo_contract_leg
  sit_leg_pass 'the committed compiler chart renders the exact v1 Kargo mapping, its yaml-update call runs in the pinned expression engine, declared CRD fields survive admission, preserved-unknown blind spots are emitted explicitly, and enum/pattern negatives are rejected; controller behavior is reserved for L9'

  sit_leg_begin 'L9-kargo-v1-runtime' \
    'kargo-runtime-chart-pull.txt' 'kargo-runtime-chart-sha256.txt' \
    'kargo-runtime-rollouts-sha256.txt' 'kargo-runtime-image-pulls.txt' \
    'kargo-runtime-image-imports.txt' 'kargo-runtime-image-aliases.txt' \
    'kargo-runtime-host-images.json' \
    'kargo-runtime-node-images.json' 'kargo-runtime-node-ctr-images.txt' \
    'kargo-runtime-cri-kargo.json' 'kargo-runtime-cri-argo-rollouts.json' \
    'kargo-runtime-cri-busybox.json' \
    'kargo-runtime-webhook-cert-verify.txt' \
    'kargo-runtime-rollouts-deployment.json' 'kargo-runtime-kargo-deployments.json' \
    'kargo-runtime-webhooks.json' 'kargo-runtime-rendered.yaml' \
    'kargo-runtime-delta-oracle.json' 'kargo-runtime-rendered-contract.json' \
    'kargo-runtime-persisted.json' 'kargo-runtime-persisted-contract.json' \
    'kargo-runtime-f1-trace.json' 'kargo-runtime-f2-trace.json' \
    'kargo-runtime-f3-trace.json' 'kargo-runtime-soak-trace.json' \
    'kargo-runtime-soak-pre-boundary-refresh.json' \
    'kargo-runtime-soak-boundary-wait.json' \
    'kargo-runtime-soak-pre-stimulus.json' \
    'kargo-runtime-soak-ampharos-available-dry-run.json' \
    'kargo-runtime-soak-post-boundary-refresh.json' \
    'kargo-runtime-git.diff' 'kargo-runtime-git-oracle.json' \
    'kargo-runtime-raichu-values-before.yaml' 'kargo-runtime-raichu-values-after.yaml' \
    'kargo-runtime-controller.log' 'kargo-runtime-management-controller.log' \
    'kargo-runtime-webhooks-server.log' 'kargo-runtime-rollouts-controller.log' \
    'kargo-runtime-proof.json'
  run_kargo_runtime_leg
  sit_leg_pass 'the pinned Kargo v1.9.10 controllers and webhook execute real git promotions and Rollouts analyses across all gate, rendezvous, verification, soak-ordering, policy-flip, denial, and 90s wall-clock traces; the literal 15m and API/UI/discovery slivers remain explicit residuals'

  local checkout_clean_at_finish direct_input_finish_digest
  assert_clean_unchanged_checkout "${SIT_CHECKOUT}" "${SIT_SOURCE_HEAD}"
  checkout_clean_at_finish="$(checkout_clean "${SIT_CHECKOUT}")"
  assert_verified_snapshot "${SIT_SOURCE_HEAD}"
  # Recompute the direct-input inventory from the recorded tree and require it
  # to be byte-identical to the one taken before execution. Provenance is
  # derived here, never asserted as a literal.
  write_direct_input_inventory "${report}/direct-input-inventory.finish.sha256" "${SIT_SOURCE_HEAD}"
  direct_input_finish_digest="${DIRECT_INPUT_SHA256}"
  cmp -s "${report}/direct-input-inventory.sha256" "${report}/direct-input-inventory.finish.sha256" ||
    sit_fail 'the direct-input inventory changed during the SIT'

  sit_assert_complete_pass_legs
  sit_report_finish pass "$(jq -n \
    --arg head "$(git -C "${SIT_CHECKOUT}" rev-parse HEAD)" \
    --argjson clean "${checkout_clean_at_finish}" \
    --arg digest "${direct_input_finish_digest}" \
    '{checkoutHeadAtFinish:$head,checkoutCleanAtFinish:$clean,
      directInputRecheckedAtFinish:true,directInputSha256AtFinish:$digest}')"
  sit_assert_provenance_bound "${SIT_SOURCE_HEAD}"
  echo "fleet SIT passed; report: ${SIT_REPORT_FILE}"
}

if [ "${mode}" = 'prepare' ]; then
  prepare_only
else
  run_full
fi
