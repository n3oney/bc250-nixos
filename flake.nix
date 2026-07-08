# SPDX-License-Identifier: GPL-2.0-only
{
  description = "BC-250 NixOS images on the validated cachyos-bore 7.0.9 liberation kernel: base netboot, llmtune inference appliance, KDE Plasma desktop ISO, standalone local inference ISO";

  # Pin nixpkgs. The KERNEL is our own pinned cachyos-bore 7.0.9 (below), NOT
  # nixpkgs' kernel: 7.0.11+ regresses the BC-250 SDMA path, so we never track
  # a stock/latest kernel here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  # Unstable ONLY for llama.cpp: 24.11's is too old for newer model archs
  # (e.g. gemma4/Gemma-3n) and we want the Vulkan backend prebuilt from the
  # binary cache. The system + kernel stay pinned to 24.11.
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Newer Rust than 24.11's cargo 1.82: llmtune/arieltune deps (indexmap 2.14)
  # need edition2024 (Rust >= 1.85). Only the Rust packages use it; the system +
  # kernel stay on 24.11.
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

  # The two Rust projects this image ships, taken straight from their public
  # repos (plain cargo trees, not flakes).
  inputs.llmtune = { url = "github:cachenetics/llmtune"; flake = false; };
  inputs.arieltune = { url = "github:cachenetics/project-ariel"; flake = false; };

  outputs = inputs @ { self, nixpkgs, nixpkgs-unstable, rust-overlay, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # linux-firmware
      };

      # The validated kernel source: the exact `linux-cachyos-bore 7.0.9-1`
      # tree the reference board runs (mainline 7.0.9 + bore + cachy sauce,
      # pre-liberation). Our 12 BC-250 patches are applied on top via
      # kernelPatches in bc250-kernel.nix.
      #
      # kernel/src is NOT tracked (~850 MB): place (or symlink) the prepared
      # 7.0.9 source tree there before building (see README). A git flake's
      # store copy excludes untracked files, so the path is resolved impurely
      # from the invocation directory (run builds from the repo root) or from
      # $BC250_KERNEL_SRC; either way builds need `--impure`.
      kernelSrcPath =
        let
          env = builtins.getEnv "BC250_KERNEL_SRC";
          pwd = builtins.getEnv "PWD";
        in
        if env != "" then env
        else if pwd != "" then pwd + "/kernel/src"
        else throw "bc250-nixos: put the kernel tree at kernel/src (or set BC250_KERNEL_SRC) and build with --impure from the repo root";
      kernelSrc = builtins.path {
        name = "cachyos-bore-7.0.9-src";
        path = /. + kernelSrcPath;
      };

      bc250Kernel = pkgs.callPackage ./kernel/bc250-kernel.nix { inherit kernelSrc; };

      # Optional site-local config: a local.nix beside this flake sets the
      # bc250.* site options (NFS export, netconsole target, ssh keys, model
      # overrides) without touching tracked files. It is gitignored, and a git
      # flake's store copy EXCLUDES ignored files, so like kernel/src it is
      # also resolved impurely from the invocation directory. Absent -> the
      # tracked placeholder defaults apply.
      localModules =
        let pwd = builtins.getEnv "PWD";
        in
        if builtins.pathExists ./local.nix then [ ./local.nix ]
        else if pwd != "" && builtins.pathExists (pwd + "/local.nix") then [ (pwd + "/local.nix") ]
        else [ ];

      # A newer Rust toolchain (>= 1.85) for our crates, on the same 24.11 stdenv.
      rustPkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      rustBin = rustPkgs.rust-bin.stable.latest.default;
      rustPlatform = rustPkgs.makeRustPlatform {
        cargo = rustBin;
        rustc = rustBin;
      };
      llmtune = pkgs.callPackage ./pkgs/llmtune.nix {
        inherit rustPlatform;
        src = inputs.llmtune;
      };
      arieltune = pkgs.callPackage ./pkgs/arieltune.nix {
        inherit rustPlatform;
        # project-ariel keeps the cargo workspace under its arieltune/ subdir.
        src = inputs.arieltune + "/arieltune";
      };

      overlay = _final: _prev: { inherit llmtune arieltune; };

      # llama.cpp with the Vulkan backend (GGML_VULKAN=ON), from unstable so it
      # supports newer model archs (gemma4/Gemma-3n). Prebuilt in the binary
      # cache, so no on-node compile. gfx1013 (Cyan Skillfish) runs the Vulkan
      # backend via mesa RADV (wired by hardware.graphics in the module).
      unstablePkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      llamaVulkan = unstablePkgs.llama-cpp.override { vulkanSupport = true; };
      # 24.11's mesa 24.2.8 RADV does NOT recognize the BC-250 chip revision
      # (family_id 143) -> "no usable GPU". Unstable mesa (26.x) enumerates it as
      # "AMD BC-250 (RADV GFX1013)". Used ONLY as the Vulkan driver for llama
      # (via VK_DRIVER_FILES in the serve unit), not as the system GL stack, to
      # avoid ABI mismatch with the 24.11 base.
      mesaUnstable = unstablePkgs.mesa;

      # The DEFAULT image: the liberated board with the arieltune tuning suite
      # but WITHOUT the LLM stack. Kernel + Vulkan GPU + arieltune + ssh node
      # identity. No llmtune/llama.cpp, no model NFS.
      bc250-nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bc250Kernel mesaUnstable; };
        modules = [
          { nixpkgs.overlays = [ overlay ]; nixpkgs.config.allowUnfree = true; }
          ./hosts/bc250-nixos.nix
        ] ++ localModules;
      };

      # The netboot inference appliance: arieltune-tuned on boot, Vulkan
      # llama.cpp serving GGUF models over NFS, driven by llmtune.
      bc250-nixos-llmtune = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bc250Kernel llamaVulkan mesaUnstable; };
        modules = [
          { nixpkgs.overlays = [ overlay ]; nixpkgs.config.allowUnfree = true; }
          ./hosts/bc250-nixos-llmtune.nix
        ] ++ localModules;
      };

      # The local KDE Plasma desktop, as a live + Calamares install ISO, with
      # arieltune for tuning the board from the desktop. No LLM stack.
      bc250-nixos-desktop = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bc250Kernel mesaUnstable; };
        modules = [
          { nixpkgs.overlays = [ overlay ]; nixpkgs.config.allowUnfree = true; }
          ./hosts/bc250-nixos-desktop.nix
        ] ++ localModules;
      };

      # The standalone single-box inference appliance: a headless live/install
      # ISO on the same kernel + GPU stack, serving GGUF models from the
      # board's OWN disk (/var/lib/llmtune/models). No netboot, no NFS,
      # no fleet.
      bc250-nixos-standalone = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bc250Kernel llamaVulkan mesaUnstable; };
        modules = [
          { nixpkgs.overlays = [ overlay ]; nixpkgs.config.allowUnfree = true; }
          ./hosts/bc250-nixos-standalone.nix
        ] ++ localModules;
      };

      # Our kernel + netboot, NO llmtune/arieltune: boots our 7.0.9 in QEMU
      # without depending on the Rust packages.
      bc250-netboot-min = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bc250Kernel; };
        modules = [ ./hosts/bc250-netboot-min.nix ];
      };
    in
    {
      nixosConfigurations = {
        inherit bc250-nixos bc250-nixos-llmtune bc250-nixos-desktop bc250-nixos-standalone bc250-netboot-min;
      };

      packages.${system} = {
        inherit bc250Kernel llmtune arieltune llamaVulkan;

        # The DEFAULT netboot triple (base image, no LLM stack). Build with:
        #   nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe --impure
        netbootKernel = bc250-nixos.config.system.build.kernel;
        netbootRamdisk = bc250-nixos.config.system.build.netbootRamdisk;
        netbootIpxe = bc250-nixos.config.system.build.netbootIpxeScript;

        # The inference-appliance triple. Build with:
        #   nix build .#netbootKernelLlmtune .#netbootRamdiskLlmtune .#netbootIpxeLlmtune --impure
        netbootKernelLlmtune = bc250-nixos-llmtune.config.system.build.kernel;
        netbootRamdiskLlmtune = bc250-nixos-llmtune.config.system.build.netbootRamdisk;
        netbootIpxeLlmtune = bc250-nixos-llmtune.config.system.build.netbootIpxeScript;

        # The KDE desktop live/install ISO. Build with:
        #   nix build .#desktopIso --impure
        desktopIso = bc250-nixos-desktop.config.system.build.isoImage;

        # The standalone (headless, local-disk models) live/install ISO. Build with:
        #   nix build .#standaloneIso --impure
        standaloneIso = bc250-nixos-standalone.config.system.build.isoImage;

        # Minimal (kernel-only, no Rust pkgs): the first "our kernel netboots" test.
        netbootKernelMin = bc250-netboot-min.config.system.build.kernel;
        netbootRamdiskMin = bc250-netboot-min.config.system.build.netbootRamdisk;
        netbootIpxeMin = bc250-netboot-min.config.system.build.netbootIpxeScript;
      };
    };
}
