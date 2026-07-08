# SPDX-License-Identifier: GPL-2.0-only
#
# arieltune (BC-250 tuning suite: APU/MEM/BIOS/WIKI), packaged so the image can
# apply a tuning profile on boot and be driven for CU/GPU/CPU/mem control.
#
# `src` is the pinned flake input (github:cachenetics/project-ariel), passed in
# from flake.nix; the Cargo.lock ships in the source tree. arieltune actuates
# SMN/SMU via /sys and debugfs, so it is mostly syscalls at runtime.
{ lib, rustPlatform, pkg-config, src, ... }:

rustPlatform.buildRustPackage {
  pname = "arieltune";
  version = "0.1.0";

  inherit src;

  cargoLock.lockFile = src + "/Cargo.lock";

  # The workspace builds several crates; we only want the top-level binary.
  cargoBuildFlags = [ "--bin" "arieltune" ];

  nativeBuildInputs = [ pkg-config ];

  doCheck = false;

  meta = {
    description = "BC-250 tuning suite (APU liberation, CU routing, GPU/CPU/mem, BIOS)";
    homepage = "https://github.com/cachenetics/project-ariel";
    license = lib.licenses.gpl2Only;
    mainProgram = "arieltune";
  };
}
