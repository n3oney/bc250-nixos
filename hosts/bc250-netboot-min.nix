# SPDX-License-Identifier: GPL-2.0-only
#
# Minimal netboot node: OUR pinned BC-250 kernel + the nixpkgs netboot module,
# and NOTHING else (no llmtune/arieltune, no services). This proves the 7.0.9
# kernel netboots a NixOS userspace in QEMU, decoupled from the Rust packages
# entirely. The full node is hosts/bc250-netboot.nix.
{ config, lib, pkgs, modulesPath, bc250Kernel, ... }:

{
  imports = [ "${modulesPath}/installer/netboot/netboot-minimal.nix" ];
  boot.kernelPackages = pkgs.linuxPackagesFor bc250Kernel;
  boot.kernelParams = [ "console=ttyS0" ];
  # The installer image ships ZFS in the initrd, but zfs-kernel doesn't support
  # 7.0.9 (marked broken). A diskless BC-250 has no ZFS, so drop it.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # nixpkgs' broad `all-hardware` initrd list references modules our config
  # doesn't build as .ko (many are built-in =y, e.g. ahci/sd_mod/virtio_pci;
  # obscure ones like pata_qdi are simply off). Requesting a missing module
  # FATALs the initrd shrink, so pin the initrd to the store-mount essentials
  # our kernel actually ships as modules (verified present).
  boot.initrd.availableKernelModules = lib.mkForce [ "squashfs" "overlay" "loop" ];
  system.stateVersion = "24.11";
}
