#!/usr/bin/env bash

sit_fail() {
  echo "fleet SIT assertion failed: $*" >&2
  return 1
}

sit_require_command() {
  command -v "$1" >/dev/null 2>&1 || sit_fail "required command is missing: $1"
}

sit_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

sit_epoch() {
  date -u +%s
}

sit_wait_for() {
  local timeout_s="$1"
  local description="$2"
  shift 2
  local deadline=$((SECONDS + timeout_s))

  while true; do
    if "$@"; then
      return 0
    fi
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      sit_fail "timed out after ${timeout_s}s waiting for ${description}"
      return 1
    fi
    sleep "${FLEET_SIT_POLL_SECONDS:-3}"
  done
}

# The exact ordered leg set of report schema v2. L0-L7 are unchanged from
# schema v1; L8 is the pinned API contract and L9 is the distinct controller
# runtime proof. Keeping them separate prevents admission from being described
# as execution (or vice versa).
SIT_LEG_CONTRACT=(
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

_sit_leg_contract_json() {
  printf '%s\n' "${SIT_LEG_CONTRACT[@]}" | jq -Rsc 'split("\n")[:-1]'
}

# sit_report_init <report-dir> <pins-json> <provenance-json>
#
# `provenance-json` is the schema-v2 binding block: the recorded commit, the
# original checkout's head/cleanliness at start, the verified input snapshot,
# and the derived direct-input inventory. It is built by the caller from git,
# never from the harness's own opinion of what it reads.
sit_report_init() {
  local report_dir="$1"
  local pins_json="$2"
  local provenance_json="$3"

  SIT_REPORT_DIR="${report_dir}"
  SIT_REPORT_FILE="${report_dir}/sit-report.json"
  SIT_RUN_STARTED_EPOCH="$(sit_epoch)"
  SIT_CURRENT_LEG=''
  SIT_CURRENT_LEG_STARTED_EPOCH=''
  SIT_CURRENT_LEG_STARTED=''
  SIT_LEG_EVIDENCE=()
  mkdir -p "${SIT_REPORT_DIR}"

  jq -n \
    --argjson pins "${pins_json}" \
    --argjson provenance "${provenance_json}" \
    --argjson legContract "$(_sit_leg_contract_json)" \
    --arg started "$(sit_now)" \
    '{
      schemaVersion: 2,
      status: "running",
      argocd: $pins.argocd,
      argocdSourceCommit: $pins.argocdSourceCommit,
      argocdManifestSha256: $pins.argocdManifestSha256,
      k3s: $pins.k3s,
      kargo: $pins.kargo,
      bindingBasis: "the recorded commit binds every consumed byte: execution reads only a verified snapshot of that commit, the direct-input inventory is derived from its git tree, and the original checkout is proven clean and unchanged at start and finish. The harness digest is NARROWER - it pins only the SIT harness files and is retained as provenance, never as the direct-input inventory.",
      started: $started,
      legContract: $legContract,
      legs: [],
      residuals: [
        "Warehouse discovery against a reachable OCI registry is not exercised: runtime coordinates intentionally use registry.sit.invalid and Freight is seeded through the real validating webhook against the rendered Warehouse subscriptions",
        "real scmProvider/GitHub repository listing not exercised; a list-generator variant is reverse-diff-asserted against the committed ApplicationSet",
        "per-row OCI workload sync not exercised because registry.atomi.cloud artifacts are unavailable; row assertions stop at generated Application specs",
        "literal passage of the production 15m soak is not bought: L9 backdates the persisted write-once Freight.status.currentlyIn[stage].since field and exercises the real pinned comparison in both verification orderings, while a separate otherwise-identical 90s project proves the same released controller code against real wall time",
        "the Kargo API server and UI approval surface are disabled; manual approval is exercised by creating a real Promotion CR through the pinned Kubernetes validating webhook and SubjectAccessReview path",
        "the L5 pointer advance models the protected GitHub Git Refs API PATCH with force:false by an equivalent server-side compare-and-swap on the throwaway serving repository, preceded by the same descendant precheck the product mover script performs; the venue has no GitHub API, and the raw non-forced git push of an existing tag is additionally proven to be rejected by the transport itself"
      ],
      deviations: [
        "the throwaway fleet mirror relaxes only values.schema.json fleet.repoURL from ^https:// to ^https?:// because its hermetic smart-HTTP endpoint is cluster-local HTTP without a TLS layer",
        "the throwaway argocd-server sets server.insecure=true because the pinned install port-80 Service targets its default self-signed TLS listener; this permits hermetic HTTP webhook delivery without weakening signature validation",
        "the derived local ApplicationSet maps the explicit-port production identity for source C to fleet-services.git, an in-root symlink to fleet.git, while source A uses fleet.git; this preserves source C at HEAD while avoiding the pinned Argo same-identity different-revision rejection",
        "before L5 the throwaway harness stops both the Application and ApplicationSet controllers, clears the resources finalizer only on platform-sitother, deletes it while neither controller can restore that finalizer, then restores and explicitly refreshes its owning ApplicationSet; this recreates an operation-free UID and clears the intentionally CRD-light initial retry before the tag moves",
        "the throwaway repo-server starts with its pinned revision-cache expiration at 30s before any ApplicationSet exists, while L7 also shortens the ApplicationSet generator requeue to 30s; matching these two real polling layers makes the no-webhook fallback runnable within the bounded test without flushing cache state",
        "the pinned Argo install uses server-side apply because its ApplicationSet CRD is larger than Kubernetes permits in a client-side last-applied annotation",
        "the planned static dumb-HTTP fixture transport was replaced after source and runtime verification: Argo CD v3.4.5 go-git remote.List rejects its static info/refs response, so the Bun wrapper invokes git http-backend for smart HTTP",
        "L9 changes only the two ordinary consumer coordinates fleet.repoURL and oci.registry, disables the optional Kargo API/external-webhook/garbage-collector components, and supplies an operator-generated one-run TLS CA/certificate to the real kubernetes-webhooks-server",
        "the literal 15m clock is strengthened with a separate SIT-only canary-sitsoak project whose otherwise-identical DAG uses 90s; this fixture is never a product render"
      ],
      feasibility: {
        applicationSetWebhookPort: 7000,
        applicationWebhookServicePort: 80,
        applicationWebhookRuntimeTransport: "HTTP after server.insecure=true in the throwaway cluster",
        githubSecretKey: "webhook.github.secret",
        webhookNegativeOracle: "wrong and missing signatures must return pinned HTTP 400 rejection responses and cause no Application spec refresh",
        applicationSetRefreshBypassesRevisionCache: true,
        pollingPhaseRestartsRepoServer: true,
        pollingPhaseApplicationSetRequeue: "30s",
        pollingPhaseRepoRevisionCacheExpiration: "30s",
        nonCanaryAutomationOracle: "a newly recreated Application UID with source-A comparison at C4, root and status controller-initiated automatic operations pinned to C4, and operation start at or after the tag-move timestamp",
        sameRepositoryDifferentRevisionConstraint: "Argo CD v3.4.5 rejects different revisions when source URLs normalize to one identity",
        fleetServicesAlias: "fleet-services.git symlink to fleet.git with identical advertised refs and a distinct URL identity",
        gitTransport: "smart HTTP via Bun CGI wrapper around git http-backend",
        argocdRefDiscovery: "pinned util/git/client.go getRefs initializes go-git in-memory storage and calls remote.List through listRemote; it does not shell out to git",
        clusterSeedSource: "ephemeral Argo cluster Secrets are seeded from registry/fixtures/clusters/*.yaml with SIT-local synthetic mark/provider substituted for the committed placeholders; no live serving ClusterRegistration row exists to seed from, and none may be guessed",
        infrastructureExclusionOracle: "multiple infrastructure-only cluster Secrets carrying hostRole and traffic:false are seeded and label-selectable; one deliberately names the real serving landscape ampharos, so deleting cluster-role NotIn infrastructure-only would generate an Application and turn the oracle red",
        machineryPointerMechanism: "forward-only pointer file plus descendant precheck plus explicit old->new compare-and-swap with force:false; rollback is a NEW descendant revert commit the pointer then advances to, never a backward move",
        kargoContractOracle: "the committed compiler chart is rendered, admitted by an API server carrying the pinned Kargo v1.9.10 CRDs, read back, and re-checked field-exactly. Read-back proves persistence for schema-declared fields; paths below x-kubernetes-preserve-unknown-fields (notably promotion step config) are emitted as blind spots and require the field-exact oracle plus the pinned expression-engine and runtime execution proofs",
        kargoBehaviourSource: "L8 binds the pinned API/schema semantics; L9 runs the pinned Kargo controller, management-controller, kubernetes-webhooks-server, real git promotion steps, and Argo Rollouts Job-provider analyses",
        kargoRuntimeCoordinates: "the runtime render changes exactly fleet.repoURL to the throwaway smart-HTTP repository and oci.registry to registry.sit.invalid; a reverse-coordinate and canonical-delta oracle proves every policy, DAG, verification, and soak byte remains equivalent"
      }
    } + $provenance' >"${SIT_REPORT_FILE}"
}

_sit_evidence_json() {
  if [ "${#SIT_LEG_EVIDENCE[@]}" -eq 0 ]; then
    printf '[]\n'
    return
  fi
  printf '%s\n' "${SIT_LEG_EVIDENCE[@]}" | jq -Rsc 'split("\n")[:-1]'
}

_sit_report_replace() {
  local replacement="$1"
  local tmp="${SIT_REPORT_FILE}.tmp.$$"
  printf '%s\n' "${replacement}" >"${tmp}"
  mv "${tmp}" "${SIT_REPORT_FILE}"
}

sit_leg_begin() {
  SIT_CURRENT_LEG="$1"
  shift
  SIT_CURRENT_LEG_STARTED_EPOCH="$(sit_epoch)"
  SIT_CURRENT_LEG_STARTED="$(sit_now)"
  SIT_LEG_EVIDENCE=("$@")
  echo "==> ${SIT_CURRENT_LEG}"
}

sit_leg_pass() {
  local note="${1:-}"
  local evidence_path
  for evidence_path in "${SIT_LEG_EVIDENCE[@]}"; do
    case "${evidence_path}" in
    /* | .. | ../* | */.. | */../*)
      sit_fail "invalid report evidence path: ${evidence_path}"
      return 1
      ;;
    esac
    [ -s "${SIT_REPORT_DIR}/${evidence_path}" ] || {
      sit_fail "claimed report evidence is missing or empty: ${evidence_path}"
      return 1
    }
  done
  local elapsed=$(($(sit_epoch) - SIT_CURRENT_LEG_STARTED_EPOCH))
  local evidence
  evidence="$(_sit_evidence_json)"
  local updated
  updated="$(jq \
    --arg leg "${SIT_CURRENT_LEG}" \
    --arg started "${SIT_CURRENT_LEG_STARTED}" \
    --arg note "${note}" \
    --argjson elapsed "${elapsed}" \
    --argjson evidence "${evidence}" \
    '.legs += [{leg:$leg,status:"pass",started:$started,elapsed_s:$elapsed,evidence:$evidence,note:$note}]' \
    "${SIT_REPORT_FILE}")"
  _sit_report_replace "${updated}"
  echo "<== ${SIT_CURRENT_LEG} passed (${elapsed}s)"
  SIT_CURRENT_LEG=''
  SIT_LEG_EVIDENCE=()
}

sit_leg_fail() {
  local exit_code="$1"
  local reason="$2"
  [ -n "${SIT_CURRENT_LEG:-}" ] || return 0
  local elapsed=$(($(sit_epoch) - SIT_CURRENT_LEG_STARTED_EPOCH))
  local evidence
  evidence="$(_sit_evidence_json)"
  local updated
  updated="$(jq \
    --arg leg "${SIT_CURRENT_LEG}" \
    --arg started "${SIT_CURRENT_LEG_STARTED}" \
    --arg reason "${reason}" \
    --argjson exitCode "${exit_code}" \
    --argjson elapsed "${elapsed}" \
    --argjson evidence "${evidence}" \
    '.legs += [{leg:$leg,status:"fail",started:$started,elapsed_s:$elapsed,evidence:$evidence,exitCode:$exitCode,reason:$reason}]' \
    "${SIT_REPORT_FILE}")"
  _sit_report_replace "${updated}"
  SIT_CURRENT_LEG=''
  SIT_LEG_EVIDENCE=()
}

# sit_report_finish <status> [finish-provenance-json]
#
# The finish provenance carries the SECOND half of the binding contract: the
# original checkout's head/cleanliness after execution and the recomputed
# direct-input inventory. It is merged verbatim, so a failing run still records
# whatever provenance was established.
sit_report_finish() {
  local status="$1"
  local finish_provenance="${2:-{\}}"
  jq -e '
    ((keys - [
      "checkoutHeadAtFinish",
      "checkoutCleanAtFinish",
      "directInputRecheckedAtFinish",
      "directInputSha256AtFinish"
    ]) | length) == 0
  ' <<<"${finish_provenance}" >/dev/null || {
    sit_fail 'finish provenance contains a key outside the four allowed finish fields'
    return 1
  }
  local elapsed=$(($(sit_epoch) - SIT_RUN_STARTED_EPOCH))
  local updated
  updated="$(jq \
    --arg status "${status}" \
    --arg completed "$(sit_now)" \
    --argjson elapsed "${elapsed}" \
    --argjson finish "${finish_provenance}" \
    '.status=$status | .completed=$completed | .elapsed_s=$elapsed | . + $finish' \
    "${SIT_REPORT_FILE}")"
  _sit_report_replace "${updated}"
}

sit_snapshot_apps() {
  kubectl -n argocd get applications.argoproj.io -o json >"$1"
}

sit_child_specs() {
  jq '
    [.items[] |
      select(any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and .name == "canary")) |
      {name:.metadata.name,spec:.spec}
    ] | sort_by(.name)
  ' "$1" >"$2"
}

sit_changed_names() {
  jq -n \
    --slurpfile before "$1" \
    --slurpfile after "$2" '
      ($before[0] | map({key:.name,value:.spec}) | from_entries) as $b |
      ($after[0] | map({key:.name,value:.spec}) | from_entries) as $a |
      ((($b | keys) + ($a | keys)) | unique |
        map(. as $name | select($b[$name] != $a[$name])))
    ' >"$3"
}

sit_assert_json_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  if ! cmp -s "${expected}" "${actual}"; then
    diff -u "${expected}" "${actual}" >&2 || true
    sit_fail "${description}"
    return 1
  fi
}

sit_assert_http_success() {
  jq -e '.status >= 200 and .status < 300 and .ok == true' "$1" >/dev/null ||
    sit_fail "signed webhook did not return a successful HTTP status: $1"
}

sit_assert_http_rejected() {
  local signature_mode="$1"
  local response_regex="$2"
  local evidence="$3"
  jq -e --arg mode "${signature_mode}" --arg responseRegex "${response_regex}" '
    .signatureMode == $mode and
    .status == 400 and
    .ok == false and
    (.responseBody | test($responseRegex; "i"))
  ' "${evidence}" >/dev/null ||
    sit_fail "${signature_mode} webhook was not rejected with the pinned HTTP 400 contract: ${evidence}"
}

sit_assert_complete_pass_legs() {
  # The contract list comes from this file, never from the report, so a report
  # that renames or drops a leg cannot define its own success criterion.
  jq -e \
    --argjson contract "$(_sit_leg_contract_json)" '
    .status == "running" and
    .schemaVersion == 2 and
    .legContract == $contract and
    [.legs[].leg] == $contract and
    all(.legs[]; .status == "pass" and (.evidence | length) > 0)
  ' "${SIT_REPORT_FILE}" >/dev/null ||
    sit_fail 'final SIT report does not contain the exact ordered L0-L9 pass set'
}

# Every schema-v2 provenance invariant, asserted on the finished report itself.
# The wrapper re-derives the same facts independently; this is the in-report
# half so a bare `--full` run can never finish `pass` without them.
sit_assert_provenance_bound() {
  local expected_commit="$1"
  jq -e --arg commit "${expected_commit}" '
    .schemaVersion == 2 and
    .commit == $commit and
    .checkoutHeadAtStart == $commit and
    .checkoutHeadAtFinish == $commit and
    .checkoutCleanAtStart == true and
    .checkoutCleanAtFinish == true and
    .inputSnapshotCommit == $commit and
    .inputSnapshotVerified == true and
    (.inputSnapshotTree | test("^[0-9a-f]{40}$")) and
    (.directInputRoots | length) > 0 and
    .directInputInventory == "direct-input-inventory.sha256" and
    (.directInputSha256 | test("^[0-9a-f]{64}$")) and
    .directInputFileCount > 0 and
    .directInputRecheckedAtFinish == true and
    .directInputSha256AtFinish == .directInputSha256 and
    (.harnessSha256 | test("^[0-9a-f]{64}$")) and
    .harnessFileCount > 0 and
    .harnessFileCount < .directInputFileCount
  ' "${SIT_REPORT_FILE}" >/dev/null ||
    sit_fail 'final SIT report does not bind the recorded commit, the verified snapshot, and the direct-input inventory'
}

sit_assert_child_specs_stable_for() {
  local duration_s="$1"
  local baseline="$2"
  local failure_evidence="$3"
  local scratch scratch_root
  scratch_root="${SIT_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
  [ -d "${scratch_root}" ] && [ -w "${scratch_root}" ] || {
    sit_fail "stability scratch root is not a writable directory: ${scratch_root}"
    return 1
  }
  scratch="$(mktemp -d "${scratch_root%/}/fleet-sit-stable.XXXXXX")"
  local deadline=$((SECONDS + duration_s))

  while [ "${SECONDS}" -lt "${deadline}" ]; do
    sit_snapshot_apps "${scratch}/apps.json"
    sit_child_specs "${scratch}/apps.json" "${scratch}/specs.json"
    if ! cmp -s "${baseline}" "${scratch}/specs.json"; then
      cp "${scratch}/apps.json" "${failure_evidence}"
      diff -u "${baseline}" "${scratch}/specs.json" >"${failure_evidence}.diff" || true
      rm -rf "${scratch}"
      sit_fail "Application specs changed during a bounded no-refresh interval"
      return 1
    fi
    sleep "${FLEET_SIT_POLL_SECONDS:-3}"
  done
  rm -rf "${scratch}"
}
