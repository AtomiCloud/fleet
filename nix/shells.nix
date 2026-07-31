{
  pkgs,
  packages,
  env,
  ciInputs,
  shellHook,
}:
with env;
{
  # ### workspace-cd
  # #### source: workspace
  cd = pkgs.mkShell {
    buildInputs = main ++ system;
    inherit shellHook;
  };

  # ### workspace-ci
  # #### source: workspace
  ci = pkgs.mkShell {
    buildInputs = ciInputs;
    inherit shellHook;
  };

  # ### nix-root-default
  # #### source: main
  default = pkgs.mkShell {
    buildInputs = system ++ main ++ lint ++ dev;
    inherit shellHook;
  };

  # ### workspace-releaser
  # #### source: workspace
  releaser = pkgs.mkShell {
    buildInputs = lint ++ main ++ releaser ++ system;
    inherit shellHook;
  };
}
