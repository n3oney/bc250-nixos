# SPDX-License-Identifier: GPL-2.0-only
#
# The BC-250 as a standalone single-box inference appliance: install it to the
# board's own disk, drop .gguf models in /var/lib/llmtune/models, and it
# serves them on the GPU at port 8080. Same liberated foundation as the other
# images (patched cachyos-bore 7.0.9 kernel, mesa-26 RADV so Vulkan sees
# gfx1013, arieltune profile applied on boot), but fully self-contained:
# NO netboot, NO NFS, NO fleet or boot server. For someone who just wants to
# run inference on one BC-250 locally.
#
# This is an INSTALLABLE image like the desktop, but headless: it composes
# nixpkgs' minimal (text-mode) installer ISO with our hardware, GPU, tuning,
# and serving modules. Flash the ISO to USB, boot the board, install to disk
# with the standard nixos-install flow (or run it live), then put your models
# in /var/lib/llmtune/models. The live/installed `nixos` user has the
# placeholder password `bc250`; CHANGE IT after first login. Build with:
#   nix build .#standaloneIso --impure
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Live + install ISO (text mode); provides config.system.build.isoImage.
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"

    ../modules/bc250-hardware.nix
    ../modules/gpu-vulkan.nix
    ../modules/arieltune-tune.nix
    # Declares services.llmtune-serve (left disabled; llama-vulkan.nix
    # force-disables it and owns the serving unit).
    ../modules/llmtune-serve.nix
    # GPU inference runtime (RADV + Vulkan llama.cpp), pointed at the LOCAL
    # models directory below instead of an NFS export.
    ../modules/llama-vulkan.nix
  ];

  # One local.nix serves every variant: accept (and ignore) the netboot-image
  # site options here, so a local.nix written for the netboot nodes also
  # evaluates against this host.
  options.bc250.netconsole = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the standalone image; consumed by modules/netconsole-debug.nix on the netboot nodes.";
  };
  options.bc250.sshAuthorizedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Ignored on the standalone image; consumed by modules/netboot-node.nix on the netboot nodes.";
  };

  config = {
    # Models come from the board's own disk, not NFS. The directory is
    # created automatically; drop .gguf files into it and use bc250-swap (or
    # llmtune) to pick what is served.
    bc250.llamaVulkan.modelsSource = "local";

    # Optimize on boot, then serve.
    services.arieltune-tune = {
      enable = true;
      profile = "balanced";
    };

    # The board's driving tools, usable straight from the console or ssh.
    environment.systemPackages = [ pkgs.llmtune pkgs.arieltune ];

    # Normal login path for a headless box: ssh with the standard installer
    # `nixos` user. The user gets a PLACEHOLDER password instead of the
    # installer profile's empty one; CHANGE IT after first login (passwd),
    # and set a real root password or ssh key before exposing the machine.
    services.openssh.enable = true;
    users.users.nixos = {
      initialHashedPassword = lib.mkForce null;
      initialPassword = "bc250"; # placeholder; change after first login
    };

    # zfs-kernel doesn't support our 7.0.9 (broken); drop it from the
    # installer's supported filesystems.
    boot.supportedFilesystems.zfs = lib.mkForce false;

    # The pinned config builds most fs/disk drivers =y, so nixpkgs'
    # all-hardware initrd list FATALs on modules we don't ship as .ko. Pin to
    # what the live ISO actually needs to find and mount its boot medium
    # (USB/SATA/NVMe device, vfat/iso9660 medium, squashfs store + overlay);
    # everything else on this kernel is built in.
    boot.initrd.availableKernelModules = lib.mkForce [
      "squashfs"
      "overlay"
      "loop"
      "iso9660"
      "vfat"
      "nls_cp437"
      "nls_iso8859-1"
      "usb_storage"
      "uas"
      "sd_mod"
      "sr_mod"
      "ahci"
      "nvme"
    ];

    system.stateVersion = "24.11";
  };
}
