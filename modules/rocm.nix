# SPDX-License-Identifier: GPL-2.0-only
{
  config,
  lib,
  ...
}: let
  cfg = config.hardware.bc250.rocm;
in {
  options.hardware.bc250.rocm = {
    enable = lib.mkEnableOption "the experimental gfx1010-compatible ROCm package set";

    gfxOverride = lib.mkOption {
      type = lib.types.str;
      default = "10.1.0";
      description = "Value exported as HSA_OVERRIDE_GFX_VERSION for gfx1013 compatibility.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs = {
      overlays = [(import ../pkgs/rocm-overlay.nix)];
      config = {
        rocmSupport = true;
        problems.handlers.composable_kernel.broken = "warn";
      };
    };

    environment.variables.HSA_OVERRIDE_GFX_VERSION = cfg.gfxOverride;
  };
}
