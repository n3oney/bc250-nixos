# SPDX-License-Identifier: GPL-2.0-only
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.bc250.vulkan;
  radvIcd = "${cfg.mesaPackage}/share/vulkan/icd.d/radeon_icd.x86_64.json";
in {
  options.hardware.bc250.vulkan = {
    enable = lib.mkEnableOption "the RADV Vulkan userspace validated on the BC-250";

    mesaPackage = lib.mkPackageOption pkgs "mesa" {};

    tools.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install vulkaninfo and the Mesa userspace package system-wide.";
    };

    forceRadv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Set VK_DRIVER_FILES to the RADV ICD and disable Vulkan loader layers.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics.enable = true;

    environment.systemPackages = lib.optionals cfg.tools.enable [
      cfg.mesaPackage
      pkgs.vulkan-tools
    ];

    environment.variables = lib.mkIf cfg.forceRadv {
      VK_DRIVER_FILES = radvIcd;
      VK_LOADER_LAYERS_DISABLE = "*";
    };
  };
}
