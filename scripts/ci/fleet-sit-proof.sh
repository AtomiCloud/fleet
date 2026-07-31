#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

# Required entry point for the fleet SIT proof.
#
# WHY A WRAPPER. `scripts/ci/fleet-sit.sh` and everything it sources are read
# before any in-script guard can run, and the SIT's direct inputs are read over
# many minutes. A cleanliness check at start and finish cannot see a direct
# input that changes in between and is restored before the end - the report
# would still name the original clean commit. This wrapper closes that route by
# construction: the SIT executes from a throwaway snapshot of the recorded
# commit, so the live checkout is never the source of a consumed byte.
#
# It also re-derives the direct-input inventory from git INDEPENDENTLY and
# compares it with the one the SIT recorded. The root list below is this
# script's own; a report may never define its own coverage.
#
# Never mutates the original checkout: the snapshot is a clone, not a worktree
# registration, and the report is written outside both trees.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checkout="$(cd "${script_dir}/../.." && pwd)"

# This wrapper's own copy of the fixed direct-input roots. It must agree with
# scripts/ci/fleet-sit.sh; disagreement fails the run rather than being
# silently reconciled.
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

# This list is deliberately owned by the wrapper. The report and the worker
# cannot define their own coverage and thereby make a dropped leg look valid.
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

mode='full'
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--prepare-only|--full]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  case "$1" in
  --prepare-only) mode='prepare' ;;
  --full) mode='full' ;;
  *)
    echo "usage: $0 [--prepare-only|--full]" >&2
    exit 2
    ;;
  esac
fi

fail() {
  echo "fleet SIT proof failed: $*" >&2
  exit 1
}

snapshot=''
proof_tmp_root="${TMPDIR:-/tmp}"
case "${proof_tmp_root}" in
/*) ;;
*) fail "TMPDIR must be absolute: ${proof_tmp_root}" ;;
esac
[ -d "${proof_tmp_root}" ] && [ -w "${proof_tmp_root}" ] ||
  fail "TMPDIR is not a writable directory: ${proof_tmp_root}"

verify_zero_fleet_sit_clusters() {
  local listing status=0
  listing="$(k3d cluster list --no-headers 2>&1)" || status=$?
  if [ "${status}" -ne 0 ]; then
    echo "fleet SIT proof failed: could not verify the zero-cluster guarantee: k3d exited ${status}: ${listing}" >&2
    return 1
  fi
  if awk '{print $1}' <<<"${listing}" | grep -q '^fleet-sit-'; then
    echo 'fleet SIT proof failed: a fleet-sit k3d cluster survived the run' >&2
    return 1
  fi
}

cleanup() {
  local rc=$?
  local cleanup_failed=0
  trap - EXIT
  if [ "${mode}" = 'full' ]; then
    verify_zero_fleet_sit_clusters || cleanup_failed=1
  fi
  if [ -n "${snapshot}" ] && [ -d "${snapshot}" ]; then
    if [[ ${snapshot} == "${proof_tmp_root%/}"/fleet-sit-snapshot.* ]]; then
      rm -rf -- "${snapshot}"
    else
      echo "fleet SIT proof failed: declining to remove unrecognized snapshot path: ${snapshot}" >&2
      cleanup_failed=1
    fi
  fi
  if [ "${cleanup_failed}" -ne 0 ]; then
    rc=1
  fi
  exit "${rc}"
}
trap cleanup EXIT

for command in bun git jq k3d sha256sum; do
  command -v "${command}" >/dev/null 2>&1 || fail "required command is missing: ${command}"
done

cd "${checkout}"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: ${checkout}"
commit="$(git rev-parse HEAD)"
[[ ${commit} =~ ^[0-9a-f]{40}$ ]] || fail 'could not resolve the checkout HEAD'
[ -z "$(git status --porcelain --untracked-files=all)" ] ||
  fail 'the checkout must be clean so the recorded commit binds every consumed byte'

report="${FLEET_SIT_REPORT:-${checkout}/sit-report}"
case "${report}" in
/*) ;;
*) report="${checkout}/${report}" ;;
esac

# The wrapper's own bytes were read before this check, so its provenance is
# recorded rather than assumed: the digest of the running file is compared with
# the blob committed at the recorded commit.
wrapper_disk_sha="$(sha256sum -- "${script_dir}/fleet-sit-proof.sh" | awk '{print $1}')"
wrapper_commit_sha="$(git show "${commit}:scripts/ci/fleet-sit-proof.sh" | sha256sum | awk '{print $1}')"
[ "${wrapper_disk_sha}" = "${wrapper_commit_sha}" ] ||
  fail 'the running wrapper differs from the wrapper committed at the recorded commit'

# --- verified snapshot ------------------------------------------------------
snapshot="$(mktemp -d "${proof_tmp_root%/}/fleet-sit-snapshot.XXXXXX")"
git clone --quiet --no-checkout "${checkout}" "${snapshot}/source"
git -C "${snapshot}/source" checkout --quiet --detach "${commit}"
snapshot_root="${snapshot}/source"

[ "$(git -C "${snapshot_root}" rev-parse HEAD)" = "${commit}" ] ||
  fail 'the snapshot is not at the recorded commit'
[ -z "$(git -C "${snapshot_root}" status --porcelain --untracked-files=all)" ] ||
  fail 'the snapshot is not a pristine checkout of the recorded commit'
snapshot_tree="$(git -C "${snapshot_root}" rev-parse 'HEAD^{tree}')"
[ "${snapshot_tree}" = "$(git rev-parse "${commit}^{tree}")" ] ||
  fail 'the snapshot tree differs from the recorded commit tree'
case "${report}" in
"${snapshot_root}" | "${snapshot_root}"/*)
  fail 'the report directory must live outside the snapshot'
  ;;
esac

# --- independent direct-input inventory ------------------------------------
canonical_inventory="${snapshot}/expected-direct-input-inventory.sha256"
: >"${canonical_inventory}"
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
  content_sha="$(git cat-file blob "${object}" | sha256sum | awk '{print $1}')"
  printf '%s,%s,%s,%s,%s\n' "${mode_bits}" "${type}" "${object}" "${content_sha}" "${path}" \
    >>"${canonical_inventory}"
done < <(git ls-tree -r -z "${commit}" -- "${DIRECT_INPUT_ROOTS[@]}")
LC_ALL=C sort -t, -k5 -o "${canonical_inventory}" "${canonical_inventory}"
expected_digest="$(sha256sum -- "${canonical_inventory}" | awk '{print $1}')"
expected_count="$(wc -l <"${canonical_inventory}" | tr -d ' ')"
[ "${expected_count}" -gt 0 ] || fail 'the direct-input roots resolved to no tracked file'

if [ "${mode}" = 'prepare' ]; then
  FLEET_SIT_REPORT="${report}" \
    bash "${snapshot_root}/scripts/ci/fleet-sit.sh" --prepare-only
  [ "$(git rev-parse HEAD)" = "${commit}" ] || fail 'the checkout HEAD changed during prepare-only'
  [ -z "$(git status --porcelain --untracked-files=all)" ] ||
    fail 'the checkout became dirty during prepare-only'
  echo "fleet SIT prepare-only passed from a verified snapshot of ${commit}"
  exit 0
fi

# --- the SIT itself, from the snapshot -------------------------------------
sit_status=0
FLEET_SIT_CHECKOUT="${checkout}" \
  FLEET_SIT_EXPECTED_HEAD="${commit}" \
  FLEET_SIT_REPORT="${report}" \
  bash "${snapshot_root}/scripts/ci/fleet-sit.sh" --full || sit_status=$?
[ "${sit_status}" -eq 0 ] || fail "the SIT exited ${sit_status}"

# --- independent validation of the finished report -------------------------
[ "$(git rev-parse HEAD)" = "${commit}" ] || fail 'the checkout HEAD changed during the SIT'
[ -z "$(git status --porcelain --untracked-files=all)" ] ||
  fail 'the checkout became dirty during the SIT'

report_file="${report}/sit-report.json"
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
  fail 'the recorded direct-input inventory differs from the one derived here from git'

# Declared evidence must exist and be non-empty, and no leg may claim a file
# outside its report directory.
while IFS= read -r evidence; do
  case "${evidence}" in
  /* | .. | ../* | */.. | */../*) fail "invalid evidence path in the report: ${evidence}" ;;
  esac
  [ -s "${report}/${evidence}" ] || fail "declared evidence is missing or empty: ${evidence}"
done < <(jq -r '.legs[].evidence[]' "${report_file}")

echo "fleet SIT passed from a verified snapshot of ${commit}"
echo "  report:          ${report_file}"
echo "  direct inputs:   ${expected_count} files, digest ${expected_digest}"
