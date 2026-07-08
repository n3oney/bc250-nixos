# SPDX-License-Identifier: GPL-2.0-only
#
# BC-250 GPU userspace: make the gfx1013 (Cyan Skillfish) GPU usable via
# Vulkan. 24.11's mesa 24.2.8 RADV does NOT recognise this chip revision
# (family_id 143) -> "no usable GPU"; unstable mesa (26.x) enumerates it as
# "AMD BC-250 (RADV GFX1013)". The mesa-26 RADV is used ONLY as the Vulkan
# driver (selected via VK_DRIVER_FILES), not as the system GL stack, to avoid
# ABI mismatch with the 24.11 base.
#
# This module is inference-agnostic: it knows nothing about llama.cpp or
# llmtune. The full node layers modules/llama-vulkan.nix on top of it.
{ config, lib, pkgs, mesaUnstable, ... }:

let
  # The mesa RADV ICD that recognises the BC-250 (unstable mesa).
  radvIcd = "${mesaUnstable}/share/vulkan/icd.d/radeon_icd.x86_64.json";
in
{
  # Base GL/Vulkan stack (24.11): vulkan-loader + the udev/device wiring. The
  # mesa-26 RADV is forced over it via VK_DRIVER_FILES below.
  hardware.graphics.enable = true;

  environment.systemPackages = [ mesaUnstable pkgs.vulkan-tools ];

  # The Vulkan environment proven on the board:
  #  - VK_DRIVER_FILES -> the mesa-26 RADV ICD (24.11's mesa can't see the chip)
  #  - VK_LOADER_LAYERS_DISABLE -> drop the 24.11 device-select layer that
  #    interferes with device enumeration
  # The ICD json points at absolute store paths, so no LD_LIBRARY_PATH is
  # needed here; services with their own library needs (e.g. llama-server)
  # set their unit environment explicitly.
  environment.variables = {
    VK_DRIVER_FILES = radvIcd;
    VK_LOADER_LAYERS_DISABLE = "*";
  };
}
