#!/usr/bin/env bash
set -euo pipefail

# Generate the diene-platform compiler chart's values.schema.json from its
# deliberate closed source schema. helm-schema still inventories values.yaml;
# generation refuses any top-level key drift between the defaults and the
# deliberate schema, so adding a value without specifying its real shape fails.

chart="registry/charts/diene-platform"
output="${1:-${chart}/values.schema.json}"
output_abs="$(realpath -m "${output}")"
source_schema="${chart}/values.schema.source.json"
inventory="$(mktemp)"
trap 'rm -f "${inventory}"' EXIT

(cd "${chart}" && helm-schema \
  --use-helm-docs \
  --values values.yaml \
  --output "${inventory}")

inventory_keys="$(jq -c '.properties | keys | sort' "${inventory}")"
schema_keys="$(jq -c '.properties | keys | sort' "${source_schema}")"
[ "${inventory_keys}" != "${schema_keys}" ] &&
  echo "❌ values.yaml top-level keys differ from values.schema.source.json" >&2 &&
  echo "   values: ${inventory_keys}" >&2 &&
  echo "   schema: ${schema_keys}" >&2 &&
  exit 1

jq --indent 4 --sort-keys . "${source_schema}" >"${output_abs}"

echo "✅ diene-platform values schema generated at ${output}"
