# SPDX-License-Identifier: GPL-2.0-only
{
  description = "BC-250 NixOS images on the validated cachyos-bore 7.0.9 liberation kernel: base netboot, llmtune inference appliance, KDE Plasma desktop ISO, standalone local inference ISO";

  nixConfig = {
    extra-substituters = ["https://neoney.cachix.org"];
    extra-trusted-public-keys = [
      "neoney.cachix.org-1:bsFaTdG04tfzci0osGfosbRX8KX94Ih/2hU0HpJ+qRM="
    ];
  };

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
      config.allowUnfree = true; # standalone package/image outputs
    };

    # NOTE: plain `import`, NOT callPackage. callPackage would wrap the result in
    # its own `.override` over this file's `{lib, cachyKernel}` signature; NixOS's
    # boot/kernel.nix then calls `kernel.override (args: { features = ...; })` and
    # `features` would hit that arg-less signature and throw. Importing directly
    # keeps `bc250Kernel.override` bound to the cachy kernel's own override, which
    # threads `features`/`kernelPatches` straight into buildLinux.
    mkBc250Kernel = modulePkgs:
      import ./kernel/bc250-kernel.nix {
        inherit (modulePkgs) lib;
        cachyKernel =
          inputs.nix-cachyos-kernel.packages.${modulePkgs.stdenv.hostPlatform.system}.linux-cachyos-bore;
      };

    bc250Kernel = mkBc250Kernel pkgs;

    llmtune = pkgs.callPackage ./pkgs/llmtune.nix {
      src = inputs.llmtune;
    };
    arieltune = pkgs.callPackage ./pkgs/arieltune.nix {
      # project-ariel keeps the cargo workspace under its arieltune/ subdir.
      src = inputs.arieltune + "/arieltune";
    };

    packageOverlay = final: _prev: {
      llmtune = final.callPackage ./pkgs/llmtune.nix {
        src = inputs.llmtune;
      };
      arieltune = final.callPackage ./pkgs/arieltune.nix {
        src = inputs.arieltune + "/arieltune";
      };
    };

    rocmOverlay = import ./pkgs/rocm-overlay.nix;

    rocmPkgs = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        rocmSupport = true;
        problems.handlers.composable_kernel.broken = "warn";
      };
      overlays = [rocmOverlay];
    };

    # vllm omitted for now: it's flagged insecure, so it needs a
    # permittedInsecurePackages allow to build.
    rocmPython = rocmPkgs.python3.withPackages (ps: [
      ps.torch
      ps.transformers
      ps.accelerate
      ps.diffusers
    ]);

    llamaVulkan = inputs.llama-cpp.packages.${system}.vulkan;

    # Public wrappers close over flake inputs only to provide overridable
    # package defaults. Consumers do not need overlays or specialArgs.
    hardwareModule = {
      lib,
      pkgs,
      ...
    }: {
      imports = [./modules/bc250-hardware.nix];
      hardware.bc250.kernelPackage = lib.mkDefault (mkBc250Kernel pkgs);
    };

    arieltuneModule = {
      lib,
      pkgs,
      ...
    }: {
      imports = [./modules/arieltune-tune.nix];
      services.arieltune-tune.package = lib.mkDefault (
        pkgs.callPackage ./pkgs/arieltune.nix {
          src = inputs.arieltune + "/arieltune";
        }
      );
    };

    llamaVulkanModule = {
      lib,
      pkgs,
      ...
    }: let
      validatedPkgs = import nixpkgs {
        system = pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      };
    in {
      imports = [./modules/llama-vulkan.nix];
      hardware.bc250.vulkan.mesaPackage = lib.mkDefault validatedPkgs.mesa;
      bc250.llamaVulkan = {
        package = lib.mkDefault inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
        llmtunePackage = lib.mkDefault (
          pkgs.callPackage ./pkgs/llmtune.nix {
            src = inputs.llmtune;
          }
        );
      };
    };

    netbootProfile = {
      imports = [
        hardwareModule
        ./modules/netboot-node.nix
        ./modules/gpu-vulkan.nix
        arieltuneModule
        ./modules/netconsole-debug.nix
        ./hosts/bc250-nixos.nix
      ];
    };

    inferenceNetbootProfile = {
      imports = [
        netbootProfile
        llamaVulkanModule
        ./hosts/bc250-nixos-llmtune.nix
      ];
    };

    desktopProfile = {
      imports = [
        hardwareModule
        ./modules/gpu-vulkan.nix
        arieltuneModule
        ./hosts/bc250-nixos-desktop.nix
      ];
    };

    standaloneProfile = {
      imports = [
        hardwareModule
        ./modules/gpu-vulkan.nix
        arieltuneModule
        llamaVulkanModule
        ./hosts/bc250-nixos-standalone.nix
      ];
    };

    moduleApiConfiguration = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        hardwareModule
        ./modules/gpu-vulkan.nix
        arieltuneModule
        llamaVulkanModule
        ./modules/netboot-node.nix
        ./modules/netconsole-debug.nix
        {
          hardware.bc250 = {
            enable = true;
            vulkan.enable = true;
          };
          services.arieltune-tune.enable = true;
          bc250 = {
            llamaVulkan = {
              enable = true;
              modelsSource = "local";
            };
            netbootNode = {
              enable = true;
              rootLogin = false;
            };
            netconsole = {
              enable = true;
              targetIp = "192.0.2.1";
            };
          };
          system.stateVersion = "24.11";
        }
      ];
    };

    rocmApiConfiguration = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./modules/rocm.nix
        {
          hardware.bc250.rocm.enable = true;
          system.stateVersion = "24.11";
        }
      ];
    };

    profileOverrideConfigurations = {
      inference = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          inferenceNetbootProfile
          {
            bc250.llamaVulkan.modelsNfs = "192.0.2.10:/srv/models";
            system.stateVersion = "25.11";
          }
        ];
      };
      desktop = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          desktopProfile
          {system.stateVersion = "25.11";}
        ];
      };
      standalone = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          standaloneProfile
          {system.stateVersion = "25.11";}
        ];
      };
    };

    # The DEFAULT image: the liberated board with the arieltune tuning suite
    # but WITHOUT the LLM stack. Kernel + Vulkan GPU + arieltune + ssh node
    # identity. No llmtune/llama.cpp, no model NFS.
    bc250-nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [netbootProfile];
    };

    # The netboot inference appliance: arieltune-tuned on boot, Vulkan
    # llama.cpp serving GGUF models over NFS, driven by llmtune.
    bc250-nixos-llmtune = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [inferenceNetbootProfile];
    };

    # The local KDE Plasma desktop, as a live + Calamares install ISO, with
    # arieltune for tuning the board from the desktop. No LLM stack.
    bc250-nixos-desktop = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [desktopProfile];
    };

    # The standalone single-box inference appliance: a headless live/install
    # ISO on the same kernel + GPU stack, serving GGUF models from the
    # board's OWN disk (/var/lib/llmtune/models). No netboot, no NFS,
    # no fleet.
    bc250-nixos-standalone = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [standaloneProfile];
    };

    # Our kernel + netboot, NO llmtune/arieltune: boots our 7.0.9 in QEMU
    # without depending on the Rust packages.
    bc250-netboot-min = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        hardwareModule
        ./hosts/bc250-netboot-min.nix
      ];
    };
  in {
    nixosConfigurations = {
      inherit
        bc250-nixos
        bc250-nixos-llmtune
        bc250-nixos-desktop
        bc250-nixos-standalone
        bc250-netboot-min
        ;
    };

    # The primary public API. Input-backed package defaults are provided by the
    # wrappers, so every module can be consumed without specialArgs or overlays.
    nixosModules = {
      default = hardwareModule;
      bc250-hardware = hardwareModule;
      netboot-node = ./modules/netboot-node.nix;
      arieltune-tune = arieltuneModule;
      gpu-vulkan = ./modules/gpu-vulkan.nix;
      llama-vulkan = llamaVulkanModule;
      netconsole-debug = ./modules/netconsole-debug.nix;
      rocm = ./modules/rocm.nix;
      profile-netboot = netbootProfile;
      profile-inference-netboot = inferenceNetbootProfile;
      profile-desktop = desktopProfile;
      profile-standalone = standaloneProfile;
    };

    overlays = {
      default = packageOverlay;
      rocm = rocmOverlay;
    };

    formatter.${system} = pkgs.alejandra;

    checks.${system} = {
      module-api = pkgs.writeText "bc250-module-api-check" (
        builtins.toJSON {
          kernelVersion = moduleApiConfiguration.config.boot.kernelPackages.kernel.version;
          vulkanIcd = moduleApiConfiguration.config.environment.variables.VK_DRIVER_FILES;
          arieltuneExec =
            moduleApiConfiguration.config.systemd.services.arieltune-tune.serviceConfig.ExecStart;
          llamaExec = moduleApiConfiguration.config.systemd.services.llama-server.serviceConfig.ExecStart;
          hostname = moduleApiConfiguration.config.networking.hostName;
          netconsoleTarget = moduleApiConfiguration.config.bc250.netconsole.targetIp;
          inferenceModelsNfs = profileOverrideConfigurations.inference.config.bc250.llamaVulkan.modelsNfs;
          inferenceStateVersion = profileOverrideConfigurations.inference.config.system.stateVersion;
          desktopStateVersion = profileOverrideConfigurations.desktop.config.system.stateVersion;
          standaloneStateVersion = profileOverrideConfigurations.standalone.config.system.stateVersion;
        }
      );
      rocm-module-api = pkgs.writeText "bc250-rocm-module-api-check" rocmApiConfiguration.config.environment.variables.HSA_OVERRIDE_GFX_VERSION;
    };

    packages.${system} = {
      inherit
        bc250Kernel
        llmtune
        arieltune
        llamaVulkan
        ;

      # gfx1010 PyTorch ML env. Build with:
      #   nix build .#rocmPython
      inherit rocmPython;

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
