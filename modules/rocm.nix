# SPDX-License-Identifier: GPL-2.0-only
#
# Opt-in gfx1010 ROCm stack. Not in the default images; pull in downstream when
# you want PyTorch/vLLM on the board.
{...}: {
  nixpkgs.overlays = [(import ../pkgs/rocm-overlay.nix)];

  # composable_kernel doesn't build for gfx1010; keep a stray reference from
  # aborting eval.
  nixpkgs.config.problems.handlers = {
    composable_kernel.broken = "warn";
  };
}
