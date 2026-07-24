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
  template bumps only `pin.tag`; it never touches the `values:` block. Proven by
  `scripts/validate/fleet.sh kargo-values-preservation`.
- **Break-glass**: rows are plain git files. A row-file commit bypassing Kargo
  is legal (Kargo gates _planned_ changes only, never DR). CODEOWNERS does NOT
  cover `platforms/**`, so a break-glass row change is an ordinary fast PR.

## The `diene-platform` compiler chart

A three-source ArgoCD Application renders one platform's control plane:

- **source A** — the chart @ `registry/charts/diene-platform`, pinned to the
  `machinery-stable` git tag (canary: `main`).
- **source B** — the carbon repo's `platform.yaml` (`ref: carbon` → `$carbon`).
- **source C** — fleet's `platforms/<p>/services.yaml` (`ref: services` →
  `$services`).

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
the next successful render) and rollback is moving the tag back one commit. This
moving-tag mechanic is WHY the compiler chart is the S32 git-sourced exception:
OCI digests cannot resolve a moving git tag; every other chart is OCI-default.

**Canary-on-main split**: the canary platform pins source A to `main` instead of
the tag, and runs with **auto-sync DISABLED**. Every compiler-chart merge to
`main` surfaces as an Argo out-of-sync render diff a human reviews (the golden
render, for free) — syncing dummy workloads across the full declared landscape
set is at the human's discretion. Promotion flow: merge to `main` → canary
render diff reviewed (sync optional) → move `machinery-stable` (a `registry/**`
PR, human + fleet-admin gated) → every other platform re-renders on its next
AppSet refresh.

**Who moves it**: fleet-admin, via a `registry/**` PR that fast-forwards the tag
one commit. "Promote to everyone" = the tag moves; every non-canary platform
re-renders on its next (webhook-driven) AppSet refresh.

## The `mercury-stable` pin

Mercury (the webhook engine — an ordinary in-cluster bun service owned by the
products platform, Q-WH1/Q-WH5) is versioned by the **same idiom** as
`machinery-stable`, but the mechanics differ: `mercury-stable` resolves as an
**ordinary Kargo image+chart pin** on mercury's own service rows (chart
`Version` == image `Tag`). Every Warehouse uses Kargo ≥1.8's native
`freightCreationCriteria.expression` to compare `imageFrom(...).Tag` with
`chartFrom(...).Version`; skewed artifacts never become Freight. The dedicated
mercury/webhook fixture exercises the identical rail and a mismatched-tag
negative. CI publishes tagged image+chart artifacts; Kargo promotes. There is
ONE fleet-wide mercury
deployment (Q-MT1): no per-platform engines, no per-platform version override.
Platforms own only their webhook _config_ — the `WebhookEngine` CR (rides
carbon's primordial chart) carries retention/backoff/quotas/custom domains and
**NO engine-version field**. The CF-era
`CloudflareDeploy.desiredVersionFrom: {tag: mercury-stable}` render is DEAD.

**Who moves it**: fleet-admin, via a `registry/**` PR bumping the pin.
`mercury-stable` and `machinery-stable` promote on **independent cadence,
identical mechanism** — each promotes on its own merge (canary green →
fast-forward its OWN moving pointer). Same-PR coupling is rejected: a
compiler-chart fix must not force a webhook-engine redeploy, and vice versa.

## GitHub `registry/**` guard (Q-GH1 — PUBLIC repo + CODEOWNERS)

Two writers share one branch: humans (PR-only) and the Kargo bot (direct push to
`platforms/**`). GitHub's push-ruleset path-restriction is a Team+/Enterprise
feature, and the AtomiCloud org is on the Free plan — so the fleet repo goes
**PUBLIC** (public repos get branch protection/rulesets on Free). Accepted
consequence: fleet topology and landscape names are world-readable (secrets
never lived in the repo).

The guard, applied as code:

1. **Branch ruleset on `main`** (`.github/rulesets/registry-guard-main.json`):
   require a PR + required code-owner review before merge, deletion + non-fast-
   forward protection, and **Kargo-bot bypass = Always** so its `platforms/**`
   promotion commits push directly.
   The provisioned Kargo automation identity is the organization-owned
   **AtomiCloud Auth Bot** GitHub App (`contents: write` only); the ruleset
   records that App's integration actor ID, never a human or organization-admin
   bypass.
2. **CODEOWNERS** (`.github/CODEOWNERS`): `registry/**` → the
   `@AtomiCloud/fleet-admin` team; combined with the ruleset's
   `require_code_owner_review`, this is a hard fleet-admin gate on registry
   changes. `platforms/**` is deliberately ABSENT (break-glass rows stay
   ungated).

Net: `registry/**` changes are human-PR + fleet-admin-review gated; the bot
pushes `platforms/**` directly. **Accepted Free-plan gap**: a misbehaving bot
could technically touch `registry/**` until a Team upgrade adds a path-restricted
push ruleset (which is then addable with no redesign). The residual is covered by
a periodic sandbox test asserting the bot tooling never writes outside
`platforms/**`.

The config is managed as code: `scripts/local/registry-guard-apply.sh` refuses
a non-public/non-`main` target, applies the payload idempotently, then verifies
the exact live policy and the remote CODEOWNERS bytes. It is human-run and
re-runnable for drift repair. `scripts/validate/registry-guard.sh` is the
offline policy-validation gate (per-PR). This is orthogonal to the tag
mechanism: the guard governs _who can write_ `registry/**`; the tag governs
_when a write takes effect_.

## ArgoCD webhook wiring

AppSet refresh is **webhook-driven, not polling**. The fleet repo's push webhook
(registry + platforms pushes, including Kargo-bot pushes) hits ArgoCD's webhook
endpoint for prompt re-render. The endpoint is configured **with a shared
secret**: ArgoCD natively validates `webhook.github.secret` from
`argocd-secret`, sourced from Infisical via the standard ESO path. An
unauthenticated refresh endpoint would be a refresh-DoS surface, so the secret is
verified at build time. **Polling is the fallback only** — disabling the webhook
still refreshes, just slower; a wrong/missing secret is rejected.

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

Lapras is intentionally absent from canary rows and stages. Fleet retains only
`registry/landscapes/lapras.yaml`, the secrets-side identity anchor required by
WAL Q-L8(c); it carries no cluster registration or central dependency material.
The deliberate input schema rejects `lapras` in the serving landscape list,
pipeline stages, and every landscape-bearing dependency/VLS/Problem fragment,
while the checked-in row validator independently rejects a lapras row.

Golden renders are committed at `registry/charts/diene-platform/tests/golden/`
(`canary.prod.yaml`) and diffed by
`scripts/validate/fleet.sh golden`.

## Testing and deferred proofs

`scripts/ci/fleet.sh` runs the local/static tier: chart lint; deliberate closed
source-B/source-C values-schema positives and targeted negatives; schema drift;
render; explicit-row identity plus mismatch negatives; golden diff; feature and
DAG checks; registered-fleet delivery boundary; Kargo-native image/chart Freight
alignment (including mercury and skew rejection); Kargo `values:` preservation;
the `values:` >7d guardrail; registry/rendered CR validation (including
CloudflareDeploy rollout and Warehouse); rollout and WebhookEngine negatives;
AppSet scope; platforms AppSet; registry guard policy; and presence.

**Deferred to a serialized live proof window (reserved for orchestration
authorization)** — every long proof here is LIVE, not a quiet-host static run:

- Fleet-owned ArgoCD machinery-tag/webhook refresh and Kargo row-promotion
  traces use the exact bounded harnesses named in the proof-ready handoff.
- machinery-stable / canary split, and webhook-driven refresh, against a live
  ArgoCD instance.
- registry-guard real behaviour + bot-tooling scope, against a public sandbox
  repo (periodic, not per-PR — GitHub authorization is best proven against a
  real repo).

The new-platform-registration, materializer stub/roster sync, and
`OrphanedSource` deletion journeys are **dependency-operator/platform-controller
owned**. They are referenced for system completeness but are not claimed as
runnable fleet-core proof. Canary manual-sync and human render-diff acceptance
are site-review/HOLD resources, not automated fleet-core evidence.

Also deferred (ENV/site-review boundary held): ENTEI/exposure-materializer,
fork-reaper, vcluster provisioning, Garden profiles, public-callback exposure,
CI preview lanes, final ENV registry/profile examples, and the applicable
publish-token / P-ENV / P-FACT tails.
