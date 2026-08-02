#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

find .github/workflows -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | while IFS= read -r -d '' file; do
  yq -o=json "${file}" | jq -r --arg file "${file}" '(.jobs // {}) | to_entries[] | select(.value["runs-on"] != null) | [$file, .key, (if (.value["runs-on"] | type) == "array" then (.value["runs-on"] | join(",")) else .value["runs-on"] end)] | @tsv'
done >"${tmp}"

while IFS=$'\t' read -r file job runners; do
  [[ ${runners} == *nscloud-*with-cache* ]] || continue
  runner="$(echo "${runners}" | tr ',' '\n' | rg '^nscloud-.*with-cache$' | head -n 1)"
  tags="$(echo "${runners}" | tr ',' '\n' | rg '^nscloud-cache-tag-' || true)"
  count="$(echo "${tags}" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "${count}" -ne 1 ] && echo "❌ ${file} job '${job}' must have exactly one nscloud cache tag" >&2 && exit 1
  os=""
  arch=""
  [[ ${runner} == *ubuntu* ]] && os="linux"
  [[ ${runner} == *macos* ]] && os="darwin"
  [[ ${runner} == *amd64* ]] && arch="amd64"
  [[ ${runner} == *arm64* ]] && arch="arm64"
  [ -z "${os}" ] && echo "❌ ${file} job '${job}' has an unknown runner OS in '${runner}'" >&2 && exit 1
  [ -z "${arch}" ] && echo "❌ ${file} job '${job}' has an unknown runner architecture in '${runner}'" >&2 && exit 1
  expected="nscloud-cache-tag-atomi-nix-store-cache-${os}-${arch}"
  [ "${tags}" != "${expected}" ] && echo "❌ ${file} job '${job}' cache tag must be '${expected}', got '${tags}'" >&2 && exit 1
done <"${tmp}"

echo "✅ nscloud cache tags conform"
