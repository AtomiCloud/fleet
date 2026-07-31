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
    kargo_runtime_canonical_image_tag \
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
  grep -q -- '--namespace k8s.io' "${nii_fns}" ||
    fail "the extracted import function does not target the k8s.io containerd namespace the CRI reads"
  # The repair's own bytes, guarded the same way. The ORCHESTRATION is extracted
  # too (kargo_runtime_bind_node_images), so every case below drives the real
  # call sites — a gate that only extracted the helpers could stay green while
  # production never called them.
  grep -q -- 'images tag' "${nii_fns}" ||
    fail "the extracted functions never create a containerd image alias; the extraction is not the production repair"
  grep -q -- 'crictl images -o json' "${nii_fns}" ||
    fail "the extracted functions never read the CRI image inventory"
  grep -q -- 'crictl inspecti -o json' "${nii_fns}" ||
    fail "the extracted functions never resolve the exact combined workload reference through the CRI"
  # The no-force rule, read off EXECUTABLE ARGV rather than prose: production
  # explains at length why it omits --force, and a check that greps the whole
  # extraction would red on those very comments. Both directions are then
  # positive-controlled, so this can neither false-red on documentation nor
  # stay silently green if it stops seeing the flag at all.
  nii_tag_argv() {
    grep -F 'ctr --namespace k8s.io images tag' "$1" | grep -v '^[[:space:]]*#'
  }
  nii_forces() {
    [ "$(nii_tag_argv "$1" | grep -cF -- '--force')" -gt 0 ]
  }
  [ -n "$(nii_tag_argv "${nii_fns}")" ] ||
    fail "the extracted alias step carries no ctr images tag argv at all"
  ! nii_forces "${nii_fns}" ||
    fail "the extracted alias step passes --force; a name collision on a fresh per-run cluster must fail closed, not be replaced"
  sed 's/ctr --namespace k8s.io images tag/& --force/' "${nii_fns}" \
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
  grep -qF 'kargo_runtime_alias_node_image "${node}"' "${nii_fns}" ||
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
  # containerd 1.7 ctr prints one line per image binding the stored name to the
  # archive root descriptor — here the pinned index digest.
  printf 'unpacking %s (%s)...done\n' "${ref}" "${digest}"
  printf '%s\t%s\n' "${ref}" "${digest}" >>"${node_state}"
}

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
  kargo_runtime_bind_node_images "${node}" "${pairs[@]}"
  ;;
project-cri)
  seed_node_state "$@"
  docker exec "${node}" crictl images -o json >"${cri_images}"
  ;;
seeded-cri)
  seed_node_state "$@"
  docker exec "${node}" crictl images -o json >"${cri_images}"
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
  grep -q '^unpacking ' "${tmp}/r1/report/kargo-runtime-image-imports.txt" ||
    fail 'R1 the fixed node-image path: the retained transcript carries no ctr unpack marker'
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
  nii_expect 'R3 platform-scope mutation' 1 'streaming the pinned image into the k3d node failed' r3
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

  # R5 — the positive marker must bind the PIN, not merely say 'done'. A
  # success-shaped transcript whose unpack digest is other content is red.
  {
    printf '== import %s (%s)\n' "${nii_kargo_tag}" "${KARGO_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_kargo_tag}" "${nii_other}"
    printf '== import %s (%s)\n' "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_rollouts_tag}" "${ROLLOUTS_IMAGE_DIGEST}"
    printf '== import %s (%s)\n' "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
    printf 'unpacking %s (%s)...done\n' "${nii_analysis_tag}" "${ANALYSIS_IMAGE_DIGEST}"
  } >"${tmp}/transcript-wrong-pin.txt"
  nii_case r5 transcript "${nii_fns}" "${tmp}/transcript-wrong-pin.txt"
  nii_expect 'R5 unpack marker with the wrong digest' 1 'does not bind' r5
  echo "  R5 an unpack marker that completes on other content is rejected, so acceptance is not 'contains done' ✓"

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
    'kargo_runtime_alias_node_image "${node}"' 'N1a the alias call is load-bearing'
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
    'kargo_runtime_assert_cri_reference "${node}"' \
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
