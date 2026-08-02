# `registry/fixtures/` — schema-valid topology fixtures for UNRATIFIED rows

These files are **not live topology**. They are the committed SHAPE that live
rows must match, for the two topology classes whose values the owner has not
ratified. They exist so the fleet node can prove its half (the row shape, the
schema, the refusal guard, the exclusion law) without guessing a value the
recorded topology ruling forbids guessing.

## Why a fixture and not a row

| Class                                       | Live row blocked on                                                                                          | Live path stays                                                          |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| serving `ClusterRegistration`               | the owner's **v1 cluster-roster ruling** (marks / providers / counts per landscape — UNSPECIFIED today)      | `registry/clusters/` **absent/empty**                                    |
| `entei` `Landscape` + `ClusterRegistration` | the owner's **ENTEI provider-input artifact**; the live commit is **`host-pool`'s deliverable**, not fleet's | no `registry/landscapes/entei.yaml`, no `registry/clusters/entei-*.yaml` |

The **emptiness of the live paths is the encoded refusal.** `host-pool` (for
ENTEI) and a future roster PR (for serving clusters) land the live rows by
copying the fixture shape and substituting the ratified values — nothing else
about the shape changes.

## Placeholder tokens

`<mark>` · `<provider>` · `<RATIFIED-HOST-REGION>`

Every fixture is **schema-valid** against `schemas/clusterregistration.json` /
`schemas/landscape.json` (the placeholders are non-empty strings, so
`kubeconform` passes and the shape is genuinely proven). The
placeholder-live-path guard in `scripts/validate/fleet.sh` (mode
`registry-manifest`) refuses any `<...>` token appearing under a **live**
registry path, so a placeholder can never be promoted into a live row by
accident.

## Layout

```
fixtures/
├── clusters/     serving-cluster + ENTEI cluster shapes (placeholders)
├── landscapes/   the ENTEI infrastructure-only Landscape shape
└── negative/     fixtures that MUST be rejected or MUST be excluded
```

`negative/` holds three distinct obligations:

1. `entei-traffic-true.yaml` — the `traffic: false` **invariant**; flipping it
   must be rejected.
2. `platform-declares-entei.yaml` — a `platform.yaml` naming an
   infrastructure-only landscape in `landscapes:`/`stages:` must be rejected.
3. `second-infrastructure-*.yaml` — a **second, differently named** synthetic
   infrastructure-only pair that must be excluded **identically** to `entei`.
   This is the fixture that proves the exclusion keys on
   `purpose: infrastructure-only` / `hostRole`, **not** on the literal string
   `entei` (host-pool §1).

## Not synced by ArgoCD

`registry/fleet-root.yaml`'s `directory.include` glob is an explicit allowlist
(`landscapes/*.yaml,clusters/*.yaml,virtual-landscapes/*.yaml,argocd-webhook-secret.yaml,platforms-appset.yaml`).
`fixtures/**` is deliberately outside it, so ArgoCD never applies a fixture —
including the negatives, which would otherwise be applied as real objects. The
`registry-manifest` gate asserts that exclusion so it cannot silently regress.
