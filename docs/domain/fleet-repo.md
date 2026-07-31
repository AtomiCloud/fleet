# Fleet repository

`fleet` is **the one deploy repo** (ARCHITECTURE.md §8, T3-DESIGN.md §1): a
single git tree ArgoCD reads directly and the Kargo bot writes into. It is not a
CI-scaffolded service — the only artifact it _builds_ is the `diene-platform`
compiler chart, a helm-wrapper instance. This node is a **materialized product**
(S30): it carries no probe matrix, no `probes/`, no `features.json`. Behaviour is
proven by ordinary chart + product tests (`scripts/ci/fleet.sh`).

## Two zones, split by writer and cadence

```
fleet/
├── registry/                       # centralized · rare · HUMAN-PR-GATED
│   ├── landscapes/*.yaml            # Landscape CRs (FK anchor; region; tier=metadata)
│   ├── clusters/*.yaml              # ClusterRegistration CRs (mark/provider/traffic dial)
│   ├── virtual-landscapes/*.yaml    # VirtualLandscape CRs (envelope {name, hosts})
│   ├── fleet-root.yaml              # the root Application (hand-applied once)
│   ├── platforms-appset.yaml        # ApplicationSet: SCM-provider generator over AtomiCloud/*.carbon
│   └── charts/diene-platform/       # the compiler chart (helm-wrapper instance)
└── platforms/                       # decentralized · frequent · 100% MACHINE-WRITTEN
    ├── canary/                      # synthetic platform — never serves real traffic
    │   ├── services.yaml            # machine roster (T3 materializer)
    │   └── landscapes/<l>/dummy.yaml
    └── <p>/
        ├── services.yaml            # which <p>.<svc> repos exist (materializer)
        └── landscapes/<l>/<svc>.yaml # one row per service per landscape
```

`registry/` is rarely touched and PR-gated. `platforms/` is written only by the
T3 materializer and the Kargo bot — humans never touch it directly except a
break-glass row PR. Registry CRs have no self-registration path: Primordial
itself is L0, outside the registry. Deletion of any registry object is refused
while anything references it; for v-landscape envelopes that refusal extends
from delete to host-set **shrink** (removing a host is refused while a
`VirtualLandscapeService` fragment still serves that host × envelope — fragment
deletion, not `serve:false`, is the release signal).

## Row-file format

A row file `platforms/<p>/landscapes/<l>/<svc>.yaml` is the per-service,
per-landscape unit. Promoting a service edits exactly one file; "what runs in
raichu" is just the directory listing.

```yaml
# platform: is ALWAYS explicit (S16) — the single source of truth, NEVER
# inferred from the containing platforms/<p>/ directory.
platform: canary
service: dummy
landscape: raichu
# pin.tag is Kargo-written on promotion.
pin:
  tag: 0.1.0
# valuesMeta is present iff values: is present.
valuesMeta:
  addedAt: '2026-07-17T00:00:00Z'
  reason: short-lived ops knob
# values: is the optional HUMAN ops-override — the only human-writable field
# under platforms/**. It is layered LAST (over chart base + landscape + cluster
# overlays).
values:
  workload:
    replicas: 3
```

- **Writers**: stub = T3 materializer; `pin` = Kargo; `values:` = human.
- **Identity validation is fail-before-render**: the row's explicit
  `platform`, `service`, and `landscape` fields feed every generated name,
  OCI path, selector, and destination. The ApplicationSet `templatePatch`
  rejects a row unless those fields equal the containing roster/release
  namespace, an entry in that roster, the filename, and the landscape path.
  `scripts/validate/fleet-rows.sh` applies the same contract to checked-in
  machine state and carries platform/service/landscape mismatch negatives.
- **`values:` is a short-lived knob**, not a config home. The chart is the
  config home; a `values:` block is a scale-now/flip-a-flag emergency knob,
  folded back into the chart within 7 days. `scripts/validate/fleet.sh
row-values-persistence` (injected clock) flags any block older than 7 days.
- **Kargo preserves `values:` byte-for-byte**: the fixed git-update promotion
  template bumps only `pin.tag`; it never touches the `values:` block. The
  render check and fast contract model prove the configured target and guard;
  `scripts/validate/kargo-yaml-update` separately imports Kargo v1.9.10's real
  `pkg/yaml` engine and proves on the checked-in row that a `pin.tag` mutation
  preserves the raw block, while a `values.*` negative trips the byte guard.
- **Break-glass**: rows are plain git files. A row-file commit bypassing Kargo
  is legal (Kargo gates _planned_ changes only, never DR). CODEOWNERS does NOT
  cover `platforms/**`, so a break-glass row change is an ordinary fast PR.

## The `diene-platform` compiler chart

A three-source ArgoCD Application renders one platform's control plane:

- **source A** — the chart @ `registry/charts/diene-platform`, pinned to the
  `machinery-stable` git tag (canary: `main`).
- **source B** — the carbon repo's `platform.yaml` (`ref: carbon` → `$carbon`).
- **source C** — fleet's `platforms/<p>/services.yaml` (`ref: services` →
  `$services`) at `HEAD`. Its URL deliberately spells the public repository as
  `https://github.com:443/AtomiCloud/fleet`: Argo CD rejects two revisions of
  one normalized repository identity, while the explicit default port remains
  a valid GitHub URL and a distinct identity in pinned Argo CD v3.4.5. This
  keeps materializer-written rosters visible immediately without unpinning the
  compiler chart. The live SIT proves both checkouts and will fail if an Argo
  upgrade changes normalization behavior.

It renders → the `Platform` CR → per-service Kargo `Project`/`Warehouse`/`Stage`
→ the platform's own AppSet with two generators:

- **g1** — git-files over `landscapes/*/*.yaml` → one primordial `Application`
  per row, destined for the Primordial central cluster.
- **g2** — g1 × a cluster generator (label-selected by landscape) → one
  per-cluster `Application` per row per matching cluster.

The git-files matched fields are exposed as `path.segments` and
`path.filename`, but they are used only to validate the explicit row fields;
they never become workload identity. The matrix pattern (git-files × templated
cluster-label generator) is an official ArgoCD generator combination from
v2.5+; the three-source `$values` Application needs ArgoCD ≥2.10. Both were
spike-confirmed.

### `stages:` → Kargo compilation rule

A platform's `stages:` list compiles into Kargo Stages by a fixed rule: the
first step subscribes directly to the service's Warehouse; each member of a
`[parallel, set]` step takes the _preceding_ step as upstream; the step
immediately after a parallel set lists ALL of that set's members (rendezvous).
Full Kargo semantics are opt-in per step — a bare landscape name is
auto-promote + Argo-health-gated + no soak; an object
`{landscape, gate: auto|manual, soak, verification: {analysisTemplates}}` opts
into the rest. The git-update promotion template is fixed either way.

### Dependency `delivery:` rendering

Every `PlatformDependency` module carries an explicit delivery; `type:` stays
the realization selector.

- **external** (neon/upstash/tigris/r2/s3/ses) — fulfilled from Primordial via
  vendor APIs; declared but NEVER rendered onto the AppSet rail.
- **replicated** (dragonfly — the only internal replicated type) — rides the g2
  per-cluster rail. The **sole** membership mechanism is the g1 × cluster
  generator over `ClusterRegistration` landscape labels, so replicated delivery
  materializes on EVERY landscape cluster; there is no pinned mode and no
  cluster-specific override.
- **local** (cnpg/minio and local Dragonfly) — **not a fleet-core rail**.
  WAL Q-L8(c)/Q-L9 forbids lapras dependency CRs on Primordial and says lapras
  clusters are anonymous Garden copies with no `ClusterRegistration`. The
  combined input schema and compiler reject `delivery: local`; the held
  Garden/local-operator owner will render and reconcile it in-instance.

fleet asserts the registered-fleet split and that local input cannot cross the
Primordial boundary (`scripts/validate/fleet.sh delivery-mode`). The full
type/delivery realization matrix remains dependency-operator-owned.

## The `machinery-stable` tag

The compiler chart is fleet-wide machinery, bumped for every platform at once —
no per-platform drift, no N-version support burden. Every platform's Application
pins source A to the **`machinery-stable` git tag**; a bad release breaks
_rendering_ loudly (running workloads are untouched — nothing re-deploys until
the next successful render). The tag is advanced from the committed
`registry/machinery-stable.yaml` pointer, so the moving-tag mechanic remains the
S32 git-sourced exception: OCI digests cannot resolve a moving git tag; every
other chart is OCI-default.

**Canary-on-main split**: the canary platform pins source A to `main` instead of
the tag, and runs with **auto-sync DISABLED**. Every compiler-chart merge to
`main` surfaces as an Argo out-of-sync render diff a human reviews (the golden
render, for free) — syncing dummy workloads across the full declared landscape
set is at the human's discretion. Promotion flow: merge to `main` → canary
render diff reviewed (sync optional) → move `machinery-stable` (a `registry/**`
pointer-file PR, human + fleet-admin gated) → the protected tag-move workflow
verifies the pointer is a descendant on `main` and advances the tag with
`force: false` → every other platform re-renders on its next AppSet refresh.

**Who moves it**: fleet-admin reviews the pointer-file PR; the private
`fleet-machinery-tag-mover` GitHub App advances only
`refs/tags/machinery-stable` after that PR merges. "Promote to everyone" = the
forward-only tag advance; every non-canary platform re-renders on its next
(webhook-driven) AppSet refresh.

**Rollback is forward-only.** Revert the bad compiler-chart change onto a new
descendant commit on `main`, review that new canary render diff, and promote the
revert commit through the same pointer-file path. Pointing the pointer at an
ancestor is rejected; rollback never force-moves the tag backward.

## The `mercury-stable` pin

Mercury (the webhook engine — an ordinary in-cluster bun service owned by the
products platform, Q-WH1/Q-WH5) uses a separate mechanism: `mercury-stable`
resolves as an **ordinary Kargo image+chart pin** on mercury's own service rows
under `platforms/mercury/**` (chart
`Version` == image `Tag`). Every Warehouse uses Kargo ≥1.8's native
`freightCreationCriteria.expression` to compare `imageFrom(...).Tag` with
`chartFrom(...).Version`; skewed artifacts never become Freight. The dedicated
mercury/webhook fixture exercises the identical rail and a mismatched-tag
negative. CI publishes tagged image+chart artifacts; Kargo promotes through
mercury's own DAG. Those service rows are bot-written, never PR-gated, and do
not live under `registry/**`. There is ONE fleet-wide mercury deployment
(Q-MT1): no per-platform engines, no per-platform version override.
Platforms own only their webhook _config_ — the `WebhookEngine` CR (rides
carbon's primordial chart) carries retention/backoff/quotas/custom domains and
**NO engine-version field**. The CF-era
`CloudflareDeploy.desiredVersionFrom: {tag: mercury-stable}` render is DEAD.

**Who moves it**: ordinary Kargo promotion walks mercury's own
`pichu → pikachu → [raichu, ampharos]` DAG under its Argo-health gates.
`mercury-stable` has no registry artifact and no moving git tag.
`mercury-stable` and `machinery-stable` therefore promote on independent
cadences with different mechanisms. Same-PR coupling is rejected: a
compiler-chart fix must not force a webhook-engine redeploy, and vice versa.

## GitHub `registry/**` guard (Q-GH1 — PUBLIC repo + CODEOWNERS)

Two writers share one branch: humans (PR-only) and the Kargo bot (direct push to
`platforms/**`). GitHub's push-ruleset path-restriction is a Team+/Enterprise
feature, and the AtomiCloud org is on the Free plan — so the fleet repo goes
**PUBLIC** (public repos get branch protection/rulesets on Free). Accepted
consequence: fleet topology and landscape names are world-readable (secrets
never lived in the repo).

The guard is one apply-time policy set, not only a branch rule:

1. **Branch ruleset on `main`** (`.github/rulesets/registry-guard-main.json`):
   require a PR and fresh code-owner approval before merge, protect deletion and
   non-fast-forward updates, and grant the organization-owned AtomiCloud Auth Bot
   the bypass needed for normal A19/A20 `platforms/**` writes.
2. **CODEOWNERS** (`.github/CODEOWNERS`): protect `registry/**`, the guard
   machinery, and the CI enforcement roots with the
   `@AtomiCloud/fleet-admin` team.
3. **Four tag rulesets plus A33**: three rulesets cover
   `machinery-stable` creation/update, deletion, and force-push blocking; a
   fourth catch-all protects every other tag. The dedicated
   `fleet-machinery-tag-mover` GitHub App (A33) bypasses only the
   creation/update rule. It has no bypass on deletion, force-push blocking,
   other tags, or `main`, and its private key must be exposed only through the
   fleet-admin-reviewed `machinery-stable-tag-move` environment. The fixed
   workflow advances the fixed tag endpoint with `force: false` from the
   committed pointer; the no-A33-bypass force-push rule is the hard
   anti-backtrack boundary.

Human `registry/**` changes therefore take the PR + fleet-admin-review lane,
while A19/A20 normally write `platforms/**` directly. **There is no Free-plan
path-level hard fence for A19/A20**: an extracted or misbehaving bot credential
can technically write `registry/**` until a Team upgrade makes a path-restricted
push ruleset available. Tooling assertions that normal promotion emits only
`platforms/**` diffs detect contract drift; they do not turn that residual into
a GitHub-enforced path boundary.

`scripts/local/registry-guard-apply.sh` refuses a non-public/non-`main` target,
applies all five rulesets idempotently, validates the A33 App/environment, and
verifies the live policy and remote CODEOWNERS bytes. It is human-run and
re-runnable for drift repair. `scripts/validate/registry-guard.sh` is the
per-PR offline policy gate. The full provisioning contract, residual authority,
and owner actions are recorded in `docs/domain/fleet-guard.md`.

The periodic `.github/workflows/registry-guard-e2e.yaml` is now a multi-job
suite targeting the public `AtomiCloud/fleet-guard-sandbox`, not the product
repository. It covers the ordinary-token, A19/A20, and raw-A33 authorization
cases, including the accepted A33 scratch-branch capability and force-backtrack
denial. Sandbox provisioning and a successful run are owner-only work; until
that evidence exists, the live denial claims remain deferred/withdrawn exactly
as `docs/domain/fleet-guard.md` records. No obsolete production run is credited.

## ArgoCD webhook wiring

AppSet refresh is **webhook-driven, not polling**. The fleet repo's push webhook
(registry + platforms pushes, including Kargo-bot pushes) hits ArgoCD's webhook
endpoint for prompt re-render. The endpoint is configured **with a shared
secret**: ArgoCD natively validates `webhook.github.secret` from
`argocd-secret`, sourced from Infisical via the standard ESO path. An
unauthenticated refresh endpoint would be a refresh-DoS surface, so the secret is
verified at build time. `registry/argocd-webhook-secret.yaml` is the executable
wiring: ESO reads `/argocd/webhook/webhook.github.secret` from
`ClusterSecretStore/infisical` and **merges** it as the exact
`webhook.github.secret` key into the existing `argocd-secret`; the fleet-root
Application syncs that manifest. `scripts/validate/fleet.sh webhook-secret`
schema-validates the object and rejects a renamed key or replacement Secret
target. No credential value is committed.

**Polling is the fallback only** — disabling the webhook still refreshes at the
ApplicationSet controller's configured reconciliation interval, just slower; a
wrong/missing shared secret is rejected at the webhook endpoint. The live
webhook/wrong-secret/poll timing trace remains a fleet-owned ArgoCD SIT proof,
separate from the build-time secret-object contract.

Q-WH13/Q-I36 are referenced here, not implemented by fleet: this compiler only
asserts the frozen render shape for `WebhookEngine` and `CloudflareDeploy`.
Webhook config-plane reconciliation belongs to mercury.webhook and
dependency-operator.

## Environment integration boundary

Fleet carries final ENV-SPEC/Q-ENV47 as an integration contract, including the
dotted `module.service.platform.instance.landscape.zone` coordinate with
`instance` outside LPSM. Fleet commits the four registered workload Landscape
rows (`pichu`, `pikachu`, `raichu`, `ampharos`) and the `mew`/`celebi`
envelopes. Serving-cluster provider coordinates remain unratified, so only
schema-valid fixtures carry their explicit placeholders and live registry paths
refuse them. Fleet likewise defines the ENTEI host-row shape and its
infrastructure-only exclusion tests; `host-pool` owns the concrete ENTEI region,
mark, provider, and live pair. The related hosted-profile, vcluster allocation,
local-Logto, Infisical-write, sulfoxide-consumption, and durable-reaper proof tail
stays dependency/site owned.

`⚠ S11 ASSUMED-GREEN`: fleet composes helm-wrapper's load-balancer Service and
fixed-IP annotations and supplies topology to the Route53 backup-domain rail; it
does not reimplement LB/EIP behavior. The live EKS Auto Mode EIP confirmation is
user-owned. `MINUN USER-REVIEW` remains a visible safety gate for the
prod-derived-data baseline; fleet does not treat it as implicitly approved.

## Registering a new platform

Creating `AtomiCloud/<p>.carbon` IS platform registration. The platforms AppSet
is an SCM-provider generator over `AtomiCloud/*.carbon`, so a new carbon repo is
picked up with **zero fleet-repo code changes**. T3's platform-controller
materializer (org-read + fleet-write) then writes `platforms/<p>/`
(`services.yaml` + row stubs) with no human involvement beyond creating the
carbon repo. The materializer implementation + its stub/roster sync test live in
dependency-operator (the platform controller); fleet carries the layout it
writes into.

## The canary platform

`platforms/canary/` is a real platform to ArgoCD/Kargo but never serves real
traffic. `platform.yaml` lives in `AtomiCloud/canary.carbon`
(`registry/charts/diene-platform/tests/fixtures/canary.platform.yaml` is the
committed golden-render fixture). Its only job is to exercise EVERY
`platform.yaml` feature the fleet-core compiler owns, always: a pipeline
`stages:` DAG (bare + `[parallel, set]` + object-form steps) across the full
registered-fleet serving set, ≥1 `PlatformDependency` module per class family
(external and replicated delivery), a `VirtualLandscapeService`
fragment, a `WebhookEngine` block (post-Q-WH1 shape — no worker/d1/engine-version
fields), a `CloudflareDeploy` block, and a `Problem` catalog fragment. Canary
takes every compiler-chart bump first and is the fleet's own golden-render smoke
test, live in the actual ArgoCD instance. The dummy service carries ZERO business
logic — any scope creep beyond feature-exercising rows is caught at review.

Lapras is intentionally absent from canary rows and stages and has no Landscape,
ClusterRegistration, or VirtualLandscape row in this repository. Its
secrets-side identity is Garden-managed outside the fleet registry. The input
schema rejects `lapras` in the serving landscape list, pipeline stages, and every
landscape-bearing dependency/VLS/Problem fragment; the registry-manifest gate
also rejects any attempted lapras row.

Golden renders are committed at `registry/charts/diene-platform/tests/golden/`
(`canary.prod.yaml`) and diffed by
`scripts/validate/fleet.sh golden`.

## Testing and proof tiers

`scripts/ci/fleet.sh` runs the local/static tier: chart lint; deliberate closed
source-B/source-C values-schema positives and targeted negatives; schema drift;
render; explicit-row identity plus mismatch negatives; golden diff; feature and
DAG checks; registered-fleet delivery boundary; Kargo-native image/chart Freight
alignment (including mercury and skew rejection); Kargo `values:` preservation;
the pinned Kargo v1.9.10 YAML-engine integration test and its guard negative;
the `values:` >7d guardrail; registry/rendered CR validation (including
CloudflareDeploy rollout and Warehouse); rollout and WebhookEngine negatives;
AppSet scope; platforms AppSet; registry guard policy; and presence.

`scripts/ci/fleet-sit-proof.sh` is the required serialized live-local SIT entry
point. It verifies a clean exact HEAD, executes `fleet-sit.sh` from a detached
throwaway snapshot, and independently rechecks the report and direct-input
inventory. The harness creates a throwaway k3d cluster, installs
checksum-pinned Argo CD v3.4.5, derives Argo cluster Secrets from the checked-in
serving and infrastructure-only fixtures, and exercises the real
ApplicationSet and Application controllers. Run it from the repository root:

```sh
nix develop .#ci -c ./scripts/ci/fleet-sit-proof.sh
```

The structured result is `sit-report/sit-report.json`, with raw snapshots and
HTTP/controller evidence beside it. Full mode refuses a dirty worktree and
requires the recorded starting HEAD to remain unchanged and clean before it can
mark the report passed. L0–L7 cover the bounded Argo refresh, row-scoping, and
`main`/`machinery-stable` journeys. L8 is deliberately the separate pinned
Kargo schema/admission contract: it verifies the v1.9.10 CRDs and expression
engine, applies the committed render, reads it back, and checks the exact
policy/DAG/verification/soak fields while reporting preserved-unknown-field
blind spots. L9 is the runtime proof: it installs the digest-pinned Kargo
controller, management-controller, kubernetes-webhooks-server, Argo Rollouts,
and Analysis Job image; admits Freight through the real webhook; executes the
real git-clone/yaml-update/git-commit/git-push promotion steps; and proves the
auto/manual policies, both analysis gates, all-members rendezvous, policy
flips, denial cases, both soak orderings, and a separate 90-second wall-clock
strengthener. Its runtime render changes only `fleet.repoURL` and
`oci.registry`, with a canonical delta oracle protecting every policy byte.

The report keeps the remaining boundaries explicit:

- Real GitHub SCM-provider repository listing is replaced by a local list
  generator whose derivation is reverse-diff-asserted against the committed
  SCM-provider ApplicationSet.
- Per-row OCI workload synchronization and Warehouse discovery against a
  reachable registry are not exercised; the registry coordinate is deliberately
  hermetic, and webhook-admitted Freight must exactly match the Warehouse
  subscriptions.
- The literal production `15m` is exercised by backdating Kargo's persisted,
  write-once `Freight.status.currentlyIn[stage].since` reference and proving
  both verification orderings. The same released controller receives a real
  90-second wall-clock test; only literal passage of fifteen wall-clock minutes
  remains unbought.
- `api.enabled=false`, so manual approval is a real Promotion CR admitted by
  Kargo's Kubernetes webhook, not the Kargo API/UI approval surface.
- The L5 pointer move uses the throwaway repository's server-side
  compare-and-swap plus descendant precheck as the local equivalent of GitHub's
  `force:false` update-ref API; no GitHub API runs in this venue.

Registry-guard authorization remains a periodic e2e against the public sandbox
repository, not a per-PR test and not a claim about an unrun product-repo probe.

The new-platform-registration, materializer stub/roster sync, and
`OrphanedSource` deletion journeys are **dependency-operator/platform-controller
owned**. They are referenced for system completeness but are not claimed as
runnable fleet-core proof. Human acceptance of the canary render diff remains a
site-review resource; the SIT proves that the canary stays manual and surfaces
the diff, not that a human accepted it.

Also deferred (ENV/site-review boundary held): ENTEI/exposure-materializer,
fork-reaper, vcluster provisioning, Garden profiles, public-callback exposure,
CI preview lanes, final ENV registry/profile examples, and the applicable
publish-token / P-ENV / P-FACT tails.
