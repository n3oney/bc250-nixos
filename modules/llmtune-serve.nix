# Serve a model with llmtune on boot, from an NFS models share (immutable OS
# closure + mutable model data cleanly split: OS over HTTP-squashfs netboot,
# models over NFS). llmtune owns llama-server + swap; this just starts it.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.llmtune-serve;
in
{
  options.services.llmtune-serve = {
    enable = lib.mkEnableOption "serve a model via llmtune on boot";
    modelsMount = lib.mkOption {
      type = lib.types.str;
      default = "/models";
      description = "Where the models share is mounted (llmtune's models dir).";
    };
    nfs = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.10:/srv/nfs/models";
      description = "server:/export of the read-only models NFS share (null = mount it yourself).";
    };
  };

  config = lib.mkIf cfg.enable {
    fileSystems = lib.mkIf (cfg.nfs != null) {
      ${cfg.modelsMount} = {
        device = cfg.nfs;
        fsType = "nfs";
        # Automount: mount on first access, so a slow/absent NFS never hangs
        # boot or the serve unit; ro, and never a boot-blocker.
        options = [
          "ro"
          "nofail"
          "_netdev"
          "x-systemd.automount"
          "x-systemd.idle-timeout=600"
          "x-systemd.mount-timeout=30"
        ];
      };
    };

    systemd.services.llmtune-serve = {
      description = "llmtune model server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "arieltune-tune.service" ];
      environment.LLMTUNE_MODELS_DIR = cfg.modelsMount;
      serviceConfig = {
        # TODO: confirm the boot serve entrypoint (llmtune manages the
        # llama-server unit; a `serve`/`node server start` shim may be needed).
        ExecStart = "${pkgs.llmtune}/bin/llmtune node server start";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };
  };
}
