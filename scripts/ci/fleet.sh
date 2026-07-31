#!/usr/bin/env bash
set -euo pipefail

# Fleet node CI batch. Ordinary chart + product gates (S30 — no probe matrix).
# Live SIT/e2e traces (throwaway ArgoCD / sandbox repo / k3d) are deferred and
# documented in docs/domain/fleet-repo.md.

bash ./scripts/validate/fleet.sh lint
bash ./scripts/validate/fleet.sh input-schema
bash ./scripts/validate/fleet.sh schema-drift
bash ./scripts/validate/fleet.sh render
bash ./scripts/validate/fleet.sh row-identity
bash ./scripts/validate/fleet.sh golden
bash ./scripts/validate/fleet.sh golden-mutation
bash ./scripts/validate/fleet.sh canary-features
bash ./scripts/validate/fleet.sh dag
bash ./scripts/validate/fleet.sh dag-negative
bash ./scripts/validate/fleet.sh delivery-mode
bash ./scripts/validate/fleet.sh freight-alignment
bash ./scripts/validate/fleet.sh kargo-values-preservation
bash ./scripts/validate/fleet.sh kargo-row-update-contract
(
  cd ./scripts/validate/kargo-yaml-update
  GOTOOLCHAIN=local go test -count=1 ./...
)
bash ./scripts/validate/fleet.sh row-values-persistence
bash ./scripts/validate/fleet.sh registry-cr
bash ./scripts/validate/fleet.sh registry-exclusion
bash ./scripts/validate/fleet.sh registry-manifest-negative
bash ./scripts/validate/fleet.sh webhook-secret
bash ./scripts/validate/fleet.sh rendered-cr
bash ./scripts/validate/fleet.sh cloudflare-rollout-negative
bash ./scripts/validate/fleet.sh webhookengine-version-negative
bash ./scripts/validate/fleet.sh appset-scope
bash ./scripts/validate/fleet.sh row-expansion
bash ./scripts/validate/fleet.sh platforms-appset
bash ./scripts/validate/fleet.sh machinery-pin
# Offline model of the L9 host-image step, running the production SIT function
# bytes against a docker shim. Daemon-free, so the SIT's export-tag binding is
# regression-guarded in ordinary CI instead of only in a live SIT venue.
bash ./scripts/validate/fleet.sh sit-host-image-binding
# Offline model of the L9 node-image import step, running the production SIT
# function bytes against docker/ctr shims. Daemon-free, so the platform-scoped
# stream import, its fail-closed transcript acceptance, and the node tag+digest
# binding are regression-guarded in ordinary CI instead of only in a live SIT
# venue — and k3d's recorded false-success shape can never be accepted again.
bash ./scripts/validate/fleet.sh sit-node-image-import
bash ./scripts/validate/fleet.sh guard
bash ./scripts/validate/fleet.sh presence

# LAST DELIBERATELY. The live-manifest acceptance gate follows the controlled
# negative matrix so CI first proves the guard is non-vacuous, then accepts the
# exact ruled registry bytes that will be materialized.
bash ./scripts/validate/fleet.sh registry-manifest

echo "✅ fleet CI validation complete"
