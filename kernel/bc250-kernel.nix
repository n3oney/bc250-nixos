# SPDX-License-Identifier: GPL-2.0-only
#
# A faithful Nix copy of the validated `linux-cachyos-bore 7.0.9-1` kernel:
#   - src        = the cachyos-prepared 7.0.9 tree (mainline + bore + cachy sauce)
#   - kernelPatches = our 12 BC-250 liberation patches (arieltune series 01-12),
#                     applied in order on top of the base tree
#   - configfile = the EXACT running .config pulled from the reference board
#                  (/proc/config.gz),
#                  verified byte-identical to the tree's own .config
#
# NOT a stock kernel: 7.0.11+ regresses the BC-250 SDMA path, so this tree is
# pinned. This reproduces what the reference board runs; it does not
# reconstruct it.
# `features`/`...` are threaded because NixOS `.override`s a consumed kernel with
# a `features` set; a fixed signature would break `boot.kernelPackages`.
{ lib, linuxManualConfig, kernelSrc, features ? { }, ... }:

let
  # The liberation series, sorted 01..12 so they apply in the authored order.
  patchFiles = lib.filterAttrs
    (name: type: type == "regular" && lib.hasSuffix ".patch" name)
    (builtins.readDir ./patches);

  kernelPatches = lib.sort (a: b: a.name < b.name)
    (lib.mapAttrsToList
      (name: _type: {
        inherit name;
        patch = ./patches + "/${name}";
      })
      patchFiles);
in
linuxManualConfig {
  inherit features;
  version = "7.0.9";
  # Must equal what the kernel itself reports (`make kernelrelease`) so modules
  # resolve under /lib/modules/<this>. In a plain Nix build (no git, LOCALVERSION
  # empty) that is "7.0.9"; the "-1-cachyos-bore" suffix on the reference board
  # is injected by
  # CachyOS's makepkg (pkgrel + localversion), not by the kernel source, so it
  # does NOT apply here. Same source/patches/config; only the uname string.
  # (If arieltune ever needs "cachyos-bore" in uname, add CONFIG_LOCALVERSION.)
  modDirVersion = "7.0.9";

  src = kernelSrc;
  configfile = ./bc250-running.config;

  # The config was generated on a real build; let Nix consume it directly.
  allowImportFromDerivation = true;

  inherit kernelPatches;

  extraMeta = {
    branch = "7.0";
    description = "BC-250 cachyos-bore 7.0.9 + liberation patches (SDMA-validated pin)";
  };
}
