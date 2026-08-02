{ treefmt-nix, pkgs, ... }:
let
  fmt = {
    projectRootFile = "flake.nix";

    # ### workspace-formatters
    # #### source: workspace
    programs = {
      actionlint.enable = true;
      nixfmt.enable = true;
      prettier = {
        enable = true;
        excludes = [
          ".claude/skills/vendor/**"
          ".github/rulesets/**"
          "Changelog.md"
          "docs/developer/CommitConventions.md"
          "infra/root_chart/**"
          "chart/**"
          "registry/charts/diene-platform/**"
        ];
      };
      shfmt.enable = true;
    };
  };
in
(treefmt-nix.lib.evalModule pkgs fmt).config.build.wrapper
