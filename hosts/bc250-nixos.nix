# SPDX-License-Identifier: GPL-2.0-only
#
# The liberated BC-250, general purpose: the patched cachyos-bore 7.0.9 kernel
# (12-patch liberation series, 40-CU unlock, validated amdgpu/TTM tuning), a
# working Vulkan GPU (mesa-26 RADV recognises gfx1013), the arieltune tuning
# suite (GPU governor / CPU OC / memory timings / BIOS, applied balanced on
# boot), and the ssh node identity (key-only root, hostname-from-MAC) - with NO
# inference stack (no llmtune, no llama.cpp, no model NFS). For people who want
# the board usable and tuned, not an LLM node. This is the DEFAULT image; the inference
# appliance is bc250-nixos-llmtune.nix, the local KDE image is
# bc250-nixos-desktop.nix.
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    # Diskless netboot: RO squashfs store + tmpfs overlay, no disk needed.
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
  ];

  # Site wiring (normally supplied by a downstream consumer flake; see README):
  # bc250.netconsole = { enable = true; targetIp = "10.0.0.10"; };
  # bc250.netbootNode.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... boot-server" ]; # REQUIRED for remote login

  config = {
    hardware.bc250 = {
      enable = true;
      disableMitigations = true;
      zswap.enable = true;
      consoles = [
        "tty0"
        "ttyS1,115200"
        "ttyS0"
      ];
      binaryCache.enable = true;
      vulkan.enable = true;
    };
    bc250.netbootNode.enable = true;

    # arieltune: the BC-250 tuning suite, available on the board, and applied
    # balanced on boot so the node comes up already tuned.
    services.arieltune-tune = {
      enable = true;
      profile = "balanced";
    };
    # Keep the image lean; this is a headless node.
    documentation.enable = lib.mkDefault false;
    # zfs-kernel doesn't support our 7.0.9 (broken); a diskless node has no ZFS.
    boot.supportedFilesystems.zfs = lib.mkForce false;
    # The pinned config builds most fs/disk drivers =y, so nixpkgs' all-hardware
    # initrd list FATALs on modules we don't ship as .ko. Pin to the store-mount
    # essentials (the embedded squashfs netboot needs no disk/net driver in the
    # initrd).
    boot.initrd.availableKernelModules = lib.mkForce [
      "squashfs"
      "overlay"
      "loop"
    ];
    system.stateVersion = lib.mkOverride 900 "24.11";
  };
}
