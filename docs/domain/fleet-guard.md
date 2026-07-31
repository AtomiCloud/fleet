# Fleet registry and machinery-tag guard

This is a branch-local, reproducible configuration record. It does **not**
claim that the GitHub App, protected environment, rulesets, sandbox repository,
fixture Apps, or sandbox workflow have been provisioned or run. The checked-in
payloads and deterministic validation are the deliverable; every GitHub change
below remains an owner or fleet-admin action.

## Authority split and checked-in policy

Three writer classes share the public `AtomiCloud/fleet` repository:

- humans use pull requests for `main`; changes in `registry/**` and the full
  guard/toolchain surface require exactly one
  `@AtomiCloud/fleet-admin` CODEOWNER;
- A19/A20 automation normally writes only `platforms/**`; A20 retains the
  existing Always bypass on the `main` branch ruleset. GitHub Free supplies no
  path hard fence for either credential;
- A33 is the dedicated `fleet-machinery-tag-mover` GitHub App. Its normal path
  is the protected, no-input workflow that advances only
  `refs/tags/machinery-stable`.

`platforms/**` remains deliberately absent from CODEOWNERS. The guard owns its
own roots as well: all `.github/**`, the branch/tag payloads, guard helpers,
CI and validator directories, materializer, `flake.nix`/`flake.lock`, `.envrc`,
and `nix/**` are each assigned exactly once to fleet-admin. The deterministic
validator rejects a missing root or an appended second owner.

| Source                                                | Ref condition                       | Rules                                                                                         | Bypass actors                        |
| ----------------------------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------ |
| `.github/rulesets/registry-guard-main.json`           | default branch                      | PR, code-owner review, stale-review dismissal, last-push approval, deletion, non-fast-forward | existing Kargo actor only            |
| `.github/rulesets/machinery-stable-update.json`       | `refs/tags/machinery-stable`        | creation, update                                                                              | fleet-admin team and A33 Integration |
| `.github/rulesets/machinery-stable-delete.json`       | `refs/tags/machinery-stable`        | deletion                                                                                      | fleet-admin team only                |
| `.github/rulesets/machinery-stable-forward-only.json` | `refs/tags/machinery-stable`        | non-fast-forward                                                                              | fleet-admin team only                |
| `.github/rulesets/other-tags-protected.json`          | every tag except `machinery-stable` | creation, update, deletion, non-fast-forward                                                  | fleet-admin team only                |

No actor ID is committed. At apply time the script resolves the GitHub **App
ID** from `GET /apps/fleet-machinery-tag-mover`, separately validates and
rejects the installation ID, resolves the fleet-admin Team ID, and requires all
actor IDs to be positive integers. A33 appears exactly once, as an
`Integration` bypass on creation/update only.

The four tag rulesets are complementary. A bypass on creation/update does not
carry to deletion, non-fast-forward, or other tags. The no-A33
non-fast-forward rule is the anti-backtrack hard control; the workflow's
`force:false` is normal behavior, not a substitute security boundary.

## Owner commissioning order

The protected environment must exist and pass preflight **before** any A33
bypass is applied. Do not reverse this order.

1. Create one private, AtomiCloud-owned App with slug
   `fleet-machinery-tag-mover`, selected-repository installation on
   `AtomiCloud/fleet` only, repository permissions exactly `Contents: write`
   plus implicit `Metadata: read`, no organization/account permissions,
   webhooks/events, or user authorization. Do not reuse A19, A20, A23, or
   AtomiCloud Auth Bot.
2. Create the protected Actions environment
   `machinery-stable-tag-move` **before applying rulesets**. It must have one
   required reviewer, the `AtomiCloud/fleet-admin` Team; `prevent_self_review`
   set to `true`; selected deployment branches with exactly one `main` branch
   policy; and no repository-level
   `FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY` secret. The private key belongs only
   in this protected environment, never in a repository secret or this tree.
3. Provision the sandbox prerequisites described below. This is required before
   any live authorization claim, including the ordinary-token claim, is made.
4. From a clean reviewed `main` checkout, run the idempotent apply script. It
   resolves App/installation/Team metadata, checks the protected environment,
   exact branch policy, repository secret absence, and clean GitHub CODEOWNERS
   diagnostics, then validates local source and paginates all rulesets before
   its first write:

   ```bash
   FLEET_REPO=AtomiCloud/fleet \
   KARGO_BOT_ACTOR_ID='<existing App actor ID>' \
   KARGO_BOT_ACTOR_TYPE=Integration \
   direnv exec . bash ./scripts/local/registry-guard-apply.sh
   ```

5. Treat the first creation/readback of the tag-target `update` rule as a
   commissioning gate. The apply script canonicalizes and compares the live
   object after mutation; an API `422`, missing rule, or mismatch means GitHub
   did not accept the tag-target `update` rule. Stop there, do not add the A33
   environment key, and do not claim the tag guard has been applied.
6. Only after a successful, drift-free apply, add
   `FLEET_MACHINERY_TAG_MOVER_APP_ID` and
   `FLEET_MACHINERY_TAG_MOVER_PRIVATE_KEY` as secrets of the protected
   environment. Fleet-admin owns overlapping-key rotation: add and verify the
   replacement before revoking the old key, and rotate immediately on exposure.
7. Run and retain the periodic sandbox evidence. Until this occurs, the live
   policy-denial and R7 claims are withdrawn rather than inferred from source.

The environment API shape is intentionally documented but not executed here:

```bash
team_id="$(gh api orgs/AtomiCloud/teams/fleet-admin --jq .id)"
jq -n --argjson team_id "${team_id}" '{
  wait_timer: 0,
  prevent_self_review: true,
  reviewers: [{type: "Team", id: $team_id}],
  deployment_branch_policy: {
    protected_branches: false,
    custom_branch_policies: true
  }
}' | gh api --method PUT \
  repos/AtomiCloud/fleet/environments/machinery-stable-tag-move --input -

jq -n '{name: "main", type: "branch"}' | gh api --method POST \
  repos/AtomiCloud/fleet/environments/machinery-stable-tag-move/deployment-branch-policies \
  --input -
```

Before executing those commands, query and converge the live environment and
policies idempotently; do not create duplicate `main` policies.

## Forward-only tag workflow

`.github/workflows/machinery-stable-tag-move.yaml` is parsed by the validator
as exactly one job with exactly three steps: checkout, protected A33 token mint,
and the fixed helper. Its trigger is exactly `push` to `main` with the one
pointer path `registry/machinery-stable.yaml`; it has no dispatch, ref input,
extra job, extra branch, widened path, or extra/exfiltration step. Its ordinary
`GITHUB_TOKEN` has `contents: read`.

The helper accepts no arguments. It requires an Actions push on production
`main`, a clean checkout at `GITHUB_SHA`, and a pointer containing exactly one
lowercase full commit SHA. While it waits for protected-environment approval,
unrelated Kargo `platforms/**` commits may advance `main`: the trigger must
remain an ancestor of current `main`, and the helper rereads the pointer from
current `main`. It proceeds only if that value is unchanged; a superseding
pointer fails explicitly so its newer run owns the advance.

The helper creates only `refs/tags/machinery-stable` when absent or PATCHes only
that endpoint with `force:false`. The pointer must be on current `main` and a
descendant of the current lightweight tag. After writing, verification accepts
the requested target or a concurrent **forward** descendant on current `main`;
it rejects a backward or different-branch target. There is no branch, delete,
other-tag, or caller-selected endpoint.

The initial pointer is
`752170d700411ae4393e5dd92e9871708561932b`, observed with the read-only command
`git ls-remote github-atomi:AtomiCloud/fleet.git refs/heads/main` on 2026-07-29
UTC. Do not substitute a guessed SHA if that observation becomes stale.

Rollback is forward-only: revert the bad machinery change onto a new descendant
commit on `main`, review it, and advance through the same pointer workflow.
Break-glass does not redefine rollback as a backward tag move.

## Sandbox evidence and exact denial classification

The schedule/manual production workflow targets only the named public sandbox
`AtomiCloud/fleet-guard-sandbox`; its helper refuses production
`AtomiCloud/fleet`. Before first use, the owner must provision the sandbox with
the mirrored branch/tag policy, separate A19/A20/A33-equivalent Apps, a
non-exempt human fixture, a distinct fleet-admin reviewer, an admin token able
to dispatch/read Actions runs, and two sandbox `main` commits where
`FLEET_GUARD_SANDBOX_FORWARD_SHA` strictly descends from
`FLEET_GUARD_SANDBOX_BACKTRACK_SHA`.

The checked-in inert fixture
`registry/fixtures/guard-sandbox/.github/workflows/ordinary-token-guard-e2e.yaml`
must be copied verbatim to the sandbox repository's
`.github/workflows/ordinary-token-guard-e2e.yaml`. It deliberately uses that
sandbox workflow's own `GITHUB_TOKEN` with `contents: write`; this avoids the
old cross-repository/read-only token false proof. Production dispatches the
fixture for create and update/delete probes, waits for its completed run, and
requires its exact non-secret log evidence. Until the fixture is installed and
that evidence succeeds, the claim that an ordinary workflow token is rejected
is **withdrawn**.

All denied REST probes establish their ref/endpoint preconditions first and
capture HTTP status and response body in separate files. A probe is accepted
only for HTTP `403` or `422` with JSON policy text identifying a repository
rule/ruleset, protected branch/ref/tag, or bypass. It rejects `404`/not found,
missing scope (`resource not accessible`), wrong repositories, existing refs,
generic validation `422`s, and transport/transient failures. Those outcomes
are failures, never evidence of a ruleset denial.

The periodic definition, once commissioned, proves human direct-main rejection,
the `REVIEW_REQUIRED`/`BLOCKED` code-owner PR state before approval, A19/A20
denials, the sandbox-native ordinary-token denials, A33 forward-only behavior,
other-tag/deletion/main denials, raw A33 scratch-branch residual, and an
always-run platforms-only cleanup. No sandbox/live E2E ran while producing this
record.

## Residual authority and withdrawn claims

The Free-plan design has two accepted credential-level residuals:

1. GitHub provides no path hard fence for A19/A20. Normal tooling confines
   writes to `platforms/**`, but an extracted or faulty credential can
   technically write `registry/**` until a Team-plan path push ruleset exists.
2. `Contents: write` is not ref-scoped. A raw A33 installation token can create
   or update an otherwise-unprotected non-`main` branch. The fixed workflow has
   no such endpoint, but that does not erase the credential-level authority.

R7 remains a mandatory withdrawn-claim fallback. The raw A33
`force:true` backtrack denial is claimable only after the sandbox proves it
against the separate no-A33 non-fast-forward ruleset. If that run cannot be
made, record raw-token force-backtracking as a second A33 W2 residual; never
present the workflow's `force:false` as a hard fence.

The W2 A33 fold is an owner/lead action outside this file. It must add the
unique A33 row, selected-repository scope, protected-environment key home,
one-hour mint, overlapping-key rotation, and non-main-branch residual; it must
also correct A19/A20's former `registry/**` hard-fence wording. A23 remains
reserved for production `/keys/<landscape>` credentials.
