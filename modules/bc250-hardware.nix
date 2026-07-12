# SPDX-License-Identifier: GPL-2.0-only
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.bc250;

  validatedGpuParams = [
    "ttm.pages_limit=${toString (cfg.gttSizeMiB * 256)}"
    "amdgpu.gartsize=${toString cfg.gttSizeMiB}"
    "amdgpu.bc250_cc_write_mode=${toString cfg.computeUnitWriteMode}"
    "amdgpu.ppfeaturemask=0xffffffff"
    "amdgpu.noretry=0"
    "amdgpu.dc=0"
    "amdgpu.mtype_local=2"
    "amdgpu.sched_policy=2"
    "amdgpu.lockup_timeout=2000,2000,100,2000"
    "amdgpu.num_kcq=4"
    "amdgpu.cg_mask=0"
    "pci=realloc,assign-busses"
    "iomem=relaxed"
  ];

  zswapParams = [
    "zswap.enabled=1"
    "zswap.zpool=zsmalloc"
    "zswap.compressor=zstd"
  ];
in {
  options.hardware.bc250 = {
    enable = lib.mkEnableOption "AMD BC-250 (Cyan Skillfish) hardware support";

    kernelPackage = lib.mkOption {
      type = lib.types.package;
      description = ''
        Patched BC-250 Linux kernel. The flake-exported module supplies the
        validated kernel by default; this option makes the dependency explicit
        and overridable by downstream configurations.
      '';
    };

    gttSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384;
      description = "GTT and GART size in MiB reserved for the unified GPU memory.";
    };

    computeUnitWriteMode = lib.mkOption {
      type = lib.types.ints.between 0 3;
      default = 3;
      description = "Value passed to amdgpu.bc250_cc_write_mode by the liberation patch.";
    };

    disableIommu = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable the AMD IOMMU, matching the validated BC-250 configuration.";
    };

    disableMitigations = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable CPU vulnerability mitigations. This trades security for performance.";
    };

    zswap.enable = lib.mkEnableOption "the validated zswap setup for memory-constrained diskless nodes";

    consoles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tty0"
        "ttyS1,115200"
      ];
      example = [
        "tty0"
        "ttyS1,115200"
        "ttyS0"
      ];
      description = "Kernel consoles to enable, in command-line order.";
    };

    extraKernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional BC-250-specific kernel command-line parameters.";
    };

    binaryCache.enable = lib.mkEnableOption "the neoney Cachix binary cache in the installed system";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isx86_64;
        message = "hardware.bc250 only supports x86_64-linux";
      }
    ];

    boot.kernelPackages = pkgs.linuxPackagesFor cfg.kernelPackage;
    boot.kernelParams =
      validatedGpuParams
      ++ lib.optional cfg.disableIommu "amd_iommu=off"
      ++ lib.optional cfg.disableMitigations "mitigations=off"
      ++ lib.optionals cfg.zswap.enable zswapParams
      ++ map (console: "console=${console}") cfg.consoles
      ++ cfg.extraKernelParams;

    # Use NixOS's standard firmware mechanism instead of directly referencing
    # linux-firmware and forcing the consumer's global allowUnfree policy.
    # netboot-minimal disables this at priority 70 to keep generic images
    # small. The board requires amdgpu firmware, so override that profile while
    # still using NixOS's standard redistributable-firmware mechanism.
    hardware.enableRedistributableFirmware = lib.mkOverride 60 true;

    nix.settings = lib.mkIf cfg.binaryCache.enable {
      extra-substituters = ["https://neoney.cachix.org"];
      extra-trusted-public-keys = [
        "neoney.cachix.org-1:bsFaTdG04tfzci0osGfosbRX8KX94Ih/2hU0HpJ+qRM="
      ];
    };
  };
}
