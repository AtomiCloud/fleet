#!/usr/bin/env bash
set -euo pipefail

snapshot="nix/snapshots/nixpkgs.json"
[ ! -f "${snapshot}" ] && echo "❌ '${snapshot}' is missing" >&2 && exit 1

rev="$(jq -r '.rev' "${snapshot}")"
channel="$(jq -r '.channel' "${snapshot}")"
release="$(jq -r '.release' "${snapshot}")"

[[ ${rev} =~ ^[0-9a-f]{40}$ ]] || {
  echo "❌ snapshot rev is not an exact SHA" >&2
  exit 1
}
[ "${channel}" != "nixos-26.05" ] && echo "❌ snapshot channel must be nixos-26.05" >&2 && exit 1
[ "${release}" != "Yarara" ] && echo "❌ snapshot release must be Yarara" >&2 && exit 1
rg -q "nixpkgs-2605.url = \"github:NixOS/nixpkgs/${rev}\";" flake.nix || {
  echo "❌ flake.nix does not use the authoritative nixpkgs SHA" >&2
  exit 1
}
rg -q 'atomipkgs.url = "github:AtomiCloud/nix-registry/v3";' flake.nix || {
  echo "❌ atomipkgs must use registry v3" >&2
  exit 1
}
rg -q 'nix-2605' nix/packages.nix || {
  echo "❌ nix/packages.nix is missing nix-2605" >&2
  exit 1
}
rg -q 'pkgs-2605' flake.nix || {
  echo "❌ flake.nix is missing pkgs-2605" >&2
  exit 1
}
if rg -q 'nix-2511|pkgs-2511|nixpkgs/nixos-26[.]05"' flake.nix nix/*.nix; then
  echo "❌ stale channel names or a floating nixos-26.05 input remain" >&2
  exit 1
fi

if [ -f flake.lock ]; then
  node="$(jq -r '.nodes.root.inputs["nixpkgs-2605"]' flake.lock)"
  locked="$(jq -r --arg node "${node}" '.nodes[$node].locked.rev' flake.lock)"
  [ "${locked}" != "${rev}" ] && echo "❌ flake.lock nixpkgs rev '${locked}' differs from '${rev}'" >&2 && exit 1
fi

echo "✅ nixpkgs 26.05 pin is consistent at ${rev}"
