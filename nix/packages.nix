{
  atomi,
  pkgs,
  pkgs-2605,
  pkgs-unstable,
}:
let
  cyanprintVersion = "4.9.0";
  cyanprintSystem = pkgs.stdenv.hostPlatform.system;
  cyanprintPlatform =
    ({
      x86_64-linux = "linux_amd64";
      aarch64-linux = "linux_arm64";
      x86_64-darwin = "darwin_amd64";
      aarch64-darwin = "darwin_arm64";
    }).${cyanprintSystem};
  cyanprintHash =
    ({
      x86_64-linux = "sha256-z5whvbKPJTgyR5qWeYefN7NuTKY1pWaRkYDnyyaNG9k=";
      aarch64-linux = "sha256-SrhazRJbeK3vJHGvv0TwKHdz/ulqZM04qMtKgX0AJgA=";
      x86_64-darwin = "sha256-XIolxZN+KVf/Ui5/rQjg+k3OXLrbJuGGxh6iYkki+/k=";
      aarch64-darwin = "sha256-xugPBTO6CTixUjpq9PPq2WOQySci735gfuOXZSn75Ew=";
    }).${cyanprintSystem};
  cyanprint = pkgs.stdenvNoCC.mkDerivation {
    pname = "cyanprint";
    version = cyanprintVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/AtomiCloud/sulfone.lite/releases/download/v${cyanprintVersion}/cyanprint_${cyanprintVersion}_${cyanprintPlatform}.tar.gz";
      hash = cyanprintHash;
    };
    sourceRoot = ".";
    strictDeps = true;
    dontStrip = true;
    nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
    buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.glibc ];
    installPhase = ''
      runHook preInstall
      install -Dm755 cyanprint "$out/bin/cyanprint"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/cyanprint" --version | grep -Fx "cyanprint ${cyanprintVersion}"
    '';
    meta.mainProgram = "cyanprint";
  };
  helm-schema = pkgs.writeShellApplication {
    name = "helm-schema";
    runtimeInputs = [
      pkgs.kubernetes-helm
      pkgs.kubernetes-helmPlugins.helm-schema
    ];
    text = ''
      export HELM_PLUGINS="${pkgs.kubernetes-helmPlugins.helm-schema}"
      exec helm schema "$@"
    '';
  };
  all = rec {
    # ### nix-root
    # #### source: main
    atomipkgs = (
      with atomi;
      {
        inherit
          atomiutils
          infralint
          infrautils
          pls
          sg
          ;
      }
    );

    # ### workspace
    # #### source: workspace
    nix-2605 = (
      with pkgs-2605;
      {
        inherit
          actionlint
          bash
          docker-client
          git
          gitlint
          go-task
          infisical
          jq
          kubeconform
          kubernetes-helm
          kyverno
          pre-commit
          ripgrep
          shellcheck
          skopeo
          treefmt
          yq-go
          ;
        # Go toolchain for the Kargo YAML-engine integration test under
        # scripts/validate/kargo-yaml-update (pinned go 1.25.x).
        go = go_1_25;
      }
    );

    # ### nix-unstable
    # #### source: main
    nix-unstable = (
      with pkgs-unstable;
      {
      }
    );

    root = {
      inherit cyanprint helm-schema;
    };
  };
in
with all;
atomipkgs // nix-2605 // nix-unstable // root
