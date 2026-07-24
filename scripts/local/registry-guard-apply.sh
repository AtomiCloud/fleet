#!/usr/bin/env bash
set -euo pipefail

# Idempotent apply of the fleet `registry/**` guard (Q-GH1 posture).
#
# Provisions the `main` branch ruleset from
# .github/rulesets/registry-guard-main.json against a PUBLIC fleet repo. The
# ruleset requires a PR + a code-owner review before merge, and exempts the
# Kargo bot (Always bypass) so its `platforms/**` promotion pushes land
# directly. CODEOWNERS (.github/CODEOWNERS) assigns `registry/**` to the
# fleet-admin team; the ruleset's require_code_owner_review turns that into a
# hard fleet-admin gate on registry changes.
#
# Human-run and idempotent: re-running converges to the same state, so it also
# serves as the drift repair for `scripts/validate/registry-guard.sh`.
#
# Required env:
#   FLEET_REPO            owner/repo of the fleet repository (e.g. AtomiCloud/fleet)
#   KARGO_BOT_ACTOR_ID    numeric actor id of the Kargo bot (GitHub App or user)
#   KARGO_BOT_ACTOR_TYPE  Integration | OrganizationAdmin | RepositoryRole | Team

repo="${FLEET_REPO:?set FLEET_REPO to owner/repo of the fleet repository}"
: "${KARGO_BOT_ACTOR_ID:?set KARGO_BOT_ACTOR_ID to the Kargo bot actor id}"
: "${KARGO_BOT_ACTOR_TYPE:?set KARGO_BOT_ACTOR_TYPE (e.g. Integration)}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="${here}/.github/rulesets/registry-guard-main.json"
codeowners="${here}/.github/CODEOWNERS"

[ ! -s "${template}" ] && echo "❌ ruleset payload ${template} missing" >&2 && exit 1
[ ! -s "${codeowners}" ] && echo "❌ CODEOWNERS ${codeowners} missing" >&2 && exit 1

visibility="$(gh api "repos/${repo}" --jq '.visibility')"
[ "${visibility}" != "public" ] && echo "❌ ${repo} must be PUBLIC (found ${visibility})" >&2 && exit 1

default_branch="$(gh api "repos/${repo}" --jq '.default_branch')"
[ "${default_branch}" != "main" ] && echo "❌ ${repo} default branch must be main (found ${default_branch})" >&2 && exit 1

"${here}/scripts/validate/registry-guard.sh" >/dev/null
local_codeowners_sha="$(sha256sum "${codeowners}" | cut -d ' ' -f 1)"
live_codeowners_sha="$(gh api "repos/${repo}/contents/.github/CODEOWNERS?ref=main" --jq '.content' | base64 --decode | sha256sum | cut -d ' ' -f 1)"
[ "${local_codeowners_sha}" != "${live_codeowners_sha}" ] && echo "❌ live main CODEOWNERS differs from ${codeowners}" >&2 && exit 1

# The single-quoted variable list is envsubst's allow-list, not shell expansion.
# shellcheck disable=SC2016
payload="$(KARGO_BOT_ACTOR_ID="${KARGO_BOT_ACTOR_ID}" KARGO_BOT_ACTOR_TYPE="${KARGO_BOT_ACTOR_TYPE}" \
  envsubst '${KARGO_BOT_ACTOR_ID} ${KARGO_BOT_ACTOR_TYPE}' <"${template}")"
name="$(jq -r '.name' <<<"${payload}")"

rulesets="$(gh api "repos/${repo}/rulesets")"
matching_count="$(jq --arg name "${name}" '[.[] | select(.name == $name)] | length' <<<"${rulesets}")"
[ "${matching_count}" -gt 1 ] && echo "❌ multiple live rulesets named ${name} on ${repo}" >&2 && exit 1
existing_id="$(jq -r --arg name "${name}" '.[] | select(.name == $name) | .id' <<<"${rulesets}")"

if [ -n "${existing_id}" ]; then
  echo "↻ updating existing ruleset ${name} (id ${existing_id}) on ${repo}"
  printf '%s' "${payload}" | gh api -X PUT "repos/${repo}/rulesets/${existing_id}" --input - >/dev/null
else
  echo "＋ creating ruleset ${name} on ${repo}"
  printf '%s' "${payload}" | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null
fi

live_id="$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\") | .id")"
[ -z "${live_id}" ] && echo "❌ ruleset ${name} was not found after apply" >&2 && exit 1

desired_policy="$(jq -cS '{name,target,enforcement,bypass_actors,conditions,rules}' <<<"${payload}")"
live_policy="$(gh api "repos/${repo}/rulesets/${live_id}" | jq -cS '{name,target,enforcement,bypass_actors,conditions,rules}')"
if [ "${desired_policy}" != "${live_policy}" ]; then
  echo "❌ live ruleset ${name} differs after apply" >&2
  diff -u <(jq -S . <<<"${desired_policy}") <(jq -S . <<<"${live_policy}") >&2 || true
  exit 1
fi

echo "✅ registry guard applied and verified on PUBLIC ${repo} (main ruleset ${name} + byte-identical CODEOWNERS)"
