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
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Diskless netboot: RO squashfs store + tmpfs overlay, no disk needed.
    "${modulesPath}/installer/netboot/netboot-minimal.nix"

    ../modules/bc250-hardware.nix
    ../modules/netboot-node.nix
    ../modules/gpu-vulkan.nix
    ../modules/arieltune-tune.nix
    ../modules/netconsole-debug.nix
  ];

  # Site wiring (usually via a gitignored local.nix beside the flake; see README):
  # bc250.netconsole.targetIp = "10.0.0.10"; # where boot logs are shipped (UDP)
  # bc250.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... boot-server" ]; # REQUIRED for remote login

  # One local.nix serves both images: accept (and ignore) the full-image site
  # options here, so a local.nix written for the inference node also evaluates
  # against this host.
  options.bc250.llamaVulkan = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the base image; consumed by modules/llama-vulkan.nix on the full node.";
  };
  options.services.llmtune-serve = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the base image; consumed by modules/llmtune-serve.nix on the full node.";
  };

  config = {
    # arieltune: the BC-250 tuning suite, available on the board, and applied
    # balanced on boot so the node comes up already tuned.
    services.arieltune-tune = {
      enable = true;
      profile = "balanced";
    };
    environment.systemPackages = [ pkgs.arieltune ];

    # Keep the image lean; this is a headless node.
    documentation.enable = lib.mkDefault false;
    # zfs-kernel doesn't support our 7.0.9 (broken); a diskless node has no ZFS.
    boot.supportedFilesystems.zfs = lib.mkForce false;
    # The pinned config builds most fs/disk drivers =y, so nixpkgs' all-hardware
    # initrd list FATALs on modules we don't ship as .ko. Pin to the store-mount
    # essentials (the embedded squashfs netboot needs no disk/net driver in the
    # initrd).
    boot.initrd.availableKernelModules = lib.mkForce [ "squashfs" "overlay" "loop" ];
    system.stateVersion = "24.11";
  };
}
