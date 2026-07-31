{
  # ### workspace-flake
  # #### source: workspace
  inputs = {
    # util
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";

    # registry
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-2605.url = "github:NixOS/nixpkgs/4382ed2b7a6839d4280a9b386db49cbc5907414d";
    atomipkgs.url = "github:AtomiCloud/nix-registry/v3";
  };
  outputs =
    {
      self,

      # utils
      flake-utils,
      treefmt-nix,
      pre-commit-hooks,

      # registries
      atomipkgs,
      nixpkgs-2605,
      nixpkgs-unstable,

    }@inputs:
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs-2605 = nixpkgs-2605.legacyPackages.${system};
        pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
        atomi = atomipkgs.packages.${system};
        pre-commit-lib = pre-commit-hooks.lib.${system};
      in
      let
        pkgs = pkgs-2605;
      in
      with rec {
        pre-commit = import ./nix/pre-commit.nix {
          inherit
            packages
            pkgs
            pre-commit-lib
            formatter
            ;
        };
        formatter = import ./nix/fmt.nix {
          inherit treefmt-nix pkgs;
        };
        packages = import ./nix/packages.nix {
          inherit
            pkgs
            pkgs-2605
            pkgs-unstable
            atomi
            ;
        };
        env = import ./nix/env.nix {
          inherit pkgs packages;
        };
        ciInputs = [
          pkgs.bun
          pkgs.gettext
        ]
        ++ env.lint
        ++ env.main
        ++ env.system;
        devShells = import ./nix/shells.nix {
          inherit
            pkgs
            env
            packages
            ciInputs
            ;
          shellHook = checks.pre-commit-check.shellHook;
        };
        checks = {
          pre-commit-check = pre-commit;
          format = formatter;
          fleet-ci-runtime = pkgs.runCommand "fleet-ci-runtime" { nativeBuildInputs = ciInputs; } ''
            for cmd in bun envsubst go helm helm-schema jq kubeconform rg yq; do
              command -v "$cmd" >/dev/null 2>&1 || {
                echo "missing runtime command: $cmd" >&2
                exit 1
              }
            done
            touch "$out"
          '';
        };
      };
      {
        inherit
          checks
          formatter
          packages
          devShells
          ;
      }
    ));

}
