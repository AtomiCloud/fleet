#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# Required entry point for the fleet L0-L9 proof.
#
# Public --prepare-only is a local, snapshot-bound source check. Public --full
# owns one anonymous Namespace instance for the whole proof. It creates (or
# validates a lead-provided) exact instance, transfers a pristine snapshot,
# invokes this file's explicit --inner mode over nsc ssh, downloads and
# independently validates the report, and only then destroys the exact id and
# proves it absent. Namespace TTL is a backstop; explicit destroy is proof law.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checkout="$(cd "${script_dir}/../.." && pwd)"
validation_dir="${checkout}/scripts/validate/fleet-sit"

# shellcheck source=scripts/validate/fleet-sit/pins.env disable=SC1091
source "${validation_dir}/pins.env"

DIRECT_INPUT_ROOTS=(
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

# The report and worker cannot define their own coverage and thereby make a
# dropped leg look valid.
LEG_CONTRACT=(
  'L0-runtime-setup'
  'L1-baseline-generation'
  'L2-signed-webhook-one-row'
  'L3-invalid-signatures-no-refresh'
  'L4-main-tag-and-manual-policy'
  'L5-machinery-pointer-forward-only-and-automated-policy'
  'L6-two-row-union-and-no-row'
  'L7-polling-fallback'
  'L8-kargo-v1-field-contract'
  'L9-kargo-v1-runtime'
)

usage() {
  echo "usage: $0 [--prepare-only|--full]" >&2
  exit 2
}

mode='full'
[ "$#" -le 1 ] || usage
if [ "$#" -eq 1 ]; then
  case "$1" in
  --prepare-only) mode='prepare' ;;
  --full) mode='full' ;;
  --inner) mode='inner' ;;
  *) usage ;;
  esac
fi

fail() {
  echo "fleet SIT proof failed: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

validate_instance_id() {
  local value="$1"
  [ -n "${value}" ] && [[ ${value} =~ ${NSC_INSTANCE_ID_PATTERN} ]] ||
    fail "invalid Namespace instance id: ${value:-<missing>}"
}

# Cleanup recovery is deliberately independent from the current proof pin. A
# newly created id must satisfy the exact 13-character contract before first
# use, but a future 13<->14 service drift must still stage the literal cid and
# destroy that exact instance rather than leak it. Limit this emergency seam to
# the two plausible lowercase-alphanumeric shapes; it is never a prefix or a
# name-wide selector.
selector_safe_cleanup_id() {
  local value="$1"
  [ -n "${value}" ] && [[ ${value} =~ ^[a-z0-9]{13,14}$ ]]
}

stage_instance_id_for_cleanup() {
  local value="$1"
  selector_safe_cleanup_id "${value}" || return 1
  instance_id="${value}"
  instance_registered=1
}

proof_tmp_root="${TMPDIR:-/tmp}"
case "${proof_tmp_root}" in
/*) ;;
*) fail "TMPDIR must be absolute: ${proof_tmp_root}" ;;
esac
[ -d "${proof_tmp_root}" ] && [ -w "${proof_tmp_root}" ] ||
  fail "TMPDIR is not a writable directory: ${proof_tmp_root}"

snapshot=''
canonical_inventory=''
commit=''
snapshot_tree=''
expected_digest=''
expected_count=''
report=''
lifecycle_dir=''
instance_id=''
instance_registered=0
created_by_harness=0
recovered_id_surface=''
destroy_attempts=0
destroy_succeeded=0
absence_proven=0
report_collected=0
report_validated=0
lifecycle_written=0
transfer_sha=''
remote_report_sha=''
failure_stage='initialization'
outer_started_epoch="$(date +%s)"
create_started_epoch=0
create_finished_epoch=0
upload_started_epoch=0
upload_finished_epoch=0
setup_started_epoch=0
setup_finished_epoch=0
inner_started_epoch=0
inner_finished_epoch=0
download_started_epoch=0
download_finished_epoch=0
destroy_started_epoch=0
destroy_finished_epoch=0

remove_snapshot() {
  [ -n "${snapshot}" ] && [ -d "${snapshot}" ] || return 0
  if [[ ${snapshot} == "${proof_tmp_root%/}"/fleet-sit-snapshot.* ]]; then
    rm -rf -- "${snapshot}"
  else
    echo "fleet SIT proof failed: declining to remove unrecognized snapshot path: ${snapshot}" >&2
    return 1
  fi
}

verify_wrapper_identity() {
  local disk_sha commit_sha
  disk_sha="$(sha256sum -- "${script_dir}/fleet-sit-proof.sh" | awk '{print $1}')"
  commit_sha="$(git -C "${checkout}" show "${commit}:scripts/ci/fleet-sit-proof.sh" | sha256sum | awk '{print $1}')"
  [ "${disk_sha}" = "${commit_sha}" ] ||
    fail 'the running wrapper differs from the wrapper committed at the recorded commit'
}

prepare_verified_snapshot() {
  git -C "${checkout}" rev-parse --git-dir >/dev/null 2>&1 ||
    fail "not a git checkout: ${checkout}"
  if [ "${mode}" = 'inner' ]; then
    commit="${FLEET_SIT_EXPECTED_HEAD:-}"
    [[ ${commit} =~ ^[0-9a-f]{40}$ ]] ||
      fail 'inner mode requires FLEET_SIT_EXPECTED_HEAD as a 40-hex commit'
    [ "$(git -C "${checkout}" rev-parse HEAD)" = "${commit}" ] ||
      fail 'the transferred checkout is not at FLEET_SIT_EXPECTED_HEAD'
  else
    commit="$(git -C "${checkout}" rev-parse HEAD)"
    [[ ${commit} =~ ^[0-9a-f]{40}$ ]] || fail 'could not resolve checkout HEAD'
  fi
  [ -z "$(git -C "${checkout}" status --porcelain --untracked-files=all)" ] ||
    fail 'the checkout must be clean so the recorded commit binds every consumed byte'
  verify_wrapper_identity

  snapshot="$(mktemp -d "${proof_tmp_root%/}/fleet-sit-snapshot.XXXXXX")"
  git clone --quiet --no-checkout "${checkout}" "${snapshot}/source"
  git -C "${snapshot}/source" checkout --quiet --detach "${commit}"
  [ "$(git -C "${snapshot}/source" rev-parse HEAD)" = "${commit}" ] ||
    fail 'the snapshot is not at the recorded commit'
  [ -z "$(git -C "${snapshot}/source" status --porcelain --untracked-files=all)" ] ||
    fail 'the snapshot is not a pristine checkout of the recorded commit'
  snapshot_tree="$(git -C "${snapshot}/source" rev-parse 'HEAD^{tree}')"
  [ "${snapshot_tree}" = "$(git -C "${checkout}" rev-parse "${commit}^{tree}")" ] ||
    fail 'the snapshot tree differs from the recorded commit tree'

  canonical_inventory="${snapshot}/expected-direct-input-inventory.sha256"
  : >"${canonical_inventory}"
  local record mode_bits type object path content_sha root
  while IFS= read -r -d '' record; do
    mode_bits="${record%% *}"
    type="$(printf '%s' "${record}" | cut -d' ' -f2)"
    object="$(printf '%s' "${record}" | cut -d' ' -f3 | cut -f1)"
    path="${record#*$'\t'}"
    [ "${type}" = 'blob' ] || fail "direct input is not a regular blob: ${path}"
    case "${mode_bits}" in
    100644 | 100755) ;;
    *) fail "direct input has an unexpected git mode: ${path}" ;;
    esac
    content_sha="$(git -C "${checkout}" cat-file blob "${object}" | sha256sum | awk '{print $1}')"
    printf '%s,%s,%s,%s,%s\n' "${mode_bits}" "${type}" "${object}" "${content_sha}" "${path}" \
      >>"${canonical_inventory}"
  done < <(git -C "${checkout}" ls-tree -r -z "${commit}" -- "${DIRECT_INPUT_ROOTS[@]}")
  LC_ALL=C sort -t, -k5 -o "${canonical_inventory}" "${canonical_inventory}"
  for root in "${DIRECT_INPUT_ROOTS[@]}"; do
    grep -q -- ",${root}\(/\|$\)" "${canonical_inventory}" ||
      fail "direct-input root resolved to no tracked entry: ${root}"
  done
  expected_digest="$(sha256sum -- "${canonical_inventory}" | awk '{print $1}')"
  expected_count="$(wc -l <"${canonical_inventory}" | tr -d ' ')"
  [ "${expected_count}" -gt 0 ] || fail 'the direct-input roots resolved to no tracked file'
}

resolve_report_path() {
  report="${FLEET_SIT_REPORT:-${checkout}/sit-report}"
  case "${report}" in
  /*) ;;
  *) report="${checkout}/${report}" ;;
  esac
  if [ -n "${snapshot}" ]; then
    case "${report}" in
    "${snapshot}/source" | "${snapshot}/source"/*)
      fail 'the report directory must live outside the execution snapshot'
      ;;
    esac
  fi
}

require_empty_report_directory() {
  if [ -L "${report}" ]; then
    fail "report path must not be a symlink: ${report}"
  fi
  if [ -e "${report}" ] && [ ! -d "${report}" ]; then
    fail "report path exists and is not a directory: ${report}"
  fi
  if [ -d "${report}" ] && [ -n "$(find "${report}" -mindepth 1 -print -quit)" ]; then
    fail "report directory must be absent or empty; preserve prior evidence elsewhere: ${report}"
  fi
}

validate_finished_report() {
  local report_file="${report}/sit-report.json"
  [ -s "${report_file}" ] || fail "no SIT report at ${report_file}"
  jq -e \
    --arg commit "${commit}" \
    --arg tree "${snapshot_tree}" \
    --arg digest "${expected_digest}" \
    --argjson count "${expected_count}" \
    --argjson roots "$(printf '%s\n' "${DIRECT_INPUT_ROOTS[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    --argjson legContract "$(printf '%s\n' "${LEG_CONTRACT[@]}" | jq -Rsc 'split("\n")[:-1]')" '
      .schemaVersion == 2 and
      .status == "pass" and
      .commit == $commit and
      .checkoutHeadAtStart == $commit and
      .checkoutHeadAtFinish == $commit and
      .checkoutCleanAtStart == true and
      .checkoutCleanAtFinish == true and
      .inputSnapshotCommit == $commit and
      .inputSnapshotTree == $tree and
      .inputSnapshotVerified == true and
      .directInputRoots == $roots and
      .directInputSha256 == $digest and
      .directInputSha256AtFinish == $digest and
      .directInputFileCount == $count and
      .directInputRecheckedAtFinish == true and
      .directInputInventory == "direct-input-inventory.sha256" and
      .harnessFileCount < .directInputFileCount and
      .legContract == $legContract and
      [.legs[].leg] == $legContract and
      all(.legs[]; .status == "pass" and (.evidence | length) > 0)
    ' "${report_file}" >/dev/null ||
    fail 'the SIT report does not satisfy the independently derived provenance contract'
  cmp -s "${canonical_inventory}" "${report}/direct-input-inventory.sha256" ||
    fail 'the recorded direct-input inventory differs from the one independently derived from git'

  local evidence
  while IFS= read -r evidence; do
    case "${evidence}" in
    /* | .. | ../* | */.. | */../*) fail "invalid evidence path in report: ${evidence}" ;;
    esac
    [ -s "${report}/${evidence}" ] || fail "declared evidence is missing or empty: ${evidence}"
  done < <(jq -r '.legs[].evidence[]' "${report_file}")
}

nsc_list_json() {
  local output="$1"
  local raw="${output}.raw"
  local list_status=0
  nsc list --output json </dev/null >"${raw}" 2>"${output}.stderr" || list_status=$?
  # The command status remains authoritative even when stdout looks complete.
  if [ "${list_status}" -ne 0 ]; then
    echo "nsc list exited ${list_status}; refusing its retained stdout" >&2
    return 1
  fi
  # Empty stdout is a distinct client failure, not an empty instance set.
  if [ ! -s "${raw}" ]; then
    echo 'nsc list returned empty stdout' >&2
    return 1
  fi
  # Never sanitize control bytes into evidence that the client did not emit.
  if LC_ALL=C grep -q $'\033' "${raw}"; then
    echo 'nsc list stdout contains an ESC byte' >&2
    return 1
  fi
  # Raw JSON evidence must be well-formed UTF-8 without byte substitution.
  if ! iconv -f UTF-8 -t UTF-8 "${raw}" >/dev/null; then
    echo 'nsc list stdout is not valid UTF-8' >&2
    return 1
  fi
  # jq must observe exactly one complete top-level null or array value.
  if ! jq -e -s '
    length == 1 and (.[0] == null or (.[0] | type) == "array")
  ' "${raw}" >/dev/null; then
    echo 'nsc list stdout is not exactly one JSON null or array value' >&2
    return 1
  fi
  cp -- "${raw}" "${output}"
}

instance_absent_from() {
  local listing="$1"
  jq -e --arg id "${instance_id}" '
    . == null or ([.[] | select(.cluster_id == $id)] | length) == 0
  ' "${listing}" >/dev/null
}

destroy_instance_and_prove_absent() {
  [ "${instance_registered}" -eq 1 ] || return 0
  [ "${destroy_succeeded}" -eq 1 ] && [ "${absence_proven}" -eq 1 ] && return 0
  selector_safe_cleanup_id "${instance_id}" || {
    echo "fleet SIT proof failed: refusing unsafe Namespace cleanup id: ${instance_id:-<missing>}" >&2
    return 1
  }
  destroy_attempts=$((destroy_attempts + 1))
  destroy_started_epoch="$(date +%s)"
  local attempt_dir="${lifecycle_dir}/destroy-attempt-${destroy_attempts}"
  mkdir -p "${attempt_dir}"
  nsc_list_json "${attempt_dir}/list-before-destroy.json" || true
  local destroy_status=0
  nsc destroy "${instance_id}" --force >"${attempt_dir}/destroy.stdout" \
    2>"${attempt_dir}/destroy.stderr" || destroy_status=$?
  printf '%s\n' "${destroy_status}" >"${attempt_dir}/destroy.exit-status"
  [ "${destroy_status}" -eq 0 ] && destroy_succeeded=1

  local list_status=1 listing list_attempt
  for list_attempt in 1 2 3 4 5 6 7 8 9 10; do
    listing="${attempt_dir}/list-after-destroy-${list_attempt}.json"
    if nsc_list_json "${listing}" && instance_absent_from "${listing}"; then
      cp -- "${listing}" "${lifecycle_dir}/list-after-destroy.json"
      absence_proven=1
      list_status=0
      break
    fi
    sleep 2
  done
  destroy_finished_epoch="$(date +%s)"
  [ "${destroy_succeeded}" -eq 1 ] && [ "${list_status}" -eq 0 ]
}

# The generated cidfile is examined as bytes and deliberately NOT repaired. A
# tolerant read is how unreviewed bytes become a destructive selector: an unsafe
# cidfile must be rejected here and superseded by a later surface, never trimmed
# into a candidate.
#
# `$(<file)` cannot do this. Bash command substitution silently drops NUL bytes,
# so a cidfile holding the pinned id followed by a NUL would read back as a
# clean exact id and the malformed surface would look authoritative. jq compares
# the raw bytes instead, and the anchors are absolute: Oniguruma's `$` also
# matches before a final newline, so `^...\n?$` would accept two trailing
# newlines, whereas `\A...\n?\z` admits only the exact 13/14-character
# lowercase-alphanumeric literal plus at most the one ordinary terminal newline.
recovery_candidate_from_cidfile() {
  local cid="${lifecycle_dir}/create.cid"
  [ -s "${cid}" ] || return 0
  jq -Rrs 'select(test("\\A[a-z0-9]{13,14}\\n?\\z")) | sub("\\n\\z"; "")' \
    "${cid}" 2>/dev/null || true
}

recovery_candidate_from_json() {
  local document="$1"
  [ -s "${document}" ] || return 0
  jq -r '.cluster_id // empty' "${document}" 2>/dev/null || true
}

# nsc leaves three independent surfaces behind for an instance this harness
# created: the generated cidfile, the full metadata receipt, and the minimal
# stdout. Each is consulted on its own in reviewed priority order.
#
# A first-NONEMPTY-surface chain is a leak. The exact product audit mutated the
# cidfile to the same 13-character id plus trailing whitespace: the chain saw a
# nonempty cidfile, rejected that literal as selector-unsafe, never read the
# still-valid receipt or stdout, failed the registration guard with a live
# instance, and repeated the same dead recovery from the EXIT trap — leaving no
# exact selector with which to destroy it. A nonempty but unsafe or unparseable
# earlier surface must therefore never suppress a later safe one.
recover_created_instance_id() {
  [ "${created_by_harness}" -eq 1 ] && [ "${instance_registered}" -ne 1 ] || return 0
  local recovery_surface candidate
  for recovery_surface in cidfile receipt stdout; do
    candidate=''
    case "${recovery_surface}" in
    cidfile) candidate="$(recovery_candidate_from_cidfile)" ;;
    receipt) candidate="$(recovery_candidate_from_json "${lifecycle_dir}/create.json")" ;;
    stdout) candidate="$(recovery_candidate_from_json "${lifecycle_dir}/create.stdout")" ;;
    esac
    if stage_instance_id_for_cleanup "${candidate}"; then
      recovered_id_surface="${recovery_surface}"
      return 0
    fi
  done
  return 1
}

write_lifecycle_report() {
  local requested_status="$1"
  [ -n "${lifecycle_dir}" ] || return 0
  local actual_status='fail'
  if [ "${requested_status}" = 'pass' ] &&
    [ "${report_collected}" -eq 1 ] && [ "${report_validated}" -eq 1 ] &&
    [ "${destroy_succeeded}" -eq 1 ] && [ "${absence_proven}" -eq 1 ]; then
    actual_status='pass'
  fi
  local receipt_path='' receipt_sha=''
  local create_stdout_path='' create_stdout_sha=''
  local create_stderr_path='' create_stderr_sha=''
  local create_cid_path='' create_cid_sha=''
  local create_argv_path='' create_argv_sha='' report_sha=''
  if [ -e "${lifecycle_dir}/create.json" ]; then
    receipt_path='lifecycle/create.json'
    receipt_sha="$(sha256sum -- "${lifecycle_dir}/create.json" | awk '{print $1}')"
  fi
  if [ -e "${lifecycle_dir}/create.stdout" ]; then
    create_stdout_path='lifecycle/create.stdout'
    create_stdout_sha="$(sha256sum -- "${lifecycle_dir}/create.stdout" | awk '{print $1}')"
  fi
  if [ -e "${lifecycle_dir}/create.stderr" ]; then
    create_stderr_path='lifecycle/create.stderr'
    create_stderr_sha="$(sha256sum -- "${lifecycle_dir}/create.stderr" | awk '{print $1}')"
  fi
  if [ -e "${lifecycle_dir}/create.cid" ]; then
    create_cid_path='lifecycle/create.cid'
    create_cid_sha="$(sha256sum -- "${lifecycle_dir}/create.cid" | awk '{print $1}')"
  fi
  if [ -e "${lifecycle_dir}/create-argv.json" ]; then
    create_argv_path='lifecycle/create-argv.json'
    create_argv_sha="$(sha256sum -- "${lifecycle_dir}/create-argv.json" | awk '{print $1}')"
  fi
  [ -s "${report}/sit-report.json" ] &&
    report_sha="$(sha256sum -- "${report}/sit-report.json" | awk '{print $1}')"
  jq -n \
    --arg status "${actual_status}" \
    --arg failureStage "${failure_stage}" \
    --arg commit "${commit}" \
    --arg tree "${snapshot_tree}" \
    --arg directInputSha256 "${expected_digest}" \
    --argjson directInputFileCount "${expected_count:-0}" \
    --arg instanceId "${instance_id}" \
    --arg recoveredIdSurface "${recovered_id_surface}" \
    --arg createReceipt "${receipt_path}" \
    --arg createReceiptSha256 "${receipt_sha}" \
    --arg createStdout "${create_stdout_path}" \
    --arg createStdoutSha256 "${create_stdout_sha}" \
    --arg createStderr "${create_stderr_path}" \
    --arg createStderrSha256 "${create_stderr_sha}" \
    --arg createCid "${create_cid_path}" \
    --arg createCidSha256 "${create_cid_sha}" \
    --arg createArgv "${create_argv_path}" \
    --arg createArgvSha256 "${create_argv_sha}" \
    --arg transferSha256 "${transfer_sha}" \
    --arg remoteReportArchiveSha256 "${remote_report_sha}" \
    --arg innerReport 'sit-report.json' \
    --arg innerReportSha256 "${report_sha}" \
    --arg nscVersion 'lifecycle/nsc-version.txt' \
    --arg platformEvidence 'namespace-platform.json' \
    --argjson createdByHarness "${created_by_harness}" \
    --argjson reportCollected "${report_collected}" \
    --argjson reportValidated "${report_validated}" \
    --argjson destroyAttempts "${destroy_attempts}" \
    --argjson destroySucceeded "${destroy_succeeded}" \
    --argjson absenceProven "${absence_proven}" \
    --argjson outerStarted "${outer_started_epoch}" \
    --argjson createStarted "${create_started_epoch}" \
    --argjson createFinished "${create_finished_epoch}" \
    --argjson uploadStarted "${upload_started_epoch}" \
    --argjson uploadFinished "${upload_finished_epoch}" \
    --argjson setupStarted "${setup_started_epoch}" \
    --argjson setupFinished "${setup_finished_epoch}" \
    --argjson innerStarted "${inner_started_epoch}" \
    --argjson innerFinished "${inner_finished_epoch}" \
    --argjson downloadStarted "${download_started_epoch}" \
    --argjson downloadFinished "${download_finished_epoch}" \
    --argjson destroyStarted "${destroy_started_epoch}" \
    --argjson destroyFinished "${destroy_finished_epoch}" '
      {
        schemaVersion:1,status:$status,failureStage:$failureStage,
        source:{commit:$commit,tree:$tree,directInputSha256:$directInputSha256,directInputFileCount:$directInputFileCount},
        namespace:{
          instanceId:$instanceId,createdByHarness:($createdByHarness == 1),
          recoveredIdSurface:$recoveredIdSurface,
          createReceipt:$createReceipt,createReceiptSha256:$createReceiptSha256,
          createStdout:$createStdout,createStdoutSha256:$createStdoutSha256,
          createStderr:$createStderr,createStderrSha256:$createStderrSha256,
          createCid:$createCid,createCidSha256:$createCidSha256,
          createArgv:$createArgv,createArgvSha256:$createArgvSha256,
          nscVersion:$nscVersion,
          platformEvidence:$platformEvidence
        },
        transfer:{snapshotArchiveSha256:$transferSha256,remoteReportArchiveSha256:$remoteReportArchiveSha256},
        innerReport:{path:$innerReport,sha256:$innerReportSha256,collected:($reportCollected == 1),validated:($reportValidated == 1)},
        cleanup:{destroyAttempts:$destroyAttempts,destroySucceeded:($destroySucceeded == 1),exactIdAbsenceProven:($absenceProven == 1)},
        timings:{
          outerStartedEpoch:$outerStarted,
          create:{startedEpoch:$createStarted,finishedEpoch:$createFinished},
          upload:{startedEpoch:$uploadStarted,finishedEpoch:$uploadFinished},
          setup:{startedEpoch:$setupStarted,finishedEpoch:$setupFinished},
          inner:{startedEpoch:$innerStarted,finishedEpoch:$innerFinished},
          download:{startedEpoch:$downloadStarted,finishedEpoch:$downloadFinished},
          destroy:{startedEpoch:$destroyStarted,finishedEpoch:$destroyFinished}
        },
        passLaw:"pass is impossible until report collection, independent report validation, exact-id destroy, and exact-id absence all succeed"
      }
    ' >"${lifecycle_dir}/lifecycle.json"
  [ "${requested_status}" != 'pass' ] || [ "${actual_status}" = 'pass' ] ||
    fail 'lifecycle pass was requested before every collection and cleanup predicate was proven'
}

cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  set +e
  # A signal may arrive after nsc has written its output but before the
  # foreground create call returns to acquire_instance. Recover only that
  # freshly scoped exact id, trying each create surface independently, so the
  # signal path still destroys and proves absence even when one surface is
  # malformed; no unsafe or unparseable literal can ever become a selector.
  if [ "${mode}" = 'full' ] && [ -n "${lifecycle_dir}" ]; then
    recover_created_instance_id
  fi
  if [ "${mode}" = 'full' ] && [ "${instance_registered}" -eq 1 ] &&
    { [ "${destroy_succeeded}" -ne 1 ] || [ "${absence_proven}" -ne 1 ]; }; then
    destroy_instance_and_prove_absent || rc=1
  fi
  if [ "${mode}" = 'full' ] && [ "${lifecycle_written}" -ne 1 ] && [ -n "${lifecycle_dir}" ]; then
    mkdir -p "${lifecycle_dir}" || rc=1
    write_lifecycle_report fail || rc=1
  fi
  remove_snapshot || rc=1
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_nsc_version() {
  nsc version >"${lifecycle_dir}/nsc-version.txt" 2>&1
  grep -Fx "version ${NSC_CLI_VERSION} (commit ${NSC_CLI_COMMIT})" \
    "${lifecycle_dir}/nsc-version.txt" >/dev/null ||
    fail "nsc client is not pinned ${NSC_CLI_VERSION} at ${NSC_CLI_COMMIT}"
}

stage_precreated_instance_for_cleanup() {
  local provided_id="${FLEET_SIT_NSC_INSTANCE_ID:-}"
  local provided_receipt="${FLEET_SIT_NSC_CREATE_RECEIPT:-}"
  [ -n "${provided_id}" ] || [ -n "${provided_receipt}" ] || return 0
  validate_instance_id "${provided_id}"
  instance_id="${provided_id}"
  instance_registered=1
}

# Falling back past a malformed cidfile keeps the instance destroyable; it must
# not also make the malformed cidfile acceptable. Once an exact id is pinned, the
# generated cidfile must itself be exactly that id, plus at most the ordinary
# terminal newline that Bash command substitution removes.
#
# This is a byte-exact digest comparison because no read-and-compare can do the
# job: command substitution silently drops NUL bytes, so the pinned id followed
# by a NUL reads back as the pinned id at a length any newline allowance
# accepts. Digest the retained bytes and admit only the two literals nsc may
# legitimately have written.
validate_create_cidfile() {
  local cid="${lifecycle_dir}/create.cid"
  [ -s "${cid}" ] || fail 'the generated Namespace cidfile is missing or empty'
  local actual bare_expected newline_expected
  actual="$(sha256sum -- "${cid}")"
  actual="${actual%% *}"
  bare_expected="$(printf '%s' "${instance_id}" | sha256sum)"
  bare_expected="${bare_expected%% *}"
  newline_expected="$(printf '%s\n' "${instance_id}" | sha256sum)"
  newline_expected="${newline_expected%% *}"
  [ "${actual}" = "${bare_expected}" ] || [ "${actual}" = "${newline_expected}" ] ||
    fail 'the generated Namespace cidfile is not exactly the pinned instance id'
}

validate_create_stdout() {
  local stdout="${lifecycle_dir}/create.stdout"
  [ -s "${stdout}" ] || fail 'Namespace create stdout is missing or empty'
  jq -e --arg id "${instance_id}" '
    .cluster_id == $id and .instance_id == $id
  ' "${stdout}" >/dev/null ||
    fail 'Namespace create stdout disagrees with the exact created instance id'
}

validate_create_receipt() {
  local receipt="${lifecycle_dir}/create.json"
  [ -s "${receipt}" ] || fail 'Namespace create receipt is missing or empty'
  jq -e \
    --arg id "${instance_id}" \
    --argjson cpu "${NSC_VCPU}" \
    --argjson memory "${NSC_MEMORY_MEGABYTES}" \
    --arg arch "${NSC_MACHINE_ARCH}" \
    --arg os "${NSC_MACHINE_OS}" \
    --arg kubernetes "${NSC_KUBERNETES_VERSION}" \
    --arg distribution "${NSC_KUBERNETES_DISTRIBUTION}" \
    --argjson duration "${NSC_DURATION_SECONDS}" '
      def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      .cluster_id == $id and
      .shape.virtual_cpu == $cpu and
      .shape.memory_megabytes == $memory and
      .shape.machine_arch == $arch and
      .shape.os == $os and
      .kubernetes_distribution == $distribution and
      any(.label[]?; .name == "nsc.kubernetes" and .value == $kubernetes) and
      any(.service_state[]?; .name == "ssh" and .status == "READY") and
      any(.service_state[]?; .name == "kubernetes" and .status == "READY") and
      ((.deadline | epoch) - (.created | epoch)) >= ($duration - 1) and
      ((.deadline | epoch) - (.created | epoch)) <= ($duration + 1)
    ' "${receipt}" >/dev/null ||
    fail 'Namespace create receipt disagrees with the reviewed id, shape, duration, or Kubernetes pins'
}

validate_live_instance() {
  local listing="${lifecycle_dir}/list-before-use.json"
  nsc_list_json "${listing}" || fail 'could not list Namespace instances before first use'
  jq -e \
    --arg id "${instance_id}" \
    --arg nodeKey "${NSC_LABEL_NODE_KEY}" \
    --arg nodeValue "${NSC_LABEL_NODE_VALUE}" \
    --arg generationKey "${NSC_LABEL_GENERATION_KEY}" \
    --arg generationValue "${NSC_LABEL_GENERATION_VALUE}" \
    --argjson cpu "${NSC_VCPU}" \
    --argjson memory "${NSC_MEMORY_MEGABYTES}" \
    --arg arch "${NSC_MACHINE_ARCH}" \
    --arg os "${NSC_MACHINE_OS}" '
      [.[] | select(.cluster_id == $id)] as $matches |
      ($matches | length) == 1 and
      $matches[0].labels[$nodeKey] == $nodeValue and
      $matches[0].labels[$generationKey] == $generationValue and
      $matches[0].shape.virtual_cpu == $cpu and
      $matches[0].shape.memory_megabytes == $memory and
      $matches[0].shape.machine_arch == $arch and
      $matches[0].shape.os == $os
    ' "${listing}" >/dev/null ||
    fail 'live Namespace instance disagrees with exact id, labels, or reviewed shape'
}

acquire_instance() {
  local provided_id="${FLEET_SIT_NSC_INSTANCE_ID:-}"
  local provided_receipt="${FLEET_SIT_NSC_CREATE_RECEIPT:-}"
  if [ -n "${provided_id}" ] || [ -n "${provided_receipt}" ]; then
    validate_instance_id "${provided_id}"
    instance_id="${provided_id}"
    instance_registered=1
    [ -n "${provided_receipt}" ] || fail 'pre-created instance id requires FLEET_SIT_NSC_CREATE_RECEIPT'
    case "${provided_receipt}" in
    /*) ;;
    *) fail 'FLEET_SIT_NSC_CREATE_RECEIPT must be an absolute path' ;;
    esac
    [ -s "${provided_receipt}" ] || fail "pre-created instance receipt is missing: ${provided_receipt}"
    cp -- "${provided_receipt}" "${lifecycle_dir}/create.json"
    jq -n '{
      executable:null,subcommand:null,argv:null,source:"lead-provided",
      note:"the outer wrapper did not create this pre-registered instance"
    }' >"${lifecycle_dir}/create-argv.json"
    create_started_epoch="$(date +%s)"
    create_finished_epoch="${create_started_epoch}"
  else
    created_by_harness=1
    local cid="${lifecycle_dir}/create.cid"
    local receipt="${lifecycle_dir}/create.json"
    local -a create_args=(
      --ephemeral
      --duration "${NSC_DURATION}"
      --machine_type "${NSC_MACHINE_TYPE}"
      --enable="kubernetes:${NSC_KUBERNETES_VERSION}"
      --wait_kube_system
      --label "${NSC_LABEL_NODE_KEY}=${NSC_LABEL_NODE_VALUE}"
      --label "${NSC_LABEL_GENERATION_KEY}=${NSC_LABEL_GENERATION_VALUE}"
      --purpose "${NSC_PURPOSE}"
      --cidfile "${cid}"
      --output json
      --output_json_to "${receipt}"
    )
    printf '%s\n' "${create_args[@]}" | jq -Rsc '{
      executable:"nsc",subcommand:"create",argv:(split("\n")[:-1]),source:"outer-wrapper"
    }' \
      >"${lifecycle_dir}/create-argv.json"
    create_started_epoch="$(date +%s)"
    local create_status=0
    nsc create "${create_args[@]}" >"${lifecycle_dir}/create.stdout" \
      2>"${lifecycle_dir}/create.stderr" || create_status=$?
    create_finished_epoch="$(date +%s)"
    # Stage a conservative literal for exact cleanup before either the command
    # status or the pinned proof contract can refuse this create.
    recover_created_instance_id || true
    [ "${create_status}" -eq 0 ] || fail "nsc create exited ${create_status}"
    [ "${instance_registered}" -eq 1 ] || fail 'nsc create returned no exact instance id'
    validate_instance_id "${instance_id}"
    validate_create_cidfile
    validate_create_stdout
  fi
  validate_create_receipt
  validate_live_instance
}

run_prepare() {
  failure_stage='prepare-only'
  FLEET_SIT_REPORT="${report}" \
    bash "${snapshot}/source/scripts/ci/fleet-sit.sh" --prepare-only
  [ "$(git -C "${checkout}" rev-parse HEAD)" = "${commit}" ] ||
    fail 'checkout HEAD changed during prepare-only'
  [ -z "$(git -C "${checkout}" status --porcelain --untracked-files=all)" ] ||
    fail 'checkout became dirty during prepare-only'
  echo "fleet SIT prepare-only passed from a verified snapshot of ${commit}"
}

run_inner() {
  [ "${FLEET_SIT_NAMESPACE_INNER:-}" = 'namespace-k3s-v1' ] ||
    fail 'inner mode requires the explicit Namespace recursion marker'
  validate_instance_id "${FLEET_SIT_INSTANCE_ID:-}"
  [ "$(hostname)" = "${FLEET_SIT_INSTANCE_ID}" ] ||
    fail 'inner wrapper hostname does not equal the exact Namespace instance id'
  failure_stage='inner-proof'
  FLEET_SIT_NAMESPACE_INNER='namespace-k3s-v1' \
    FLEET_SIT_INSTANCE_ID="${FLEET_SIT_INSTANCE_ID}" \
    FLEET_SIT_CHECKOUT="${checkout}" \
    FLEET_SIT_EXPECTED_HEAD="${commit}" \
    FLEET_SIT_REPORT="${report}" \
    bash "${snapshot}/source/scripts/ci/fleet-sit.sh" --full
  validate_finished_report
  echo "fleet SIT inner proof passed on Namespace instance ${FLEET_SIT_INSTANCE_ID}"
}

validate_download_archive() {
  local archive="$1"
  local listing="${archive}.listing"
  tar -tzf "${archive}" >"${listing}"
  [ -s "${listing}" ] || fail 'downloaded report archive is empty'
  local entry
  while IFS= read -r entry; do
    case "${entry}" in
    sit-report | sit-report/*) ;;
    *) fail "downloaded report archive has an invalid member: ${entry}" ;;
    esac
    case "${entry}" in
    /* | *'/../'* | ../* | */..) fail "downloaded report archive escapes its root: ${entry}" ;;
    esac
  done <"${listing}"
}

run_outer() {
  for command in bash date git iconv jq nsc sha256sum tar timeout; do
    require_command "${command}"
  done
  validate_nsc_version

  failure_stage='instance-acquisition'
  acquire_instance

  failure_stage='hostname-preflight'
  nsc ssh --disable-pty "${instance_id}" hostname \
    >"${lifecycle_dir}/hostname.txt" 2>"${lifecycle_dir}/hostname.stderr"
  [ "$(tr -d '[:space:]' <"${lifecycle_dir}/hostname.txt")" = "${instance_id}" ] ||
    fail 'Namespace hostname does not equal the exact instance id'

  local transfer_archive="${snapshot}/fleet-sit-source.tgz"
  tar -czf "${transfer_archive}" -C "${snapshot}" source
  transfer_sha="$(sha256sum -- "${transfer_archive}" | awk '{print $1}')"
  local remote_root="/tmp/fleet-sit-${instance_id}"
  local remote_archive="${remote_root}/source.tgz"
  local remote_report="${remote_root}/result/sit-report"
  local remote_report_archive="${remote_root}/result/sit-report.tgz"

  failure_stage='snapshot-upload'
  upload_started_epoch="$(date +%s)"
  nsc instance upload "${instance_id}" "${transfer_archive}" "${remote_archive}" --mkdir \
    >"${lifecycle_dir}/upload.stdout" 2>"${lifecycle_dir}/upload.stderr"
  upload_finished_epoch="$(date +%s)"

  failure_stage='snapshot-setup'
  local setup_command
  setup_command="test ! -e '${remote_root}/source' && mkdir -p '${remote_root}/result' && tar -xzf '${remote_archive}' -C '${remote_root}' && printf '%s  %s\\n' '${transfer_sha}' '${remote_archive}' | sha256sum --check"
  setup_started_epoch="$(date +%s)"
  nsc ssh --disable-pty "${instance_id}" sh -eu -c "${setup_command}" \
    >"${lifecycle_dir}/setup.txt" 2>"${lifecycle_dir}/setup.stderr"
  setup_finished_epoch="$(date +%s)"

  failure_stage='inner-run'
  inner_started_epoch="$(date +%s)"
  local inner_status=0
  timeout --signal=TERM --kill-after=30s 5400 \
    nsc ssh --disable-pty "${instance_id}" env \
    FLEET_SIT_NAMESPACE_INNER=namespace-k3s-v1 \
    FLEET_SIT_INSTANCE_ID="${instance_id}" \
    FLEET_SIT_EXPECTED_HEAD="${commit}" \
    FLEET_SIT_REPORT="${remote_report}" \
    bash "${remote_root}/source/scripts/ci/fleet-sit-proof.sh" --inner \
    >"${lifecycle_dir}/inner-run.log" 2>&1 || inner_status=$?
  inner_finished_epoch="$(date +%s)"
  [ "${inner_status}" -eq 0 ] || fail "on-instance inner proof exited ${inner_status}"

  failure_stage='remote-report-collection'
  local archive_command
  archive_command="test -s '${remote_report}/sit-report.json' && tar -czf '${remote_report_archive}' -C '${remote_root}/result' sit-report && sha256sum '${remote_report_archive}'"
  nsc ssh --disable-pty "${instance_id}" sh -eu -c "${archive_command}" \
    >"${lifecycle_dir}/remote-report-sha256.txt" \
    2>"${lifecycle_dir}/remote-report-archive.stderr"
  remote_report_sha="$(awk 'NR == 1 {print $1}' "${lifecycle_dir}/remote-report-sha256.txt")"
  [[ ${remote_report_sha} =~ ^[0-9a-f]{64}$ ]] || fail 'remote report archive digest is invalid'

  failure_stage='report-download'
  local downloaded_archive="${snapshot}/sit-report.tgz"
  download_started_epoch="$(date +%s)"
  nsc instance download "${instance_id}" "${remote_report_archive}" "${downloaded_archive}" \
    >"${lifecycle_dir}/download.stdout" 2>"${lifecycle_dir}/download.stderr"
  download_finished_epoch="$(date +%s)"
  [ "$(sha256sum -- "${downloaded_archive}" | awk '{print $1}')" = "${remote_report_sha}" ] ||
    fail 'downloaded report archive digest differs from the on-instance digest'
  validate_download_archive "${downloaded_archive}"
  tar --no-same-owner --no-same-permissions -xzf "${downloaded_archive}" \
    --strip-components=1 -C "${report}"
  report_collected=1

  failure_stage='report-validation'
  validate_finished_report
  report_validated=1
  [ "$(git -C "${checkout}" rev-parse HEAD)" = "${commit}" ] ||
    fail 'checkout HEAD changed during outer proof'
  [ -z "$(git -C "${checkout}" status --porcelain --untracked-files=all)" ] ||
    fail 'checkout became dirty during outer proof'

  failure_stage='exact-id-destroy-and-absence'
  destroy_instance_and_prove_absent || fail 'exact-id destroy or absence proof failed'
  failure_stage='complete'
  write_lifecycle_report pass
  lifecycle_written=1
  echo "fleet SIT passed from a verified snapshot of ${commit}"
  echo "  report:        ${report}/sit-report.json"
  echo "  lifecycle:     ${lifecycle_dir}/lifecycle.json"
  echo "  instance id:   ${instance_id} (destroyed and absent)"
}

for command in bash git jq sha256sum; do
  require_command "${command}"
done

# Reserve the evidence directory and accept a syntactically exact pre-created
# id before source or nsc-version preflight. From this point the wrapper owns
# exact-id cleanup even if either preflight refuses. Errors before this boundary
# have not accepted the handoff and cannot safely write into its evidence path.
if [ "${mode}" = 'full' ]; then
  resolve_report_path
  require_empty_report_directory
  lifecycle_dir="${report}/lifecycle"
  stage_precreated_instance_for_cleanup
  failure_stage='source-snapshot-preflight'
fi
prepare_verified_snapshot
if [ "${mode}" = 'full' ]; then
  # Recheck after snapshot creation to close both a path race and the rule that
  # lifecycle evidence must not be written inside the execution snapshot.
  resolve_report_path
  require_empty_report_directory
  mkdir -p "${lifecycle_dir}"
else
  resolve_report_path
fi

case "${mode}" in
prepare)
  run_prepare
  ;;
inner)
  require_empty_report_directory
  run_inner
  ;;
full)
  run_outer
  ;;
esac
