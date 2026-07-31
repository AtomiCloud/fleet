#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
map_file="config/action-trust.json"

[ "${mode}" != "trusted" ] && [ "${mode}" != "non-trusted" ] && echo "❌ mode must be 'trusted' or 'non-trusted'" >&2 && exit 1
[ ! -f "${map_file}" ] && echo "❌ '${map_file}' is missing" >&2 && exit 1
jq -e '.schemaVersion == 1 and (.actions | type == "object") and ([.actions[] | select(. != "trusted" and . != "non-trusted")] | length == 0)' "${map_file}" >/dev/null || {
  echo "❌ '${map_file}' has an invalid schema or classification" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
rg -n --no-heading '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[^[:space:]]+' .github/workflows >"${tmp}" || true

while IFS=: read -r file line body; do
  [ -n "${body}" ] || continue
  raw="$(echo "${body#*uses:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ "${raw#./}" != "${raw}" ] && continue
  reference="$(echo "${raw%%#*}" | sed -E 's/[[:space:]]+$//')"
  reference="${reference#\"}"
  reference="${reference%\"}"
  reference="${reference#\'}"
  reference="${reference%\'}"
  action="${reference%@*}"
  ref="${reference##*@}"
  classification="$(jq -r --arg action "${action}" '.actions[$action] // empty' "${map_file}")"
  [ -z "${classification}" ] && echo "❌ ${file}:${line}: action '${action}' has no authored trust classification" >&2 && exit 1
  [ "${classification}" != "${mode}" ] && continue
  if [ "${mode}" = "trusted" ]; then
    [[ ${ref} =~ ^v[1-9][0-9]*$ ]] || {
      echo "❌ ${file}:${line}: trusted action '${action}' must use a major pin, got '${ref}'" >&2
      exit 1
    }
  else
    [[ ${ref} =~ ^[0-9a-fA-F]{40}$ ]] || {
      echo "❌ ${file}:${line}: non-trusted action '${action}' must use an exact SHA, got '${ref}'" >&2
      exit 1
    }
    comment="${raw#*#}"
    [ "${comment}" = "${raw}" ] && echo "❌ ${file}:${line}: non-trusted SHA pin needs its tag as a trailing comment" >&2 && exit 1
    [[ ${comment} =~ v[0-9]+([.][0-9x]+)* ]] || {
      echo "❌ ${file}:${line}: trailing comment must name the source tag" >&2
      exit 1
    }
  fi
done <"${tmp}"

echo "✅ ${mode} action pins conform"
