#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r file; do
  [ -x "${file}" ] || {
    echo "❌ '${file}' is tracked but not executable" >&2
    exit 1
  }
done < <(git ls-files '*.sh')

echo "✅ Tracked shell scripts are executable"
