#!/usr/bin/env bash
set -euo pipefail

# Live authorization probes for the periodic public sandbox only. Production
# AtomiCloud/fleet is an explicit refusal. Every denied REST request captures
# the HTTP status and response body separately; only a narrow ruleset-policy
# response is accepted as proof, never a scope, endpoint, or transient error.

readonly production_repo='AtomiCloud/fleet'
readonly expected_sandbox='AtomiCloud/fleet-guard-sandbox'
readonly stable_ref='refs/tags/machinery-stable'
readonly ordinary_fixture_workflow='ordinary-token-guard-e2e.yaml'

fail() {
  echo "❌ $1" >&2
  exit 1
}

classify_policy_denial() {
  local status="$1"
  local body_file="$2"

  case "${status}" in
  403 | 422) ;;
  *) return 1 ;;
  esac

  jq -e '
    def denial_text:
      [
        .message? // empty,
        .documentation_url? // empty,
        (.errors[]? |
          if type == "object" then
            .message? // empty,
            .code? // empty,
            .field? // empty
          else
            tostring
          end)
      ] | join("\n");
    denial_text as $text
    | (($text | test("(?i)(not[[:space:]-]*found|resource[[:space:]-]*not[[:space:]-]*accessible|reference[[:space:]-]*already[[:space:]-]*exists)")) | not)
    and ($text | test("(?i)(repository[[:space:]-]*(rule|ruleset)|ruleset|protected[[:space:]-]*(branch|ref|tag)|bypass)"))
  ' "${body_file}" >/dev/null
}

# Offline contract used by the deterministic validator. A generic 422, an
# unavailable repository, or a missing-scope 403 must fail this classifier.
if [ "${1:-}" = '--classify-policy-denial' ]; then
  [ "$#" -eq 3 ] || fail "usage: $0 --classify-policy-denial STATUS BODY_JSON"
  [[ $2 =~ ^[0-9]{3}$ ]] || fail 'HTTP status must have three digits'
  [ -s "$3" ] || fail 'policy-denial body fixture is missing'
  classify_policy_denial "$2" "$3" ||
    fail "HTTP $2/body fixture is not an exact GitHub ruleset-policy denial"
  exit 0
fi

mode="${1:-}"
[ "$#" -eq 1 ] || fail "usage: $0 <setup-absent|setup-base|create-denied|update-delete-denied|force-update-denied|ordinary-create-denied|ordinary-update-delete-denied|main-denied|a33-boundaries|cleanup>"
: "${GH_TOKEN:?GH_TOKEN is required}"
sandbox_repo="${FLEET_GUARD_SANDBOX_REPOSITORY:?set FLEET_GUARD_SANDBOX_REPOSITORY}"
[ "${sandbox_repo}" != "${production_repo}" ] || fail 'live guard e2e must never target production AtomiCloud/fleet'
[ "${sandbox_repo}" = "${expected_sandbox}" ] || fail "unexpected sandbox ${sandbox_repo}; expected ${expected_sandbox}"

backtrack_sha="${FLEET_GUARD_BACKTRACK_SHA:-}"
forward_sha="${FLEET_GUARD_FORWARD_SHA:-}"
if [ "${mode}" != 'setup-absent' ]; then
  [[ ${backtrack_sha} =~ ^[0-9a-f]{40}$ ]] || fail 'FLEET_GUARD_BACKTRACK_SHA must be a full SHA'
  [[ ${forward_sha} =~ ^[0-9a-f]{40}$ ]] || fail 'FLEET_GUARD_FORWARD_SHA must be a full SHA'
fi

run_key="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
[[ ${run_key} =~ ^[0-9]+-[0-9]+$ ]] || fail 'run identity must be numeric'
scratch_ref="refs/heads/guard-e2e-a33-${run_key}"
other_tag_ref="refs/tags/guard-e2e-a33-forbidden-${run_key}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
api_request_count=0
api_response_status=''
api_response_body=''

capture_api_response() {
  local method="$1"
  local endpoint="$2"
  local payload="${3:-}"

  api_request_count=$((api_request_count + 1))
  api_response_body="${tmp_dir}/api-response-${api_request_count}.json"
  if [ -n "${payload}" ]; then
    api_response_status="$(printf '%s' "${payload}" | curl \
      --silent --show-error --connect-timeout 15 --max-time 60 \
      --request "${method}" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      --output "${api_response_body}" \
      --write-out '%{http_code}' \
      "https://api.github.com/${endpoint}")" ||
      fail "${method} ${endpoint} did not reach the GitHub API"
  else
    api_response_status="$(curl \
      --silent --show-error --connect-timeout 15 --max-time 60 \
      --request "${method}" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --output "${api_response_body}" \
      --write-out '%{http_code}' \
      "https://api.github.com/${endpoint}")" ||
      fail "${method} ${endpoint} did not reach the GitHub API"
  fi
  [[ ${api_response_status} =~ ^[0-9]{3}$ ]] ||
    fail "${method} ${endpoint} returned an invalid HTTP status ${api_response_status:-empty}"
}

api_expect_policy_denied() {
  local label="$1"
  local method="$2"
  local endpoint="$3"
  local payload="${4:-}"

  capture_api_response "${method}" "${endpoint}" "${payload}"
  classify_policy_denial "${api_response_status}" "${api_response_body}" ||
    fail "${label} was not an exact ruleset-policy denial (HTTP ${api_response_status}; refusing scope, endpoint, generic-422, and transient failures)"
  echo "✅ policy denial: ${label} (HTTP ${api_response_status})"
}

exact_ref_json() {
  local ref="$1"
  local suffix="${ref#refs/}"
  local prefix="${suffix%/*}/${suffix##*/}"
  gh api --method GET "repos/${sandbox_repo}/git/matching-refs/${prefix}" |
    jq -c --arg ref "${ref}" '[.[] | select(.ref == $ref)]'
}

assert_ref_absent() {
  local ref="$1"
  local exact
  exact="$(exact_ref_json "${ref}")"
  [ "$(jq 'length' <<<"${exact}")" -eq 0 ] ||
    fail "endpoint precondition failed: ${ref} must be absent"
}

assert_ref_at_sha() {
  local ref="$1"
  local expected_sha="$2"
  local exact
  exact="$(exact_ref_json "${ref}")"
  jq -e --arg ref "${ref}" --arg sha "${expected_sha}" '
    length == 1
    and .[0].ref == $ref
    and .[0].object.type == "commit"
    and .[0].object.sha == $sha
  ' <<<"${exact}" >/dev/null ||
    fail "endpoint precondition failed: ${ref} must be one lightweight commit ref at ${expected_sha}"
}

delete_ref_if_present() {
  local ref="$1"
  local exact
  exact="$(exact_ref_json "${ref}")"
  if [ "$(jq 'length' <<<"${exact}")" -eq 1 ]; then
    gh api --method DELETE "repos/${sandbox_repo}/git/refs/${ref#refs/}" >/dev/null
  fi
}

assert_fixture_ancestry() {
  local comparison
  comparison="$(gh api --method GET "repos/${sandbox_repo}/compare/${backtrack_sha}...${forward_sha}")"
  jq -e --arg base "${backtrack_sha}" '
    .status == "ahead" and .ahead_by >= 1 and .merge_base_commit.sha == $base
  ' <<<"${comparison}" >/dev/null || fail 'sandbox forward fixture is not a strict descendant of backtrack fixture'
}

dispatch_ordinary_token_fixture() {
  local fixture_mode="$1"
  local expected_title="ordinary-token-guard-${run_key}-${fixture_mode}"
  local fixture_run_id=''
  local fixture_status=''
  local fixture_conclusion=''
  local logs

  gh workflow run "${ordinary_fixture_workflow}" --repo "${sandbox_repo}" \
    -f mode="${fixture_mode}" \
    -f run_key="${run_key}" \
    -f backtrack_sha="${backtrack_sha}" \
    -f forward_sha="${forward_sha}"

  for _ in $(seq 1 60); do
    fixture_run_id="$(gh run list --repo "${sandbox_repo}" \
      --workflow "${ordinary_fixture_workflow}" \
      --event workflow_dispatch \
      --limit 50 \
      --json databaseId,displayTitle |
      jq -r --arg title "${expected_title}" '[.[] | select(.displayTitle == $title) | .databaseId] | max // empty')"
    if [ -n "${fixture_run_id}" ]; then
      break
    fi
    sleep 5
  done
  [ -n "${fixture_run_id}" ] ||
    fail "sandbox-native ordinary-token fixture did not start (${expected_title})"

  for _ in $(seq 1 60); do
    fixture_status="$(gh run view "${fixture_run_id}" --repo "${sandbox_repo}" --json status --jq '.status')"
    if [ "${fixture_status}" = 'completed' ]; then
      fixture_conclusion="$(gh run view "${fixture_run_id}" --repo "${sandbox_repo}" --json conclusion --jq '.conclusion')"
      break
    fi
    sleep 5
  done
  [ "${fixture_status}" = 'completed' ] ||
    fail "sandbox-native ordinary-token fixture did not complete (${fixture_run_id})"
  [ "${fixture_conclusion}" = 'success' ] ||
    fail "sandbox-native ordinary-token fixture failed (${fixture_run_id}: ${fixture_conclusion})"

  logs="$(gh run view "${fixture_run_id}" --repo "${sandbox_repo}" --log)" ||
    fail "cannot read completed sandbox-native fixture evidence (${fixture_run_id})"
  grep -Fq -- "FLEET_GUARD_ORDINARY_TOKEN_EVIDENCE mode=${fixture_mode} run_key=${run_key} result=policy-denied" <<<"${logs}" ||
    fail "sandbox-native ordinary-token fixture completed without its exact policy-denial evidence (${fixture_run_id})"
  echo "✅ sandbox-native ordinary workflow token evidence verified (${fixture_mode}, run ${fixture_run_id})"
}

case "${mode}" in
setup-absent)
  delete_ref_if_present "${stable_ref}"
  delete_ref_if_present "${scratch_ref}"
  delete_ref_if_present "${other_tag_ref}"
  assert_ref_absent "${stable_ref}"
  echo "✅ sandbox stable tag absent for create-denial probes"
  ;;

setup-base)
  assert_fixture_ancestry
  exact="$(exact_ref_json "${stable_ref}")"
  if [ "$(jq 'length' <<<"${exact}")" -eq 0 ]; then
    jq -n --arg ref "${stable_ref}" --arg sha "${backtrack_sha}" '{ref: $ref, sha: $sha}' |
      gh api --method POST "repos/${sandbox_repo}/git/refs" --input - >/dev/null
  else
    jq -n --arg sha "${backtrack_sha}" '{sha: $sha, force: true}' |
      gh api --method PATCH "repos/${sandbox_repo}/git/refs/tags/machinery-stable" --input - >/dev/null
  fi
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  echo "✅ sandbox stable tag reset to ${backtrack_sha}"
  ;;

create-denied)
  assert_fixture_ancestry
  assert_ref_absent "${stable_ref}"
  payload="$(jq -n --arg ref "${stable_ref}" --arg sha "${backtrack_sha}" '{ref: $ref, sha: $sha}')"
  api_expect_policy_denied 'machinery-stable creation' POST "repos/${sandbox_repo}/git/refs" "${payload}"
  assert_ref_absent "${stable_ref}"
  ;;

update-delete-denied)
  assert_fixture_ancestry
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  payload="$(jq -n --arg sha "${forward_sha}" '{sha: $sha, force: false}')"
  api_expect_policy_denied 'machinery-stable update' PATCH "repos/${sandbox_repo}/git/refs/tags/machinery-stable" "${payload}"
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  api_expect_policy_denied 'machinery-stable deletion' DELETE "repos/${sandbox_repo}/git/refs/tags/machinery-stable"
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  ;;

force-update-denied)
  assert_fixture_ancestry
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  payload="$(jq -n --arg sha "${forward_sha}" '{sha: $sha, force: true}')"
  api_expect_policy_denied 'direct machinery-stable force:true update' PATCH \
    "repos/${sandbox_repo}/git/refs/tags/machinery-stable" "${payload}"
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  ;;

ordinary-create-denied)
  assert_fixture_ancestry
  assert_ref_absent "${stable_ref}"
  dispatch_ordinary_token_fixture 'create-denied'
  assert_ref_absent "${stable_ref}"
  ;;

ordinary-update-delete-denied)
  assert_fixture_ancestry
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  dispatch_ordinary_token_fixture 'update-delete-denied'
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  ;;

main-denied)
  main_ref="$(gh api "repos/${sandbox_repo}/git/ref/heads/main")"
  main_sha="$(jq -r '.object.sha' <<<"${main_ref}")"
  [[ ${main_sha} =~ ^[0-9a-f]{40}$ ]] || fail 'main endpoint did not return a commit SHA'
  tree_sha="$(gh api "repos/${sandbox_repo}/git/commits/${main_sha}" --jq '.tree.sha')"
  commit_payload="$(jq -n \
    --arg message "guard e2e denied main write ${run_key}" \
    --arg tree "${tree_sha}" \
    --arg parent "${main_sha}" \
    '{message: $message, tree: $tree, parents: [$parent]}')"
  denied_sha="$(gh api --method POST "repos/${sandbox_repo}/git/commits" --input - --jq '.sha' <<<"${commit_payload}")"
  payload="$(jq -n --arg sha "${denied_sha}" '{sha: $sha, force: false}')"
  api_expect_policy_denied 'main branch update' PATCH "repos/${sandbox_repo}/git/refs/heads/main" "${payload}"
  current_main_sha="$(gh api "repos/${sandbox_repo}/git/ref/heads/main" --jq '.object.sha')"
  [ "${current_main_sha}" = "${main_sha}" ] || fail 'main changed during a rejected direct-write probe'
  ;;

a33-boundaries)
  assert_fixture_ancestry
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"

  # Allowed normal behavior: one forward, force:false stable-tag update.
  jq -n --arg sha "${forward_sha}" '{sha: $sha, force: false}' |
    gh api --method PATCH "repos/${sandbox_repo}/git/refs/tags/machinery-stable" --input - >/dev/null
  assert_ref_at_sha "${stable_ref}" "${forward_sha}"

  payload="$(jq -n --arg sha "${backtrack_sha}" '{sha: $sha, force: true}')"
  api_expect_policy_denied 'raw A33 force:true backtrack (R7)' PATCH \
    "repos/${sandbox_repo}/git/refs/tags/machinery-stable" "${payload}"
  assert_ref_at_sha "${stable_ref}" "${forward_sha}"
  api_expect_policy_denied 'A33 stable-tag deletion' DELETE \
    "repos/${sandbox_repo}/git/refs/tags/machinery-stable"
  assert_ref_at_sha "${stable_ref}" "${forward_sha}"

  assert_ref_absent "${other_tag_ref}"
  payload="$(jq -n --arg ref "${other_tag_ref}" --arg sha "${forward_sha}" '{ref: $ref, sha: $sha}')"
  api_expect_policy_denied 'A33 other-tag creation' POST "repos/${sandbox_repo}/git/refs" "${payload}"
  assert_ref_absent "${other_tag_ref}"

  # Positive accepted residual: raw A33 may create/update an otherwise
  # unprotected non-main branch. The admin cleanup mode removes it.
  assert_ref_absent "${scratch_ref}"
  jq -n --arg ref "${scratch_ref}" --arg sha "${backtrack_sha}" '{ref: $ref, sha: $sha}' |
    gh api --method POST "repos/${sandbox_repo}/git/refs" --input - >/dev/null
  jq -n --arg sha "${forward_sha}" '{sha: $sha, force: false}' |
    gh api --method PATCH "repos/${sandbox_repo}/git/refs/${scratch_ref#refs/}" --input - >/dev/null
  assert_ref_at_sha "${scratch_ref}" "${forward_sha}"

  # The same A33 token must not write main.
  bash "${BASH_SOURCE[0]}" main-denied
  {
    echo '### A33 sandbox authorization proof'
    echo
    echo "- forward stable-tag update: allowed (${forward_sha})"
    echo '- raw force:true backtrack: rejected (R7 proof)'
    echo '- stable deletion, other tag, and main writes: rejected'
    echo "- scratch non-main branch create/update: allowed (${scratch_ref})"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  ;;

cleanup)
  delete_ref_if_present "${scratch_ref}"
  delete_ref_if_present "${other_tag_ref}"
  exact="$(exact_ref_json "${stable_ref}")"
  if [ "$(jq 'length' <<<"${exact}")" -eq 0 ]; then
    jq -n --arg ref "${stable_ref}" --arg sha "${backtrack_sha}" '{ref: $ref, sha: $sha}' |
      gh api --method POST "repos/${sandbox_repo}/git/refs" --input - >/dev/null
  else
    jq -n --arg sha "${backtrack_sha}" '{sha: $sha, force: true}' |
      gh api --method PATCH "repos/${sandbox_repo}/git/refs/tags/machinery-stable" --input - >/dev/null
  fi
  assert_ref_at_sha "${stable_ref}" "${backtrack_sha}"
  echo "✅ sandbox refs cleaned and stable baseline restored"
  ;;

*) fail "unknown mode ${mode}" ;;
esac
