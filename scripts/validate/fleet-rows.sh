#!/usr/bin/env bash
set -euo pipefail

root="${1:-platforms}"

[ ! -d "${root}" ] && echo "❌ row root '${root}' does not exist" >&2 && exit 1

while IFS= read -r roster; do
  platform_dir="$(basename "$(dirname "${roster}")")"
  roster_platform="$(yq -r '.platform // ""' "${roster}")"
  [ -z "${roster_platform}" ] && echo "❌ ${roster}: explicit platform is required" >&2 && exit 1
  [ "${roster_platform}" != "${platform_dir}" ] &&
    echo "❌ ${roster}: platform '${roster_platform}' must equal containing platform/release namespace '${platform_dir}'" >&2 &&
    exit 1

  roster_unknown="$(yq -o=json '.' "${roster}" | jq -r 'keys - ["platform", "services"] | join(",")')"
  [ -n "${roster_unknown}" ] && echo "❌ ${roster}: unknown keys ${roster_unknown}" >&2 && exit 1

  yq -e '.services | type == "!!seq" and length > 0' "${roster}" >/dev/null ||
    {
      echo "❌ ${roster}: services must be a non-empty array" >&2
      exit 1
    }

  service_count="$(yq -o=json '.services' "${roster}" | jq 'length')"
  unique_service_count="$(yq -o=json '.services' "${roster}" | jq '[.[].name] | unique | length')"
  [ "${service_count}" != "${unique_service_count}" ] &&
    echo "❌ ${roster}: service names must be unique" >&2 && exit 1

  while IFS= read -r service_entry; do
    entry_unknown="$(jq -r 'keys - ["name", "repo"] | join(",")' <<<"${service_entry}")"
    [ -n "${entry_unknown}" ] && echo "❌ ${roster}: service entry has unknown keys ${entry_unknown}" >&2 && exit 1
    jq -e '.name | type == "string" and length > 0' <<<"${service_entry}" >/dev/null ||
      {
        echo "❌ ${roster}: service entry name is required" >&2
        exit 1
      }
    jq -e '.repo | type == "string" and length > 0' <<<"${service_entry}" >/dev/null ||
      {
        echo "❌ ${roster}: service entry repo is required" >&2
        exit 1
      }
  done < <(yq -o=json '.services[]' "${roster}" | jq -c '.')

  rows_dir="$(dirname "${roster}")/landscapes"
  [ ! -d "${rows_dir}" ] && echo "❌ ${roster}: landscapes row directory is missing" >&2 && exit 1

  while IFS= read -r row; do
    path_landscape="$(basename "$(dirname "${row}")")"
    filename_service="$(basename "${row}" .yaml)"
    row_platform="$(yq -r '.platform // ""' "${row}")"
    row_service="$(yq -r '.service // ""' "${row}")"
    row_landscape="$(yq -r '.landscape // ""' "${row}")"

    [ "${row_platform}" != "${roster_platform}" ] &&
      echo "❌ ${row}: platform '${row_platform}' must equal roster/release namespace '${roster_platform}'" >&2 && exit 1
    [ "${row_service}" != "${filename_service}" ] &&
      echo "❌ ${row}: service '${row_service}' must equal filename '${filename_service}'" >&2 && exit 1
    [ "${row_landscape}" != "${path_landscape}" ] &&
      echo "❌ ${row}: landscape '${row_landscape}' must equal path '${path_landscape}'" >&2 && exit 1
    [ "${row_landscape}" = "lapras" ] &&
      echo "❌ ${row}: lapras rows are Garden-owned and forbidden in fleet-core" >&2 && exit 1

    yq -o=json '.services' "${roster}" | jq -e --arg service "${row_service}" 'any(.[]; .name == $service)' >/dev/null ||
      {
        echo "❌ ${row}: service '${row_service}' is absent from ${roster}" >&2
        exit 1
      }

    row_unknown="$(yq -o=json '.' "${row}" | jq -r 'keys - ["platform", "service", "landscape", "pin", "valuesMeta", "values"] | join(",")')"
    [ -n "${row_unknown}" ] && echo "❌ ${row}: unknown keys ${row_unknown}" >&2 && exit 1
    yq -o=json '.pin' "${row}" | jq -e 'type == "object" and (keys == ["tag"]) and (.tag | type == "string" and length > 0)' >/dev/null ||
      {
        echo "❌ ${row}: pin must be the closed shape {tag: <non-empty string>}" >&2
        exit 1
      }

    has_values="$(yq -o=json '.' "${row}" | jq 'has("values")')"
    has_meta="$(yq -o=json '.' "${row}" | jq 'has("valuesMeta")')"
    [ "${has_values}" != "${has_meta}" ] &&
      echo "❌ ${row}: values and valuesMeta must be present together" >&2 && exit 1
    if [ "${has_values}" = "true" ]; then
      yq -o=json '.values' "${row}" | jq -e 'type == "object"' >/dev/null ||
        {
          echo "❌ ${row}: values must be an object" >&2
          exit 1
        }
      yq -o=json '.valuesMeta' "${row}" | jq -e 'type == "object" and (keys == ["addedAt", "reason"]) and (.addedAt | type == "string" and length > 0) and (.reason | type == "string" and length > 0)' >/dev/null ||
        {
          echo "❌ ${row}: valuesMeta must be the closed shape {addedAt, reason}" >&2
          exit 1
        }
    fi
  done < <(find "${rows_dir}" -mindepth 2 -maxdepth 2 -type f -name '*.yaml' | sort)
done < <(find "${root}" -mindepth 2 -maxdepth 2 -type f -name services.yaml | sort)

echo "✅ fleet row identities and closed row shapes validated"
