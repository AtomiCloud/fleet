#!/usr/bin/env bash
set -euo pipefail

# Materialize the S30 fleet product (AtomiCloud/fleet) from this diene worktree
# into an explicit target checkout, using a reviewed allowlist.
#
# The fleet node ships as its own ops repo. This script is the executable S30
# boundary: it copies ONLY the fleet-owned surfaces the product CI pyramid needs
# and deliberately leaves behind the inherited helm-wrapper product, the probe
# matrix, and unrelated release/publish machinery. Re-running converges the
# target to the same state (drift repair), so it doubles as the materialization
# audit.
#
# Usage:
#   scripts/local/materialize-fleet.sh <target-checkout>       # apply
#   scripts/local/materialize-fleet.sh --check <target>        # dry-run report
#   scripts/local/materialize-fleet.sh --allow-dirty <target>  # skip clean gate
#   scripts/local/materialize-fleet.sh --self-test             # temp-target proof
#
# Safety posture:
#   * writes are confined to <target>; nothing outside it is ever deleted
#   * the target `.git` is protected (never traversed, copied, or pruned)
#   * `--delete` prunes stale files ONLY inside allowlisted trees, so inherited
#     product files in the target are preserved, never silently removed
#   * a dirty/invalid target aborts before any write unless --allow-dirty
#   * inherited/forbidden surfaces present in the target are reported and abort
#     the run (S30 blocker) — removing them stays a deliberate human act

mode="apply"
allow_dirty=0
self_test=0
target=""

# --- parse arguments (linear, substitution-friendly) ---
while [ "$#" -gt 0 ]; do
  case "$1" in
  --check | -n) mode="check" ;;
  --allow-dirty) allow_dirty=1 ;;
  --self-test) self_test=1 ;;
  -*) echo "❌ unknown flag '$1'" >&2 && exit 1 ;;
  *)
    [ -n "${target}" ] && echo "❌ only one target may be given" >&2 && exit 1
    target="$1"
    ;;
  esac
  shift
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- reviewed allowlist (rsync first-match filters) ---
# `/dir/***` includes a whole fleet-owned tree; a bare path includes one file,
# with its parent dirs listed so rsync descends only into allowlisted paths and
# never into (nor warns about) the excluded inherited trees. --prune-empty-dirs
# drops any parent left empty; the trailing `*` denies everything unmatched.
filters=(
  # never touch the target's own git metadata
  --exclude=/.git
  --exclude=/.git/
  --exclude=/.direnv/
  --exclude=/.direnv
  --exclude=/node_modules/
  # --- fleet registry: topology, root App, platforms AppSet, webhook secret,
  #     the diene-platform compiler chart + its fixtures and goldens ---
  --include=/registry/***
  # --- platform rows consumed by the AppSet generator + render tests ---
  --include=/platforms/***
  # --- pinned Argo/Kargo/ESO schema slices the validators assert against ---
  --include=/schemas/***
  # --- dev shell the product CI resolves (`nix develop .#ci -c ...`) ---
  --include=/flake.nix
  --include=/flake.lock
  --include=/nix/***
  --include=/.envrc
  --include=/.gitignore
  # --- lint/format configs the pre-commit gate reads ---
  --include=/.markdownlint.json
  --include=/.markdownlint-cli2.jsonc
  --include=/.prettierrc.yaml
  --include=/.gitlint
  # --- fleet domain doc (carries the ruling markers) ---
  --include=/docs/
  --include=/docs/domain/
  --include=/docs/domain/fleet-repo.md
  # Guard-lane companion doc; inert until that lane lands it.
  # (registry/machinery-stable.yaml needs no entry — the /registry/*** include
  # above already carries it, fixtures included.)
  --include=/docs/domain/fleet-guard.md
  # --- fleet CI + validators (product pyramid + fleet precommit runtime) ---
  # scripts/ci/pre-commit.sh and config/action-trust.json are NOT copied here:
  # the overlay ships fleet-only variants (the inherited ones reference excluded
  # skills-sync / merge-gatekeeper surfaces). ci.yaml / Taskfile / nix/pre-commit
  # are likewise overlaid.
  --include=/scripts/
  --include=/scripts/ci/
  --include=/scripts/ci/fleet.sh
  --include=/scripts/ci/fleet-sit.sh
  --include=/scripts/validate/
  --include=/scripts/validate/fleet.sh
  --include=/scripts/validate/fleet-rows.sh
  --include=/scripts/validate/fleet-row-expansion.ts
  --include=/scripts/validate/fleet-yaml-update.ts
  --include=/scripts/validate/fleet-sit/***
  --include=/scripts/validate/kargo-freight-criteria.ts
  --include=/scripts/validate/registry-guard.sh
  # validators backing the fleet precommit hooks (workflow pins/cache, exec, pin)
  --include=/scripts/validate/action-pins.sh
  --include=/scripts/validate/cache-tags.sh
  --include=/scripts/validate/executable-shells.sh
  --include=/scripts/validate/nixpkgs-pin.sh
  --include=/scripts/validate/kargo-yaml-update/***
  --include=/scripts/local/
  --include=/scripts/local/registry-guard-apply.sh
  # guard-lane scripts invoked by the tag-move / guard-e2e workflows
  --include=/scripts/local/machinery-stable-tag-move.sh
  --include=/scripts/local/registry-guard-e2e.sh
  --include=/scripts/local/generate-platform-schema.sh
  --include=/scripts/local/materialize-fleet.sh
  --include=/scripts/local/materialize-fleet/***
  # Optional wrapped-SIT proof entry point (owned by the SIT lane). Included
  # unconditionally: rsync simply copies nothing when the source lacks it, so
  # this wiring is inert until that lane lands the file.
  --include=/scripts/ci/fleet-sit-proof.sh
  # --- guard posture: CODEOWNERS + ruleset payloads + fleet-owned workflows ---
  # The A33 / machinery-stable guard surfaces are owned by the guard lane. They
  # are allowlisted here so the product receives them the moment they land; the
  # self-test derives its expectations from SOURCE PRESENCE (below), so this
  # never fails on a file that has not been written yet.
  --include=/.github/
  --include=/.github/CODEOWNERS
  --include=/.github/actionlint.yaml
  --include=/.github/rulesets/***
  --include=/.github/workflows/
  '--include=/.github/workflows/⚡reusable-fleet.yaml'
  '--include=/.github/workflows/⚡reusable-precommit.yaml'
  --include=/.github/workflows/registry-guard-e2e.yaml
  --include=/.github/workflows/machinery-stable-tag-move.yaml
  # deny everything not explicitly allowed above
  --exclude=*
)

# --- inherited / non-fleet surfaces that MUST NOT reach the product (S30) ---
# The allowlist already omits these; this list is the post-copy assertion that
# a pre-populated target does not still carry them.
forbidden=(
  chart
  probes
  infra
  policies
  config/application.yaml
  config/application.example.yaml
  config/application.schema.json
  tasks
  VERSION
  Changelog.md
  atomi_release.yaml
  CLAUDE.md
  .coderabbit.yaml
  scripts/release
  scripts/ci/helm.sh
  scripts/ci/helm-wrapper.sh
  scripts/ci/publish.sh
  scripts/ci/release.sh
  scripts/ci/setup.sh
  scripts/validate/helm-wrapper.sh
  scripts/validate/helm-wrapper-k3d.sh
  scripts/local/create-k3d-cluster.sh
  scripts/local/delete-k3d-cluster.sh
  scripts/local/vendor-chart-config.sh
  scripts/local/generate-chart-schema.sh
  scripts/local/latest-chart-upstreams.sh
  scripts/local/secrets.sh
  scripts/local/skills-sync.sh
  docs/developer/helm-wrapper-baseline.md
  .github/workflows/⚡reusable-helm.yaml
  .github/workflows/⚡reusable-helm-wrapper.yaml
  .github/workflows/⚡reusable-chart-publish.yaml
  .github/workflows/⚡reusable-release.yaml
  .github/workflows/cd.yaml
  .github/workflows/release.yaml
)

# ---------------------------------------------------------------------------
# Self-test: prove the allowlist against a throwaway git target, then stop.
# Re-invokes THIS script (apply mode) so the copy path under test is the real
# one. Never touches the caller's target or the real product worktree.
# ---------------------------------------------------------------------------
if [ "${self_test}" -eq 1 ]; then
  echo "🧪 self-test: materializing into a throwaway git target"
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch}"' EXIT
  git -C "${scratch}" init -q
  git -C "${scratch}" config user.email materialize@fleet.local
  git -C "${scratch}" config user.name materialize-selftest
  : >"${scratch}/.keep"
  git -C "${scratch}" add -A
  git -C "${scratch}" commit -qm seed

  "${BASH_SOURCE[0]}" "${scratch}" >/dev/null

  required=(
    registry/fleet-root.yaml
    registry/platforms-appset.yaml
    registry/argocd-webhook-secret.yaml
    registry/charts/diene-platform/Chart.yaml
    registry/charts/diene-platform/values.schema.json
    registry/charts/diene-platform/tests/golden/canary.prod.yaml
    # ratified live topology (canonical spelling)
    registry/landscapes/ampharos.yaml
    registry/virtual-landscapes/mew.yaml
    registry/virtual-landscapes/celebi.yaml
    # topology FIXTURES for the two unratified classes — the product needs them
    # because the registry-manifest / registry-exclusion gates run in product CI
    registry/fixtures/README.md
    registry/fixtures/clusters/pichu-mark.yaml
    registry/fixtures/clusters/pikachu-mark.yaml
    registry/fixtures/clusters/raichu-mark.yaml
    registry/fixtures/clusters/ampharos-mark.yaml
    registry/fixtures/clusters/entei-mark.yaml
    registry/fixtures/landscapes/entei.yaml
    registry/fixtures/negative/entei-traffic-true.yaml
    registry/fixtures/negative/platform-declares-entei.yaml
    registry/fixtures/negative/second-infrastructure-landscape.yaml
    registry/fixtures/negative/second-infrastructure-cluster.yaml
    platforms/canary/services.yaml
    platforms/canary/landscapes/pichu/dummy.yaml
    platforms/canary/landscapes/pikachu/dummy.yaml
    platforms/canary/landscapes/raichu/dummy.yaml
    platforms/canary/landscapes/ampharos/dummy.yaml
    schemas/platform.json
    schemas/projectconfig.json
    schemas/warehouse.json
    scripts/ci/fleet.sh
    scripts/ci/fleet-sit.sh
    scripts/ci/pre-commit.sh
    scripts/validate/fleet.sh
    scripts/validate/fleet-rows.sh
    scripts/validate/fleet-row-expansion.ts
    scripts/validate/fleet-sit/assert.sh
    scripts/validate/fleet-sit/derive-appset.sh
    scripts/validate/fleet-sit/git-server.ts
    scripts/validate/fleet-sit/github-webhook.ts
    scripts/validate/fleet-sit/kargo-contract.ts
    scripts/validate/fleet-sit/pins.env
    scripts/validate/fleet-sit/fixtures/sitother-row.yaml
    scripts/validate/fleet-sit/fixtures/sitother.services.yaml
    scripts/validate/registry-guard.sh
    scripts/validate/action-pins.sh
    scripts/validate/cache-tags.sh
    scripts/validate/executable-shells.sh
    scripts/validate/nixpkgs-pin.sh
    scripts/local/registry-guard-apply.sh
    scripts/local/generate-platform-schema.sh
    scripts/local/materialize-fleet/overlay/nix/pre-commit.nix
    docs/domain/fleet-repo.md
    README.md
    flake.nix
    flake.lock
    nix/env.nix
    nix/pre-commit.nix
    .envrc
    config/action-trust.json
    .github/CODEOWNERS
    .github/rulesets/registry-guard-main.json
    ".github/workflows/⚡reusable-fleet.yaml"
    ".github/workflows/⚡reusable-precommit.yaml"
    .github/workflows/registry-guard-e2e.yaml
    Taskfile.yaml
    .github/workflows/ci.yaml
  )
  # --- cross-lane surfaces: expectation DERIVED FROM SOURCE PRESENCE ---------
  # The guard lane (A33 / machinery-stable) and the SIT lane own these files.
  # Hard-coding them as required would make this self-test fail on work that has
  # not landed yet; omitting them entirely would let a landed file silently miss
  # the product. Deriving the expectation from the SOURCE tree gives the right
  # behaviour in both states: absent upstream → not expected; present upstream →
  # MUST be materialized. The list itself is the interface contract, so a typo
  # in a filename shows up as a permanently-unchecked entry rather than silence.
  cross_lane=(
    docs/domain/fleet-guard.md
    registry/machinery-stable.yaml
    .github/workflows/machinery-stable-tag-move.yaml
    scripts/local/machinery-stable-tag-move.sh
    scripts/local/registry-guard-e2e.sh
    # all four machinery-stable/other-tag ruleset payloads + the branch ruleset.
    # The allowlist carries these via /.github/rulesets/*** (name-independent);
    # these entries only pin the EXPECTED SET so a renamed or dropped payload is
    # visible here instead of silently vanishing from the product.
    .github/rulesets/registry-guard-main.json
    .github/rulesets/machinery-stable-update.json
    .github/rulesets/machinery-stable-delete.json
    .github/rulesets/machinery-stable-forward-only.json
    .github/rulesets/other-tags-protected.json
    scripts/ci/fleet-sit-proof.sh
  )
  pending=()
  for path in "${cross_lane[@]}"; do
    if [ -e "${here}/${path}" ]; then
      required+=("${path}")
    else
      pending+=("${path}")
    fi
  done

  fail=0
  for path in "${required[@]}"; do
    [ -e "${scratch}/${path}" ] || { echo "❌ required inclusion missing: ${path}" >&2 && fail=1; }
  done
  if [ "${#pending[@]}" -gt 0 ]; then
    echo "ℹ️  cross-lane surfaces not yet in this worktree (wired, not required):" >&2
    printf '   - %s\n' "${pending[@]}" >&2
  fi

  # fixtures must reach the product, but must NEVER be synced by fleet-root:
  # ArgoCD would apply the negative fixtures as real cluster objects.
  grep -q 'fixtures' "${scratch}/registry/fleet-root.yaml" &&
    { echo "❌ fleet-root include glob references fixtures — ArgoCD would apply the negatives" >&2 && fail=1; }
  [ -d "${scratch}/registry/fixtures" ] ||
    { echo "❌ topology fixtures did not reach the product (registry-manifest gate would have nothing to validate)" >&2 && fail=1; }
  for path in "${forbidden[@]}"; do
    [ -e "${scratch}/${path}" ] && { echo "❌ forbidden surface materialized: ${path}" >&2 && fail=1; }
  done
  if "${BASH_SOURCE[0]}" --check "${here}/scripts" >/dev/null 2>&1; then
    echo "❌ nested target inside the source worktree was accepted" >&2
    fail=1
  fi
  # overlays must carry the fleet-only entry points, not the inherited ones
  grep -q 'scripts/ci/fleet.sh' "${scratch}/Taskfile.yaml" || { echo "❌ product Taskfile lost the fleet test entry" >&2 && fail=1; }
  grep -q 'reusable-fleet.yaml' "${scratch}/.github/workflows/ci.yaml" || { echo "❌ product ci.yaml lost the fleet job" >&2 && fail=1; }
  grep -q 'reusable-precommit.yaml' "${scratch}/.github/workflows/ci.yaml" || { echo "❌ product ci.yaml lost the precommit job" >&2 && fail=1; }
  grep -vE '^[[:space:]]*#' "${scratch}/scripts/ci/pre-commit.sh" | grep -qE 'skills-sync|setup\.sh' && { echo "❌ product pre-commit.sh still calls skills-sync/setup" >&2 && fail=1; }
  grep -q 'actions/checkout' "${scratch}/config/action-trust.json" || { echo "❌ product action-trust.json missing the workflow actions" >&2 && fail=1; }

  # config surfaces the product actually executes (workflows / tasks / precommit)
  surfaces=(
    "${scratch}/Taskfile.yaml"
    "${scratch}/nix/pre-commit.nix"
    "${scratch}/scripts/ci/pre-commit.sh"
    "${scratch}/config/action-trust.json"
  )
  while IFS= read -r wf; do surfaces+=("${wf}"); done < <(find "${scratch}/.github/workflows" -type f | sort)

  # (1) no EXCLUDED path may be referenced by an active (non-comment) line
  excluded_re='infra/root_chart|atomi_release|helm-wrapper|skills-sync|skills-freshness|many-owner|merge-gatekeeper|release-config|helm-docs|CLAUDE\.md|config/application|workflows\.sh'
  hits="$(grep -rhvE '^[[:space:]]*#' "${surfaces[@]}" | grep -nE "${excluded_re}" || true)"
  [ -n "${hits}" ] && { echo "❌ product config references an excluded surface:" >&2 && echo "${hits}" >&2 && fail=1; }

  # (2) every fleet script referenced by a product surface must exist (no dangle)
  refs="$(grep -rhoE 'scripts/(ci|validate|local)/[A-Za-z0-9._/-]+\.(sh|ts)' "${surfaces[@]}" | sort -u || true)"
  while IFS= read -r ref; do
    [ -z "${ref}" ] && continue
    [ -e "${scratch}/${ref}" ] || { echo "❌ product surface references a missing script: ${ref}" >&2 && fail=1; }
  done <<<"${refs}"

  # the throwaway git history must survive untouched
  [ -d "${scratch}/.git" ] || { echo "❌ target .git was not preserved" >&2 && fail=1; }
  git -C "${scratch}" cat-file -e HEAD || { echo "❌ target git history was clobbered" >&2 && fail=1; }
  if find "${scratch}" -path "${scratch}/.git" -prune -o -type f -name features.json -print | grep -q .; then
    echo "❌ features.json leaked into the materialized product" >&2
    fail=1
  fi

  # A pre-populated receiver must be rejected even when rsync correctly leaves
  # excluded files untouched. This proves the retained-target half of the S30
  # boundary rather than only checking that forbidden source files were not
  # copied into an initially empty checkout.
  contaminated="${scratch}/contaminated-target"
  mkdir -p "${contaminated}/probes"
  git -C "${contaminated}" init -q
  git -C "${contaminated}" config user.email materialize@fleet.local
  git -C "${contaminated}" config user.name materialize-selftest
  : >"${contaminated}/probes/stale"
  git -C "${contaminated}" add -A
  git -C "${contaminated}" commit -qm seed
  if "${BASH_SOURCE[0]}" --check "${contaminated}" >/dev/null 2>&1; then
    echo "❌ pre-existing probes tree was accepted in the target" >&2
    fail=1
  fi

  [ "${fail}" -eq 0 ] || { echo "❌ self-test failed" >&2 && exit 1; }
  echo "✅ self-test passed: inclusions present, forbidden/excluded surfaces absent, no dangling script refs, .git preserved"
  exit 0
fi

# --- validate target ---
[ -z "${target}" ] && echo "❌ target checkout path required (see --help usage in header)" >&2 && exit 1
[ -d "${target}" ] || { echo "❌ target '${target}' is not an existing directory" >&2 && exit 1; }
target="$(cd "${target}" && pwd)"

[ "${target}" = "/" ] && echo "❌ refusing to materialize into '/'" >&2 && exit 1
[ "${target}" = "${HOME}" ] && echo "❌ refusing to materialize into the home directory" >&2 && exit 1
[ "${target}" = "${here}" ] && echo "❌ target must differ from the source worktree" >&2 && exit 1
case "${here}/" in "${target}/"*) echo "❌ target must not contain the source worktree" >&2 && exit 1 ;; esac
case "${target}/" in "${here}/"*) echo "❌ target must not be inside the source worktree" >&2 && exit 1 ;; esac

# apply mode requires a clean git target unless the caller opts out
if [ "${mode}" = "apply" ] && [ "${allow_dirty}" -eq 0 ]; then
  git -C "${target}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    { echo "❌ target '${target}' is not a git checkout (pass --allow-dirty to override)" >&2 && exit 1; }
  [ -z "$(git -C "${target}" status --porcelain)" ] ||
    { echo "❌ target '${target}' has uncommitted changes (commit/stash or pass --allow-dirty)" >&2 && exit 1; }
fi

# --- copy the allowlist ---
if [ "${mode}" = "check" ]; then
  echo "🔍 dry-run: planned changes for ${target}"
  rsync -a --delete --prune-empty-dirs -ni "${filters[@]}" "${here}/" "${target}/"
  echo "📝 would also apply fleet-only product overlays and refresh README.md"
else
  echo "📦 materializing fleet product into ${target}"
  rsync -a --delete --prune-empty-dirs "${filters[@]}" "${here}/" "${target}/"

  # --- product-form overlays (fleet-only variants of inherited workspace files) ---
  # Laid over the allowlisted copy so the product references no excluded surface:
  #   nix/pre-commit.nix          fleet-only hook set
  #   scripts/ci/pre-commit.sh    no setup/skills-sync
  #   Taskfile.yaml               fleet-only tasks
  #   .github/workflows/ci.yaml   precommit + fleet jobs only
  #   config/action-trust.json    only the actions the product workflows use
  rsync -a "${here}/scripts/local/materialize-fleet/overlay/" "${target}/"
  cp "${here}/docs/domain/fleet-repo.md" "${target}/README.md"
  chmod +x "${target}/scripts/ci/pre-commit.sh"
  echo "🛠️  applied product overlays and refreshed README.md from the fleet domain document"
fi

# --- S30 assertion: no inherited/forbidden surface left in the target ---
present=()
for path in "${forbidden[@]}"; do
  [ -e "${target}/${path}" ] && present+=("${path}")
done
if [ "${#present[@]}" -gt 0 ]; then
  echo "❌ inherited/forbidden surfaces present in ${target} (remove before S30 materialization):" >&2
  printf '   - %s\n' "${present[@]}" >&2
  exit 1
fi
mapfile -t feature_files < <(find "${target}" -path "${target}/.git" -prune -o -type f -name features.json -print)
if [ "${#feature_files[@]}" -gt 0 ]; then
  echo "❌ features.json is forbidden everywhere in the S30 product:" >&2
  printf '   - %s\n' "${feature_files[@]}" >&2
  exit 1
fi

# --- report resulting status/diff for the reviewer ---
if git -C "${target}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "📋 target git status (${target}):"
  git -C "${target}" status --short || true
  echo "📊 target diff stat:"
  git -C "${target}" --no-pager diff --stat || true
fi

echo "✅ fleet materialization ${mode} complete"
