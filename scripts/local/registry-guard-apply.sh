#!/usr/bin/env bash
set -euo pipefail

# Idempotently apply the checked-in fleet branch/tag rulesets after proving
# the dedicated machinery tag mover is the exact GitHub App installation the
# policy expects. This script deliberately does not create the App, mint a
# private key, create Actions secrets, or configure the protected environment;
# those fleet-admin acts are recorded in docs/domain/fleet-guard.md.

readonly expected_repo='AtomiCloud/fleet'
readonly expected_owner='AtomiCloud'
readonly app_slug='fleet-machinery-tag-mover'
readonly fleet_admin_slug='fleet-admin'
readonly protected_environment='machinery-stable-tag-move'
readonly private_key_secret='FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY'

fail() {
  echo "❌ $1" >&2
  exit 1
}

validate_a33_metadata() {
  local app_json="$1"
  local installation_json="$2"
  local repositories_json="$3"
  local team_json="$4"
  local app_id installation_id team_id

  jq -e --arg slug "${app_slug}" --arg owner "${expected_owner}" '
    .slug == $slug
    and .owner.login == $owner
    and (.id | type == "number" and . > 0 and floor == .)
    and .permissions == {contents: "write", metadata: "read"}
    and .events == []
  ' <<<"${app_json}" >/dev/null ||
    fail "GitHub App must have the exact slug/owner, Contents:write + Metadata:read only, and no webhook events"
  app_id="$(jq -r '.id' <<<"${app_json}")"

  jq -e \
    --arg slug "${app_slug}" \
    --arg owner "${expected_owner}" \
    --argjson app_id "${app_id}" '
      .app_slug == $slug
      and .app_id == $app_id
      and .account.login == $owner
      and .target_type == "Organization"
      and .repository_selection == "selected"
      and (.id | type == "number" and . > 0 and floor == .)
      and .permissions == {contents: "write", metadata: "read"}
    ' <<<"${installation_json}" >/dev/null ||
    fail "App installation owner, app binding, selected-repository mode, or permissions mismatch"
  installation_id="$(jq -r '.id' <<<"${installation_json}")"

  [ "${app_id}" != "${installation_id}" ] ||
    fail "GitHub App ID and installation ID unexpectedly match; refusing an ambiguous actor binding"

  jq -e --arg repo "${expected_repo}" '
    .total_count == 1
    and (.repositories | length) == 1
    and .repositories[0].full_name == $repo
  ' <<<"${repositories_json}" >/dev/null ||
    fail "App installation must select AtomiCloud/fleet and no other repository"

  jq -e --arg slug "${fleet_admin_slug}" --arg owner "${expected_owner}" '
    .slug == $slug
    and .organization.login == $owner
    and (.id | type == "number" and . > 0 and floor == .)
  ' <<<"${team_json}" >/dev/null ||
    fail "fleet-admin team lookup did not resolve the expected AtomiCloud team"
  team_id="$(jq -r '.id' <<<"${team_json}")"

  printf '%s %s %s\n' "${app_id}" "${team_id}" "${installation_id}"
}

# The A33 bypass is only defensible after this read-only preflight.  Keep the
# environment policy check separate from owner provisioning so apply mode never
# creates an environment, secret, App, or reviewer.
validate_protected_environment() {
  local environment_json="$1"
  local branch_policies_json="$2"
  local repository_secrets_json="$3"
  local team_id="$4"

  [[ ${team_id} =~ ^[1-9][0-9]*$ ]] ||
    fail 'fleet-admin Team actor ID must be a positive integer'

  jq -e --arg name "${protected_environment}" --argjson team_id "${team_id}" '
    .name == $name
    and .deployment_branch_policy == {
      protected_branches: false,
      custom_branch_policies: true
    }
    and ([.protection_rules[]? | select(.type == "required_reviewers")] | length) == 1
    and (
      .protection_rules[]
      | select(.type == "required_reviewers")
      | .prevent_self_review == true
      and ([.reviewers[]? | {type, id: .reviewer.id}] == [{type: "Team", id: $team_id}])
    )
  ' <<<"${environment_json}" >/dev/null ||
    fail "protected environment ${protected_environment} must have only the fleet-admin Team reviewer, prevent self-review, and selected branches"

  jq -e '
    . == [{name: "main", type: "branch"}]
  ' <<<"${branch_policies_json}" >/dev/null ||
    fail "protected environment ${protected_environment} must have exactly one main branch policy"

  if jq -e --arg name "${private_key_secret}" '.[]? | select(.name == $name)' \
    <<<"${repository_secrets_json}" >/dev/null; then
    fail "repository-level ${private_key_secret} is forbidden; keep the key only in ${protected_environment}"
  fi
}

# Shared post-apply comparison shape. This must never rewrite a value GitHub
# actually returned: it only drops server-side bookkeeping fields and orders
# the sets that GitHub is free to return in any order.
canonical_policy() {
  jq -cS '
    {name, target, enforcement, bypass_actors, conditions, rules}
    | .bypass_actors |= sort_by(.actor_type, .actor_id, .bypass_mode)
    | .conditions.ref_name.include |= sort
    | .conditions.ref_name.exclude |= sort
    | .rules |= sort_by(.type)
  '
}

# Only the rendered payload omits these keys; GitHub materialises explicit
# defaults for them. Fill them in on the desired side alone so a live
# dismissal_restriction or required_reviewers drift stays visible instead of
# being normalised away on both sides of the comparison.
desired_policy_defaults() {
  jq -c '
    .rules |= map(
      if .type == "pull_request" then
        .parameters.dismissal_restriction //= {allowed_actors: [], enabled: false}
        | .parameters.required_reviewers //= []
      else . end
    )
  '
}

# Offline entry point used by scripts/validate/registry-guard.sh. It exercises
# the same fail-closed metadata checks as apply mode without calling GitHub.
if [ "${1:-}" = '--validate-a33-metadata' ]; then
  [ "$#" -eq 5 ] ||
    fail "usage: $0 --validate-a33-metadata APP INSTALLATION REPOSITORIES TEAM"
  validate_a33_metadata "$(<"$2")" "$(<"$3")" "$(<"$4")" "$(<"$5")" >/dev/null
  exit 0
fi

if [ "${1:-}" = '--validate-protected-environment' ]; then
  [ "$#" -eq 5 ] ||
    fail "usage: $0 --validate-protected-environment ENVIRONMENT BRANCH_POLICIES REPOSITORY_SECRETS TEAM_ID"
  validate_protected_environment "$(<"$2")" "$(<"$3")" "$(<"$4")" "$5"
  exit 0
fi

# Offline entry point for the same post-apply drift comparison apply mode runs,
# so the validator can prove live drift is still detected without GitHub.
if [ "${1:-}" = '--compare-policies' ]; then
  [ "$#" -eq 3 ] ||
    fail "usage: $0 --compare-policies DESIRED LIVE"
  compare_desired="$(desired_policy_defaults <"$2" | canonical_policy)"
  compare_live="$(canonical_policy <"$3")"
  # Bind both sides first: an empty canonicalisation must never compare equal
  # to another empty canonicalisation inside the test itself.
  if [ -z "${compare_desired}" ] || [ -z "${compare_live}" ]; then
    fail 'policy comparison input did not canonicalise to a policy'
  fi
  [ "${compare_desired}" = "${compare_live}" ] ||
    fail 'live ruleset policy differs from the desired payload'
  exit 0
fi

repo="${FLEET_REPO:?set FLEET_REPO to AtomiCloud/fleet}"
[ "${repo}" = "${expected_repo}" ] || fail "refusing to apply fleet guard to ${repo}; expected ${expected_repo}"
: "${KARGO_BOT_ACTOR_ID:?set KARGO_BOT_ACTOR_ID to the existing Kargo bot actor id}"
: "${KARGO_BOT_ACTOR_TYPE:?set KARGO_BOT_ACTOR_TYPE (normally Integration)}"
[[ ${KARGO_BOT_ACTOR_ID} =~ ^[1-9][0-9]*$ ]] || fail "KARGO_BOT_ACTOR_ID must be a positive integer"
case "${KARGO_BOT_ACTOR_TYPE}" in
Integration | OrganizationAdmin | RepositoryRole | Team) ;;
*) fail "unsupported KARGO_BOT_ACTOR_TYPE ${KARGO_BOT_ACTOR_TYPE}" ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
codeowners="${here}/.github/CODEOWNERS"
readonly -a templates=(
  "${here}/.github/rulesets/registry-guard-main.json"
  "${here}/.github/rulesets/machinery-stable-update.json"
  "${here}/.github/rulesets/machinery-stable-delete.json"
  "${here}/.github/rulesets/machinery-stable-forward-only.json"
  "${here}/.github/rulesets/other-tags-protected.json"
)

[ -s "${codeowners}" ] || fail "CODEOWNERS ${codeowners} missing"
for template in "${templates[@]}"; do
  [ -s "${template}" ] || fail "ruleset payload ${template} missing"
done

visibility="$(gh api "repos/${repo}" --jq '.visibility')"
[ "${visibility}" = 'public' ] || fail "${repo} must be PUBLIC (found ${visibility})"
default_branch="$(gh api "repos/${repo}" --jq '.default_branch')"
[ "${default_branch}" = 'main' ] || fail "${repo} default branch must be main (found ${default_branch})"

# Resolve the ruleset actor as the GitHub App ID. The installation ID is kept
# separately and is explicitly rejected from every rendered bypass list.
app_json="$(gh api "/apps/${app_slug}")"
app_id_from_lookup="$(jq -r '.id // empty' <<<"${app_json}")"
[[ ${app_id_from_lookup} =~ ^[1-9][0-9]*$ ]] || fail "App lookup returned no numeric App ID"
installation_pages="$(gh api --paginate --slurp "user/installations?per_page=100")"
installation_matches="$(jq -c \
  --arg slug "${app_slug}" \
  --arg owner "${expected_owner}" \
  --argjson app_id "${app_id_from_lookup}" '
    [.[].installations[] |
      select(.app_id == $app_id and .app_slug == $slug and .account.login == $owner)]
  ' <<<"${installation_pages}")"
[ "$(jq 'length' <<<"${installation_matches}")" -eq 1 ] ||
  fail "authenticated owner must see exactly one ${app_slug} installation on ${expected_owner}"
installation_json="$(jq -c '.[0]' <<<"${installation_matches}")"
installation_id="$(jq -r '.id // empty' <<<"${installation_json}")"
[[ ${installation_id} =~ ^[1-9][0-9]*$ ]] || fail "repository installation lookup returned no numeric installation ID"
repositories_json="$(gh api "user/installations/${installation_id}/repositories?per_page=100")"
team_json="$(gh api "orgs/${expected_owner}/teams/${fleet_admin_slug}")"
read -r app_id fleet_admin_team_id verified_installation_id < <(
  validate_a33_metadata "${app_json}" "${installation_json}" "${repositories_json}" "${team_json}"
)
[ "${installation_id}" = "${verified_installation_id}" ] || fail "installation changed during validation"

# Read-only preflight comes before any ruleset mutation or A33 bypass grant.
environment_json="$(gh api "repos/${repo}/environments/${protected_environment}")" ||
  fail "protected environment ${protected_environment} is missing or unreadable"
branch_policy_pages="$(gh api --paginate --slurp "repos/${repo}/environments/${protected_environment}/deployment-branch-policies?per_page=100")" ||
  fail "cannot read deployment branch policies for ${protected_environment}"
branch_policies="$(jq -c '[.[].branch_policies[]? | {name, type}]' <<<"${branch_policy_pages}")"
repository_secret_pages="$(gh api --paginate --slurp "repos/${repo}/actions/secrets?per_page=100")" ||
  fail "cannot read repository Actions secrets for ${repo}"
repository_secrets="$(jq -c '[.[].secrets[]?]' <<<"${repository_secret_pages}")"
validate_protected_environment "${environment_json}" "${branch_policies}" "${repository_secrets}" "${fleet_admin_team_id}"

codeowners_diagnostics="$(gh api "repos/${repo}/codeowners/errors")" ||
  fail "cannot read CODEOWNERS diagnostics for ${repo}"
jq -e '.errors == []' <<<"${codeowners_diagnostics}" >/dev/null ||
  fail "live CODEOWNERS has GitHub diagnostics; refusing to apply guard rulesets"

"${here}/scripts/validate/registry-guard.sh" >/dev/null
local_codeowners_sha="$(sha256sum "${codeowners}" | cut -d ' ' -f 1)"
live_codeowners_sha="$(gh api "repos/${repo}/contents/.github/CODEOWNERS?ref=main" --jq '.content' | base64 --decode | sha256sum | cut -d ' ' -f 1)"
[ "${local_codeowners_sha}" = "${live_codeowners_sha}" ] ||
  fail "live main CODEOWNERS differs from ${codeowners}"

render_dir="$(mktemp -d)"
trap 'rm -rf -- "${render_dir}"' EXIT
readonly render_dir
readonly app_id fleet_admin_team_id verified_installation_id
declare -a rendered_payloads=()

for template in "${templates[@]}"; do
  rendered="${render_dir}/$(basename "${template}")"
  # The single-quoted variable list is envsubst's allow-list.
  # shellcheck disable=SC2016
  KARGO_BOT_ACTOR_ID="${KARGO_BOT_ACTOR_ID}" \
    KARGO_BOT_ACTOR_TYPE="${KARGO_BOT_ACTOR_TYPE}" \
    FLEET_ADMIN_TEAM_ACTOR_ID="${fleet_admin_team_id}" \
    MACHINERY_TAG_MOVER_APP_ID="${app_id}" \
    envsubst '${KARGO_BOT_ACTOR_ID} ${KARGO_BOT_ACTOR_TYPE} ${FLEET_ADMIN_TEAM_ACTOR_ID} ${MACHINERY_TAG_MOVER_APP_ID}' \
    <"${template}" >"${rendered}"
  jq -e '.' "${rendered}" >/dev/null || fail "rendered ruleset $(basename "${template}") is not JSON"
  rendered_payloads+=("${rendered}")
done

readonly update_ruleset_name='machinery-stable-create-update'
for rendered in "${rendered_payloads[@]}"; do
  name="$(jq -r '.name' "${rendered}")"
  if jq -e --argjson installation_id "${installation_id}" \
    '.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $installation_id)' "${rendered}" >/dev/null; then
    fail "ruleset ${name} uses the installation ID as a bypass actor"
  fi
  a33_count="$(jq --argjson app_id "${app_id}" \
    '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $app_id)] | length' "${rendered}")"
  if [ "${name}" = "${update_ruleset_name}" ]; then
    [ "${a33_count}" -eq 1 ] || fail "${name} must carry exactly one A33 Integration bypass"
  else
    [ "${a33_count}" -eq 0 ] || fail "A33 is forbidden from the ${name} bypass list"
  fi
done

rulesets="$(gh api --paginate --slurp "repos/${repo}/rulesets?per_page=100" | jq -c 'add // []')"

# Refuse a forbidden live A33/installation bypass before making any change.
for rendered in "${rendered_payloads[@]}"; do
  name="$(jq -r '.name' "${rendered}")"
  matching_count="$(jq --arg name "${name}" '[.[] | select(.name == $name)] | length' <<<"${rulesets}")"
  [ "${matching_count}" -le 1 ] || fail "multiple live rulesets named ${name} on ${repo}"
  [ "${matching_count}" -eq 1 ] || continue
  existing_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' <<<"${rulesets}")"
  live="$(gh api "repos/${repo}/rulesets/${existing_id}")"
  if jq -e --argjson installation_id "${installation_id}" \
    '.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $installation_id)' <<<"${live}" >/dev/null; then
    fail "live ruleset ${name} contains an installation ID bypass; refusing to mutate"
  fi
  if [ "${name}" != "${update_ruleset_name}" ] && jq -e --argjson app_id "${app_id}" \
    '.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $app_id)' <<<"${live}" >/dev/null; then
    fail "live ruleset ${name} contains forbidden A33 bypass; refusing to mutate"
  fi
done

for rendered in "${rendered_payloads[@]}"; do
  name="$(jq -r '.name' "${rendered}")"
  existing_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' <<<"${rulesets}")"
  if [ -n "${existing_id}" ]; then
    echo "↻ updating existing ruleset ${name} (id ${existing_id}) on ${repo}"
    gh api --method PUT "repos/${repo}/rulesets/${existing_id}" --input "${rendered}" >/dev/null
  else
    echo "＋ creating ruleset ${name} on ${repo}"
    gh api --method POST "repos/${repo}/rulesets" --input "${rendered}" >/dev/null
  fi
done

rulesets="$(gh api --paginate --slurp "repos/${repo}/rulesets?per_page=100" | jq -c 'add // []')"
for rendered in "${rendered_payloads[@]}"; do
  name="$(jq -r '.name' "${rendered}")"
  matching_count="$(jq --arg name "${name}" '[.[] | select(.name == $name)] | length' <<<"${rulesets}")"
  [ "${matching_count}" -eq 1 ] || fail "ruleset ${name} is absent or duplicated after apply"
  live_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' <<<"${rulesets}")"
  desired_policy="$(desired_policy_defaults <"${rendered}" | canonical_policy)"
  live_policy="$(gh api "repos/${repo}/rulesets/${live_id}" | canonical_policy)"
  if [ "${desired_policy}" != "${live_policy}" ]; then
    echo "❌ live ruleset ${name} differs after apply" >&2
    diff -u <(jq -S . <<<"${desired_policy}") <(jq -S . <<<"${live_policy}") >&2 || true
    exit 1
  fi
done

# Non-vacuous final actor check over the exact live policies.
a33_live_count=0
for rendered in "${rendered_payloads[@]}"; do
  name="$(jq -r '.name' "${rendered}")"
  live_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' <<<"${rulesets}")"
  live="$(gh api "repos/${repo}/rulesets/${live_id}")"
  if jq -e --argjson installation_id "${installation_id}" \
    '.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $installation_id)' <<<"${live}" >/dev/null; then
    fail "live ruleset ${name} contains the installation ID after apply"
  fi
  count="$(jq --argjson app_id "${app_id}" \
    '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $app_id)] | length' <<<"${live}")"
  if [ "${name}" = "${update_ruleset_name}" ]; then
    [ "${count}" -eq 1 ] || fail "live ${name} lacks the exact A33 App-ID bypass"
  else
    [ "${count}" -eq 0 ] || fail "live ${name} contains a forbidden A33 bypass"
  fi
  a33_live_count=$((a33_live_count + count))
done
[ "${a33_live_count}" -eq 1 ] || fail "A33 must appear exactly once across the aggregate live ruleset set"

echo "✅ fleet guard applied and verified on PUBLIC ${repo} (main + four tag rulesets + CODEOWNERS)"
