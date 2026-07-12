# SPDX-License-Identifier: GPL-2.0-only
#
# The BC-250 diskless netboot inference appliance: the nixpkgs netboot module
# (produces the netbootKernelLlmtune / netbootRamdiskLlmtune / netbootIpxeLlmtune
# artifacts for llmtune to serve) composed with our hardware pin, identity,
# boot-time tuning, and model serving. The no-LLM default image is
# bc250-nixos.nix.
{lib, ...}: {
  # Site wiring: point these at YOUR boot/NFS server before deploying.
  # bc250.llamaVulkan.modelsNfs = "10.0.0.10:/srv/nfs/models"; # your GGUF library export
  # bc250.netconsole = { enable = true; targetIp = "10.0.0.10"; };
  # bc250.netbootNode.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... boot-server" ]; # REQUIRED for remote login

  # Optimize on boot, then serve.
  services.arieltune-tune = {
    enable = true;
    profile = "balanced";
  };
  bc250.llamaVulkan = {
    enable = true;
    modelsSource = "nfs";
    modelsNfs = lib.mkDefault "10.0.0.10:/srv/nfs/models";
  };

  # Keep the image lean; this is a headless inference node.
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
}
