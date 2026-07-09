# SPDX-License-Identifier: GPL-2.0-only
#
# The BC-250 kernel, expressed as an OVERRIDE of xddxdd/nix-cachyos-kernel's
# `linux-cachyos-bore` rather than a hand-rolled `linuxManualConfig`. That flake
# already pins the validated cachyos-bore 7.0.9 tree (mainline + bore + cachy
# sauce) and its config, so we only layer the two BC-250-specific things on top:
#
#   - patches      = our 12 liberation patches (arieltune series 01-12). They are
#                    fed to the cachy wrapper's `patches` arg, which applies them
#                    in the patched-source phase AFTER bore+cachy, exactly the
#                    tree the series was authored against. Applied in 01..12 order.
#   - postPatch    = drops our EXACT board config over the cachy defconfig the
#                    wrapper installs to arch/x86/configs/cachyos_defconfig, so the
#                    build's `make cachyos_defconfig` starts from ours. (The wrapper
#                    still layers its NixOS-required structuredExtraConfig (overlayfs,
#                    NR_CPUS, LOCALVERSION) on top, which is what we want on NixOS.)
#
# NOTE: 7.0.11+ regresses the BC-250 SDMA path; the pinned 7.0.9 tree lives in the
# nix-cachyos-kernel input rev, not here.
#
# PROVENANCE (verified 2026-07-09 against the validated 7.0.9-1 board build):
#   - source tarball: the wrapper's version.json pins cachyos-7.0.9-1.tar.gz
#     with sha256 e1469e8e271e720bf524ae6ad2d26cd91dd9f0ad091131d301edc69d6149a621
#     (sha256-4Uaejicecgv1JK5q0tJs2R3Z8K0JETHTAe3GnWFJpiE=), byte-identical to
#     the tarball the validated board kernel was built from;
#   - bore patch: the pinned cachyos-kernel-patches rev (65cbbfc1) ships
#     7.0/sched/0001-bore-cachy.patch with sha256
#     f594e3a0cf55649377e09bc22e6dd5152ecafe6a96460a68036a35bba5ba932e,
#     byte-identical to the one the validated PKGBUILD build fetched and applied.
# So the wrapper reproduces the validated tree exactly before our 12 patches.
{
  lib,
  cachyKernel,
}:
# HARD VERSION GATE: the BC-250 is only validated on cachyos 7.0.9; 7.0.11+
# regresses the board's SDMA path. nix-cachyos-kernel builds its bore variant
# from the "latest" entry of its version.json, so bumping the input rev can
# silently move this kernel off 7.0.9. Fail evaluation loud instead.
# (`cachyKernel` is a buildLinux derivation; `.version` is the wrapper's
# version.json "latest" version, "7.0.9" at the pinned rev.)
assert lib.assertMsg (lib.hasPrefix "7.0.9" cachyKernel.version)
("bc250-nixos: nix-cachyos-kernel provides linux-cachyos-bore ${cachyKernel.version}, "
  + "but the BC-250 is only validated on 7.0.9 (7.0.11+ regresses the SDMA path). "
  + "Pin the nix-cachyos-kernel input to a rev whose version.json 'latest' is 7.0.9, "
  + "or re-validate the board on the new kernel before relaxing this assert."); let
  # The liberation series, sorted 01..12 so they apply in the authored order.
  patchFiles =
    lib.filterAttrs
    (name: type: type == "regular" && lib.hasSuffix ".patch" name)
    (builtins.readDir ./patches);

  patches =
    lib.sort (a: b: a < b)
    (lib.mapAttrsToList (name: _type: ./patches + "/${name}") patchFiles);
in
  # CONFIG FIDELITY (static analysis vs kernel/bc250-running.config; the proof
  # is scripts/verify-kernel-config.sh, run it on every kernel-affecting change):
  # the wrapper's structuredExtraConfig (largely mkForce'd) MATCHES the
  # validated board config on every load-bearing setting: NR_CPUS=8192,
  # SCHED_BORE=y, HZ=1000, NO_HZ_FULL=y (tickrate full), PREEMPT=y +
  # PREEMPT_DYNAMIC=y (preempt full), TRANSPARENT_HUGEPAGE_ALWAYS=y
  # (hugepage=always; the validated 16 GiB UMA board ran THP=always through
  # all tuning/bench work - GTT pages come from ttm pages_limit, not THP, so
  # the two do not fight), CACHY=y, MQ_IOSCHED_ADIOS=y, O3, HID=y,
  # OVERLAY_FS=m. It DIVERGES in three accepted places:
  #   1. LOCALVERSION "" -> "-cachyos": uname becomes 7.0.9-cachyos. Cosmetic,
  #      but re-check anything that matches on uname, once, on first boot.
  #   2. processorOpt: the validated config was compiled ON the board with
  #      X86_NATIVE_CPU=y; the wrapper default builds generic x86_64-v1 so the
  #      kernel is reproducible off-board. Possible small perf delta; the
  #      wrapper's -x86_64-v3 bore variant is a validated-later option (the
  #      BC-250's Zen2 cores are v3-capable).
  #   3. OVERLAY_FS_* suboptions pinned to NixOS defaults (etc-overlay needs
  #      them); feature-behavior only.
  cachyKernel.override {
    inherit patches;
    # Runs after the wrapper installs the cachy config; overwrite it with ours.
    postPatch = ''
      cp ${./bc250-running.config} arch/x86/configs/cachyos_defconfig
    '';

    # DECISION: autoModules = false, chosen EMPIRICALLY. Built the resolved
    # .config both ways (nix-portable on cache, 2026-07-09) and diffed each
    # against the validated board config with scripts/verify-kernel-config.sh:
    #   - autoModules = true  -> 1302 deltas, 6 GPU-critical (autoModules
    #     answering =m/=y to DRM display + HSA helpers the board never uses);
    #   - autoModules = false ->  134 deltas, 1 GPU-critical (HSA_AMD_P2P,
    #     inert on a single-GPU board; allowlisted in the verify script).
    # false is ~90% more faithful to the validated kernel with NO regression:
    # the remaining -> n deltas are all NixOS-vs-CachyOS build conventions
    # (module signing off, no zstd module compression), gcc-15-vs-16 compiler
    # probe symbols, or the documented overlayfs/x86-native set. amdgpu/SDMA/
    # scheduler/THP/NR_CPUS are untouched. The wrapper author's autoModules =
    # false boot break was on his desktop CachyOS initrd; our images use the
    # NixOS stage-1 initrd, which selects modules via availableKernelModules,
    # and our defconfig is complete for the board's own hardware, so
    # autoModules only ever dropped drivers for hardware the BC-250 lacks.
    # VERIFY ON FIRST BOOT: the board boot-test (docs/BUILD_AND_VALIDATE.md
    # section 4) is the final gate; if a netboot initrd ever misses a module,
    # flip this back to true and allowlist the 6 additive display/HSA deltas.
    autoModules = false;

    # nix-cachyos-kernel builds against its own (older) pinned nixpkgs, so its
    # kernel lacks two passthru attrs that our newer system nixpkgs' NixOS modules
    # read unconditionally (hardware/device-tree.nix -> `kernel.buildDTBs`, the
    # netboot/ISO image builders -> `kernel.target`). Supply them via extraPassthru
    # so they survive NixOS's own `kernel.override` re-invocation. BC-250 is x86_64:
    # no device tree, and the kernel image target is bzImage.
    extraPassthru = {
      buildDTBs = false;
      target = "bzImage";
    };
  }
