# SPDX-License-Identifier: GPL-2.0-only
#
# The BC-250 as a local desktop: a KDE Plasma 6 live + install ISO on the same
# liberated foundation as the netboot images (patched cachyos-bore 7.0.9
# kernel, mesa-26 RADV so Plasma gets GPU acceleration on gfx1013), with
# arieltune installed so the local user can tune the board (GPU governor,
# CPU OC, memory timings, BIOS) from the desktop. NO inference stack: no
# llmtune serving, no llama.cpp, no model NFS.
#
# This is an INSTALLABLE image, not a netboot one: it composes nixpkgs'
# graphical Calamares Plasma 6 installer ISO (which already enables
# services.desktopManager.plasma6, SDDM with autologin, services.xserver,
# NetworkManager, and the `nixos` live user with passwordless sudo) with our
# hardware and GPU modules. Build the ISO with:
#   nix build .#desktopIso --impure
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Live + Calamares install ISO; provides config.system.build.isoImage.
    "${modulesPath}/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"

    ../modules/bc250-hardware.nix
    ../modules/gpu-vulkan.nix
  ];

  # One local.nix serves every variant: accept (and ignore) the netboot-image
  # site options here, so a local.nix written for the netboot nodes also
  # evaluates against this host. Only bc250-hardware/gpu-vulkan options apply.
  options.bc250.llamaVulkan = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the desktop image; consumed by modules/llama-vulkan.nix on the inference node.";
  };
  options.bc250.netconsole = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the desktop image; consumed by modules/netconsole-debug.nix on the netboot nodes.";
  };
  options.bc250.sshAuthorizedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Ignored on the desktop image; consumed by modules/netboot-node.nix on the netboot nodes.";
  };
  options.services.llmtune-serve = lib.mkOption {
    type = lib.types.attrs;
    default = { };
    description = "Ignored on the desktop image; consumed by modules/llmtune-serve.nix on the inference node.";
  };

  config = {
    # The point of this image: tune the board from the desktop.
    environment.systemPackages = [ pkgs.arieltune ];

    # Sound via pipewire (the desktop counterpart of the headless images).
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # The live/installed `nixos` user (created by the installer profile with
    # wheel + networkmanager + passwordless sudo) gets a PLACEHOLDER password
    # instead of the profile's empty one. CHANGE IT after first login (passwd),
    # and set a real root password or ssh key before exposing the machine.
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
