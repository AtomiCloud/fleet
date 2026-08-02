#!/usr/bin/env bash
set -euo pipefail

# Forward-only implementation for the protected machinery-stable workflow.
# It accepts no ref or SHA argument: both the pointer path and tag API endpoint
# are constants. GitHub rulesets remain the security boundary against raw-token
# deletion/backtracking/other-ref writes.

readonly expected_repo='AtomiCloud/fleet'
readonly expected_ref='refs/heads/main'
readonly stable_ref='refs/tags/machinery-stable'

fail() {
  echo "❌ $1" >&2
  exit 1
}

[ "$#" -eq 0 ] || fail 'this helper accepts no arguments or ref input'
[ "${GITHUB_ACTIONS:-}" = 'true' ] || fail 'this helper runs only in GitHub Actions'
[ "${GITHUB_EVENT_NAME:-}" = 'push' ] || fail 'machinery-stable moves only after a push event'
[ "${GITHUB_REPOSITORY:-}" = "${expected_repo}" ] || fail "unexpected repository ${GITHUB_REPOSITORY:-unset}"
[ "${GITHUB_REF:-}" = "${expected_ref}" ] || fail "unexpected ref ${GITHUB_REF:-unset}; main only"
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'GITHUB_SHA is not a full commit SHA'
: "${GH_TOKEN:?GH_TOKEN must be the protected-environment A33 installation token}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pointer="${root}/registry/machinery-stable.yaml"
[ -s "${pointer}" ] || fail "missing pointer ${pointer}"

# Exactly one non-comment line is accepted, which makes duplicate keys or a
# hidden second target fail closed without depending on a YAML implementation.
pointer_line="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${pointer}")"
if [[ ! ${pointer_line} =~ ^target:[[:space:]]([0-9a-f]{40})$ ]]; then
  fail 'pointer must contain exactly: target: <40-lowercase-hex-main-commit>'
fi
target_sha="${BASH_REMATCH[1]}"

cd "${root}"
[ "$(git rev-parse HEAD)" = "${GITHUB_SHA}" ] || fail 'checkout HEAD differs from the triggering push SHA'
git diff --quiet --exit-code || fail 'tracked working tree differs from the triggering commit'
test -z "$(git status --short --untracked-files=all)" || fail 'working tree contains untracked or staged bytes'

# A Kargo platforms/** push can advance main while this protected job waits for
# approval. The triggering commit must still be on main, and a newer pointer
# value explicitly supersedes this run; unrelated descendants do not.
git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
main_sha="$(git rev-parse refs/remotes/origin/main)"
git merge-base --is-ancestor "${GITHUB_SHA}" "${main_sha}" ||
  fail "trigger SHA ${GITHUB_SHA} is no longer an ancestor of current main ${main_sha}"
main_pointer_line="$(git show "refs/remotes/origin/main:registry/machinery-stable.yaml" 2>/dev/null | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')" ||
  fail 'current main does not contain a readable machinery-stable pointer'
if [[ ! ${main_pointer_line} =~ ^target:[[:space:]]([0-9a-f]{40})$ ]]; then
  fail 'current main pointer must contain exactly: target: <40-lowercase-hex-main-commit>'
fi
current_target_sha="${BASH_REMATCH[1]}"
[ "${current_target_sha}" = "${target_sha}" ] ||
  fail "pointer superseded on current main (${target_sha} -> ${current_target_sha}); a newer run owns the tag advance"
git cat-file -e "${target_sha}^{commit}" 2>/dev/null || fail "pointer ${target_sha} is not a commit in the checkout"
git merge-base --is-ancestor "${target_sha}" "${main_sha}" || fail "pointer ${target_sha} is not on main"

# The fixed matching-refs endpoint returns [] when the tag is absent, avoiding
# an ambiguous 404 path. Only the exact ref is considered.
matching_refs="$(gh api --method GET "repos/${expected_repo}/git/matching-refs/tags/machinery-stable")"
exact_count="$(jq --arg ref "${stable_ref}" '[.[] | select(.ref == $ref)] | length' <<<"${matching_refs}")"
[ "${exact_count}" -le 1 ] || fail "GitHub returned duplicate ${stable_ref} refs"

if [ "${exact_count}" -eq 0 ]; then
  jq -n --arg ref "${stable_ref}" --arg sha "${target_sha}" \
    '{ref: $ref, sha: $sha}' |
    gh api --method POST "repos/${expected_repo}/git/refs" --input - >/dev/null
  action='created'
else
  object_type="$(jq -r --arg ref "${stable_ref}" '.[] | select(.ref == $ref) | .object.type' <<<"${matching_refs}")"
  current_sha="$(jq -r --arg ref "${stable_ref}" '.[] | select(.ref == $ref) | .object.sha' <<<"${matching_refs}")"
  [ "${object_type}" = 'commit' ] || fail "${stable_ref} must be a lightweight commit tag (found ${object_type})"
  [[ ${current_sha} =~ ^[0-9a-f]{40}$ ]] || fail "current ${stable_ref} target is not a commit SHA"

  if ! git cat-file -e "${current_sha}^{commit}" 2>/dev/null; then
    git fetch --quiet --no-tags origin "${current_sha}"
  fi
  git merge-base --is-ancestor "${current_sha}" "${target_sha}" ||
    fail "pointer ${target_sha} would backtrack ${stable_ref} from ${current_sha}"

  if [ "${current_sha}" = "${target_sha}" ]; then
    echo "✅ ${stable_ref} already points at ${target_sha}; no write required"
    exit 0
  fi

  jq -n --arg sha "${target_sha}" '{sha: $sha, force: false}' |
    gh api --method PATCH "repos/${expected_repo}/git/refs/tags/machinery-stable" --input - >/dev/null
  action='advanced'
fi

verified_sha="$(gh api --method GET "repos/${expected_repo}/git/ref/tags/machinery-stable" --jq '.object.sha')"
[[ ${verified_sha} =~ ^[0-9a-f]{40}$ ]] || fail "post-write tag target ${verified_sha} is not a commit SHA"
if ! git cat-file -e "${verified_sha}^{commit}" 2>/dev/null; then
  git fetch --quiet --no-tags origin "${verified_sha}"
fi
git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
verified_main_sha="$(git rev-parse refs/remotes/origin/main)"
git merge-base --is-ancestor "${target_sha}" "${verified_sha}" ||
  fail "post-write tag target ${verified_sha} is not ${target_sha} or a forward descendant"
git merge-base --is-ancestor "${verified_sha}" "${verified_main_sha}" ||
  fail "post-write tag target ${verified_sha} is not on current main ${verified_main_sha}"
echo "✅ ${action} ${stable_ref} at forward-only main commit ${verified_sha}"
