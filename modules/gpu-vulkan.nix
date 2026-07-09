# SPDX-License-Identifier: GPL-2.0-only
#
# BC-250 GPU userspace: make the gfx1013 (Cyan Skillfish) GPU usable via
# Vulkan. Older mesa (24.2.8 RADV) does NOT recognise this chip revision
# (family_id 143) -> "no usable GPU"; the unstable-nixpkgs mesa (26.x) this
# image is built on enumerates it as "AMD BC-250 (RADV GFX1013)".
#
# This module is inference-agnostic: it knows nothing about llama.cpp or
# llmtune. The full node layers modules/llama-vulkan.nix on top of it.
{ config, lib, pkgs, ... }:

let
  # The mesa RADV ICD that recognises the BC-250.
  radvIcd = "${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.x86_64.json";
in
{
  # Base GL/Vulkan stack: vulkan-loader + the udev/device wiring. RADV is
  # selected explicitly over it via VK_DRIVER_FILES below.
  hardware.graphics.enable = true;

  environment.systemPackages = [ pkgs.mesa pkgs.vulkan-tools ];

  # The Vulkan environment proven on the board:
  #  - VK_DRIVER_FILES -> the RADV ICD
  #  - VK_LOADER_LAYERS_DISABLE -> drop the device-select layer that
  #    interferes with device enumeration
  # The ICD json points at absolute store paths, so no LD_LIBRARY_PATH is
  # needed here; services with their own library needs (e.g. llama-server)
  # set their unit environment explicitly.
  environment.variables = {
    VK_DRIVER_FILES = radvIcd;
    VK_LOADER_LAYERS_DISABLE = "*";
  };
}
