#!/usr/bin/env bash
set -euo pipefail

# Registry-guard policy validation (int, offline). Validates the checked-in
# `gh api` branch-ruleset payload + CODEOWNERS against the Q-GH1 posture so the
# guard is a repeatable, drift-free check. This is the per-PR tier; the real
# GitHub-authorization behaviour is proven periodically against a sandbox repo
# (deferred; see docs/domain/fleet-repo.md).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="${here}/.github/rulesets/registry-guard-main.json"
codeowners="${here}/.github/CODEOWNERS"

fail() {
  echo "❌ $1" >&2
  exit 1
}

[ ! -s "${template}" ] && fail "ruleset payload ${template} missing"
[ ! -s "${codeowners}" ] && fail "CODEOWNERS ${codeowners} missing"

# The payload is an env-substituted template; render with placeholder actor
# identity so the structure parses as JSON without any live ids. The
# single-quoted variable list is envsubst's allow-list, not a shell expansion.
# shellcheck disable=SC2016
payload="$(KARGO_BOT_ACTOR_ID=0 KARGO_BOT_ACTOR_TYPE=Integration \
  envsubst '${KARGO_BOT_ACTOR_ID} ${KARGO_BOT_ACTOR_TYPE}' <"${template}")"

jq -e '.' <<<"${payload}" >/dev/null 2>&1 || fail "ruleset payload is not valid JSON after substitution"

# Branch ruleset, active, scoped to the default branch.
jq -e '.target == "branch"' <<<"${payload}" >/dev/null || fail "ruleset target must be branch"
jq -e '.enforcement == "active"' <<<"${payload}" >/dev/null || fail "ruleset must be active"
jq -e '.conditions.ref_name.include == ["~DEFAULT_BRANCH"]' <<<"${payload}" >/dev/null ||
  fail "ruleset must target the default branch"

# Require a PR + a code-owner review (this is the fleet-admin gate on registry/**).
jq -e '[.rules[] | select(.type == "pull_request")] | length == 1' <<<"${payload}" >/dev/null ||
  fail "ruleset must carry exactly one pull_request rule"
jq -e '.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review == true' <<<"${payload}" >/dev/null ||
  fail "pull_request rule must require code-owner review"
jq -e '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count >= 1' <<<"${payload}" >/dev/null ||
  fail "pull_request rule must require at least one approving review"

# Kargo-bot bypass = Always (its platforms/** promotion pushes skip the PR gate).
jq -e '[.bypass_actors[] | select(.bypass_mode == "always")] | length >= 1' <<<"${payload}" >/dev/null ||
  fail "ruleset must grant an Always bypass actor for the Kargo bot"

# CODEOWNERS assigns registry/** to the fleet-admin team, and NOT platforms/**.
grep -Eq '^/registry/\*\*[[:space:]]+@AtomiCloud/fleet-admin' "${codeowners}" ||
  fail "CODEOWNERS must assign /registry/** to @AtomiCloud/fleet-admin"
grep -Eq '^/registry/[[:space:]]+@AtomiCloud/fleet-admin' "${codeowners}" ||
  fail "CODEOWNERS must assign /registry/ to @AtomiCloud/fleet-admin"
if grep -Eq '^/?platforms/' "${codeowners}"; then
  fail "CODEOWNERS must NOT cover platforms/** (break-glass rows are ungated)"
fi

echo "✅ registry guard policy validation passed"
