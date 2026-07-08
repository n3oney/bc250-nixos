# SPDX-License-Identifier: GPL-2.0-only
#
# GPU inference runtime: a Vulkan llama.cpp served on the BC-250 GPU
# (gfx1013) via unstable-mesa RADV, wired so llmtune drives it.
#
# The image ships the runtime (llama.cpp + the mesa RADV that recognises this
# chip); where the MODELS come from is selected by modelsSource:
#   "nfs" (default): the netboot appliance. Models live on an NFS export
#     (read-only), mounted at boot, so the whole library is available without
#     copying any into the node's 14 GB RAM.
#   "local": the standalone installed box. Models live in a plain local
#     directory on the board's own disk (/var/lib/llmtune/models); no NFS,
#     no network dependency.
# `bc250-swap <name>` restarts the server on a different model (freeing the
# previous model's GPU+RAM), writing a drop-in to /run (writable) since /etc is
# read-only on NixOS.
#
# NOTE: we serve DECLARATIVELY (a NixOS systemd unit), NOT via `llmtune setup`/
# `node load`, since those write units into /etc/systemd/system, which is
# read-only on NixOS. llmtune still SEES + drives this unit (status/endpoint/
# gpu/bench/stop-start) because it probes :8080 and the unit is named
# llama-server.service.
#
# The GPU-userspace enablement itself (mesa-26 RADV for gfx1013, vulkan-tools,
# hardware.graphics) lives in gpu-vulkan.nix, imported below; this module adds
# only the llama.cpp/llmtune serving on top.
{ config, lib, pkgs, llamaVulkan, mesaUnstable, ... }:

let
  cfg = config.bc250.llamaVulkan;
  modelsDir = "/var/lib/llmtune/models";
  modelPath = "${modelsDir}/${cfg.modelFile}";

  # The mesa RADV ICD that recognises the BC-250 (unstable mesa).
  radvIcd = "${mesaUnstable}/share/vulkan/icd.d/radeon_icd.x86_64.json";

  # The GPU Vulkan environment proven on the board:
  #  - VK_DRIVER_FILES -> the mesa-26 RADV ICD (24.11's mesa can't see the chip)
  #  - LD_LIBRARY_PATH  -> llama's libs + mesa-26 libs (RADV deps)
  #  - VK_LOADER_LAYERS_DISABLE -> drop the 24.11 device-select layer that
  #    interferes with device enumeration
  gpuEnv = {
    VK_DRIVER_FILES = radvIcd;
    LD_LIBRARY_PATH = "${llamaVulkan}/lib:${mesaUnstable}/lib";
    VK_LOADER_LAYERS_DISABLE = "*";
  };

  # BC-250-tuned gemma flags (llmtune's seed) + full GPU offload.
  gemmaFlags = "-c 32768 --parallel 1 --cache-ram 1024 --cache-reuse 256 --flash-attn on --no-mmap --jinja -ngl 99 -t 4 -ctk q4_0 -ctv q4_0 --temp 1.0 --top-p 0.95 --top-k 64";

  # llmtune profiles.toml: point the `gemma` profile at the baked binary + the
  # GPU env, so `llmtune bench`/node ops resolve the GPU llama (no on-node build).
  profilesToml = pkgs.writeText "llmtune-profiles.toml" ''
    [[profile]]
    id = "gemma"
    arch_match = ["gemma"]
    bin = "${llamaVulkan}/bin/llama-server"
    ld_path = "${llamaVulkan}/lib:${mesaUnstable}/lib"
    flags = "${gemmaFlags}"
    [profile.env]
    VK_DRIVER_FILES = "${radvIcd}"
    VK_LOADER_LAYERS_DISABLE = "*"

    [[profile]]
    id = "_default"
    arch_match = []
    bin = "${llamaVulkan}/bin/llama-server"
    ld_path = "${llamaVulkan}/lib:${mesaUnstable}/lib"
    # --no-mmap: the model library is NFS-served, so mmap would hold the weights
    # in host page cache WHILE the GPU also copies them into GTT (~2x resident on
    # a 16 GiB UMA board -> OOM at full offload). Reading straight into GTT keeps
    # one copy and lets -ngl 99 fit.
    flags = "-c 8192 --parallel 1 --flash-attn on --jinja -ngl 99 -t 4 --no-mmap"
    [profile.env]
    VK_DRIVER_FILES = "${radvIcd}"
    VK_LOADER_LAYERS_DISABLE = "*"
  '';

  # llmtune per-model flag overrides (the store llmtune's TUI/`node profile
  # set-model` edits). Baked as the seed so full-GPU tunings survive the diskless
  # reboot (/ is tmpfs). Runtime edits win until the next boot re-seeds this.
  # Seeded from the bc250.llamaVulkan.modelOverrides option (empty by default).
  overrideLines = lib.mapAttrsToList
    (model: flags: ''"${model}" = "${flags}"'')
    cfg.modelOverrides;
  overridesToml = pkgs.writeText "llmtune-overrides.toml" ''
    # llmtune per-model llama.cpp flag overrides (managed by the TUI editor).
    # Example: a ~10 GiB Q8_0 model fits full-offload on the 16 GiB UMA only
    # with --no-mmap + q8_0 KV cache:
    #   "some-model-Q8_0.gguf" = "-c 8192 --parallel 1 --flash-attn on --jinja -ngl 99 -t 4 -ctk q8_0 -ctv q8_0 --no-mmap"

    [flags]
    ${lib.concatStringsSep "\n" overrideLines}
  '';

  # Swap the served model across the NFS library. Writes a systemd drop-in to
  # /run (writable; /etc is read-only on NixOS) and restarts llama-server, which
  # frees the previous model's GPU + RAM on exit. gemma models get the tuned
  # cache-ram flags; others a generic GPU profile.
  swapHelper = pkgs.writeShellScriptBin "bc250-swap" ''
    set -eu
    q="''${1:-}"
    if [ -z "$q" ]; then
      echo "usage: bc250-swap <model-name-substring>"
      echo "available:"; ls ${modelsDir}/*.gguf 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
      exit 1
    fi
    f=$(ls ${modelsDir}/*.gguf 2>/dev/null | grep -i "$q" | head -1)
    if [ -z "$f" ]; then echo "no model matching '$q' in ${modelsDir}"; exit 1; fi
    case "$(basename "$f" | tr 'A-Z' 'a-z')" in
      *gemma*) flags="${gemmaFlags}";;
      *) flags="-c 8192 --parallel 1 --flash-attn on --jinja -ngl 99 -t 4 --no-mmap";;
    esac
    echo "swapping -> $(basename "$f")"
    mkdir -p /run/systemd/system/llama-server.service.d
    { echo "[Service]"; echo "ExecStart="; \
      echo "ExecStart=${llamaVulkan}/bin/llama-server -m $f --host 0.0.0.0 --port 8080 $flags"; \
    } > /run/systemd/system/llama-server.service.d/override.conf
    systemctl daemon-reload
    systemctl restart llama-server
    echo "restarted on $(basename "$f"); previous model's GPU+RAM freed."
  '';
in
{
  imports = [ ./gpu-vulkan.nix ];

  options.bc250.llamaVulkan = {
    modelsSource = lib.mkOption {
      type = lib.types.enum [ "nfs" "local" ];
      default = "nfs";
      description = ''
        Where the GGUF models come from. "nfs" (the netboot appliance):
        mount the modelsNfs export at ${modelsDir}. "local" (the standalone
        installed box): ${modelsDir} is a plain local directory on the
        board's disk; no NFS mount is declared.
      '';
    };
    modelsNfs = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.10:/srv/nfs/models"; # set to your NFS/boot-server export
      example = "10.0.0.10:/srv/nfs/models";
      description = "server:/export of the read-only GGUF model library the node mounts at boot (only used when modelsSource is \"nfs\").";
    };
    modelFile = lib.mkOption {
      type = lib.types.str;
      default = "gemma-4-E4B-it-Q4_K_M.gguf"; # default served model (GPU-proven)
      description = "Filename (within the NFS library) of the model served at boot.";
    };
    modelOverrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "some-model-Q8_0.gguf" = "-c 8192 --parallel 1 --flash-attn on --jinja -ngl 99 -t 4 -ctk q8_0 -ctv q8_0 --no-mmap";
      };
      description = "Per-model llama.cpp flag overrides seeded into llmtune's overrides.toml: model filename -> flag string.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = [ 8080 ];

    # mesaUnstable + vulkan-tools come from gpu-vulkan.nix. The NFS client
    # helper is only needed when the models come over NFS.
    environment.systemPackages = [ llamaVulkan swapHelper ]
      ++ lib.optional (cfg.modelsSource == "nfs") pkgs.nfs-utils;

    # llmtune's own NFS serve is superseded; turn it off.
    services.llmtune-serve.enable = lib.mkForce false;

    # NFS client support, STAGE-2 ONLY. Do NOT use boot.supportedFilesystems here:
    # it pulls NFS toward the initrd, which this netboot pins to a minimal module
    # set (squashfs/overlay/loop) and the mismatch hangs stage-1. Load nfs at
    # runtime + ship the mount.nfs helper (added to systemPackages above) instead.
    boot.kernelModules = lib.optionals (cfg.modelsSource == "nfs") [ "nfs" ];

    # Mount the whole model library from the NFS export (read-only). Automount
    # so a slow/absent server never blocks boot; llama-server RequiresMountsFor
    # it. The library lives on the boot server's disk, NOT in the node's RAM.
    fileSystems = lib.mkIf (cfg.modelsSource == "nfs") {
      ${modelsDir} = {
        device = cfg.modelsNfs;
        fsType = "nfs";
        options = [
          "ro"
          "nfsvers=4"
          "nofail"
          "_netdev"
          "x-systemd.automount"
          "x-systemd.mount-timeout=30"
          # NO x-systemd.idle-timeout: llama-server loads the model once (weights in
          # RAM/GPU, no ongoing mount access), so an idle-timeout unmounts the share
          # out from under the running server (RequiresMountsFor then stops it). The
          # model mount must stay for the life of the serve.
        ];
      };
    };

    # Local models: no mount to declare, just make sure the directory exists
    # on the installed disk. The user drops .gguf files straight into it.
    systemd.tmpfiles.rules = lib.optionals (cfg.modelsSource == "local") [
      "d ${modelsDir} 0755 root root -"
    ];

    # Install the llmtune profiles.toml (so `llmtune bench`/node ops resolve the
    # GPU binary). /root/.config isn't declarative, so a tiny oneshot writes it.
    systemd.services.bc250-llmtune-profiles = {
      description = "Install llmtune GPU profiles.toml + per-model overrides";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -Dm644 ${profilesToml} /root/.config/llmtune/profiles.toml
        install -Dm644 ${overridesToml} /root/.config/llmtune/overrides.toml
      '';
    };

    # Serve the default model on the GPU (Vulkan), declaratively. Waits for the
    # NFS model mount. `bc250-swap <name>` overrides ExecStart via a /run drop-in.
    systemd.services.llama-server = {
      description = "llama.cpp Vulkan inference server (BC-250 GPU)";
      wantedBy = [ "multi-user.target" ];
      after = [ "arieltune-tune.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = modelsDir;
      environment = gpuEnv;
      serviceConfig = {
        ExecStart = "${llamaVulkan}/bin/llama-server -m ${modelPath} --host 0.0.0.0 --port 8080 ${gemmaFlags}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
