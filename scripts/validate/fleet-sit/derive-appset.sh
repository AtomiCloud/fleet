#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
  echo "usage: $0 <committed-appset> <output> <fleet-url> <fleet-services-url> <canary-url> <sitother-url> [evidence-dir]" >&2
  exit 2
fi

source_appset="$1"
output="$2"
fleet_url="$3"
fleet_services_url="$4"
canary_url="$5"
sitother_url="$6"
evidence_dir="${7:-}"
canonical_fleet_url='https://github.com/AtomiCloud/fleet'
canonical_fleet_services_url='https://github.com:443/AtomiCloud/fleet'
tmp="$(mktemp -d)"

cleanup() {
  rm -rf "${tmp}"
}
trap cleanup EXIT

[ -f "${source_appset}" ] || {
  echo "source ApplicationSet does not exist: ${source_appset}" >&2
  exit 1
}

yq -o=json '.' "${source_appset}" >"${tmp}/source.json"
jq -e --arg fleet "${canonical_fleet_url}" --arg services "${canonical_fleet_services_url}" '
  .kind == "ApplicationSet" and
  .metadata.name == "platforms" and
  (.spec.generators | length) == 1 and
  .spec.generators[0].scmProvider.github.organization == "AtomiCloud" and
  .spec.generators[0].scmProvider.filters == [{"repositoryMatch":"\\.carbon$"}] and
  ([.spec.template.spec.sources[] | select(.repoURL == $fleet)] | length) == 1 and
  ([.spec.template.spec.sources[] | select(.repoURL == $services)] | length) == 1 and
  .spec.template.spec.sources[0].targetRevision == "{{ if eq .repository \"canary.carbon\" }}main{{ else }}machinery-stable{{ end }}" and
  .spec.template.spec.sources[2].repoURL == $services and
  .spec.template.spec.sources[2].targetRevision == "HEAD" and
  .spec.template.spec.sources[2].ref == "services" and
  (.spec.templatePatch | contains("if ne .repository \"canary.carbon\""))
' "${tmp}/source.json" >/dev/null || {
  echo 'committed platforms ApplicationSet no longer matches the derivation contract' >&2
  exit 1
}

export FLEET_REPO_URL="${fleet_url}"
export FLEET_SERVICES_REPO_URL="${fleet_services_url}"
export CANARY_REPO_URL="${canary_url}"
export SITOTHER_REPO_URL="${sitother_url}"
mkdir -p "$(dirname "${output}")"
yq '
  .spec.generators = [{"list":{"elements":[
    {"repository":"canary.carbon","url":strenv(CANARY_REPO_URL)},
    {"repository":"sitother.carbon","url":strenv(SITOTHER_REPO_URL)}
  ]}}] |
  (.spec.template.spec.sources[] | select(.repoURL == "https://github.com/AtomiCloud/fleet") | .repoURL) = strenv(FLEET_REPO_URL) |
  (.spec.template.spec.sources[] | select(.repoURL == "https://github.com:443/AtomiCloud/fleet") | .repoURL) = strenv(FLEET_SERVICES_REPO_URL)
' "${source_appset}" >"${output}"

yq -o=json '.' "${output}" >"${tmp}/derived.json"
jq -e \
  --arg fleet "${fleet_url}" \
  --arg services "${fleet_services_url}" \
  --arg canary "${canary_url}" \
  --arg sitother "${sitother_url}" '
  .spec.generators == [{"list":{"elements":[
    {"repository":"canary.carbon","url":$canary},
    {"repository":"sitother.carbon","url":$sitother}
  ]}}] and
  ([.spec.template.spec.sources[] | select(.repoURL == $fleet)] | length) == 1 and
  ([.spec.template.spec.sources[] | select(.repoURL == $services)] | length) == 1 and
  .spec.template.spec.sources[2].repoURL == $services and
  .spec.template.spec.sources[2].targetRevision == "HEAD"
' "${tmp}/derived.json" >/dev/null || {
  echo 'derived ApplicationSet does not contain the exact authorized substitutions' >&2
  exit 1
}

# Reverse only the authorized edits and compare canonical JSON. This proves
# that generator replacement plus the source-A and source-C repoURL rewrites
# are the full semantic diff while allowing yq to choose the derived file's
# formatting.
jq '.spec.generators' "${tmp}/source.json" >"${tmp}/original-generators.json"
export ORIGINAL_GENERATORS_FILE="${tmp}/original-generators.json"
yq '
  .spec.generators = load(strenv(ORIGINAL_GENERATORS_FILE)) |
  (.spec.template.spec.sources[] | select(.repoURL == strenv(FLEET_REPO_URL)) | .repoURL) = "https://github.com/AtomiCloud/fleet" |
  (.spec.template.spec.sources[] | select(.repoURL == strenv(FLEET_SERVICES_REPO_URL)) | .repoURL) = "https://github.com:443/AtomiCloud/fleet"
' "${output}" >"${tmp}/reversed.yaml"
yq -o=json -I=0 '.' "${source_appset}" | jq -S . >"${tmp}/source.canonical.json"
yq -o=json -I=0 '.' "${tmp}/reversed.yaml" | jq -S . >"${tmp}/reversed.canonical.json"
if ! cmp -s "${tmp}/source.canonical.json" "${tmp}/reversed.canonical.json"; then
  diff -u "${tmp}/source.canonical.json" "${tmp}/reversed.canonical.json" >&2 || true
  echo 'reverse derivation did not reproduce the committed ApplicationSet semantics' >&2
  exit 1
fi

if [ -n "${evidence_dir}" ]; then
  mkdir -p "${evidence_dir}"
  cp "${tmp}/source.canonical.json" "${evidence_dir}/platforms-appset.original.json"
  cp "${tmp}/derived.json" "${evidence_dir}/platforms-appset.derived.json"
  cp "${tmp}/reversed.canonical.json" "${evidence_dir}/platforms-appset.reversed.json"
  jq -n \
    --slurpfile source "${tmp}/source.json" \
    --slurpfile derived "${tmp}/derived.json" \
    '{
      assertion: "reverse authorized edits equals committed source",
      generator: {from: $source[0].spec.generators, to: $derived[0].spec.generators},
      fleetRepoURLs: {
        from: [$source[0].spec.template.spec.sources[].repoURL],
        to: [$derived[0].spec.template.spec.sources[].repoURL]
      },
      servicesAlias: {
        from: ($source[0].spec.template.spec.sources[] | select(.ref == "services") | .repoURL),
        to: ($derived[0].spec.template.spec.sources[] | select(.ref == "services") | .repoURL),
        targetRevisionUnchanged: (
          ($source[0].spec.template.spec.sources[] | select(.ref == "services") | .targetRevision) ==
          ($derived[0].spec.template.spec.sources[] | select(.ref == "services") | .targetRevision)
        )
      }
    }' >"${evidence_dir}/platforms-appset.authorized-diff.json"
fi
