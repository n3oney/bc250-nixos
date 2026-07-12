# SPDX-License-Identifier: GPL-2.0-only
#
# llmtune (BC-250 inference engine + netboot control plane), packaged for the
# diskless image so a booted board can serve models + be driven locally.
#
# `src` is the pinned flake input (github:cachenetics/llmtune), passed in from
# flake.nix; the Cargo.lock ships in the source tree.
{
  lib,
  rustPlatform,
  pkg-config,
  src,
  ...
}:
rustPlatform.buildRustPackage {
  pname = "llmtune";
  version = "0.1.0";

  inherit src;

  cargoLock.lockFile = src + "/Cargo.lock";

  nativeBuildInputs = [pkg-config];

  # llmtune is CLI/TUI + a small tiny_http server; no unusual native deps.
  doCheck = false; # the suite spawns ssh/systemctl; run tests in CI, not the sandbox

  meta = {
    description = "BC-250 LLM inference engine + iPXE netboot control plane";
    homepage = "https://github.com/cachenetics/llmtune";
    license = lib.licenses.gpl2Only;
    mainProgram = "llmtune";
  };
}
