# SPDX-License-Identifier: GPL-2.0-only
#
# The BC-250 diskless netboot inference appliance: the nixpkgs netboot module
# (produces the netbootKernelLlmtune / netbootRamdiskLlmtune / netbootIpxeLlmtune
# artifacts for llmtune to serve) composed with our hardware pin, identity,
# boot-time tuning, and model serving. The no-LLM default image is
# bc250-nixos.nix.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Diskless netboot: RO squashfs store + tmpfs overlay, no disk needed.
    "${modulesPath}/installer/netboot/netboot-minimal.nix"

    ../modules/bc250-hardware.nix
    ../modules/netboot-node.nix
    ../modules/arieltune-tune.nix
    ../modules/llmtune-serve.nix
    # GPU inference runtime (RADV + Vulkan llama.cpp) + llmtune GPU autoserve.
    # Supersedes the NFS llmtune-serve above (force-disabled inside).
    ../modules/llama-vulkan.nix
    ../modules/netconsole-debug.nix
  ];

  # Site wiring: point these at YOUR boot/NFS server before deploying.
  # bc250.llamaVulkan.modelsNfs = "10.0.0.10:/srv/nfs/models"; # your GGUF library export
  # bc250.netconsole.targetIp = "10.0.0.10"; # where boot logs are shipped (UDP)
  # bc250.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... boot-server" ]; # REQUIRED for remote login

  # Optimize on boot, then serve.
  services.arieltune-tune = {
    enable = true;
    profile = "balanced";
  };
  services.llmtune-serve = {
    enable = true;
    nfs = "10.0.0.10:/srv/nfs/models"; # set to your NFS/boot-server export
  };

  environment.systemPackages = [ pkgs.llmtune pkgs.arieltune ];

  # Keep the image lean; this is a headless inference node.
  documentation.enable = lib.mkDefault false;
  # zfs-kernel doesn't support our 7.0.9 (broken); a diskless node has no ZFS.
  boot.supportedFilesystems.zfs = lib.mkForce false;
  # The pinned config builds most fs/disk drivers =y, so nixpkgs' all-hardware
  # initrd list FATALs on modules we don't ship as .ko. Pin to the store-mount
  # essentials (the embedded squashfs netboot needs no disk/net driver in the
  # initrd).
  boot.initrd.availableKernelModules = lib.mkForce [ "squashfs" "overlay" "loop" ];
  system.stateVersion = "24.11";
}
