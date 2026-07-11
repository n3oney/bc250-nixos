# SPDX-License-Identifier: GPL-2.0-only
#
# BC-250 (Cyan Skillfish / gfx1013) hardware: the pinned kernel + the boot-time
# knobs that make it stable and fast headless. `bc250Kernel` comes from the
# flake's specialArgs (built by kernel/bc250-kernel.nix).
{
  pkgs,
  bc250Kernel,
  ...
}: {
  boot.kernelPackages = pkgs.linuxPackagesFor bc250Kernel;

  nix.settings = {
    extra-substituters = ["https://neoney.cachix.org"];
    extra-trusted-public-keys = [
      "neoney.cachix.org-1:bsFaTdG04tfzci0osGfosbRX8KX94Ih/2hU0HpJ+qRM="
    ];
  };

  # amdgpu loads in stage-2 from the store (no need in the initrd for a headless
  # serial node - keeps the initrd lean and avoids bundling GPU firmware there).

  # The BC-250's validated boot cmdline, matched to the reference board's
  # /proc/cmdline. These are the proven values, not guesses.
  boot.kernelParams = [
    # -- FULL 16 GiB unified memory for the GPU (needs BOTH of these) --
    "ttm.pages_limit=4194304" # 16 GiB GTT (4194304 * 4096 = 16 GiB)
    "amdgpu.gartsize=16384" # 16 GiB GART aperture

    # -- BC-250 amdgpu tuning (the validated set) --
    "amdgpu.bc250_cc_write_mode=3" # 40-CU unlock (liberation patch 12)
    "amdgpu.ppfeaturemask=0xffffffff"
    "amdgpu.noretry=0"
    "amdgpu.dc=0"
    "amdgpu.mtype_local=2"
    "amdgpu.sched_policy=2"
    "amdgpu.lockup_timeout=2000,2000,100,2000"
    "amdgpu.num_kcq=4"
    "amdgpu.cg_mask=0"

    # -- platform --
    "pci=realloc,assign-busses"
    "iomem=relaxed"
    "amd_iommu=off"
    "mitigations=off"

    # -- memory-pressure helper for the diskless 16 GiB node --
    "zswap.enabled=1"
    "zswap.zpool=zsmalloc"
    "zswap.compressor=zstd"

    # -- console: ttyS0 for the QEMU harness (primary, last), plus the real
    #    board's tty0 + ttyS1 so the same image works on hardware too --
    "console=tty0"
    "console=ttyS1,115200"
    "console=ttyS0"
  ];

  hardware.firmware = [pkgs.linux-firmware];
  hardware.graphics.enable = true;

  # Our inference path is llama.cpp over Vulkan/rusticl (NOT ROCm), so we do not
  # pull the rocm stack here. arieltune owns SMU/CU/mem tuning at runtime.
}
