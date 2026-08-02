#!/usr/bin/env bash
set -euo pipefail

# Fleet node validation (S30 product — no probe matrix). The diene-platform
# compiler chart inherits helm-wrapper's chart gates (lint/template/schema) as
# ordinary chart CI; the repo-level behaviours (golden render, delivery-mode
# split, Kargo values preservation, registry-CR schema, ArgoCD spike facts) are
# proven here by concrete product tests, not a probe suite. Live SIT/e2e traces
# (throwaway ArgoCD / sandbox repo / k3d) are deferred — see
# docs/domain/fleet-repo.md.

mode="${1:-}"
chart="registry/charts/diene-platform"
fixture="${chart}/tests/fixtures/canary.platform.yaml"
services="platforms/canary/services.yaml"
mercury_fixture="${chart}/tests/fixtures/mercury.platform.yaml"
mercury_services="${chart}/tests/fixtures/mercury.services.yaml"
golden_dir="${chart}/tests/golden"
release="canary"
namespace="canary"
prefix="atomi.cloud"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

[ -z "${mode}" ] && echo "❌ validation mode not set" >&2 && exit 1

fail() {
  echo "❌ $1" >&2
  exit 1
}

# Render the canary platform.
render() {
  helm template "${release}" "${chart}" --namespace "${namespace}" \
    --values "${services}" --values "${fixture}"
}

case "${mode}" in
lint)
  helm lint "${chart}" --namespace "${namespace}" \
    --values "${services}" --values "${fixture}"
  ;;
input-schema)
  helm lint "${chart}" --namespace "${namespace}" \
    --values "${services}" --values "${fixture}" >/dev/null

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  cp "${services}" "${tmp}/bad-services.yaml"
  yq -i '.belt = ["derived-is-not-input"]' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${tmp}/bad-services.yaml" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted an unknown root/source-B field"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  cp "${services}" "${tmp}/bad-services.yaml"
  yq -i 'del(.services[0].repo)' "${tmp}/bad-services.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${tmp}/bad-services.yaml" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted a malformed source-C roster row"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  cp "${services}" "${tmp}/bad-services.yaml"
  yq -i '.stages[0] = {"landscape": "pichu", "gate": "sometimes"}' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${tmp}/bad-services.yaml" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted a malformed DAG member"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.dependencies.database.maindb.unexpected = true' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted an open dependency fragment"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.dependencies.landscape = "lapras"' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted a Primordial lapras dependency"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.virtualLandscapeServices[0].hostname = "forbidden.example"' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted an open VLS fragment"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.webhookEngine.engineVersion = "mercury-stable"' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted a forbidden WebhookEngine field"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.cloudflareDeploy[0].rollout.steps[0].percent = 101' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted an invalid deploy rollout"

  cp "${fixture}" "${tmp}/bad-platform.yaml"
  yq -i '.problems[0].entries[0].status = 399' "${tmp}/bad-platform.yaml"
  helm lint "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/bad-platform.yaml" >/dev/null 2>&1 &&
    fail "combined input schema accepted an invalid Problem fragment"
  echo "  closed source-B/source-C schema accepts canary and rejects targeted malformed shapes ✓"
  ;;
schema-drift)
  bash ./scripts/local/generate-platform-schema.sh "${tmp}/values.schema.json" >/dev/null
  cmp "${chart}/values.schema.json" "${tmp}/values.schema.json" ||
    fail "diene-platform values.schema.json is stale — run scripts/local/generate-platform-schema.sh"
  ;;
render)
  render >/dev/null
  # S16: the explicit platform must equal the release namespace, or compile fails.
  helm template "${release}" "${chart}" --namespace "wrong-ns" \
    --values "${services}" --values "${fixture}" >/dev/null 2>&1 &&
    fail "namespace/platform mismatch was accepted (S16 guard broken)"
  echo "  namespace/platform S16 guard rejects a mismatch ✓"
  ;;
row-identity)
  bash ./scripts/validate/fleet-rows.sh platforms >/dev/null
  cp -R platforms "${tmp}/rows"
  row="${tmp}/rows/canary/landscapes/raichu/dummy.yaml"

  yq -i '.platform = "other"' "${row}"
  bash ./scripts/validate/fleet-rows.sh "${tmp}/rows" >/dev/null 2>&1 &&
    fail "row validator accepted a platform mismatch"
  cp platforms/canary/landscapes/raichu/dummy.yaml "${row}"

  yq -i '.service = "other"' "${row}"
  bash ./scripts/validate/fleet-rows.sh "${tmp}/rows" >/dev/null 2>&1 &&
    fail "row validator accepted a service/filename mismatch"
  cp platforms/canary/landscapes/raichu/dummy.yaml "${row}"

  yq -i '.landscape = "other"' "${row}"
  bash ./scripts/validate/fleet-rows.sh "${tmp}/rows" >/dev/null 2>&1 &&
    fail "row validator accepted a landscape/path mismatch"
  echo "  explicit row platform/service/landscape identity + three mismatch negatives ✓"
  ;;
golden)
  render >"${tmp}/prod.yaml"
  cmp "${golden_dir}/canary.prod.yaml" "${tmp}/prod.yaml" ||
    fail "canary prod golden render drifted — regenerate tests/golden/canary.prod.yaml"
  ;;
canary-features)
  render >"${tmp}/r.yaml"
  json() { yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s "$1"; }
  # Every machinery feature present (asserted present, not just "doesn't error").
  json -e 'map(select(.kind=="Platform")) | length==1' >/dev/null || fail "Platform CR missing"
  json -e 'map(select(.kind=="PlatformDependency")) | length==1' >/dev/null || fail "PlatformDependency missing"
  json -e 'map(select(.kind=="VirtualLandscapeService")) | length==1' >/dev/null || fail "VLS fragment missing"
  json -e 'map(select(.kind=="WebhookEngine")) | length==1' >/dev/null || fail "WebhookEngine missing"
  json -e 'map(select(.kind=="CloudflareDeploy")) | length==1' >/dev/null || fail "CloudflareDeploy missing"
  json -e 'map(select(.kind=="Project")) | length==1' >/dev/null || fail "Kargo Project missing"
  json -e 'map(select(.kind=="Warehouse")) | length==1' >/dev/null || fail "Kargo Warehouse missing"
  # Full registered-fleet serving set present as Kargo Stages; lapras is a
  # secrets-side Landscape anchor and must not materialize centrally.
  json -e '[.[] | select(.kind=="Stage") | .metadata.labels["'"${prefix}"'/landscape"]] | sort == ["ampharos","pichu","pikachu","raichu"]' >/dev/null ||
    fail "Kargo stages do not cover exactly the registered WORKLOAD landscape set"
  # ENTEI is infrastructure-only and must never receive a Stage, a row, or any
  # rendered object — asserted on the rendered output, not only on the input.
  json -e 'all(.[]; (.metadata.labels["'"${prefix}"'/landscape"] // "") != "entei")' >/dev/null ||
    fail "an infrastructure-only landscape received a rendered object (exclusion law, ENV-SPEC §0.3)"
  # Canary dummy-service guardrail: exactly ONE service, named dummy, so canary
  # can never quietly become a second real platform to maintain.
  json -e '[.[] | select(.kind=="Warehouse") | .metadata.name] == ["dummy"]' >/dev/null ||
    fail "canary must expose exactly one service named 'dummy' (dummy-service guardrail)"
  # ≥1 dependency module per class family.
  json -e 'map(select(.kind=="PlatformDependency"))[0].spec | (.database|length>=1) and (.kv|length>=1) and (.cache|length>=1) and (.store|length>=1)' >/dev/null ||
    fail "PlatformDependency lacks a module in every class family"
  # WebhookEngine post-Q-WH1 shape — NO engine-version field of any kind.
  json -e 'map(select(.kind=="WebhookEngine"))[0].spec | has("version")==false and has("engineVersion")==false and has("engine")==false' >/dev/null ||
    fail "WebhookEngine carries a forbidden engine-version field (Q-WH1)"
  echo "  every platform.yaml feature present + WebhookEngine version-free ✓"
  ;;
dag)
  render >"${tmp}/r.yaml"
  stage() { yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s '.[] | select(.kind=="Stage" and .metadata.name=="'"$1"'")'; }
  policies() { yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s '.[] | select(.kind=="ProjectConfig") | .spec.promotionPolicies'; }
  auto_enabled() { policies | jq -e --arg s "$1" 'map(select(.stageSelector.name==$s and .autoPromotionEnabled==true)) | length==1' >/dev/null; }
  no_policy() { policies | jq -e --arg s "$1" 'map(select(.stageSelector.name==$s)) | length==0' >/dev/null; }

  # ---------------------------------------------------------------------------
  # FIELD-EXACT v1 Kargo mapping (goals/fleet.md: "exact, not an implementation
  # choice"). Every assertion below reads a REAL Kargo field, never an
  # annotation: an annotation cannot gate a promotion, so asserting one would be
  # a green that answers a weaker question than the one being asked.
  # Field shapes verified against the Kargo v1.9.10 CRDs
  # (projectconfigs: stageSelector.name + autoPromotionEnabled;
  #  stages: sources.{direct,stages,availabilityStrategy,requiredSoakTime}).
  # ---------------------------------------------------------------------------

  # pichu — bare first step: enabled auto-promotion policy, subscribes DIRECT to
  # the Warehouse, no verification, no required-soak.
  auto_enabled canary-dummy-pichu || fail "pichu must carry an enabled auto-promotion policy"
  stage canary-dummy-pichu | jq -e '.spec.requestedFreight[0].sources.direct==true' >/dev/null ||
    fail "first pipeline step must subscribe direct to the Warehouse"
  stage canary-dummy-pichu | jq -e '.spec.verification==null and (.spec.requestedFreight[0].sources|has("requiredSoakTime")|not)' >/dev/null ||
    fail "bare first step must omit verification and required-soak fields"

  # pikachu — object parallel member, gate: manual: NO enabling policy (absence
  # is the mechanism), requests freight from pichu, carries canary-smoke.
  no_policy canary-dummy-pikachu || fail "gate: manual must emit NO enabling promotion policy for pikachu"
  stage canary-dummy-pikachu | jq -e '.spec.requestedFreight[0].sources.stages==["canary-dummy-pichu"]' >/dev/null ||
    fail "parallel-set member must take the preceding step as upstream"
  stage canary-dummy-pikachu | jq -e '.spec.verification.analysisTemplates==[{"name":"canary-smoke"}]' >/dev/null ||
    fail "pikachu must carry exactly analysisTemplates [{name: canary-smoke}]"

  # raichu — BARE parallel member: enabled policy, upstream pichu, and no
  # verification or required-soak fields at all.
  auto_enabled canary-dummy-raichu || fail "bare parallel member raichu must carry an enabled auto-promotion policy"
  stage canary-dummy-raichu | jq -e '.spec.requestedFreight[0].sources.stages==["canary-dummy-pichu"]' >/dev/null ||
    fail "bare parallel member must take the preceding step as upstream"
  stage canary-dummy-raichu | jq -e '.spec.verification==null and (.spec.requestedFreight[0].sources|has("requiredSoakTime")|not)' >/dev/null ||
    fail "bare parallel member must omit verification and required-soak fields"

  # ampharos — the post-parallel RENDEZVOUS: enabled policy, BOTH upstream
  # members, availabilityStrategy All, 15m residency, canary-analysis.
  auto_enabled canary-dummy-ampharos || fail "ampharos rendezvous must carry an enabled auto-promotion policy"
  stage canary-dummy-ampharos | jq -e '.spec.requestedFreight[0].sources.stages==["canary-dummy-pikachu","canary-dummy-raichu"]' >/dev/null ||
    fail "step after a parallel set must rendezvous on ALL members, in order"
  stage canary-dummy-ampharos | jq -e '.spec.requestedFreight[0].sources.availabilityStrategy=="All"' >/dev/null ||
    fail "rendezvous must set sources.availabilityStrategy: All (Kargo defaults to OneOf — omitting it silently weakens the gate)"
  stage canary-dummy-ampharos | jq -e '.spec.requestedFreight[0].sources.requiredSoakTime=="15m"' >/dev/null ||
    fail "rendezvous must map soak to sources.requiredSoakTime: 15m"
  stage canary-dummy-ampharos | jq -e '.spec.verification.analysisTemplates==[{"name":"canary-analysis"}]' >/dev/null ||
    fail "ampharos must carry exactly analysisTemplates [{name: canary-analysis}]"

  # Every Stage retains the fixed git-update promotion template, identical for
  # auto and manual gates, and updates ONLY the pin.
  yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s -e '
    [.[] | select(.kind=="Stage")] as $s
    | ($s|length) == 4
    and all($s[]; [.spec.promotionTemplate.spec.steps[].uses] == ["git-clone","yaml-update","git-commit","git-push"])
    and all($s[]; [.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates[].key] == ["pin.tag"])
    and all($s[]; [.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates[].value] == ["${{ imageFrom(\"registry.atomi.cloud/canary/dummy\").Tag }}"])
  ' >/dev/null || fail "every Stage must retain the fixed pin-only git-update promotion template with the exact native Kargo imageFrom(...).Tag value"

  echo "  stages: → Kargo v1 mapping (ProjectConfig policies / direct / preceding / rendezvous All+soak / verification / fixed pin-only template) ✓"
  ;;
dag-negative)
  # Controlled negatives over the EXACT rendered fields. Each mutates one field
  # of the ratified fixture and requires the shape assertion above to notice.
  # These are golden-diff-class negatives expressed as targeted field checks so
  # a failure names the field rather than dumping a whole-file diff.
  neg() {
    local desc="$1" expr="$2"
    cp "${fixture}" "${tmp}/neg.yaml"
    yq -i "${expr}" "${tmp}/neg.yaml"
    helm template "${release}" "${chart}" --namespace "${namespace}" \
      --values "${services}" --values "${tmp}/neg.yaml" >"${tmp}/neg-render.yaml" 2>/dev/null || {
      echo "    ${desc} → rejected at render ✓"
      return 0
    }
    cmp -s "${golden_dir}/canary.prod.yaml" "${tmp}/neg-render.yaml" &&
      fail "negative '${desc}' produced a render IDENTICAL to the golden — the mutation is invisible"
    echo "    ${desc} → golden diff detected ✓"
  }
  # remove the rendezvous soak
  neg "rendezvous soak removed" 'del(.stages[2].soak)'
  # flip the rendezvous gate to manual (drops its enabling policy)
  neg "rendezvous gate flipped to manual" '.stages[2].gate = "manual"'
  # flip the manual parallel member to auto (adds an enabling policy)
  neg "manual member flipped to auto" '.stages[1][0].gate = "auto"'
  # rename an analysis template
  neg "analysis template renamed" '.stages[2].verification.analysisTemplates[0] = "not-canary-analysis"'
  # drop verification from the manual member
  neg "manual member verification removed" 'del(.stages[1][0].verification)'

  # ---------------------------------------------------------------------------
  # RENDER-TAMPER negatives — prove the `dag` field assertions are NON-VACUOUS.
  # The two mutations the goal names by name (dropping `availabilityStrategy:
  # All`, and dropping an upstream stage name from the rendezvous) cannot be
  # reached from the INPUT: the parallel set's minItems:2 rejects the collapsed
  # DAG at the schema, so an input mutation would only re-test the schema. These
  # tamper the RENDERED output directly and require the exact assertion the
  # `dag` mode runs to go red — i.e. they test the guard, not the input.
  # ---------------------------------------------------------------------------
  render >"${tmp}/t.yaml"
  # Both dollar-brace forms are literal Kargo inputs, not shell expansions.
  # shellcheck disable=SC2016
  bad_pipe_value='${{ imageFrom "registry.atomi.cloud/canary/dummy" | .Tag }}'
  # shellcheck disable=SC2016
  exact_yaml_update_value='${{ imageFrom("registry.atomi.cloud/canary/dummy").Tag }}'
  tamper() {
    local desc="$1" mutate="$2" assert="$3"
    yq eval-all -o=json '.' "${tmp}/t.yaml" |
      jq -s --arg bad_pipe_value "$bad_pipe_value" --arg exact_yaml_update_value "$exact_yaml_update_value" "${mutate}" >"${tmp}/tampered.json"
    if jq -e --arg exact_yaml_update_value "$exact_yaml_update_value" "${assert}" "${tmp}/tampered.json" >/dev/null 2>&1; then
      fail "VACUOUS GUARD: '${desc}' still satisfied the dag assertion — that assertion proves nothing"
    fi
    echo "    ${desc} → dag assertion goes red ✓"
  }
  tamper "availabilityStrategy: All deleted from the rendezvous" \
    'map(if .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" then del(.spec.requestedFreight[0].sources.availabilityStrategy) else . end)' \
    'any(.[]; .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" and .spec.requestedFreight[0].sources.availabilityStrategy=="All")'
  tamper "one upstream stage name dropped from the rendezvous" \
    'map(if .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" then .spec.requestedFreight[0].sources.stages = ["canary-dummy-raichu"] else . end)' \
    'any(.[]; .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" and .spec.requestedFreight[0].sources.stages==["canary-dummy-pikachu","canary-dummy-raichu"])'
  tamper "requiredSoakTime deleted from the rendezvous" \
    'map(if .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" then del(.spec.requestedFreight[0].sources.requiredSoakTime) else . end)' \
    'any(.[]; .kind=="Stage" and .metadata.name=="canary-dummy-ampharos" and .spec.requestedFreight[0].sources.requiredSoakTime=="15m")'
  tamper "manual pikachu granted an enabling promotion policy" \
    'map(if .kind=="ProjectConfig" then .spec.promotionPolicies += [{"stageSelector":{"name":"canary-dummy-pikachu"},"autoPromotionEnabled":true}] else . end)' \
    '[.[] | select(.kind=="ProjectConfig") | .spec.promotionPolicies[] | select(.stageSelector.name=="canary-dummy-pikachu")] | length==0'
  # The jq variables below are populated by --arg, not expanded by the shell.
  # shellcheck disable=SC2016
  tamper "yaml-update value uses the invalid Go-template pipe" \
    'map(if .kind=="Stage" then (.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates[].value) = $bad_pipe_value else . end)' \
    'all(.[]; (.kind != "Stage") or ([.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates[].value] == [$exact_yaml_update_value]))'

  echo "  controlled DAG negatives visible in the render, and the dag assertions proven non-vacuous ✓"
  ;;
delivery-mode)
  render >"${tmp}/prod.yaml"
  pd() { yq eval-all -o=json '.' "$1" | jq -s '.[] | select(.kind=="PlatformDependency") | .spec'; }
  # replicated (dragonfly) rides the g2 rail on EVERY eligible landscape cluster.
  pd "${tmp}/prod.yaml" | jq -e '.cache | has("hot")' >/dev/null || fail "replicated module must render (prod)"
  # external (neon/upstash/tigris) is declared but fulfilled off-rail from Primordial.
  pd "${tmp}/prod.yaml" | jq -e '(.database|has("maindb")) and (.kv|has("sessions")) and (.store|has("assets"))' >/dev/null ||
    fail "external modules must be declared in prod"
  # A local module must be rejected before Helm can render a Primordial CR.
  cp "${fixture}" "${tmp}/local-platform.yaml"
  yq -i '.dependencies.database.maindb.delivery = "local"' "${tmp}/local-platform.yaml"
  helm template "${release}" "${chart}" --namespace "${namespace}" --values "${services}" --values "${tmp}/local-platform.yaml" >/dev/null 2>&1 &&
    fail "delivery: local was centrally rendered instead of rejected"
  echo "  delivery split: replicated on-rail / external declared / local rejected as Garden-owned ✓"
  ;;
freight-alignment)
  render >"${tmp}/canary.yaml"
  helm template mercury "${chart}" --namespace mercury \
    --values "${mercury_services}" --values "${mercury_fixture}" >"${tmp}/mercury.yaml"
  # Fast deterministic regression over the exact rendered expression. The
  # correction handoff additionally runs these fixtures through Kargo
  # v1.9.10's native freightCreationCriteria evaluator; this Bun helper is not
  # represented as a substitute controller.
  for rendered in "${tmp}/canary.yaml" "${tmp}/mercury.yaml"; do
    while IFS= read -r warehouse; do
      name="$(jq -r '.metadata.namespace + "/" + .metadata.name' <<<"${warehouse}")"
      expression="$(jq -r '.spec.freightCreationCriteria.expression' <<<"${warehouse}")"
      image_repo="$(jq -r '.spec.subscriptions[] | select(.image) | .image.repoURL' <<<"${warehouse}")"
      chart_repo="$(jq -r '.spec.subscriptions[] | select(.chart) | .chart.repoURL' <<<"${warehouse}")"
      expected="imageFrom('${image_repo}').Tag == chartFrom('${chart_repo}').Version"
      [ "${expression}" != "${expected}" ] && fail "${name} has a non-native or wrong freight alignment criterion"
      jq -n --arg image "${image_repo}" --arg chart "${chart_repo}" \
        '{images:[{RepoURL:$image,Tag:"1.2.3"}],charts:[{RepoURL:$chart,Version:"1.2.3"}]}' >"${tmp}/aligned.json"
      bun ./scripts/validate/kargo-freight-criteria.ts "${expression}" "${tmp}/aligned.json" ||
        fail "${name} rejected aligned image/chart freight"
      jq -n --arg image "${image_repo}" --arg chart "${chart_repo}" \
        '{images:[{RepoURL:$image,Tag:"1.2.3"}],charts:[{RepoURL:$chart,Version:"1.2.4"}]}' >"${tmp}/skewed.json"
      if bun ./scripts/validate/kargo-freight-criteria.ts "${expression}" "${tmp}/skewed.json"; then
        fail "${name} accepted mismatched image/chart freight"
      fi
    done < <(yq eval-all -o=json '.' "${rendered}" | jq -c 'select(.kind == "Warehouse")')
  done
  echo "  rendered Kargo criterion accepts aligned fixtures and rejects skew, including mercury/webhook ✓"
  ;;
kargo-values-preservation)
  render >"${tmp}/r.yaml"
  # The fixed git-update promotion template bumps ONLY pin.tag; it must never
  # touch the human values: override block (Kargo preserves it byte-for-byte).
  yq eval-all -o=json '.' "${tmp}/r.yaml" |
    jq -s '.[] | select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates' |
    jq -e 'length==1 and .[0].key=="pin.tag"' >/dev/null ||
    fail "Kargo yaml-update must touch ONLY pin.tag (values: block preserved)"
  # The canary raichu row carries a human values: block; assert it exists and is
  # covered by the persistence-meta convention.
  yq -e '.values.workload.replicas==3 and (.valuesMeta.addedAt|length>0)' \
    platforms/canary/landscapes/raichu/dummy.yaml >/dev/null ||
    fail "canary raichu row values: override or valuesMeta missing"
  echo "  Kargo promotion template config is pin-only; values: fixture is present ✓"
  ;;
row-values-persistence)
  # >7d persistence guardrail (unit, injected clock). A values: block present in
  # a row for more than 7 days without being folded back into the chart trips a
  # finding. NOW is injectable so CI is deterministic.
  now="${FLEET_NOW:-2026-07-19T00:00:00Z}"
  now_s="$(date -u -d "${now}" +%s)"
  findings=0
  while IFS= read -r row; do
    added="$(yq -r '.valuesMeta.addedAt // ""' "${row}")"
    has_values="$(yq -r 'has("values")' "${row}")"
    [ "${has_values}" != "true" ] && continue
    [ -z "${added}" ] && fail "row ${row} has values: but no valuesMeta.addedAt"
    added_s="$(date -u -d "${added}" +%s)"
    age_days=$(((now_s - added_s) / 86400))
    if [ "${age_days}" -gt 7 ]; then
      echo "  ⚠ persistence finding: ${row} values: block is ${age_days}d old (>7d, fold back into the chart)"
      findings=$((findings + 1))
    else
      echo "  ${row} values: block is ${age_days}d old (≤7d, within the ops-knob window) ✓"
    fi
  done < <(find platforms -type f -name '*.yaml' -path '*/landscapes/*')
  # Positive gate: with the committed clock the canary block is fresh (no finding).
  [ "${findings}" -ne 0 ] && fail "un-folded >7d values: overrides present (see findings above)"
  # Negative proof: a clock 8+ days later MUST produce a finding.
  late="$(FLEET_NOW=2026-08-01T00:00:00Z bash "$0" row-values-persistence 2>&1 || true)"
  echo "${late}" | grep -q 'persistence finding' ||
    fail "persistence guardrail failed to fire on an aged (>7d) override"
  echo "  row values: >7d persistence guardrail proven (fresh passes, aged fires) ✓"
  ;;
registry-cr)
  # Registry CRs validate against frozen fleet-owned slices. Application and
  # ApplicationSet use hand-reduced, pinned Argo CD v3.4.5 schemas.
  # registry/clusters is ABSENT while the v1 serving roster is unratified (its
  # emptiness IS the encoded refusal), so it is included only when it exists —
  # host-pool's live ENTEI row will populate it.
  live_targets=(registry/landscapes registry/virtual-landscapes
    registry/fleet-root.yaml registry/argocd-webhook-secret.yaml
    registry/platforms-appset.yaml)
  [ -d registry/clusters ] && live_targets+=(registry/clusters)
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${live_targets[@]}"

  # Deterministic negative: Applications may not declare an empty source URL.
  cp registry/fleet-root.yaml "${tmp}/invalid-application.yaml"
  yq -i '.spec.source.repoURL = ""' "${tmp}/invalid-application.yaml"
  if kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${tmp}/invalid-application.yaml" >/dev/null 2>&1; then
    fail "Application schema accepted an empty source repoURL"
  fi
  # Topology FIXTURES are schema-valid too — that is the whole point of proving
  # a shape rather than a value. They are validated here and excluded from the
  # live-set assertions in `registry-manifest`.
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    registry/fixtures/landscapes registry/fixtures/clusters \
    registry/fixtures/negative/entei-traffic-true.yaml \
    registry/fixtures/negative/second-infrastructure-landscape.yaml \
    registry/fixtures/negative/second-infrastructure-cluster.yaml

  echo "  registry CRs + topology fixtures validate against frozen schemas; invalid Application source is rejected ✓"
  ;;
registry-manifest)
  # ---------------------------------------------------------------------------
  # The ratified registry roster, asserted mechanically (goals/fleet.md DoD:
  # "asserted by a registry-manifest CI check, not review convention").
  #
  # SCOPE NOTE: canonical-spelling checks run over SEMANTIC FIELDS AND PATHS
  # only — never over comment prose. Several files legitimately name the stale
  # variant while explaining that it is stale; a gate that banned the string
  # outright would forbid documenting its own rule.
  # ---------------------------------------------------------------------------
  workload=(pichu pikachu raichu ampharos)
  live_landscapes="registry/landscapes"
  live_clusters="registry/clusters"
  live_vlandscapes="registry/virtual-landscapes"

  live_rows_in() {
    [ -d "$1" ] || return 0
    find "$1" -type f -name '*.yaml' | sort
  }

  names_in() {
    # semantic identity of every live CR in a directory: metadata.name
    [ -d "$1" ] || return 0
    find "$1" -type f -name '*.yaml' -print0 | sort -z |
      xargs -0 -r -n1 yq -r '.metadata.name'
  }

  # --- (1) live Landscape set is EXACTLY the four workload rows (+ optional entei)
  actual_landscapes="$(names_in "${live_landscapes}" | sort | tr '\n' ' ' | sed 's/ $//')"
  expected_landscapes="$(printf '%s\n' "${workload[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
  # NOTE: `printf '%s\nentei\n' ${workload}` would REUSE the format per argument
  # and emit `entei` four times. Feed entei as a trailing argument instead.
  expected_with_entei="$(printf '%s\n' "${workload[@]}" entei | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "${actual_landscapes}" != "${expected_landscapes}" ] && [ "${actual_landscapes}" != "${expected_with_entei}" ]; then
    fail "registry/landscapes must contain exactly [${expected_landscapes}] (plus the optional infrastructure-only 'entei' row landed by host-pool) — found [${actual_landscapes}]"
  fi

  # --- (2) the LIVE ENTEI pair is mutually exclusive: no ENTEI Landscape
  # permits no cluster rows; one ENTEI Landscape permits exactly its one
  # authoritative host row. This refuses every serving row until the owner
  # publishes the serving-cluster roster, without guessing any coordinates.
  mapfile -t entei_landscape_rows < <(
    while IFS= read -r manifest; do
      if yq -e '.kind == "Landscape" and .metadata.name == "entei"' "$manifest" >/dev/null 2>&1; then
        printf '%s\n' "$manifest"
      fi
    done < <(live_rows_in "$live_landscapes")
  )
  mapfile -t live_cluster_rows < <(live_rows_in "$live_clusters")

  case "${#entei_landscape_rows[@]}" in
  0)
    [ "${#live_cluster_rows[@]}" -eq 0 ] ||
      fail "no live ENTEI Landscape requires registry/clusters to contain zero live ClusterRegistration rows"
    ;;
  1)
    entei_landscape="${entei_landscape_rows[0]}"
    yq -e '.spec.purpose == "infrastructure-only"' "$entei_landscape" >/dev/null ||
      fail "a live ENTEI Landscape must carry spec.purpose: infrastructure-only"
    [ "${#live_cluster_rows[@]}" -eq 1 ] ||
      fail "one live ENTEI Landscape requires exactly one live ClusterRegistration row"

    entei_cluster="${live_cluster_rows[0]}"
    yq -e '.kind == "ClusterRegistration"' "$entei_cluster" >/dev/null ||
      fail "the single live ENTEI row must be a ClusterRegistration"
    entei_mark="$(yq -r '.spec.mark // ""' "$entei_cluster")"
    [ -n "$entei_mark" ] ||
      fail "the live ENTEI ClusterRegistration must carry a non-empty spec.mark"
    entei_name="entei-$entei_mark"
    # The diagnostic names the literal schema field `${spec.mark}`.
    # shellcheck disable=SC2016
    [ "$(yq -r '.metadata.name // ""' "$entei_cluster")" = "$entei_name" ] ||
      fail 'the live ENTEI ClusterRegistration name must equal entei-${spec.mark}'
    yq -e '.spec.landscape == "entei"' "$entei_cluster" >/dev/null ||
      fail "the live ENTEI ClusterRegistration must set spec.landscape: entei"
    yq -e '.metadata.labels["atomi.cloud/landscape"] == "entei"' "$entei_cluster" >/dev/null ||
      fail "the live ENTEI ClusterRegistration must set label atomi.cloud/landscape: entei"
    yq -e '.spec.hostRole == "anonymous-vcluster-host"' "$entei_cluster" >/dev/null ||
      fail "the live ENTEI ClusterRegistration must set spec.hostRole: anonymous-vcluster-host"
    yq -e '.spec.originMode == "loadbalancer"' "$entei_cluster" >/dev/null ||
      fail "the live ENTEI ClusterRegistration must set spec.originMode: loadbalancer"
    yq -e '.spec.traffic == false' "$entei_cluster" >/dev/null ||
      fail "the live ENTEI ClusterRegistration must set spec.traffic: false"
    ;;
  *)
    fail "registry/landscapes may contain at most one live ENTEI Landscape row"
    ;;
  esac

  # --- (3) forbidden identities: Garden-managed, hosted instance types, retired
  mapfile -t live_manifests < <(
    {
      live_rows_in "$live_landscapes"
      live_rows_in "$live_clusters"
      live_rows_in "$live_vlandscapes"
    } | sort
  )
  live_identities=""
  if [ "${#live_manifests[@]}" -gt 0 ]; then
    live_identities="$(yq eval-all -o=json '.' "${live_manifests[@]}" |
      jq -rs -r '.[] | [(.metadata.name // ""), (.spec.landscape // "")] + (.spec.hosts // []) | .[]')"
  fi
  for forbidden_name in primordial lapras ditto rotom absol eevee castform plusle minun; do
    grep -Fxq "$forbidden_name" <<<"$live_identities" &&
      fail "forbidden identity '$forbidden_name' appears in the live registry — Garden-managed, hosted-instance, and retired identities never get a registry row"
  done

  # --- (4) canonical spelling in SEMANTIC FIELDS and PATHS (never in prose)
  # Compile the semantic fields once, rather than launching yq once per file:
  # this gate runs inside every controlled-negative copy.
  mapfile -d '' -t semantic_manifests < <(
    find "${live_landscapes}" "${live_clusters}" "${live_vlandscapes}" registry/fixtures platforms -type f -name '*.yaml' -print0 2>/dev/null | sort -z
  )
  if [ "${#semantic_manifests[@]}" -gt 0 ] &&
    yq eval-all -o=json '.' "${semantic_manifests[@]}" |
    jq -s -e 'any(.[]; [(.metadata.name // ""), (.spec.landscape // ""), (.metadata.labels["atomi.cloud/landscape"] // "")] + (.spec.hosts // []) | any(. == "amphoros"))' >/dev/null; then
    fail "stale spelling 'amphoros' in a semantic field — the canonical registry spelling is 'ampharos'"
  fi

  while IFS= read -r stale_path; do
    [ -n "${stale_path}" ] && fail "stale spelling 'amphoros' in a committed PATH: ${stale_path}"
  done < <(find registry platforms -depth -name '*amphoros*' 2>/dev/null)

  # --- (5) virtual-landscape envelopes are EXACTLY mew + celebi with exact hosts
  actual_vl="$(names_in "${live_vlandscapes}" | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "${actual_vl}" = "celebi mew" ] ||
    fail "registry/virtual-landscapes must contain exactly [celebi mew] — found [${actual_vl}]"
  # NOTE: mikefarah yq's `==` does not perform deep ARRAY equality (it returns
  # false for equal arrays), so every ordered-list assertion in this file goes
  # through jq. Using yq here would produce a permanently-false check that reads
  # like a passing guard.
  yq -o=json '.spec.hosts' "${live_vlandscapes}/mew.yaml" | jq -e '. == ["raichu","ampharos"]' >/dev/null ||
    fail "mew envelope hosts must be exactly [raichu, ampharos]"
  yq -o=json '.spec.hosts' "${live_vlandscapes}/celebi.yaml" | jq -e '. == ["pikachu"]' >/dev/null ||
    fail "celebi envelope hosts must be exactly [pikachu]"

  # --- (6) placeholder-live-path refusal
  while IFS= read -r manifest; do
    [ -z "${manifest}" ] && continue
    placeholders="$(yq -r '[.. | select(tag == "!!str")] | map(select(test("<[A-Za-z-]+>"))) | join(",")' "${manifest}" 2>/dev/null || true)"
    [ -z "${placeholders}" ] && continue
    fail "placeholder ${placeholders} committed under a LIVE registry path: ${manifest} — placeholders belong in registry/fixtures/ only"
  done < <(find "${live_landscapes}" "${live_clusters}" "${live_vlandscapes}" -type f -name '*.yaml' 2>/dev/null | sort)

  # --- (7) fleet-root must NOT sync the fixtures tree
  include_glob="$(yq -r '.spec.source.directory.include' registry/fleet-root.yaml)"
  case "${include_glob}" in
  *fixtures*) fail "registry/fleet-root.yaml's include glob covers fixtures/ — ArgoCD would APPLY the negative fixtures as real objects" ;;
  esac
  yq -e '.spec.source.directory.include | test("landscapes/\*\.yaml")' registry/fleet-root.yaml >/dev/null ||
    fail "registry/fleet-root.yaml must keep its explicit include allowlist"

  echo "  live roster exact · entei invariant · forbidden identities absent · canonical spelling · envelopes exact · no guessed serving rows · no live-path placeholders · fixtures unsynced ✓"
  ;;
registry-manifest-negative)
  # ---------------------------------------------------------------------------
  # Proves the registry-manifest gate is NON-VACUOUS. Each case copies the live
  # registry into a throwaway tree, plants ONE violation, and requires the gate
  # to reject it. Without this, every assertion above is an untested claim.
  #
  # The baseline is the ruled live registry. Each controlled negative must fail
  # for its OWN mutation, and case 0 proves the unmodified baseline is green.
  # ---------------------------------------------------------------------------
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/validate/fleet.sh"
  base="${tmp}/base"
  mkdir -p "${base}"
  cp -r registry platforms "${base}/"

  run_case() {
    local desc="$1" expect="$2"
    shift 2
    local work="${tmp}/case-$$-${RANDOM}"
    cp -r "${base}" "${work}"
    (cd "${work}" && "$@")
    if (cd "${work}" && bash "${self}" registry-manifest >/dev/null 2>&1); then
      [ "${expect}" = "pass" ] && {
        echo "    ${desc} → gate green ✓"
        return 0
      }
      fail "VACUOUS GATE: '${desc}' was ACCEPTED by registry-manifest"
    else
      [ "${expect}" = "fail" ] && {
        echo "    ${desc} → gate red ✓"
        return 0
      }
      fail "gate rejected the baseline it should accept: ${desc}"
    fi
  }

  # A controlled negative must fail for its own mutation. Requiring the expected
  # diagnostic also proves the exact gate branch fired.
  run_reject() {
    local desc="$1" needle="$2"
    shift 2
    local work="$tmp/case-$$-$RANDOM"
    cp -r "$base" "$work"
    (cd "$work" && "$@")
    local output
    if output="$(cd "$work" && bash "$self" registry-manifest 2>&1)"; then
      fail "VACUOUS GATE: '$desc' was ACCEPTED by registry-manifest"
    fi
    grep -Fq "$needle" <<<"$output" ||
      fail "wrong rejection for '$desc' (expected '$needle'): $output"
    echo "    $desc → expected gate branch red ✓"
  }

  live_entei_landscape() {
    sed 's/<RATIFIED-HOST-REGION>/us-test-1/' registry/fixtures/landscapes/entei.yaml >registry/landscapes/entei.yaml
  }
  live_entei_cluster() {
    mkdir -p registry/clusters
    sed -e 's/<mark>/jade/g' -e 's/<provider>/ratified-provider/g' \
      registry/fixtures/clusters/entei-mark.yaml >registry/clusters/entei-jade.yaml
  }
  live_entei_pair() {
    live_entei_landscape
    live_entei_cluster
  }
  non_entei_host_row() {
    live_entei_cluster
    yq -i '.metadata.name = "suicune-jade" | .metadata.labels["atomi.cloud/landscape"] = "suicune" | .spec.landscape = "suicune"' registry/clusters/entei-jade.yaml
    mv registry/clusters/entei-jade.yaml registry/clusters/suicune-jade.yaml
  }
  wrong_entei_cluster_landscape() {
    live_entei_pair
    yq -i '.spec.landscape = "suicune"' registry/clusters/entei-jade.yaml
  }
  wrong_entei_cluster_label() {
    live_entei_pair
    yq -i '.metadata.labels["atomi.cloud/landscape"] = "suicune"' registry/clusters/entei-jade.yaml
  }
  entei_name_mark_mismatch() {
    live_entei_pair
    yq -i '.metadata.name = "entei-onyx"' registry/clusters/entei-jade.yaml
  }
  second_entei_host_row() {
    live_entei_pair
    cp registry/clusters/entei-jade.yaml registry/clusters/entei-onyx.yaml
    yq -i '.metadata.name = "entei-onyx" | .spec.mark = "onyx"' registry/clusters/entei-onyx.yaml
  }
  entei_missing_origin_mode() {
    live_entei_pair
    yq -i 'del(.spec.originMode)' registry/clusters/entei-jade.yaml
  }
  entei_wrong_origin_mode() {
    live_entei_pair
    yq -i '.spec.originMode = "clusterip"' registry/clusters/entei-jade.yaml
  }
  entei_traffic_true() {
    live_entei_landscape
    mkdir -p registry/clusters
    sed -e 's/<mark>/jade/g' -e 's/<provider>/ratified-provider/g' \
      registry/fixtures/negative/entei-traffic-true.yaml >registry/clusters/entei-jade.yaml
  }
  entei_missing_purpose() {
    live_entei_pair
    yq -i 'del(.spec.purpose)' registry/landscapes/entei.yaml
  }

  run_case "ruled live-registry baseline" pass true
  run_reject "extra live landscape (suicune)" \
    "registry/landscapes must contain exactly" \
    cp registry/fixtures/negative/second-infrastructure-landscape.yaml registry/landscapes/suicune.yaml
  run_reject "Garden-managed lapras identity" \
    "forbidden identity 'lapras'" \
    yq -i '.spec.hosts = ["lapras","ampharos"]' registry/virtual-landscapes/mew.yaml
  run_reject "retired plusle identity" \
    "forbidden identity 'plusle'" \
    yq -i '.spec.hosts = ["raichu","plusle"]' registry/virtual-landscapes/mew.yaml
  run_reject "stale spelling in a semantic field" \
    "stale spelling 'amphoros' in a semantic field" \
    yq -i '.metadata.labels["atomi.cloud/landscape"] = "amphoros"' registry/landscapes/ampharos.yaml
  run_reject "stale spelling in a committed PATH" \
    "stale spelling 'amphoros' in a committed PATH" \
    mv registry/landscapes/ampharos.yaml registry/landscapes/amphoros.yaml
  run_reject "mew envelope host set altered" \
    "mew envelope hosts must be exactly [raichu, ampharos]" \
    yq -i '.spec.hosts = ["raichu"]' registry/virtual-landscapes/mew.yaml
  run_reject "celebi envelope removed" \
    "registry/virtual-landscapes must contain exactly [celebi mew]" \
    rm registry/virtual-landscapes/celebi.yaml
  run_reject "arbitrary non-ENTEI host-role/traffic row" \
    "no live ENTEI Landscape requires registry/clusters to contain zero live ClusterRegistration rows" \
    non_entei_host_row
  run_reject "live ENTEI row with traffic: true" \
    "the live ENTEI ClusterRegistration must set spec.traffic: false" \
    entei_traffic_true
  run_reject "live ENTEI Landscape missing its purpose" \
    "a live ENTEI Landscape must carry spec.purpose: infrastructure-only" \
    entei_missing_purpose
  run_reject "placeholder promoted into a live path" \
    "placeholder <UNRATIFIED-REGION> committed under a LIVE registry path" \
    yq -i '.spec.region = "<UNRATIFIED-REGION>"' registry/landscapes/pichu.yaml
  run_reject "fleet-root taught to sync fixtures" \
    "registry/fleet-root.yaml's include glob covers fixtures/" \
    yq -i '.spec.source.directory.include = "{landscapes/*.yaml,fixtures/**/*.yaml}"' registry/fleet-root.yaml

  # the ONE shape the gate must accept: host-pool's live ENTEI pair under its invariant
  run_case "host-pool lands the live ENTEI pair under its invariant" pass live_entei_pair

  run_reject "ENTEI row with wrong spec.landscape" \
    "the live ENTEI ClusterRegistration must set spec.landscape: entei" \
    wrong_entei_cluster_landscape
  run_reject "ENTEI row with wrong landscape label" \
    "the live ENTEI ClusterRegistration must set label atomi.cloud/landscape: entei" \
    wrong_entei_cluster_label
  # The expected diagnostic names the literal schema field `${spec.mark}`.
  # shellcheck disable=SC2016
  run_reject "ENTEI name and mark mismatch" \
    'the live ENTEI ClusterRegistration name must equal entei-${spec.mark}' \
    entei_name_mark_mismatch
  run_reject "second ENTEI host row" \
    "one live ENTEI Landscape requires exactly one live ClusterRegistration row" \
    second_entei_host_row
  run_reject "Landscape-only ENTEI pair" \
    "one live ENTEI Landscape requires exactly one live ClusterRegistration row" \
    live_entei_landscape
  run_reject "ClusterRegistration-only ENTEI pair" \
    "no live ENTEI Landscape requires registry/clusters to contain zero live ClusterRegistration rows" \
    live_entei_cluster
  run_reject "ENTEI row missing originMode" \
    "the live ENTEI ClusterRegistration must set spec.originMode: loadbalancer" \
    entei_missing_origin_mode
  run_reject "ENTEI row with wrong originMode" \
    "the live ENTEI ClusterRegistration must set spec.originMode: loadbalancer" \
    entei_wrong_origin_mode

  echo "  registry-manifest gate proven non-vacuous across 20 violations + 2 accepted shapes ✓"
  ;;
registry-exclusion)
  # ---------------------------------------------------------------------------
  # The exclusion law keys on purpose/hostRole, NOT on the literal name `entei`.
  # A second, differently named infrastructure-only pair must be excluded
  # IDENTICALLY — this is the only assertion that catches a name-special-cased
  # gate (host-pool §1).
  # ---------------------------------------------------------------------------
  entei_l=registry/fixtures/landscapes/entei.yaml
  second_l=registry/fixtures/negative/second-infrastructure-landscape.yaml
  second_c=registry/fixtures/negative/second-infrastructure-cluster.yaml

  [ "$(yq -r '.metadata.name' "${second_l}")" != "entei" ] ||
    fail "the second infrastructure-only fixture must NOT be named entei — it exists to prove the exclusion is not name-keyed"

  # both infrastructure-only landscapes carry the same discriminator
  for f in "${entei_l}" "${second_l}"; do
    yq -e '.spec.purpose == "infrastructure-only"' "${f}" >/dev/null ||
      fail "${f} must carry spec.purpose: infrastructure-only"
  done
  # both host clusters carry the same role + traffic invariant
  for f in registry/fixtures/clusters/entei-mark.yaml "${second_c}"; do
    yq -e '.spec.hostRole == "anonymous-vcluster-host" and .spec.traffic == false' "${f}" >/dev/null ||
      fail "${f} must carry hostRole: anonymous-vcluster-host and traffic: false"
  done

  # traffic-true negative is schema-VALID but semantically rejected
  kubeconform -strict -summary -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    registry/fixtures/negative/entei-traffic-true.yaml >/dev/null ||
    fail "the traffic-true negative must stay schema-valid, so the rejection proves the INVARIANT rather than the schema"
  yq -e '.spec.traffic == true and .spec.hostRole == "anonymous-vcluster-host"' \
    registry/fixtures/negative/entei-traffic-true.yaml >/dev/null ||
    fail "the traffic-true negative no longer expresses the violation it exists to encode"

  # a platform.yaml declaring an infrastructure-only landscape must be REJECTED
  # by the closed registeredLandscape enum, before any object is rendered.
  if helm template "${release}" "${chart}" --namespace "${namespace}" \
    --values "${services}" --values registry/fixtures/negative/platform-declares-entei.yaml >/dev/null 2>&1; then
    fail "a platform.yaml declaring 'entei' in landscapes:/stages: was RENDERED — the exclusion law is not enforced"
  fi
  # ...and so must one naming the SECOND infrastructure-only landscape, proving
  # the rejection is structural rather than a special case for `entei`.
  cp registry/fixtures/negative/platform-declares-entei.yaml "${tmp}/second-infra-platform.yaml"
  yq -i '(.landscapes[] | select(. == "entei")) = "suicune" | (.stages[] | select(. == "entei")) = "suicune"' "${tmp}/second-infra-platform.yaml"
  if helm template "${release}" "${chart}" --namespace "${namespace}" \
    --values "${services}" --values "${tmp}/second-infra-platform.yaml" >/dev/null 2>&1; then
    fail "a platform.yaml declaring the SECOND infrastructure-only landscape rendered — the exclusion is name-keyed, not purpose-keyed"
  fi

  # canary declares exactly the four workload landscapes, and never entei
  yq -o=json '.landscapes' "${fixture}" | jq -e '. == ["pichu","pikachu","raichu","ampharos"]' >/dev/null ||
    fail "canary must declare exactly the four registered WORKLOAD landscapes"

  echo "  infrastructure-only exclusion keyed on purpose/hostRole (proven with a second, differently named pair) ✓"
  ;;
webhook-secret)
  # Build-time semantic contract for the authenticated GitHub -> ArgoCD
  # refresh path. The secret value never enters git: ESO merges exactly the
  # Infisical-backed webhook.github.secret key into the existing argocd-secret.
  webhook_contract() {
    yq -e '
      .apiVersion == "external-secrets.io/v1" and
      .kind == "ExternalSecret" and
      .metadata.namespace == "argocd" and
      .spec.secretStoreRef.kind == "ClusterSecretStore" and
      .spec.secretStoreRef.name == "infisical" and
      .spec.target.name == "argocd-secret" and
      .spec.target.creationPolicy == "Merge" and
      .spec.target.deletionPolicy == "Retain" and
      (.spec.data | length) == 1 and
      .spec.data[0].secretKey == "webhook.github.secret" and
      .spec.data[0].remoteRef.key == "/argocd/webhook/webhook.github.secret" and
      (.spec | has("dataFrom") | not)
    ' "$1" >/dev/null 2>&1
  }

  webhook=registry/argocd-webhook-secret.yaml
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${webhook}" >/dev/null
  webhook_contract "${webhook}" ||
    fail "ArgoCD webhook ExternalSecret is not the exact Infisical -> argocd-secret merge contract"

  cp "${webhook}" "${tmp}/wrong-key.yaml"
  yq -i '.spec.data[0].secretKey = "webhook.github.wrong"' "${tmp}/wrong-key.yaml"
  if webhook_contract "${tmp}/wrong-key.yaml"; then
    fail "webhook contract accepted a wrong ArgoCD secret key"
  fi

  cp "${webhook}" "${tmp}/wrong-target.yaml"
  yq -i '.spec.target.name = "replacement-secret" | .spec.target.creationPolicy = "Owner"' "${tmp}/wrong-target.yaml"
  if webhook_contract "${tmp}/wrong-target.yaml"; then
    fail "webhook contract accepted replacement of the existing argocd-secret"
  fi

  include="$(yq -r '.spec.source.directory.include' registry/fleet-root.yaml)"
  grep -Fq 'argocd-webhook-secret.yaml' <<<"${include}" ||
    fail "fleet-root does not sync the ArgoCD webhook ExternalSecret"
  echo "  authenticated webhook secret: Infisical -> ESO Merge -> argocd-secret/webhook.github.secret; wrong key/target rejected ✓"
  ;;
rendered-cr)
  # The compiler chart's own diene CRD kinds and rendered ArgoCD
  # ApplicationSets validate against frozen schemas. Project/Stage remain
  # upstream Kargo kinds without a diene slice. Warehouse and ProjectConfig use
  # pinned Kargo v1.9.10 slices; CloudflareDeploy including optional rollout
  # validates against the frozen T3 shape.
  #
  # ProjectConfig is deliberately NOT skipped: it is the CR that actually gates
  # promotion, and `gate: manual` is realized as the ABSENCE of an enabling
  # policy — a distinction an unvalidated render could lose silently.
  render >"${tmp}/r.yaml"
  yq eval-all -o=json 'select(.kind == "ApplicationSet")' "${tmp}/r.yaml" >"${tmp}/applicationset.json"
  jq -e '
    .spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions == [{
      key:"atomi.cloud/cluster-role", operator:"NotIn", values:["infrastructure-only"]
    }]
  ' "${tmp}/applicationset.json" >/dev/null ||
    fail "rendered ApplicationSet lost the exact infrastructure-only cluster-role exclusion"
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    -skip Project,Stage \
    "${tmp}/r.yaml"
  # Schema negative: keep the exact selector path but make `values` a scalar.
  # Requiring the field-specific diagnostic proves this fails in the frozen
  # matchExpressions slice, not in an unrelated part of the ApplicationSet.
  jq '.spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions[0].values = "infrastructure-only"' \
    "${tmp}/applicationset.json" >"${tmp}/invalid-match-expressions.json"
  if kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${tmp}/invalid-match-expressions.json" >"${tmp}/invalid-match-expressions.log" 2>&1; then
    fail "ApplicationSet schema accepted scalar matchExpressions values"
  fi
  rg -q 'matchExpressions.*values|values.*matchExpressions' "${tmp}/invalid-match-expressions.log" ||
    fail "malformed matchExpressions was rejected without its field-specific schema diagnostic"
  rg -qi 'array' "${tmp}/invalid-match-expressions.log" ||
    fail "malformed matchExpressions diagnostic did not require values to be an array"
  # Deterministic negative: fleet ApplicationSets require Go templating for
  # generator variables and the templatePatch row guard.
  yq eval-all 'select(.kind == "ApplicationSet")' "${tmp}/r.yaml" >"${tmp}/invalid-applicationset.yaml"
  yq -i '.spec.goTemplate = false' "${tmp}/invalid-applicationset.yaml"
  if kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${tmp}/invalid-applicationset.yaml" >/dev/null 2>&1; then
    fail "ApplicationSet schema accepted goTemplate=false"
  fi
  echo "  rendered ApplicationSet selector validates exactly; malformed matchExpressions and goTemplate=false are rejected ✓"
  ;;
cloudflare-rollout-negative)
  render >"${tmp}/r.yaml"
  yq eval-all 'select(.kind == "CloudflareDeploy")' "${tmp}/r.yaml" >"${tmp}/cloudflaredeploy.yaml"
  kubeconform -strict -summary -schema-location 'schemas/{{ .ResourceKind }}.json' "${tmp}/cloudflaredeploy.yaml" >/dev/null
  yq -i '.spec.rollout.steps[0].percent = 101' "${tmp}/cloudflaredeploy.yaml"
  if kubeconform -strict -summary -schema-location 'schemas/{{ .ResourceKind }}.json' "${tmp}/cloudflaredeploy.yaml" >/dev/null 2>&1; then
    fail "CloudflareDeploy accepted an invalid rollout percentage"
  fi
  echo "  frozen CloudflareDeploy rollout schema accepts canary and rejects invalid rollout ✓"
  ;;
webhookengine-version-negative)
  # A WebhookEngine fixture declaring an engine-version field must be
  # schema-invalid (Q-WH1: no per-platform version; the CF-era
  # desiredVersionFrom:{tag: mercury-stable} render is DEAD).
  cat >"${tmp}/bad-webhookengine.yaml" <<'YAML'
apiVersion: fleet.atomi.cloud/v1alpha1
kind: WebhookEngine
metadata:
  name: mercury
spec:
  home:
    vlandscape: mew
  engineVersion: mercury-stable
YAML
  if kubeconform -strict -summary \
    -schema-location default \
    -schema-location 'schemas/{{ .ResourceKind }}.json' \
    "${tmp}/bad-webhookengine.yaml" >/dev/null 2>&1; then
    fail "WebhookEngine with an engine-version field was ACCEPTED (Q-WH1 guard broken)"
  fi
  echo "  WebhookEngine engine-version field is schema-rejected ✓"
  ;;
appset-scope)
  render >"${tmp}/r.yaml"
  as() { yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s '.[] | select(.kind=="ApplicationSet")'; }
  # ArgoCD spike facts encoded as config, not just docs.
  # matrix generator (git-files × cluster label selector).
  as | jq -e '.spec.generators | any(.[]; has("matrix"))' >/dev/null ||
    fail "AppSet must carry the matrix (git-files × clusters) generator"
  # Generated names, OCI paths, selectors, and destinations consume explicit
  # row fields. path-derived values appear only in templatePatch validation.
  as | jq -e '.spec.generators[0].git.template.metadata.name == "{{ .platform }}-{{ .landscape }}-{{ .service }}-primordial"' >/dev/null ||
    fail "g1 name must consume explicit row fields"
  as | jq -e '.spec.generators[0].git.template.spec.sources[0].repoURL == "oci://registry.atomi.cloud/{{ .platform }}-{{ .service }}-primordial"' >/dev/null ||
    fail "g1 OCI path must consume explicit row fields"
  as | jq -e '.spec.generators[0].git.template.spec.destination.namespace == "{{ .platform }}"' >/dev/null ||
    fail "g1 destination namespace must consume explicit row platform"
  as | jq -e '.spec.generators[1].matrix.template.metadata.name == "{{ .platform }}-{{ .landscape }}-{{ .service }}-{{ .name }}"' >/dev/null ||
    fail "g2 name must consume explicit row fields"
  as | jq -e '.spec.generators[1].matrix.generators[1].clusters.selector.matchLabels["'"${prefix}"'/landscape"] == "{{ .landscape }}"' >/dev/null ||
    fail "g2 selector must consume explicit row landscape"
  as | jq -e '.spec.generators[1].matrix.generators[1].clusters.selector.matchExpressions == [{key:"'"${prefix}"'/cluster-role",operator:"NotIn",values:["infrastructure-only"]}]' >/dev/null ||
    fail "g2 selector must exclude infrastructure-only cluster-role Secrets"
  as | jq -e '.spec.generators[1].matrix.template.spec.sources[0].repoURL == "oci://registry.atomi.cloud/{{ .platform }}-{{ .service }}"' >/dev/null ||
    fail "g2 OCI path must consume explicit row fields"
  expected_values='{{ get . "values" | default dict | toRawJson }}'
  as | jq -e --arg expected "${expected_values}" '
    .spec.generators[0].git.template.spec.sources[0].helm.values == $expected and
    .spec.generators[1].matrix.template.spec.sources[0].helm.values == $expected
  ' >/dev/null ||
    fail "g1/g2 must access optional row values with get under missingkey=error"
  as | jq -e '.spec.templatePatch | contains("ne .platform \"canary\"") and contains("has .service") and contains("ne .service $filenameService") and contains("ne .landscape $pathLandscape")' >/dev/null ||
    fail "AppSet templatePatch must validate row fields against roster/path/filename"
  as | jq -e '[.. | strings | select(test("path\\.segments|path\\.filename"))] | length == 1' >/dev/null ||
    fail "path-derived identity leaked outside the row-validation templatePatch"
  echo "  AppSet g1/g2 uses explicit row identity, excludes infrastructure-only Secrets, and keeps fail-before-render path/roster guards ✓"
  ;;
platforms-appset)
  # The committed platforms AppSet: SCM-provider generator over *.carbon,
  # three-source Application, machinery-stable pin with canary-on-main split,
  # canary auto-sync disabled via templatePatch.
  f=registry/platforms-appset.yaml
  yq -e '.spec.generators[0].scmProvider.github.organization=="AtomiCloud"' "${f}" >/dev/null ||
    fail "platforms AppSet must use an SCM-provider generator over the AtomiCloud org"
  yq -e '.spec.generators[0].scmProvider.filters[0].repositoryMatch=="\\.carbon$"' "${f}" >/dev/null ||
    fail "platforms AppSet must filter to *.carbon repos"
  yq -e '[.spec.template.spec.sources[] | .ref] | contains(["carbon","services"])' "${f}" >/dev/null ||
    fail "platforms AppSet must declare three sources (chart + carbon + services refs)"
  yq -e '.spec.template.spec.sources[0].targetRevision | test("canary.carbon.*main.*machinery-stable")' "${f}" >/dev/null ||
    fail "platforms AppSet source A must pin machinery-stable with the canary-on-main split"
  yq -e '
    .spec.template.spec.sources[0].repoURL == "https://github.com/AtomiCloud/fleet" and
    .spec.template.spec.sources[2].repoURL == "https://github.com:443/AtomiCloud/fleet" and
    .spec.template.spec.sources[2].targetRevision == "HEAD" and
    .spec.template.spec.sources[2].ref == "services" and
    .spec.template.spec.sources[0].repoURL != .spec.template.spec.sources[2].repoURL
  ' "${f}" >/dev/null ||
    fail "platforms AppSet must keep the HEAD services ref on its distinct explicit-443 Git identity"
  patch="$(yq -r '.spec.templatePatch' "${f}")"
  { echo "${patch}" | grep -q 'ne .repository "canary.carbon"' && echo "${patch}" | grep -q 'automated'; } ||
    fail "platforms AppSet must disable auto-sync for canary via templatePatch"
  echo "  platforms AppSet: scmProvider *.carbon + 3-source + distinct HEAD roster identity + machinery-stable/main split + canary manual-sync ✓"
  ;;
golden-mutation | golden-mutations)
  # Behavioural mutation sensitivity. Starting from the canary baseline render,
  # every accepted one-at-a-time change to a major source-B machinery section
  # MUST alter the rendered output. These are valid mutations (helm still
  # renders them), not malformed-schema negatives — they prove the golden render
  # actually consumes each section rather than dropping it on the floor.
  render >"${tmp}/base.yaml"
  mut() {
    local label="$1" expr="$2"
    cp "${fixture}" "${tmp}/m.yaml"
    yq -i "${expr}" "${tmp}/m.yaml"
    helm template "${release}" "${chart}" --namespace "${namespace}" \
      --values "${services}" --values "${tmp}/m.yaml" >"${tmp}/m.out" 2>"${tmp}/m.err" ||
      fail "mutation '${label}' was rejected — expected a valid accepted mutation: $(tail -1 "${tmp}/m.err")"
    cmp -s "${tmp}/base.yaml" "${tmp}/m.out" &&
      fail "mutation '${label}' left the rendered output unchanged (section not wired into the render)"
    echo "  ${label} → render changed ✓"
  }
  mut "platform/Infisical identity (projectSlug)" '.infisical.projectSlug = "canary-alt"'
  mut "platform/Infisical identity (sos.register)" '.sos.register = false'
  mut "stages (rendezvous soak)" '.stages[2].soak = "30m"'
  mut "dependencies.database (neon representative)" '.dependencies.database.maindb.cpu = 2'
  mut "dependencies.kv (upstash representative)" '.dependencies.kv.sessions.ram = "256Mi"'
  mut "dependencies.cache (dragonfly representative)" '.dependencies.cache.hot.ram = "256Mi"'
  mut "dependencies.store (tigris representative)" '.dependencies.store.assets.rotation = "off"'
  mut "virtualLandscapeServices" '.virtualLandscapeServices[0].serve = false'
  mut "webhookEngine" '.webhookEngine.retryWindow = "48h"'
  mut "cloudflareDeploy" '.cloudflareDeploy[0].tag = "0.2.0"'
  mut "problems" '.problems[0].entries[0].status = 400'
  echo "  every major source-B machinery section is render-sensitive to a valid mutation ✓"
  ;;
row-expansion)
  # Deterministic AppSet contract tier, not a live Argo reconciliation trace.
  # The temporary fixture begins with a committed row, adds a second service,
  # and supplies Secret-shaped cluster-generator inputs to prove row isolation.
  render >"${tmp}/r.yaml"
  yq eval-all -o=json 'select(.kind=="ApplicationSet")' "${tmp}/r.yaml" >"${tmp}/appset.json"
  bun ./scripts/validate/fleet-row-expansion.ts platforms "${tmp}/appset.json" ||
    fail "row-scoped AppSet expansion violated the row-isolation contract"
  ;;
machinery-pin | machinery-stable)
  # Deterministic contract tier (no live cluster/tag mutation). A throwaway local
  # git repo models the compiler chart (source A of the platforms Application).
  # Using the REAL committed revision split, canary (pinned main) observes a
  # main-only commit while a machinery-stable consumer stays on the old commit
  # until the tag moves — proven with git rev-parse in the throwaway repo only.
  f=registry/platforms-appset.yaml
  rev="$(yq -r '.spec.template.spec.sources[0].targetRevision' "${f}")"
  canary_ref="$(sed -E 's/.*canary\.carbon" *\}\}([^{]*)\{\{ *else.*/\1/' <<<"${rev}")"
  other_ref="$(sed -E 's/.*else *\}\}([^{]*)\{\{ *end.*/\1/' <<<"${rev}")"
  [ "${canary_ref}" = "main" ] ||
    fail "committed split must pin canary to main (got '${canary_ref}')"
  [ "${other_ref}" = "machinery-stable" ] ||
    fail "committed split must pin non-canary to machinery-stable (got '${other_ref}')"

  repo="${tmp}/compiler"
  mkdir -p "${repo}"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email fleet-test@atomi.cloud
  git -C "${repo}" config user.name fleet-test
  printf 'compiler v1\n' >"${repo}/compiler"
  git -C "${repo}" add -A && git -C "${repo}" commit -qm 'compiler v1'
  old="$(git -C "${repo}" rev-parse HEAD)"
  git -C "${repo}" tag machinery-stable
  printf 'compiler v2\n' >"${repo}/compiler"
  git -C "${repo}" add -A && git -C "${repo}" commit -qm 'compiler v2 (main-only)'
  new="$(git -C "${repo}" rev-parse HEAD)"

  resolve() { git -C "${repo}" rev-parse "$1^{commit}"; }
  [ "${old}" != "${new}" ] || fail "test setup produced identical commits"
  [ "$(resolve "${canary_ref}")" = "${new}" ] ||
    fail "canary (main) did not observe the new main-only compiler commit"
  [ "$(resolve "${other_ref}")" = "${old}" ] ||
    fail "machinery-stable consumer did not stay on the old commit before the tag moved"
  git -C "${repo}" tag -f machinery-stable >/dev/null
  [ "$(resolve "${other_ref}")" = "${new}" ] ||
    fail "machinery-stable consumer did not catch up after the tag moved"

  # Manual-sync contract from the committed AppSet: canary base template carries
  # no automated block; the templatePatch enables automated only for non-canary.
  yq -e '.spec.template.spec.syncPolicy.automated == null' "${f}" >/dev/null ||
    fail "platforms AppSet base template must leave canary manual (no automated block)"
  patch="$(yq -r '.spec.templatePatch' "${f}")"
  { grep -q 'ne .repository "canary.carbon"' <<<"${patch}" && grep -q 'automated' <<<"${patch}"; } ||
    fail "platforms AppSet templatePatch must enable automated sync only for non-canary"
  echo "  main/machinery-stable split observes main-only change, catches up on tag move, canary-manual/non-canary-auto ✓"
  ;;
kargo-row-update-contract | kargo-row-update | kargo-yaml-update-contract)
  # Fast deterministic contract model — NOT Kargo-controller e2e evidence.
  # Check the fixed configured yaml-update target against a copied real row,
  # then prove the model leaves the raw human values: block unchanged.
  render >"${tmp}/r.yaml"
  row="platforms/canary/landscapes/raichu/dummy.yaml"
  stages="$(yq eval-all -o=json '.' "${tmp}/r.yaml" | jq -s '[.[] | select(.kind=="Stage")]')"
  jq -e '
    length > 0 and
    all(.[];
      ([.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update")] | length == 1) and
      ([.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.updates] |
        (length == 1) and (.[0] | type == "array" and length == 1 and .[0].key == "pin.tag"))
    )
  ' <<<"${stages}" >/dev/null ||
    fail "every rendered Stage must configure exactly one yaml-update with only pin.tag"
  update="$(jq -c --arg path "./repo/${row}" '
    [.[] | select(
      [.spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config.path] == [$path]
    )] | if length == 1 then .[0].spec.promotionTemplate.spec.steps[] | select(.uses=="yaml-update") | .config else empty end
  ' <<<"${stages}")"
  [ -n "${update}" ] || fail "exactly one Stage must target the copied Raichu row ${row}"
  key="$(jq -r '.updates[0].key' <<<"${update}")"
  [ "${key}" = "pin.tag" ] || fail "Raichu Stage yaml-update key must be pin.tag"
  yq -e 'has("values")' "${row}" >/dev/null ||
    fail "expected the raichu row to carry a human values: block"
  values_block() { awk '/^values:/{f=1} f' "$1"; }
  values_block "${row}" >"${tmp}/values.before"

  cp "${row}" "${tmp}/row.yaml"
  old_tag="$(yq -r '.pin.tag' "${tmp}/row.yaml")"
  bun ./scripts/validate/fleet-yaml-update.ts "${tmp}/row.yaml" "${key}" 0.9.9-canary ||
    fail "fast yaml-update contract model failed on the configured pin.tag target"
  new_tag="$(yq -r '.pin.tag' "${tmp}/row.yaml")"
  { [ "${new_tag}" = "0.9.9-canary" ] && [ "${new_tag}" != "${old_tag}" ]; } ||
    fail "pin.tag was not updated (${old_tag} -> ${new_tag})"
  values_block "${tmp}/row.yaml" >"${tmp}/values.after"
  cmp -s "${tmp}/values.before" "${tmp}/values.after" ||
    fail "values: block changed during a pin.tag-only update (must be byte-identical)"

  # Negative: the raw-block guard must detect a values: mutation.
  cp "${row}" "${tmp}/bad.yaml"
  bun ./scripts/validate/fleet-yaml-update.ts "${tmp}/bad.yaml" values.workload.replicas 99 ||
    fail "fast yaml-update contract model failed to seed the values: negative"
  values_block "${tmp}/bad.yaml" >"${tmp}/values.bad"
  cmp -s "${tmp}/values.before" "${tmp}/values.bad" &&
    fail "byte-identical guard failed to detect a mutated values: block"
  if bun ./scripts/validate/fleet-yaml-update.ts "${tmp}/bad.yaml" missing.path value >/dev/null 2>&1; then
    fail "fast yaml-update contract model accepted a missing update path"
  fi
  echo "  fast yaml-update contract model: exact Raichu pin.tag target, raw values bytes, and negatives ✓"
  ;;
sit-namespace-lifecycle | sit-proof-lifecycle)
  proof_source="${PWD}/scripts/ci/fleet-sit-proof.sh"
  sit_source="${PWD}/scripts/ci/fleet-sit.sh"
  pins_source="${PWD}/scripts/validate/fleet-sit/pins.env"
  for source_file in "${proof_source}" "${sit_source}" "${pins_source}"; do
    test -s "${source_file}" || fail "Namespace lifecycle source is missing: ${source_file}"
  done

  # Production source law. Historical failed-wrapper fixtures below may name
  # the old substrate; no executable production byte may do so.
  if rg -n 'k3d cluster create|k3d kubeconfig|host\.k3d\.internal|docker exec' \
    "${proof_source}" "${sit_source}"; then
    fail 'the production fleet proof retains a nested-cluster or node-exec path'
  fi
  if rg -n 'k3s[[:space:]]+ctr|images[[:space:]]+export|containerd.*export' \
    "${proof_source}" "${sit_source}"; then
    fail 'the production fleet proof introduced a forbidden containerd export path'
  fi
  rg -qF '/vendor/containerd/ctr --address /var/run/containerd/containerd.sock' \
    "${sit_source}" || fail 'the production platform containerd socket is not explicit'
  rg -qF -- '--namespace k8s.io "$@"' "${sit_source}" ||
    fail 'the production platform containerd namespace is not explicit'
  rg -qF 'k3s crictl "$@"' "${sit_source}" ||
    fail 'the production CRI seam no longer uses built-in k3s crictl'
  rg -qF '[ "${observed_k3s}" = "${NSC_K3S_VERSION}" ]' "${sit_source}" ||
    fail 'the inner preflight no longer refuses a drifted k3s version'
  rg -qF '[ "$(hostname)" = "${namespace_instance_id}" ]' "${sit_source}" ||
    fail 'the inner preflight no longer binds hostname to exact instance id'
  rg -qF "NSC_INSTANCE_ID_PATTERN='^[a-z0-9]{13}$'" "${pins_source}" ||
    fail 'the Namespace instance-id pin is not the observed exact 13-character contract'
  # The second live g15 run exposed Wolfi's intentional Git package split:
  # `git` supplies the client, while `git-daemon` owns git-http-backend. The
  # smart-HTTP L0 server therefore needs an executable-based package probe, not
  # another `command -v git` test.
  rg -qF 'NSC_GIT_HTTP_BACKEND_PACKAGE=git-daemon' "${pins_source}" ||
    fail 'the Wolfi Git smart-HTTP backend package pin is not git-daemon'
  rg -qF 'NSC_GIT_HTTP_BACKEND_CANONICAL=/usr/libexec/git-core/git-http-backend' "${pins_source}" ||
    fail 'the Wolfi Git smart-HTTP backend executable pin changed'
  rg -qF '[ -x "${NSC_GIT_HTTP_BACKEND_CANONICAL}" ] ||' "${sit_source}" ||
    fail 'Namespace preparation no longer probes the Git smart-HTTP backend executable'
  rg -qF 'packages+=("${NSC_GIT_HTTP_BACKEND_PACKAGE}")' "${sit_source}" ||
    fail 'Namespace preparation no longer installs the pinned Git smart-HTTP backend package'
  rg -qF 'namespace_git_http_backend_record' "${sit_source}" ||
    fail 'Namespace platform evidence no longer records the Git smart-HTTP backend owner'
  rg -qF 'expected_prefix="${canonical} is owned by ${package}-"' "${sit_source}" ||
    fail 'APK-owned tool evidence no longer binds canonical path to exact package family'
  nsl_git_backend_prepare="${tmp}/namespace-git-backend-prepare.sh"
  sed -n '/^namespace_prepare_tools() {$/,/^}$/p' "${sit_source}" >"${nsl_git_backend_prepare}"
  [ "$(tail -n 1 "${nsl_git_backend_prepare}")" = '}' ] ||
    fail 'the Namespace tool-preparation body is unterminated'
  nsl_git_backend_probe_line="$(rg -n -F '[ -x "${NSC_GIT_HTTP_BACKEND_CANONICAL}" ] ||' "${nsl_git_backend_prepare}" | head -n 1 | cut -d: -f1)"
  nsl_git_backend_install_line="$(rg -n -F 'packages+=("${NSC_GIT_HTTP_BACKEND_PACKAGE}")' "${nsl_git_backend_prepare}" | head -n 1 | cut -d: -f1)"
  nsl_git_backend_apk_line="$(rg -n -F 'apk add --no-cache "${packages[@]}"' "${nsl_git_backend_prepare}" | head -n 1 | cut -d: -f1)"
  [ -n "${nsl_git_backend_probe_line}" ] &&
    [ -n "${nsl_git_backend_install_line}" ] &&
    [ -n "${nsl_git_backend_apk_line}" ] &&
    [ "${nsl_git_backend_probe_line}" -lt "${nsl_git_backend_install_line}" ] &&
    [ "${nsl_git_backend_install_line}" -lt "${nsl_git_backend_apk_line}" ] ||
    fail 'the Git smart-HTTP backend probe/install sequence no longer precedes APK installation'
  echo '    Wolfi Git smart-HTTP backend: executable probe installs pinned git-daemon and records exact APK ownership ✓'
  # The first live g15 run reached L0 and exposed a Wolfi/BusyBox portability
  # defect: GNU sed's `0,/pattern/` address is not accepted by the substrate's
  # sed applet. Exercise the exact shipped helper, then prove the structural
  # gate rejects a reintroduced first-match sed command.
  nsl_schema_relaxation_is_portable() {
    local source="$1" body="${tmp}/schema-relaxation-body.sh"
    sed -n '/^relax_fleet_repo_url_schema() {$/,/^}$/p' "${source}" >"${body}"
    [ "$(tail -n 1 "${body}")" = '}' ] || return 1
    rg -qF 'jq --indent 4' "${body}" &&
      rg -qF '.properties.fleet.properties.repoURL.pattern = "^https?://"' "${body}" &&
      rg -qF '"${schema}" >"${schema}.next" || return 1' "${body}" &&
      rg -qF 'mv -- "${schema}.next" "${schema}"' "${body}" &&
      ! rg -q '^[[:space:]]*sed[[:space:]]+-i[[:space:]]+.*0,' "${body}"
  }
  nsl_schema_relaxation_is_portable "${sit_source}" ||
    fail 'the runtime fleet.repoURL schema correction is not the reviewed portable helper'
  nsl_schema_before="${tmp}/schema-relaxation-before.json"
  nsl_schema_after="${tmp}/schema-relaxation-after.json"
  cp registry/charts/diene-platform/values.schema.json "${nsl_schema_before}"
  cp "${nsl_schema_before}" "${nsl_schema_after}"
  nsl_schema_fn="${tmp}/schema-relaxation-function.sh"
  sed -n '/^relax_fleet_repo_url_schema() {$/,/^}$/p' "${sit_source}" >"${nsl_schema_fn}"
  (
    # shellcheck source=/dev/null
    source "${nsl_schema_fn}"
    relax_fleet_repo_url_schema "${nsl_schema_after}"
  ) || fail 'the shipped portable schema correction failed against the real schema'
  jq -e '
    .properties.fleet.properties.repoURL.pattern == "^https?://" and
    .properties.primordial.properties.server.pattern == "^https://"
  ' "${nsl_schema_after}" >/dev/null ||
    fail 'the portable schema correction changed the wrong contract'
  diff -u "${nsl_schema_before}" "${nsl_schema_after}" \
    >"${tmp}/schema-relaxation.diff" || true
  [ "$(rg -c '^[+-] *"pattern"' "${tmp}/schema-relaxation.diff")" -eq 2 ] ||
    fail 'the portable schema correction changed more than one pattern value'
  nsl_schema_busybox_old="${tmp}/schema-relaxation-busybox-old.json"
  cp "${nsl_schema_before}" "${nsl_schema_busybox_old}"
  busybox sed -i '0,/"pattern": "\^https:\/\/"/s//"pattern": "^https?:\/\/"/' \
    "${nsl_schema_busybox_old}" ||
    fail 'the BusyBox first-match regression fixture did not execute'
  cmp -s "${nsl_schema_before}" "${nsl_schema_busybox_old}" ||
    fail 'the BusyBox first-match regression fixture no longer reproduces the silent no-op'
  nsl_schema_mutant="${tmp}/schema-relaxation-mutant.sh"
  awk '
    { print }
    /^relax_fleet_repo_url_schema\(\) \{$/ {
      print "  sed -i 0, \"${schema}\""
    }
  ' "${sit_source}" >"${nsl_schema_mutant}"
  ! cmp -s "${nsl_schema_mutant}" "${sit_source}" ||
    fail 'the nonportable schema-rewrite mutant changed no bytes'
  if nsl_schema_relaxation_is_portable "${nsl_schema_mutant}"; then
    fail 'the portability gate accepted a reintroduced first-match sed command'
  fi
  echo '    L0 schema relaxation: BusyBox reproduces the silent first-match no-op; shipped jq changes one field; mutation gate refuses reintroduction ✓'
  # Structural pins for the created-instance recovery seam. The behavioural
  # regressions below are the real gate; these refuse a silent reversion to a
  # first-nonempty-surface chain or a dropped cidfile check outright.
  rg -qF 'for recovery_surface in cidfile receipt stdout; do' "${proof_source}" ||
    fail 'created-instance recovery no longer tries the cidfile, receipt, and stdout surfaces independently'
  rg -qF 'validate_create_cidfile' "${proof_source}" ||
    fail 'the harness no longer validates the generated cidfile against the pinned instance id'
  mapfile -t nsl_production_ssh_calls < <(
    rg -n '^[[:space:]]+nsc ssh[[:space:]]' "${proof_source}"
  )
  [ "${#nsl_production_ssh_calls[@]}" -eq 4 ] ||
    fail 'the production Namespace wrapper must carry exactly four explicit nsc ssh calls'
  for nsl_production_ssh_call in "${nsl_production_ssh_calls[@]}"; do
    if [[ ${nsl_production_ssh_call} != *"nsc ssh --disable-pty \"\${instance_id}\" -- "* ]]; then
      fail "the production Namespace ssh call lacks the nsc v0.0.532 remote-command separator: ${nsl_production_ssh_call}"
    fi
  done
  # nsc v0.0.532 InlineSsh joins the post-separator argv with single spaces, so
  # a remote program holding spaces or quotes must be exactly one argument. The
  # behavioural packing regressions below are the real gate; these refuse a
  # silent reversion to the split `sh -eu -c <program>` form outright.
  # shellcheck disable=SC2016
  rg -qF -- '-- "${setup_command}"' "${proof_source}" ||
    fail 'the production snapshot-setup program is not packed as one remote argument'
  # shellcheck disable=SC2016
  rg -qF -- '-- "${archive_command}"' "${proof_source}" ||
    fail 'the production report-archive program is not packed as one remote argument'
  if rg -n -- '--[[:space:]]+sh[[:space:]]' "${proof_source}"; then
    fail 'a production Namespace ssh call reintroduced a nested remote shell that the nsc join would split'
  fi

  # ---------------------------------------------------------------------
  # SESSION-HANG lane source law.
  #
  # The generation-13 live attempt emitted correct hostname bytes and then the
  # nsc ssh client failed to terminate. The pre-repair preflight carried no
  # timeout and no closed stdin, so it hung unboundedly. These pins refuse a
  # reversion to that shape and pin the lane that replaced it. The behavioural
  # matrix further down is the real gate; every pin here is additionally proven
  # non-vacuous by a mutant that must go red.
  # ---------------------------------------------------------------------

  # EVERY production ssh call must be bounded and stdin-closed, not just the
  # hostname preflight: an unbounded setup or report-archive call hangs the proof
  # exactly as the hostname call did. One bound per call site, each with its own
  # reviewed pin, and one `</dev/null` per site.
  # Asserted PER CALL SITE rather than by a raw count: a count would be
  # satisfied by five timeouts anywhere in the file, including five on one call
  # and none on another. Each `nsc ssh` line must have its own `timeout` opener
  # within the preceding four lines (the opener, the kill-after, the duration,
  # then the call), and its own `</dev/null` somewhere in the REST OF ITS OWN
  # logical command. The scan runs to the end of the backslash continuation
  # rather than a fixed window, because the inner run carries several
  # environment-assignment lines between the call and its redirects.
  # Defined as a function so the gate self-tests further down can run THE SAME
  # scanner against deliberately broken copies. A self-test that re-implemented
  # this logic could pass while the real gate was vacuous.
  nsl_ssh_bound_scan() {
    awk '
      /^[[:space:]]+timeout --verbose --signal=TERM \\$/ { last_timeout = NR }
      /^[[:space:]]+nsc ssh[[:space:]]/ {
        sites++
        if (last_timeout == 0 || NR - last_timeout > 4) unbounded = unbounded " " NR
        pending[NR] = 1
        pending_line = NR
        if ($0 !~ /\\$/) pending_line = 0
        next
      }
      pending_line {
        if (index($0, "</dev/null") > 0) { closed[pending_line] = 1; pending_line = 0 }
        else if ($0 !~ /\\$/) pending_line = 0
      }
      END {
        for (n in pending) if (!(n in closed)) open_stdin = open_stdin " " n
        printf "%d|%s|%s", sites, unbounded, open_stdin
      }
    ' "$1"
  }
  # Refuses when any ssh site is unbounded or leaves stdin open. Used by the
  # gate self-tests; the real gate below reports the offending line numbers.
  nsl_ssh_bounds_ok() {
    local report
    report="$(nsl_ssh_bound_scan "$1")"
    [ "$(printf '%s' "${report}" | cut -d'|' -f2)" = '' ] &&
      [ "$(printf '%s' "${report}" | cut -d'|' -f3)" = '' ]
  }
  nsl_ssh_bound_report="$(nsl_ssh_bound_scan "${proof_source}")"
  nsl_ssh_sites="${nsl_ssh_bound_report%%|*}"
  nsl_ssh_unbounded="$(printf '%s' "${nsl_ssh_bound_report}" | cut -d'|' -f2)"
  nsl_ssh_open_stdin="$(printf '%s' "${nsl_ssh_bound_report}" | cut -d'|' -f3)"
  [ "${nsl_ssh_sites}" -eq 4 ] ||
    fail "the production wrapper must carry exactly four nsc ssh call sites, found ${nsl_ssh_sites}"
  [ -z "${nsl_ssh_unbounded}" ] ||
    fail "a production ssh call site is not preceded by its own explicit hard timeout, at line(s):${nsl_ssh_unbounded}"
  [ -z "${nsl_ssh_open_stdin}" ] ||
    fail "a production ssh call site does not close stdin against an interactive session, at line(s):${nsl_ssh_open_stdin}"
  # The liveness/list client call is bounded too, and is the fifth and last
  # timeout site. Nothing else in the wrapper may acquire one silently.
  nsl_timeout_sites="$(rg -c -- '^[[:space:]]+timeout --verbose --signal=TERM \\$' "${proof_source}" || true)"
  [ "${nsl_timeout_sites}" -eq 5 ] ||
    fail "the wrapper must bound exactly the four ssh calls and the list call, found ${nsl_timeout_sites} timeout sites"
  for nsl_ssh_bound in \
    NSC_SESSION_HANG_PER_CALL_TIMEOUT_SECONDS \
    NSC_SSH_SETUP_TIMEOUT_SECONDS \
    NSC_SSH_INNER_TIMEOUT_SECONDS \
    NSC_SSH_REPORT_ARCHIVE_TIMEOUT_SECONDS; do
    rg -qF "\${${nsl_ssh_bound}}s" "${proof_source}" ||
      fail "a production ssh call site is not bounded by its reviewed pin ${nsl_ssh_bound}"
  done

  rg -qF 'enter_session_hang_lane' "${proof_source}" ||
    fail 'the wrapper has no same-live-instance SESSION-HANG lane'
  rg -qF 'session_hang_outcome=' "${proof_source}" ||
    fail 'the SESSION-HANG lane records no closed outcome'
  rg -qF 'instance_present_and_reviewed_in' "${proof_source}" ||
    fail 'liveness re-proof does not reuse the reviewed live-row predicate'
  rg -qF 'consumesInstanceOrdinal:false' "${proof_source}" ||
    fail 'the SESSION-HANG receipt no longer denies instance-ordinal consumption'
  # The liveness probe must stay TRI-state. A boolean would map every list
  # failure onto "instance lost", which is exactly the ordinal-consuming claim
  # ruling item 7 forbids uncertainty from manufacturing.
  rg -qF 'probe_instance_liveness' "${proof_source}" ||
    fail 'liveness is no longer a distinct probe'
  rg -qF 'instance_present_in' "${proof_source}" ||
    fail 'present-but-drifted liveness is no longer separable from proven absence'
  rg -qF 'liveness-unproven' "${proof_source}" ||
    fail 'liveness uncertainty no longer has its own terminal class'
  rg -qF 'close_lane_terminally' "${proof_source}" ||
    fail 'the lane has no outcome-branching terminal close'

  # The terminal close must branch on the CLOSED OUTCOME, never on the lane's
  # bare return status: the lane returns 1 for a closed session lane, for proven
  # instance loss, and for unproven liveness, and those are three different
  # terminal classes that must not collapse onto one signature.
  nsl_close_body="${tmp}/close-lane-terminally.sh"
  sed -n '/^close_lane_terminally() {$/,/^}$/p' "${proof_source}" >"${nsl_close_body}"
  [ "$(tail -n 1 "${nsl_close_body}")" = '}' ] ||
    fail 'the terminal close body is unterminated'
  for nsl_terminal_stage in \
    session-hang-exhausted session-hang-instance-lost session-hang-liveness-unproven; do
    rg -qF "failure_stage='${nsl_terminal_stage}'" "${nsl_close_body}" ||
      fail "the terminal close does not classify ${nsl_terminal_stage}"
  done
  for nsl_terminal_status in \
    NSC_SESSION_HANG_EXHAUSTED_STATUS NSC_INSTANCE_LOST_STATUS NSC_LIVENESS_UNPROVEN_STATUS; do
    rg -qF "${nsl_terminal_status}" "${nsl_close_body}" ||
      fail "the terminal close does not emit the reserved ${nsl_terminal_status}"
  done
  # Cleanup must be ATTEMPTED before the process leaves the lane, or a terminal
  # lane close leaks the instance.
  rg -qF 'destroy_instance_and_prove_absent' "${nsl_close_body}" ||
    fail 'the terminal close does not destroy the instance and prove absence'
  # The receipt must NOT be written here. The reserved terminals defer their one
  # receipt to the EXIT cleanup, which retries cleanup first and therefore writes
  # cleanup booleans that are facts rather than a pre-cleanup snapshot. A receipt
  # written inside this function would permanently record the first attempt.
  if rg -qF 'write_lifecycle_report' "${nsl_close_body}"; then
    fail 'the terminal close writes its own receipt, so a retried cleanup can never be reflected in it'
  fi
  # ...and the EXIT cleanup must be the writer, and must preserve the reserved
  # status. If a snapshot or cleanup failure could rewrite rc, the external
  # driver would read an ordinary refusal where a reserved terminal occurred.
  nsl_cleanup_body="${tmp}/cleanup-body.sh"
  sed -n '/^cleanup() {$/,/^}$/p' "${proof_source}" >"${nsl_cleanup_body}"
  [ "$(tail -n 1 "${nsl_cleanup_body}")" = '}' ] ||
    fail 'the cleanup body is unterminated'
  rg -qF 'write_lifecycle_report' "${nsl_cleanup_body}" ||
    fail 'the EXIT cleanup does not write the reserved-terminal receipt'
  rg -qF 'preserve_reserved_terminal' "${nsl_cleanup_body}" ||
    fail 'the EXIT cleanup does not preserve the reserved terminal status'
  rg -qF 'rc="${reserved_terminal_status}"' "${nsl_cleanup_body}" ||
    fail 'the EXIT cleanup does not adopt the reserved terminal status as its exit code'

  # The liveness call must itself be bounded: it is a client call against the
  # same client that just failed to terminate, so nothing may assume it cannot
  # hang. The reviewed non-TTY redirect form must survive the rewrite verbatim.
  rg -qF 'nsc list --output json </dev/null >"${raw}" 2>"${output}.stderr"' "${proof_source}" ||
    fail 'the production Namespace list path lost its non-TTY redirect form'
  rg -qF 'NSC_LIST_TIMEOUT_SECONDS' "${proof_source}" ||
    fail 'the Namespace list path is not bounded by an explicit hard timeout'

  # Byte-exactness of the hostname predicate. The replaced production line used
  # `tr -d '[:space:]'`, which accepts leading, trailing and internal whitespace
  # and accepts multiple lines — any of which could let padded stdout "prove"
  # reachability, which is precisely the claim this lane escalates on.
  # shellcheck disable=SC2016
  rg -qF -- '. == $id or . == ($id + "\n")' "${proof_source}" ||
    fail 'the hostname predicate is no longer byte-exact'
  if rg -n -- "tr -d '\[:space:\]'" "${proof_source}"; then
    fail 'the hostname predicate reverted to the whitespace-stripping form that accepts padded or multi-line stdout'
  fi

  # The lane must never create, destroy or mint a second instance: the wrapper
  # owns exactly one instance for its whole life, and a lane outcome is not an
  # instance event.
  nsl_lane_body="${tmp}/session-hang-lane.sh"
  sed -n '/^enter_session_hang_lane() {$/,/^}$/p' "${proof_source}" >"${nsl_lane_body}"
  [ "$(tail -n 1 "${nsl_lane_body}")" = '}' ] ||
    fail 'the SESSION-HANG lane body is unterminated'
  if rg -n 'nsc create|nsc destroy' "${nsl_lane_body}"; then
    fail 'the SESSION-HANG lane reached an instance lifecycle mutation'
  fi

  # The bounds are reviewed pins, recomputed here rather than trusted.
  rg -qF 'NSC_SESSION_HANG_MAX_REINVOCATIONS=3' "${pins_source}" ||
    fail 'the ratified three-re-invocation SESSION-HANG bound is not pinned'
  rg -qF 'NSC_SESSION_HANG_PER_CALL_TIMEOUT_SECONDS=60' "${pins_source}" ||
    fail 'the ratified 60-second per-call SESSION-HANG bound is not pinned'
  rg -qF 'NSC_SESSION_HANG_LANE_BUDGET_SECONDS=300' "${pins_source}" ||
    fail 'the ratified five-minute SESSION-HANG lane budget is not pinned'
  rg -qF 'NSC_LIST_TIMEOUT_SECONDS=20' "${pins_source}" ||
    fail 'the bounded liveness-proof timeout is not pinned'
  rg -qF 'NSC_LIST_KILL_AFTER_SECONDS=5' "${pins_source}" ||
    fail 'the bounded liveness-proof kill allowance is not pinned'
  for nsl_terminal_pin in \
    'NSC_SESSION_HANG_EXHAUSTED_STATUS=75' \
    'NSC_INSTANCE_LOST_STATUS=76' \
    'NSC_LIVENESS_UNPROVEN_STATUS=77'; do
    rg -qF "${nsl_terminal_pin}" "${pins_source}" ||
      fail "the reserved terminal status pin is missing or drifted: ${nsl_terminal_pin}"
  done

  # The lane begins AFTER the initial readiness call, so that call is not
  # charged. Each of the MAX_REINVOCATIONS iterations pays for one bounded
  # liveness proof PLUS one bounded ssh call; charging the ssh calls alone would
  # ignore all three liveness calls and understate the worst case.
  # With the ratified pins: 3 * ((20 + 5) + (60 + 10)) = 3 * 95 = 285 <= 300.
  (
    # shellcheck source=/dev/null
    . "${pins_source}"
    nsl_worst=$((NSC_SESSION_HANG_MAX_REINVOCATIONS * ((\
      NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS) + (\
      NSC_SESSION_HANG_PER_CALL_TIMEOUT_SECONDS + NSC_SESSION_HANG_KILL_AFTER_SECONDS))))
    [ "${nsl_worst}" -eq 285 ] &&
      [ "${nsl_worst}" -le "${NSC_SESSION_HANG_LANE_BUDGET_SECONDS}" ]
  ) ||
    fail 'the pinned SESSION-HANG per-iteration budget is not the ratified 3 x 95 = 285 within 300'
  # The structural formula and the wrapper's runtime formula must agree, or this
  # gate could accept pins the wrapper itself refuses, or worse, the reverse.
  #
  # SCOPED to the extracted validate_session_hang_bounds body on purpose. Both
  # of these substrings also occur in enter_session_hang_lane and in a comment,
  # so a whole-file scan would stay green even if the bounds check itself were
  # rewritten to charge the ssh calls alone — which is exactly the defect this
  # pin exists to catch.
  nsl_bounds_body="${tmp}/validate-session-hang-bounds.sh"
  sed -n '/^validate_session_hang_bounds() {$/,/^}$/p' "${proof_source}" >"${nsl_bounds_body}"
  [ "$(tail -n 1 "${nsl_bounds_body}")" = '}' ] ||
    fail 'the session-hang bounds validator body is unterminated'
  rg -qF 'NSC_SESSION_HANG_MAX_REINVOCATIONS *' "${nsl_bounds_body}" ||
    fail 'the wrapper no longer recomputes its worst case from MAX_REINVOCATIONS'
  rg -qF 'NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS' "${nsl_bounds_body}" ||
    fail 'the wrapper worst case no longer charges the bounded liveness proofs'
  echo '    SESSION-HANG lane source law: four bounded stdin-closed ssh sites, tri-state liveness, three distinct reserved terminals, deferred receipt, 3 x 95 = 285 <= 300 ✓'
  # Stock Wolfi exposes every core utility through BusyBox. The ratified guest
  # bootstrap installs the measured GNU package set as the FIRST setup action,
  # before extracting or running any climb script. Tar is the explicit
  # exception: Wolfi has no GNU tar package, so its BusyBox-compatible short
  # options remain mandatory.
  rg -qF "NSC_GNU_BOOTSTRAP_PACKAGES='coreutils findutils sed grep gawk'" "${pins_source}" ||
    fail 'the exact measured GNU guest-bootstrap package set is not pinned'
  rg -qF '[ "${NSC_GNU_BOOTSTRAP_PACKAGES}" = '\''coreutils findutils sed grep gawk'\'' ] ||' \
    "${proof_source}" ||
    fail 'the outer wrapper does not fail closed on a drifted GNU bootstrap pin'
  rg -qF 'namespace_apk_owned_tool_receipt "${gnu_path}" "${gnu_package}"' "${sit_source}" ||
    fail 'the inner preflight no longer proves GNU command ownership before the climb'
  # shellcheck disable=SC2016 # source-code literals intentionally retain $().
  for nsl_gnu_owner in \
    'awk "$(command -v awk)" gawk' \
    'find "$(command -v find)" findutils' \
    'grep "$(command -v grep)" grep' \
    'sed "$(command -v sed)" sed' \
    'sha256sum "$(command -v sha256sum)" coreutils' \
    'timeout "$(command -v timeout)" coreutils'; do
    rg -qF "namespace_apk_owned_tool_record ${nsl_gnu_owner}" "${sit_source}" ||
      fail "Namespace platform evidence no longer records GNU ownership: ${nsl_gnu_owner}"
  done
  mapfile -t nsl_setup_program_lines < <(rg -N '^  setup_command=' "${proof_source}")
  [ "${#nsl_setup_program_lines[@]}" -eq 1 ] ||
    fail 'the production wrapper must define exactly one remote setup program'
  nsl_setup_program_line="${nsl_setup_program_lines[0]}"
  # shellcheck disable=SC2016 # match the literal guest-side variable reference.
  case "${nsl_setup_program_line}" in
  '  setup_command="apk add --no-cache ${NSC_GNU_BOOTSTRAP_PACKAGES} && '*)
    ;;
  *) fail 'the GNU toolchain install is not the first remote setup action' ;;
  esac
  case "${nsl_setup_program_line}" in
  *'| sha256sum --check"') ;;
  *) fail 'the remote setup checksum does not prove GNU coreutils was installed first' ;;
  esac
  # The remote extraction must decline restored ownership, using BusyBox's
  # documented short flag. `tar -o -xzf` does not contain the substring
  # `tar -xzf`, so refusing that substring refuses exactly the bare form. The
  # GNU long spellings are absent from BusyBox's usage table and are refused
  # here for the same reason `sha256sum --check` was.
  case "${nsl_setup_program_line}" in
  *'tar -o -xzf'*) ;;
  *) fail 'the remote source extraction is not the ownership-neutral BusyBox tar -o -xzf form' ;;
  esac
  case "${nsl_setup_program_line}" in
  *'tar -xzf'*)
    fail 'the remote source extraction reverted to the bare tar -xzf that restores the archive owner'
    ;;
  esac
  case "${nsl_setup_program_line}" in
  *'--no-same-owner'* | *'--no-same-permissions'*)
    fail 'the remote source extraction used a GNU-only long ownership flag that BusyBox tar does not document'
    ;;
  esac
  # The setup program must prove the extracted tree is a usable checkout at the
  # stage that owns the transfer, not leave it to fail opaquely at inner-run.
  case "${nsl_setup_program_line}" in
  *'rev-parse --git-dir'*) ;;
  *) fail 'the remote setup program does not prove the transferred tree is a git checkout' ;;
  esac
  # The predicate must precede the checksum, or the packed program stops ending
  # in the trailing token every other pin and the fake client rely on.
  case "${nsl_setup_program_line}" in
  *'rev-parse --git-dir'*'| sha256sum --check"') ;;
  *) fail 'the remote git predicate must run before the trailing checksum' ;;
  esac
  # R1: the wrapper must keep git's own diagnosis rather than discard it.
  if rg -qF -- 'rev-parse --git-dir >/dev/null 2>&1' "${proof_source}"; then
    fail 'the checkout preflight still discards the git diagnostic that made the g11 inner failure undiagnosable'
  fi
  # Process substitution needs an openable /dev/fd. The instance shell does not
  # reliably provide one — the generation-11 run at product 22bf742 died on
  # `/dev/fd/63: No such file or directory` — so neither shipped script may use
  # it anywhere. Scoped to the two files that execute on the instance: this
  # validator runs only on the CI host and is deliberately not covered.
  for nsl_instance_script in "${proof_source}" "${sit_source}"; do
    if rg -n -- '<\(|>\(' "${nsl_instance_script}"; then
      fail "process substitution is not portable to the instance shell: ${nsl_instance_script}"
    fi
  done
  # Pin the replacement shape, so the refusal above cannot be satisfied by a
  # line-oriented or pipeline rewrite that loses NUL safety or fail-closed
  # status.
  rg -qF -- 'ls-tree -r -z' "${proof_source}" ||
    fail 'the wrapper direct-input enumeration is no longer NUL-delimited'
  rg -qF -- 'ls-tree -r -z' "${sit_source}" ||
    fail 'the SIT direct-input enumeration is no longer NUL-delimited'
  rg -qF -- "read -r -d ''" "${proof_source}" ||
    fail 'the wrapper direct-input loop no longer parses NUL-delimited records'
  rg -qF -- "read -r -d ''" "${sit_source}" ||
    fail 'the SIT direct-input loop no longer parses NUL-delimited records'
  rg -qF -- 'could not enumerate the direct-input roots' "${proof_source}" ||
    fail 'the wrapper direct-input producer is no longer status-checked'
  rg -qF -- 'could not enumerate the direct-input roots' "${sit_source}" ||
    fail 'the SIT direct-input producer is no longer status-checked'
  # The harness log must still reach both the log file and the caller, via the
  # FIFO lifecycle rather than a plain append.
  rg -qF -- 'mkfifo -m 600' "${sit_source}" ||
    fail 'the harness log no longer uses a named FIFO'
  rg -qF -- 'finish_harness_log' "${sit_source}" ||
    fail 'the harness log has no finalizer'
  rg -qF -- 'start_harness_log' "${sit_source}" ||
    fail 'the harness log has no guarded setup'
  rg -qF -- 'mkfifo nproc sed sha256sum tar tee timeout tr' "${sit_source}" ||
    fail 'the SIT bootstrap preflight no longer requires mkfifo and tee before the harness log is armed'
  if rg -n "script -q.*nsc list|nsc list.*script -q" "${proof_source}"; then
    fail 'the production Namespace list path still allocates a pseudo-terminal'
  fi
  rg -qF 'nsc list --output json </dev/null >"${raw}" 2>"${output}.stderr"' \
    "${proof_source}" ||
    fail 'the production Namespace list path is not the direct non-TTY client interface'
  rg -qF 'for command in bash date git iconv jq nsc sha256sum tar timeout; do' \
    "${proof_source}" ||
    fail 'the production Namespace outer preflight does not require iconv'
  rg -qF 'iconv -f UTF-8 -t UTF-8 "${raw}" >/dev/null' "${proof_source}" ||
    fail 'the production Namespace list path has no checked raw UTF-8 boundary'
  # BusyBox applets are trigger-created aliases, so the receipt binds both PATH
  # and the applet inode to one reviewed canonical executable, then attributes
  # that exact path to the exact busybox package. No list-only or alias-query
  # substitute answers that file-to-package claim.
  rg -qF 'NSC_BUSYBOX_PACKAGE=busybox' "${pins_source}" ||
    fail 'the Namespace BusyBox package pin is not the reviewed literal busybox'
  rg -qF 'NSC_BUSYBOX_CANONICAL=/usr/bin/busybox' "${pins_source}" ||
    fail 'the Namespace BusyBox canonical-path pin is not /usr/bin/busybox'
  rg -qF '[ "${NSC_BUSYBOX_PACKAGE}" = '\''busybox'\'' ] &&' "${sit_source}" ||
    fail 'the inner input gate no longer validates the exact BusyBox package pin'
  rg -qF '[ "${NSC_BUSYBOX_CANONICAL}" = '\''/usr/bin/busybox'\'' ] ||' "${sit_source}" ||
    fail 'the inner input gate no longer validates the exact BusyBox canonical-path pin'
  nsl_wolfi_production="${tmp}/namespace-wolfi-production.sh"
  sed -n '/^namespace_wolfi_tool_receipt() {$/,/^}$/p' "${sit_source}" \
    >"${nsl_wolfi_production}"
  [ "$(tail -n 1 "${nsl_wolfi_production}")" = '}' ] ||
    fail 'the production Wolfi BusyBox receipt is unterminated'
  rg -qF 'apk info --who-owns "${NSC_BUSYBOX_CANONICAL}"' "${nsl_wolfi_production}" ||
    fail 'Wolfi BusyBox receipts no longer query exact canonical package ownership'
  if rg -n -- '--who-owns "\$\{(path|busybox_path)\}"' "${nsl_wolfi_production}"; then
    fail 'a Wolfi BusyBox receipt reverted to an unowned applet or PATH-alias ownership query'
  fi
  if rg -n -- 'apk[[:space:]]+(--from[[:space:]]+installed[[:space:]]+)?info[[:space:]]+(-L|-v|-e)|apk[[:space:]]+list[[:space:]]+--installed|namespace_first_line_receipt[[:space:]]+apk[[:space:]]+(info|list)' \
    "${nsl_wolfi_production}"; then
    fail 'the canonical BusyBox success path added a prohibited manifest, list-only, or merged-stream APK receipt'
  fi
  rg -qF 'busybox_path="$(command -v busybox 2>/dev/null || true)"' "${sit_source}" ||
    fail 'the Wolfi applet receipt no longer resolves busybox from PATH fail-closed'
  rg -qF 'busybox is not on PATH for the applet ownership receipt' "${sit_source}" ||
    fail 'the Wolfi applet receipt no longer refuses a missing busybox binary'
  rg -qF '[ "${busybox_path}" -ef "${NSC_BUSYBOX_CANONICAL}" ] ||' "${sit_source}" ||
    fail 'the Wolfi receipt no longer binds PATH BusyBox to the canonical binary by file identity'
  rg -qF '[ "${path}" -ef "${NSC_BUSYBOX_CANONICAL}" ] ||' "${sit_source}" ||
    fail 'the Wolfi receipt no longer binds the applet to canonical BusyBox by file identity'
  rg -qF 'PATH busybox is not the canonical busybox binary: ${busybox_path} vs ${NSC_BUSYBOX_CANONICAL}' \
    "${sit_source}" || fail 'the PATH-shadow refusal no longer names both BusyBox paths'
  rg -qF 'applet is not the canonical busybox binary: ${path} vs ${NSC_BUSYBOX_CANONICAL}' \
    "${sit_source}" || fail 'the applet identity refusal no longer names both paths'
  rg -qF '2>"${apk_stderr_file}" || apk_status=$?' "${sit_source}" ||
    fail 'the canonical APK ownership query no longer preserves stderr and status separately'
  rg -qF 'mapfile -t owner_rows <"${apk_stdout_file}"' "${sit_source}" ||
    fail 'the canonical APK ownership query no longer validates complete stdout rows'
  rg -qF '[ "${owner_name}" = "${NSC_BUSYBOX_PACKAGE}" ] ||' "${sit_source}" ||
    fail 'the canonical APK owner token is no longer parsed to an exact package name'
  mapfile -t nsl_apk_record_lines < <(rg -n '^[[:space:]]+namespace_tool_record apk ' "${sit_source}")
  [ "${#nsl_apk_record_lines[@]}" -eq 1 ] ||
    fail 'the Namespace APK platform receipt must be recorded exactly once'
  rg -qF 'apk_version="$(namespace_first_line_receipt apk --version)" || return 1' "${sit_source}" ||
    fail 'the Namespace APK version is no longer captured from one checked probe'
  rg -qF 'printf '\''Namespace apk version: %s\n'\'' "${apk_version}"' "${sit_source}" ||
    fail 'the Namespace APK version is no longer observable before BusyBox receipts'
  rg -qF 'namespace_tool_record apk "${apk_path}" "${apk_version}"' "${sit_source}" ||
    fail 'the checked Namespace APK probe is no longer the recorded APK row'
  if rg -qF 'namespace_tool_command_record apk' "${sit_source}"; then
    fail 'the Namespace platform capture reintroduced a duplicate APK version probe'
  fi
  # The failing receipt command's own words are the only thing that separates an
  # unowned path from an unsupported ownership invocation. R1 of g11c made the
  # same repair for the git checkout predicate.
  rg -qF 'sit_fail "tool receipt command failed: $*: ${output}"' "${sit_source}" ||
    fail 'the tool receipt failure diagnostic discards the failing command output again'
  if rg -n '(sha256sum|tar|timeout)[[:space:]]+--version' "${sit_source}"; then
    fail 'a Wolfi BusyBox applet receipt reverted to a non-portable GNU --version probe'
  fi
  rg -qF 'apk awk bash busybox curl docker git gzip head jq kubectl mkfifo nproc sed sha256sum tar tee timeout tr' \
    "${sit_source}" || fail 'the Namespace bootstrap gate no longer requires nproc and busybox before use'
  rg -qF 'sit_require_command "${bootstrap}"' "${sit_source}" ||
    fail 'the Namespace bootstrap command gate disappeared'
  rg -qF "'namespace-platform.json' 'pins-verified.txt'" "${sit_source}" ||
    fail 'the L0 evidence declaration omits the platform/toolchain preflight'

  # Run the production receipt helpers, not a transcription. A command
  # substitution used directly as an outer function argument can mask its
  # non-zero status in Bash, so both empty-success and partial-output/failure
  # probes are positive-controlled refusals here.
  nsl_tool_fns="${tmp}/namespace-tool-receipt-fns.sh"
  : >"${nsl_tool_fns}"
  for nsl_tool_fn in \
    namespace_tool_record \
    namespace_first_line_receipt \
    namespace_tool_command_record; do
    sed -n "/^${nsl_tool_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/nsl-tool-fn.sh"
    test -s "${tmp}/nsl-tool-fn.sh" ||
      fail "could not extract ${nsl_tool_fn}() for the Namespace receipt refusal test"
    [ "$(tail -n 1 "${tmp}/nsl-tool-fn.sh")" = '}' ] ||
      fail "the extracted ${nsl_tool_fn}() receipt helper is unterminated"
    cat "${tmp}/nsl-tool-fn.sh" >>"${nsl_tool_fns}"
  done
  cat >"${tmp}/namespace-tool-receipt-driver.sh" <<'NSL_TOOL_RECEIPT_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
work="$2"
mkdir -p "${work}"

sit_fail() {
  printf 'fixture refusal: %s\n' "$*" >&2
  return 1
}

# shellcheck source=/dev/null
source "${fn_file}"

receipt_ok() { printf 'version 1.2.3\nignored second line\n'; }
receipt_empty() { :; }
receipt_partial_failure() { printf 'misleading partial version\n'; return 23; }

namespace_tool_command_record good /fixture/tool receipt_ok
if namespace_tool_command_record empty /fixture/tool receipt_empty 2>/dev/null; then
  echo 'empty version receipt was accepted' >&2
  exit 31
fi
if namespace_tool_command_record partial /fixture/tool receipt_partial_failure 2>/dev/null; then
  echo 'non-zero version probe with partial output was accepted' >&2
  exit 32
fi
if namespace_tool_record direct-empty /fixture/tool '' 2>/dev/null; then
  echo 'direct empty version receipt was accepted' >&2
  exit 33
fi
[ "$(wc -l <"${work}/namespace-tools.tsv" | tr -d ' ')" -eq 1 ]
grep -qxF $'good\t/fixture/tool\tversion 1.2.3' "${work}/namespace-tools.tsv"
NSL_TOOL_RECEIPT_DRIVER
  bash "${tmp}/namespace-tool-receipt-driver.sh" \
    "${nsl_tool_fns}" "${tmp}/namespace-tool-receipt-work" ||
    fail 'Namespace tool-version receipts did not fail closed'

  # BusyBox applet ownership receipts, again as extracted production bytes
  # rather than a transcription, driven against real symlink and hardlink
  # fixtures and a PATH-first fake busybox plus fake apk. The fake apk answers
  # only for the busybox binary, which is exactly the asymmetry the repair
  # depends on. The same driver is the shared acceptance predicate for the
  # unmutated baseline and for both isolated mutants, and each assertion has a
  # distinct exit status and witness line, so a mutant that dies of exit 127, a
  # syntax error, a missing fixture or an unrelated assertion cannot be
  # mistaken for a mutation that was genuinely caught.
  nsl_wolfi_fns="${tmp}/namespace-wolfi-receipt-fns.sh"
  : >"${nsl_wolfi_fns}"
  for nsl_wolfi_fn in \
    namespace_tool_record \
    namespace_wolfi_tool_receipt \
    namespace_wolfi_tool_record; do
    sed -n "/^${nsl_wolfi_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/nsl-wolfi-fn.sh"
    test -s "${tmp}/nsl-wolfi-fn.sh" ||
      fail "could not extract ${nsl_wolfi_fn}() for the BusyBox applet ownership test"
    [ "$(tail -n 1 "${tmp}/nsl-wolfi-fn.sh")" = '}' ] ||
      fail "the extracted ${nsl_wolfi_fn}() applet helper is unterminated"
    cat "${tmp}/nsl-wolfi-fn.sh" >>"${nsl_wolfi_fns}"
  done
  cat >"${tmp}/namespace-wolfi-receipt-driver.sh" <<'NSL_WOLFI_RECEIPT_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
work="$2"
rm -rf "${work}"
mkdir -p "${work}"

sit_fail() {
  printf 'fixture refusal: %s\n' "$*" >&2
  return 1
}

nsl_die() {
  printf 'NSL-WOLFI-ASSERTION-FAILED: %s\n' "$2" >&2
  exit "$1"
}

# shellcheck source=/dev/null
source "${fn_file}"

apk_bin="${work}/apkbin"
bb_bin="${work}/bbbin"
shadow_bin="${work}/shadowbin"
applets="${work}/applets"
mkdir -p "${apk_bin}" "${bb_bin}" "${shadow_bin}" "${applets}"

printf '#!/bin/sh\nexit 0\n' >"${bb_bin}/busybox"
chmod 755 "${bb_bin}/busybox"
NSC_BUSYBOX_PACKAGE=busybox
NSC_BUSYBOX_CANONICAL="${bb_bin}/busybox"
NSL_CANONICAL="${NSC_BUSYBOX_CANONICAL}"
export NSC_BUSYBOX_PACKAGE NSC_BUSYBOX_CANONICAL NSL_CANONICAL

# Faithfully reproduce the live asymmetry: only the canonical packaged path has
# an owner. Modes isolate every stdout, stderr, row-shape and owner-token edge.
cat >"${apk_bin}/apk" <<'NSL_FAKE_APK'
#!/bin/sh
if [ "$#" -ne 3 ] || [ "$1" != info ] || [ "$2" != --who-owns ]; then
  echo "apk fixture rejects unexpected invocation: $*" >&2
  exit 64
fi
if [ "$3" != "${NSL_CANONICAL}" ]; then
  echo "ERROR: $3: could not find owner package" >&2
  exit 1
fi
case "${NSL_APK_MODE:-owned}" in
owned)
  echo "${NSL_CANONICAL} is owned by busybox-1.37.0-r59"
  ;;
nonzero)
  echo "partial canonical owner stdout"
  echo "apk fixture nonzero stderr" >&2
  exit 23
  ;;
empty)
  :
  ;;
multiline)
  echo "${NSL_CANONICAL} is owned by busybox-1.37.0-r59"
  echo "${NSL_CANONICAL} is owned by busybox-1.37.0-r60"
  ;;
stderr)
  echo "${NSL_CANONICAL} is owned by busybox-1.37.0-r59"
  echo "apk fixture warning stderr" >&2
  ;;
wrong-path)
  echo "/wrong/canonical/busybox is owned by busybox-1.37.0-r59"
  ;;
wrong-static)
  echo "${NSL_CANONICAL} is owned by busybox-static-1.37.0-r59"
  ;;
wrong-extras)
  echo "${NSL_CANONICAL} is owned by busybox-extras-1.37.0-r59"
  ;;
malformed)
  echo "${NSL_CANONICAL} is owned by busybox-1.37.0"
  ;;
whitespace)
  echo "${NSL_CANONICAL} is owned by busybox 1.37.0-r59"
  ;;
*)
  echo "apk fixture rejects unknown mode: ${NSL_APK_MODE}" >&2
  exit 65
  ;;
esac
NSL_FAKE_APK
chmod 755 "${apk_bin}/apk"

nsl_outer_path="${PATH}"
PATH="${apk_bin}:${bb_bin}:${nsl_outer_path}"
export PATH

# Real inode relationships, not simulated ones.
ln -s "${bb_bin}/busybox" "${applets}/gzip"
ln "${bb_bin}/busybox" "${applets}/sha256sum"
printf '#!/bin/sh\nexit 0\n' >"${applets}/tar"
chmod 755 "${applets}/tar"
cp "${bb_bin}/busybox" "${applets}/busybox-copy"
chmod 755 "${applets}/busybox-copy"
ln -s "${applets}/no-such-busybox" "${applets}/dangling"
cp "${bb_bin}/busybox" "${shadow_bin}/busybox"
chmod 755 "${shadow_bin}/busybox"
printf '#!/bin/sh\nexit 0\n' >"${work}/nonexec-busybox"
chmod 644 "${work}/nonexec-busybox"

owned_line="${NSC_BUSYBOX_CANONICAL} is owned by busybox-1.37.0-r59"

# 1. The canonical executable succeeds and records its exact original path.
namespace_wolfi_tool_record busybox "${NSC_BUSYBOX_CANONICAL}" 2>"${work}/t1.err" ||
  nsl_die 41 canonical-busybox-success
grep -qxF "$(printf 'busybox\t%s\t%s' "${NSC_BUSYBOX_CANONICAL}" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 41 canonical-busybox-evidence

# 2. A symlinked applet succeeds and keeps the applet path in evidence.
namespace_wolfi_tool_record gzip "${applets}/gzip" 2>"${work}/t1.err" ||
  nsl_die 42 symlink-applet-success
grep -qxF "$(printf 'gzip\t%s\t%s' "${applets}/gzip" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 42 symlink-applet-evidence

# 3. A hardlinked applet succeeds. This is the case a basename guard got wrong.
namespace_wolfi_tool_record sha256sum "${applets}/sha256sum" 2>"${work}/t2.err" ||
  nsl_die 43 hardlink-applet-success
grep -qxF "$(printf 'sha256sum\t%s\t%s' "${applets}/sha256sum" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 43 hardlink-applet-evidence

# 4. An unrelated executable is refused, naming applet and canonical paths.
if namespace_wolfi_tool_record tar "${applets}/tar" 2>"${work}/t3.err"; then
  nsl_die 44 unrelated-regular-file-refusal
fi
grep -qF "applet is not the canonical busybox binary: ${applets}/tar vs ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t3.err" ||
  nsl_die 44 unrelated-regular-file-refusal-message

# 5. Byte-identical content is insufficient without inode identity.
if namespace_wolfi_tool_record copy "${applets}/busybox-copy" 2>"${work}/t5.err"; then
  nsl_die 45 byte-identical-copy-refusal
fi
grep -qF "applet is not the canonical busybox binary: ${applets}/busybox-copy vs ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t5.err" ||
  nsl_die 45 byte-identical-copy-refusal-message

# 6. A dangling applet link is refused rather than resolved.
if namespace_wolfi_tool_record dangling "${applets}/dangling" 2>"${work}/t6.err"; then
  nsl_die 46 dangling-applet-refusal
fi
grep -qF "applet is not the canonical busybox binary: ${applets}/dangling vs ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t6.err" ||
  nsl_die 46 dangling-applet-refusal-message

# 7. Missing PATH BusyBox refuses before APK is consulted.
if PATH="${apk_bin}" namespace_wolfi_tool_record gzip-no-busybox "${applets}/gzip" \
  2>"${work}/t7.err"; then
  nsl_die 47 missing-path-busybox-refusal
fi
grep -qF "busybox is not on PATH for the applet ownership receipt: ${applets}/gzip" \
  "${work}/t7.err" ||
  nsl_die 47 missing-path-busybox-refusal-message

# 8. A PATH-shadowed byte-identical BusyBox is not canonical.
if PATH="${shadow_bin}:${apk_bin}:${bb_bin}:${nsl_outer_path}" \
  namespace_wolfi_tool_record gzip-shadow "${applets}/gzip" 2>"${work}/t8.err"; then
  nsl_die 48 path-shadow-refusal
fi
grep -qF "PATH busybox is not the canonical busybox binary: ${shadow_bin}/busybox vs ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t8.err" ||
  nsl_die 48 path-shadow-refusal-message

# 9. A missing canonical executable is refused.
nsl_saved_canonical="${NSC_BUSYBOX_CANONICAL}"
NSC_BUSYBOX_CANONICAL="${work}/missing/busybox"
if namespace_wolfi_tool_record gzip-missing-canonical "${applets}/gzip" 2>"${work}/t9.err"; then
  nsl_die 49 missing-canonical-refusal
fi
grep -qF "canonical busybox pin is not an absolute executable path: ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t9.err" ||
  nsl_die 49 missing-canonical-refusal-message
NSC_BUSYBOX_CANONICAL="${nsl_saved_canonical}"

# 10. A present but non-executable canonical file is refused.
NSC_BUSYBOX_CANONICAL="${work}/nonexec-busybox"
if namespace_wolfi_tool_record gzip-nonexec-canonical "${applets}/gzip" 2>"${work}/t10.err"; then
  nsl_die 50 nonexecutable-canonical-refusal
fi
grep -qF "canonical busybox pin is not an absolute executable path: ${NSC_BUSYBOX_CANONICAL}" \
  "${work}/t10.err" ||
  nsl_die 50 nonexecutable-canonical-refusal-message
NSC_BUSYBOX_CANONICAL="${nsl_saved_canonical}"

# 11. APK nonzero preserves both a partial stdout and its stderr diagnostic.
if NSL_APK_MODE=nonzero namespace_wolfi_tool_record gzip-apk-fail "${applets}/gzip" \
  2>"${work}/t4.err"; then
  nsl_die 51 apk-nonzero-refusal
fi
grep -qF 'canonical busybox ownership query exited 23' "${work}/t4.err" ||
  nsl_die 51 apk-nonzero-refusal-message
grep -qF 'partial canonical owner stdout' "${work}/t4.err" ||
  nsl_die 51 apk-nonzero-stdout-preserved
grep -qF 'apk fixture nonzero stderr' "${work}/t4.err" ||
  nsl_die 51 apk-nonzero-stderr-preserved

# 12. Exit-zero empty stdout is refused.
if NSL_APK_MODE=empty namespace_wolfi_tool_record gzip-apk-empty "${applets}/gzip" \
  2>"${work}/t5.err"; then
  nsl_die 52 apk-empty-stdout-refusal
fi
grep -qF 'canonical busybox ownership query returned empty stdout' "${work}/t5.err" ||
  nsl_die 52 apk-empty-stdout-refusal-message

# 13. Exit-zero multi-row stdout is refused.
if NSL_APK_MODE=multiline namespace_wolfi_tool_record gzip-apk-multiline \
  "${applets}/gzip" 2>"${work}/t13.err"; then
  nsl_die 53 apk-multiline-refusal
fi
grep -qF 'canonical busybox ownership query returned 2 rows' "${work}/t13.err" ||
  nsl_die 53 apk-multiline-refusal-message

# 14. Exit-zero valid stdout plus any stderr warning is refused.
if NSL_APK_MODE=stderr namespace_wolfi_tool_record gzip-apk-stderr \
  "${applets}/gzip" 2>"${work}/t14.err"; then
  nsl_die 54 apk-nonempty-stderr-refusal
fi
grep -qF 'canonical busybox ownership query wrote stderr' "${work}/t14.err" ||
  nsl_die 54 apk-nonempty-stderr-refusal-message
grep -qF 'apk fixture warning stderr' "${work}/t14.err" ||
  nsl_die 54 apk-warning-stderr-preserved

# 15. The returned owner row must name the exact canonical path.
if NSL_APK_MODE=wrong-path namespace_wolfi_tool_record gzip-wrong-path \
  "${applets}/gzip" 2>"${work}/t15.err"; then
  nsl_die 55 wrong-canonical-path-row-refusal
fi
grep -qF 'canonical busybox ownership row has the wrong path or shape' \
  "${work}/t15.err" ||
  nsl_die 55 wrong-canonical-path-row-refusal-message

# 16-17. Prefix-sharing BusyBox families are not the literal package.
if NSL_APK_MODE=wrong-static namespace_wolfi_tool_record gzip-static \
  "${applets}/gzip" 2>"${work}/t16.err"; then
  nsl_die 56 wrong-owner-family-static-refusal
fi
grep -qF 'wrong package family: busybox-static' "${work}/t16.err" ||
  nsl_die 56 wrong-owner-family-static-refusal-message
if NSL_APK_MODE=wrong-extras namespace_wolfi_tool_record gzip-extras \
  "${applets}/gzip" 2>"${work}/t17.err"; then
  nsl_die 57 wrong-owner-family-extras-refusal
fi
grep -qF 'wrong package family: busybox-extras' "${work}/t17.err" ||
  nsl_die 57 wrong-owner-family-extras-refusal-message

# 18-19. Missing release fields and whitespace-bearing tokens are malformed.
if NSL_APK_MODE=malformed namespace_wolfi_tool_record gzip-malformed \
  "${applets}/gzip" 2>"${work}/t18.err"; then
  nsl_die 58 malformed-owner-token-refusal
fi
grep -qF 'malformed release field' "${work}/t18.err" ||
  nsl_die 58 malformed-owner-token-refusal-message
if NSL_APK_MODE=whitespace namespace_wolfi_tool_record gzip-whitespace \
  "${applets}/gzip" 2>"${work}/t19.err"; then
  nsl_die 59 whitespace-owner-token-refusal
fi
grep -qF 'malformed package token' "${work}/t19.err" ||
  nsl_die 59 whitespace-owner-token-refusal-message

# Only the canonical path and two accepted applets may produce evidence rows,
# and every row must retain its caller-supplied original path.
[ "$(wc -l <"${work}/namespace-tools.tsv" | tr -d ' ')" -eq 3 ] ||
  nsl_die 60 accepted-applet-row-count
grep -qxF "$(printf 'busybox\t%s\t%s' "${NSC_BUSYBOX_CANONICAL}" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 60 canonical-original-path
grep -qxF "$(printf 'gzip\t%s\t%s' "${applets}/gzip" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 60 symlink-original-path
grep -qxF "$(printf 'sha256sum\t%s\t%s' "${applets}/sha256sum" "${owned_line}")" \
  "${work}/namespace-tools.tsv" ||
  nsl_die 60 hardlink-original-path
printf 'NSL-WOLFI-BASELINE-PASS: canonical-and-applet-cases\n'
NSL_WOLFI_RECEIPT_DRIVER

  nsl_wolfi_predicate() {
    bash "${tmp}/namespace-wolfi-receipt-driver.sh" \
      "$1" "${tmp}/namespace-wolfi-work-$2" >"${tmp}/nsl-wolfi-$2.out" \
      2>"${tmp}/nsl-wolfi-$2.err"
  }

  # The shared unmutated baseline. Without this passing, a mutant's failure
  # proves nothing at all.
  bash -n "${nsl_wolfi_fns}" ||
    fail 'the extracted BusyBox applet receipt helpers are not valid Bash'
  nsl_wolfi_predicate "${nsl_wolfi_fns}" baseline ||
    fail 'the BusyBox applet ownership receipt baseline did not pass its own acceptance predicate'
  [ ! -s "${tmp}/nsl-wolfi-baseline.err" ] ||
    fail 'the BusyBox applet ownership baseline emitted unexpected stderr'
  grep -qxF 'NSL-WOLFI-BASELINE-PASS: canonical-and-applet-cases' \
    "${tmp}/nsl-wolfi-baseline.out" ||
    fail 'the BusyBox applet ownership baseline did not reach its exact completion witness'
  echo '    NSL-WOLFI baseline status=0 witness=canonical-and-applet-cases ✓'

  nsl_wolfi_assert_mutant() {
    local label="$1" mutant="$2" expected_status="$3" expected_witness="$4"
    local mutant_status=0
    if cmp -s "${nsl_wolfi_fns}" "${mutant}"; then
      fail "the ${label} mutation did not change the extracted BusyBox receipt"
    fi
    bash -n "${mutant}" ||
      fail "the ${label} mutant is not valid Bash, so its failure would be vacuous"
    nsl_wolfi_predicate "${mutant}" "${label}" || mutant_status="$?"
    [ "${mutant_status}" -ne 0 ] ||
      fail "the ${label} mutant still satisfied the shared baseline predicate"
    case "${mutant_status}" in
    2 | 126 | 127)
      fail "the ${label} mutant died vacuously with shell/exec status ${mutant_status}"
      ;;
    esac
    [ "${mutant_status}" -eq "${expected_status}" ] ||
      fail "the ${label} mutant failed with status ${mutant_status}, expected ${expected_status}"
    [ "$(wc -l <"${tmp}/nsl-wolfi-${label}.err" | tr -d ' ')" -eq 1 ] ||
      fail "the ${label} mutant emitted an unrelated failure beside its named witness"
    grep -qxF "NSL-WOLFI-ASSERTION-FAILED: ${expected_witness}" \
      "${tmp}/nsl-wolfi-${label}.err" ||
      fail "the ${label} mutant did not die at ${expected_witness}"
    echo "    NSL-WOLFI ${label} status=${mutant_status} witness=${expected_witness} ✓"
  }

  # M1: remove only the applet-to-canonical inode guard.
  nsl_wolfi_m1="${tmp}/namespace-wolfi-receipt-fns-m1.sh"
  awk '
    index($0, "[ \"${path}\" -ef \"${NSC_BUSYBOX_CANONICAL}\" ] ||") { skip = 1; next }
    skip && $0 == "  }" { skip = 0; next }
    skip { next }
    { print }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m1}"
  nsl_wolfi_assert_mutant m1 "${nsl_wolfi_m1}" 44 unrelated-regular-file-refusal

  # M2: query the applet alias instead of the reviewed canonical path.
  nsl_wolfi_m2="${tmp}/namespace-wolfi-receipt-fns-m2.sh"
  awk '
    {
      from = "--who-owns \"${NSC_BUSYBOX_CANONICAL}\""
      to = "--who-owns \"${path}\""
      i = index($0, from)
      if (i > 0) {
        $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
      }
      print
    }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m2}"
  nsl_wolfi_assert_mutant m2 "${nsl_wolfi_m2}" 42 symlink-applet-success

  # M3: remove only the PATH-BusyBox-to-canonical inode guard.
  nsl_wolfi_m3="${tmp}/namespace-wolfi-receipt-fns-m3.sh"
  awk '
    index($0, "[ \"${busybox_path}\" -ef \"${NSC_BUSYBOX_CANONICAL}\" ] ||") { skip = 1; next }
    skip && $0 == "  }" { skip = 0; next }
    skip { next }
    { print }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m3}"
  nsl_wolfi_assert_mutant m3 "${nsl_wolfi_m3}" 48 path-shadow-refusal

  # M4: retain only the row prefix and remove exact owner-token parsing.
  nsl_wolfi_m4="${tmp}/namespace-wolfi-receipt-fns-m4.sh"
  awk '
    index($0, "  owner_token=\"${owner_line#") == 1 { skip = 1; next }
    skip && index($0, "  printf '\''%s\\n'\'' \"${owner_line}\"") == 1 {
      skip = 0
      print
      next
    }
    skip { next }
    { print }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m4}"
  nsl_wolfi_assert_mutant m4 "${nsl_wolfi_m4}" 56 wrong-owner-family-static-refusal

  # M5: drop the separate non-empty stderr refusal.
  nsl_wolfi_m5="${tmp}/namespace-wolfi-receipt-fns-m5.sh"
  awk '
    index($0, "[ -z \"${apk_error}\" ] ||") { skip = 1; next }
    skip && $0 == "  }" { skip = 0; next }
    skip { next }
    { print }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m5}"
  nsl_wolfi_assert_mutant m5 "${nsl_wolfi_m5}" 54 apk-nonempty-stderr-refusal

  # M6: drop the exactly-one-stdout-row refusal.
  nsl_wolfi_m6="${tmp}/namespace-wolfi-receipt-fns-m6.sh"
  awk '
    index($0, "[ \"${#owner_rows[@]}\" -eq 1 ] ||") { skip = 1; next }
    skip && $0 == "  }" { skip = 0; next }
    skip { next }
    { print }
  ' "${nsl_wolfi_fns}" >"${nsl_wolfi_m6}"
  nsl_wolfi_assert_mutant m6 "${nsl_wolfi_m6}" 53 apk-multiline-refusal

  # The recursive hard-deadline seam, executed for real against a PATH-first
  # timeout spy. The seam `exec`s timeout, so the spy terminates the run before
  # any SIT work begins: nothing live can happen, and the exact argv the
  # instance would receive is captured.
  #
  # The instance's timeout is not guaranteed to accept GNU long spellings, which
  # is why the short form is load-bearing rather than cosmetic. A source grep
  # would not prove the argv actually handed over, so this runs the bytes.
  nsl_seam_root="${tmp}/deadline-seam"
  nsl_seam_real_timeout="$(command -v timeout)"
  case "${nsl_seam_real_timeout}" in
  /*) ;;
  *) fail 'could not resolve the real timeout executable for the deadline seam test' ;;
  esac
  nsl_seam_build() {
    local dest="$1"
    rm -rf -- "${dest}"
    mkdir -p -- "${dest}/scripts/ci" "${dest}/scripts/validate/fleet-sit" "${dest}/spy"
    cp "${sit_source}" "${dest}/scripts/ci/fleet-sit.sh"
    cp "${PWD}/scripts/validate/fleet-sit/pins.env" \
      "${dest}/scripts/validate/fleet-sit/pins.env"
    cp "${PWD}/scripts/validate/fleet-sit/assert.sh" \
      "${dest}/scripts/validate/fleet-sit/assert.sh"
    # One argument per line: "$*" would collapse argument boundaries and make a
    # split or merged argument indistinguishable from the accepted form.
    cat >"${dest}/spy/timeout" <<'NSL_SEAM_TIMEOUT_SPY'
#!/usr/bin/env bash
: >"${NSL_SEAM_ARGV_FILE:?}"
for nsl_seam_arg in "$@"; do
  printf '%s\n' "${nsl_seam_arg}" >>"${NSL_SEAM_ARGV_FILE}"
done
printf '%s\n' "${FLEET_SIT_UNDER_TIMEOUT:-<unset>}" >"${NSL_SEAM_MARKER_FILE:?}"
exit 0
NSL_SEAM_TIMEOUT_SPY
    cat >"${dest}/spy/nsc" <<'NSL_SEAM_NSC_SENTINEL'
#!/usr/bin/env bash
printf 'nsc reached: %s\n' "$*" >>"${NSL_SEAM_NSC_WITNESS:?}"
exit 90
NSL_SEAM_NSC_SENTINEL
    chmod +x "${dest}/spy/timeout" "${dest}/spy/nsc"
  }
  nsl_seam_run() {
    local dest="$1"
    nsl_seam_argv_file="${dest}/argv.txt"
    nsl_seam_marker_file="${dest}/marker.txt"
    nsl_seam_nsc_witness="${dest}/nsc-witness.txt"
    : >"${nsl_seam_argv_file}"
    : >"${nsl_seam_marker_file}"
    : >"${nsl_seam_nsc_witness}"
    nsl_seam_status=0
    # The outer bound must use the real binary by absolute path: the spy is
    # first on PATH for the child, so an unqualified `timeout` here would be
    # intercepted and the witness would record this wrapper instead of the seam.
    env PATH="${dest}/spy:${PATH}" \
      NSL_SEAM_ARGV_FILE="${nsl_seam_argv_file}" \
      NSL_SEAM_MARKER_FILE="${nsl_seam_marker_file}" \
      NSL_SEAM_NSC_WITNESS="${nsl_seam_nsc_witness}" \
      FLEET_SIT_UNDER_TIMEOUT=0 \
      "${nsl_seam_real_timeout}" 60 bash "${dest}/scripts/ci/fleet-sit.sh" --full \
      >"${dest}/stdout.txt" 2>"${dest}/stderr.txt" || nsl_seam_status=$?
  }
  # The single acceptance predicate. The baseline must pass it and every mutant
  # must be required to fail it, with an on-point reason — comparing a mutant's
  # argv against the canonical string alone would not prove the production
  # regression makes this test fail for the right cause.
  nsl_seam_reason=''
  nsl_seam_accepts() {
    local dest="$1"
    local -a argv=()
    nsl_seam_reason=''
    mapfile -t argv <"${dest}/argv.txt"
    local -a want=(-s TERM -k 30 4200 "${dest}/scripts/ci/fleet-sit.sh" --full)
    if [ "${#argv[@]}" -ne "${#want[@]}" ]; then
      nsl_seam_reason="argument count ${#argv[@]} is not ${#want[@]}"
      return 1
    fi
    local index
    for index in "${!want[@]}"; do
      if [ "${argv[${index}]}" != "${want[${index}]}" ]; then
        nsl_seam_reason="argument $((index + 1)) is '${argv[${index}]}', expected '${want[${index}]}'"
        return 1
      fi
    done
    if [ "$(cat "${dest}/marker.txt")" != '1' ]; then
      nsl_seam_reason='the recursion marker was not exported before exec'
      return 1
    fi
    if [ -s "${dest}/nsc-witness.txt" ]; then
      nsl_seam_reason='an nsc client was reached'
      return 1
    fi
    return 0
  }
  nsl_seam_build "${nsl_seam_root}"
  nsl_seam_run "${nsl_seam_root}"
  [ "${nsl_seam_status}" -eq 0 ] ||
    fail "the deadline seam did not reach the timeout spy: $(tr '\n' ' ' <"${nsl_seam_root}/stderr.txt")"
  nsl_seam_accepts "${nsl_seam_root}" ||
    fail "the deadline seam was rejected by its own acceptance predicate: ${nsl_seam_reason}"
  echo '    deadline seam hands timeout the exact portable short-option argv ✓'
  echo '    deadline seam exports the recursion marker before handing over ✓'
  echo '    deadline seam performs no client action before the hard deadline ✓'

  # Mutation coverage. Each rewrites only the seam line in an isolated copy and
  # requires the argv assertion above to fail on point. A source grep cannot
  # establish this, so every case re-executes the seam.
  nsl_seam_mutation() {
    local label="$1" replacement="$2" expected_reason="$3"
    local dest="${tmp}/deadline-seam-${label}"
    nsl_seam_build "${dest}"
    # shellcheck disable=SC2016
    local original='  exec timeout -s TERM -k 30 4200 "${script_path}" --full'
    MUTATION_EXACT_LINE="${original}" MUTATION_MUTANT_LINE="${replacement}" awk '
      BEGIN {
        exact = ENVIRON["MUTATION_EXACT_LINE"]
        mutant = ENVIRON["MUTATION_MUTANT_LINE"]
        found = 0
      }
      $0 == exact { found++; print mutant; next }
      { print }
      END { if (found != 1) exit 89 }
    ' "${sit_source}" >"${dest}/scripts/ci/fleet-sit.sh" ||
      fail "could not install the ${label} deadline-seam mutation"
    chmod +x "${dest}/scripts/ci/fleet-sit.sh"
    nsl_seam_run "${dest}"
    if nsl_seam_accepts "${dest}"; then
      fail "the ${label} deadline-seam mutation still satisfied the acceptance predicate"
    fi
    case "${nsl_seam_reason}" in
    *"${expected_reason}"*) ;;
    *)
      fail "the ${label} deadline-seam mutation failed for the wrong reason: ${nsl_seam_reason}"
      ;;
    esac
    echo "    deadline-seam mutation ${label} fails the acceptance predicate on point ✓"
  }
  # shellcheck disable=SC2016
  # The GNU long form packs option and value into one word each, so it arrives
  # as five argv words rather than seven; the count check is the on-point
  # rejection for that regression.
  nsl_seam_mutation gnu-long-flags \
    '  exec timeout --signal=TERM --kill-after=30s 4200 "${script_path}" --full' \
    'argument count 5 is not 7'
  # shellcheck disable=SC2016
  nsl_seam_mutation altered-signal-value \
    '  exec timeout -s HUP -k 30 4200 "${script_path}" --full' \
    "argument 2 is 'HUP', expected 'TERM'"
  # shellcheck disable=SC2016
  nsl_seam_mutation altered-kill-after-value \
    '  exec timeout -s TERM -k 45 4200 "${script_path}" --full' \
    "argument 4 is '45', expected '30'"
  # shellcheck disable=SC2016
  nsl_seam_mutation omitted-kill-after-option \
    '  exec timeout -s TERM 4200 "${script_path}" --full' \
    'argument count 5 is not 7'
  # shellcheck disable=SC2016
  nsl_seam_mutation altered-deadline-value \
    '  exec timeout -s TERM -k 30 3600 "${script_path}" --full' \
    "argument 5 is '3600', expected '4200'"
  # shellcheck disable=SC2016
  nsl_seam_mutation omitted-full-argument \
    '  exec timeout -s TERM -k 30 4200 "${script_path}"' \
    'argument count 6 is not 7'

  # The checkout preflight, driven as production bytes rather than a
  # transcription. The generation-11 inner failure at product 1ce87ae reported
  # only `not a git checkout: <path>` because the probe discarded git's stderr,
  # which left a foreign-owned tree and an absent `.git` indistinguishable —
  # both exit 128 and differ only in that discarded text. These cases require
  # the distinguishing text to survive into the refusal.
  #
  # The preamble is extracted verbatim from the opening of
  # prepare_verified_snapshot up to its first mode branch, then closed into a
  # callable function, so the probe under test is the shipped bytes.
  nsl_probe_fn="${tmp}/namespace-checkout-probe-fn.sh"
  awk '
    /^prepare_verified_snapshot\(\) \{$/ { capture = 1 }
    capture && /^  if \[ "\$\{mode\}" = .inner. \]; then$/ { capture = 0; print "}" }
    capture { print }
  ' "${proof_source}" >"${nsl_probe_fn}"
  grep -qxF 'prepare_verified_snapshot() {' "${nsl_probe_fn}" &&
    [ "$(tail -n 1 "${nsl_probe_fn}")" = '}' ] ||
    fail 'could not extract the production checkout preflight for the diagnostic regression'
  grep -qF 'rev-parse --git-dir' "${nsl_probe_fn}" ||
    fail 'the extracted checkout preflight does not contain the git-dir probe'

  cat >"${tmp}/namespace-checkout-probe-driver.sh" <<'NSL_PROBE_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
checkout="$2"
fail() {
  echo "fleet SIT proof failed: $*" >&2
  exit 1
}
# shellcheck source=/dev/null
source "${fn_file}"
prepare_verified_snapshot
echo 'checkout preflight accepted'
NSL_PROBE_DRIVER

  nsl_probe_repo="${tmp}/namespace-checkout-probe-repo"
  mkdir -p "${nsl_probe_repo}"
  git -C "${nsl_probe_repo}" init --quiet --initial-branch=main
  git -C "${nsl_probe_repo}" config user.name fleet-checkout-probe
  git -C "${nsl_probe_repo}" config user.email fleet-checkout-probe@invalid.example
  printf '%s\n' fixture >"${nsl_probe_repo}/fixture.txt"
  git -C "${nsl_probe_repo}" add fixture.txt
  git -C "${nsl_probe_repo}" commit --quiet -m 'checkout probe fixture'

  nsl_probe_run() {
    local name="$1" target="$2"
    shift 2
    nsl_probe_status=0
    env "$@" bash "${tmp}/namespace-checkout-probe-driver.sh" \
      "${nsl_probe_fn}" "${target}" \
      >"${tmp}/checkout-probe-${name}.out" \
      2>"${tmp}/checkout-probe-${name}.err" || nsl_probe_status=$?
  }

  nsl_probe_run healthy "${nsl_probe_repo}"
  [ "${nsl_probe_status}" -eq 0 ] ||
    fail "the production checkout preflight rejected a healthy checkout: $(tr '\n' ' ' <"${tmp}/checkout-probe-healthy.err")"

  # Positive control for the lever itself. If this git no longer honours the
  # ownership test hook the case would silently stop proving anything, so refuse
  # rather than skip.
  git -C "${nsl_probe_repo}" rev-parse --git-dir >/dev/null 2>&1 ||
    fail 'the checkout probe fixture is not a usable repository'
  nsl_probe_foreign_owner_env=(
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_NOSYSTEM=1
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1
  )
  if env "${nsl_probe_foreign_owner_env[@]}" \
    git -C "${nsl_probe_repo}" rev-parse --git-dir >/dev/null 2>&1; then
    fail 'GIT_TEST_ASSUME_DIFFERENT_OWNER no longer forces the ownership refusal, so the diagnostic regression would be vacuous'
  fi

  nsl_probe_run foreign-owner "${nsl_probe_repo}" "${nsl_probe_foreign_owner_env[@]}"
  [ "${nsl_probe_status}" -ne 0 ] ||
    fail 'the production checkout preflight accepted a checkout git refuses to own'
  grep -qF 'not a git checkout' "${tmp}/checkout-probe-foreign-owner.err" ||
    fail 'the foreign-owner refusal lost the production refusal text'
  grep -qF 'dubious ownership' "${tmp}/checkout-probe-foreign-owner.err" ||
    fail 'the foreign-owner refusal discarded the git ownership diagnostic that made the g11 inner failure undiagnosable'

  nsl_probe_absent="${tmp}/namespace-checkout-probe-absent"
  rm -rf "${nsl_probe_absent}"
  mkdir -p "${nsl_probe_absent}"
  printf '%s\n' fixture >"${nsl_probe_absent}/fixture.txt"
  nsl_probe_run absent-git "${nsl_probe_absent}"
  [ "${nsl_probe_status}" -ne 0 ] ||
    fail 'the production checkout preflight accepted a directory with no .git surface'
  grep -qF 'not a git repository' "${tmp}/checkout-probe-absent-git.err" ||
    fail 'the absent-.git refusal discarded the git diagnostic that distinguishes it from an ownership refusal'
  if grep -qF 'dubious ownership' "${tmp}/checkout-probe-absent-git.err"; then
    fail 'the absent-.git refusal reported an ownership cause, so the two causes are still not distinguished'
  fi
  echo '    checkout preflight keeps git diagnosis for both foreign ownership and an absent .git ✓'

  # The wrapper's direct-input enumeration, driven as production bytes. Both
  # properties the process-substitution form could not offer are asserted here:
  # NUL-delimited paths survive intact, and a failed producer refuses at its
  # source instead of yielding a successful empty inventory.
  nsl_inv_fn="${tmp}/direct-input-inventory-fn.sh"
  awk '
    /^prepare_verified_snapshot\(\) \{$/ { capture = 1 }
    capture && /^  LC_ALL=C sort -t, -k5 -o/ { capture = 0; print "}" }
    capture { print }
  ' "${proof_source}" >"${nsl_inv_fn}"
  grep -qxF 'prepare_verified_snapshot() {' "${nsl_inv_fn}" &&
    [ "$(tail -n 1 "${nsl_inv_fn}")" = '}' ] ||
    fail 'could not extract the production direct-input enumeration'
  grep -qF 'ls-tree -r -z' "${nsl_inv_fn}" ||
    fail 'the extracted direct-input enumeration lost its NUL-delimited producer'

  nsl_inv_repo="${tmp}/direct-input-repo"
  rm -rf "${nsl_inv_repo}"
  mkdir -p "${nsl_inv_repo}/platforms/canary"
  git -C "${nsl_inv_repo}" init --quiet --initial-branch=main
  git -C "${nsl_inv_repo}" config user.name fleet-direct-input
  git -C "${nsl_inv_repo}" config user.email fleet-direct-input@invalid.example
  printf '%s\n' plain >"${nsl_inv_repo}/platforms/canary/plain.yaml"
  printf '%s\n' spaced >"${nsl_inv_repo}/platforms/canary/a file with spaces.yaml"
  # A path git would C-quote without -z (embedded double quote plus non-ASCII).
  # This is the case NUL delimiting actually protects here: without -z the
  # producer emits an escaped, quoted path and the inventory records the wrong
  # bytes. A newline-bearing path is deliberately NOT used — the production
  # record parser splits fields with line-based `cut`, so it cannot represent
  # one at all. That is a pre-existing limitation of the parser, unrelated to
  # this portability change, and is reported rather than silently worked around.
  printf '%s\n' quoted >"${nsl_inv_repo}/platforms/canary/naïve \"quoted\".yaml"
  git -C "${nsl_inv_repo}" add -A
  git -C "${nsl_inv_repo}" commit --quiet -m 'direct input fixture'

  # The extracted function derives `commit` from FLEET_SIT_EXPECTED_HEAD in
  # inner mode and makes its own `snapshot` under `proof_tmp_root`, so the
  # driver seeds those production globals rather than passing them positionally.
  cat >"${tmp}/direct-input-driver.sh" <<'NSL_INV_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
checkout="$2"
proof_tmp_root="$3"
mode='inner'
DIRECT_INPUT_ROOTS=('platforms/canary')
canonical_inventory=''
snapshot=''
commit=''
snapshot_tree=''
fail() {
  echo "fleet SIT proof failed: $*" >&2
  exit 1
}
verify_wrapper_identity() { :; }
# shellcheck source=/dev/null
source "${fn_file}"
prepare_verified_snapshot
cat "${canonical_inventory}"
NSL_INV_DRIVER

  nsl_inv_tmp="${tmp}/direct-input-tmp"
  mkdir -p "${nsl_inv_tmp}"
  nsl_inv_commit="$(git -C "${nsl_inv_repo}" rev-parse HEAD)"
  nsl_inv_status=0
  env FLEET_SIT_EXPECTED_HEAD="${nsl_inv_commit}" \
    bash "${tmp}/direct-input-driver.sh" "${nsl_inv_fn}" "${nsl_inv_repo}" "${nsl_inv_tmp}" \
    >"${tmp}/direct-input.out" 2>"${tmp}/direct-input.err" || nsl_inv_status=$?
  [ "${nsl_inv_status}" -eq 0 ] ||
    fail "the production direct-input enumeration failed on a healthy fixture: $(tr '\n' ' ' <"${tmp}/direct-input.err")"

  # Fidelity is asserted against an independent NUL-correct reader over the same
  # stream rather than against a line count, since the inventory is LF-emitted
  # and a record is not guaranteed to be one physical line.
  git -C "${nsl_inv_repo}" ls-tree -r -z "${nsl_inv_commit}" -- 'platforms/canary' \
    >"${tmp}/direct-input-stream.z" ||
    fail 'could not build the direct-input reference stream'
  nsl_inv_records="$(tr -dc '\0' <"${tmp}/direct-input-stream.z" | wc -c | tr -d ' ')"
  [ "${nsl_inv_records}" -eq 3 ] ||
    fail "the direct-input fixture did not produce three NUL records, got ${nsl_inv_records}"
  : >"${tmp}/direct-input.expected"
  while IFS= read -r -d '' nsl_inv_record; do
    nsl_inv_mode="${nsl_inv_record%% *}"
    nsl_inv_type="$(printf '%s' "${nsl_inv_record}" | cut -d' ' -f2)"
    nsl_inv_object="$(printf '%s' "${nsl_inv_record}" | cut -d' ' -f3 | cut -f1)"
    nsl_inv_path="${nsl_inv_record#*$'\t'}"
    nsl_inv_content="$(git -C "${nsl_inv_repo}" cat-file blob "${nsl_inv_object}" |
      sha256sum | awk '{print $1}')"
    printf '%s,%s,%s,%s,%s\n' "${nsl_inv_mode}" "${nsl_inv_type}" "${nsl_inv_object}" \
      "${nsl_inv_content}" "${nsl_inv_path}" >>"${tmp}/direct-input.expected"
  done <"${tmp}/direct-input-stream.z"
  cmp -s "${tmp}/direct-input.expected" "${tmp}/direct-input.out" ||
    fail 'the production direct-input inventory differs from an independent NUL-correct reader over the same stream'
  grep -qF 'a file with spaces.yaml' "${tmp}/direct-input.out" ||
    fail 'the production direct-input enumeration lost a space-bearing path'

  # Fail-closed: shadow git so only `ls-tree` fails. A process substitution
  # would have swallowed this and produced a successful empty inventory.
  mkdir -p "${tmp}/direct-input-stub"
  nsl_inv_real_git="$(command -v git)"
  cat >"${tmp}/direct-input-stub/git" <<NSL_INV_GIT_STUB
#!/usr/bin/env bash
for nsl_arg in "\$@"; do
  if [ "\${nsl_arg}" = 'ls-tree' ]; then
    echo 'stub: ls-tree refused' >&2
    exit 1
  fi
done
exec "${nsl_inv_real_git}" "\$@"
NSL_INV_GIT_STUB
  chmod +x "${tmp}/direct-input-stub/git"
  nsl_inv_status=0
  env PATH="${tmp}/direct-input-stub:${PATH}" FLEET_SIT_EXPECTED_HEAD="${nsl_inv_commit}" \
    bash "${tmp}/direct-input-driver.sh" "${nsl_inv_fn}" "${nsl_inv_repo}" "${nsl_inv_tmp}" \
    >"${tmp}/direct-input-fail.out" 2>"${tmp}/direct-input-fail.err" || nsl_inv_status=$?
  [ "${nsl_inv_status}" -ne 0 ] ||
    fail 'the production direct-input enumeration accepted a failed producer'
  grep -qF 'could not enumerate the direct-input roots' "${tmp}/direct-input-fail.err" ||
    fail 'a failed direct-input producer did not refuse at its source; a process substitution would have yielded an empty inventory'
  echo '    direct-input enumeration matches a NUL-correct reference and refuses a failed producer ✓'

  # The six full-mode-only textual producers, driven as production bytes. These
  # sites never execute offline, so without this they would ship unexercised.
  # Each category is proved in both directions: an empty successful producer
  # must stay an empty loop, and a failed producer must reach its own
  # site-specific refusal rather than becoming a successful empty iteration.
  nsl_cat_fns="${tmp}/producer-category-fns.sh"
  : >"${nsl_cat_fns}"
  for nsl_cat_fn in wait_argo_rollouts build_expected_child_apps \
    expected_changed_names kargo_runtime_verify_node_image \
    kargo_runtime_ctr_saved_display_tag kargo_runtime_assert_import_transcript \
    write_direct_input_inventory; do
    sed -n "/^${nsl_cat_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/nsl-cat-fn.sh"
    test -s "${tmp}/nsl-cat-fn.sh" ||
      fail "could not extract ${nsl_cat_fn}() for the producer-category regression"
    [ "$(tail -n 1 "${tmp}/nsl-cat-fn.sh")" = '}' ] ||
      fail "the extracted ${nsl_cat_fn}() is unterminated"
    cat "${tmp}/nsl-cat-fn.sh" >>"${nsl_cat_fns}"
  done

  cat >"${tmp}/producer-category-driver.sh" <<'NSL_CAT_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
work="$2"
category="$3"
outcome="$4"
mkdir -p "${work}/stub" "${work}/report"
report="${work}/report"
FLEET_SOURCE="${work}/source"
mkdir -p "${FLEET_SOURCE}/platforms/canary/landscapes"
sit_fail() {
  echo "fixture refusal: $*" >&2
  exit 1
}
kargo_runtime_canonical_image_tag() { printf '%s' "$1"; }

# Call-sensitive stub: fails only when the invocation matches SELECTOR, and
# otherwise defers to the real tool. Without this, a blanket-failing stub always
# stops at the first producer and later sites in the same function are never
# driven.
# passthrough=real defers non-matching calls to the real tool; passthrough=quiet
# returns empty success, which is what models "the producer legitimately found
# nothing" for tools that cannot run offline at all.
stub() {
  local name="$1" selector="$2" passthrough="$3"
  local real
  real="$(command -v "${name}" || true)"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "${outcome}" = 'fail' ]; then
      printf 'for a in "$@"; do [ "$a" = %q ] && { echo "stub: %s refused" >&2; exit 1; }; done\n' \
        "${selector}" "${name}"
    fi
    if [ "${passthrough}" = 'real' ] && [ -n "${real}" ]; then
      printf 'exec %q "$@"\n' "${real}"
    else
      printf 'exit 0\n'
    fi
  } >"${work}/stub/${name}"
  chmod +x "${work}/stub/${name}"
}

case "${category}" in
kubectl-deployments) stub kubectl deployments quiet ;;
kubectl-statefulsets) stub kubectl statefulsets quiet ;;
find) stub find "${FLEET_SOURCE}/platforms/canary/landscapes" quiet ;;
jq) stub jq '.[] | select(.landscape == $landscape) | .name' quiet ;;
sed-inventory | sed-inventory-match) stub sed '1d' "$([ "${category}" = 'sed-inventory-match' ] && echo real || echo quiet)" ;;
sed-transcript) stub sed -n quiet ;;
awk-transcript) stub awk -v quiet ;;
git-ls-tree) stub git ls-tree real ;;
esac
PATH="${work}/stub:${PATH}"
export PATH
# shellcheck source=/dev/null
source "${fn_file}"
case "${category}" in
kubectl-deployments | kubectl-statefulsets) wait_argo_rollouts ;;
find) build_expected_child_apps "${work}/child-apps.json" ;;
jq)
  printf '[]\n' >"${report}/expected-child-apps.json"
  expected_changed_names "${work}/changed.json" canary
  ;;
sed-inventory)
  printf 'HEADER\n' >"${work}/inventory.txt"
  kargo_runtime_verify_node_image "${work}/inventory.txt" 'img:tag' 'sha256:deadbeef'
  ;;
sed-inventory-match)
  # Successful match path: proves the listing is removed even when the loop
  # stops early, now that it no longer lives in the cleanup-managed scratch.
  printf 'HEADER\nimg:tag application/json sha256:deadbeef extra\n' >"${work}/inventory.txt"
  kargo_runtime_verify_node_image "${work}/inventory.txt" 'img:tag' 'sha256:deadbeef'
  ;;
sed-transcript)
  printf 'unpacking img:tag (sha256:%064d)...done\n' 1 >"${work}/transcript.txt"
  kargo_runtime_assert_import_transcript "${work}/transcript.txt" 'img:tag' "sha256:$(printf '%064d' 1)"
  ;;
awk-transcript)
  printf 'img:tag\t\tsaved\napplication/vnd.oci.image.index.v1+json sha256:%064d\n' \
    1 >"${work}/transcript.txt"
  kargo_runtime_assert_import_transcript "${work}/transcript.txt" 'img:tag' "sha256:$(printf '%064d' 1)"
  ;;
git-ls-tree)
  SIT_DIRECT_INPUT_ROOTS=('.')
  git init --quiet --initial-branch=main "${work}/repo"
  git -C "${work}/repo" config user.name p
  git -C "${work}/repo" config user.email p@invalid.example
  printf 'x\n' >"${work}/repo/f.txt"
  git -C "${work}/repo" add -A
  git -C "${work}/repo" commit --quiet -m fixture
  cd "${work}/repo"
  write_direct_input_inventory "${work}/inv.sha256" "$(git rev-parse HEAD)" advisory
  ;;
esac
echo 'category completed without a producer refusal'
NSL_CAT_DRIVER

  # ${3} is the refusal a failed producer must reach. ${4}, when given, is the
  # downstream semantic refusal the empty-but-successful case must reach — that
  # proves the empty loop was actually consumed rather than the case passing on
  # any arbitrary failure.
  nsl_cat_check() {
    local category="$1" refusal="$2" empty_expect="${3:-}"
    local w
    for nsl_cat_outcome in empty fail; do
      w="${tmp}/producer-${category}-${nsl_cat_outcome}"
      rm -rf "${w}"
      mkdir -p "${w}"
      nsl_cat_status=0
      timeout 60 bash "${tmp}/producer-category-driver.sh" \
        "${nsl_cat_fns}" "${w}" "${category}" "${nsl_cat_outcome}" \
        >"${w}/out.txt" 2>"${w}/err.txt" || nsl_cat_status=$?
      if [ "${nsl_cat_outcome}" = 'fail' ]; then
        [ "${nsl_cat_status}" -ne 0 ] ||
          fail "producer ${category}: a failed producer was accepted"
        grep -qF "${refusal}" "${w}/err.txt" ||
          fail "producer ${category}: a failed producer did not reach its site-specific refusal"
      else
        if grep -qF "${refusal}" "${w}/err.txt"; then
          fail "producer ${category}: an empty but successful producer was refused as a failure"
        fi
        if [ -n "${empty_expect}" ]; then
          grep -qF "${empty_expect}" "${w}/err.txt" ||
            fail "producer ${category}: the empty loop was not consumed into its expected downstream refusal"
        fi
      fi
    done
    echo "    producer ${category}: empty stays an empty loop, failure reaches its own refusal ✓"
  }
  nsl_cat_check kubectl-deployments 'could not list argocd deployments'
  nsl_cat_check kubectl-statefulsets 'could not list argocd statefulsets'
  nsl_cat_check find 'could not enumerate the canary landscape files'
  nsl_cat_check jq 'could not read expected child-app names'
  nsl_cat_check sed-inventory 'could not read the platform containerd image inventory' \
    'platform containerd does not bind'
  nsl_cat_check sed-transcript 'could not extract unpack markers from the import transcript' \
    'does not bind'
  nsl_cat_check awk-transcript 'could not extract saved markers from the import transcript' \
    'does not bind'
  nsl_cat_check git-ls-tree 'could not enumerate the direct-input roots'

  # The successful-match path must leave no listing behind, now that it is keyed
  # off the input rather than the cleanup-managed scratch root.
  nsl_cat_match="${tmp}/producer-sed-inventory-match"
  rm -rf "${nsl_cat_match}"
  mkdir -p "${nsl_cat_match}"
  nsl_cat_status=0
  timeout 60 bash "${tmp}/producer-category-driver.sh" \
    "${nsl_cat_fns}" "${nsl_cat_match}" sed-inventory-match empty \
    >"${nsl_cat_match}/out.txt" 2>"${nsl_cat_match}/err.txt" || nsl_cat_status=$?
  [ "${nsl_cat_status}" -eq 0 ] ||
    fail "producer sed-inventory-match: a matching inventory was rejected: $(tr '\n' ' ' <"${nsl_cat_match}/err.txt")"
  [ -z "$(find "${nsl_cat_match}" -name '*.rows.*' 2>/dev/null)" ] ||
    fail 'producer sed-inventory-match: the successful match path leaked its listing file'
  echo '    producer sed-inventory-match: early match still removes its listing ✓'

  # The wrapper's report-evidence producer (the second converted wrapper site),
  # extracted as the exact production block rather than driven through the whole
  # of validate_finished_report, which would need a full report fixture.
  nsl_ev_fn="${tmp}/evidence-producer-fn.sh"
  {
    printf 'validate_report_evidence() {\n'
    awk '
      /^  local evidence$/ { capture = 1 }
      capture { print }
      capture && /^  rm -f "\$\{evidence_listing\}"$/ { capture = 0 }
    ' "${proof_source}"
    printf '}\n'
  } >"${nsl_ev_fn}"
  grep -qF 'jq -r ' "${nsl_ev_fn}" ||
    fail 'could not extract the wrapper report-evidence producer'
  grep -qF 'could not read the declared evidence paths' "${nsl_ev_fn}" ||
    fail 'the extracted wrapper report-evidence producer is not status-checked'
  cat >"${tmp}/evidence-driver.sh" <<'NSL_EV_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
report="$2"
outcome="$3"
report_file="${report}/sit-report.json"
mkdir -p "${report}"
printf '{"legs":[{"evidence":["ok.txt"]}]}\n' >"${report_file}"
printf 'x\n' >"${report}/ok.txt"
fail() {
  echo "fleet SIT proof failed: $*" >&2
  exit 1
}
if [ "${outcome}" = 'fail' ]; then
  mkdir -p "${report}/stub"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${report}/stub/jq"
  chmod +x "${report}/stub/jq"
  PATH="${report}/stub:${PATH}"
  export PATH
fi
# shellcheck source=/dev/null
source "${fn_file}"
validate_report_evidence
echo 'evidence validation completed'
NSL_EV_DRIVER
  for nsl_ev_outcome in ok fail; do
    nsl_ev_work="${tmp}/evidence-${nsl_ev_outcome}"
    rm -rf "${nsl_ev_work}"
    nsl_ev_status=0
    timeout 60 bash "${tmp}/evidence-driver.sh" "${nsl_ev_fn}" "${nsl_ev_work}" "${nsl_ev_outcome}" \
      >"${tmp}/evidence-${nsl_ev_outcome}.out" 2>"${tmp}/evidence-${nsl_ev_outcome}.err" ||
      nsl_ev_status=$?
    if [ "${nsl_ev_outcome}" = 'fail' ]; then
      [ "${nsl_ev_status}" -ne 0 ] ||
        fail 'the wrapper report-evidence producer accepted a failed jq'
      grep -qF 'could not read the declared evidence paths' "${tmp}/evidence-fail.err" ||
        fail 'a failed report-evidence producer did not refuse at its source'
    else
      [ "${nsl_ev_status}" -eq 0 ] ||
        fail "the wrapper report-evidence producer failed on a healthy report: $(tr '\n' ' ' <"${tmp}/evidence-ok.err")"
    fi
  done
  echo '    wrapper report-evidence producer refuses a failed jq ✓'

  # The harness-log FIFO lifecycle, driven as production bytes. Every case runs
  # under a bounded timeout, because the failure this design exists to prevent
  # is a hang: an exit of 124 is a regression, not a slow test.
  nsl_log_fns="${tmp}/harness-log-fns.sh"
  : >"${nsl_log_fns}"
  for nsl_log_fn in start_harness_log finish_harness_log; do
    sed -n "/^${nsl_log_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/nsl-log-fn.sh"
    test -s "${tmp}/nsl-log-fn.sh" ||
      fail "could not extract ${nsl_log_fn}() for the harness log regression"
    [ "$(tail -n 1 "${tmp}/nsl-log-fn.sh")" = '}' ] ||
      fail "the extracted ${nsl_log_fn}() is unterminated"
    cat "${tmp}/nsl-log-fn.sh" >>"${nsl_log_fns}"
  done
  grep -qF '<>' "${nsl_log_fns}" ||
    fail 'the extracted harness log setup no longer opens a bootstrap descriptor read-write, so a dead reader could block the writer open'

  cat >"${tmp}/harness-log-driver.sh" <<'NSL_LOG_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
work="$2"
log_path="$3"
scenario="$4"
mkdir -p "${work}"

SIT_LOG_FIFO=''
SIT_LOG_TEE_PID=''
SIT_LOG_BOOT_FD=''
SIT_LOG_WRITER_FD=''
SIT_LOG_SAVED_OUT=''
SIT_LOG_SAVED_ERR=''
SIT_LOG_ARMED=0
SIT_LOG_FINALIZED=0
FINALIZER_ENTRIES=0

sit_fail() {
  echo "fixture refusal: $*" >&2
  exit 1
}
sit_require_command() {
  command -v "$1" >/dev/null 2>&1 || sit_fail "required command is missing: $1"
}
# shellcheck source=/dev/null
source "${fn_file}"

# The reader is substituted only to model reader death; every other scenario
# uses the production tee path.
mkdir -p "${work}/stubdir"
case "${scenario}" in
reader-dies)
  printf '#!/usr/bin/env bash\nexit 7\n' >"${work}/stubdir/tee"
  ;;
reader-missing)
  printf '#!/usr/bin/env bash\nexec /nonexistent/reader\n' >"${work}/stubdir/tee"
  ;;
late-reader-fails | both-fail)
  # Drains stdin normally, copies to the log, then fails at EOF. This is the
  # late failure an early-death test cannot reach.
  printf '#!/usr/bin/env bash\nshift\ncat >>"%s"\nexit 9\n' "${log_path}" \
    >"${work}/stubdir/tee"
  ;;
esac
if [ -f "${work}/stubdir/tee" ]; then
  chmod +x "${work}/stubdir/tee"
  PATH="${work}/stubdir:${PATH}"
  export PATH
fi

finalize() {
  local rc=$?
  FINALIZER_ENTRIES=$((FINALIZER_ENTRIES + 1))
  [ "${FINALIZER_ENTRIES}" -eq 1 ] || return
  trap - EXIT ERR TERM INT
  set +e
  echo 'cleanup-stdout-marker'
  echo 'cleanup-stderr-marker' >&2
  local reader_pid="${SIT_LOG_TEE_PID}"
  local log_rc=0
  finish_harness_log || log_rc=1
  if [ "${rc}" -eq 0 ] && [ "${log_rc}" -ne 0 ]; then
    rc=1
  fi
  if [ -n "${reader_pid}" ] && kill -0 "${reader_pid}" 2>/dev/null; then
    echo 'READER_SURVIVED=1' >&2
  fi
  echo "ENTRIES=${FINALIZER_ENTRIES} BODY=${rc} LOG=${log_rc}" >&2
  exit "${rc}"
}

trap finalize EXIT
trap 'exit 130' INT
start_harness_log "${log_path}"

echo 'body-stdout-marker'
echo 'body-stderr-marker' >&2
case "${scenario}" in
body-fails) false ;;
signal-int) kill -INT $$ ;;
both-fail) exit 3 ;;
esac
NSL_LOG_DRIVER

  nsl_log_run() {
    local name="$1"
    nsl_log_work="${tmp}/harness-log-${name}"
    rm -rf "${nsl_log_work}"
    mkdir -p "${nsl_log_work}"
    nsl_log_file="${nsl_log_work}/harness.log"
    nsl_log_status=0
    timeout 30 bash "${tmp}/harness-log-driver.sh" \
      "${nsl_log_fns}" "${nsl_log_work}" "${nsl_log_file}" "${name}" \
      >"${nsl_log_work}/caller.out" 2>"${nsl_log_work}/caller.err" || nsl_log_status=$?
    [ "${nsl_log_status}" -ne 124 ] ||
      fail "harness log ${name}: timed out, which is the hang this design exists to prevent"
    grep -qF 'ENTRIES=1' "${nsl_log_work}/caller.err" ||
      fail "harness log ${name}: the finalizer did not run exactly once"
    [ -z "$(find "${nsl_log_work}" -name '*.fifo' 2>/dev/null)" ] ||
      fail "harness log ${name}: the FIFO survived finalization"
    if grep -qF 'READER_SURVIVED=1' "${nsl_log_work}/caller.err"; then
      fail "harness log ${name}: the reader was not reaped and outlived finalization"
    fi
  }

  nsl_log_run normal
  [ "${nsl_log_status}" -eq 0 ] ||
    fail 'harness log normal: a healthy run did not succeed'
  for nsl_log_marker in body-stdout-marker body-stderr-marker cleanup-stdout-marker; do
    [ "$(grep -c "${nsl_log_marker}" "${nsl_log_work}/caller.out")" -eq 1 ] ||
      fail "harness log normal: ${nsl_log_marker} did not reach the caller exactly once"
    [ "$(grep -c "${nsl_log_marker}" "${nsl_log_file}")" -eq 1 ] ||
      fail "harness log normal: ${nsl_log_marker} did not reach the log exactly once"
  done

  nsl_log_run body-fails
  [ "${nsl_log_status}" -eq 1 ] ||
    fail 'harness log body-fails: the primary body status was not preserved'

  nsl_log_run signal-int
  [ "${nsl_log_status}" -eq 130 ] ||
    fail 'harness log signal-int: the signal status was not preserved'
  grep -qF 'cleanup-stdout-marker' "${nsl_log_file}" ||
    fail 'harness log signal-int: cleanup output was lost from the log'

  # The two cases the bootstrap descriptor exists for. Without it the writer
  # open would block forever on a reader that is already gone.
  nsl_log_run reader-dies
  [ "${nsl_log_status}" -ne 0 ] ||
    fail 'harness log reader-dies: a dead log writer still produced success'
  nsl_log_run reader-missing
  [ "${nsl_log_status}" -ne 0 ] ||
    fail 'harness log reader-missing: an unlaunchable log writer still produced success'

  # A reader that drains normally and only fails at EOF — the late failure an
  # early-death case cannot reach.
  nsl_log_run late-reader-fails
  [ "${nsl_log_status}" -ne 0 ] ||
    fail 'harness log late-reader-fails: a log writer that failed at EOF still produced success'
  grep -qF 'body-stdout-marker' "${nsl_log_file}" ||
    fail 'harness log late-reader-fails: the drained output never reached the log'

  # Status precedence when both the body and the reader fail: the body wins.
  nsl_log_run both-fail
  [ "${nsl_log_status}" -eq 3 ] ||
    fail "harness log both-fail: the primary body status was not preserved over the log writer failure, got ${nsl_log_status}"
  echo '    harness log FIFO: both destinations exactly once, single finalization, dead reader fails closed without hanging ✓'

  nsl_root="${tmp}/namespace-lifecycle"
  nsl_fixture="${nsl_root}/fixture"
  nsl_bin="${nsl_root}/bin"
  mkdir -p \
    "${nsl_fixture}/platforms/canary" \
    "${nsl_fixture}/registry/charts/diene-platform" \
    "${nsl_fixture}/registry/fixtures/clusters" \
    "${nsl_fixture}/registry/fixtures/negative" \
    "${nsl_fixture}/scripts/ci" \
    "${nsl_fixture}/scripts/validate/fleet-sit" \
    "${nsl_bin}"
  cp "${proof_source}" "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh"
  nsl_proof_baseline="${nsl_root}/fleet-sit-proof.baseline.sh"
  cp "${proof_source}" "${nsl_proof_baseline}"
  cp "${pins_source}" "${nsl_fixture}/scripts/validate/fleet-sit/pins.env"
  printf '%s\n' fixture >"${nsl_fixture}/platforms/canary/services.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/charts/diene-platform/fixture.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/fixtures/clusters/fixture.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/fixtures/negative/fixture.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/argocd-webhook-secret.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/machinery-stable.yaml"
  printf '%s\n' fixture >"${nsl_fixture}/registry/platforms-appset.yaml"
  cat >"${nsl_fixture}/scripts/ci/fleet-sit.sh" <<'NSL_SIT_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" = '--prepare-only' ] || {
  echo 'the lifecycle fixture inner run must be supplied by the nsc shim' >&2
  exit 91
}
printf 'fixture prepare-only invoked\n'
NSL_SIT_STUB
  chmod +x "${nsl_fixture}/scripts/ci/fleet-sit.sh" \
    "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh"
  git -C "${nsl_fixture}" init --quiet --initial-branch=main
  git -C "${nsl_fixture}" config user.name fleet-sit-lifecycle
  git -C "${nsl_fixture}" config user.email fleet-sit-lifecycle@invalid.example
  git -C "${nsl_fixture}" add .
  git -C "${nsl_fixture}" commit --quiet -m 'Namespace lifecycle fixture'

  cat >"${nsl_bin}/sleep" <<'NSL_SLEEP_SHIM'
#!/usr/bin/env sh
exit 0
NSL_SLEEP_SHIM
  chmod +x "${nsl_bin}/sleep"

  # Scripted epoch source, so the five-minute SESSION-HANG lane budget can be
  # driven to exhaustion without any real waiting. Real sleeping scaled to the
  # ratified budgets is forbidden in this harness, and the budget pins cannot be
  # shrunk instead: validate_session_hang_bounds hard-asserts 60 and 300.
  #
  # Unarmed it execs the real date, so every pre-existing lifecycle case is
  # byte-for-byte unaffected. Armed by NSL_DATE_OFFSETS it adds an offset once a
  # named lane event has occurred. Arming is keyed to the OBSERVED CALL COUNTERS
  # the fake client maintains, never to this shim's own call ordinal: the number
  # of `date +%s` calls the wrapper makes before the lane is an implementation
  # detail that would silently drift, whereas the counters are lane events with
  # fixed meaning.
  #   hN — once the Nth hostname invocation has happened
  #        (N=1 readiness, N=2 lane re-invocation 1, ...)
  #   lN — once the Nth list invocation has happened
  #        (N=1 the pre-use liveness proof, N=2 lane liveness proof 1, ...)
  # Offsets are cumulative and permanent once reached, so the modelled clock is
  # monotonic non-decreasing — the lifecycle receipt asserts
  # finishedEpoch >= startedEpoch and a one-shot spike would violate it.
  nsl_real_date="$(command -v date)"
  case "${nsl_real_date}" in
  /*) ;;
  *) fail 'could not resolve the real date executable for the Namespace lifecycle shim' ;;
  esac
  # The real date path is BAKED IN as a default rather than relied upon from the
  # environment. This shim shadows `date` for every caller that puts nsl_bin on
  # PATH, including the prepare-only fixture, and a missing variable would turn
  # an unrelated case into a confusing shim failure.
  cat >"${nsl_bin}/date" <<NSL_DATE_HEAD
#!/usr/bin/env bash
set -Eeuo pipefail

NSL_REAL_DATE="\${NSL_REAL_DATE:-${nsl_real_date}}"
NSL_DATE_HEAD
  cat >>"${nsl_bin}/date" <<'NSL_DATE_SHIM'

if [ "${1:-}" != '+%s' ] || [ -z "${NSL_DATE_OFFSETS:-}" ]; then
  exec "${NSL_REAL_DATE:?}" "$@"
fi

state="${NSC_SHIM_STATE:?}"
mkdir -p "${state}"

offset=0
IFS=',' read -r -a nsl_date_pairs <<<"${NSL_DATE_OFFSETS}"
for nsl_date_pair in "${nsl_date_pairs[@]}"; do
  [ -n "${nsl_date_pair}" ] || continue
  nsl_date_when="${nsl_date_pair%%:*}"
  nsl_date_add="${nsl_date_pair##*:}"
  case "${nsl_date_when}" in
  h*) nsl_date_counter="${state}/hostname-calls" ;;
  l*) nsl_date_counter="${state}/list-calls" ;;
  *)
    echo "date shim: unmodeled arming key ${nsl_date_when}" >&2
    exit 90
    ;;
  esac
  nsl_date_seen=0
  [ ! -f "${nsl_date_counter}" ] || nsl_date_seen="$(cat "${nsl_date_counter}")"
  [ "${nsl_date_seen}" -ge "${nsl_date_when#?}" ] || continue
  offset=$((offset + nsl_date_add))
done
printf '%s\n' "$(("$("${NSL_REAL_DATE:?}" +%s)" + offset))"
NSL_DATE_SHIM
  chmod +x "${nsl_bin}/date"

  cat >"${nsl_bin}/script" <<'NSL_SCRIPT_SHIM'
#!/usr/bin/env sh
echo 'the lifecycle fixture forbids pseudo-terminal allocation' >&2
exit 97
NSL_SCRIPT_SHIM
  chmod +x "${nsl_bin}/script"

  # Accelerated-duration `timeout` seam.
  #
  # A bounded list hang must reach full-wrapper liveness-unproven exit 77, but
  # the ratified 20s+5s list allowance can be neither waited out nor shrunk:
  # validate_session_hang_bounds hard-asserts both values, so a mutated pin is
  # refused before any client call. This shim leaves the pins, the wrapper source
  # and the validated argv completely untouched and rewrites ONLY the duration
  # actually forwarded to the real timeout, and only for the production list
  # invocation, and only when explicitly armed. Unarmed it is the real timeout.
  nsl_real_timeout="$(command -v timeout)"
  case "${nsl_real_timeout}" in
  /*) ;;
  *) fail 'could not resolve the real timeout executable for the Namespace lifecycle shim' ;;
  esac
  cat >"${nsl_bin}/timeout" <<NSL_TIMEOUT_HEAD
#!/usr/bin/env bash
set -Eeuo pipefail

NSL_REAL_TIMEOUT="\${NSL_REAL_TIMEOUT:-${nsl_real_timeout}}"
NSL_TIMEOUT_HEAD
  cat >>"${nsl_bin}/timeout" <<'NSL_TIMEOUT_SHIM'

if [ "${NSC_SHIM_ACCELERATE_LIST_TIMEOUT:-0}" -ne 1 ]; then
  exec "${NSL_REAL_TIMEOUT:?}" "$@"
fi

# Recognize EXACTLY the production list invocation, in its reviewed argv shape:
#   timeout --verbose --signal=TERM --kill-after=<k>s <d>s nsc list --output json
# Anything else — including all four ssh call sites — is forwarded untouched, so
# this seam cannot silently accelerate a bound it was not pointed at.
if [ "$#" -eq 8 ] &&
  [ "${1:-}" = '--verbose' ] && [ "${2:-}" = '--signal=TERM' ] &&
  [ "${3:-}" = "--kill-after=${NSC_LIST_KILL_AFTER_SECONDS:-5}s" ] &&
  [ "${4:-}" = "${NSC_LIST_TIMEOUT_SECONDS:-20}s" ] &&
  [ "${5:-}" = 'nsc' ] && [ "${6:-}" = 'list' ] &&
  [ "${7:-}" = '--output' ] && [ "${8:-}" = 'json' ]; then
  shift 4
  exec "${NSL_REAL_TIMEOUT:?}" --verbose --signal=TERM \
    --kill-after=1s 1s "$@"
fi

exec "${NSL_REAL_TIMEOUT:?}" "$@"
NSL_TIMEOUT_SHIM
  chmod +x "${nsl_bin}/timeout"

  nsl_real_grep="$(command -v grep)"
  case "${nsl_real_grep}" in
  /*) ;;
  *) fail 'could not resolve the real grep executable for the Namespace lifecycle shim' ;;
  esac
  cat >"${nsl_bin}/grep" <<'NSL_GREP_SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${NSC_SHIM_GREP_FAILURE_AFTER_DESTROY:-0}" -eq 1 ] &&
  [ -f "${NSC_SHIM_STATE:?}/destroyed" ] &&
  [ "${1:-}" = '-q' ] && [ "${2:-}" = $'\033' ]; then
  echo 'shim: injected grep execution failure during the ESC scan' >&2
  exit 2
fi
exec "${NSC_SHIM_REAL_GREP:?}" "$@"
NSL_GREP_SHIM
  chmod +x "${nsl_bin}/grep"

  cat >"${nsl_bin}/nsc" <<'NSL_NSC_SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail

state="${NSC_SHIM_STATE:?}"
id="${NSC_SHIM_ID:?}"
mkdir -p "${state}"

log() {
  printf '%s\n' "$1" >>"${state}/calls.log"
}

active_instance_json() {
  local listed_id="${1:-${id}}"
  local cpu=16 memory=32768 kubernetes='1.33'
  local label_form="${NSC_SHIM_LIST_LABELS:-exact}"
  [ "${NSC_SHIM_LIST_SHAPE:-}" != 'wrong' ] || {
    cpu=4
    memory=8192
  }
  case "${label_form}" in
  exact | wrong-generation | wrong-node) ;;
  *)
    echo "shim: unmodeled list labels ${label_form}" >&2
    return 55
    ;;
  esac
  # Match the pinned client's direct non-TTY interface: one plain JSON array,
  # with no terminal renderer or modeled ANSI envelope between the client and
  # the production capture boundary.
  jq -nM \
    --arg id "${listed_id}" \
    --argjson cpu "${cpu}" \
    --argjson memory "${memory}" \
    --arg kubernetes "${kubernetes}" \
    --arg labelForm "${label_form}" '
      [{cluster_id:$id,labels:{"ratchet-node":"fleet","ratchet-generation":"15"},
        shape:{virtual_cpu:$cpu,memory_megabytes:$memory,machine_arch:"amd64",os:"linux"},
        kubernetes:$kubernetes}]
      | if $labelForm == "wrong-generation" then
          .[0].labels["ratchet-generation"] = "7"
        elif $labelForm == "wrong-node" then
          .[0].labels["ratchet-node"] = "not-fleet"
        else
          .
        end
    '
}

emit_list_form() {
  local form="$1"
  local unrelated_id='zzzzzzzzzzzzz'
  case "${form}" in
  array) active_instance_json ;;
  null) printf 'null\n' ;;
  # A schema-valid empty reviewed array. This is a POSITIVE proof that the exact
  # id is absent — the one and only condition the external driver may read as
  # consuming an instance ordinal.
  empty-array) printf '[]\n' ;;
  # The exact id is PRESENT but disagrees with the reviewed generation label.
  # Disagreement is not absence, so this must reach liveness-unproven and can
  # never be promoted into an ordinal-consuming loss. Applied independently of
  # NSC_SHIM_LIST_LABELS so the pre-use liveness proof can still succeed and the
  # lane is genuinely entered before the drift appears.
  drifted) active_instance_json | jq -cM '.[0].labels["ratchet-generation"] = "7"' ;;
  # A client that emits nothing and never terminates. Blocks on a reader-only
  # FIFO, so it costs no CPU and writes nothing to stderr; the only stderr bytes
  # the wrapper retains are its own timeout diagnostic. Killed by the real
  # production bound, whose forwarded duration the timeout seam accelerates.
  block)
    [ -p "${state}/list-block.fifo" ] || mkfifo -m 600 "${state}/list-block.fifo"
    exec cat -- "${state}/list-block.fifo"
    ;;
  empty) : ;;
  nonzero-valid)
    active_instance_json
    exit 29
    ;;
  multiple)
    active_instance_json
    active_instance_json
    ;;
  multiple-null)
    printf 'null\nnull\n'
    ;;
  malformed) printf '[{"cluster_id":"%s"}' "${id}" ;;
  escape)
    active_instance_json
    printf '\033[0K'
    ;;
  invalid-utf8)
    printf '[{"cluster_id":"%s","labels":{"ratchet-node":"fleet","ratchet-generation":"15"},"shape":{"virtual_cpu":16,"memory_megabytes":32768,"machine_arch":"amd64","os":"linux"},"kubernetes":"1.33","ignored":"audited-' "${id}"
    printf '\xff'
    printf -- '-byte"}]\n'
    ;;
  missing-id)
    active_instance_json "${unrelated_id}" | jq '.[0] |= del(.cluster_id)'
    ;;
  null-id)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = null'
    ;;
  numeric-id)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = 7'
    ;;
  unsafe-id)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = "ABCDEFGHIJKLM"'
    ;;
  unsafe-id-newline)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = "abcdefghijklm\n"'
    ;;
  unsafe-id-short)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = "abcdefghijkl"'
    ;;
  unsafe-id-long)
    active_instance_json "${unrelated_id}" | jq '.[0].cluster_id = "abcdefghijklmno"'
    ;;
  valid-14-id)
    active_instance_json 'abcdefghijklmn' | jq '.[0].labels = {}'
    ;;
  scalar-row) printf '[null]\n' ;;
  labels-scalar)
    active_instance_json "${unrelated_id}" | jq '.[0].labels = "schema-drift"'
    ;;
  labels-numeric)
    active_instance_json "${unrelated_id}" | jq '.[0].labels["ratchet-node"] = 7'
    ;;
  shape-scalar)
    active_instance_json "${unrelated_id}" | jq '.[0].shape = "schema-drift"'
    ;;
  shape-cpu-string)
    active_instance_json "${unrelated_id}" | jq '.[0].shape.virtual_cpu = "16"'
    ;;
  shape-memory-string)
    active_instance_json "${unrelated_id}" | jq '.[0].shape.memory_megabytes = "32768"'
    ;;
  shape-arch-number)
    active_instance_json "${unrelated_id}" | jq '.[0].shape.machine_arch = 64'
    ;;
  shape-os-number)
    active_instance_json "${unrelated_id}" | jq '.[0].shape.os = 7'
    ;;
  duplicate-id)
    active_instance_json "${unrelated_id}" | jq '. + .'
    ;;
  top-object) printf '{}\n' ;;
  missing-exact-id) active_instance_json "${unrelated_id}" ;;
  *)
    echo "shim: unmodeled list form ${form}" >&2
    exit 54
    ;;
  esac
}

write_synthetic_report() {
  local source="${state}/remote/source"
  local report="${state}/remote/result/sit-report"
  local commit="$1" status='pass'
  [ "${NSC_SHIM_FAIL_STAGE:-}" != 'report-validation' ] || status='fail'
  mkdir -p "${report}"
  local -a roots=(
    'platforms/canary'
    'registry/argocd-webhook-secret.yaml'
    'registry/charts/diene-platform'
    'registry/fixtures/clusters'
    'registry/fixtures/negative'
    'registry/machinery-stable.yaml'
    'registry/platforms-appset.yaml'
    'scripts/ci/fleet-sit-proof.sh'
    'scripts/ci/fleet-sit.sh'
    'scripts/validate/fleet-sit'
  )
  local inventory="${report}/direct-input-inventory.sha256"
  : >"${inventory}"
  local record mode type object path sha
  while IFS= read -r -d '' record; do
    mode="${record%% *}"
    type="$(printf '%s' "${record}" | cut -d' ' -f2)"
    object="$(printf '%s' "${record}" | cut -d' ' -f3 | cut -f1)"
    path="${record#*$'\t'}"
    sha="$(git -C "${source}" cat-file blob "${object}" | sha256sum | awk '{print $1}')"
    printf '%s,%s,%s,%s,%s\n' "${mode}" "${type}" "${object}" "${sha}" "${path}" >>"${inventory}"
  done < <(git -C "${source}" ls-tree -r -z "${commit}" -- "${roots[@]}")
  LC_ALL=C sort -t, -k5 -o "${inventory}" "${inventory}"
  local digest count tree legs_json roots_json contract_json
  digest="$(sha256sum -- "${inventory}" | awk '{print $1}')"
  count="$(wc -l <"${inventory}" | tr -d ' ')"
  tree="$(git -C "${source}" rev-parse "${commit}^{tree}")"
  roots_json="$(printf '%s\n' "${roots[@]}" | jq -Rsc 'split("\n")[:-1]')"
  local -a legs=(
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
  contract_json="$(printf '%s\n' "${legs[@]}" | jq -Rsc 'split("\n")[:-1]')"
  : >"${state}/legs.jsonl"
  local index=0 leg evidence
  for leg in "${legs[@]}"; do
    if [ "${index}" -eq 0 ]; then
      evidence='namespace-platform.json'
      printf '%s\n' '{"fixture":true,"tools":[]}' >"${report}/${evidence}"
    else
      evidence="fixture-leg-${index}.txt"
      printf 'synthetic outer-lifecycle fixture for %s\n' "${leg}" >"${report}/${evidence}"
    fi
    jq -n --arg leg "${leg}" --arg evidence "${evidence}" \
      '{leg:$leg,status:"pass",started:"2026-07-31T20:00:00Z",elapsed_s:1,evidence:[$evidence],note:"outer lifecycle fixture"}' \
      >>"${state}/legs.jsonl"
    index=$((index + 1))
  done
  legs_json="$(jq -s . "${state}/legs.jsonl")"
  jq -n \
    --arg status "${status}" \
    --arg commit "${commit}" \
    --arg tree "${tree}" \
    --arg digest "${digest}" \
    --argjson count "${count}" \
    --argjson roots "${roots_json}" \
    --argjson contract "${contract_json}" \
    --argjson legs "${legs_json}" '
      {
        schemaVersion:2,status:$status,commit:$commit,
        checkoutHeadAtStart:$commit,checkoutHeadAtFinish:$commit,
        checkoutCleanAtStart:true,checkoutCleanAtFinish:true,
        inputSnapshotCommit:$commit,inputSnapshotTree:$tree,inputSnapshotVerified:true,
        directInputRoots:$roots,directInputSha256:$digest,directInputSha256AtFinish:$digest,
        directInputFileCount:$count,directInputRecheckedAtFinish:true,
        directInputInventory:"direct-input-inventory.sha256",harnessFileCount:1,
        legContract:$contract,legs:$legs
      }
    ' >"${report}/sit-report.json"
}

command_name="${1:-}"
shift || true
case "${command_name}" in
version)
  log 'version'
  if [ "${NSC_SHIM_FAIL_STAGE:-}" = 'wrong-nsc-version' ]; then
    cat <<'WRONG_VERSION'
version v0.0.531 (commit 0000000000000000000000000000000000000000)
WRONG_VERSION
  else
    cat <<'VERSION'
version v0.0.532 (commit 8fd20e2be4ee9d72b1357fa6f8ff2e15629abc96)
  commit date 2026-07-06T06:09:45Z
  architecture linux/amd64
VERSION
  fi
  ;;
create)
  log "create"$'\t'"$(printf '%q ' "$@")"
  cid=''
  metadata=''
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" != '--cidfile' ] || cid="${args[i + 1]:-}"
    [ "${args[i]}" != '--output_json_to' ] || metadata="${args[i + 1]:-}"
  done
  expected=(
    --ephemeral --duration 2h --machine_type 16x32 --enable=kubernetes:1.33
    --wait_kube_system --label ratchet-node=fleet --label ratchet-generation=15
    --purpose 'fleet full L0-L9 Namespace built-in-k3s proof'
    --cidfile "${cid}" --output json --output_json_to "${metadata}"
  )
  [ "${#args[@]}" -eq "${#expected[@]}" ] || {
    echo 'shim: create argv length drifted' >&2
    exit 40
  }
  for ((i = 0; i < ${#expected[@]}; i++)); do
    [ "${args[i]}" = "${expected[i]}" ] || {
      echo "shim: create argv drift at ${i}: ${args[i]} != ${expected[i]}" >&2
      exit 41
    }
  done
  [ -n "${cid}" ] && [ -n "${metadata}" ] || exit 42
  case "${metadata}" in
  /*) ;;
  *) exit 43 ;;
  esac
  # The generated cidfile, the full metadata receipt, and the minimal stdout are
  # three separate surfaces the client writes. Each can be mutated on its own,
  # so each is independently modelled here; the exact product audit observed the
  # cidfile carrying the same 13-character id plus trailing whitespace.
  case "${NSC_SHIM_CID_FORM:-exact}" in
  exact) printf '%s\n' "${id}" >"${cid}" ;;
  trailing-whitespace) printf '%s  \n' "${id}" >"${cid}" ;;
  # A NUL suffix is the form no read-and-compare can catch: Bash command
  # substitution drops the NUL, so these bytes read back as the exact id at a
  # length an ordinary-newline allowance accepts.
  trailing-nul) printf '%s\0' "${id}" >"${cid}" ;;
  # Two terminal newlines: accepted by a `$`-anchored shape, since Oniguruma's
  # `$` also matches before a final newline.
  trailing-newlines) printf '%s\n\n' "${id}" >"${cid}" ;;
  *)
    echo "shim: unmodeled cidfile form ${NSC_SHIM_CID_FORM:-}" >&2
    exit 45
    ;;
  esac
  cpu=16
  memory=32768
  kubernetes='1.33'
  [ "${NSC_SHIM_RECEIPT_SHAPE:-}" != 'wrong' ] || {
    cpu=4
    memory=8192
  }
  [ "${NSC_SHIM_RECEIPT_KUBERNETES:-}" != 'wrong' ] || kubernetes='1.32'
  jq -n \
    --arg id "${id}" --argjson cpu "${cpu}" --argjson memory "${memory}" \
    --arg kubernetes "${kubernetes}" '
      {
        cluster_id:$id,created:"2026-07-31T20:00:00Z",deadline:"2026-07-31T22:00:00Z",
        shape:{virtual_cpu:$cpu,memory_megabytes:$memory,machine_arch:"amd64",os:"linux"},
        kubernetes_distribution:"k3s",label:[{name:"nsc.kubernetes",value:$kubernetes}],
        service_state:[{name:"ssh",status:"READY"},{name:"kubernetes",status:"READY"}]
      }
    ' >"${metadata}"
  if [ "${NSC_SHIM_RECEIPT_ID:-}" = 'absent' ]; then
    jq 'del(.cluster_id)' "${metadata}" >"${metadata}.without-id"
    mv -- "${metadata}.without-id" "${metadata}"
  fi
  if [ "${NSC_SHIM_STDOUT_FORM:-}" = 'unparseable' ]; then
    printf 'nsc: instance ready (progress stream, not a JSON document)\n'
  else
    jq -n --arg id "${id}" '{
      api_endpoint:"fixture.compute.namespaceapis.com",cluster_id:$id,
      cluster_url:("https://cloud.namespace.so/fixture/instance/" + $id),
      ingress_domain:"fixture.nscluster.cloud",instance_id:$id
    }'
  fi
  if [ "${NSC_SHIM_FAIL_STAGE:-}" = 'create-signal' ]; then
    kill -TERM "${PPID}"
  fi
  [ "${NSC_SHIM_FAIL_STAGE:-}" != 'create-nonzero' ] || exit 44
  ;;
list)
  log 'list'
  [ "${1:-}" = '--output' ] && [ "${2:-}" = 'json' ] && [ "$#" -eq 2 ] || {
    echo 'shim: list must use exactly --output json' >&2
    exit 52
  }
  [ ! -t 0 ] && [ ! -t 1 ] || {
    echo 'shim: list must run with direct non-TTY stdin and stdout' >&2
    exit 53
  }
  printf 'fixture direct-list stderr\n' >&2
  # Per-call counter, so a lane liveness re-proof can be scripted independently
  # of the pre-use proof, and so the date shim can arm on list events.
  list_calls=0
  [ ! -f "${state}/list-calls" ] || list_calls="$(cat "${state}/list-calls")"
  list_calls=$((list_calls + 1))
  printf '%s\n' "${list_calls}" >"${state}/list-calls"
  # Scripted liveness outcomes for the lane, applied only AFTER the given call
  # ordinal so the pre-use liveness proof still succeeds and the lane is really
  # entered. `empty-array` is a schema-valid POSITIVE proof of absence, which is
  # the only condition that may be read as instance loss; every other form here
  # is uncertainty and must never reach that class.
  if [ -f "${state}/destroyed" ]; then
    :
  elif [ -n "${NSC_SHIM_LIVENESS_FORM_AFTER:-}" ] &&
    [ "${list_calls}" -gt "${NSC_SHIM_LIVENESS_FORM_AFTER}" ]; then
    emit_list_form "${NSC_SHIM_LIVENESS_FORM:?}"
    exit "${NSC_SHIM_LIVENESS_STATUS:-0}"
  fi
  if [ -f "${state}/destroyed" ]; then
    if [ "${NSC_SHIM_FAIL_STAGE:-}" = 'absence' ]; then
      emit_list_form array
    else
      emit_list_form "${NSC_SHIM_AFTER_DESTROY_LIST_FORM:-null}"
    fi
    exit 0
  fi
  emit_list_form "${NSC_SHIM_LIST_FORM:-array}"
  ;;
destroy)
  log "destroy"$'\t'"${1:-}"$'\t'"${2:-}"
  [ "${1:-}" = "${id}" ] && [ "${2:-}" = '--force' ] && [ "$#" -eq 2 ] || {
    echo 'shim: destroy must target only the exact id with --force' >&2
    exit 50
  }
  [ "${NSC_SHIM_FAIL_STAGE:-}" != 'destroy' ] || exit 51
  : >"${state}/destroyed"
  ;;
ssh)
  log "ssh"$'\t'"$(printf '%q ' "$@")"
  [ "${1:-}" = '--disable-pty' ] || exit 60
  shift
  [ "${1:-}" = "${id}" ] || exit 61
  shift
  [ "${1:-}" = '--' ] || {
    echo 'shim: nsc ssh requires -- before the remote command' >&2
    exit 68
  }
  shift
  [ "$#" -gt 0 ] || {
    echo 'shim: nsc ssh remote command is empty after --' >&2
    exit 69
  }
  # nsc v0.0.532 InlineSsh (internal/cli/cmd/cluster/ssh.go) puts the remote
  # program on the wire as strings.Join(args, " "), and the remote login shell
  # re-parses that one string. The client-side argv boundary therefore never
  # reaches the instance, so this fake client must not dispatch on it: build the
  # joined string exactly as nsc does, classify whether the join was lossless,
  # then drop the original argv so nothing below can be blessed by a boundary
  # the real remote side cannot observe.
  remote_argc="$#"
  remote_command="$(printf '%s ' "$@")"
  remote_command="${remote_command% }"
  # An argument survives the join only as a bare word; anything holding
  # whitespace or shell syntax gets re-split remotely. Every legitimate
  # multi-argument call the wrapper makes (hostname, the env/bash inner run) is
  # bare, so a non-bare argument sent alongside others means the join already
  # destroyed the program the wrapper intended.
  remote_join_lossy=0
  if [ "${remote_argc}" -gt 1 ]; then
    for remote_arg in "$@"; do
      case "${remote_arg}" in
      '' | *[!A-Za-z0-9_@%+=:,./-]*) remote_join_lossy=1 ;;
      esac
    done
  fi
  set --
  if [ "${remote_join_lossy}" -eq 1 ]; then
    # Model the loss rather than assert against it, so the fixture reproduces
    # the retained live failure instead of inventing a shim-only refusal. The
    # only lossy shape the wrapper has ever produced is `sh <flags> -c <program>`:
    # after the join the remote shell hands `sh` just the first word of the
    # program as its -c operand. The setup program now begins with `apk` and the
    # archive program with `test`; both exit 1 with no operands, and nsc renders
    # that as its generic remote status report.
    case "${remote_command}" in
    'sh '*' -c '*)
      remote_operand="${remote_command#*' -c '}"
      remote_operand="${remote_operand%%' '*}"
      case "${remote_operand}" in
      test | apk) ;;
      *)
        echo "shim: unmodeled joined sh -c operand: ${remote_operand}" >&2
        exit 75
        ;;
      esac
      printf '\n========================================\n' >&2
      printf 'Failed: Process exited with status 1\n' >&2
      printf '========================================\n\n' >&2
      exit 1
      ;;
    *)
      echo "shim: unmodeled lossy ssh serialization: ${remote_command}" >&2
      exit 75
      ;;
    esac
  fi
  # The stock instance answers as BusyBox v1.37.0 until the setup command's
  # leading package install replaces sha256sum with GNU coreutils. Model the
  # retained refusal only when that bootstrap is absent. The decisive lines
  # reproduce the retained stderr
  # of fleet-g11-live-6ae04f0-20260801T082535Z: the applet refusal, the version
  # and usage banner, and nsc's generic remote status block. nsc's trailing
  # docs footer is deliberately not reproduced — it is client boilerplate, not
  # part of the failure signature — so this is not full-byte equality, and the
  # command-packing model above omits it for the same reason.
  case "${remote_command}" in
  *'apk add --no-cache coreutils findutils sed grep gawk'*'sha256sum --check'*) ;;
  *'sha256sum --check'*)
    printf "sha256sum: unrecognized option '--check'\n" >&2
    printf 'BusyBox v1.37.0 (2026-05-22 13:39:12 UTC) multi-call binary.\n\n' >&2
    printf 'Usage: sha256sum [-c[sw]] [FILE]...\n\n' >&2
    printf 'Print or check SHA256 checksums\n\n' >&2
    printf '\t-c\tCheck sums against list in FILEs\n' >&2
    printf "\t-s\tDon't output anything, status code shows success\n" >&2
    printf '\t-w\tWarn about improperly formatted checksum lines\n\n' >&2
    printf '========================================\n' >&2
    printf 'Failed: Process exited with status 1\n' >&2
    printf '========================================\n\n' >&2
    exit 1
    ;;
  esac
  case "${remote_command}" in
  hostname)
    # The shim is a fresh process per call, so per-call scripting needs a
    # counter file. It is also what the date shim arms against.
    hostname_calls=0
    [ ! -f "${state}/hostname-calls" ] || hostname_calls="$(cat "${state}/hostname-calls")"
    hostname_calls=$((hostname_calls + 1))
    printf '%s\n' "${hostname_calls}" >"${state}/hostname-calls"
    if [ "${NSC_SHIM_FAIL_STAGE:-}" = 'hostname' ]; then
      printf 'wronghostname00\n'
      exit 0
    fi
    # Byte-exactness corpus. Bytes are supplied as an escaped string and emitted
    # with %b so a fixture can inject padding, extra lines, CR, tabs, internal
    # whitespace or empty stdout exactly. Paired with a nonzero status this is
    # what proves the lane keys on EXACT bytes and cannot be widened into "any
    # failing call retries".
    if [ -n "${NSC_SHIM_HOSTNAME_BYTES:-}" ]; then
      printf '%b' "${NSC_SHIM_HOSTNAME_BYTES//@ID@/${id}}"
      exit "${NSC_SHIM_HOSTNAME_STATUS:-137}"
    fi
    if [ "${NSC_SHIM_HOSTNAME_EMPTY:-0}" -eq 1 ]; then
      exit "${NSC_SHIM_HOSTNAME_STATUS:-137}"
    fi
    # Model the exact generation-13 signature: correct hostname bytes on stdout,
    # then a client that fails to terminate and is killed by the wrapper's hard
    # timeout. The status the wrapper observes for a TERM/KILL is 124/137, so the
    # fixture reports one of those rather than inventing a code. The shim never
    # actually blocks here — real waiting scaled to the ratified 60s bound is
    # forbidden, and the bound's real mechanism is proven separately by the
    # extracted-function case below.
    if [ "${hostname_calls}" -le "${NSC_SHIM_SSH_HANG_CALLS:-0}" ]; then
      printf '%s\n' "${id}"
      printf 'timeout: sending signal TERM to command \xe2\x80\x98nsc\xe2\x80\x99\n' >&2
      exit "${NSC_SHIM_SSH_HANG_STATUS:-137}"
    fi
    printf '%s\n' "${id}"
    ;;
  *'apk add --no-cache coreutils findutils sed grep gawk'*source.tgz*'| sha256sum --check')
    # Only the exact GNU-first bootstrap reaches the happy path. A missing
    # bootstrap falls into the BusyBox refusal above, and every other checksum
    # spelling falls through to the unmodeled branch and fails closed.
    #
    # The setup program holds spaces and quotes, so the wrapper must pack it as
    # exactly one remote argument for the join to preserve its bytes.
    [ "${remote_argc}" -eq 1 ] || {
      echo 'shim: the setup program must be one remote argument after --' >&2
      exit 76
    }
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'setup' ] || exit 62
    # Model the remote program's own predicates, in its order, from the joined
    # string. The instance restores the archive's recorded owner unless the
    # extraction declines to; a session whose euid differs from that owner then
    # meets git's ownership refusal on the transferred tree. Reproducing that
    # here is what stops a bare extraction from being blessed offline.
    setup_owner_neutral=''
    case "${remote_command}" in
    *'tar -o -xzf'*) setup_owner_neutral=1 ;;
    *'tar -xzf'*) setup_owner_neutral=0 ;;
    *)
      echo 'shim: unmodeled remote source extraction' >&2
      exit 77
      ;;
    esac
    case "${remote_command}" in
    *"rev-parse --git-dir"*) ;;
    *)
      echo 'shim: the setup program does not prove the transferred tree is a git checkout' >&2
      exit 78
      ;;
    esac
    mkdir -p "${state}/remote/result"
    tar -xzf "${state}/source.tgz" -C "${state}/remote"
    if [ "${setup_owner_neutral}" -eq 0 ]; then
      # Recover the exact remote path the program probes, so the modeled refusal
      # names the same directory the real one would.
      setup_source_path="${remote_command#*git -C \'}"
      setup_source_path="${setup_source_path%%\'*}"
      printf "fatal: detected dubious ownership in repository at '%s'\n" "${setup_source_path}" >&2
      printf 'To add an exception for this directory, call:\n\n' >&2
      printf "\tgit config --global --add safe.directory %s\n\n" "${setup_source_path}" >&2
      printf '========================================\n' >&2
      printf 'Failed: Process exited with status 128\n' >&2
      printf '========================================\n\n' >&2
      exit 128
    fi
    printf 'source.tgz: OK\n'
    ;;
  env\ *--inner)
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'inner' ] || exit 63
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'wrong-k3s' ] || {
      echo 'built-in k3s version must be v1.33.1+k3s1, found v1.32.0+k3s1' >&2
      exit 64
    }
    # Read the inner environment back out of the joined string, not out of the
    # original argv: the instance only ever sees these words after the join.
    expected_head="${remote_command#*FLEET_SIT_EXPECTED_HEAD=}"
    expected_head="${expected_head%%' '*}"
    [[ ${expected_head} =~ ^[0-9a-f]{40}$ ]] || exit 65
    write_synthetic_report "${expected_head}"
    ;;
  *sit-report.tgz*)
    # Same packing contract as setup: one remote argument after --.
    [ "${remote_argc}" -eq 1 ] || {
      echo 'shim: the archive program must be one remote argument after --' >&2
      exit 76
    }
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'archive' ] || exit 66
    tar -czf "${state}/sit-report.tgz" -C "${state}/remote/result" sit-report
    sha256sum "${state}/sit-report.tgz" | sed 's#  .*#  /tmp/fleet-sit-fixture/result/sit-report.tgz#'
    ;;
  *)
    echo "shim: unmodeled ssh remote command: ${remote_command}" >&2
    exit 67
    ;;
  esac
  ;;
instance)
  subcommand="${1:-}"
  shift || true
  case "${subcommand}" in
  upload)
    log "upload"$'\t'"$(printf '%q ' "$@")"
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'upload' ] || exit 70
    [ "${1:-}" = "${id}" ] && [ "${4:-}" = '--mkdir' ] || exit 71
    cp -- "${2}" "${state}/source.tgz"
    ;;
  download)
    log "download"$'\t'"$(printf '%q ' "$@")"
    [ "${NSC_SHIM_FAIL_STAGE:-}" != 'download' ] || exit 72
    [ "${1:-}" = "${id}" ] || exit 73
    cp -- "${state}/sit-report.tgz" "${3}"
    ;;
  *) exit 74 ;;
  esac
  ;;
*)
  echo "shim: unsupported nsc command ${command_name}" >&2
  exit 80
  ;;
esac
NSL_NSC_SHIM
  chmod +x "${nsl_bin}/nsc"

  nsl_id='abcdefghijklm'
  nsl_status=0
  nsl_report=''
  nsl_state=''
  nsl_run() {
    local name="$1" expected="$2"
    shift 2
    nsl_state="${nsl_root}/cases/${name}/state"
    nsl_report="${nsl_root}/cases/${name}/report"
    mkdir -p "${nsl_state}"
    nsl_status=0
    env \
      PATH="${nsl_bin}:${PATH}" \
      NSC_SHIM_STATE="${nsl_state}" \
      NSC_SHIM_ID="${nsl_id}" \
      NSC_SHIM_REAL_GREP="${nsl_real_grep}" \
      NSL_REAL_DATE="${nsl_real_date}" \
      FLEET_SIT_REPORT="${nsl_report}" \
      "$@" \
      bash "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh" --full \
      >"${nsl_root}/cases/${name}/stdout.txt" \
      2>"${nsl_root}/cases/${name}/stderr.txt" || nsl_status=$?
    # Retain the observed wrapper process status as an artifact, not just as a
    # transient variable. The reserved lane terminals are distinguished from an
    # ordinary refusal by status alone, so that number is evidence in its own
    # right and must survive the case rather than only being asserted on.
    printf '%s\n' "${nsl_status}" >"${nsl_root}/cases/${name}/wrapper.exit-status"
    if [ "${expected}" = 'pass' ]; then
      [ "${nsl_status}" -eq 0 ] ||
        fail "Namespace lifecycle ${name}: expected pass, got ${nsl_status}: $(tr '\n' ' ' <"${nsl_root}/cases/${name}/stderr.txt")"
    else
      [ "${nsl_status}" -ne 0 ] || fail "Namespace lifecycle ${name}: expected refusal"
    fi
  }

  nsl_assert_exact_destroy() {
    local name="$1"
    local expected_id="${2:-${nsl_id}}"
    grep -qxF $'destroy\t'"${expected_id}"$'\t--force' "${nsl_state}/calls.log" ||
      fail "Namespace lifecycle ${name}: no exact-id destroy --force attempt was recorded"
    if grep '^destroy' "${nsl_state}/calls.log" | grep -vFx $'destroy\t'"${expected_id}"$'\t--force' >/dev/null; then
      fail "Namespace lifecycle ${name}: a non-exact destructive selector was attempted"
    fi
  }

  nsl_assert_failed_lifecycle() {
    local name="$1"
    test -s "${nsl_report}/lifecycle/lifecycle.json" ||
      fail "Namespace lifecycle ${name}: failed run retained no lifecycle receipt"
    jq -e '
      .status == "fail" and
      .cleanup.destroyAttempts >= 1 and
      (.passLaw | contains("pass is impossible"))
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: failed receipt claimed completion or omitted cleanup"
  }

  # Prepare-only runs the real production wrapper from a committed fixture and
  # must never even resolve nsc through PATH.
  nsl_prepare_state="${nsl_root}/prepare-state"
  mkdir -p "${nsl_prepare_state}"
  env PATH="${nsl_bin}:${PATH}" NSC_SHIM_STATE="${nsl_prepare_state}" NSC_SHIM_ID="${nsl_id}" \
    NSC_SHIM_REAL_GREP="${nsl_real_grep}" \
    FLEET_SIT_REPORT="${nsl_root}/prepare-report" \
    bash "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh" --prepare-only \
    >"${nsl_root}/prepare.stdout" 2>"${nsl_root}/prepare.stderr" ||
    fail "Namespace prepare-only fixture failed: $(tr '\n' ' ' <"${nsl_root}/prepare.stderr")"
  test ! -e "${nsl_prepare_state}/calls.log" ||
    fail 'prepare-only created, listed, used, or destroyed a Namespace instance'

  nsl_run success pass
  mapfile -t nsl_success_ssh_calls < <(grep '^ssh' "${nsl_state}/calls.log")
  [ "${#nsl_success_ssh_calls[@]}" -eq 4 ] ||
    fail 'successful Namespace lifecycle did not exercise all four production ssh calls'
  for nsl_success_ssh_call in "${nsl_success_ssh_calls[@]}"; do
    if [[ ${nsl_success_ssh_call} != $'ssh\t'"--disable-pty ${nsl_id} -- "* ]]; then
      fail "successful Namespace lifecycle observed an ssh call without the exact separator position: ${nsl_success_ssh_call}"
    fi
  done
  jq -e '
    .status == "pass" and
    .namespace.createdByHarness == true and
    .namespace.recoveredIdSurface == "cidfile" and
    (.namespace.createArgvSha256 | test("^[0-9a-f]{64}$")) and
    (.namespace.createReceiptSha256 | test("^[0-9a-f]{64}$")) and
    .namespace.createReceipt == "lifecycle/create.json" and
    .namespace.createStdout == "lifecycle/create.stdout" and
    (.namespace.createStdoutSha256 | test("^[0-9a-f]{64}$")) and
    .namespace.createStderr == "lifecycle/create.stderr" and
    (.namespace.createStderrSha256 | test("^[0-9a-f]{64}$")) and
    .namespace.createCid == "lifecycle/create.cid" and
    (.namespace.createCidSha256 | test("^[0-9a-f]{64}$")) and
    .namespace.createArgv == "lifecycle/create-argv.json" and
    .innerReport.collected == true and .innerReport.validated == true and
    .cleanup.destroySucceeded == true and .cleanup.exactIdAbsenceProven == true and
    .timings.setup.startedEpoch > 0 and .timings.setup.finishedEpoch >= .timings.setup.startedEpoch and
    .failureStage == "complete"
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'successful Namespace lifecycle receipt is not bound through report validation, setup, destroy, and absence'
  for nsl_artifact in createReceipt createStdout createStderr createCid createArgv; do
    nsl_artifact_path="$(jq -r --arg field "${nsl_artifact}" '.namespace[$field]' \
      "${nsl_report}/lifecycle/lifecycle.json")"
    nsl_artifact_sha="$(jq -r --arg field "${nsl_artifact}Sha256" '.namespace[$field]' \
      "${nsl_report}/lifecycle/lifecycle.json")"
    [ -e "${nsl_report}/${nsl_artifact_path}" ] &&
      [ "$(sha256sum -- "${nsl_report}/${nsl_artifact_path}" | awk '{print $1}')" = "${nsl_artifact_sha}" ] ||
      fail "successful Namespace lifecycle ${nsl_artifact} hash does not bind its retained bytes"
  done
  jq -e --arg cid "${nsl_report}/lifecycle/create.cid" \
    --arg metadata "${nsl_report}/lifecycle/create.json" '
    .executable == "nsc" and .subcommand == "create" and
    .source == "outer-wrapper" and
    .argv == [
      "--ephemeral","--duration","2h","--machine_type","16x32",
      "--enable=kubernetes:1.33","--wait_kube_system",
      "--label","ratchet-node=fleet","--label","ratchet-generation=15",
      "--purpose","fleet full L0-L9 Namespace built-in-k3s proof",
      "--cidfile",$cid,"--output","json","--output_json_to",$metadata
    ]
  ' "${nsl_report}/lifecycle/create-argv.json" >/dev/null ||
    fail 'successful Namespace lifecycle did not retain its exact structured create argv'
  grep -qxF "${nsl_id}" "${nsl_report}/lifecycle/create.cid" ||
    fail 'successful Namespace lifecycle did not retain the exact cidfile bytes'
  test -e "${nsl_report}/lifecycle/create.stderr" ||
    fail 'successful Namespace lifecycle did not retain create stderr'
  jq -e --arg id "${nsl_id}" '
    .cluster_id == $id and .instance_id == $id and
    has("shape") == false and has("service_state") == false
  ' "${nsl_report}/lifecycle/create.stdout" >/dev/null ||
    fail 'successful Namespace lifecycle did not retain the minimal create stdout separately'
  jq -e --arg id "${nsl_id}" '
    .cluster_id == $id and .shape.virtual_cpu == 16 and
    .shape.memory_megabytes == 32768 and
    .kubernetes_distribution == "k3s" and
    any(.label[]?; .name == "nsc.kubernetes" and .value == "1.33") and
    any(.service_state[]?; .name == "ssh" and .status == "READY") and
    any(.service_state[]?; .name == "kubernetes" and .status == "READY")
  ' "${nsl_report}/lifecycle/create.json" >/dev/null ||
    fail 'successful Namespace lifecycle did not retain the full metadata receipt separately'
  nsl_assert_exact_destroy success

  # The ordinary path pins the live interface itself: one nonempty array before
  # first use, one JSON null after exact destroy, and byte-identical retained raw
  # and validated files. Stderr is a separate capture even when stdout is valid.
  nsl_list_before="${nsl_report}/lifecycle/list-before-use.json"
  nsl_list_after="${nsl_report}/lifecycle/destroy-attempt-1/list-after-destroy-1.json"
  nsl_success_list_before="${nsl_list_before}"
  for nsl_listing in "${nsl_list_before}" "${nsl_list_after}"; do
    test -s "${nsl_listing}" && test -e "${nsl_listing}.raw" &&
      test -e "${nsl_listing}.stderr" ||
      fail 'successful Namespace lifecycle did not retain list JSON, raw stdout, and stderr separately'
    cmp -s "${nsl_listing}.raw" "${nsl_listing}" ||
      fail 'successful Namespace lifecycle rewrote the direct list JSON bytes'
    grep -qxF 'fixture direct-list stderr' "${nsl_listing}.stderr" ||
      fail 'successful Namespace lifecycle did not keep list stderr out of raw stdout'
  done
  jq -e --arg id "${nsl_id}" '
    type == "array" and length == 1 and .[0].cluster_id == $id
  ' "${nsl_list_before}" >/dev/null ||
    fail 'successful Namespace lifecycle pre-use list is not the live-shaped nonempty array'
  jq -e '. == null' "${nsl_list_after}" >/dev/null ||
    fail 'successful Namespace lifecycle post-destroy list is not JSON null'

  nsl_assert_closed_cleanup() {
    local name="$1"
    nsl_assert_exact_destroy "${name}"
    nsl_assert_failed_lifecycle "${name}"
    jq -e '
      .cleanup.destroySucceeded == true and
      .cleanup.exactIdAbsenceProven == true
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: refusal did not finish exact destroy and null absence proof"
  }

  nsl_assert_list_boundary_refusal() {
    local name="$1" reason="$2"
    local listing="${nsl_report}/lifecycle/list-before-use.json"
    nsl_assert_closed_cleanup "${name}"
    test -e "${listing}.raw" && test -e "${listing}.stderr" ||
      fail "Namespace lifecycle ${name}: rejected list did not retain raw stdout and stderr"
    test ! -e "${listing}" ||
      fail "Namespace lifecycle ${name}: rejected raw list bytes reached the validated output"
    grep -qxF 'fixture direct-list stderr' "${listing}.stderr" ||
      fail "Namespace lifecycle ${name}: list stderr was not retained separately"
    grep -qF "${reason}" "${nsl_root}/cases/${name}/stderr.txt" ||
      fail "Namespace lifecycle ${name}: expected list refusal reason was not emitted"
  }

  nsl_assert_single_live_label_delta() {
    local name="$1" key="$2" wrong_value="$3" reviewed_value="$4"
    local listing="${nsl_report}/lifecycle/list-before-use.json"
    if ! { test -s "${listing}" && cmp -s "${listing}.raw" "${listing}"; }; then
      fail "Namespace lifecycle ${name}: live-label fixture did not cross the validated direct-list boundary intact"
    fi
    jq -e \
      --arg key "${key}" \
      --arg wrongValue "${wrong_value}" \
      --arg reviewedValue "${reviewed_value}" \
      --slurpfile reviewedListing "${nsl_success_list_before}" '
        type == "array" and length == 1 and
        .[0].labels[$key] == $wrongValue and
        (. as $actual |
          ($actual | .[0].labels[$key] = $reviewedValue) == $reviewedListing[0])
      ' "${listing}" >/dev/null ||
      fail "Namespace lifecycle ${name}: the fixture changed more than its one stale live label"
  }

  nsl_assert_live_label_refusal() {
    local name="$1" key="$2" wrong_value="$3" reviewed_value="$4"
    nsl_assert_closed_cleanup "${name}"
    nsl_assert_single_live_label_delta \
      "${name}" "${key}" "${wrong_value}" "${reviewed_value}"
    grep -qxF \
      'fleet SIT proof failed: live Namespace instance disagrees with exact id, labels, or reviewed shape' \
      "${nsl_root}/cases/${name}/stderr.txt" ||
      fail "Namespace lifecycle ${name}: exact live-disagreement diagnostic was not emitted"
    jq -e '. == null' "${nsl_report}/lifecycle/list-after-destroy.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: exact-id cleanup retained no JSON-null absence proof"
  }

  nsl_run list-empty fail NSC_SHIM_LIST_FORM=empty
  nsl_assert_list_boundary_refusal list-empty 'nsc list returned empty stdout'
  test ! -s "${nsl_report}/lifecycle/list-before-use.json.raw" ||
    fail 'Namespace lifecycle list-empty fixture emitted nonempty stdout'

  nsl_run list-nonzero-valid fail NSC_SHIM_LIST_FORM=nonzero-valid
  nsl_assert_list_boundary_refusal \
    list-nonzero-valid 'nsc list exited 29; refusing its retained stdout'
  jq -e --arg id "${nsl_id}" '
    type == "array" and any(.[]; .cluster_id == $id)
  ' "${nsl_report}/lifecycle/list-before-use.json.raw" >/dev/null ||
    fail 'Namespace lifecycle nonzero-list fixture did not retain its valid-looking partial stdout'

  nsl_run list-multiple-values fail NSC_SHIM_LIST_FORM=multiple
  nsl_assert_list_boundary_refusal \
    list-multiple-values 'nsc list stdout is not exactly one JSON null or array value'
  jq -e -s --arg id "${nsl_id}" '
    length == 2 and all(.[]; type == "array" and any(.[]; .cluster_id == $id))
  ' "${nsl_report}/lifecycle/list-before-use.json.raw" >/dev/null ||
    fail 'Namespace lifecycle multiple-list fixture is not two success-shaped arrays'

  nsl_run list-malformed fail NSC_SHIM_LIST_FORM=malformed
  nsl_assert_list_boundary_refusal \
    list-malformed 'nsc list stdout is not exactly one JSON null or array value'
  if jq -e -s . "${nsl_report}/lifecycle/list-before-use.json.raw" >/dev/null 2>&1; then
    fail 'Namespace lifecycle malformed-list fixture unexpectedly parses as complete JSON'
  fi

  nsl_run list-escape fail NSC_SHIM_LIST_FORM=escape
  nsl_assert_list_boundary_refusal list-escape 'nsc list stdout contains an ESC byte'
  LC_ALL=C grep -q $'\033' "${nsl_report}/lifecycle/list-before-use.json.raw" ||
    fail 'Namespace lifecycle escape-list fixture contains no literal ESC byte'

  nsl_run list-invalid-utf8 fail NSC_SHIM_LIST_FORM=invalid-utf8
  nsl_assert_list_boundary_refusal list-invalid-utf8 'nsc list stdout is not valid UTF-8'
  nsl_invalid_utf8_raw="${nsl_report}/lifecycle/list-before-use.json.raw"
  nsl_invalid_utf8_count="$(od -An -tx1 -v "${nsl_invalid_utf8_raw}" |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "ff") count++ } END { print count + 0 }')"
  [ "${nsl_invalid_utf8_count}" -eq 1 ] ||
    fail 'Namespace lifecycle invalid-UTF-8 fixture does not contain exactly one raw 0xff byte'
  if iconv -f UTF-8 -t UTF-8 "${nsl_invalid_utf8_raw}" >/dev/null 2>&1; then
    fail 'Namespace lifecycle invalid-UTF-8 fixture is accepted by the checked iconv boundary'
  fi
  jq -e -s --arg id "${nsl_id}" '
    length == 1 and
    (.[0] | type) == "array" and
    .[0][0].cluster_id == $id and
    (.[0][0].ignored | type) == "string"
  ' "${nsl_invalid_utf8_raw}" >/dev/null ||
    fail 'jq alone no longer accepts the success-shaped raw 0xff fixture, so the regression test is not specific'

  nsl_uncertain_listing=''
  nsl_assert_unproven_absence() {
    local name="$1"
    local attempt
    nsl_assert_exact_destroy "${name}"
    nsl_assert_failed_lifecycle "${name}"
    jq -e '
      .failureStage == "exact-id-destroy-and-absence" and
      .cleanup.destroySucceeded == true and
      .cleanup.exactIdAbsenceProven == false
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: schema uncertainty became exact-id absence"
    attempt="$(jq -r '.cleanup.destroyAttempts' \
      "${nsl_report}/lifecycle/lifecycle.json")"
    [[ ${attempt} =~ ^[1-9][0-9]*$ ]] ||
      fail "Namespace lifecycle ${name}: cleanup attempt count is invalid"
    nsl_uncertain_listing="${nsl_report}/lifecycle/destroy-attempt-${attempt}/list-after-destroy-10.json"
    test -s "${nsl_uncertain_listing}.raw" &&
      test -e "${nsl_uncertain_listing}.stderr" ||
      fail "Namespace lifecycle ${name}: uncertain absence bytes were not retained"
    test ! -e "${nsl_uncertain_listing}" ||
      fail "Namespace lifecycle ${name}: uncertain absence bytes reached the validated output"
  }

  nsl_assert_schema_fixture() {
    local form="$1" raw="$2"
    jq -e -s --arg form "${form}" --arg target "${nsl_id}" '
      def selector_safe_id:
        type == "string" and test("\\A[a-z0-9]{13,14}\\z");
      def reviewed_labels:
        type == "object" and all(.[]; type == "string");
      def reviewed_shape:
        type == "object" and
        (.virtual_cpu | type) == "number" and
        (.memory_megabytes | type) == "number" and
        (.machine_arch | type) == "string" and
        (.os | type) == "string";
      def one_row:
        length == 1 and (.[0] | type) == "array" and (.[0] | length) == 1;
      if $form == "top-object" then
        length == 1 and (.[0] | type) == "object" and (.[0] | length) == 0
      elif $form == "multiple-null" then
        length == 2 and all(.[]; . == null)
      elif $form == "scalar-row" then
        length == 1 and .[0] == [null]
      elif $form == "duplicate-id" then
        length == 1 and (.[0] | type) == "array" and (.[0] | length) == 2 and
        .[0][0].cluster_id == .[0][1].cluster_id and
        .[0][0].cluster_id != $target and
        all(.[0][];
          (type == "object") and
          (.cluster_id | selector_safe_id) and
          (.labels | reviewed_labels) and
          (.shape | reviewed_shape))
      elif one_row then
        .[0][0] as $row |
        if $form == "missing-id" then
          ($row | type) == "object" and
          ($row | has("cluster_id") | not) and
          ($row.labels | reviewed_labels) and ($row.shape | reviewed_shape)
        elif $form == "null-id" then
          $row.cluster_id == null and
          ($row.labels | reviewed_labels) and ($row.shape | reviewed_shape)
        elif $form == "numeric-id" then
          ($row.cluster_id | type) == "number" and
          ($row.labels | reviewed_labels) and ($row.shape | reviewed_shape)
        elif ($form | startswith("unsafe-id")) then
          ($row.cluster_id | type) == "string" and
          ($row.cluster_id | selector_safe_id | not) and
          ($row.labels | reviewed_labels) and ($row.shape | reviewed_shape)
        elif $form == "labels-scalar" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | type) == "string" and ($row.shape | reviewed_shape)
        elif $form == "labels-numeric" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | type) == "object" and
          ($row.labels["ratchet-node"] | type) == "number" and
          ($row.shape | reviewed_shape)
        elif $form == "shape-scalar" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | reviewed_labels) and ($row.shape | type) == "string"
        elif $form == "shape-cpu-string" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | reviewed_labels) and ($row.shape | type) == "object" and
          ($row.shape.virtual_cpu | type) == "string" and
          ($row.shape.memory_megabytes | type) == "number" and
          ($row.shape.machine_arch | type) == "string" and
          ($row.shape.os | type) == "string"
        elif $form == "shape-memory-string" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | reviewed_labels) and ($row.shape | type) == "object" and
          ($row.shape.virtual_cpu | type) == "number" and
          ($row.shape.memory_megabytes | type) == "string" and
          ($row.shape.machine_arch | type) == "string" and
          ($row.shape.os | type) == "string"
        elif $form == "shape-arch-number" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | reviewed_labels) and ($row.shape | type) == "object" and
          ($row.shape.virtual_cpu | type) == "number" and
          ($row.shape.memory_megabytes | type) == "number" and
          ($row.shape.machine_arch | type) == "number" and
          ($row.shape.os | type) == "string"
        elif $form == "shape-os-number" then
          ($row.cluster_id | selector_safe_id) and $row.cluster_id != $target and
          ($row.labels | reviewed_labels) and ($row.shape | type) == "object" and
          ($row.shape.virtual_cpu | type) == "number" and
          ($row.shape.memory_megabytes | type) == "number" and
          ($row.shape.machine_arch | type) == "string" and
          ($row.shape.os | type) == "number"
        else false
        end
      else false
      end
    ' "${raw}" >/dev/null ||
      fail "Namespace lifecycle schema fixture ${form} does not isolate its named uncertainty"
  }

  nsl_assert_schema_uncertain_absence_refusal() {
    local name="$1" form="$2"
    nsl_run "${name}" fail "NSC_SHIM_AFTER_DESTROY_LIST_FORM=${form}"
    nsl_assert_unproven_absence "${name}"
    nsl_assert_schema_fixture "${form}" "${nsl_uncertain_listing}.raw"
    grep -qF \
      'nsc list stdout is not exactly one JSON null or array value with schema-valid rows' \
      "${nsl_root}/cases/${name}/stderr.txt" ||
      fail "Namespace lifecycle ${name}: schema-valid-row refusal was not emitted"
    echo "    ${name}: destructive-path schema uncertainty refused ✓"
  }

  while IFS=$'\t' read -r nsl_schema_name nsl_schema_form; do
    nsl_assert_schema_uncertain_absence_refusal \
      "schema-absence-${nsl_schema_name}" "${nsl_schema_form}"
  done <<'NSL_SCHEMA_CASES'
missing-id	missing-id
null-id	null-id
numeric-id	numeric-id
unsafe-id	unsafe-id
unsafe-id-newline	unsafe-id-newline
unsafe-id-short	unsafe-id-short
unsafe-id-long	unsafe-id-long
scalar-row	scalar-row
labels-scalar	labels-scalar
labels-numeric	labels-numeric
shape-scalar	shape-scalar
shape-cpu-string	shape-cpu-string
shape-memory-string	shape-memory-string
shape-arch-number	shape-arch-number
shape-os-number	shape-os-number
duplicate-id	duplicate-id
top-object	top-object
multiple-values	multiple-null
NSL_SCHEMA_CASES

  nsl_run schema-absence-grep-error fail \
    NSC_SHIM_GREP_FAILURE_AFTER_DESTROY=1
  nsl_assert_unproven_absence schema-absence-grep-error
  jq -e -s 'length == 1 and .[0] == null' \
    "${nsl_uncertain_listing}.raw" >/dev/null ||
    fail 'Namespace lifecycle grep-error fixture is not a success-shaped JSON null absence'
  grep -qF 'nsc list ESC scan failed: grep exited 2' \
    "${nsl_root}/cases/schema-absence-grep-error/stderr.txt" ||
    fail 'Namespace lifecycle grep execution error was not distinguished from ordinary no-match'
  echo '    schema-absence-grep-error: grep execution failure refused after destroy ✓'

  # The emergency selector seam admits the two reviewed service shapes even
  # though first use remains pinned to 13 characters. A valid unrelated 14-byte
  # row therefore crosses the raw boundary and does not block exact-id absence.
  nsl_run schema-valid-fourteen-id pass \
    NSC_SHIM_AFTER_DESTROY_LIST_FORM=valid-14-id
  nsl_assert_exact_destroy schema-valid-fourteen-id
  nsl_valid_fourteen_listing="${nsl_report}/lifecycle/destroy-attempt-1/list-after-destroy-1.json"
  if ! { test -s "${nsl_valid_fourteen_listing}" &&
    cmp -s "${nsl_valid_fourteen_listing}.raw" "${nsl_valid_fourteen_listing}"; }; then
    fail 'Namespace lifecycle valid 14-character row did not cross the raw list boundary intact'
  fi
  jq -e -s '
    length == 1 and (.[0] | type) == "array" and (.[0] | length) == 1 and
    (.[0][0].cluster_id | test("\\A[a-z0-9]{14}\\z")) and
    (.[0][0].labels | type) == "object" and
    (.[0][0].shape.virtual_cpu | type) == "number" and
    (.[0][0].shape.memory_megabytes | type) == "number" and
    (.[0][0].shape.machine_arch | type) == "string" and
    (.[0][0].shape.os | type) == "string"
  ' "${nsl_valid_fourteen_listing}" >/dev/null ||
    fail 'Namespace lifecycle valid 14-character row lost its reviewed schema'
  echo '    schema-valid-fourteen-id: selector-safe emergency shape admitted ✓'

  # A syntactically valid array reaches the exact-id selection predicate but
  # cannot authorize first use unless it contains the one registered id.
  nsl_run list-missing-exact-id fail NSC_SHIM_LIST_FORM=missing-exact-id
  nsl_assert_closed_cleanup list-missing-exact-id
  nsl_list_before="${nsl_report}/lifecycle/list-before-use.json"
  if ! { test -s "${nsl_list_before}" &&
    cmp -s "${nsl_list_before}.raw" "${nsl_list_before}"; }; then
    fail 'Namespace lifecycle missing-id fixture did not cross the validated direct-list boundary intact'
  fi
  jq -e --arg id "${nsl_id}" '
    type == "array" and length == 1 and all(.[]; .cluster_id != $id)
  ' "${nsl_list_before}" >/dev/null ||
    fail 'Namespace lifecycle missing-id fixture accidentally contains the exact registered id'
  grep -qF 'live Namespace instance disagrees with exact id, labels, or reviewed shape' \
    "${nsl_root}/cases/list-missing-exact-id/stderr.txt" ||
    fail 'Namespace lifecycle array without the exact id was not refused before first use'

  # The exact-id live listing may be fully success-shaped yet still carry stale
  # provenance. Compare each negative fixture with the ordinary success listing
  # after correcting only the targeted label, then require the production
  # validate_live_instance diagnostic and closed exact-id cleanup.
  nsl_run wrong-live-generation fail NSC_SHIM_LIST_LABELS=wrong-generation
  nsl_assert_live_label_refusal \
    wrong-live-generation ratchet-generation 7 15
  nsl_run wrong-live-node fail NSC_SHIM_LIST_LABELS=wrong-node
  nsl_assert_live_label_refusal \
    wrong-live-node ratchet-node not-fleet fleet

  # Install deliberately guard-deleted production variants in the committed
  # lifecycle fixture. A mutant that does not alter the relevant case is a weak
  # test and fails here; no copied parser is involved.
  nsl_install_list_guard_mutant() {
    local label="$1" marker="$2"
    awk -v marker="${marker}" -v label="${label}" '
      BEGIN { found = 0; skipping = 0 }
      $0 == marker {
        found++
        print
        print "  : # lifecycle mutation removed " label
        skipping = 1
        next
      }
      skipping && $0 == "  fi" { skipping = 0; next }
      !skipping { print }
      END { if (found != 1 || skipping) exit 89 }
    ' "${nsl_proof_baseline}" >"${nsl_fixture}/scripts/ci/fleet-sit-proof.sh" ||
      fail "could not install the ${label} list-guard mutation"
    git -C "${nsl_fixture}" add scripts/ci/fleet-sit-proof.sh
    if git -C "${nsl_fixture}" diff --cached --quiet; then
      fail "the ${label} list-guard mutation changed no production bytes"
    fi
    git -C "${nsl_fixture}" commit --quiet \
      -m "Remove ${label} list guard" --only scripts/ci/fleet-sit-proof.sh
  }

  nsl_install_exact_proof_line_mutant() {
    local label="$1" clause="$2"
    local proof_path='scripts/ci/fleet-sit-proof.sh'
    local expected_stat=$'0\t1\tscripts/ci/fleet-sit-proof.sh'
    local mutation_stat
    awk -v clause="${clause}" '
      BEGIN { found = 0 }
      $0 == clause { found++; next }
      { print }
      END { if (found != 1) exit 89 }
    ' "${nsl_proof_baseline}" >"${nsl_fixture}/${proof_path}" ||
      fail "could not delete the exact ${label} production clause"
    git -C "${nsl_fixture}" add "${proof_path}"
    if git -C "${nsl_fixture}" diff --cached --quiet; then
      fail "the exact ${label} production-clause mutation changed no bytes"
    fi
    mutation_stat="$(git -C "${nsl_fixture}" diff --cached --numstat -- "${proof_path}")"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the exact ${label} mutation did not delete one production line"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "-${clause}" ||
      fail "the exact ${label} mutation deleted a different production line"
    git -C "${nsl_fixture}" commit --quiet \
      -m "Remove ${label} clause" --only "${proof_path}"
    mutation_stat="$(git -C "${nsl_fixture}" diff-tree --no-commit-id --numstat -r HEAD)"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the committed ${label} mutant changed more than one production line"
  }

  # Rewrites exactly one reviewed production line. The separator mutants, the
  # command-packing regressions, and the BusyBox checksum regression below are
  # all single-line rewrites, so they share one installer; the label carries
  # which defect is being restored.
  nsl_install_exact_line_mutant() {
    local label="$1" exact_call="$2" mutant_call="$3"
    local proof_path='scripts/ci/fleet-sit-proof.sh'
    local expected_stat=$'1\t1\tscripts/ci/fleet-sit-proof.sh'
    local mutation_stat
    # Both strings travel through the environment, not `awk -v`: -v assignments
    # are escape-processed, so a production line containing a literal backslash
    # sequence (the setup program's `printf '%s  %s\\n'`) would arrive mangled
    # and match nothing. ENVIRON values are passed through byte for byte.
    MUTATION_EXACT_LINE="${exact_call}" MUTATION_MUTANT_LINE="${mutant_call}" awk '
      BEGIN {
        exact_call = ENVIRON["MUTATION_EXACT_LINE"]
        mutant_call = ENVIRON["MUTATION_MUTANT_LINE"]
        found = 0
      }
      $0 == exact_call { found++; print mutant_call; next }
      { print }
      END { if (found != 1) exit 89 }
    ' "${nsl_proof_baseline}" >"${nsl_fixture}/${proof_path}" ||
      fail "could not install the exact ${label} production-line mutation"
    git -C "${nsl_fixture}" add "${proof_path}"
    if git -C "${nsl_fixture}" diff --cached --quiet; then
      fail "the exact ${label} production-line mutation changed no bytes"
    fi
    mutation_stat="$(git -C "${nsl_fixture}" diff --cached --numstat -- "${proof_path}")"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the exact ${label} production-line mutation did not replace one production line"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "-${exact_call}" ||
      fail "the exact ${label} production-line mutation did not remove its reviewed call"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "+${mutant_call}" ||
      fail "the exact ${label} production-line mutation inserted unexpected bytes"
    git -C "${nsl_fixture}" commit --quiet \
      -m "Rewrite ${label} production line" --only "${proof_path}"
    mutation_stat="$(git -C "${nsl_fixture}" diff-tree --no-commit-id --numstat -r HEAD)"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the committed ${label} production-line mutant changed more than one production line"
  }

  nsl_install_exact_proof_block_mutant() {
    local label="$1" start_clause="$2" end_clause="$3" deleted_count="$4"
    local proof_path='scripts/ci/fleet-sit-proof.sh'
    local expected_stat
    local mutation_stat
    expected_stat="0"$'\t'"${deleted_count}"$'\t'"${proof_path}"
    awk \
      -v start_clause="${start_clause}" \
      -v end_clause="${end_clause}" \
      -v expected_deleted="${deleted_count}" '
        BEGIN { found = 0; skipping = 0; deleted = 0 }
        !skipping && $0 == start_clause {
          found++
          skipping = 1
          deleted++
          next
        }
        skipping {
          deleted++
          if ($0 == end_clause) skipping = 0
          next
        }
        { print }
        END {
          if (found != 1 || skipping || deleted != expected_deleted) exit 89
        }
      ' "${nsl_proof_baseline}" >"${nsl_fixture}/${proof_path}" ||
      fail "could not delete the exact ${label} production block"
    git -C "${nsl_fixture}" add "${proof_path}"
    if git -C "${nsl_fixture}" diff --cached --quiet; then
      fail "the exact ${label} production-block mutation changed no bytes"
    fi
    mutation_stat="$(git -C "${nsl_fixture}" diff --cached --numstat -- "${proof_path}")"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the exact ${label} mutation did not delete ${deleted_count} production lines"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "-${start_clause}" ||
      fail "the exact ${label} mutation did not delete its opening production clause"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "-${end_clause}" ||
      fail "the exact ${label} mutation did not delete its closing production clause"
    git -C "${nsl_fixture}" commit --quiet \
      -m "Remove ${label} block" --only "${proof_path}"
    mutation_stat="$(git -C "${nsl_fixture}" diff-tree --no-commit-id --numstat -r HEAD)"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the committed ${label} mutant changed outside its exact production block"
  }

  nsl_install_live_label_guard_mutant() {
    local label="$1" clause="$2"
    local proof_path='scripts/ci/fleet-sit-proof.sh'
    local expected_stat=$'0\t1\tscripts/ci/fleet-sit-proof.sh'
    local mutation_stat
    awk -v clause="${clause}" '
      BEGIN { found = 0 }
      $0 == clause { found++; next }
      { print }
      END { if (found != 1) exit 89 }
    ' "${nsl_proof_baseline}" >"${nsl_fixture}/${proof_path}" ||
      fail "could not install the ${label} live-label guard mutation"
    git -C "${nsl_fixture}" add "${proof_path}"
    if git -C "${nsl_fixture}" diff --cached --quiet; then
      fail "the ${label} live-label guard mutation changed no production bytes"
    fi
    mutation_stat="$(git -C "${nsl_fixture}" diff --cached --numstat -- "${proof_path}")"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the ${label} live-label guard mutation did not delete exactly one production line"
    git -C "${nsl_fixture}" diff --cached --unified=0 -- "${proof_path}" |
      grep -qxF -- "-${clause}" ||
      fail "the ${label} live-label guard mutation deleted a different production line"
    git -C "${nsl_fixture}" commit --quiet \
      -m "Remove ${label} live-label guard" --only "${proof_path}"
    mutation_stat="$(git -C "${nsl_fixture}" diff-tree --no-commit-id --numstat -r HEAD)"
    [ "${mutation_stat}" = "${expected_stat}" ] ||
      fail "the committed ${label} live-label mutant changed more than one production line"
  }

  nsl_restore_list_proof() {
    cp "${nsl_proof_baseline}" "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh"
    git -C "${nsl_fixture}" add scripts/ci/fleet-sit-proof.sh
    if ! git -C "${nsl_fixture}" diff --cached --quiet; then
      git -C "${nsl_fixture}" commit --quiet \
        -m 'Restore direct list guards' --only scripts/ci/fleet-sit-proof.sh
    fi
  }

  nsl_assert_ssh_separator_refusal() {
    local name="$1" stage="$2" retained_stderr="$3"
    nsl_assert_closed_cleanup "${name}"
    jq -e --arg stage "${stage}" '.failureStage == $stage' \
      "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: missing separator did not fail at ${stage}"
    grep -qF 'shim: nsc ssh requires -- before the remote command' \
      "${nsl_report}/lifecycle/${retained_stderr}" ||
      fail "Namespace lifecycle ${name}: retained stderr did not prove nsc client-side option parsing"
    echo "    ${name}: exact production separator deletion failed closed at ${stage} ✓"
  }

  nsl_assert_ssh_packing_refusal() {
    local name="$1" stage="$2" retained_stderr="$3"
    nsl_assert_closed_cleanup "${name}"
    jq -e --arg stage "${stage}" '.failureStage == $stage' \
      "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: the unpacked remote program did not fail at ${stage}"
    grep -qF 'Failed: Process exited with status 1' \
      "${nsl_report}/lifecycle/${retained_stderr}" ||
      fail "Namespace lifecycle ${name}: retained stderr did not reproduce the live remote status-1 report"
    echo "    ${name}: split remote command string failed closed at ${stage} ✓"
  }

  # ---- SESSION-HANG lane assertions ------------------------------------
  #
  # Exit status alone is NEVER sufficient evidence here. The fake client already
  # uses internal status 75 for an unmodeled lossy ssh serialization, the same
  # number as NSC_SESSION_HANG_EXHAUSTED_STATUS. A production 75 is therefore
  # authenticated by three independent things: the status, the failure stage,
  # and the closed outcome in the receipt.
  nsl_assert_terminal_signature() {
    local name="$1" expected_status="$2" expected_stage="$3" expected_outcome="$4"
    [ "${nsl_status}" -eq "${expected_status}" ] ||
      fail "Namespace lifecycle ${name}: expected exit ${expected_status}, got ${nsl_status}: $(tr '\n' ' ' <"${nsl_root}/cases/${name}/stderr.txt")"
    test -s "${nsl_report}/lifecycle/lifecycle.json" ||
      fail "Namespace lifecycle ${name}: reserved terminal ${expected_status} retained no receipt"
    jq -e --arg stage "${expected_stage}" --arg outcome "${expected_outcome}" \
      --argjson status "${expected_status}" '
      .failureStage == $stage and
      .sessionHang.outcome == $outcome and
      .sessionHang.terminalStatus == $status
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: exit ${expected_status} was not authenticated by stage ${expected_stage} and outcome ${expected_outcome}: $(jq -c '{failureStage,sessionHang:{outcome:.sessionHang.outcome,terminalStatus:.sessionHang.terminalStatus}}' "${nsl_report}/lifecycle/lifecycle.json")"
  }

  nsl_assert_session_hang_receipt() {
    local name="$1" outcome="$2" reinvocations="$3" exhausted="$4"
    local report="${nsl_report}/lifecycle/lifecycle.json"
    test -s "${report}" ||
      fail "Namespace lifecycle ${name}: no lifecycle receipt"
    jq -e --arg outcome "${outcome}" \
      --argjson reinvocations "${reinvocations}" \
      --argjson exhausted "${exhausted}" '
        .schemaVersion == 2 and
        .sessionHang.entered == true and
        .sessionHang.outcome == $outcome and
        .sessionHang.reinvocations == $reinvocations and
        .sessionHang.maxReinvocations == 3 and
        .sessionHang.perCallTimeoutSeconds == 60 and
        .sessionHang.killAfterSeconds == 10 and
        .sessionHang.laneBudgetSeconds == 300 and
        .sessionHang.worstCaseLaneSeconds == 285 and
        .sessionHang.livenessTimeoutSeconds == 20 and
        .sessionHang.livenessKillAfterSeconds == 5 and
        .sessionHang.exhausted == ($exhausted == 1) and
        .sessionHang.consumesInstanceOrdinal == false
      ' "${report}" >/dev/null ||
      fail "Namespace lifecycle ${name}: SESSION-HANG receipt is wrong: $(jq -c '.sessionHang' "${report}")"
  }

  # Every recorded ssh row must be the bounded non-interactive form. The shim's
  # own exit 60/68/69 guards refuse a missing --disable-pty or separator at call
  # time; this asserts the RECORDED argv shape independently, so a lane that
  # smuggled in a differently-shaped call is visible in the retained evidence.
  nsl_assert_ssh_call_shape() {
    local name="$1"
    local row
    while IFS= read -r row; do
      case "${row}" in
      $'ssh\t--disable-pty '*" -- "*) ;;
      *) fail "Namespace lifecycle ${name}: an ssh call was not bounded non-interactive: ${row}" ;;
      esac
    done < <(grep '^ssh' "${nsl_state}/calls.log")
  }

  # A resolved lane and an exhausted lane each consume exactly one instance, so
  # no lane outcome may mint or destroy a second one.
  nsl_assert_single_instance_lifecycle() {
    local name="$1"
    local creates destroys
    creates="$(grep -c '^create' "${nsl_state}/calls.log" || true)"
    destroys="$(grep -c '^destroy' "${nsl_state}/calls.log" || true)"
    [ "${creates}" -eq 1 ] ||
      fail "Namespace lifecycle ${name}: expected exactly one create, found ${creates}"
    [ "${destroys}" -eq 1 ] ||
      fail "Namespace lifecycle ${name}: expected exactly one destroy, found ${destroys}"
  }

  nsl_count_ssh_calls() {
    grep -c '^ssh' "${nsl_state}/calls.log" || true
  }

  nsl_assert_busybox_checksum_refusal() {
    local name="$1"
    nsl_assert_closed_cleanup "${name}"
    jq -e '.failureStage == "snapshot-setup"' \
      "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: the GNU-only checksum spelling did not fail at snapshot-setup"
    grep -qF "sha256sum: unrecognized option '--check'" \
      "${nsl_report}/lifecycle/setup.stderr" ||
      fail "Namespace lifecycle ${name}: retained stderr lost the BusyBox unrecognized-option signature"
    grep -qF 'BusyBox v1.37.0' "${nsl_report}/lifecycle/setup.stderr" ||
      fail "Namespace lifecycle ${name}: retained stderr did not identify the refusing BusyBox applet"
    echo "    ${name}: GNU-only sha256sum --check failed closed at snapshot-setup ✓"
  }

  nsl_assert_extract_owner_refusal() {
    local name="$1"
    nsl_assert_closed_cleanup "${name}"
    jq -e '.failureStage == "snapshot-setup"' \
      "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: the bare extraction did not fail at snapshot-setup"
    grep -qF 'dubious ownership' "${nsl_report}/lifecycle/setup.stderr" ||
      fail "Namespace lifecycle ${name}: retained stderr lost the ownership diagnostic"
    grep -qF 'Failed: Process exited with status 128' \
      "${nsl_report}/lifecycle/setup.stderr" ||
      fail "Namespace lifecycle ${name}: retained stderr lost the remote git refusal status"
    echo "    ${name}: bare extraction failed closed at snapshot-setup on the ownership refusal ✓"
  }

  nsl_assert_false_absence_mutant_pass() {
    local name="$1" form="$2"
    local listing="${nsl_report}/lifecycle/destroy-attempt-1/list-after-destroy-1.json"
    nsl_assert_exact_destroy "${name}"
    jq -e '
      .status == "pass" and .failureStage == "complete" and
      .cleanup.destroySucceeded == true and
      .cleanup.exactIdAbsenceProven == true
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: deleted production clause did not reopen false absence"
    if ! { test -s "${listing}" && test -s "${listing}.raw" &&
      cmp -s "${listing}.raw" "${listing}"; }; then
      fail "Namespace lifecycle ${name}: mutant did not publish the uncertain bytes as validated absence"
    fi
    [ -z "${form}" ] ||
      nsl_assert_schema_fixture "${form}" "${listing}.raw"
    echo "    ${name}: exact production-line deletion re-opened false absence ✓"
  }

  # nsc v0.0.532 requires `--` after the instance id even when the remote
  # command begins with a non-option token. Delete only that separator at each
  # production call and require the fake client to reproduce the real
  # client-side refusal while exact cleanup and absence proof still complete.
  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    separator-hostname \
    '    nsc ssh --disable-pty "${instance_id}" -- hostname \' \
    '    nsc ssh --disable-pty "${instance_id}" hostname \'
  nsl_run mutation-ssh-separator-hostname fail
  nsl_assert_ssh_separator_refusal \
    mutation-ssh-separator-hostname hostname-preflight hostname.stderr
  nsl_restore_list_proof

  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    separator-setup \
    '    nsc ssh --disable-pty "${instance_id}" -- "${setup_command}" \' \
    '    nsc ssh --disable-pty "${instance_id}" "${setup_command}" \'
  nsl_run mutation-ssh-separator-setup fail
  nsl_assert_ssh_separator_refusal \
    mutation-ssh-separator-setup snapshot-setup setup.stderr
  nsl_restore_list_proof

  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    separator-inner \
    '    nsc ssh --disable-pty "${instance_id}" -- env \' \
    '    nsc ssh --disable-pty "${instance_id}" env \'
  nsl_run mutation-ssh-separator-inner fail
  nsl_assert_ssh_separator_refusal \
    mutation-ssh-separator-inner inner-run inner-run.log
  nsl_restore_list_proof

  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    separator-archive \
    '    nsc ssh --disable-pty "${instance_id}" -- "${archive_command}" \' \
    '    nsc ssh --disable-pty "${instance_id}" "${archive_command}" \'
  nsl_run mutation-ssh-separator-archive fail
  nsl_assert_ssh_separator_refusal \
    mutation-ssh-separator-archive remote-report-collection remote-report-archive.stderr
  nsl_restore_list_proof

  # Regression for the generation-11 live failure. nsc v0.0.532 InlineSsh joins
  # the post-separator argv with single spaces, so the pre-repair
  # `-- sh -eu -c "${program}"` form put an unquoted command string on the wire
  # and the remote `sh -c` executed only its first word. Restoring exactly that
  # line must fail at the stage the live run failed at, carrying the same
  # generic remote status-1 report, while exact cleanup and absence proof still
  # complete. The mutant text is the accepted pre-repair production line, so on
  # that baseline the installer finds no packed line to replace and this case
  # cannot pass: it is green only once both programs are packed correctly.
  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    packing-setup \
    '    nsc ssh --disable-pty "${instance_id}" -- "${setup_command}" \' \
    '    nsc ssh --disable-pty "${instance_id}" -- sh -eu -c "${setup_command}" \'
  nsl_run mutation-ssh-packing-setup fail
  nsl_assert_ssh_packing_refusal \
    mutation-ssh-packing-setup snapshot-setup setup.stderr
  nsl_restore_list_proof

  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    packing-archive \
    '    nsc ssh --disable-pty "${instance_id}" -- "${archive_command}" \' \
    '    nsc ssh --disable-pty "${instance_id}" -- sh -eu -c "${archive_command}" \'
  nsl_run mutation-ssh-packing-archive fail
  nsl_assert_ssh_packing_refusal \
    mutation-ssh-packing-archive remote-report-collection remote-report-archive.stderr
  nsl_restore_list_proof

  # The GNU bootstrap is load-bearing. Remove only its leading install from the
  # reviewed setup line: the unchanged --check then reaches stock BusyBox and
  # reproduces the generation-11 refusal at snapshot-setup, with cleanup and
  # exact absence still complete.
  # shellcheck disable=SC2016 # remove the literal guest-side variable reference.
  nsl_gnu_setup_prefix='apk add --no-cache ${NSC_GNU_BOOTSTRAP_PACKAGES} && '
  nsl_setup_without_gnu="${nsl_setup_program_line/"${nsl_gnu_setup_prefix}"/}"
  [ "${nsl_setup_without_gnu}" != "${nsl_setup_program_line}" ] ||
    fail 'could not derive the missing-GNU-bootstrap mutant from the setup program'
  nsl_install_exact_line_mutant \
    gnu-bootstrap-setup \
    "${nsl_setup_program_line}" \
    "${nsl_setup_without_gnu}"
  nsl_run mutation-setup-missing-gnu-bootstrap fail
  nsl_assert_busybox_checksum_refusal mutation-setup-missing-gnu-bootstrap
  nsl_restore_list_proof

  # Regression for the generation-11 inner failure at product 1ce87ae. Restoring
  # the exact pre-repair bare extraction lets the instance restore the archive's
  # recorded owner, and the transferred tree then meets git's ownership refusal.
  # Foreign ownership is the leading, offline-reproduced hypothesis for that run,
  # not a fact the consumed bundle proves — the remote uid was never captured —
  # so this case pins the modeled behaviour of a bare extraction, not a claim
  # about what the instance did. The failure must land at snapshot-setup with
  # the ownership diagnostic while exact destroy and strict absence complete.
  nsl_setup_program_bare="${nsl_setup_program_line/tar -o -xzf/tar -xzf}"
  [ "${nsl_setup_program_bare}" != "${nsl_setup_program_line}" ] ||
    fail 'could not derive the bare-extraction mutant from the reviewed setup program'
  nsl_install_exact_line_mutant \
    extract-owner \
    "${nsl_setup_program_line}" \
    "${nsl_setup_program_bare}"
  nsl_run mutation-setup-bare-extract fail
  nsl_assert_extract_owner_refusal mutation-setup-bare-extract
  nsl_restore_list_proof

  nsl_install_list_guard_mutant \
    exit-status '  # The command status remains authoritative even when stdout looks complete.'
  nsl_run mutation-list-exit-guard pass NSC_SHIM_LIST_FORM=nonzero-valid
  nsl_assert_exact_destroy mutation-list-exit-guard
  nsl_restore_list_proof

  nsl_install_list_guard_mutant \
    empty-output '  # Empty stdout is a distinct client failure, not an empty instance set.'
  nsl_run mutation-list-empty-guard fail NSC_SHIM_LIST_FORM=empty
  nsl_assert_closed_cleanup mutation-list-empty-guard
  if grep -qF 'nsc list returned empty stdout' \
    "${nsl_root}/cases/mutation-list-empty-guard/stderr.txt"; then
    fail 'removing the empty-list guard left the empty-list refusal assertion green'
  fi
  grep -qF 'nsc list stdout is not exactly one JSON null or array value' \
    "${nsl_root}/cases/mutation-list-empty-guard/stderr.txt" ||
    fail 'the empty-list mutant did not reach the later single-value guard'
  nsl_restore_list_proof

  nsl_install_list_guard_mutant \
    single-value '  # jq must observe exactly one complete top-level null or array value.'
  nsl_run mutation-list-single-value-guard pass NSC_SHIM_LIST_FORM=multiple
  nsl_assert_exact_destroy mutation-list-single-value-guard
  nsl_restore_list_proof

  nsl_install_list_guard_mutant \
    escape-byte '  # Never sanitize control bytes into evidence that the client did not emit.'
  nsl_run mutation-list-escape-guard fail NSC_SHIM_LIST_FORM=escape
  nsl_assert_closed_cleanup mutation-list-escape-guard
  if grep -qF 'nsc list stdout contains an ESC byte' \
    "${nsl_root}/cases/mutation-list-escape-guard/stderr.txt"; then
    fail 'removing the ESC-byte guard left the escape-list refusal assertion green'
  fi
  grep -qF 'nsc list stdout is not exactly one JSON null or array value' \
    "${nsl_root}/cases/mutation-list-escape-guard/stderr.txt" ||
    fail 'the escape-list mutant did not reach the later JSON boundary'
  nsl_restore_list_proof

  nsl_install_list_guard_mutant \
    utf8-byte '  # Raw JSON evidence must be well-formed UTF-8 without byte substitution.'
  nsl_run mutation-list-utf8-guard pass NSC_SHIM_LIST_FORM=invalid-utf8
  nsl_assert_exact_destroy mutation-list-utf8-guard
  nsl_list_before="${nsl_report}/lifecycle/list-before-use.json"
  if ! { test -s "${nsl_list_before}" &&
    cmp -s "${nsl_list_before}.raw" "${nsl_list_before}"; }; then
    fail 'removing only the UTF-8 guard did not pass the original invalid bytes into the validated list'
  fi
  if iconv -f UTF-8 -t UTF-8 "${nsl_list_before}" >/dev/null 2>&1; then
    fail 'the UTF-8 guard mutant fixture no longer carries invalid bytes'
  fi
  jq -e -s --arg id "${nsl_id}" '
    length == 1 and (.[0] | type) == "array" and .[0][0].cluster_id == $id
  ' "${nsl_list_before}" >/dev/null ||
    fail 'the UTF-8 guard mutant did not prove jq alone accepts the invalid success-shaped list'
  nsl_restore_list_proof

  # Delete the exact jq admission call, then replay every targeted malformed row
  # after destructive cleanup. Each run must become a false lifecycle pass under
  # the mutant, proving the production row-schema clause—not test prose—closed it.
  nsl_install_exact_proof_line_mutant \
    row-schema '      all(.[0][]; reviewed_row) and'
  while IFS=$'\t' read -r nsl_schema_name nsl_schema_form; do
    nsl_run "mutation-schema-${nsl_schema_name}" pass \
      "NSC_SHIM_AFTER_DESTROY_LIST_FORM=${nsl_schema_form}"
    nsl_assert_false_absence_mutant_pass \
      "mutation-schema-${nsl_schema_name}" "${nsl_schema_form}"
  done <<'NSL_ROW_SCHEMA_MUTANTS'
missing-id	missing-id
null-id	null-id
numeric-id	numeric-id
unsafe-id	unsafe-id
unsafe-id-newline	unsafe-id-newline
unsafe-id-short	unsafe-id-short
unsafe-id-long	unsafe-id-long
scalar-row	scalar-row
labels-scalar	labels-scalar
labels-numeric	labels-numeric
shape-scalar	shape-scalar
shape-cpu-string	shape-cpu-string
shape-memory-string	shape-memory-string
shape-arch-number	shape-arch-number
shape-os-number	shape-os-number
NSL_ROW_SCHEMA_MUTANTS
  nsl_restore_list_proof

  # Each remaining one-line admission clause gets its own destructive-path
  # mutant. The fixture is success-shaped for every other production predicate.
  nsl_install_exact_proof_line_mutant \
    top-level-array '      (.[0] | type) == "array" and'
  nsl_run mutation-schema-top-object pass \
    NSC_SHIM_AFTER_DESTROY_LIST_FORM=top-object
  nsl_assert_false_absence_mutant_pass mutation-schema-top-object top-object
  nsl_restore_list_proof

  nsl_install_exact_proof_line_mutant \
    single-document '    length == 1 and'
  nsl_run mutation-schema-multiple-values pass \
    NSC_SHIM_AFTER_DESTROY_LIST_FORM=multiple-null
  nsl_assert_false_absence_mutant_pass \
    mutation-schema-multiple-values multiple-null
  nsl_restore_list_proof

  # The jq variable is literal production source, not a shell expansion.
  # shellcheck disable=SC2016
  nsl_install_exact_proof_line_mutant \
    duplicate-id \
    '      ([.[0][] | select(type == "object") | .cluster_id] as $ids | ($ids | length) == ($ids | unique | length)) and'
  nsl_run mutation-schema-duplicate-id pass \
    NSC_SHIM_AFTER_DESTROY_LIST_FORM=duplicate-id
  nsl_assert_false_absence_mutant_pass \
    mutation-schema-duplicate-id duplicate-id
  nsl_restore_list_proof

  # Status 2 is injected only after exact destroy. Deleting precisely the grep
  # execution-error branch must turn that uncertainty into a false null absence.
  nsl_install_exact_proof_block_mutant \
    grep-execution-error \
    '    [2-9] | [1-9][0-9]*)' \
    '      ;;' \
    4
  nsl_run mutation-schema-grep-error pass \
    NSC_SHIM_GREP_FAILURE_AFTER_DESTROY=1
  nsl_assert_false_absence_mutant_pass mutation-schema-grep-error ''
  jq -e -s 'length == 1 and .[0] == null' \
    "${nsl_report}/lifecycle/destroy-attempt-1/list-after-destroy-1.json.raw" \
    >/dev/null ||
    fail 'the grep-error mutant did not falsely accept a success-shaped JSON null'
  nsl_restore_list_proof

  # Delete exactly one jq clause from the committed production wrapper. The
  # same one-label-delta fixtures that fail above must pass only when their own
  # guard is absent; the other live-label guard remains production-authentic.
  # The jq variable names are literal production bytes, not shell expansions.
  # shellcheck disable=SC2016
  nsl_install_live_label_guard_mutant \
    generation '      $matches[0].labels[$generationKey] == $generationValue and'
  nsl_run mutation-live-generation-guard pass NSC_SHIM_LIST_LABELS=wrong-generation
  nsl_assert_exact_destroy mutation-live-generation-guard
  nsl_assert_single_live_label_delta \
    mutation-live-generation-guard ratchet-generation 7 15
  nsl_restore_list_proof

  # The jq variable names are literal production bytes, not shell expansions.
  # shellcheck disable=SC2016
  nsl_install_live_label_guard_mutant \
    node '      $matches[0].labels[$nodeKey] == $nodeValue and'
  nsl_run mutation-live-node-guard pass NSC_SHIM_LIST_LABELS=wrong-node
  nsl_assert_exact_destroy mutation-live-node-guard
  nsl_assert_single_live_label_delta \
    mutation-live-node-guard ratchet-node not-fleet fleet
  nsl_restore_list_proof

  cmp -s "${nsl_proof_baseline}" "${nsl_fixture}/scripts/ci/fleet-sit-proof.sh" ||
    fail 'the lifecycle fixture did not restore the unmutated production list guards'
  test -z "$(git -C "${nsl_fixture}" status --porcelain --untracked-files=all)" ||
    fail 'the lifecycle fixture remained dirty after list-guard mutation proofs'

  # A success-shaped exact-id array after destroy is not absence. The wrapper
  # must exhaust its bounded probes, retain the direct bytes, and refuse pass.
  nsl_run list-present-after-destroy fail NSC_SHIM_FAIL_STAGE=absence
  nsl_assert_exact_destroy list-present-after-destroy
  nsl_assert_failed_lifecycle list-present-after-destroy
  nsl_list_after="${nsl_report}/lifecycle/destroy-attempt-1/list-after-destroy-10.json"
  if ! { test -s "${nsl_list_after}" &&
    cmp -s "${nsl_list_after}.raw" "${nsl_list_after}"; }; then
    fail 'Namespace lifecycle retained no validated direct array after the failed absence probes'
  fi
  jq -e --arg id "${nsl_id}" '
    type == "array" and any(.[]; .cluster_id == $id)
  ' "${nsl_list_after}" >/dev/null ||
    fail 'Namespace lifecycle post-destroy refusal fixture no longer contains the exact id'
  jq -e '
    .cleanup.destroySucceeded == true and
    .cleanup.exactIdAbsenceProven == false
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'Namespace lifecycle accepted an exact-id array as post-destroy absence'

  # A lead-provided instance/receipt skips create, is still fully validated,
  # and remains owned by the exact-id cleanup path.
  nsl_precreated_receipt="${nsl_root}/precreated-create.json"
  jq -n --arg id "${nsl_id}" '{
    cluster_id:$id,created:"2026-07-31T20:00:00Z",deadline:"2026-07-31T22:00:00Z",
    shape:{virtual_cpu:16,memory_megabytes:32768,machine_arch:"amd64",os:"linux"},
    kubernetes_distribution:"k3s",label:[{name:"nsc.kubernetes",value:"1.33"}],
    service_state:[{name:"ssh",status:"READY"},{name:"kubernetes",status:"READY"}]
  }' >"${nsl_precreated_receipt}"
  nsl_run precreated pass \
    FLEET_SIT_NSC_INSTANCE_ID="${nsl_id}" \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_precreated_receipt}"
  ! grep -q '^create' "${nsl_state}/calls.log" ||
    fail 'pre-created Namespace interface silently created a second instance'
  jq -e '
    .source == "lead-provided" and .executable == null and
    .subcommand == null and .argv == null
  ' "${nsl_report}/lifecycle/create-argv.json" >/dev/null ||
    fail 'pre-created Namespace handoff did not record the honest no-local-create marker'
  jq -e '
    .namespace.createReceipt == "lifecycle/create.json" and
    .namespace.createStdout == "" and .namespace.createStdoutSha256 == "" and
    .namespace.createStderr == "" and .namespace.createStderrSha256 == "" and
    .namespace.createCid == "" and .namespace.createCidSha256 == "" and
    .namespace.recoveredIdSurface == ""
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'pre-created Namespace handoff fabricated local create stdout, stderr, cid, or recovery evidence'
  nsl_assert_exact_destroy precreated

  # A lead handoff is accepted only after the supplied id satisfies the pinned
  # exact contract. Unlike a cid produced by this harness, a non-contract env
  # value is not owned and must never become a destructive selector.
  nsl_wrong_length_id='abcdefghijklmn'
  nsl_wrong_length_receipt="${nsl_root}/precreated-wrong-length.json"
  jq --arg id "${nsl_wrong_length_id}" '.cluster_id = $id' \
    "${nsl_precreated_receipt}" >"${nsl_wrong_length_receipt}"
  nsl_run precreated-wrong-length-id fail \
    FLEET_SIT_NSC_INSTANCE_ID="${nsl_wrong_length_id}" \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_wrong_length_receipt}"
  ! grep -q '^destroy' "${nsl_state}/calls.log" 2>/dev/null ||
    fail 'wrong-length pre-created Namespace id produced a destructive selector'

  # Cleanup ownership starts before source and pinned-CLI preflight once the
  # empty lifecycle evidence path and syntactically exact provided id are
  # accepted. Neither refusal may leak the lead's registered instance.
  nsl_run precreated-wrong-nsc-version fail \
    FLEET_SIT_NSC_INSTANCE_ID="${nsl_id}" \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_precreated_receipt}" \
    NSC_SHIM_FAIL_STAGE=wrong-nsc-version
  nsl_assert_exact_destroy precreated-wrong-nsc-version
  nsl_assert_failed_lifecycle precreated-wrong-nsc-version
  printf '\nfixture source drift\n' >>"${nsl_fixture}/scripts/ci/fleet-sit.sh"
  nsl_run precreated-dirty-snapshot fail \
    FLEET_SIT_NSC_INSTANCE_ID="${nsl_id}" \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_precreated_receipt}"
  nsl_assert_exact_destroy precreated-dirty-snapshot
  nsl_assert_failed_lifecycle precreated-dirty-snapshot
  git -C "${nsl_fixture}" restore scripts/ci/fleet-sit.sh

  # Every injected post-create failure must fail closed and take the same
  # exact-id destroy path. The report-validation case proves outer bytes do not
  # trust an inner success claim; destroy/absence cases prove pass is ordered
  # after cleanup, never before it.
  for nsl_stage in create-signal create-nonzero upload setup inner wrong-k3s archive download report-validation destroy hostname; do
    nsl_run "failure-${nsl_stage}" fail "NSC_SHIM_FAIL_STAGE=${nsl_stage}"
    nsl_assert_exact_destroy "failure-${nsl_stage}"
    nsl_assert_failed_lifecycle "failure-${nsl_stage}"
  done

  # nsc-produced ids are staged through the narrow selector-safe cleanup seam
  # before the pinned contract is enforced. This must refuse a future 13<->14
  # identity drift yet still destroy exactly the resource that create emitted.
  nsl_run wrong-length-created-id fail NSC_SHIM_ID="${nsl_wrong_length_id}"
  grep -qF "invalid Namespace instance id: ${nsl_wrong_length_id}" \
    "${nsl_root}/cases/wrong-length-created-id/stderr.txt" ||
    fail 'wrong-length nsc cid was not refused by the exact 13-character contract'
  nsl_assert_exact_destroy wrong-length-created-id "${nsl_wrong_length_id}"
  nsl_assert_failed_lifecycle wrong-length-created-id

  # RECOVERY-SURFACE INDEPENDENCE. The exact product audit mutated the generated
  # cidfile to the same 13-character id plus trailing whitespace. A recovery that
  # consults only the first NONEMPTY surface then rejects that literal as
  # selector-unsafe, never reads the still-valid receipt or stdout, fails the
  # registration guard with a live instance, and repeats the same dead recovery
  # from the EXIT trap — a leak with no exact selector left to destroy it.
  #
  # The three cases below each leave exactly ONE surface able to yield the id, so
  # dropping any single surface turns one of them red. A tolerant read that
  # trimmed the mutated cidfile instead would make all three pass the run and be
  # caught by the expected-refusal contract plus the recovered-surface assertion.
  nsl_assert_cid_recovery_case() {
    local name="$1" surface="$2"
    nsl_assert_exact_destroy "${name}"
    nsl_assert_failed_lifecycle "${name}"
    grep -qF 'the generated Namespace cidfile is not exactly the pinned instance id' \
      "${nsl_root}/cases/${name}/stderr.txt" ||
      fail "Namespace lifecycle ${name}: a malformed generated cidfile was not refused on its own bytes"
    # Positive control on the fixture itself, compared as bytes so a NUL-bearing
    # mutation cannot look identical to the exact literal: the cidfile must be
    # nonempty (the audited shape is malformed-but-NONEMPTY, which is what makes
    # a first-nonempty-surface chain stop there) and must NOT be the exact id.
    test -s "${nsl_report}/lifecycle/create.cid" ||
      fail "Namespace lifecycle ${name}: the fixture left no nonempty cidfile to recover past"
    nsl_cid_sha="$(sha256sum -- "${nsl_report}/lifecycle/create.cid")"
    nsl_exact_cid_sha="$(printf '%s\n' "${nsl_id}" | sha256sum)"
    if [ "${nsl_cid_sha%% *}" = "${nsl_exact_cid_sha%% *}" ]; then
      fail "Namespace lifecycle ${name}: the mutated cidfile fixture degenerated to the exact literal"
    fi
    if grep -q -- $'destroy\t'"${nsl_id} " "${nsl_state}/calls.log"; then
      fail "Namespace lifecycle ${name}: the malformed cidfile literal reached a destructive selector"
    fi
    jq -e --arg id "${nsl_id}" --arg surface "${surface}" '
      .status == "fail" and
      .namespace.createdByHarness == true and
      .namespace.instanceId == $id and
      .namespace.recoveredIdSurface == $surface and
      .cleanup.destroySucceeded == true and
      .cleanup.exactIdAbsenceProven == true and
      .innerReport.collected == false and .innerReport.validated == false
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "Namespace lifecycle ${name}: recovery surface, exact-id destroy, or absence was not proven"
  }

  # The blocking gate: malformed-but-nonempty cidfile, otherwise valid receipt
  # and stdout. Recovery must reach the receipt, and the proof must still refuse.
  nsl_run malformed-cid fail NSC_SHIM_CID_FORM=trailing-whitespace
  nsl_assert_cid_recovery_case malformed-cid receipt
  # Pin the exact audited bytes: the pinned id plus trailing whitespace.
  grep -qxF "${nsl_id}  " "${nsl_report}/lifecycle/create.cid" ||
    fail 'the malformed-cid fixture no longer reproduces the audited trailing-whitespace bytes'
  # Only the full metadata receipt can supply the id here.
  nsl_run malformed-cid-receipt-only fail \
    NSC_SHIM_CID_FORM=trailing-whitespace NSC_SHIM_STDOUT_FORM=unparseable
  nsl_assert_cid_recovery_case malformed-cid-receipt-only receipt
  # Only the minimal stdout can supply the id here, proving the third surface is
  # a real fallback and not dead code behind the receipt.
  nsl_run malformed-cid-stdout-only fail \
    NSC_SHIM_CID_FORM=trailing-whitespace NSC_SHIM_RECEIPT_ID=absent
  nsl_assert_cid_recovery_case malformed-cid-stdout-only stdout

  # A NUL-suffixed cidfile is the form a read-and-compare cannot refuse: Bash
  # command substitution silently drops the NUL, so `$(<cidfile)` returns a clean
  # exact id and both the cidfile surface and any length-tolerant acceptance
  # check would treat these malformed bytes as authoritative. The cidfile surface
  # must therefore reject them on the raw bytes and hand off to the receipt, and
  # the byte-exact acceptance guard must still refuse the run.
  nsl_run malformed-cid-trailing-nul fail NSC_SHIM_CID_FORM=trailing-nul
  nsl_assert_cid_recovery_case malformed-cid-trailing-nul receipt
  [ "$(wc -c <"${nsl_report}/lifecycle/create.cid" | tr -d ' ')" -eq "$((${#nsl_id} + 1))" ] ||
    fail 'the NUL-suffixed cidfile fixture is not the pinned id plus exactly one extra byte'
  # Positive control on the hazard itself: a tolerant read of these bytes really
  # does yield the exact id, which is why only a byte-level check can refuse them.
  # The group redirect drops Bash's own ignored-null-byte warning.
  { nsl_cid_read="$(<"${nsl_report}/lifecycle/create.cid")"; } 2>/dev/null
  [ "${nsl_cid_read}" = "${nsl_id}" ] ||
    fail 'the NUL-suffixed cidfile fixture no longer reads back as the exact id, so it proves nothing'

  # A repeated terminal newline pins the cidfile matcher's ABSOLUTE anchors.
  # Oniguruma's `$` also matches before a final newline, so a `\A...\n?$` shape
  # accepts these bytes and stages from the cidfile as though they were exact;
  # only `\z` hands off to the receipt as this asserts.
  nsl_run malformed-cid-extra-newline fail NSC_SHIM_CID_FORM=trailing-newlines
  nsl_assert_cid_recovery_case malformed-cid-extra-newline receipt

  nsl_run wrong-receipt-shape fail NSC_SHIM_RECEIPT_SHAPE=wrong
  nsl_assert_exact_destroy wrong-receipt-shape
  nsl_assert_failed_lifecycle wrong-receipt-shape
  nsl_run wrong-receipt-kubernetes fail NSC_SHIM_RECEIPT_KUBERNETES=wrong
  nsl_assert_exact_destroy wrong-receipt-kubernetes
  nsl_assert_failed_lifecycle wrong-receipt-kubernetes
  nsl_run wrong-live-shape fail NSC_SHIM_LIST_SHAPE=wrong
  nsl_assert_exact_destroy wrong-live-shape
  nsl_assert_failed_lifecycle wrong-live-shape

  nsl_run missing-receipt fail FLEET_SIT_NSC_INSTANCE_ID="${nsl_id}"
  nsl_assert_exact_destroy missing-receipt
  nsl_assert_failed_lifecycle missing-receipt
  nsl_mismatched_receipt="${nsl_root}/mismatched-create.json"
  jq '.cluster_id = "zzzzzzzzzzzzz"' "${nsl_precreated_receipt}" >"${nsl_mismatched_receipt}"
  nsl_run mismatched-receipt-id fail \
    FLEET_SIT_NSC_INSTANCE_ID="${nsl_id}" \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_mismatched_receipt}"
  nsl_assert_exact_destroy mismatched-receipt-id
  nsl_assert_failed_lifecycle mismatched-receipt-id
  nsl_run missing-id fail FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_precreated_receipt}"
  ! grep -q '^destroy' "${nsl_state}/calls.log" 2>/dev/null ||
    fail 'missing instance id produced a destructive selector'
  nsl_run malformed-id fail \
    FLEET_SIT_NSC_INSTANCE_ID='fleet-sit-prefix' \
    FLEET_SIT_NSC_CREATE_RECEIPT="${nsl_precreated_receipt}"
  ! grep -q '^destroy' "${nsl_state}/calls.log" 2>/dev/null ||
    fail 'malformed instance id produced a destructive selector'

  # =====================================================================
  # SESSION-HANG lane behavioural matrix.
  #
  # The generation-13 live signature was: correct hostname bytes on stdout, then
  # an nsc ssh client that never terminated. Exact stdout proves the instance is
  # ready and reachable, so that event is NOT an instance-readiness failure, not
  # a Fleet defect, not a subject result, and never consumes an instance
  # ordinal. It enters a separately bounded same-instance lane.
  #
  # Every case below runs the REAL production wrapper bytes from the committed
  # fixture through nsl_run. The fixture is at baseline here; each mutation case
  # restores it afterwards.
  #
  # HERMETIC LAW. Nothing here sleeps for a duration derived from the ratified
  # budgets, and no full-wrapper case overrides a production pin — every timing
  # pin the lane depends on is hard-asserted by the wrapper's own
  # validate_session_hang_bounds, so an overridden pin would be refused before
  # any client call and the case would go red for the wrong reason. (A detached
  # structural COPY of the pins is deliberately mutated further down, purely to
  # prove the arithmetic gate refuses a set that cannot fit its own budget; no
  # wrapper is ever run against it.) Time is driven three ways instead:
  #   - the 60s per-call and 300s lane bounds, by a scripted epoch shim armed on
  #     observed hostname/list call counters;
  #   - the ssh timeout MECHANISM, by extracting run_hostname_attempt from the
  #     shipped bytes and driving it at an accelerated bound in isolation;
  #   - the list timeout, by a `timeout` seam that rewrites only the duration
  #     forwarded to the real timeout, and only for the exact production list
  #     argv, leaving pins, wrapper source and validated argv untouched.
  # Every such case asserts its own elapsed time, so a bound that silently
  # stopped firing would be caught rather than waited out.
  # =====================================================================

  # NOTE ON PIN OVERRIDES. There are deliberately none. Every timing pin the
  # lane depends on — 60, 10, 300, 20, 5 — is hard-asserted by the wrapper's own
  # validate_session_hang_bounds, so a mutated pin is refused before any client
  # call is made. A case built on an overridden pin would go red for that reason
  # rather than for the behaviour under test, which is worthless evidence. The
  # ratified values are therefore left untouched everywhere, and the two cases
  # that must prove a bound really fires do so on extracted production functions
  # at an accelerated bound instead.

  # ---- T1: resolved on the first re-invocation -------------------------
  nsl_run session-hang-resolved-first-retry pass NSC_SHIM_SSH_HANG_CALLS=1
  nsl_assert_session_hang_receipt session-hang-resolved-first-retry resolved 1 0
  nsl_assert_ssh_call_shape session-hang-resolved-first-retry
  nsl_assert_single_instance_lifecycle session-hang-resolved-first-retry
  jq -e '
    .status == "pass" and .failureStage == "complete" and
    .sessionHang.exhausted == false and
    .sessionHang.classification == null and
    .sessionHang.instanceLossProven == false and
    .sessionHang.livenessUnproven == false and
    .sessionHang.livenessProofs >= 1
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'session-hang-resolved-first-retry: a resolved lane did not leave the proof passing and unclassified'
  # Four staged calls plus exactly one re-invocation. This is also what proves
  # the clean path is unchanged: the success case below still makes exactly 4.
  nsl_resolved_ssh="$(nsl_count_ssh_calls)"
  [ "${nsl_resolved_ssh}" -eq 5 ] ||
    fail "session-hang-resolved-first-retry: expected 5 ssh calls, found ${nsl_resolved_ssh}"
  echo '    session-hang-resolved-first-retry: exact bytes plus a hung client resolved on re-invocation 1, proof still passes ✓'

  # ---- T2: resolved on the THIRD re-invocation (bound is inclusive) ----
  nsl_run session-hang-resolved-third-retry pass NSC_SHIM_SSH_HANG_CALLS=3
  nsl_assert_session_hang_receipt session-hang-resolved-third-retry resolved 3 0
  nsl_assert_single_instance_lifecycle session-hang-resolved-third-retry
  nsl_third_ssh="$(nsl_count_ssh_calls)"
  [ "${nsl_third_ssh}" -eq 7 ] ||
    fail "session-hang-resolved-third-retry: expected 7 ssh calls, found ${nsl_third_ssh}"
  echo '    session-hang-resolved-third-retry: the third re-invocation is admitted, so the bound is inclusive and not off by one ✓'

  # ---- T3: three-call exhaustion, exit 75, exact classification --------
  nsl_run session-hang-exhausted fail NSC_SHIM_SSH_HANG_CALLS=9
  nsl_assert_terminal_signature \
    session-hang-exhausted 75 session-hang-exhausted exhausted-calls
  nsl_assert_session_hang_receipt session-hang-exhausted exhausted-calls 3 1
  nsl_assert_exact_destroy session-hang-exhausted
  nsl_assert_ssh_call_shape session-hang-exhausted
  nsl_assert_single_instance_lifecycle session-hang-exhausted
  # The whole classification object, compared as one value rather than grepped,
  # so a partially-correct or widened verdict cannot pass.
  nsl_expected_classification='{"verdict":"SESSION-HANG-EXHAUSTED","instanceReadinessResult":false,"fleetDefect":false,"proofFailure":false,"subjectResult":false,"consumesInstanceOrdinal":false}'
  nsl_observed_classification="$(jq -cS '.sessionHang.classification' \
    "${nsl_report}/lifecycle/lifecycle.json")"
  [ "${nsl_observed_classification}" = "$(printf '%s' "${nsl_expected_classification}" | jq -cS '.')" ] ||
    fail "session-hang-exhausted: classification object is not the exact ratified verdict: ${nsl_observed_classification}"
  # Cleanup facts must be CURRENT, not a pre-cleanup snapshot. The reserved
  # terminals defer their only receipt to the EXIT cleanup for exactly this.
  jq -e '
    .status == "fail" and
    .cleanup.destroySucceeded == true and
    .cleanup.exactIdAbsenceProven == true and
    .sessionHang.reinvocations == 3
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'session-hang-exhausted: the deferred receipt did not carry current cleanup facts'
  # Retain the terminal artifacts rather than only asserting on them.
  cp "${nsl_report}/lifecycle/lifecycle.json" "${nsl_root}/T3-exhausted-lifecycle.json"
  printf '%s\n' "${nsl_status}" >"${nsl_root}/T3-exhausted.exit-status"
  echo '    session-hang-exhausted: three re-invocations then exit 75 with the exact SESSION-HANG-EXHAUSTED verdict and current cleanup facts ✓'

  # ---- Reserved terminal survives a cleanup FAILURE --------------------
  # The reserved terminals defer their only receipt to the EXIT cleanup so that
  # cleanup booleans are final facts. This is the case that proves the deferral
  # actually buys something: the instance is still listed after destroy, so
  # absence can never be proven, the EXIT trap RETRIES, and the receipt records
  # what really happened — without the failure rewriting the terminal class.
  # A cleanup failure must not turn 75 into 1, or the external driver would read
  # an ordinary refusal where a closed session lane occurred.
  nsl_run session-hang-exhausted-cleanup-fails fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_FAIL_STAGE=absence
  nsl_assert_terminal_signature \
    session-hang-exhausted-cleanup-fails 75 session-hang-exhausted exhausted-calls
  nsl_assert_session_hang_receipt \
    session-hang-exhausted-cleanup-fails exhausted-calls 3 1
  jq -e '
    .status == "fail" and
    .cleanup.destroyAttempts == 2 and
    .cleanup.destroySucceeded == true and
    .cleanup.exactIdAbsenceProven == false
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail "session-hang-exhausted-cleanup-fails: the retried cleanup facts were not recorded: $(jq -c '.cleanup' "${nsl_report}/lifecycle/lifecycle.json")"
  cp "${nsl_report}/lifecycle/lifecycle.json" \
    "${nsl_root}/T3b-cleanup-failure-preserves-75-lifecycle.json"
  printf '%s\n' "${nsl_status}" >"${nsl_root}/T3b-cleanup-failure-preserves-75.exit-status"
  echo '    session-hang-exhausted-cleanup-fails: EXIT cleanup retried, recorded unproven absence, and still exited 75 rather than an ordinary refusal ✓'

  # The contrast that makes the above meaningful: the SAME cleanup failure on an
  # ORDINARY (non-reserved) refusal must still collapse to status 1, so the
  # preservation above is specific to the reserved lane terminals.
  nsl_run ordinary-cleanup-failure-stays-1 fail NSC_SHIM_FAIL_STAGE=absence
  [ "${nsl_status}" -eq 1 ] ||
    fail "ordinary-cleanup-failure-stays-1: an ordinary cleanup failure reported ${nsl_status}, not 1"
  jq -e '
    .sessionHang.entered == false and
    .sessionHang.terminalStatus == null and
    .cleanup.exactIdAbsenceProven == false
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'ordinary-cleanup-failure-stays-1: an ordinary cleanup failure claimed a reserved terminal'
  echo '    ordinary-cleanup-failure-stays-1: the same cleanup failure outside the lane still exits 1, so reserved-status preservation is lane-specific ✓'

  # ---- T10: separate stdout/stderr/status custody for every attempt ----
  # Asserted on T3, which is the only case exercising all four attempts. Bound to
  # that case's EXPLICIT report path rather than to ${nsl_report}, which every
  # later nsl_run silently repoints — a custody claim must not depend on which
  # case happened to run last.
  nsl_custody_report="${nsl_root}/cases/session-hang-exhausted/report"
  for nsl_attempt in readiness-1 session-hang-1 session-hang-2 session-hang-3; do
    for nsl_stream in txt stderr exit-status; do
      test -f "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.${nsl_stream}" ||
        fail "session-hang-exhausted: attempt ${nsl_attempt} lost its ${nsl_stream} custody"
    done
    # stdout must never be merged into stderr: the exact bytes are what proves
    # reachability, and the timeout diagnostic is what distinguishes the two
    # exhaustion signatures. Merging them would destroy both claims.
    grep -qxF "${nsl_id}" "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.txt" ||
      fail "session-hang-exhausted: attempt ${nsl_attempt} did not retain the exact hostname bytes"
    grep -qF 'timeout: sending signal TERM' \
      "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.stderr" ||
      fail "session-hang-exhausted: attempt ${nsl_attempt} lost its separate timeout diagnostic"
    grep -qxF '137' "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.exit-status" ||
      fail "session-hang-exhausted: attempt ${nsl_attempt} did not retain its own observed status"
    # No two attempts may share a file: separate custody means separate bytes.
    test ! "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.txt" \
      -ef "${nsl_custody_report}/lifecycle/hostname-attempt-${nsl_attempt}.stderr" ||
      fail "session-hang-exhausted: attempt ${nsl_attempt} merged its stdout and stderr into one file"
  done
  # stderr NEVER authorizes success: every attempt above carried a non-empty
  # stderr and none of them was accepted.
  echo '    session-hang-custody: initial and all three re-invocations kept separate stdout, stderr and status, and stderr never authorized acceptance ✓'

  # ---- T4: independently proven instance loss, exit 76 -----------------
  # The lane liveness proof observes a schema-valid EMPTY reviewed array, which
  # is a positive absence proof. This is the only outcome the external driver may
  # read as consuming an instance ordinal, and it must never report 75.
  nsl_run session-hang-instance-lost fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=empty-array
  nsl_assert_terminal_signature \
    session-hang-instance-lost 76 session-hang-instance-lost instance-lost
  jq -e '
    .sessionHang.instanceLossProven == true and
    .sessionHang.livenessUnproven == false and
    .sessionHang.exhausted == false and
    .sessionHang.reinvocations < 3 and
    .sessionHang.livenessProofs >= 1 and
    .sessionHang.consumesInstanceOrdinal == false
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'session-hang-instance-lost: proven loss was not reported as its own terminal class'
  cp "${nsl_report}/lifecycle/lifecycle.json" "${nsl_root}/T4-instance-lost-lifecycle.json"
  printf '%s\n' "${nsl_status}" >"${nsl_root}/T4-instance-lost.exit-status"
  echo '    session-hang-instance-lost: a positive absence proof closes the lane as exit 76, never 75 or 77 ✓'

  # ---- T4a/T4b/T4c: liveness UNPROVEN, exit 77, never instance loss ----
  # Three distinct uncertainties. None of them is absence, so none of them may
  # manufacture an ordinal-consuming loss claim.
  nsl_assert_liveness_unproven() {
    local name="$1"
    nsl_assert_terminal_signature \
      "${name}" 77 session-hang-liveness-unproven liveness-unproven
    jq -e '
      .sessionHang.instanceLossProven == false and
      .sessionHang.livenessUnproven == true and
      .sessionHang.exhausted == false and
      .sessionHang.consumesInstanceOrdinal == false
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "${name}: uncertain liveness was not held apart from proven instance loss"
    nsl_assert_exact_destroy "${name}"
  }

  nsl_run liveness-unproven-list-nonzero fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=array \
    NSC_SHIM_LIVENESS_STATUS=29
  nsl_assert_liveness_unproven liveness-unproven-list-nonzero
  cp "${nsl_report}/lifecycle/lifecycle.json" "${nsl_root}/T4a-liveness-unproven-lifecycle.json"
  printf '%s\n' "${nsl_status}" >"${nsl_root}/T4a-liveness-unproven.exit-status"
  echo '    liveness-unproven-list-nonzero: a nonzero list command can never become a proven loss ✓'

  nsl_run liveness-unproven-list-malformed fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=malformed
  nsl_assert_liveness_unproven liveness-unproven-list-malformed
  echo '    liveness-unproven-list-malformed: an unparseable listing is uncertainty, not absence ✓'

  nsl_run liveness-unproven-row-drifted fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=drifted
  nsl_assert_liveness_unproven liveness-unproven-row-drifted
  echo '    liveness-unproven-row-drifted: the exact id present but disagreeing is disagreement, never absence ✓'

  # ---- T4d: the liveness call is itself really bounded -----------------
  # The production wrapper hard-pins NSC_LIST_TIMEOUT_SECONDS to 20 and its TERM
  # grace to 5 in validate_session_hang_bounds, so those values CANNOT be shrunk
  # for a full-wrapper run: a mutated pin is refused before any client call, and
  # a case built that way would go red for the wrong reason entirely. Waiting the
  # real 20s out is equally forbidden.
  #
  # So the two claims are proven separately and honestly:
  #   (a) the MECHANISM — nsc_list_json is extracted from the shipped wrapper and
  #       driven in isolation at a 1s bound against a client that genuinely never
  #       terminates, so the elapsed time does not scale with the ratified 20s;
  #   (b) the CLASSIFICATION — the full-wrapper cases above already prove that a
  #       list which fails to produce a usable answer reaches liveness-unproven
  #       and exit 77, never a proven loss.
  # A bounded-out list arrives at (b) through exactly the same nonzero-status
  # branch that (a) produces, which is what joins the two halves.
  nsl_list_fn="${tmp}/nsc-list-json.sh"
  sed -n '/^nsc_list_json() {$/,/^}$/p' "${proof_source}" >"${nsl_list_fn}"
  test -s "${nsl_list_fn}" ||
    fail 'could not extract nsc_list_json() for the bounded-liveness proof'
  [ "$(tail -n 1 "${nsl_list_fn}")" = '}' ] ||
    fail 'the extracted nsc_list_json() is unterminated'
  mkdir -p "${nsl_root}/listbound/bin" "${nsl_root}/listbound/state"
  cat >"${nsl_root}/listbound/bin/nsc" <<'NSL_BLOCKING_LIST'
#!/usr/bin/env bash
set -Eeuo pipefail
block="${NSC_SHIM_STATE:?}/list-block.fifo"
mkdir -p "${NSC_SHIM_STATE}"
[ -p "${block}" ] || mkfifo -m 600 "${block}"
exec cat -- "${block}"
NSL_BLOCKING_LIST
  chmod +x "${nsl_root}/listbound/bin/nsc"
  cat >"${nsl_root}/listbound/drive.sh" <<'NSL_LIST_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
out="$2"
# shellcheck source=/dev/null
source "${fn_file}"
status=0
nsc_list_json "${out}" >/dev/null 2>"${out}.driver-stderr" || status=$?
printf '%s\n' "${status}"
NSL_LIST_DRIVER
  nsl_listbound_started="$(date +%s)"
  nsl_listbound_status="$(
    env PATH="${nsl_root}/listbound/bin:${PATH}" \
      NSC_SHIM_STATE="${nsl_root}/listbound/state" \
      instance_id="${nsl_id}" \
      NSC_LIST_TIMEOUT_SECONDS=1 \
      NSC_LIST_KILL_AFTER_SECONDS=1 \
      bash "${nsl_root}/listbound/drive.sh" "${nsl_list_fn}" \
      "${nsl_root}/listbound/listing.json"
  )"
  nsl_listbound_elapsed=$(($(date +%s) - nsl_listbound_started))
  [ "${nsl_listbound_status}" -ne 0 ] ||
    fail 'liveness-bounded-out: a never-terminating list client was accepted as a valid listing'
  [ "${nsl_listbound_elapsed}" -lt 15 ] ||
    fail "liveness-bounded-out: the list bound did not fire, ${nsl_listbound_elapsed}s elapsed"
  # The bounded-out listing must NOT be published as validated evidence: a
  # timeout is uncertainty, and an absence claim can never be read from it.
  test ! -s "${nsl_root}/listbound/listing.json" ||
    fail 'liveness-bounded-out: a bounded-out list published a validated listing'
  grep -qF 'nsc list exited' "${nsl_root}/listbound/listing.json.driver-stderr" ||
    fail 'liveness-bounded-out: the bounded-out list did not refuse on the authoritative command status'
  echo "    liveness-bounded-out-mechanism: production bytes killed a never-terminating list client in ${nsl_listbound_elapsed}s and refused it on command status, publishing no listing ✓"

  # ...and the CLASSIFICATION half, through the whole wrapper. The blocking list
  # client is driven by the real production list path; only the duration the
  # real timeout actually receives is accelerated, by the seam above. Pins,
  # wrapper source and validated argv are untouched, so this is the genuine
  # bounded-out list reaching its terminal class.
  nsl_wrapper_block_started="$(date +%s)"
  nsl_run liveness-bounded-out-classification fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=block \
    NSC_SHIM_ACCELERATE_LIST_TIMEOUT=1
  nsl_wrapper_block_elapsed=$(($(date +%s) - nsl_wrapper_block_started))
  nsl_assert_liveness_unproven liveness-bounded-out-classification
  [ "${nsl_wrapper_block_elapsed}" -lt 20 ] ||
    fail "liveness-bounded-out-classification: took ${nsl_wrapper_block_elapsed}s, so the accelerated bound did not fire"
  # The bounded-out liveness proof must retain its own killed status and the
  # timeout diagnostic, as evidence rather than prose.
  nsl_block_listing="${nsl_report}/lifecycle/session-hang-liveness-1.json"
  # Exactly 124, not 124-or-137. This case is fully deterministic: GNU timeout
  # sends TERM, and a blocking `cat` dies on TERM immediately, so the KILL grace
  # is never reached. Accepting 137 here would weaken the observed witness to
  # "something signalled it". 137 is admitted only where the modelled real nsc
  # signature explicitly produces it.
  nsl_block_status="$(cat "${nsl_block_listing}.exit-status" 2>/dev/null || echo missing)"
  [ "${nsl_block_status}" = '124' ] ||
    fail "liveness-bounded-out-classification: the killed list retained status ${nsl_block_status}, not the exact TERM-kill status 124"
  grep -qF 'timeout: sending signal TERM' "${nsl_block_listing}.stderr" ||
    fail 'liveness-bounded-out-classification: the bounded-out list lost its timeout diagnostic'
  test ! -s "${nsl_block_listing}" ||
    fail 'liveness-bounded-out-classification: a bounded-out list was published as a validated listing'
  cp "${nsl_report}/lifecycle/lifecycle.json" "${nsl_root}/T4d-bounded-out-lifecycle.json"
  printf '%s\n' "${nsl_status}" >"${nsl_root}/T4d-bounded-out.exit-status"
  echo "    liveness-bounded-out-classification: a real bounded-out list reaches exit 77 with retained status ${nsl_block_status} and its timeout diagnostic, never an absence claim ✓"

  # ---- T6b: the ssh bound really fires, on production bytes ------------
  # The lane's 60s per-call bound cannot be waited out, and cannot be shrunk
  # because validate_session_hang_bounds hard-asserts 60. So run_hostname_attempt
  # is EXTRACTED from the shipped wrapper and driven in isolation at a 1s bound
  # against a client that genuinely never terminates — the same extract-and-drive
  # pattern this validator already uses for the tool-receipt helpers. This proves
  # the mechanism; the pin above proves the ratified value.
  nsl_attempt_fn="${tmp}/run-hostname-attempt.sh"
  sed -n '/^run_hostname_attempt() {$/,/^}$/p' "${proof_source}" >"${nsl_attempt_fn}"
  test -s "${nsl_attempt_fn}" ||
    fail 'could not extract run_hostname_attempt() for the bounded-call proof'
  [ "$(tail -n 1 "${nsl_attempt_fn}")" = '}' ] ||
    fail 'the extracted run_hostname_attempt() is unterminated'
  mkdir -p "${nsl_root}/bound/bin" "${nsl_root}/bound/lifecycle" "${nsl_root}/bound/state"
  cat >"${nsl_root}/bound/bin/nsc" <<'NSL_BLOCKING_NSC'
#!/usr/bin/env bash
set -Eeuo pipefail
# The exact generation-13 signature: correct hostname bytes, then a client that
# never terminates. Blocks on a reader-only FIFO, so it costs no CPU and emits
# nothing on stderr; the only stderr bytes are the wrapper's own diagnostic.
printf '%s\n' "${NSC_SHIM_ID:?}"
block="${NSC_SHIM_STATE:?}/ssh-block.fifo"
mkdir -p "${NSC_SHIM_STATE}"
[ -p "${block}" ] || mkfifo -m 600 "${block}"
exec cat -- "${block}"
NSL_BLOCKING_NSC
  chmod +x "${nsl_root}/bound/bin/nsc"
  cat >"${nsl_root}/bound/drive.sh" <<'NSL_BOUND_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn_file="$1"
# shellcheck source=/dev/null
source "${fn_file}"
status=0
run_hostname_attempt bounded-probe || status=$?
printf '%s\n' "${status}"
NSL_BOUND_DRIVER
  nsl_bound_started="$(date +%s)"
  nsl_bound_status="$(
    env PATH="${nsl_root}/bound/bin:${PATH}" \
      NSC_SHIM_ID="${nsl_id}" \
      NSC_SHIM_STATE="${nsl_root}/bound/state" \
      instance_id="${nsl_id}" \
      lifecycle_dir="${nsl_root}/bound/lifecycle" \
      NSC_SESSION_HANG_PER_CALL_TIMEOUT_SECONDS=1 \
      NSC_SESSION_HANG_KILL_AFTER_SECONDS=1 \
      bash "${nsl_root}/bound/drive.sh" "${nsl_attempt_fn}"
  )"
  nsl_bound_elapsed=$(($(date +%s) - nsl_bound_started))
  case "${nsl_bound_status}" in
  124 | 137) ;;
  *) fail "hostname-attempt-really-bounded: a never-terminating client returned ${nsl_bound_status}, not a terminal-signal status" ;;
  esac
  [ "${nsl_bound_elapsed}" -lt 15 ] ||
    fail "hostname-attempt-really-bounded: the bound did not fire, ${nsl_bound_elapsed}s elapsed"
  # The exact bytes survive the kill: that is the whole semantic split.
  grep -qxF "${nsl_id}" "${nsl_root}/bound/lifecycle/hostname-attempt-bounded-probe.txt" ||
    fail 'hostname-attempt-really-bounded: the exact hostname bytes were lost when the client was killed'
  grep -qxF "${nsl_bound_status}" "${nsl_root}/bound/lifecycle/hostname-attempt-bounded-probe.exit-status" ||
    fail 'hostname-attempt-really-bounded: the observed status was not retained as an artifact'
  test -s "${nsl_root}/bound/lifecycle/hostname-attempt-bounded-probe.stderr" ||
    fail 'hostname-attempt-really-bounded: the timeout diagnostic was not retained on its own stderr'
  echo "    hostname-attempt-really-bounded: production bytes killed a never-terminating client in ${nsl_bound_elapsed}s, keeping exact stdout, separate stderr and status ${nsl_bound_status} ✓"

  # ---- T5a: an iteration never STARTS without budget for both calls ----
  # The clock jumps once the lane's first re-invocation has happened, leaving
  # less than liveness_allowance + call_allowance (95s). A bare `now >= deadline`
  # test would still admit the next iteration and overrun the ratified lane.
  nsl_run budget-refuses-late-start fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSL_DATE_OFFSETS=h2:215
  nsl_assert_terminal_signature \
    budget-refuses-late-start 75 session-hang-exhausted exhausted-budget
  nsl_assert_session_hang_receipt budget-refuses-late-start exhausted-budget 1 1
  jq -e '.sessionHang.livenessProofs == .sessionHang.reinvocations' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'budget-refuses-late-start: the refused iteration still paid for a liveness proof, so the check did not precede it'
  # Exactly two ssh calls: the readiness call, plus the ONE lane re-invocation
  # that had budget. Iteration 2 is refused before its liveness proof and before
  # its ssh call, and a lane that closes terminally never reaches snapshot-setup,
  # inner-run or report-archive — so two is the whole ssh population, and any
  # third call would mean an iteration started without sufficient budget.
  nsl_late_ssh="$(nsl_count_ssh_calls)"
  [ "${nsl_late_ssh}" -eq 2 ] ||
    fail "budget-refuses-late-start: expected 2 ssh calls (readiness plus one funded re-invocation), found ${nsl_late_ssh}"
  echo '    budget-refuses-late-start: an iteration is admitted only when the remaining budget covers BOTH bounded calls ✓'

  # ---- T5b: the deadline is re-read AFTER the liveness proof -----------
  # The pre-liveness check passes, the liveness proof itself consumes the
  # budget, and the ssh call it exists to authorize is then correctly refused.
  # livenessProofs is exactly one GREATER than reinvocations — the only
  # observable that distinguishes "the second check exists" from "it does not".
  nsl_run budget-refuses-after-liveness fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSL_DATE_OFFSETS=l3:260
  nsl_assert_terminal_signature \
    budget-refuses-after-liveness 75 session-hang-exhausted exhausted-budget
  jq -e '
    .sessionHang.outcome == "exhausted-budget" and
    .sessionHang.reinvocations < 3 and
    .sessionHang.livenessProofs == (.sessionHang.reinvocations + 1)
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail "budget-refuses-after-liveness: the post-liveness re-read did not refuse the call: $(jq -c '.sessionHang|{outcome,reinvocations,livenessProofs}' "${nsl_report}/lifecycle/lifecycle.json")"
  echo '    budget-refuses-after-liveness: the deadline is re-read after the liveness proof, so the last iteration cannot overrun ✓'

  # ---- T13/T15: byte-exact acceptance and refusal ----------------------
  # MEASURED, not assumed: the new byte-exact predicate and the removed loose
  # `tr -d '[:space:]'` form agree on `<id>x`, `<id>\nother\n` and empty stdout,
  # so those three prove nothing about byte-exactness on their own. The six
  # fixtures marked discriminating below are the ones that actually separate the
  # two predicates, and they are what makes the loose-form mutant go red.
  nsl_assert_no_lane_entry() {
    local name="$1"
    jq -e '
      .sessionHang.entered == false and
      .sessionHang.outcome == "not-entered" and
      .sessionHang.reinvocations == 0
    ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "${name}: non-exact hostname bytes entered the SESSION-HANG lane"
    grep -qF 'Namespace hostname does not equal the exact instance id' \
      "${nsl_root}/cases/${name}/stderr.txt" ||
      fail "${name}: non-exact bytes did not keep the ordinary readiness refusal"
    [ "${nsl_status}" -eq 1 ] ||
      fail "${name}: an ordinary readiness refusal reported ${nsl_status} instead of 1"
  }

  # Discriminating fixtures: refused by the byte-exact predicate, ACCEPTED by
  # the loose one. These are the load-bearing rows.
  for nsl_bytes_case in \
    'trailing-space:@ID@ ' \
    'leading-space: @ID@' \
    'extra-line:@ID@\n\n' \
    'carriage-return:@ID@\r\n' \
    'tab-padded:\t@ID@\n' \
    'internal-space:abcdefg hijklm'; do
    nsl_bytes_name="${nsl_bytes_case%%:*}"
    nsl_bytes_value="${nsl_bytes_case#*:}"
    nsl_run "hostname-bytes-${nsl_bytes_name}" fail \
      "NSC_SHIM_HOSTNAME_BYTES=${nsl_bytes_value}"
    nsl_assert_no_lane_entry "hostname-bytes-${nsl_bytes_name}"
  done
  # Non-discriminating but still required: both predicates refuse these, so they
  # guard the refusal itself rather than the byte-exactness.
  for nsl_bytes_case in \
    'second-line:@ID@\nother\n' \
    'suffixed:@ID@x'; do
    nsl_bytes_name="${nsl_bytes_case%%:*}"
    nsl_bytes_value="${nsl_bytes_case#*:}"
    nsl_run "hostname-bytes-${nsl_bytes_name}" fail \
      "NSC_SHIM_HOSTNAME_BYTES=${nsl_bytes_value}"
    nsl_assert_no_lane_entry "hostname-bytes-${nsl_bytes_name}"
  done
  nsl_run hostname-bytes-empty fail NSC_SHIM_HOSTNAME_EMPTY=1
  nsl_assert_no_lane_entry hostname-bytes-empty
  echo '    hostname-bytes-adversarial: padded, internal-whitespace, extra-line, CR, tab, wrong and empty stdout all stay ordinary readiness refusals and never enter the lane ✓'

  # T15 — both ratified exact forms DO enter the lane, paired with a nonzero
  # status. `<id>\n` is the retained generation-13 witness; bare `<id>` is the
  # other form the reviewed driver predicate accepts.
  nsl_run hostname-bytes-exact-newline fail \
    'NSC_SHIM_HOSTNAME_BYTES=@ID@\n' NSC_SHIM_SSH_HANG_CALLS=9
  jq -e '.sessionHang.entered == true' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'hostname-bytes-exact-newline: the retained witness form did not enter the lane'
  nsl_run hostname-bytes-exact-bare fail \
    'NSC_SHIM_HOSTNAME_BYTES=@ID@' NSC_SHIM_SSH_HANG_CALLS=9
  jq -e '.sessionHang.entered == true' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'hostname-bytes-exact-bare: the bare exact form did not enter the lane'
  echo '    hostname-bytes-both-exact-forms: exactly the two ratified byte sequences enter the lane ✓'

  # ---- T12: schema v2 and the ordinal denial, in EVERY lane outcome ----
  for nsl_v2_case in \
    session-hang-resolved-first-retry session-hang-exhausted \
    session-hang-instance-lost liveness-unproven-list-nonzero; do
    jq -e '
      .schemaVersion == 2 and
      .sessionHang.consumesInstanceOrdinal == false and
      (.sessionHangLaw | contains("never consumes an instance ordinal"))
    ' "${nsl_root}/cases/${nsl_v2_case}/report/lifecycle/lifecycle.json" >/dev/null ||
      fail "${nsl_v2_case}: schema v2 or the instance-ordinal denial is missing"
  done
  echo '    session-hang-schema-v2: every lane outcome, including resolved, denies instance-ordinal consumption under schema 2 ✓'

  # =====================================================================
  # Mutation cases. Each must go RED, and for the RIGHT reason: the installers
  # already refuse a no-op diff and enforce an exact numstat, and each assertion
  # below names the specific behaviour that must break. A mutant that merely
  # dies of a syntax error, exit 89 or 127 is not evidence.
  # =====================================================================

  # ---- T7: the lane itself is load-bearing -----------------------------
  # The lane's only call site is the body of an `elif`, so DELETING it leaves an
  # empty branch and the mutant dies of a bash syntax error before reaching any
  # production logic — a vacuous mutant that proves nothing. It is therefore
  # REWRITTEN to the exact pre-repair behaviour instead: the generation-13
  # signature falls back to the ordinary readiness refusal it used to get.
  nsl_install_exact_line_mutant \
    session-hang-lane-entry \
    '    enter_session_hang_lane || close_lane_terminally' \
    "    fail 'Namespace hostname does not equal the exact instance id'"
  nsl_run mutation-session-hang-lane-removed fail NSC_SHIM_SSH_HANG_CALLS=1
  # Without the lane, exact-bytes-plus-hang falls through to the ordinary
  # readiness refusal that the repair exists to replace.
  # Authenticate the INTENDED pre-repair semantics, not merely "it went red".
  # Without the lane, the generation-13 signature — exact bytes plus a client
  # that failed to terminate — is misreported as an ordinary readiness refusal:
  # exit exactly 1, the original message, and a lane that was never entered.
  jq -e '.sessionHang.entered == false and .sessionHang.reinvocations == 0' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'mutation-session-hang-lane-removed: the lane still ran after its only call site was replaced'
  [ "${nsl_status}" -eq 1 ] ||
    fail "mutation-session-hang-lane-removed: expected the ordinary refusal status 1, got ${nsl_status}"
  grep -qF 'Namespace hostname does not equal the exact instance id' \
    "${nsl_root}/cases/mutation-session-hang-lane-removed/stderr.txt" ||
    fail 'mutation-session-hang-lane-removed: the pre-repair readiness refusal message is missing, so the red is not the intended semantic'
  nsl_restore_list_proof
  echo '    mutation-session-hang-lane-removed: without the lane, exact bytes plus a hung client are misreported as an ordinary readiness refusal (exit 1) ✓'

  # ---- T8: the split keys on EXACT BYTES, not on "any failure" ---------
  # shellcheck disable=SC2016
  nsl_install_exact_line_mutant \
    session-hang-widened-guard \
    '  elif hostname_bytes_are_exact "${readiness_out}"; then' \
    '  elif true; then'
  nsl_run mutation-wrong-bytes-enter-lane fail NSC_SHIM_FAIL_STAGE=hostname
  # wronghostname00 must NEVER prove reachability. Under the mutant it does, and
  # a wrong-byte readiness failure is wrongly escalated into the lane.
  jq -e '.sessionHang.entered == true' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'mutation-wrong-bytes-enter-lane: the widened guard did not admit wrong bytes, so the byte predicate is not what gates the lane'
  nsl_restore_list_proof
  # ...and on the real bytes it stays out, which is the pairing that makes the
  # mutant meaningful rather than merely red.
  nsl_run wrong-bytes-stay-out-of-lane fail NSC_SHIM_FAIL_STAGE=hostname
  nsl_assert_no_lane_entry wrong-bytes-stay-out-of-lane
  echo '    mutation-wrong-bytes-enter-lane: only exact bytes enter the lane; widening the guard admits wronghostname00 ✓'

  # ---- T14: byte-exactness is load-bearing -----------------------------
  # Restore the removed loose predicate and require the six DISCRIMINATING
  # fixtures to flip. Driving this with `<id>x` or empty stdout would leave the
  # mutant green and prove nothing, because both predicates refuse those.
  # shellcheck disable=SC1003,SC2016
  nsl_install_exact_line_mutant \
    hostname-loose-bytes \
    '  jq -eRs --arg id "${instance_id}" '\''. == $id or . == ($id + "\n")'\'' \' \
    '  [ "$(tr -d '\''[:space:]'\'' <"$1")" = "${instance_id}" ] || return 1; : \'
  for nsl_loose_case in \
    'trailing-space:@ID@ ' \
    'leading-space: @ID@' \
    'extra-line:@ID@\n\n' \
    'carriage-return:@ID@\r\n' \
    'tab-padded:\t@ID@\n' \
    'internal-space:abcdefg hijklm'; do
    nsl_loose_name="${nsl_loose_case%%:*}"
    nsl_loose_value="${nsl_loose_case#*:}"
    nsl_run "mutation-loose-bytes-${nsl_loose_name}" fail \
      "NSC_SHIM_HOSTNAME_BYTES=${nsl_loose_value}" NSC_SHIM_SSH_HANG_CALLS=9
    jq -e '.sessionHang.entered == true' \
      "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
      fail "mutation-loose-bytes-${nsl_loose_name}: the loose predicate did not admit these bytes, so this fixture cannot prove byte-exactness is load-bearing"
  done
  nsl_restore_list_proof
  echo '    mutation-hostname-loose-bytes: all six discriminating fixtures enter the lane under the loose predicate, so byte-exactness is load-bearing ✓'

  # ---- T4e: the tri-state is load-bearing ------------------------------
  # Booleanize the liveness probe so a REFUSED list becomes "instance lost".
  # That is the ruling-item-7 violation: uncertainty manufacturing an
  # ordinal-consuming loss claim.
  # shellcheck disable=SC2016
  nsl_install_exact_line_mutant \
    liveness-booleanized \
    '  nsc_list_json "${listing}" || return 2' \
    '  nsc_list_json "${listing}" || return 1'
  nsl_run mutation-liveness-boolean fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSC_SHIM_LIVENESS_FORM_AFTER=1 \
    NSC_SHIM_LIVENESS_FORM=array \
    NSC_SHIM_LIVENESS_STATUS=29
  # The same fixture that produced 77 above must now produce 76.
  [ "${nsl_status}" -eq 76 ] ||
    fail "mutation-liveness-boolean: booleanizing the probe did not promote a nonzero list into a proven loss, got ${nsl_status}"
  jq -e '.sessionHang.outcome == "instance-lost" and .sessionHang.instanceLossProven == true' \
    "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'mutation-liveness-boolean: the booleanized probe did not report instance loss'
  nsl_restore_list_proof
  echo '    mutation-liveness-boolean: without the tri-state, a merely nonzero list is promoted into an ordinal-consuming loss ✓'

  # ---- T5c: the post-liveness deadline re-read is load-bearing ---------
  # shellcheck disable=SC2016
  nsl_install_exact_proof_block_mutant \
    post-liveness-deadline \
    '    if [ "${remaining}" -lt "${call_allowance}" ]; then' \
    '    fi' \
    5
  nsl_run mutation-single-budget-check fail \
    NSC_SHIM_SSH_HANG_CALLS=9 \
    NSL_DATE_OFFSETS=l3:260
  # With the re-check gone, the ssh call the budget could not afford STARTS
  # anyway. Under the same l3 offset that made T5b close after one funded
  # re-invocation, the mutant instead runs a second one and only then closes on
  # budget at the top of iteration 3. That is a deterministic tuple, asserted
  # exactly so an unrelated mutant failure cannot be mistaken for this one:
  # terminal 75 / exhausted-budget, two liveness proofs, two re-invocations, and
  # exactly three ssh rows (readiness plus two retries).
  nsl_assert_terminal_signature \
    mutation-single-budget-check 75 session-hang-exhausted exhausted-budget
  jq -e '
    .sessionHang.outcome == "exhausted-budget" and
    .sessionHang.livenessProofs == 2 and
    .sessionHang.reinvocations == 2
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail "mutation-single-budget-check: expected the unguarded tuple of 2 liveness proofs and 2 re-invocations, got $(jq -c '.sessionHang|{outcome,livenessProofs,reinvocations}' "${nsl_report}/lifecycle/lifecycle.json")"
  nsl_unguarded_ssh="$(nsl_count_ssh_calls)"
  [ "${nsl_unguarded_ssh}" -eq 3 ] ||
    fail "mutation-single-budget-check: expected 3 ssh rows once the unaffordable call is allowed to start, found ${nsl_unguarded_ssh}"
  # ...and the shipped wrapper, on the identical fixture, must refuse that second
  # re-invocation. Without this contrast the tuple above proves nothing.
  jq -e '
    .sessionHang.reinvocations == 1 and
    .sessionHang.livenessProofs == 2
  ' "${nsl_root}/cases/budget-refuses-after-liveness/report/lifecycle/lifecycle.json" >/dev/null ||
    fail 'mutation-single-budget-check: the shipped wrapper did not refuse the call the mutant allowed'
  nsl_restore_list_proof
  echo '    mutation-single-budget-check: deleting the post-liveness deadline re-read lets a call start with insufficient budget ✓'

  # ---- Structural-gate self-tests: the source law is non-vacuous -------
  # These prove the pins added at the top of this mode actually refuse a
  # reversion, by running each predicate against a deliberately broken COPY of
  # the wrapper. A structural pin that cannot fail is a comment.
  nsl_gate_copy="${tmp}/gate-mutant.sh"
  nsl_assert_gate_refuses() {
    local label="$1" predicate="$2"
    if eval "${predicate}"; then
      fail "structural gate ${label}: the mutated wrapper was accepted, so that pin is vacuous"
    fi
    echo "      gate refuses ${label} ✓"
  }
  # Unbounded hostname preflight — the exact generation-13 defect. The three
  # timeout lines are stripped from run_hostname_attempt ONLY, leaving a bare
  # `nsc ssh ... hostname` exactly as the pre-repair wrapper had it.
  # `s == 1` and not merely `s`, so only the FIRST timeout site after the
  # function header is stripped; leaving it armed would strip all five.
  # skip=2 drops the --kill-after and duration lines only: the `nsc ssh` line
  # itself must SURVIVE, unbounded, or the fixture would not model the defect.
  awk 'BEGIN{s=0}
    /^run_hostname_attempt\(\) \{$/{s=1}
    s == 1 && /^[[:space:]]+timeout --verbose --signal=TERM \\$/{s=2; skip=2; next}
    skip>0 {skip--; next}
    {print}' "${proof_source}" >"${nsl_gate_copy}"
  # Prove the mutation actually landed and hit the HOSTNAME site specifically,
  # so a self-test cannot pass against an unmutated or wrongly-mutated copy.
  [ "$(rg -c -- '^[[:space:]]+timeout --verbose --signal=TERM \\$' "${nsl_gate_copy}" || true)" -eq 4 ] ||
    fail 'structural gate fixture: the unbounded-preflight mutation did not remove exactly one timeout site'
  # shellcheck disable=SC1003
  rg -qF -- '    nsc ssh --disable-pty "${instance_id}" -- hostname \' "${nsl_gate_copy}" ||
    fail 'structural gate fixture: the mutated copy lost the hostname call site itself'
  # The scanner must now name the hostname site as unbounded.
  nsl_gate_unbounded="$(printf '%s' "$(nsl_ssh_bound_scan "${nsl_gate_copy}")" | cut -d'|' -f2)"
  [ -n "${nsl_gate_unbounded}" ] ||
    fail 'structural gate an unbounded hostname preflight: the scanner named no unbounded site, so that pin is vacuous'
  nsl_assert_gate_refuses 'an unbounded hostname preflight' \
    "nsl_ssh_bounds_ok '${nsl_gate_copy}'"
  # ...and the unmutated wrapper must still be accepted by the same scanner, or
  # the refusal above would be meaningless.
  nsl_ssh_bounds_ok "${proof_source}" ||
    fail 'structural gate: the shipped wrapper is rejected by its own ssh-bounds scanner'
  # Reverted loose byte predicate.
  sed "s|. == \$id or . == (\$id + \"\\\\n\")|tr -d '[:space:]'|" \
    "${proof_source}" >"${nsl_gate_copy}"
  nsl_assert_gate_refuses 'a whitespace-stripping hostname predicate' \
    "rg -qF -- '. == \$id or . == (\$id + \"\\n\")' '${nsl_gate_copy}'"
  # A receipt written inside the terminal close, which would freeze the
  # pre-cleanup snapshot into the only receipt.
  awk '{print} /^close_lane_terminally\(\) \{$/{print "  write_lifecycle_report fail"}' \
    "${proof_source}" >"${nsl_gate_copy}"
  sed -n '/^close_lane_terminally() {$/,/^}$/p' "${nsl_gate_copy}" >"${tmp}/gate-close-body.sh"
  nsl_assert_gate_refuses 'a receipt written inside the terminal close' \
    "! rg -qF 'write_lifecycle_report' '${tmp}/gate-close-body.sh'"
  # A lane that mints or destroys a second instance.
  awk '{print} /^enter_session_hang_lane\(\) \{$/{print "  nsc destroy \"${instance_id}\" --force"}' \
    "${proof_source}" >"${nsl_gate_copy}"
  sed -n '/^enter_session_hang_lane() {$/,/^}$/p' "${nsl_gate_copy}" >"${tmp}/gate-lane-body.sh"
  nsl_assert_gate_refuses 'an instance mutation inside the lane' \
    "! rg -q 'nsc create|nsc destroy' '${tmp}/gate-lane-body.sh'"
  # Pins whose true worst case cannot fit the ratified lane budget. Asserted
  # against the EXTRACTED production bounds validator, not a transcription, so
  # the gate cannot drift away from the arithmetic the wrapper really runs.
  sed 's/^NSC_LIST_TIMEOUT_SECONDS=.*/NSC_LIST_TIMEOUT_SECONDS=40/' \
    "${pins_source}" >"${tmp}/gate-pins.env"
  nsl_assert_gate_refuses 'a pin set whose worst case exceeds the lane budget' \
    "( . '${tmp}/gate-pins.env'; w=\$(( NSC_SESSION_HANG_MAX_REINVOCATIONS * ( (NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS) + (NSC_SESSION_HANG_PER_CALL_TIMEOUT_SECONDS + NSC_SESSION_HANG_KILL_AFTER_SECONDS) ) )); [ \"\${w}\" -le \"\${NSC_SESSION_HANG_LANE_BUDGET_SECONDS}\" ] )"
  # A bounds validator rewritten to charge the SSH calls alone. This is the real
  # production line, mutated in place and re-extracted, so the scoped gate is
  # proven to reject the actual defect rather than a synthetic stand-in.
  # shellcheck disable=SC1003
  sed 's|^    NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS) + (\\$|    0 + 0) + (\\|' \
    "${proof_source}" >"${nsl_gate_copy}"
  cmp -s "${nsl_gate_copy}" "${proof_source}" &&
    fail 'structural gate fixture: the ssh-only bounds mutation changed no production bytes'
  sed -n '/^validate_session_hang_bounds() {$/,/^}$/p' "${nsl_gate_copy}" \
    >"${tmp}/gate-bounds-body.sh"
  nsl_assert_gate_refuses 'an ssh-only worst-case formula that hides the liveness cost' \
    "rg -qF 'NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS' '${tmp}/gate-bounds-body.sh'"
  echo '    session-hang-gate-self-tests: every structural pin refuses its own reversion, so none of them is vacuous ✓'

  # ---- T5d: the ssh-only formula is load-bearing in PRODUCTION ---------
  # The strongest available pairing: mutate the real production arithmetic, run
  # the whole wrapper on the untouched ratified pins, and read the wrapper's own
  # recomputed worst case out of its receipt. Charging the ssh calls alone gives
  # 3 * (60 + 10) = 210 instead of the true 3 * ((20+5) + (60+10)) = 285, so the
  # wrapper would accept a pin set whose real worst case overruns the lane.
  # shellcheck disable=SC1003
  nsl_install_exact_line_mutant \
    bounds-ssh-only \
    '    NSC_LIST_TIMEOUT_SECONDS + NSC_LIST_KILL_AFTER_SECONDS) + (\' \
    '    0 + 0) + (\'
  nsl_run mutation-budget-arithmetic fail NSC_SHIM_SSH_HANG_CALLS=9
  nsl_mutant_worst="$(jq -r '.sessionHang.worstCaseLaneSeconds' \
    "${nsl_report}/lifecycle/lifecycle.json")"
  [ "${nsl_mutant_worst}" -eq 210 ] ||
    fail "mutation-budget-arithmetic: the ssh-only formula produced ${nsl_mutant_worst}s, not the 210s that proves the liveness proofs went uncharged"
  nsl_restore_list_proof
  # ...and the unmutated wrapper must report the true 285, or the contrast above
  # would prove nothing about the shipped bytes.
  jq -e '.sessionHang.worstCaseLaneSeconds == 285' \
    "${nsl_root}/cases/session-hang-exhausted/report/lifecycle/lifecycle.json" >/dev/null ||
    fail 'mutation-budget-arithmetic: the shipped wrapper does not report the true 285s worst case'
  echo '    mutation-budget-arithmetic: charging only the ssh calls drops the wrapper worst case from 285s to 210s, so the liveness proofs are really charged ✓'

  # ---- T11 / clean-path regression -------------------------------------
  # The clean, non-lane path must be completely unchanged: exactly four ssh
  # calls and a lane that was never entered.
  nsl_run session-hang-clean-path pass
  nsl_clean_ssh="$(nsl_count_ssh_calls)"
  [ "${nsl_clean_ssh}" -eq 4 ] ||
    fail "session-hang-clean-path: a clean lifecycle made ${nsl_clean_ssh} ssh calls, not the required four"
  nsl_assert_single_instance_lifecycle session-hang-clean-path
  jq -e '
    .status == "pass" and
    .sessionHang.entered == false and
    .sessionHang.outcome == "not-entered-clean" and
    .sessionHang.reinvocations == 0 and
    .sessionHang.classification == null
  ' "${nsl_report}/lifecycle/lifecycle.json" >/dev/null ||
    fail 'session-hang-clean-path: the clean non-lane path was disturbed by the lane'
  echo '    session-hang-clean-path: a clean run still makes exactly four ssh calls and never enters the lane ✓'

  echo '  Namespace outer lifecycle, pre-created handoff, exact pins, failure collection, exact-id cleanup, and pass ordering are refusal-tested ✓'
  ;;
sit-host-image-binding | sit-host-image)
  # Deterministic offline model of the L9 host-image step. No docker daemon, no
  # network, no cluster, no k3d — the gate runs anywhere `bash`, `jq`, `awk` and
  # `sed` run.
  #
  # WHY THIS EXISTS. The recorded L9 abort in
  # exec/nodes/fleet/evidence/failed-sit-1ab1964-run1 (exit 1 at the export-tag
  # assertion) is a harness bug with a fully deterministic cause: `docker pull
  # name:tag@digest` stores the image under name@digest ONLY and never creates
  # name:tag, on both the classic and the containerd image stores. The pull
  # transcript in that bundle shows exactly that — Docker normalized the header
  # and Status lines to the digest-only reference. So the SIT could only ever
  # reach `k3d image import` on a machine whose daemon already happened to carry
  # that tag from an earlier tag-only pull.
  #
  # WHY IT RUNS PRODUCTION BYTES. The function under test is EXTRACTED from
  # scripts/ci/fleet-sit.sh and sourced, never transcribed here. A copy would
  # drift and could go green while the SIT stayed red.
  #
  # WHAT THE SHIM IS ALLOWED TO MODEL. Only daemon semantics that were observed
  # against a real docker 29.1.3: digest-qualified pull stores by digest; a
  # digest-qualified reference resolves whether or not it carries a tag; `docker
  # image tag` binds a new name to the source's content and overwrites any
  # previous binding. M0 below asserts the shim actually reproduces the recorded
  # failure, so a shim that trivially satisfies everything cannot pass.
  sit_source="scripts/ci/fleet-sit.sh"
  sit_fn="kargo_runtime_verify_host_image"
  sit_assert="${PWD}/scripts/validate/fleet-sit/assert.sh"
  test -s "${sit_assert}" || fail "the SIT assertion library is missing: ${sit_assert}"

  sed -n "/^${sit_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/host-image-fn.sh"
  test -s "${tmp}/host-image-fn.sh" ||
    fail "could not extract ${sit_fn}() from ${sit_source}; this gate must run production bytes, never a copy"
  [ "$(tail -n 1 "${tmp}/host-image-fn.sh")" = '}' ] ||
    fail "the extracted ${sit_fn}() body is unterminated; refusing to assert on a truncated function"
  grep -q 'docker pull' "${tmp}/host-image-fn.sh" ||
    fail "the extracted ${sit_fn}() does not pull an image; the extraction is not the production function"

  # The offline driver. It is generated, not committed, so nothing here can
  # become a second copy of the production logic: it supplies the real
  # sit_fail, sources the extracted function, and shims `docker` as a shell
  # function over a plain state file of daemon-visible references.
  cat >"${tmp}/host-image-driver.sh" <<'HOSTIMAGEDRIVER'
#!/usr/bin/env bash
# Generated by scripts/validate/fleet.sh (sit-host-image-binding). Runs the
# EXTRACTED production kargo_runtime_verify_host_image bytes under the same
# `set -Eeuo pipefail` regime the SIT uses, against a docker shell-function
# shim. Never contacts a daemon, a registry, or a cluster.
set -Eeuo pipefail

assert_lib="$1" # scripts/validate/fleet-sit/assert.sh, for the real sit_fail
fn_file="$2"    # the extracted production function
state="$3"      # "<reference>\t<repo>@<digest>" per daemon-visible reference
report="$4"     # the production function appends its pull log here
image_ref="$5"
digest_ref="$6"
output="$7"

# shellcheck source=/dev/null
source "${assert_lib}"
# shellcheck source=/dev/null
source "${fn_file}"
export LC_ALL=C

# A digest-qualified reference resolves by digest whether or not it also
# carries a tag, so both forms normalize to the same stored key.
shim_normalize() {
  local ref="$1" name
  case "${ref}" in
  *@*)
    name="${ref%@*}"
    case "${name##*/}" in
    *:*) name="${name%:*}" ;;
    esac
    printf '%s@%s' "${name}" "${ref#*@}"
    ;;
  *) printf '%s' "${ref}" ;;
  esac
}

shim_lookup() {
  awk -F '\t' -v ref="$1" '$1 == ref { print $2; hit = 1 } END { exit hit ? 0 : 1 }' "${state}"
}

# `docker tag` overwrites an existing binding, so drop any previous row first.
shim_bind() {
  awk -F '\t' -v ref="$1" '$1 != ref' "${state}" >"${state}.next"
  mv -- "${state}.next" "${state}"
  printf '%s\t%s\n' "$1" "$2" >>"${state}"
}

docker() {
  local sub="$1"
  shift
  case "${sub}" in
  pull)
    local ref="$1" name digest recorded
    case "${ref}" in
    *@sha256:*) ;;
    *)
      echo "shim: only digest-qualified pulls are modeled: ${ref}" >&2
      return 1
      ;;
    esac
    digest="${ref#*@}"
    name="${ref%@*}"
    case "${name##*/}" in
    *:*) name="${name%:*}" ;;
    esac
    # The proven semantics: the tag is discarded and only name@digest is stored.
    recorded="${SHIM_PULL_REPODIGEST:-${name}@${digest}}"
    shim_bind "${name}@${digest}" "${recorded}"
    # Shaped like the recorded transcript in the preserved evidence bundle.
    printf '%s: Pulling from %s\nDigest: %s\nStatus: Downloaded newer image for %s\n%s\n' \
      "${name}@${digest}" "${name#*/}" "${digest}" "${name}@${digest}" "${ref}"
    ;;
  image)
    local action="$1"
    shift
    case "${action}" in
    inspect)
      local ref="$1" key repo_digest
      key="$(shim_normalize "${ref}")"
      repo_digest="$(shim_lookup "${key}")" || {
        echo "Error response from daemon: No such image: ${ref}" >&2
        return 1
      }
      # Only the fields the production assertions read are modeled. On the
      # containerd image store .Id is the image's ROOT DESCRIPTOR digest, so it
      # equals the pin; on the classic graph-driver store it is the config blob
      # digest and cannot. SHIM_INSPECT_ID models that second daemon.
      jq -n --arg ref "${key}" --arg repoDigest "${repo_digest}" \
        --arg id "${SHIM_INSPECT_ID:-}" \
        '[{
          Id: (if $id == "" then ($repoDigest | split("@")[1]) else $id end),
          RepoTags: [$ref],
          RepoDigests: [$repoDigest]
        }]'
      ;;
    tag)
      local src="$1" dst="$2" repo_digest
      # A daemon that accepts the command and changes nothing. Nothing in the
      # docker CLI guarantees an error here, so the harness may not rely on one.
      [ "${SHIM_TAG_NOOP:-0}" != '1' ] || return 0
      repo_digest="$(shim_lookup "$(shim_normalize "${src}")")" || {
        echo "Error response from daemon: No such image: ${src}" >&2
        return 1
      }
      shim_bind "${dst}" "${repo_digest}"
      ;;
    *)
      echo "shim: unmodeled docker image subcommand: ${action}" >&2
      return 1
      ;;
    esac
    ;;
  *)
    echo "shim: unmodeled docker subcommand: ${sub}" >&2
    return 1
    ;;
  esac
}

if [ "${SHIM_SELFTEST:-0}" = '1' ]; then
  # M0: the shim must reproduce the recorded daemon behaviour, or every case
  # below would be asserting against a fiction.
  tag_ref="${image_ref%@*}"
  docker pull "${image_ref}" >>"${report}/kargo-runtime-image-pulls.txt" 2>&1
  docker image inspect "${image_ref}" >"${output}"
  docker image inspect "${digest_ref}" >/dev/null ||
    sit_fail 'the shim did not resolve the digest-only reference after a digest-qualified pull'
  if docker image inspect "${tag_ref}" >/dev/null 2>&1; then
    sit_fail "the shim bound ${tag_ref} on a digest-qualified pull; a real daemon does not"
  fi
  docker image tag "${digest_ref}" "${tag_ref}"
  docker image inspect "${tag_ref}" >/dev/null ||
    sit_fail "the shim did not bind ${tag_ref} after an explicit docker image tag"
  exit 0
fi

kargo_runtime_verify_host_image "${image_ref}" "${digest_ref}" "${output}"
HOSTIMAGEDRIVER

  hia_repo='example.test/kargo'
  hia_pin="sha256:$(printf 'a%.0s' {1..64})"
  hia_other="sha256:$(printf 'b%.0s' {1..64})"
  hia_tag_ref="${hia_repo}:v0.0.0"
  hia_image_ref="${hia_tag_ref}@${hia_pin}"
  hia_digest_ref="${hia_repo}@${hia_pin}"
  hia_status=0

  hia_run() {
    local dir="$1"
    mkdir -p "${dir}/report"
    : >"${dir}/report/kargo-runtime-image-pulls.txt"
    hia_status=0
    bash "${tmp}/host-image-driver.sh" \
      "${sit_assert}" \
      "${tmp}/host-image-fn.sh" \
      "${dir}/state" \
      "${dir}/report" \
      "${hia_image_ref}" \
      "${hia_digest_ref}" \
      "${dir}/image.json" \
      >"${dir}/stdout.txt" 2>"${dir}/stderr.txt" || hia_status=$?
  }

  hia_expect() {
    local label="$1" expected="$2" needle="$3" dir="$4"
    [ "${hia_status}" -eq "${expected}" ] ||
      fail "${label}: expected exit ${expected}, got ${hia_status} — $(tr '\n' ' ' <"${dir}/stderr.txt")"
    [ -z "${needle}" ] || grep -qF -- "${needle}" "${dir}/stderr.txt" ||
      fail "${label}: production failure text did not contain '${needle}' — $(tr '\n' ' ' <"${dir}/stderr.txt")"
  }

  # M0 — the shim reproduces the recorded daemon behaviour (non-vacuity of the
  # model itself, independent of which production bytes are in the tree).
  mkdir -p "${tmp}/m0"
  : >"${tmp}/m0/state"
  SHIM_SELFTEST=1
  export SHIM_SELFTEST
  hia_run "${tmp}/m0"
  unset SHIM_SELFTEST
  hia_expect 'M0 shim fidelity' 0 '' "${tmp}/m0"
  grep -q "Status: Downloaded newer image for ${hia_digest_ref}" "${tmp}/m0/report/kargo-runtime-image-pulls.txt" ||
    fail "M0 shim fidelity: the modeled pull did not normalize to the digest-only reference"
  echo "  M0 digest-qualified pull stores by digest only, never binds the tag, and an explicit tag does ✓"

  # R1 — fresh state, the exact shape of the recorded L9 failure. At the
  # baseline bytes this is red with "did not bind its export tag"; it may only
  # go green by the function itself binding the tag to the pinned digest.
  mkdir -p "${tmp}/r1"
  : >"${tmp}/r1/state"
  hia_run "${tmp}/r1"
  hia_expect 'R1 fresh digest-qualified pull' 0 '' "${tmp}/r1"
  # Asserted on the daemon model, not on the function's word: k3d v5.8 discovers
  # export inputs through RepoTags, so the tag must resolve to the pinned digest.
  grep -qxF "${hia_tag_ref}"$'\t'"${hia_digest_ref}" "${tmp}/r1/state" ||
    fail "R1 fresh digest-qualified pull: ${hia_tag_ref} is not bound to the pinned digest in the daemon model"
  test -s "${tmp}/r1/image.json" ||
    fail "R1 fresh digest-qualified pull: the digest inspection artifact was not written"
  test -s "${tmp}/r1/image-tag.json" ||
    fail "R1 fresh digest-qualified pull: the export-tag inspection artifact was not written (it feeds kargo-runtime-host-images.json)"
  jq -e --arg digest "${hia_pin}" 'any(.[0].RepoDigests[]?; endswith("@" + $digest))' \
    "${tmp}/r1/image-tag.json" >/dev/null ||
    fail "R1 fresh digest-qualified pull: the retained export-tag inspection does not carry the pinned digest"
  echo "  R1 the recorded L9 failure is gone and the export tag resolves to the pinned digest ✓"

  # R2 — a warm daemon whose :v0.0.0 tag was left pointing at DIFFERENT content
  # by an earlier tag-only pull, plus a tag command that silently does nothing.
  # An existence-only check passes here. The pinned-digest check must not.
  mkdir -p "${tmp}/r2"
  printf '%s\t%s\n' "${hia_tag_ref}" "${hia_repo}@${hia_other}" >"${tmp}/r2/state"
  SHIM_TAG_NOOP=1
  export SHIM_TAG_NOOP
  hia_run "${tmp}/r2"
  unset SHIM_TAG_NOOP
  hia_expect 'R2 stale warm-daemon tag' 1 'the export tag does not resolve to the pinned digest' "${tmp}/r2"
  echo "  R2 a stale cached tag pointing at other content is rejected, so the assertion is not existence-only ✓"

  # R3 — the pull succeeds but the pulled bytes do not carry the pin. The
  # original immutable-digest guard must still be the thing that stops it.
  mkdir -p "${tmp}/r3"
  : >"${tmp}/r3/state"
  SHIM_PULL_REPODIGEST="${hia_repo}@${hia_other}"
  export SHIM_PULL_REPODIGEST
  hia_run "${tmp}/r3"
  unset SHIM_PULL_REPODIGEST
  hia_expect 'R3 pulled bytes without the pin' 1 'host image does not carry the pinned digest' "${tmp}/r3"
  grep -qxF "${hia_tag_ref}"$'\t'"${hia_digest_ref}" "${tmp}/r3/state" &&
    fail "R3 pulled bytes without the pin: the export tag was bound even though the digest guard failed"
  echo "  R3 an image whose RepoDigests omit the pin is still rejected by the immutable-digest guard ✓"

  # R4 — the store-type assertion. The L9 save->import chain preserves the
  # pinned INDEX digest only because this daemon runs the containerd image
  # store. A classic graph-driver daemon reports a config blob digest as .Id,
  # where the chain silently cannot hold; that must fail here, precisely, and
  # not three steps later as an ambiguous node-digest mismatch.
  mkdir -p "${tmp}/r4"
  : >"${tmp}/r4/state"
  SHIM_INSPECT_ID="sha256:$(printf 'd%.0s' {1..64})"
  export SHIM_INSPECT_ID
  hia_run "${tmp}/r4"
  unset SHIM_INSPECT_ID
  hia_expect 'R4 classic image store' 1 'not running the containerd image store' "${tmp}/r4"
  echo "  R4 a classic-store daemon, whose .Id can never equal the pinned index digest, is rejected at the source ✓"
  ;;
sit-node-image-import | sit-node-image)
  # Ordinary fleet CI already invokes this mode. Run the outer lifecycle model
  # first so the Namespace refusal matrix cannot be omitted from the standard
  # source gate while scripts/ci/fleet.sh remains outside this worker's scope.
  bash "$0" sit-namespace-lifecycle
  # Deterministic offline model of the L9 node-image IMPORT step, the leg that
  # follows the host-image binding above. No docker daemon, no network, no
  # cluster, no k3d — the gate runs anywhere `bash`, `jq`, `awk` and `sed` run.
  #
  # WHY THIS EXISTS. The recorded L9 abort in
  # exec/nodes/fleet/evidence/failed-sit-c064c9c-run1 stacked TWO defects.
  # (a) `k3d image import` runs `ctr image import --all-platforms` inside the
  # node (k3d v5.8.3, pkg/client/tools.go:143). On a containerd-image-store
  # daemon a digest-qualified pull fetches ONLY the linux/amd64 child while
  # recording the whole multi-platform index as the image root, so the archive
  # `docker save` emits is partial and an all-platforms walk aborts on the
  # first absent child with `ctr: content digest sha256:…: not found`.
  # (b) k3d's tools-mode importer never RETURNS that per-node error: it logs
  # ERRO, returns nil, prints "Successfully imported image(s)" and exits 0. The
  # preserved transcript carries exactly that shape three times, and the SIT —
  # under `set -Eeuo pipefail` — walked straight past all three, only failing
  # later at the honest node-inventory assertion.
  #
  # WHY IT RUNS PRODUCTION BYTES. Every function under test is EXTRACTED from
  # scripts/ci/fleet-sit.sh and sourced, never transcribed here. A copy would
  # drift and could go green while the SIT stayed red.
  #
  # WHAT THE SHIM IS ALLOWED TO MODEL. Only semantics the evidence bundle and
  # the k3d/containerd sources establish: an unfiltered `docker image save`
  # streams an archive whose root is the pinned index digest; walking every
  # child of that index fails on the child the partial pull never fetched;
  # `--platform linux/amd64` scopes the walk to content that is present. M0
  # asserts the shim reproduces the RECORDED failure text, so a shim that
  # trivially accepts everything cannot pass.
  sit_source="scripts/ci/fleet-sit.sh"
  sit_assert="${PWD}/scripts/validate/fleet-sit/assert.sh"
  test -s "${sit_assert}" || fail "the SIT assertion library is missing: ${sit_assert}"
  # The image coordinates come from the SIT's own pin file, so these fixtures
  # can never drift away from the images the SIT actually imports.
  # shellcheck source=scripts/validate/fleet-sit/pins.env disable=SC1091
  source ./scripts/validate/fleet-sit/pins.env

  nii_fns="${tmp}/node-image-fns.sh"
  : >"${nii_fns}"
  for nii_fn in \
    namespace_ctr \
    namespace_crictl \
    kargo_runtime_canonical_image_tag \
    kargo_runtime_ctr_saved_display_tag \
    kargo_runtime_import_node_image \
    kargo_runtime_assert_import_transcript \
    kargo_runtime_verify_node_image \
    kargo_runtime_alias_image_ref \
    kargo_runtime_image_slug \
    kargo_runtime_alias_node_image \
    kargo_runtime_verify_cri_image \
    kargo_runtime_probe_cri_reference \
    kargo_runtime_assert_cri_reference \
    kargo_runtime_bind_node_images; do
    sed -n "/^${nii_fn}() {\$/,/^}\$/p" "${sit_source}" >"${tmp}/nii-fn.sh"
    test -s "${tmp}/nii-fn.sh" ||
      fail "could not extract ${nii_fn}() from ${sit_source}; this gate must run production bytes, never a copy"
    [ "$(tail -n 1 "${tmp}/nii-fn.sh")" = '}' ] ||
      fail "the extracted ${nii_fn}() body is unterminated; refusing to assert on a truncated function"
    cat "${tmp}/nii-fn.sh" >>"${nii_fns}"
  done
  grep -q 'docker image save' "${nii_fns}" ||
    fail "the extracted import function does not stream a docker image save; the extraction is not the production function"
  grep -q -- '--platform linux/amd64' "${nii_fns}" ||
    fail "the extracted import function does not scope the node-side import to linux/amd64"
  grep -qF '/vendor/containerd/ctr --address /var/run/containerd/containerd.sock' "${nii_fns}" ||
    fail "the extracted platform ctr seam does not target the reviewed containerd socket"
  grep -qF -- '--namespace k8s.io "$@"' "${nii_fns}" ||
    fail "the extracted platform ctr seam does not target the k8s.io namespace the CRI reads"
  grep -qF 'k3s crictl "$@"' "${nii_fns}" ||
    fail "the extracted CRI seam does not use built-in k3s crictl"
  # The repair's own bytes, guarded the same way. The ORCHESTRATION is extracted
  # too (kargo_runtime_bind_node_images), so every case below drives the real
  # call sites — a gate that only extracted the helpers could stay green while
  # production never called them.
  grep -q -- 'images tag' "${nii_fns}" ||
    fail "the extracted functions never create a containerd image alias; the extraction is not the production repair"
  grep -q -- 'namespace_crictl images -o json' "${nii_fns}" ||
    fail "the extracted functions never read the CRI image inventory"
  grep -q -- 'namespace_crictl inspecti -o json' "${nii_fns}" ||
    fail "the extracted functions never resolve the exact combined workload reference through the CRI"
  # The no-force rule, read off EXECUTABLE ARGV rather than prose: production
  # explains at length why it omits --force, and a check that greps the whole
  # extraction would red on those very comments. Both directions are then
  # positive-controlled, so this can neither false-red on documentation nor
  # stay silently green if it stops seeing the flag at all.
  nii_tag_argv() {
    grep -F 'namespace_ctr images tag' "$1" | grep -v '^[[:space:]]*#'
  }
  nii_forces() {
    [ "$(nii_tag_argv "$1" | grep -cF -- '--force')" -gt 0 ]
  }
  [ -n "$(nii_tag_argv "${nii_fns}")" ] ||
    fail "the extracted alias step carries no ctr images tag argv at all"
  ! nii_forces "${nii_fns}" ||
    fail "the extracted alias step passes --force; a name collision on a fresh per-run cluster must fail closed, not be replaced"
  sed 's/namespace_ctr images tag/& --force/' "${nii_fns}" \
    >"${tmp}/node-image-fns-force.sh"
  nii_forces "${tmp}/node-image-fns-force.sh" ||
    fail "the no-force check cannot see --force even when it is injected into the alias argv, so its silence proves nothing"
  {
    cat "${nii_fns}"
    printf '  # a comment mentioning --force must never red this gate\n'
  } >"${tmp}/node-image-fns-forceprose.sh"
  ! nii_forces "${tmp}/node-image-fns-forceprose.sh" ||
    fail "the no-force check reds on prose rather than on argv"
  # The literal call-site bytes, deliberately unexpanded: this asserts what
  # production SOURCE says, not what a shell would substitute.
  # shellcheck disable=SC2016
  grep -qF 'kargo_runtime_alias_node_image "${pairs[i]}"' "${nii_fns}" ||
    fail "the extracted orchestration never calls the alias step; the gate would be asserting on a call site production does not have"

  # The offline driver. Generated, not committed, so nothing here can become a
  # second copy of the production logic: it supplies the real sit_fail, sources
  # the extracted functions, and shims `docker` (and the node-side `ctr` it
  # execs) as shell functions over plain state files.
  cat >"${tmp}/node-image-driver.sh" <<'NODEIMAGEDRIVER'
#!/usr/bin/env bash
# Generated by scripts/validate/fleet.sh (sit-node-image-import). Runs the
# EXTRACTED production node-import bytes under the same `set -Eeuo pipefail`
# regime the SIT uses, against docker/ctr shell-function shims. Never contacts
# a daemon, a registry, or a cluster.
set -Eeuo pipefail

assert_lib="$1" # scripts/validate/fleet-sit/assert.sh, for the real sit_fail
fn_file="$2"    # the extracted production functions
state_dir="$3"  # the daemon-side and node-side model state
report="$4"     # the production import function appends its transcript here
case_name="$5"
shift 5

# shellcheck source=/dev/null
source "${assert_lib}"
# shellcheck source=/dev/null
source "${fn_file}"

node='k3d-fleet-sit-93320-server-0'
host_state="${state_dir}/host-images.tsv" # <tag> <pinned index digest> <absent child>
node_state="${state_dir}/node-images.tsv" # <stored name> <target digest>
images="${state_dir}/images.tsv"          # <tag> <pinned index digest>
cri_ids="${state_dir}/cri-ids.tsv"        # <target digest> <recorded CRI image id>
cri_base="${state_dir}/cri-base.tsv"      # <target digest> <name>, normally pulled images
attempts="${state_dir}/crictl-inspecti-attempts.txt"
# The SIT scratch root the production resolver puts its TRANSIENT probe stderr
# in. Modeling it here keeps that file out of the modeled report exactly as it
# is out of the real one, so the gate would notice if it ever moved back.
sit_tmp_root="${state_dir}"

# Modeled time. The production resolver sleeps between attempts; offline the
# bound that matters is its ATTEMPT CEILING, which the gate asserts by counting
# the recorded inspecti attempts. Waiting real seconds would only slow the gate
# down without testing anything.
sleep() { :; }

shim_host_field() {
  awk -F '\t' -v ref="$1" -v col="$2" \
    '$1 == ref { print $col; hit = 1 } END { exit hit ? 0 : 1 }' "${host_state}"
}

shim_save() {
  local ref="$1" digest
  digest="$(shim_host_field "${ref}" 2)" || {
    echo "Error response from daemon: No such image: ${ref}" >&2
    return 1
  }
  # An UNFILTERED save keeps the archive root at the original pinned
  # multi-platform index — that is what makes the node record's target digest
  # equal the immutable pin — so the marker stream carries exactly that root.
  printf 'FLEETSIT-ARCHIVE\t%s\t%s\n' "${ref}" "${digest}"
}

shim_ctr_list() {
  cat "${state_dir}/inventory-header.txt"
  [ ! -s "${state_dir}/inventory-base.txt" ] || cat "${state_dir}/inventory-base.txt"
  local ref digest
  while IFS=$'\t' read -r ref digest; do
    [ -n "${ref}" ] || continue
    printf '%s application/vnd.oci.image.index.v1+json %s 42.0 MiB linux/amd64 io.cri-containerd.image=managed\n' \
      "${ref}" "${digest}"
  done <"${node_state}"
}

shim_ctr_node_target() {
  awk -F '\t' -v ref="$1" \
    '$1 == ref { print $2; hit = 1 } END { exit hit ? 0 : 1 }' "${node_state}"
}

# containerd 1.7 `ctr images tag` in its default local mode retrieves the source
# image OBJECT and rewrites only its Name, so the new name inherits the source's
# target descriptor verbatim — and ctr never checks that a digest-shaped name
# agrees with that target, which is exactly why a wrong digest alias is possible
# and must be caught by re-reading state. Without --force an existing target
# name is a hard error rather than a replacement.
shim_ctr_tag() {
  local source="${1:-}" target="${2:-}" digest
  { [ -n "${source}" ] && [ -n "${target}" ]; } || {
    echo "shim: ctr images tag takes <source> <target>" >&2
    return 1
  }
  digest="$(shim_ctr_node_target "${source}")" || {
    echo "ctr: image \"${source}\": not found" >&2
    return 1
  }
  if shim_ctr_node_target "${target}" >/dev/null; then
    echo "ctr: image \"${target}\": already exists" >&2
    return 1
  fi
  printf '%s\t%s\n' "${target}" "${digest}" >>"${node_state}"
  printf '%s\n' "${target}"
}

# The CRI projection. containerd's CRI groups stored NAMES by the image they
# resolve to; repoTags come from tag-shaped names and repoDigests from
# digest-shaped NAMES ONLY — never synthesized from a record's target
# descriptor. `id` is the image's own config-level identity, which is NOT the
# ctr target digest, so the model may not derive it: it comes from cri-ids.tsv,
# recorded verbatim from the preserved run.
cri_entries() {
  {
    awk -F '\t' 'NF >= 2 && $1 != "" { print $2 "\t" $1 }' "${node_state}"
    [ ! -s "${cri_base}" ] || cat "${cri_base}"
  } | LC_ALL=C sort | jq -R -s --rawfile ids "${cri_ids}" '
    ($ids | split("\n") | map(select(length > 0) | split("\t"))) as $idmap |
    split("\n") | map(select(length > 0) | split("\t")) |
    group_by(.[0]) |
    map(
      (.[0][0]) as $target |
      {
        id: (($idmap | map(select(.[0] == $target)) | first | .[1]) // $target),
        repoTags: [ .[] | .[1] | select(contains("@") | not) ],
        repoDigests: [ .[] | .[1] | select(contains("@")) ]
      }
    ) | sort_by(.repoTags, .repoDigests)
  '
}

# distribution/reference.ParseDockerRef: a reference carrying a digest resolves
# by DROPPING its tag, and the remainder is matched against stored names
# exactly. This one line is the whole reason the tag-only node state failed L9.
cri_resolve_name() {
  local ref="$1" name digest repo
  case "${ref}" in
  *@*)
    digest="${ref##*@}"
    name="${ref%@*}"
    case "${name##*/}" in
    *:*) repo="${name%:*}" ;;
    *) repo="${name}" ;;
    esac
    printf '%s@%s' "${repo}" "${digest}"
    ;;
  *) printf '%s' "${ref}" ;;
  esac
}

shim_crictl() {
  local verb="${1:-}"
  shift 2>/dev/null || true
  local format='' ref=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -o | --output)
      format="$2"
      shift 2
      ;;
    -o=* | --output=*)
      format="${1#*=}"
      shift
      ;;
    -*) shift ;;
    *)
      ref="$1"
      shift
      ;;
    esac
  done
  [ "${format}" = 'json' ] || {
    echo "shim: unmodeled crictl output format: '${format}'" >&2
    return 1
  }
  local lookup entry
  case "${verb}" in
  images | image)
    cri_entries | jq '{images: .}'
    ;;
  inspecti)
    printf '%s\n' "${ref}" >>"${attempts}"
    lookup="$(cri_resolve_name "${ref}")"
    entry="$(cri_entries | jq -c --arg name "${lookup}" '
      [ .[] | select(any(.repoTags[], .repoDigests[]; . == $name)) ] | first // empty')"
    [ -n "${entry}" ] || {
      # Not-found text varies by version; production gates on the exit status
      # and its own jq predicates, never on these bytes.
      printf 'FATA[0000] no such image "%s"\n' "${ref}" >&2
      return 1
    }
    jq -n --argjson status "${entry}" '{status: $status}'
    ;;
  *)
    echo "shim: unmodeled crictl verb: ${verb}" >&2
    return 1
    ;;
  esac
}

shim_ctr() {
  local namespace='' platform='' all_platforms=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --namespace | -n)
      namespace="$2"
      shift 2
      ;;
    --namespace=*)
      namespace="${1#*=}"
      shift
      ;;
    *) break ;;
    esac
  done
  local group="${1:-}" verb="${2:-}"
  case "${group}" in
  image | images) ;;
  *)
    echo "shim: unmodeled ctr group: ${group}" >&2
    return 1
    ;;
  esac
  # The node inventory and the crictl assertion both read k8s.io; an import
  # into any other namespace would be invisible to them.
  [ "${namespace}" = 'k8s.io' ] ||
    {
      echo "shim: the node inventory requires namespace k8s.io, got '${namespace}'" >&2
      return 1
    }
  shift 2 2>/dev/null || true
  case "${verb}" in
  list | ls)
    shim_ctr_list
    return 0
    ;;
  tag)
    shim_ctr_tag "$@"
    return
    ;;
  import) ;;
  *)
    echo "shim: unmodeled ctr verb: ${verb}" >&2
    return 1
    ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --all-platforms)
      all_platforms=1
      shift
      ;;
    --platform)
      platform="$2"
      shift 2
      ;;
    --platform=*)
      platform="${1#*=}"
      shift
      ;;
    *) shift ;; # the archive operand ('-' or a tarball path)
    esac
  done
  local marker ref digest missing
  IFS=$'\t' read -r marker ref digest || marker=''
  [ "${marker}" = 'FLEETSIT-ARCHIVE' ] ||
    {
      echo "shim: the import stream is not a modeled docker save archive" >&2
      return 1
    }
  missing="$(shim_host_field "${ref}" 3)"
  if [ "${all_platforms}" -eq 1 ] || [ "${platform}" != 'linux/amd64' ]; then
    # The recorded failure, reproduced: walking every child of the pinned index
    # reaches a child the digest-qualified pull never fetched. The byte shape is
    # taken from failed-sit-c064c9c-run1/kargo-runtime-image-imports.txt.
    printf 'ctr: content digest %s: not found\n' "${missing}" >&2
    return 1
  fi
  # Current Wolfi ctr prints an adjacent saved-name / root-descriptor pair.
  printf '%s\t\tsaved\n' "${ref//-/ }"
  printf 'application/vnd.docker.distribution.manifest.list.v2+json %s\n' "${digest}"
  printf '%s\t%s\n' "${ref}" "${digest}" >>"${node_state}"
}

# Override the extracted production seams after sourcing them. The source
# assertions above separately bind the exact platform socket/namespace and
# `k3s crictl` argv; these functions model their state effects offline.
namespace_ctr() { shim_ctr --namespace k8s.io "$@"; }
namespace_crictl() { shim_crictl "$@"; }

docker() {
  local sub="$1"
  shift
  case "${sub}" in
  image | images)
    case "${1:-}" in
    save)
      shift
      shim_save "$@"
      ;;
    *)
      echo "shim: unmodeled docker image subcommand: ${1:-}" >&2
      return 1
      ;;
    esac
    ;;
  save) shim_save "$@" ;;
  exec)
    while [ "$#" -gt 0 ]; do
      case "$1" in
      -i | -t | -it | --interactive | --tty) shift ;;
      *) break ;;
      esac
    done
    [ "${1:-}" = "${node}" ] ||
      {
        echo "shim: unmodeled exec target: ${1:-}" >&2
        return 1
      }
    shift
    case "${1:-}" in
    ctr)
      shift
      shim_ctr "$@"
      ;;
    crictl)
      shift
      shim_crictl "$@"
      ;;
    *)
      echo "shim: unmodeled exec command: ${1:-}" >&2
      return 1
      ;;
    esac
    ;;
  *)
    echo "shim: unmodeled docker subcommand: ${sub}" >&2
    return 1
    ;;
  esac
}

pairs=()
while IFS=$'\t' read -r nii_tag nii_pin; do
  [ -n "${nii_tag}" ] || continue
  pairs+=("${nii_tag}" "${nii_pin}")
done <"${images}"

transcript="${report}/kargo-runtime-image-imports.txt"
inventory="${report}/kargo-runtime-node-ctr-images.txt"
cri_images="${report}/kargo-runtime-node-images.json"

# Put the node into a chosen state without running the production path, so the
# CRI-side predicates can be aimed at states the fixed path can no longer
# produce (a stale tag, a wrong alias, the recorded tag-only state).
seed_node_state() {
  : >"${node_state}"
  while [ "$#" -ge 2 ]; do
    printf '%s\t%s\n' "$1" "$2" >>"${node_state}"
    shift 2
  done
  [ "$#" -eq 0 ] || {
    echo "driver: seed takes <name> <digest> pairs" >&2
    exit 2
  }
}

case "${case_name}" in
m0-k3d-argv)
  # k3d v5.8.3 pkg/client/tools.go:143 argv, replayed through the shim over the
  # same unfiltered save stream. Nothing production is involved: this asserts
  # the MODEL, not the fix.
  docker image save "${pairs[0]}" |
    docker exec -i "${node}" ctr --namespace k8s.io image import --all-platforms -
  ;;
fixed-path)
  # The whole production leg, orchestration bytes included: import, transcript
  # acceptance, alias creation, and every node/CRI assertion, driven by the
  # extracted call sites rather than by this driver.
  kargo_runtime_bind_node_images "${pairs[@]}"
  ;;
project-cri)
  seed_node_state "$@"
  namespace_crictl images -o json >"${cri_images}"
  ;;
seeded-cri)
  seed_node_state "$@"
  namespace_crictl images -o json >"${cri_images}"
  kargo_runtime_verify_cri_image "${cri_images}" "${pairs[0]}" \
    "$(kargo_runtime_alias_image_ref "${pairs[0]}" "${pairs[1]}")"
  ;;
transcript)
  kargo_runtime_assert_import_transcript "$1" "${pairs[@]}"
  ;;
verify-node)
  kargo_runtime_verify_node_image "$1" "$2" "$3"
  ;;
verify-cri)
  # The production same-entry predicate aimed at a caller-supplied CRI listing,
  # so shapes a well-formed containerd store cannot produce (duplicate entries,
  # duplicate array elements) can still be proven to fail closed.
  kargo_runtime_verify_cri_image "$1" "$2" "$3"
  ;;
*)
  echo "driver: unknown case ${case_name}" >&2
  exit 2
  ;;
esac
NODEIMAGEDRIVER

  # --- recorded fixtures -----------------------------------------------------
  # The three index children the partial archives lacked, verbatim from
  # failed-sit-c064c9c-run1/kargo-runtime-image-imports.txt. They are historical
  # facts of that run, so they stay literal while the pins above come from
  # pins.env.
  nii_kargo_missing='sha256:a5e2a943cd2b43d87dbebb1d351581fbc5c7bff30d3b5aa4ee3c145dca6fd839'
  nii_rollouts_missing='sha256:864d749d420021ad185cdea878d98b1d3b6be5b337acdb5258708919d5adc926'
  nii_analysis_missing='sha256:71b0cbca78cef3413c843ed16136b822b6deefc6dea540f0f77b0e39eb991dc5'
  nii_other="sha256:$(printf 'c%.0s' {1..64})"
  nii_kargo_tag="${KARGO_IMAGE_REPOSITORY}:${KARGO_IMAGE_TAG}"
  nii_rollouts_tag="${ROLLOUTS_IMAGE_REPOSITORY}:${ROLLOUTS_IMAGE_TAG}"
  nii_analysis_tag="${ANALYSIS_IMAGE_REPOSITORY}:${ANALYSIS_IMAGE_TAG}"
  nii_cr=$'\r'

  # k3d's logrus renders `<colour>LEVEL<reset>[<elapsed>] %-44s ` — reproducing
  # that format (rather than pasting escape bytes) keeps the fixture readable
  # while staying byte-identical to the preserved transcript.
  nii_info() { printf '\033[36mINFO\033[0m[%s] %-44s \n' "$1" "$2"; }

  nii_k3d_block() {
    local t_import="$1" t_erro="$2" t_tail="$3" tarball="$4" missing="$5"
    local cluster='fleet-sit-93320'
    local k3d_node="k3d-${cluster}-server-0"
    nii_info '0000' "Importing image(s) into cluster '${cluster}'"
    nii_info '0000' 'Starting new tools node...'
    nii_info '0000' "Starting node 'k3d-${cluster}-tools'"
    nii_info '0000' 'Saving 1 image(s) from runtime...'
    nii_info "${t_import}" 'Importing images into nodes...'
    nii_info "${t_import}" "Importing images from tarball '/k3d/images/k3d-${cluster}-images-${tarball}.tar' into node '${k3d_node}'..."
    # The ERRO record embeds the container's own CR-terminated ctr line; logrus
    # appends its single trailing space after that embedded newline.
    printf '\033[31mERRO\033[0m[%s] %-44s \n' "${t_erro}" \
      "failed to import images in node '${k3d_node}': Exec process in node '${k3d_node}' failed with exit code '1': Logs from failed access process:
ctr: content digest ${missing}: not found${nii_cr}"
    nii_info "${t_erro}" 'Removing the tarball(s) from image volume...'
    nii_info "${t_tail}" 'Removing k3d-tools node...'
    nii_info "${t_tail}" 'Successfully imported image(s)'
    nii_info "${t_tail}" 'Successfully imported 1 image(s) into 1 cluster(s)'
  }

  # The preserved failed transcript, regenerated byte-for-byte.
  {
    nii_k3d_block '0003' '0005' '0006' '20260729130749' "${nii_kargo_missing}"
    nii_k3d_block '0002' '0003' '0004' '20260729130756' "${nii_rollouts_missing}"
    nii_k3d_block '0001' '0002' '0003' '20260729130801' "${nii_analysis_missing}"
  } >"${tmp}/recorded-imports.txt"
  # The preserved evidence bundle is not carried in this repository, so the
  # fixture is bound to it by CHECKSUM instead: this is the sha256 of
  # failed-sit-c064c9c-run1/kargo-runtime-image-imports.txt (39 lines). If the
  # regeneration above ever stops reproducing those exact bytes — padding,
  # escape sequences, the embedded CR and all — R2 stops being a test of the
  # real recorded transcript and this gate says so instead of quietly drifting.
  nii_recorded_sha256='52b00369f07dc964ef4bbfa152a6eebf40421b7169b40e73c7bf4a31087ce62f'
  printf '%s  %s\n' "${nii_recorded_sha256}" "${tmp}/recorded-imports.txt" |
    sha256sum --check --status ||
    fail 'the regenerated fixture is not byte-identical to the preserved failed-run import transcript'
  grep -qF "ctr: content digest ${nii_kargo_missing}: not found" "${tmp}/recorded-imports.txt" ||
    fail 'the regenerated failed transcript lost the recorded ctr error line'
  [ "$(grep -cF 'Successfully imported image(s)' "${tmp}/recorded-imports.txt")" -eq 3 ] ||
    fail "the regenerated failed transcript lost k3d's false-success lines"

  # The recorded node inventory, from the same bundle: the real header and real
  # k3s/Argo rows that WERE present, with the column padding (which the
  # production parser never reads) trimmed. No Kargo/Rollouts/BusyBox row —
  # that absence is what the honest gate reported.
  cat >"${tmp}/inventory-header.txt" <<'NIIHEADER'
REF                                                                                                                TYPE                                                      DIGEST                                                                  SIZE      PLATFORMS                                                                                              LABELS
NIIHEADER
  cat >"${tmp}/inventory-base.txt" <<'NIIBASE'
docker.io/rancher/klipper-helm:v0.9.3-build20241008                                                                application/vnd.docker.distribution.manifest.list.v2+json sha256:73ff7ef399717ba8339559054557bd427bdafb47db112165a8c0c358d1ca0283 67.2 MiB  linux/amd64,linux/arm,linux/arm64/v8                                                                   io.cri-containerd.image=managed
docker.io/rancher/klipper-helm@sha256:73ff7ef399717ba8339559054557bd427bdafb47db112165a8c0c358d1ca0283             application/vnd.docker.distribution.manifest.list.v2+json sha256:73ff7ef399717ba8339559054557bd427bdafb47db112165a8c0c358d1ca0283 67.2 MiB  linux/amd64,linux/arm,linux/arm64/v8                                                                   io.cri-containerd.image=managed
quay.io/argoproj/argocd:v3.4.5                                                                                     application/vnd.docker.distribution.manifest.list.v2+json sha256:224e454cfd8c1818fec3ed17b72b2034c9a3915fa819e1dcccafc753776d446a 184.8 MiB linux/amd64,linux/arm64,linux/ppc64le,linux/s390x                                                      io.cri-containerd.image=managed
quay.io/argoproj/argocd@sha256:224e454cfd8c1818fec3ed17b72b2034c9a3915fa819e1dcccafc753776d446a                    application/vnd.docker.distribution.manifest.list.v2+json sha256:224e454cfd8c1818fec3ed17b72b2034c9a3915fa819e1dcccafc753776d446a 184.8 MiB linux/amd64,linux/arm64,linux/ppc64le,linux/s390x                                                      io.cri-containerd.image=managed
NIIBASE

  # The CRI-side fixtures, all verbatim from
  # failed-sit-ade9451-run1/kargo-runtime-node-images.json (bundle manifest
  # a5c8c034d0145b6fb6217520a4917024bdade47b215e181a1a1915822bd0f26f). CRI
  # reports an image's own config-level identity as `id`, which is NOT the ctr
  # target digest, so these are supplied as recorded facts rather than derived.
  # klipper-helm and argocd are the decisive CONTROL GROUP: images the node
  # pulled normally hold both a tag and a digest NAME, and therefore project a
  # populated repoDigests, while the three imported ones projected none.
  nii_klipper_digest='sha256:73ff7ef399717ba8339559054557bd427bdafb47db112165a8c0c358d1ca0283'
  nii_klipper_id='sha256:4e0aed78b287d2b5e7fc96d81ccef135d5bd0feb2a4c27aeda3b03bcc4882e9d'
  nii_argocd_digest='sha256:224e454cfd8c1818fec3ed17b72b2034c9a3915fa819e1dcccafc753776d446a'
  nii_argocd_id='sha256:92bb8fd739f98162e03bc377ed9f19a49aa525973d6bfe011a7b426afc82a85a'
  printf '%s\t%s\n' \
    "${KARGO_IMAGE_DIGEST}" 'sha256:722c772753348aa5e71c029417e8a7c065b4a3cb5fe68b82762ab27ba8b1c0d6' \
    "${ROLLOUTS_IMAGE_DIGEST}" 'sha256:265f91722eb29960a548712f8dca5be653a15bbd68fba969031a4f1623df0d73' \
    "${ANALYSIS_IMAGE_DIGEST}" 'sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d' \
    "${nii_klipper_digest}" "${nii_klipper_id}" \
    "${nii_argocd_digest}" "${nii_argocd_id}" \
    >"${tmp}/cri-ids.tsv"
  printf '%s\t%s\n' \
    "${nii_klipper_digest}" 'docker.io/rancher/klipper-helm:v0.9.3-build20241008' \
    "${nii_klipper_digest}" "docker.io/rancher/klipper-helm@${nii_klipper_digest}" \
    "${nii_argocd_digest}" 'quay.io/argoproj/argocd:v3.4.5' \
    "${nii_argocd_digest}" "quay.io/argoproj/argocd@${nii_argocd_digest}" \
    >"${tmp}/cri-base.tsv"

  # The names the CRI lookup of each pinned `tag@digest` workload reference
  # actually resolves to, spelled out here so the expectations below are the
  # gate's own statement of the contract rather than a re-run of production's
  # derivation.
  nii_kargo_alias="${KARGO_IMAGE_REPOSITORY}@${KARGO_IMAGE_DIGEST}"
  nii_rollouts_alias="${ROLLOUTS_IMAGE_REPOSITORY}@${ROLLOUTS_IMAGE_DIGEST}"
  nii_analysis_alias="${ANALYSIS_IMAGE_REPOSITORY}@${ANALYSIS_IMAGE_DIGEST}"
  # The only pinned image whose canonical spelling differs from its stored one,
  # so it is the one that can prove the occurrence count is canonical.
  nii_analysis_tag_short="${nii_analysis_tag#docker.io/library/}"

  nii_status=0
  nii_case() {
    local dir="${tmp}/$1" case_name="$2" fns="${3:-${nii_fns}}"
    shift 3 2>/dev/null || shift "$#"
    mkdir -p "${dir}/report"
    cp "${tmp}/cri-ids.tsv" "${dir}/cri-ids.tsv"
    cp "${tmp}/cri-base.tsv" "${dir}/cri-base.tsv"
    : >"${dir}/crictl-inspecti-attempts.txt"
    printf '%s\t%s\t%s\n' \
      "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}" "${nii_kargo_missing}" \
      "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}" "${nii_rollouts_missing}" \
      "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}" "${nii_analysis_missing}" \
      >"${dir}/host-images.tsv"
    printf '%s\t%s\n' \
      "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}" \
      "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}" \
      "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}" \
      >"${dir}/images.tsv"
    : >"${dir}/node-images.tsv"
    cp "${tmp}/inventory-header.txt" "${dir}/inventory-header.txt"
    cp "${tmp}/inventory-base.txt" "${dir}/inventory-base.txt"
    nii_status=0
    bash "${tmp}/node-image-driver.sh" \
      "${sit_assert}" "${fns}" "${dir}" "${dir}/report" "${case_name}" "$@" \
      >"${dir}/stdout.txt" 2>"${dir}/stderr.txt" || nii_status=$?
  }

  nii_expect() {
    local label="$1" expected="$2" needle="$3" dir="${tmp}/$4"
    [ "${nii_status}" -eq "${expected}" ] ||
      fail "${label}: expected exit ${expected}, got ${nii_status} — $(tr '\n' ' ' <"${dir}/stderr.txt")"
    [ -z "${needle}" ] || grep -qF -- "${needle}" "${dir}/stderr.txt" ||
      fail "${label}: production failure text did not contain '${needle}' — $(tr '\n' ' ' <"${dir}/stderr.txt")"
  }

  # M0 — the shim reproduces the RECORDED failure when replayed with k3d's own
  # argv. Without this every case below would be asserting against a fiction.
  nii_case m0 m0-k3d-argv
  nii_expect 'M0 shim fidelity' 1 "ctr: content digest ${nii_kargo_missing}: not found" m0
  nii_m0_line="$(grep -m 1 '^ctr: ' "${tmp}/m0/stderr.txt")"
  grep -qF -- "${nii_m0_line}" "${tmp}/recorded-imports.txt" ||
    fail 'M0 shim fidelity: the modeled ctr error is not the line the preserved transcript recorded'
  echo "  M0 replaying k3d's own ctr image import --all-platforms argv reproduces the recorded content-digest failure ✓"

  # M1 — model fidelity for the CRI projection, the sibling of M0. Seeded with
  # exactly the TAG-ONLY node state the preserved run left behind, the modeled
  # projection must reproduce that run's own CRI view of the three imported
  # images. The bundle is not carried in this repository, so the binding is a
  # CHECKSUM of a documented derivation of its bytes — the same out-of-repo
  # evidence binding R2 uses. The derivation, over
  # failed-sit-ade9451-run1/kargo-runtime-node-images.json, is:
  #   jq -S '[ .images[] | {id, repoTags, repoDigests} ]
  #          | map(select(any(.repoTags[]?; . == <the three canonical tags>)))
  #          | sort_by(.repoTags, .repoDigests)'
  nii_cri_recorded_sha256='c682618d6d9ab3c09c55e8c14e35d0223dc31cc67f19cfd3f791cfcdee222959'
  nii_case m1 project-cri "${nii_fns}" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}" \
    "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}" \
    "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
  nii_expect 'M1 CRI projection fidelity' 0 '' m1
  jq -S \
    --arg kargo "${nii_kargo_tag}" \
    --arg rollouts "${nii_rollouts_tag}" \
    --arg analysis "${nii_analysis_tag}" '
      [ .images[] | {id, repoTags, repoDigests} ] |
      map(select(any(.repoTags[]?; . == $kargo or . == $rollouts or . == $analysis))) |
      sort_by(.repoTags, .repoDigests)
    ' "${tmp}/m1/report/kargo-runtime-node-images.json" >"${tmp}/m1-projection.json"
  printf '%s  %s\n' "${nii_cri_recorded_sha256}" "${tmp}/m1-projection.json" |
    sha256sum --check --status ||
    fail 'M1 CRI projection fidelity: the modeled tag-only projection is not the CRI view the preserved failed run recorded'
  jq -e '
    [ .images[] | select(any(.repoTags[]?;
      startswith("docker.io/rancher/klipper-helm:") or
      startswith("quay.io/argoproj/argocd:"))) ] as $pulled |
    ($pulled | length) == 2 and all($pulled[]; (.repoDigests | length) == 1)
  ' "${tmp}/m1/report/kargo-runtime-node-images.json" >/dev/null ||
    fail 'M1 CRI projection fidelity: the normally pulled control images did not project a populated repoDigests, so the empty repoDigests above would be a model artefact rather than the recorded state'
  echo "  M1 the modeled CRI projection of the recorded tag-only node state reproduces the preserved run's own empty repoDigests, while normally pulled images keep theirs ✓"

  # R1 — the fixed path. Production import bytes + transcript acceptance + the
  # production alias step + the extracted node verifier must all pass, and the
  # node model must end with BOTH names per image: the canonical tag and the
  # canonical repo@pin the CRI lookup actually resolves.
  nii_case r1 fixed-path
  nii_expect 'R1 the fixed node-image path' 0 '' r1
  nii_r1_rows="$(wc -l <"${tmp}/r1/node-images.tsv" | tr -d ' ')"
  [ "${nii_r1_rows}" -eq 6 ] ||
    fail "R1 the fixed node-image path: expected 6 node rows (three tags plus three digest aliases), got ${nii_r1_rows}"
  grep -qxF "${nii_kargo_tag}"$'\t'"${KARGO_IMAGE_DIGEST}" "${tmp}/r1/node-images.tsv" ||
    fail "R1 the fixed node-image path: ${nii_kargo_tag} is not bound to the pinned digest in the node model"
  grep -qxF "${nii_kargo_alias}"$'\t'"${KARGO_IMAGE_DIGEST}" "${tmp}/r1/node-images.tsv" ||
    fail "R1 the fixed node-image path: ${nii_kargo_alias} is not bound to the pinned digest in the node model"
  grep -q '[[:space:]]saved$' "${tmp}/r1/report/kargo-runtime-image-imports.txt" ||
    fail 'R1 the fixed node-image path: the retained transcript carries no ctr saved marker'
  grep -qF "${nii_rollouts_tag//-/ }"$'\t\tsaved' \
    "${tmp}/r1/report/kargo-runtime-image-imports.txt" ||
    fail 'R1 the fixed node-image path: the Wolfi shim did not reproduce ctr hyphen-to-space display rendering'
  grep -qF "== alias ${nii_kargo_tag} -> ${nii_kargo_alias}" \
    "${tmp}/r1/report/kargo-runtime-image-aliases.txt" ||
    fail 'R1 the fixed node-image path: the retained alias transcript does not record the alias it created'
  [ "$(grep -c '^== alias ' "${tmp}/r1/report/kargo-runtime-image-aliases.txt")" -eq 3 ] ||
    fail 'R1 the fixed node-image path: the retained alias transcript does not carry one record per image'
  echo "  R1 the unfiltered save stream imports platform-scoped, binds every canonical tag to its pin, and adds the digest alias each pinned reference resolves to ✓"

  # R2 — the acceptance step over the ACTUAL preserved failed-run transcript.
  # This is the exact hidden-error shape k3d exited 0 on.
  nii_case r2 transcript "${nii_fns}" "${tmp}/recorded-imports.txt"
  nii_expect 'R2 preserved failed transcript' 1 'carries an error marker' r2
  echo "  R2 the preserved k3d transcript — ERRO plus 'Successfully imported' — is rejected, not accepted ✓"

  # R3 — the platform scope is load-bearing. Strip it from the PRODUCTION bytes
  # and the shim reproduces the recorded partial-archive failure.
  sed 's/--platform linux\/amd64 //' "${nii_fns}" >"${tmp}/node-image-fns-noplatform.sh"
  cmp -s "${nii_fns}" "${tmp}/node-image-fns-noplatform.sh" &&
    fail 'R3 platform-scope mutation: stripping --platform linux/amd64 changed nothing, so the flag is not where the gate thinks it is'
  nii_case r3 fixed-path "${tmp}/node-image-fns-noplatform.sh"
  nii_expect 'R3 platform-scope mutation' 1 'streaming the pinned image into platform containerd failed' r3
  grep -qF "ctr: content digest ${nii_kargo_missing}: not found" \
    "${tmp}/r3/report/kargo-runtime-image-imports.txt" ||
    fail 'R3 platform-scope mutation: the retained transcript did not capture the node-side failure'
  echo "  R3 removing --platform linux/amd64 reproduces the recorded failure and fails the leg closed ✓"

  # R4 — the node verifier is neither absence-blind nor existence-only.
  nii_case r4a verify-node "${nii_fns}" "${tmp}/inventory-header.txt" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'R4a absent from the recorded inventory' 1 'does not bind' r4a
  cat "${tmp}/inventory-header.txt" "${tmp}/inventory-base.txt" >"${tmp}/inventory-recorded.txt"
  nii_case r4b verify-node "${nii_fns}" "${tmp}/inventory-recorded.txt" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'R4b recorded failed inventory' 1 'does not bind' r4b
  nii_inv_row() {
    printf '%s application/vnd.oci.image.index.v1+json %s 42.0 MiB linux/amd64 io.cri-containerd.image=managed\n' \
      "$1" "$2"
  }
  {
    cat "${tmp}/inventory-recorded.txt"
    nii_inv_row "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  } >"${tmp}/inventory-bound.txt"
  nii_case r4c verify-node "${nii_fns}" "${tmp}/inventory-bound.txt" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'R4c tag bound to the pin' 0 '' r4c
  {
    cat "${tmp}/inventory-recorded.txt"
    nii_inv_row "${nii_kargo_tag}" "${nii_other}"
  } >"${tmp}/inventory-wrong-pin.txt"
  nii_case r4d verify-node "${nii_fns}" "${tmp}/inventory-wrong-pin.txt" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'R4d tag bound to other content' 1 'does not bind' r4d
  echo "  R4 the node verifier rejects absence and a tag carrying other content, and accepts only tag+pin ✓"

  # R5 — either positive marker must bind the PIN, not merely say `done` or
  # `saved`. Success-shaped legacy and current-Wolfi transcripts whose root
  # digest is other content are both red.
  {
    printf '== import %s (%s)\n' "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_kargo_tag}" "${nii_other}"
    printf '== import %s (%s)\n' "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}"
    printf '== import %s (%s)\n' "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
  } >"${tmp}/transcript-wrong-pin.txt"
  nii_case r5a transcript "${nii_fns}" "${tmp}/transcript-wrong-pin.txt"
  nii_expect 'R5a unpack marker with the wrong digest' 1 'does not bind' r5a
  {
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      "${nii_kargo_tag}" "${nii_other}"
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}"
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
  } >"${tmp}/transcript-saved-wrong-pin.txt"
  nii_case r5b transcript "${nii_fns}" "${tmp}/transcript-saved-wrong-pin.txt"
  nii_expect 'R5b saved marker with the wrong digest' 1 'does not bind' r5b
  {
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      'quay.io/argoproj/argo rolloutz:v1.8.3' "${ROLLOUTS_IMAGE_DIGEST}"
    printf '%s\t\tsaved\napplication/vnd.oci.image.index.v1+json %s\n' \
      "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
  } >"${tmp}/transcript-saved-wrong-display.txt"
  nii_case r5c transcript "${nii_fns}" "${tmp}/transcript-saved-wrong-display.txt"
  nii_expect 'R5c saved marker with an inexact displayed tag' 1 'does not bind' r5c
  echo "  R5 legacy unpack and current Wolfi saved markers with another digest or displayed tag are rejected ✓"

  # P1 — the positive control for the repair itself: unmutated production bytes
  # end with the tag and the pinned digest name on ONE CRI entry per image, and
  # the CRI resolves the exact combined reference the pinned workloads carry.
  nii_case p1 fixed-path
  nii_expect 'P1 the repaired CRI state' 0 '' p1
  # Counted, exactly as production counts: one occurrence of the tag and one of
  # the alias across the WHOLE inventory, both on the same entry. An existential
  # form here would have re-stated the weakness the production predicate had.
  jq -e \
    --arg kargo "${nii_kargo_tag}" --arg kargoAlias "${nii_kargo_alias}" \
    --arg rollouts "${nii_rollouts_tag}" --arg rolloutsAlias "${nii_rollouts_alias}" \
    --arg analysis "${nii_analysis_tag}" --arg analysisAlias "${nii_analysis_alias}" '
      def joined($tag; $alias):
        [ .images[] |
          {
            tags: ([ .repoTags[]? | select(. == $tag) ] | length),
            digests: ([ .repoDigests[]? | select(. == $alias) ] | length)
          }
        ] as $rows |
        (([ $rows[].tags ] | add) // 0) == 1 and
        (([ $rows[].digests ] | add) // 0) == 1 and
        ([ $rows[] | select(.tags == 1 and .digests == 1) ] | length) == 1;
      joined($kargo; $kargoAlias) and
      joined($rollouts; $rolloutsAlias) and
      joined($analysis; $analysisAlias)
    ' "${tmp}/p1/report/kargo-runtime-node-images.json" >/dev/null ||
    fail 'P1 the repaired CRI state: the canonical tag and the pinned repoDigest do not occur exactly once each on one and the same CRI entry per image'
  nii_p1_evidence() {
    local slug="$1" tag="$2" alias_ref="$3"
    local file="${tmp}/p1/report/kargo-runtime-cri-${slug}.json"
    test -s "${file}" ||
      fail "P1 the repaired CRI state: the retained CRI resolution evidence is missing: ${file}"
    jq -e --arg tag "${tag}" --arg alias "${alias_ref}" '
      ([ .status.repoTags[]? | select(. == $tag) ] | length) == 1 and
      ([ .status.repoDigests[]? | select(. == $alias) ] | length) == 1
    ' "${file}" >/dev/null ||
      fail "P1 the repaired CRI state: ${file} does not name the canonical tag and the pinned repoDigest exactly once each"
  }
  nii_p1_evidence kargo "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_p1_evidence argo-rollouts "${nii_rollouts_tag}" "${nii_rollouts_alias}"
  nii_p1_evidence busybox "${nii_analysis_tag}" "${nii_analysis_alias}"
  nii_p1_attempts="$(wc -l <"${tmp}/p1/crictl-inspecti-attempts.txt" | tr -d ' ')"
  [ "${nii_p1_attempts}" -eq 3 ] ||
    fail "P1 the repaired CRI state: expected one CRI resolution per image, got ${nii_p1_attempts} attempts"
  grep -qxF "${nii_kargo_tag}@${KARGO_IMAGE_DIGEST}" "${tmp}/p1/crictl-inspecti-attempts.txt" ||
    fail 'P1 the repaired CRI state: the CRI was not queried with the exact combined tag@digest reference the pinned workloads carry'
  # The retained report must contain exactly the artifacts the L9 evidence
  # inventory declares. Probe stderr is transient by design, so neither an
  # undeclared log inside the report nor a leftover scratch file may survive a
  # successful run.
  [ -z "$(find "${tmp}/p1/report" -name 'kargo-runtime-cri-*.log' -print -quit)" ] ||
    fail 'P1 the repaired CRI state: the probe retained an undeclared stderr artifact inside the report'
  [ -z "$(find "${tmp}/p1" -maxdepth 1 -name 'fleet-sit-cri.*' -print -quit)" ] ||
    fail 'P1 the repaired CRI state: the transient probe stderr file outlived a successful resolution'
  echo "  P1 the fixed path leaves six node rows, one canonical tag and one pinned repoDigest joined on a single CRI entry, a first-try resolution of the exact combined reference, and no undeclared probe residue ✓"

  # C — the duplicate shapes Kyron's review proved the existential predicate
  # accepted. A well-formed containerd store cannot produce them (names are
  # unique), so they are fed to the PRODUCTION predicate directly as crafted
  # inventories: the point is that it fails closed on a CRI listing that is not
  # the unambiguous one a pinned `Never` lookup depends on.
  nii_cri_control='[{"id":"'"${nii_argocd_id}"'","repoTags":["quay.io/argoproj/argocd:v3.4.5","quay.io/argoproj/argocd:latest"],"repoDigests":["quay.io/argoproj/argocd@'"${nii_argocd_digest}"'"]}]'
  nii_cri_fixture() {
    local out="$1" tags="$2" digests="$3" extra="${4:-[]}"
    jq -n \
      --arg id 'sha256:722c772753348aa5e71c029417e8a7c065b4a3cb5fe68b82762ab27ba8b1c0d6' \
      --argjson tags "${tags}" \
      --argjson digests "${digests}" \
      --argjson extra "${extra}" \
      --argjson control "${nii_cri_control}" '
        {images: ([{id: $id, repoTags: $tags, repoDigests: $digests}] + $extra + $control)}
      ' >"${out}"
  }
  nii_tag_json="[\"${nii_kargo_tag}\"]"
  nii_alias_json="[\"${nii_kargo_alias}\"]"

  # C0 — the ordinary joined state still passes, beside a control image that
  # carries duplicate-ish names of its OWN. The rule is about the queried names,
  # not about the inventory being duplicate-free everywhere.
  nii_cri_fixture "${tmp}/cri-joined.json" "${nii_tag_json}" "${nii_alias_json}"
  nii_case c0 verify-cri "${nii_fns}" "${tmp}/cri-joined.json" \
    "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_expect 'C0 the ordinary joined entry' 0 '' c0

  # C1 — a valid joined entry PLUS a second tag-only entry: the exact shape the
  # review executed against the old predicate and got `true`.
  nii_cri_fixture "${tmp}/cri-dup-entry-tag.json" "${nii_tag_json}" "${nii_alias_json}" \
    "[{\"id\":\"sha256:$(printf 'e%.0s' {1..64})\",\"repoTags\":[\"${nii_kargo_tag}\"],\"repoDigests\":[]}]"
  nii_case c1 verify-cri "${nii_fns}" "${tmp}/cri-dup-entry-tag.json" \
    "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_expect 'C1 duplicate tag on a second entry' 1 'exactly once each on one and the same image entry' c1

  # C2 — the mirror: a second entry carrying the pinned digest name.
  nii_cri_fixture "${tmp}/cri-dup-entry-alias.json" "${nii_tag_json}" "${nii_alias_json}" \
    "[{\"id\":\"sha256:$(printf 'f%.0s' {1..64})\",\"repoTags\":[],\"repoDigests\":[\"${nii_kargo_alias}\"]}]"
  nii_case c2 verify-cri "${nii_fns}" "${tmp}/cri-dup-entry-alias.json" \
    "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_expect 'C2 duplicate alias on a second entry' 1 'exactly once each on one and the same image entry' c2

  # C3/C4 — duplicates INSIDE one entry's arrays, which the old predicate also
  # accepted because `any` stops at the first hit.
  nii_cri_fixture "${tmp}/cri-dup-array-tag.json" \
    "[\"${nii_kargo_tag}\",\"${nii_kargo_tag}\"]" "${nii_alias_json}"
  nii_case c3 verify-cri "${nii_fns}" "${tmp}/cri-dup-array-tag.json" \
    "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_expect 'C3 duplicate tag inside one entry' 1 'exactly once each on one and the same image entry' c3
  nii_cri_fixture "${tmp}/cri-dup-array-alias.json" \
    "${nii_tag_json}" "[\"${nii_kargo_alias}\",\"${nii_kargo_alias}\"]"
  nii_case c4 verify-cri "${nii_fns}" "${tmp}/cri-dup-array-alias.json" \
    "${nii_kargo_tag}" "${nii_kargo_alias}"
  nii_expect 'C4 duplicate alias inside one entry' 1 'exactly once each on one and the same image entry' c4

  # C5 — the count is CANONICAL, so the same name spelled two ways is still two
  # occurrences. Uses the docker.io/library image, the only one whose canonical
  # form differs from its stored form.
  nii_cri_fixture "${tmp}/cri-dup-canonical.json" \
    "[\"${nii_analysis_tag}\",\"${nii_analysis_tag_short}\"]" \
    "[\"${nii_analysis_alias}\"]"
  nii_case c5 verify-cri "${nii_fns}" "${tmp}/cri-dup-canonical.json" \
    "${nii_analysis_tag}" "${nii_analysis_alias}"
  nii_expect 'C5 the same tag spelled two ways' 1 'exactly once each on one and the same image entry' c5
  # ... and the same fixture minus the duplicate spelling still passes, so C5 is
  # not merely rejecting the short spelling.
  nii_cri_fixture "${tmp}/cri-canonical-ok.json" \
    "[\"${nii_analysis_tag_short}\"]" "[\"${nii_analysis_alias}\"]"
  nii_case c6 verify-cri "${nii_fns}" "${tmp}/cri-canonical-ok.json" \
    "${nii_analysis_tag}" "${nii_analysis_alias}"
  nii_expect 'C6 the short spelling alone still joins' 0 '' c6
  echo "  C duplicate entries and duplicate array elements — for the tag and for the alias, canonical spelling included — are rejected, while the ordinary joined state beside a duplicate-carrying control image still passes ✓"

  # The mutations below all strip PRODUCTION bytes — including the orchestration
  # call sites — exactly as R3 does for --platform, so each proves a specific
  # layer of the repair is load-bearing rather than decorative.
  # Neuter exactly one production STATEMENT, keeping the surrounding structure
  # intact: the statement is replaced in place by `:`, so a call that is the
  # only body of a loop cannot turn the mutation into a syntax error and let a
  # parse failure masquerade as the assertion firing. The helper refuses to
  # proceed unless the call it was aimed at existed exactly once and is gone
  # afterwards.
  nii_neuter() {
    local source="$1" target="$2" token="$3" label="$4" hits
    hits="$(grep -cF -- "${token}" "${source}" || true)"
    [ "${hits}" -eq 1 ] ||
      fail "${label}: expected exactly one production call of '${token}' to neuter, found ${hits}"
    awk -v token="${token}" \
      'index($0, token) { sub(/[^[:space:]].*$/, ":") } { print }' \
      "${source}" >"${target}"
    [ "$(grep -cF -- "${token}" "${target}" || true)" -eq 0 ] ||
      fail "${label}: the mutation left the production call in place"
    [ "$(wc -l <"${source}")" -eq "$(wc -l <"${target}")" ] ||
      fail "${label}: the mutation changed the line structure instead of neutering one statement"
  }

  # N1a — delete the production ALIAS CALL. The node then holds precisely the
  # tag-only state the failed run left behind, and the ctr-side alias row
  # assertion is the first thing that says so.
  # The neuter tokens are production SOURCE text and must never expand here.
  # shellcheck disable=SC2016
  nii_neuter "${nii_fns}" "${tmp}/node-image-fns-noalias.sh" \
    'kargo_runtime_alias_node_image "${pairs[i]}"' 'N1a the alias call is load-bearing'
  nii_case n1a fixed-path "${tmp}/node-image-fns-noalias.sh"
  nii_expect 'N1a the alias call is load-bearing' 1 \
    "does not bind ${nii_kargo_alias} to pinned digest ${KARGO_IMAGE_DIGEST}" n1a
  nii_n1a_rows="$(wc -l <"${tmp}/n1a/node-images.tsv" | tr -d ' ')"
  [ "${nii_n1a_rows}" -eq 3 ] ||
    fail "N1a the alias call is load-bearing: the mutated path should leave the recorded tag-only state of 3 rows, got ${nii_n1a_rows}"
  echo "  N1a removing the production alias call leaves the recorded tag-only node state and fails the leg closed ✓"

  # N1b — additionally delete the ctr-side alias assertion, so the mutated run
  # reaches the CRI layer against that same tag-only state. This is the exact
  # production failure of run 20260729T135154Z-ade9451: the combined
  # `tag@digest` reference cannot be resolved, and the former tag-only green is
  # now an asserted RED.
  # shellcheck disable=SC2016
  nii_neuter "${tmp}/node-image-fns-noalias.sh" "${tmp}/node-image-fns-noalias-noctr.sh" \
    'kargo_runtime_verify_node_image "${inventory}" "${alias_ref}"' \
    'N1b the exact-reference resolution is load-bearing'
  nii_case n1b fixed-path "${tmp}/node-image-fns-noalias-noctr.sh"
  nii_expect 'N1b the exact-reference resolution is load-bearing' 1 \
    "did not resolve the exact pinned workload reference" n1b
  nii_n1b_attempts="$(wc -l <"${tmp}/n1b/crictl-inspecti-attempts.txt" | tr -d ' ')"
  [ "${nii_n1b_attempts}" -eq 30 ] ||
    fail "N1b the exact-reference resolution is load-bearing: expected the bounded retry to stop at 30 attempts, got ${nii_n1b_attempts}"
  [ "$(sort -u "${tmp}/n1b/crictl-inspecti-attempts.txt" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail 'N1b the exact-reference resolution is load-bearing: the retry did not keep querying the same exact reference'
  grep -qxF "${nii_kargo_tag}@${KARGO_IMAGE_DIGEST}" "${tmp}/n1b/crictl-inspecti-attempts.txt" ||
    fail 'N1b the exact-reference resolution is load-bearing: the retried reference is not the combined tag@digest one the pinned workloads carry'
  # The fail-closed path prints the transient probe stderr as diagnostics and
  # then removes it, so even a red run leaves no undeclared artifact behind.
  grep -qF 'no such image' "${tmp}/n1b/stderr.txt" ||
    fail 'N1b the exact-reference resolution is load-bearing: the fail-closed path did not surface the probe diagnostics it collected'
  [ -z "$(find "${tmp}/n1b" -maxdepth 1 -name 'fleet-sit-cri.*' -print -quit)" ] ||
    fail 'N1b the exact-reference resolution is load-bearing: the transient probe stderr file survived the fail-closed path'
  [ -z "$(find "${tmp}/n1b/report" -name 'kargo-runtime-cri-*.log' -print -quit)" ] ||
    fail 'N1b the exact-reference resolution is load-bearing: the probe retained an undeclared stderr artifact inside the report'
  echo "  N1b on the tag-only state the CRI cannot resolve the combined tag@digest reference, and the bounded retry fails closed at its ceiling ✓"

  # N1c — additionally delete the resolution call, leaving only the CRI
  # inventory join. It must catch the same tag-only state on its own, so no
  # single CRI predicate is carrying the others.
  # shellcheck disable=SC2016
  nii_neuter "${tmp}/node-image-fns-noalias-noctr.sh" "${tmp}/node-image-fns-joinonly.sh" \
    'kargo_runtime_assert_cri_reference "${tag_ref}@${digest}"' \
    'N1c the same-entry CRI join is load-bearing'
  nii_case n1c fixed-path "${tmp}/node-image-fns-joinonly.sh"
  nii_expect 'N1c the same-entry CRI join is load-bearing' 1 \
    "does not carry ${nii_kargo_tag} and ${nii_kargo_alias} exactly once each on one and the same image entry" n1c
  echo "  N1c the same-entry tag/repoDigest join independently rejects the tag-only state the old tag-only predicate accepted ✓"

  # N2 — a WRONG DIGEST ALIAS: the name says the pin, the record serves other
  # content. `ctr images tag` performs no such validation, and every crictl view
  # would look perfect because CRI derives repoDigests from NAMES, so the
  # name-suffix-equals-target predicate on the ctr inventory is the only place
  # this is catchable.
  {
    cat "${tmp}/inventory-recorded.txt"
    nii_inv_row "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
    nii_inv_row "${nii_kargo_alias}" "${nii_other}"
  } >"${tmp}/inventory-wrong-alias.txt"
  nii_case n2 verify-node "${nii_fns}" "${tmp}/inventory-wrong-alias.txt" \
    "${nii_kargo_alias}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'N2 wrong digest alias' 1 'does not bind' n2
  echo "  N2 a digest-shaped alias whose record targets other content is rejected, though ctr itself would never have checked it ✓"

  # N3 — a STALE TAG beside a correct alias. The ctr predicate rejects the tag,
  # and the CRI join rejects the split brain two different targets produce: the
  # tag and the pinned repoDigest land on two entries, not one.
  {
    cat "${tmp}/inventory-recorded.txt"
    nii_inv_row "${nii_kargo_tag}" "${nii_other}"
    nii_inv_row "${nii_kargo_alias}" "${KARGO_IMAGE_DIGEST}"
  } >"${tmp}/inventory-stale-tag.txt"
  nii_case n3a verify-node "${nii_fns}" "${tmp}/inventory-stale-tag.txt" \
    "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'N3a stale tag on the ctr inventory' 1 'does not bind' n3a
  nii_case n3b seeded-cri "${nii_fns}" \
    "${nii_kargo_tag}" "${nii_other}" \
    "${nii_kargo_alias}" "${KARGO_IMAGE_DIGEST}"
  nii_expect 'N3b stale tag in the CRI' 1 \
    "does not carry ${nii_kargo_tag} and ${nii_kargo_alias} exactly once each on one and the same image entry" n3b
  echo "  N3 a stale tag beside a correct alias is rejected by the ctr predicate and by the same-entry join that kills split brain ✓"
  ;;
sit-post-promotion-verification)
  # Daemon-free model of the L9 post-Promotion edge. Every function under test
  # is extracted from scripts/ci/fleet-sit.sh; the shim supplies only observed
  # Kubernetes objects and a monotonic clock, never a second implementation of
  # the controller-facing predicates.
  ppv_source='scripts/ci/fleet-sit.sh'
  ppv_promotion_fixture='scripts/validate/fleet-sit/fixtures/kargo-runtime/promotion.yaml'
  ppv_assert="${PWD}/scripts/validate/fleet-sit/assert.sh"
  ppv_fns="${tmp}/post-promotion-fns.sh"
  test -s "${ppv_assert}" || fail "the SIT assertion library is missing: ${ppv_assert}"
  : >"${ppv_fns}"
  sed -n "/^KARGO_STAGE_PREDICATE_PREAMBLE='/,/^'$/p" "${ppv_source}" >>"${ppv_fns}"
  sed -n "/^KARGO_POST_PROMOTION_PREDICATE_PREAMBLE='/,/^'$/p" \
    "${ppv_source}" >>"${ppv_fns}"
  for ppv_fn in \
    kargo_check_refresh_handled \
    kargo_monotonic_now \
    kargo_driver_request_timeout \
    kargo_check_refresh_handled_bounded \
    kargo_refresh_stage_quiet \
    kargo_capture_json_evidence \
    kargo_capture_stage_failure_diagnostics \
    kargo_sleep_before_deadline \
    kargo_post_promotion_deadline_reason \
    kargo_capture_post_promotion_observation \
    kargo_write_post_promotion_record \
    _kargo_drive_post_promotion_verification \
    kargo_drive_post_promotion_verification \
    kargo_promotion_ulid \
    kargo_promotion_name_timestamp_ms \
    kargo_manual_promotion_ordering_floor_reached \
    kargo_wait_manual_promotion_ordering_floor \
    kargo_validate_manual_promotion_name \
    kargo_generate_manual_promotion_name \
    kargo_next_manual_promotion_timestamp \
    kargo_set_analysis_outcome \
    sit_prepare_failure_evidence; do
    sed -n "/^${ppv_fn}() {$/,/^}$/p" "${ppv_source}" >"${tmp}/ppv-fn.sh"
    [ "$(tail -n 1 "${tmp}/ppv-fn.sh")" = '}' ] ||
      fail "the extracted ${ppv_fn}() body is unterminated"
    cat "${tmp}/ppv-fn.sh" >>"${ppv_fns}"
  done
  # Literal production source, deliberately not expanded here.
  # shellcheck disable=SC2016
  grep -qF 'overall_deadline=$((started_seconds + 180))' "${ppv_fns}" ||
    fail 'the extracted public driver no longer owns one literal 180-second deadline'
  ! grep -qF 'SECONDS + 300' "${ppv_fns}" ||
    fail 'the extracted post-Promotion driver retained the additive 300-second window'
  ! rg -q 'generateName:[[:space:]]*fleet-sit-' "${ppv_promotion_fixture}" ||
    fail 'the manual Promotion fixture still delegates ordering to a random Kubernetes suffix'
  yq -e '.metadata.name == "<name>" and (.metadata | has("generateName") | not)' \
    "${ppv_promotion_fixture}" >/dev/null ||
    fail 'the manual Promotion fixture does not require an explicit ordered name'
  sed -n '/^kargo_next_manual_promotion_timestamp() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-promotion-clock.sh"
  rg -qF 'date -u +%s%3N' "${tmp}/ppv-promotion-clock.sh" ||
    fail 'manual Promotion ULIDs are no longer sourced from the real millisecond clock'
  rg -qF 'candidate_ms=$((now_ms - 1))' "${tmp}/ppv-promotion-clock.sh" ||
    fail 'manual Promotion ULIDs no longer carry the one-millisecond realtime ordering floor'
  sed -n '/^kargo_write_promotion_manifest() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-promotion-writer.sh"
  if ! rg -q 'kargo_next_manual_promotion_timestamp' "${tmp}/ppv-promotion-writer.sh" ||
    ! rg -q 'kargo_generate_manual_promotion_name' "${tmp}/ppv-promotion-writer.sh" ||
    ! rg -qF '.metadata.name = strenv(NAME)' "${tmp}/ppv-promotion-writer.sh"; then
    fail 'the manual Promotion manifest writer is not bound to the ordered generated name'
  fi
  sed -n '/^kargo_create_manual_promotion() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-promotion-create.sh"
  [ "$(tail -n 1 "${tmp}/ppv-promotion-create.sh")" = '}' ] ||
    fail 'the extracted kargo_create_manual_promotion() body is unterminated'
  ppv_floor_line="$(rg -n '^[[:space:]]*kargo_wait_manual_promotion_ordering_floor ' \
    "${tmp}/ppv-promotion-create.sh" | cut -d: -f1)"
  ppv_create_line="$(rg -n '^[[:space:]]*kubectl create -f ' \
    "${tmp}/ppv-promotion-create.sh" | cut -d: -f1)"
  if ! [[ ${ppv_floor_line} =~ ^[0-9]+$ && ${ppv_create_line} =~ ^[0-9]+$ ]] ||
    [ "${ppv_floor_line}" -ge "${ppv_create_line}" ]; then
    fail 'the manual Promotion ordering floor is not enforced immediately before kubectl create'
  fi
  sed -n '/^_kargo_drive_post_promotion_verification() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-worker.sh"
  ! rg -q 'overall_deadline.*\+ (60|300)|sit_wait_for (60|300)' "${ppv_fns}" ||
    fail 'the worker reintroduced an additive 60/300-second window'

  cat >"${tmp}/post-promotion-driver.sh" <<'POSTPROMOTIONDRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail

assert_lib="$1"
fn_file="$2"
test_root="$3"
# shellcheck source=/dev/null
source "${assert_lib}"
# shellcheck source=/dev/null
source "${fn_file}"

TEST_PROJECT='canary'
TEST_STAGE='canary-dummy-pikachu'
TEST_FREIGHT='freight-f2'
TEST_PROMOTION='promotion-f2'
TEST_COLLECTION='collection-f2'
case_dir=''
report=''
KARGO_RUNTIME_DIR=''
STAGE_LAST=''
FREIGHT_PROJECT_AFTER=999999
SLEEP_JUMP=0
FAKE_CLOCK_FILE=''
STAGE_READ_ADVANCE=0
CROSS_AFTER_DECISION=0
SIT_LEG_EVIDENCE=()

die() {
  echo "post-Promotion gate failed: $*" >&2
  exit 1
}

sleep() {
  local delta="$1"
  local now
  if [ "${SLEEP_JUMP:-0}" -gt 0 ]; then
    delta="${SLEEP_JUMP}"
  fi
  now="$(<"${FAKE_CLOCK_FILE}")"
  printf '%s\n' "$((now + delta))" >"${FAKE_CLOCK_FILE}"
}

# Override the extracted production clock with a file-backed fake. Real CPU
# time and scheduler load therefore cannot change a deadline assertion.
kargo_monotonic_now() {
  printf '%s\n' "$(<"${FAKE_CLOCK_FILE}")"
}

cp() {
  local now
  command cp "$@"
  if [ "${CROSS_AFTER_DECISION:-0}" -eq 1 ]; then
    now="$(<"${FAKE_CLOCK_FILE}")"
    printf '%s\n' "$((now + 1))" >"${FAKE_CLOCK_FILE}"
    CROSS_AFTER_DECISION=0
  fi
}

make_stage() {
  local output="$1"
  local phase="$2"
  local with_analysis="$3"
  local include_exact="${4:-true}"
  jq -n \
    --arg freight "${TEST_FREIGHT}" \
    --arg promotion "${TEST_PROMOTION}" \
    --arg collection "${TEST_COLLECTION}" \
    --arg phase "${phase}" \
    --argjson withAnalysis "${with_analysis}" \
    --argjson includeExact "${include_exact}" '
      def item($name): {"Warehouse/dummy":{name:$name}};
      def verification($id;$phase;$message;$analysis):
        {id:$id,phase:$phase,message:$message,
         startTime:"2026-07-31T00:00:01Z",finishTime:"2026-07-31T00:00:02Z",
         analysisRun:$analysis};
      {
        metadata:{name:"canary-dummy-pikachu",namespace:"canary"},
        status:{
          currentPromotion:null,
          lastPromotion:{
            name:$promotion,freight:{name:$freight},
            status:{phase:"Succeeded",freightCollection:{id:$collection}}
          },
          health:{status:"Healthy"},
          freightHistory:([
            {id:"stale-collection",items:item($freight),verificationHistory:[
              verification("stale-verification";"Failed";"stale F1 result";
                {name:"stale-run",namespace:"canary",phase:"Failed"})
            ]}
          ] + (if $includeExact then [
            {id:$collection,items:item($freight),verificationHistory:
              (if $phase == "" then [] else [
                verification("exact-verification";$phase;(if $phase == "Error" then "provider exploded" else "exact result" end);
                  (if $withAnalysis then
                    {name:"exact-run",namespace:"canary",phase:$phase}
                   else null end))
              ] end)}
          ] else [] end))
        }
      }
    ' >"${output}"
}

reset_case() {
  local name="$1"
  case_dir="${test_root}/${name}"
  report="${case_dir}/report"
  KARGO_RUNTIME_DIR="${case_dir}/runtime"
  mkdir -p "${report}" "${KARGO_RUNTIME_DIR}"
  printf '0\n' >"${case_dir}/stage-index"
  printf '0\n' >"${case_dir}/freight-index"
  printf '0\n' >"${case_dir}/annotate-count"
  : >"${case_dir}/handled-token"
  : >"${case_dir}/kubectl-calls.log"
  FAKE_CLOCK_FILE="${case_dir}/clock"
  printf '0\n' >"${FAKE_CLOCK_FILE}"
  SIT_LEG_EVIDENCE=()
  FREIGHT_PROJECT_AFTER=999999
  SLEEP_JUMP=0
  STAGE_READ_ADVANCE=0
  CROSS_AFTER_DECISION=0
  jq -n \
    --arg stage "${TEST_STAGE}" \
    --arg freight "${TEST_FREIGHT}" \
    --arg promotion "${TEST_PROMOTION}" \
    --arg collection "${TEST_COLLECTION}" '
      [{metadata:{name:$promotion,creationTimestamp:"2026-07-31T00:00:00Z"},
        spec:{stage:$stage,freight:$freight},
        status:{phase:"Succeeded",freight:{name:$freight},
          freightCollection:{id:$collection}}}]
    ' >"${case_dir}/promotion.json"
}

stage_snapshot() {
  local index file token
  index="$(<"${case_dir}/stage-index")"
  file="${case_dir}/stage-${index}.json"
  [ -s "${file}" ] || file="${STAGE_LAST}"
  printf '%s\n' "$((index + 1))" >"${case_dir}/stage-index"
  token="$(<"${case_dir}/handled-token")"
  jq --arg token "${token}" \
    '.status.lastHandledRefresh = (if $token == "" then null else $token end)' \
    "${file}"
}

freight_snapshot() {
  local index
  index="$(<"${case_dir}/freight-index")"
  index=$((index + 1))
  printf '%s\n' "${index}" >"${case_dir}/freight-index"
  if [ "${index}" -ge "${FREIGHT_PROJECT_AFTER}" ]; then
    jq -n --arg stage "${TEST_STAGE}" \
      '{status:{verifiedIn:{($stage):{verifiedAt:"2026-07-31T00:00:03Z"}}}}'
  else
    jq -n '{status:{verifiedIn:{}}}'
  fi
}

kubectl() {
  local namespace=''
  printf '%s\n' "$*" >>"${case_dir}/kubectl-calls.log"
  if [ "${1:-}" = '-n' ]; then
    namespace="$2"
    shift 2
  fi
  case "${1:-}:${2:-}" in
  annotate:stage)
    local token="${4#*=}"
    printf '%s\n' "${token}" >"${case_dir}/handled-token"
    local count
    count="$(<"${case_dir}/annotate-count")"
    printf '%s\n' "$((count + 1))" >"${case_dir}/annotate-count"
    return 0
    ;;
  get:stage | get:stage/*)
    if [[ $* == *jsonpath* ]]; then
      printf '%s' "$(<"${case_dir}/handled-token")"
    else
      if [ "${STAGE_READ_ADVANCE:-0}" -gt 0 ]; then
        local now
        now="$(<"${FAKE_CLOCK_FILE}")"
        printf '%s\n' "$((now + STAGE_READ_ADVANCE))" >"${FAKE_CLOCK_FILE}"
        STAGE_READ_ADVANCE=0
      fi
      stage_snapshot
    fi
    return 0
    ;;
  get:freight | get:freight/*)
    freight_snapshot
    return 0
    ;;
  get:promotions.kargo.akuity.io)
    jq -n \
      --arg stage "${TEST_STAGE}" --arg freight "${TEST_FREIGHT}" \
      --arg promotion "${TEST_PROMOTION}" --arg collection "${TEST_COLLECTION}" '
        {items:[{metadata:{name:$promotion,creationTimestamp:"2026-07-31T00:00:00Z"},
          spec:{stage:$stage,freight:$freight},status:{phase:"Succeeded",
            freight:{name:$freight},freightCollection:{id:$collection}}}]}
      '
    return 0
    ;;
  get:analysisruns | get:analysisruns.argoproj.io)
    jq -n \
      --arg stage "${TEST_STAGE}" --arg collection "${TEST_COLLECTION}" '
        {items:[
          {metadata:{name:"stale-run",creationTimestamp:"2026-07-30T00:00:00Z",
            labels:{"kargo.akuity.io/stage":$stage,
              "kargo.akuity.io/freight-collection":"stale-collection"}}},
          {metadata:{name:"exact-run",creationTimestamp:"2026-07-31T00:00:01Z",
            labels:{"kargo.akuity.io/stage":$stage,
              "kargo.akuity.io/freight-collection":$collection}}}
        ]}
      '
    return 0
    ;;
  patch:configmap)
    local payload='{}'
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in
      -p) payload="$2"; shift 2 ;;
      *) shift ;;
      esac
    done
    jq -n --argjson patch "${payload}" \
      --arg name 'kargo-analysis-outcomes' \
      '{metadata:{name:$name},data:$patch.data}'
    return 0
    ;;
  *)
    echo "unmodeled kubectl call in ${namespace}: $*" >&2
    return 1
    ;;
  esac
}

drive() {
  local expected="$1"
  kargo_drive_post_promotion_verification \
    "${TEST_PROJECT}" "${TEST_STAGE}" "${TEST_FREIGHT}" \
    "${case_dir}/promotion.json" "${expected}" \
    "${report}/stage.json" "${report}/reconciliation.json"
}

expect_drive_failure() {
  local expected="$1"
  if drive "${expected}" >"${case_dir}/stdout.txt" 2>"${case_dir}/stderr.txt"; then
    die "${case_dir}: expected ${expected} driver failure"
  fi
}

# N1: reproduce the rejected equal-millisecond entropy hole, then prove the
# real-time floor makes even a maximal-entropy manual name sort below a later
# minimal-entropy Kargo-style name. All helpers are extracted production bytes.
naming_stage='canary-dummy-pikachu'
naming_freight='0123456789abcdef'
naming_wall_ms=1700000000002
naming_safe_manual_ms=$((naming_wall_ms - 1))
naming_earlier_manual_ms=$((naming_wall_ms - 2))
naming_earlier=''
naming_later_manual=''
naming_wall_ulid=''
naming_safe_ulid=''
kargo_generate_manual_promotion_name \
  "${naming_stage}" "${naming_freight}" "${naming_earlier_manual_ms}" naming_earlier
kargo_generate_manual_promotion_name \
  "${naming_stage}" "${naming_freight}" "${naming_safe_manual_ms}" naming_later_manual
[[ "${naming_earlier}" < "${naming_later_manual}" ]] ||
  die 'N1 a later manual ULID name did not sort above the earlier manual name'

kargo_promotion_ulid "${naming_wall_ms}" naming_wall_ulid
kargo_promotion_ulid "${naming_safe_manual_ms}" naming_safe_ulid
naming_wall_prefix="${naming_wall_ulid:0:10}"
naming_safe_prefix="${naming_safe_ulid:0:10}"
naming_unsafe_manual="${naming_stage}.${naming_wall_prefix}zzzzzzzzzzzzzzzz.${naming_freight:0:7}"
naming_same_time_auto="${naming_stage}.${naming_wall_prefix}0000000000000000.${naming_freight:0:7}"
naming_safe_manual="${naming_stage}.${naming_safe_prefix}zzzzzzzzzzzzzzzz.${naming_freight:0:7}"
kargo_validate_manual_promotion_name \
  "${naming_unsafe_manual}" "${naming_stage}" "${naming_freight}"
kargo_validate_manual_promotion_name \
  "${naming_same_time_auto}" "${naming_stage}" "${naming_freight}"
kargo_validate_manual_promotion_name \
  "${naming_safe_manual}" "${naming_stage}" "${naming_freight}"
[[ "${naming_same_time_auto}" < "${naming_unsafe_manual}" ]] ||
  die 'N1 did not reproduce the equal-timestamp independent-entropy ordering hole'
[[ "${naming_safe_manual}" < "${naming_same_time_auto}" ]] ||
  die 'N1 the floored maximal-entropy manual name did not sort below the minimal-entropy auto name'
if kargo_manual_promotion_ordering_floor_reached \
  "${naming_safe_manual}" "${naming_safe_manual_ms}"; then
  die 'N1 accepted a controller clock equal to the embedded manual timestamp'
fi
kargo_manual_promotion_ordering_floor_reached \
  "${naming_safe_manual}" "${naming_wall_ms}" ||
  die 'N1 rejected a controller clock strictly beyond the embedded manual timestamp'
kargo_promotion_name_timestamp_ms "${naming_safe_manual}" naming_decoded_ms
[ "${naming_decoded_ms}" = "${naming_safe_manual_ms}" ] ||
  die 'N1 the encoded ULID timestamp was not the supplied real millisecond value'
[ "${#naming_safe_manual}" -le 253 ] || die 'N1 generated a name beyond the DNS limit'
naming_invalid=''
if kargo_promotion_ulid 281474976710656 naming_invalid >/dev/null 2>&1; then
  die 'N1 accepted a timestamp outside the ULID 48-bit range'
fi
naming_overflow="${naming_stage}.zzzzzzzzzzzzzzzzzzzzzzzzzz.${naming_freight:0:7}"
if kargo_validate_manual_promotion_name \
  "${naming_overflow}" "${naming_stage}" "${naming_freight}" >/dev/null 2>&1; then
  die 'N1 accepted a Promotion name with an overflowing 48-bit timestamp'
fi
naming_long_label="$(printf '%064d' 0)"
if kargo_generate_manual_promotion_name \
  "${naming_long_label}" "${naming_freight}" "${naming_earlier_manual_ms}" \
  naming_invalid >/dev/null 2>&1; then
  die 'N1 accepted a Promotion name with a DNS label beyond 63 characters'
fi

# P1: the recorded missing-scheduling shape is repaired by one handled refresh;
# once Pending exists, Running and Failed are observed without another write.
reset_case pending-running-failed
make_stage "${case_dir}/stage-0.json" '' true
make_stage "${case_dir}/stage-1.json" Pending true
make_stage "${case_dir}/stage-2.json" Running true
make_stage "${case_dir}/stage-3.json" Failed true
STAGE_LAST="${case_dir}/stage-3.json"
drive Failed
[ "$(<"${case_dir}/annotate-count")" -eq 1 ] ||
  die 'P1 refreshed again after exact verification scheduling'
rg -q 'get stage .* -o json --request-timeout=[0-9][0-9]*s' \
  "${case_dir}/kubectl-calls.log" || die 'P1 Stage observation was not request-bounded'
rg -q 'annotate stage .* --request-timeout=[0-9][0-9]*s' \
  "${case_dir}/kubectl-calls.log" || die 'P1 refresh annotation was not request-bounded'
rg -q 'get stage .*jsonpath.* --request-timeout=[0-9][0-9]*s' \
  "${case_dir}/kubectl-calls.log" || die 'P1 refresh acknowledgement was not request-bounded'
jq -e '
  .result == "success" and .budget_s == 180 and .elapsed_s <= 180 and
  .promotionName == "promotion-f2" and .freightCollectionId == "collection-f2" and
  .firstObservedScheduledPhase == "Pending" and .finalPhase == "Failed" and
  (.refreshes | length) == 1 and .refreshes[0].handled == true
' "${report}/reconciliation.json" >/dev/null || die 'P1 reconciliation record is incomplete'

# P2: a fast terminal result is legal and requires no synthetic refresh.
reset_case direct-failed
make_stage "${case_dir}/stage-0.json" Failed true
STAGE_LAST="${case_dir}/stage-0.json"
drive Failed
[ "$(<"${case_dir}/annotate-count")" -eq 0 ] || die 'P2 refreshed a direct Failed result'

# P3: direct no-AnalysisRun success still waits for the exact Freight projection
# inside the same deadline.
reset_case direct-success-projection
make_stage "${case_dir}/stage-0.json" Successful false
STAGE_LAST="${case_dir}/stage-0.json"
FREIGHT_PROJECT_AFTER=2
drive Successful
[ "$(<"${case_dir}/annotate-count")" -eq 0 ] || die 'P3 refreshed a direct Successful result'
rg -q 'get freight .* -o json --request-timeout=[0-9][0-9]*s' \
  "${case_dir}/kubectl-calls.log" || die 'P3 Freight projection read was not request-bounded'
jq -e '
  .verification.analysisRunName == null and .freightVerifiedAt != null and
  .finalPhase == "Successful"
' "${report}/reconciliation.json" >/dev/null || die 'P3 did not require the Freight projection'

# P3b: accept an exact terminal controller outcome at the inclusive deadline.
# Crossing the next second during the subsequent Stage copy must not rewrite
# that accepted decision as an evidence-contract failure.
reset_case success-at-deadline
make_stage "${case_dir}/stage-0.json" Failed true
STAGE_LAST="${case_dir}/stage-0.json"
STAGE_READ_ADVANCE=180
CROSS_AFTER_DECISION=1
drive Failed
jq -e '
  .result == "success" and .budget_s == 180 and .elapsed_s == 180 and
  .decisionMonotonic_s == 180 and .finalPhase == "Failed"
' "${report}/reconciliation.json" >/dev/null ||
  die 'P3b post-decision evidence work converted an at-deadline success into failure'
[ "$(<"${FAKE_CLOCK_FILE}")" -eq 181 ] ||
  die 'P3b did not cross the deadline after the controller decision as intended'

# P4: stale same-Freight history is first on purpose. It cannot satisfy the
# exact terminal Promotion collection; the driver must refresh for the new one.
reset_case stale-history
make_stage "${case_dir}/stage-0.json" '' true
make_stage "${case_dir}/stage-1.json" Failed true
STAGE_LAST="${case_dir}/stage-1.json"
drive Failed
[ "$(<"${case_dir}/annotate-count")" -eq 1 ] || die 'P4 accepted stale collection history'

# P5: non-asserted terminal/unknown outcomes fail immediately, retain the actual phase,
# and never stimulate an already terminal attempt.
for actual in Error Aborted Inconclusive Successful Mystery; do
  reset_case "unexpected-${actual}"
  make_stage "${case_dir}/stage-0.json" "${actual}" true
  STAGE_LAST="${case_dir}/stage-0.json"
  expect_drive_failure Failed
  [ "$(<"${case_dir}/annotate-count")" -eq 0 ] || die "P5 refreshed terminal ${actual}"
  jq -e --arg actual "${actual}" '
    .result == "failure" and .finalPhase == $actual and
    (.failureReason | contains($actual))
  ' "${report}/reconciliation.json" >/dev/null || die "P5 erased terminal ${actual}"
done
reset_case opposite-failed
make_stage "${case_dir}/stage-0.json" Failed true
STAGE_LAST="${case_dir}/stage-0.json"
expect_drive_failure Successful

# P6: invalid public input fails before annotate.
reset_case invalid-expected-phase
make_stage "${case_dir}/stage-0.json" '' true
STAGE_LAST="${case_dir}/stage-0.json"
expect_drive_failure Error
[ "$(<"${case_dir}/annotate-count")" -eq 0 ] || die 'P6 annotated for invalid expected phase'
jq -e '.trigger == "none" and .refreshAttempts == 0' \
  "${report}/reconciliation.json" >/dev/null || die 'P6 invalid-input record is misleading'

# P7: force the monotonic clock to the public deadline after one observation.
# Diagnostics must still use the Promotion collection even though the Stage has
# no exact history collection and all six dynamic artifacts must be declared.
reset_case expired
make_stage "${case_dir}/stage-0.json" '' true false
STAGE_LAST="${case_dir}/stage-0.json"
SLEEP_JUMP=180
expect_drive_failure Failed
jq -e '.budget_s == 180 and .elapsed_s == 180 and .refreshAttempts == 1' \
  "${report}/reconciliation.json" >/dev/null || die 'P7 exceeded or replaced the shared deadline'
[ "${#SIT_LEG_EVIDENCE[@]}" -eq 6 ] ||
  die "P7 expected six dynamic artifacts, got ${#SIT_LEG_EVIDENCE[@]}"
for evidence in "${SIT_LEG_EVIDENCE[@]}"; do
  [ -s "${report}/${evidence}" ] || die "P7 declared missing evidence ${evidence}"
done
jq -e '
  (. | length) == 1 and
  .[0].metadata.labels["kargo.akuity.io/freight-collection"] == "collection-f2"
' "${report}/reconciliation-failure-analysisruns.json" >/dev/null ||
  die 'P7 diagnostics joined a stale AnalysisRun or lost the Promotion collection'
jq -e '
  .collectionId == "collection-f2" and .collectionSource == "supplied" and
  .analysisRunCapture.captureAvailable == true
' "${report}/reconciliation-failure-analysisruns-join.json" >/dev/null ||
  die 'P7 did not record the supplied exact diagnostics join'
jq -e '
  .coherentStage.collectionMatchCount == 0 and
  (.failureReason | contains("absent from Stage freightHistory"))
' "${report}/reconciliation.json" >/dev/null ||
  die 'P7 did not model or report the terminal Promotion collection missing from Stage history'

# P8: terminal Stage success without Freight projection consumes the same
# deadline and never opens the removed additive projection window.
reset_case projection-timeout
make_stage "${case_dir}/stage-0.json" Successful false
STAGE_LAST="${case_dir}/stage-0.json"
SLEEP_JUMP=180
expect_drive_failure Successful
jq -e '
  .elapsed_s == 180 and .finalPhase == "Successful" and
  (.failureReason | contains("not projected verified"))
' "${report}/reconciliation.json" >/dev/null || die 'P8 did not fail the shared projection deadline'

# P8a: a failed Stage read after a real observed phase retains that phase and
# message instead of rewriting the attempt as never scheduled.
reset_case capture-loss-after-phase
make_stage "${case_dir}/stage-0.json" Pending true
STAGE_LAST="${case_dir}/stage-unavailable.json"
SLEEP_JUMP=90
expect_drive_failure Failed
jq -e '
  .finalPhase == "Pending" and .verification.message == "exact result" and
  .coherentStage.captureAvailable == false and
  (.failureReason | contains("Stage capture became unavailable after observing Pending"))
' "${report}/reconciliation.json" >/dev/null ||
  die 'P8a erased the observed phase/message after Stage capture loss'

# P8b: duplicate exact collection entries are reported as ambiguity, not as an
# unscheduled verification.
reset_case ambiguous-collection
make_stage "${case_dir}/stage-0.json" '' true
jq '.status.freightHistory += [.status.freightHistory[-1]]' \
  "${case_dir}/stage-0.json" >"${case_dir}/stage-duplicate.json"
STAGE_LAST="${case_dir}/stage-duplicate.json"
mv "${case_dir}/stage-duplicate.json" "${case_dir}/stage-0.json"
STAGE_LAST="${case_dir}/stage-0.json"
SLEEP_JUMP=180
expect_drive_failure Failed
jq -e '
  .coherentStage.collectionMatchCount == 2 and
  (.failureReason | contains("ambiguous entries"))
' "${report}/reconciliation.json" >/dev/null ||
  die 'P8b misreported duplicate exact collections as never scheduled'

# P8c: a terminal exact verification on an incoherent Stage names coherence as
# the blocker and retains the controller-owned terminal message.
reset_case terminal-incoherent
make_stage "${case_dir}/stage-0.json" Failed true
jq '.status.lastPromotion.name = "different-promotion"' \
  "${case_dir}/stage-0.json" >"${case_dir}/stage-incoherent.json"
mv "${case_dir}/stage-incoherent.json" "${case_dir}/stage-0.json"
STAGE_LAST="${case_dir}/stage-0.json"
SLEEP_JUMP=180
expect_drive_failure Failed
jq -e '
  .finalPhase == "Failed" and .verification.message == "exact result" and
  .coherentStage.coherent == false and
  (.failureReason | contains("terminal Failed verification")) and
  (.failureReason | contains("remained incoherent"))
' "${report}/reconciliation.json" >/dev/null ||
  die 'P8c misreported a terminal-but-incoherent Stage'

# P8d: the no-ID diagnostics path used by the distinct reverify wait records a
# derived join when possible and an explicit unavailable join otherwise. Its
# AnalysisRun evidence is always a valid array.
reset_case diagnostics-derived-join
make_stage "${case_dir}/stage-0.json" Failed true
jq --arg collection "${TEST_COLLECTION}" \
  '.status.freightHistory |= map(select(.id == $collection))' \
  "${case_dir}/stage-0.json" >"${case_dir}/stage-derived.json"
mv "${case_dir}/stage-derived.json" "${case_dir}/stage-0.json"
STAGE_LAST="${case_dir}/stage-0.json"
kargo_capture_stage_failure_diagnostics \
  "${TEST_PROJECT}" "${TEST_STAGE}" "${TEST_FREIGHT}" \
  "${report}/derived" ''
jq -e '
  .collectionId == "collection-f2" and .collectionSource == "derived" and
  .analysisRunCapture.captureAvailable == true
' "${report}/derived-analysisruns-join.json" >/dev/null ||
  die 'P8d did not record the derived reverify diagnostics join'
jq -e 'type == "array" and length == 1' \
  "${report}/derived-analysisruns.json" >/dev/null ||
  die 'P8d derived join did not emit valid exact AnalysisRun evidence'

reset_case diagnostics-unavailable-join
make_stage "${case_dir}/stage-0.json" '' true false
jq '.status.freightHistory = []' \
  "${case_dir}/stage-0.json" >"${case_dir}/stage-unavailable.json"
mv "${case_dir}/stage-unavailable.json" "${case_dir}/stage-0.json"
STAGE_LAST="${case_dir}/stage-0.json"
kargo_capture_stage_failure_diagnostics \
  "${TEST_PROJECT}" "${TEST_STAGE}" "${TEST_FREIGHT}" \
  "${report}/unavailable" ''
jq -e '
  .collectionId == null and .collectionSource == "unavailable" and
  .analysisRunCapture.attempted == false
' "${report}/unavailable-analysisruns-join.json" >/dev/null ||
  die 'P8d did not record the unavailable reverify diagnostics join'
jq -e 'type == "array" and length == 0' \
  "${report}/unavailable-analysisruns.json" >/dev/null ||
  die 'P8d unavailable join did not emit valid empty AnalysisRun evidence'

# P9: ConfigMap responses are persisted, asserted, and declared.
reset_case outcome-capture
kargo_set_analysis_outcome "${TEST_PROJECT}" canary-smoke fail \
  "${report}/analysis-outcome.json"
jq -e '.data["canary-smoke"] == "fail"' "${report}/analysis-outcome.json" >/dev/null ||
  die 'P9 analysis outcome response was not preserved'
[ "${SIT_LEG_EVIDENCE[0]}" = 'analysis-outcome.json' ] ||
  die 'P9 analysis outcome response was not dynamically declared'

# P10: failed-leg declarations are truthful even when pass-only files were not
# reached. Missing expectations survive in a real gap artifact, never evidence[].
reset_case failure-evidence
printf '{}\n' >"${report}/present.json"
SIT_LEG_EVIDENCE=('present.json' 'not-created.json')
sit_prepare_failure_evidence
[ "${#SIT_LEG_EVIDENCE[@]}" -eq 2 ] || die 'P10 failure evidence was not partitioned'
[ "${SIT_LEG_EVIDENCE[0]}" = 'present.json' ] || die 'P10 dropped existing evidence'
[ "${SIT_LEG_EVIDENCE[1]}" = 'failure-evidence-gaps.json' ] || die 'P10 did not declare its gap record'
jq -e '.missingEvidence == ["not-created.json"] and .invalidEvidence == []' \
  "${report}/failure-evidence-gaps.json" >/dev/null || die 'P10 gap record is inaccurate'

echo '  exact post-Promotion driver passes production-byte scheduling, terminal, identity, deadline, projection, diagnostics, outcome, and evidence regressions ✓'
POSTPROMOTIONDRIVER
  chmod +x "${tmp}/post-promotion-driver.sh"
  bash "${tmp}/post-promotion-driver.sh" "${ppv_assert}" "${ppv_fns}" \
    "${tmp}/post-promotion-model"

  # Source-level invariant: join each continued shell command, pair every
  # Promotion wait with its immediate driver, and compare the exact
  # (Stage, Promotion capture, expected phase) tuple. The shared helper owns
  # eight runtime edges and the other seven tuples own one each: fifteen total.
  awk '
    {
      line = $0
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      print logical
      logical = ""
    }
  ' "${ppv_source}" >"${tmp}/ppv-logical-commands.sh"
  awk -F '"' '
    /^[[:space:]]+kargo_wait_promotion_succeeded / {
      if (pending) exit 1
      pending = 1
      wait_stage = $4
      wait_capture = $8
      waits++
      next
    }
    /^[[:space:]]+kargo_drive_post_promotion_verification / {
      if (!pending || $4 != wait_stage || $8 != wait_capture) exit 1
      phase = $9
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", phase)
      split(phase, tokens, /[[:space:]]+/)
      print $4 "\t" $8 "\t" tokens[1]
      pending = 0
      drivers++
    }
    END {
      if (pending || waits != 8 || drivers != 8) exit 1
    }
  ' "${tmp}/ppv-logical-commands.sh" >"${tmp}/ppv-actual-tuples.tsv" ||
    fail 'not every lexical Promotion wait flows directly through its identity-matched driver'
  cat >"${tmp}/ppv-expected-tuples.tsv" <<'PPVTUPLES'
${stage}	${report}/${prefix}-promotion.json	Successful
${pikachu}	${report}/kargo-runtime-f1-pikachu-promotion.json	Successful
${ampharos}	${report}/kargo-runtime-f1-ampharos-promotion.json	Successful
${pikachu}	${report}/kargo-runtime-f2-pikachu-promotion.json	Failed
${ampharos}	${report}/kargo-runtime-f2-ampharos-promotion.json	Successful
${pikachu}	${report}/kargo-runtime-f3-pikachu-auto-promotion.json	Successful
${pikachu}	${report}/kargo-runtime-soak-pikachu-promotion.json	Successful
${ampharos}	${report}/kargo-runtime-soak-ampharos-promotion.json	Successful
PPVTUPLES
  if ! cmp -s "${tmp}/ppv-expected-tuples.tsv" "${tmp}/ppv-actual-tuples.tsv"; then
    diff -u "${tmp}/ppv-expected-tuples.tsv" "${tmp}/ppv-actual-tuples.tsv" >&2 || true
    fail 'the eight post-Promotion Stage/capture/expected-phase tuples drifted'
  fi
  ppv_shared_edges="$(rg -c '^  kargo_auto_promote_and_verify ' "${ppv_source}")"
  ppv_direct_edges=$(($(wc -l <"${tmp}/ppv-actual-tuples.tsv") - 1))
  [ "$((ppv_shared_edges + ppv_direct_edges))" -eq 14 ] ||
    fail 'the exact post-Promotion tuple guard no longer covers all fourteen runtime edges'
  sed -n '/^kargo_runtime_trace_wall_clock_soak() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-soak-function.sh"
  [ "$(tail -n 1 "${tmp}/ppv-soak-function.sh")" = '}' ] ||
    fail 'the extracted wall-clock soak function is unterminated'
  awk '
    {
      line = $0
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      print logical
      logical = ""
    }
  ' "${tmp}/ppv-soak-function.sh" >"${tmp}/ppv-soak-logical.sh"

  ppv_soak_ordering_contract() {
    awk '
      index($0, "lower_bound=$((since_epoch + 90))") { lower_bound = NR; lower_count++ }
      /^[[:space:]]+kargo_seed_freight / { seed_count++ }
      /^[[:space:]]+kargo_create_manual_promotion / { manual = NR; manual_count++ }
      /^[[:space:]]+kargo_refresh_stage(_recorded)? / &&
          index($0, "\"${ampharos}\"") {
        refresh_count++
        if (index($0, "kargo-runtime-soak-pre-boundary-refresh.json")) {
          pre_refresh = NR
          pre_refresh_count++
        } else if (index($0, "kargo-runtime-soak-post-boundary-refresh.json")) {
          post_refresh = NR
          post_refresh_count++
        } else {
          unexpected_refresh = 1
        }
      }
      /^[[:space:]]+kargo_assert_no_promotion_for 12 / &&
          index($0, "kargo-runtime-soak-early-hold.json") { hold = NR; hold_count++ }
      /^[[:space:]]+kargo_capture_promotion_denial / &&
          index($0, "kargo-runtime-soak-early-denial.json") { denial = NR; denial_count++ }
      /^[[:space:]]+kargo_wait_wall_clock_boundary / &&
          index($0, "kargo-runtime-soak-boundary-wait.json") { boundary = NR; boundary_count++ }
      /^[[:space:]]+kargo_capture_soak_pre_stimulus / &&
          index($0, "kargo-runtime-soak-pre-stimulus.json") { snapshot = NR; snapshot_count++ }
      /^[[:space:]]+kargo_capture_promotion_dry_run_acceptance / &&
          index($0, "kargo-runtime-soak-ampharos-available-dry-run.json") {
        dry_run = NR
        dry_run_count++
      }
      /^[[:space:]]+kargo_wait_promotion_succeeded / &&
          index($0, "kargo-runtime-soak-ampharos-promotion.json") { wait = NR; wait_count++ }
      /promotion_epoch.*-ge.*lower_bound/ { lower_assertion = NR; lower_assertion_count++ }
      /elapsed.*-le 180/ { upper_assertion = NR; upper_assertion_count++ }
      /^[[:space:]]+kargo_drive_post_promotion_verification / &&
          index($0, "kargo-runtime-soak-ampharos-promotion.json") { driver = NR; driver_count++ }
      /^[[:space:]]+kargo_wait_git_tag / && index($0, "ampharos") { git_oracle = NR; git_count++ }
      /^[[:space:]]+kargo_capture_current_analysis_run / &&
          index($0, "${ampharos}") { analysis = NR; analysis_count++ }
      END {
        if (lower_count != 1 || seed_count != 1 || manual_count != 1 ||
            refresh_count != 2 || pre_refresh_count != 1 || post_refresh_count != 1 ||
            hold_count != 1 || denial_count != 1 || boundary_count != 1 ||
            snapshot_count != 1 || dry_run_count != 1 || wait_count != 1 ||
            lower_assertion_count != 1 || upper_assertion_count != 1 ||
            driver_count != 1 || git_count != 1 || analysis_count != 1 ||
            unexpected_refresh) exit 1
        if (!(manual < lower_bound && lower_bound < pre_refresh &&
              pre_refresh < hold && hold < denial && denial < boundary &&
              boundary < snapshot && snapshot < dry_run && dry_run < post_refresh &&
              post_refresh < wait && wait < lower_assertion &&
              lower_assertion < upper_assertion && upper_assertion < driver &&
              driver < git_oracle && git_oracle < analysis)) exit 1
      }
    ' "$1"
  }
  ppv_soak_ordering_contract "${tmp}/ppv-soak-logical.sh" ||
    fail 'the soak path lost its strict deny-boundary-snapshot-admit-refresh-wait ordering'

  # Controlled negative: the previous no-post-boundary-stimulus shape must be
  # rejected by the same production-byte ordering contract.
  sed '/^[[:space:]]*kargo_refresh_stage_recorded .*kargo-runtime-soak-post-boundary-refresh.json/d' \
    "${tmp}/ppv-soak-logical.sh" >"${tmp}/ppv-soak-no-post-refresh.sh"
  ! cmp -s "${tmp}/ppv-soak-logical.sh" "${tmp}/ppv-soak-no-post-refresh.sh" ||
    fail 'the no-post-boundary-refresh negative did not mutate the controlled source'
  if ppv_soak_ordering_contract "${tmp}/ppv-soak-no-post-refresh.sh"; then
    fail 'the soak ordering contract accepted the old no-post-boundary-refresh sequence'
  fi

  # The soak function may only observe state and invoke the named helpers. It
  # must never manufacture eligibility, status, policy, Freight, or Promotion
  # state, nor replace the boundary predicate with an in-function sleep.
  if rg -qi '^[[:space:]]*sleep([[:space:]]|$)|kargo_backdate_freight_stage|--subresource[= ]status|kubectl .*\b(apply|create|delete|patch|replace)\b|projectconfig|promotionpolicies' \
    "${tmp}/ppv-soak-logical.sh"; then
    fail 'the wall-clock soak function fabricates state or sleeps instead of using the persisted boundary'
  fi
  # shellcheck disable=SC2016 # literal shell/jq bytes from the extracted source
  for ppv_persisted_boundary_contract in \
    'since="$(kubectl -n "${project}" get freight "${freight}" -o json |' \
    'jq -r --arg stage "${pikachu}" '\''.status.currentlyIn[$stage].since'\'')"' \
    'since_epoch="$(date -u -d "${since}" +%s)"' \
    'lower_bound=$((since_epoch + 90))' \
    'kargo_wait_wall_clock_boundary "${since}" "${lower_bound}"' \
    '"${since}" "${lower_bound}" "${pre_boundary_token}"'; do
    rg -qF "${ppv_persisted_boundary_contract}" "${tmp}/ppv-soak-logical.sh" ||
      fail "the soak path is no longer bound to persisted Pikachu since: ${ppv_persisted_boundary_contract}"
  done

  for ppv_soak_fn in \
    kargo_refresh_stage_recorded \
    kargo_wait_wall_clock_boundary \
    kargo_capture_soak_pre_stimulus \
    kargo_capture_promotion_dry_run_acceptance \
    kargo_capture_promotion_denial \
    kargo_assert_no_promotion_for \
    kargo_wait_promotion_succeeded; do
    sed -n "/^${ppv_soak_fn}() {$/,/^}$/p" "${ppv_source}" \
      >"${tmp}/ppv-${ppv_soak_fn}.sh"
    [ "$(tail -n 1 "${tmp}/ppv-${ppv_soak_fn}.sh")" = '}' ] ||
      fail "the extracted ${ppv_soak_fn}() body is unterminated"
  done
  awk '
    {
      line = $0
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      print logical
      logical = ""
    }
  ' "${tmp}/ppv-kargo_refresh_stage_recorded.sh" \
    >"${tmp}/ppv-recorded-refresh-logical.sh"
  awk '
    /previous_token="\$\(kubectl/ { previous = NR }
    /kubectl .* annotate stage/ { annotate = NR }
    /sit_wait_for 90 .*kargo_check_refresh_handled/ { wait = NR }
    /last_handled_refresh="\$\(kubectl/ { handled = NR }
    /\[ "\$\{last_handled_refresh\}" = "\$\{token\}" \]/ { assertion = NR }
    /acknowledged_at="\$\(sit_now\)"/ { acknowledged = NR }
    END {
      if (!previous || !annotate || !wait || !handled || !assertion || !acknowledged ||
          !(previous < annotate && annotate < wait && wait < handled &&
            handled < assertion && assertion < acknowledged)) exit 1
    }
  ' "${tmp}/ppv-recorded-refresh-logical.sh" ||
    fail 'the recorded Stage refresh does not order previous-token capture, annotation, acknowledgement, and evidence'
  if ! rg -qF 'token="fleet-sit-$(sit_epoch)-$$-${RANDOM}"' \
    "${tmp}/ppv-recorded-refresh-logical.sh" ||
    ! rg -q 'previous_token=.*status\.lastHandledRefresh' \
      "${tmp}/ppv-recorded-refresh-logical.sh" ||
    ! rg -q 'sit_wait_for 90 .*kargo_check_refresh_handled .*"\$\{token\}"' \
      "${tmp}/ppv-recorded-refresh-logical.sh" ||
    ! rg -q 'last_handled_refresh=.*status\.lastHandledRefresh' \
      "${tmp}/ppv-recorded-refresh-logical.sh" ||
    ! rg -qF '[ "${last_handled_refresh}" = "${token}" ]' \
      "${tmp}/ppv-recorded-refresh-logical.sh"; then
    fail 'the recorded Stage refresh no longer proves a unique token and lastHandledRefresh acknowledgement'
  fi
  # shellcheck disable=SC2016 # literal jq fields from the extracted source
  for ppv_refresh_field in \
    'token:$token' 'previousToken:$previousToken' \
    'annotatedAt:$annotatedAt' 'annotatedEpoch:$annotatedEpoch' \
    'acknowledgedAt:$acknowledgedAt' 'acknowledgedEpoch:$acknowledgedEpoch' \
    'lastHandledRefresh:$lastHandledRefresh'; do
    rg -qF "${ppv_refresh_field}" "${tmp}/ppv-kargo_refresh_stage_recorded.sh" ||
      fail "the recorded Stage refresh omits ${ppv_refresh_field}"
  done

  if ! rg -qF 'while [ "${current_epoch}" -lt "${lower_bound}" ]' \
    "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh" ||
    ! rg -qF 'current_epoch="$(sit_epoch)"' \
      "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh" ||
    ! rg -qF 'deadline=$((started_monotonic + remaining + 30))' \
      "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh" ||
    ! rg -qF '[ "${sleep_s}" -le 2 ] || sleep_s=2' \
      "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh" ||
    ! rg -qF 'finishedEpoch:$finishedEpoch' \
      "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh"; then
    fail 'the wall-clock helper is not a bounded predicate over the persisted epoch'
  fi
  if rg -q "sleep[[:space:]]+(['\"]?90['\"]?|.*lower_bound)|sleep_s=90" \
    "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh"; then
    fail 'the wall-clock helper replaced boundary polling with a hard-coded soak sleep'
  fi

  awk '
    {
      line = $0
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      print logical
      logical = ""
    }
  ' "${tmp}/ppv-kargo_capture_soak_pre_stimulus.sh" \
    >"${tmp}/ppv-soak-snapshot-logical.sh"

  if rg -qi 'kubectl .*\b(annotate|apply|create|delete|patch|replace)\b|kargo_refresh_stage|kargo_backdate_freight_stage|--subresource[= ]status|projectconfig|promotionpolicies|kargo_seed_freight|kargo_create_manual_promotion' \
    "${tmp}/ppv-soak-snapshot-logical.sh"; then
    fail 'the pre-stimulus snapshot is not read-only'
  fi
  if rg -qi 'kubectl .*\b(annotate|apply|create|delete|patch|replace)\b|kargo_refresh_stage|kargo_backdate_freight_stage|--subresource[= ]status|projectconfig|promotionpolicies|kargo_seed_freight|kargo_create_manual_promotion' \
    "${tmp}/ppv-kargo_wait_wall_clock_boundary.sh"; then
    fail 'the wall-clock boundary helper manufactures eligibility or state'
  fi
  if rg -qi 'kubectl .*\b(apply|create|delete|patch|replace)\b|kargo_backdate_freight_stage|--subresource[= ]status|projectconfig|promotionpolicies|kargo_seed_freight|kargo_create_manual_promotion' \
    "${tmp}/ppv-recorded-refresh-logical.sh"; then
    fail 'the recorded refresh helper performs state changes beyond its supported annotation'
  fi
  # shellcheck disable=SC2016 # literal jq predicates from the extracted source
  for ppv_snapshot_contract in \
    '.capturedEpoch >= .lowerBoundEpoch' \
    '.expectedPikachuSince == $since and .persistedPikachuSince == $since' \
    '(.residency.pikachu.since // "") == $since' \
    '(.residency.raichu.since // "") != ""' \
    '(.verification.pikachu.verifiedAt // "") != ""' \
    '(.verification.raichu.verifiedAt // "") != ""' \
    '.autoPromotionEnabled == true' \
    '.lastHandledRefresh == $token' \
    '.promotionCount == 0 and (.ampharosPromotions | length) == 0'; do
    rg -qF "${ppv_snapshot_contract}" \
      "${tmp}/ppv-kargo_capture_soak_pre_stimulus.sh" ||
      fail "the pre-stimulus snapshot lost contract ${ppv_snapshot_contract}"
  done
  rg -q 'kubectl create --dry-run=server ' \
    "${tmp}/ppv-kargo_capture_promotion_dry_run_acceptance.sh" ||
    fail 'the post-boundary admission proof is not a server-side dry run'
  rg -q 'admitted:true,serverSide:true' \
    "${tmp}/ppv-kargo_capture_promotion_dry_run_acceptance.sh" ||
    fail 'the server-side dry-run artifact no longer records successful admission'
  [ "$(rg -c 'kubectl create ' \
    "${tmp}/ppv-kargo_capture_promotion_dry_run_acceptance.sh")" -eq 1 ] ||
    fail 'the admission helper contains a Promotion create beyond its one server-side dry run'
  if rg -q 'kubectl .*\b(annotate|apply|delete|patch|replace)\b|kargo_refresh_stage' \
    "${tmp}/ppv-kargo_capture_promotion_dry_run_acceptance.sh"; then
    fail 'the admission helper mutates state outside its server-side dry run'
  fi
  if ! rg -q 'kubectl create -f ' \
    "${tmp}/ppv-kargo_capture_promotion_denial.sh" ||
    rg -q -- '--dry-run' "${tmp}/ppv-kargo_capture_promotion_denial.sh" ||
    ! rg -qF '[ "${status}" -ne 0 ] ||' \
      "${tmp}/ppv-kargo_capture_promotion_denial.sh" ||
    ! rg -qF "rg -F 'Freight is not available to this Stage'" \
      "${tmp}/ppv-kargo_capture_promotion_denial.sh" ||
    ! rg -q 'admitted:false' \
      "${tmp}/ppv-kargo_capture_promotion_denial.sh"; then
    fail 'the pre-boundary negative is no longer a real webhook denial with pinned text'
  fi
  [ "$(rg -c 'kubectl create ' \
    "${tmp}/ppv-kargo_capture_promotion_denial.sh")" -eq 1 ] ||
    fail 'the denial helper contains a Promotion create beyond its one rejected request'
  if rg -q 'kubectl .*\b(annotate|apply|delete|patch|replace)\b|kargo_refresh_stage' \
    "${tmp}/ppv-kargo_capture_promotion_denial.sh"; then
    fail 'the pre-boundary denial helper mutates state beyond its rejected Promotion request'
  fi
  if ! rg -qF 'deadline=$((SECONDS + duration_s))' \
    "${tmp}/ppv-kargo_assert_no_promotion_for.sh" ||
    ! rg -qF 'while [ "${SECONDS}" -lt "${deadline}" ]' \
      "${tmp}/ppv-kargo_assert_no_promotion_for.sh" ||
    ! rg -qF 'count="$(kargo_promotion_count' \
      "${tmp}/ppv-kargo_assert_no_promotion_for.sh" ||
    ! rg -qF 'promotionCount:0' \
      "${tmp}/ppv-kargo_assert_no_promotion_for.sh"; then
    fail 'the 12-second pre-boundary hold no longer proves zero Promotions for its full duration'
  fi
  if rg -qi 'kubectl .*\b(annotate|apply|create|delete|patch|replace)\b|kargo_refresh_stage|kargo_backdate_freight_stage|--subresource[= ]status|projectconfig|promotionpolicies' \
    "${tmp}/ppv-kargo_assert_no_promotion_for.sh"; then
    fail 'the pre-boundary no-Promotion hold mutates the state it observes'
  fi
  rg -q 'sit_wait_for 240 ' "${tmp}/ppv-kargo_wait_promotion_succeeded.sh" ||
    fail 'the Promotion success wait no longer retains its literal 240-second budget'
  rg -qF '== Promotion wait diagnostics:' \
    "${tmp}/ppv-kargo_wait_promotion_succeeded.sh" ||
    fail 'the Promotion timeout no longer emits its retained diagnostic block'
  # shellcheck disable=SC2016 # source-code literals intentionally retain ${}.
  for ppv_timeout_surface in \
    'get stage "${stage}" -o json' \
    'get freight "${freight}" -o json' \
    'get promotions.kargo.akuity.io -o json' \
    'logs deployment/kargo-controller --tail=500'; do
    rg -qF "${ppv_timeout_surface}" \
      "${tmp}/ppv-kargo_wait_promotion_succeeded.sh" ||
      fail "the Promotion timeout lost diagnostic surface: ${ppv_timeout_surface}"
  done
  if rg -qi 'kubectl .*\b(annotate|apply|create|delete|patch|replace)\b|kargo_refresh_stage|kargo_backdate_freight_stage|--subresource[= ]status|projectconfig|promotionpolicies' \
    "${tmp}/ppv-kargo_wait_promotion_succeeded.sh"; then
    fail 'the bounded Promotion wait mutates the Stage or eligibility state it observes'
  fi

  # shellcheck disable=SC2016 # literal jq predicates from the extracted source
  for ppv_post_refresh_contract in \
    '.token != $previousToken and .previousToken == $previousToken' \
    '.lastHandledRefresh == .token' \
    '(.annotatedAt | fromdateiso8601) == .annotatedEpoch' \
    '(.acknowledgedAt | fromdateiso8601) == .acknowledgedEpoch' \
    '.annotatedEpoch >= $lowerBoundEpoch' \
    '.acknowledgedEpoch >= $lowerBoundEpoch' \
    '$dryRun[0].fleetSitDryRun.admittedEpoch <= .annotatedEpoch'; do
    rg -qF "${ppv_post_refresh_contract}" "${tmp}/ppv-soak-function.sh" ||
      fail "the post-boundary refresh lost contract ${ppv_post_refresh_contract}"
  done
  for ppv_soak_evidence in \
    kargo-runtime-soak-pre-boundary-refresh.json \
    kargo-runtime-soak-boundary-wait.json \
    kargo-runtime-soak-pre-stimulus.json \
    kargo-runtime-soak-ampharos-available-dry-run.json \
    kargo-runtime-soak-post-boundary-refresh.json; do
    sed -n "/sit_leg_begin 'L9-kargo-v1-runtime'/,/run_kargo_runtime_leg/p" \
      "${ppv_source}" | rg -qF "${ppv_soak_evidence}" ||
      fail "the L9 evidence declaration omits ${ppv_soak_evidence}"
  done
  sed -n '/^run_kargo_runtime_leg() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-runtime-leg.sh"
  awk '
    /kargo_runtime_trace_wall_clock_soak/ { soak = NR }
    /kargo_runtime_finalize_git_oracle/ { oracle = NR }
    /kargo_runtime_collect_logs/ { logs = NR }
    END { if (!soak || !oracle || !logs || !(soak < oracle && oracle < logs)) exit 1 }
  ' "${tmp}/ppv-runtime-leg.sh" ||
    fail 'the repaired soak no longer flows through the unchanged git oracle and log capture'
  ! rg -q '\.status\.freightHistory\[0\]' "${ppv_source}" ||
    fail 'the F2 reverify path still uses freightHistory[0] identity'
  ! rg -q 'kargo_wait_verification_phase|kargo_drive_stage_reconciliation' "${ppv_source}" ||
    fail 'an obsolete post-Promotion wait/driver remains reachable'
  rg -q 'reverify_succeeded_epoch=.*reverify_finished_at' "${ppv_source}" ||
    fail 'F2 immediate eligibility is not based on observed re-verification success'
  if ! rg -q 'kargo-runtime-f2-analysis-outcome-fail.json' "${ppv_source}" ||
    ! rg -q 'kargo-runtime-f2-analysis-outcome-pass.json' "${ppv_source}"; then
    fail 'F2 does not retain both analysis-outcome API responses'
  fi
  for fallback in \
    kargo-runtime-canary-stages-final.json \
    kargo-runtime-canary-freight-final.json \
    kargo-runtime-canary-promotions-final.json \
    kargo-runtime-canary-analysisruns-final.json \
    kargo-runtime-canary-events-final.json \
    kargo-runtime-canary-analysis-outcomes-final.json \
    kargo-runtime-canary-sitsoak-stages-final.json \
    kargo-runtime-canary-sitsoak-freight-final.json \
    kargo-runtime-canary-sitsoak-promotions-final.json \
    kargo-runtime-canary-sitsoak-analysisruns-final.json \
    kargo-runtime-canary-sitsoak-events-final.json \
    kargo-runtime-canary-sitsoak-analysis-outcomes-final.json; do
    rg -qF "${fallback}" "${ppv_source}" ||
      fail "final failure fallback omits ${fallback}"
  done
  sed -n '/^collect_final_evidence() {$/,/^}$/p' "${ppv_source}" \
    >"${tmp}/ppv-final-evidence.sh"
  awk '
    {
      line = $0
      sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      print logical
      logical = ""
    }
  ' "${tmp}/ppv-final-evidence.sh" >"${tmp}/ppv-final-evidence-logical.sh"
  for fallback_capture in \
    'canary-sitsoak stages.kargo.akuity.io .*kargo_final_paths\[6\]' \
    'canary-sitsoak freight.kargo.akuity.io .*kargo_final_paths\[7\]' \
    'canary-sitsoak promotions.kargo.akuity.io .*kargo_final_paths\[8\]' \
    'canary-sitsoak analysisruns.argoproj.io .*kargo_final_paths\[9\]' \
    'canary-sitsoak events .*kargo_final_paths\[10\]' \
    'canary-sitsoak configmap/kargo-analysis-outcomes .*kargo_final_paths\[11\]'; do
    rg -q "kargo_capture_json_evidence ${fallback_capture}" \
      "${tmp}/ppv-final-evidence-logical.sh" ||
      fail "final failure fallback does not capture ${fallback_capture}"
  done
  rg -qF 'SIT_LEG_EVIDENCE+=("${kargo_final_paths[@]}")' \
    "${tmp}/ppv-final-evidence.sh" ||
    fail 'the final canary and canary-sitsoak captures are not declared on L9 failure'
  sed -n '/^on_error() {$/,/^}$/p' "${ppv_source}" >"${tmp}/ppv-on-error.sh"
  awk '
    /collect_final_evidence/ { collect = NR }
    /sit_prepare_failure_evidence/ { prepare = NR }
    /sit_leg_fail/ { fail = NR }
    END {
      if (!collect || !prepare || !fail || !(collect < prepare && prepare < fail)) exit 1
    }
  ' "${tmp}/ppv-on-error.sh" ||
    fail 'failure evidence is serialized before final capture/filtering'
  if ! rg -q 'error_functions=.*FUNCNAME' "${ppv_source}" ||
    ! rg -q 'error_sources=.*BASH_SOURCE' "${ppv_source}" ||
    ! rg -q 'error_lines=.*BASH_LINENO' "${ppv_source}"; then
    fail 'last-error diagnostics do not retain the Bash call stack'
  fi
  echo '  all 14 runtime edges, distinct reverify, causal soak ordering, outcome captures, and both project fallbacks are source-guarded ✓'
  ;;
guard)
  bash ./scripts/validate/registry-guard.sh
  ;;
presence)
  test -s docs/domain/fleet-repo.md || fail "docs/domain/fleet-repo.md missing"
  test -s .github/CODEOWNERS || fail "CODEOWNERS missing"
  test -s .github/rulesets/registry-guard-main.json || fail "registry ruleset payload missing"
  test -s scripts/local/registry-guard-apply.sh || fail "registry-guard apply script missing"
  test -s .github/workflows/registry-guard-e2e.yaml || fail "periodic registry-guard e2e workflow missing"
  test -s registry/argocd-webhook-secret.yaml || fail "ArgoCD webhook ExternalSecret missing"
  test -s "${chart}/values.schema.json" || fail "compiler chart values.schema.json missing"
  test -s "${chart}/values.schema.source.json" || fail "deliberate compiler schema source missing"
  test -s "${golden_dir}/canary.prod.yaml" || fail "prod golden render missing"
  # pin-management + webhook-wiring docs are published in the domain doc.
  rg -q '^## The `machinery-stable` tag' docs/domain/fleet-repo.md || fail "machinery-stable pin doc missing"
  rg -q '^## The `mercury-stable` pin' docs/domain/fleet-repo.md || fail "mercury-stable pin doc missing"
  rg -q '^## ArgoCD webhook wiring' docs/domain/fleet-repo.md || fail "ArgoCD webhook wiring doc missing"
  rg -q '⚠ S11 ASSUMED-GREEN' docs/domain/fleet-repo.md || fail "S11 assumption marker missing"
  rg -q 'MINUN USER-REVIEW' docs/domain/fleet-repo.md || fail "MINUN user-review marker missing"
  ;;
*)
  echo "❌ unknown validation mode '${mode}'" >&2
  exit 1
  ;;
esac

echo "✅ fleet ${mode} validation passed"
