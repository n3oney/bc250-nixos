# SPDX-License-Identifier: GPL-2.0-only
{
  description = "BC-250 NixOS images on the validated cachyos-bore 7.0.9 liberation kernel: base netboot, llmtune inference appliance, KDE Plasma desktop ISO, standalone local inference ISO";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The two Rust projects this image ships, taken straight from their public
    # repos (plain cargo trees, not flakes).
    llmtune = {
      url = "github:cachenetics/llmtune";
      flake = false;
    };
    arieltune = {
      url = "github:cachenetics/project-ariel";
      flake = false;
    };

    # llama.cpp's flake takes a `nixpkgs` input (confirmed in our flake.lock:
    # node llama-cpp -> nixpkgs). Follow ours so the serve unit's
    # LD_LIBRARY_PATH (llama libs + mesa libs, see modules/llama-vulkan.nix)
    # is built from ONE nixpkgs; without the follows, llama.cpp's own locked
    # nixpkgs drifts from ours and the runtime mixes two nixpkgs' mesa/glibc.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DELIBERATELY NOT following our nixpkgs here: the wrapper's own pinned
    # nixos-unstable-small nixpkgs is the toolchain xddxdd tested these kernel
    # builds against, and it is entangled with the extraPassthru workaround in
    # kernel/bc250-kernel.nix (its older kernel infra lacks buildDTBs/target).
    # Do not "helpfully" add inputs.nixpkgs.follows = "nixpkgs" to this input.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/86d7051a5694db99f4db6165bcaf15e7bba8672a";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true; # linux-firmware
    };

    # NOTE: plain `import`, NOT callPackage. callPackage would wrap the result in
    # its own `.override` over this file's `{lib, cachyKernel}` signature; NixOS's
    # boot/kernel.nix then calls `kernel.override (args: { features = ...; })` and
    # `features` would hit that arg-less signature and throw. Importing directly
    # keeps `bc250Kernel.override` bound to the cachy kernel's own override, which
    # threads `features`/`kernelPatches` straight into buildLinux.
    bc250Kernel = import ./kernel/bc250-kernel.nix {
      inherit (pkgs) lib;
      cachyKernel = inputs.nix-cachyos-kernel.packages.${system}.linux-cachyos-bore;
    };

    llmtune = pkgs.callPackage ./pkgs/llmtune.nix {
      src = inputs.llmtune;
    };
    arieltune = pkgs.callPackage ./pkgs/arieltune.nix {
      # project-ariel keeps the cargo workspace under its arieltune/ subdir.
      src = inputs.arieltune + "/arieltune";
    };

    overlay = _final: _prev: {inherit llmtune arieltune;};

    llamaVulkan = inputs.llama-cpp.packages.${system}.vulkan;

    # OPTIONAL site-local config: a gitignored local.nix beside this flake sets
    # the bc250.* site options (ssh keys, NFS export, netconsole target, model
    # overrides) without putting keys/addresses in tracked files. A git flake's
    # store copy EXCLUDES ignored files, so the file is resolved impurely from
    # the invocation directory: the lookup only finds it under `--impure` (in
    # pure eval getEnv/pathExists come back empty and this is []), so the
    # common no-site-config path stays pure. For a PURE build WITH site config,
    # use the consumer-flake pattern instead: extendModules over these
    # nixosConfigurations from a private downstream flake (README, "Site
    # configuration").
    localModules = let
      pwd = builtins.getEnv "PWD";
    in
      if builtins.pathExists ./local.nix
      then [./local.nix]
      else if pwd != "" && builtins.pathExists (pwd + "/local.nix")
      then [(pwd + "/local.nix")]
      else [];

    # The DEFAULT image: the liberated board with the arieltune tuning suite
    # but WITHOUT the LLM stack. Kernel + Vulkan GPU + arieltune + ssh node
    # identity. No llmtune/llama.cpp, no model NFS.
    bc250-nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit bc250Kernel;};
      modules = [
        {
          nixpkgs.overlays = [overlay];
          nixpkgs.config.allowUnfree = true;
        }
        ./hosts/bc250-nixos.nix
      ]
      ++ localModules;
    };

    # The netboot inference appliance: arieltune-tuned on boot, Vulkan
    # llama.cpp serving GGUF models over NFS, driven by llmtune.
    bc250-nixos-llmtune = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit bc250Kernel llamaVulkan;};
      modules = [
        {
          nixpkgs.overlays = [overlay];
          nixpkgs.config.allowUnfree = true;
        }
        ./hosts/bc250-nixos-llmtune.nix
      ]
      ++ localModules;
    };

    # The local KDE Plasma desktop, as a live + Calamares install ISO, with
    # arieltune for tuning the board from the desktop. No LLM stack.
    bc250-nixos-desktop = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit bc250Kernel;};
      modules = [
        {
          nixpkgs.overlays = [overlay];
          nixpkgs.config.allowUnfree = true;
        }
        ./hosts/bc250-nixos-desktop.nix
      ]
      ++ localModules;
    };

    # The standalone single-box inference appliance: a headless live/install
    # ISO on the same kernel + GPU stack, serving GGUF models from the
    # board's OWN disk (/var/lib/llmtune/models). No netboot, no NFS,
    # no fleet.
    bc250-nixos-standalone = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit bc250Kernel llamaVulkan;};
      modules = [
        {
          nixpkgs.overlays = [overlay];
          nixpkgs.config.allowUnfree = true;
        }
        ./hosts/bc250-nixos-standalone.nix
      ]
      ++ localModules;
    };

    # Our kernel + netboot, NO llmtune/arieltune: boots our 7.0.9 in QEMU
    # without depending on the Rust packages.
    bc250-netboot-min = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit bc250Kernel;};
      modules = [./hosts/bc250-netboot-min.nix];
    };
  in {
    nixosConfigurations = {
      inherit bc250-nixos bc250-nixos-llmtune bc250-nixos-desktop bc250-nixos-standalone bc250-netboot-min;
    };

    # The building blocks, for downstream flakes that want to assemble their
    # own system instead of extending one of the nixosConfigurations above.
    # NOTE: bc250-hardware expects `bc250Kernel` and llama-vulkan/llmtune-serve
    # expect `llamaVulkan` via specialArgs; the RECOMMENDED way to add private
    # site config (ssh keys, NFS export, netconsole target) is
    # `nixosConfigurations.<name>.extendModules { modules = [ ... ]; }` from a
    # private consumer flake, which inherits all of that wiring. See README,
    # "Site configuration".
    #
    # Assembling a system from these parts (instead of extendModules over a
    # nixosConfiguration) means YOU must set `nixpkgs.config.allowUnfree =
    # true`: bc250-hardware pulls in linux-firmware (unfree). The
    # nixosConfigurations above and their extendModules already set it.
    # llmtune-serve is intentionally NOT exported: it is the legacy NFS-serve
    # path, superseded by llama-vulkan.nix (which mkForce-disables it), so
    # wiring it into a fresh system would be a footgun.
    nixosModules = {
      bc250-hardware = ./modules/bc250-hardware.nix;
      netboot-node = ./modules/netboot-node.nix;
      arieltune-tune = ./modules/arieltune-tune.nix;
      gpu-vulkan = ./modules/gpu-vulkan.nix;
      llama-vulkan = ./modules/llama-vulkan.nix;
      netconsole-debug = ./modules/netconsole-debug.nix;
    };

    packages.${system} = {
      inherit bc250Kernel llmtune arieltune llamaVulkan;

      # The DEFAULT netboot triple (base image, no LLM stack). Build with:
      #   nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe
      netbootKernel = bc250-nixos.config.system.build.kernel;
      netbootRamdisk = bc250-nixos.config.system.build.netbootRamdisk;
      netbootIpxe = bc250-nixos.config.system.build.netbootIpxeScript;

      # The inference-appliance triple. Build with:
      #   nix build .#netbootKernelLlmtune .#netbootRamdiskLlmtune .#netbootIpxeLlmtune
      netbootKernelLlmtune = bc250-nixos-llmtune.config.system.build.kernel;
      netbootRamdiskLlmtune = bc250-nixos-llmtune.config.system.build.netbootRamdisk;
      netbootIpxeLlmtune = bc250-nixos-llmtune.config.system.build.netbootIpxeScript;

      # The KDE desktop live/install ISO. Build with:
      #   nix build .#desktopIso
      desktopIso = bc250-nixos-desktop.config.system.build.isoImage;

      # The standalone (headless, local-disk models) live/install ISO. Build with:
      #   nix build .#standaloneIso
      standaloneIso = bc250-nixos-standalone.config.system.build.isoImage;

      # Minimal (kernel-only, no Rust pkgs): the first "our kernel netboots" test.
      netbootKernelMin = bc250-netboot-min.config.system.build.kernel;
      netbootRamdiskMin = bc250-netboot-min.config.system.build.netbootRamdisk;
      netbootIpxeMin = bc250-netboot-min.config.system.build.netbootIpxeScript;

      kernel = bc250Kernel;
    };
  };
}
