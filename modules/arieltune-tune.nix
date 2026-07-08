# SPDX-License-Identifier: GPL-2.0-only
#
# Apply an arieltune tuning profile on boot, the "already optimized on arrival"
# step. Declarative: the profile bundles CU routing / GPU governor / CPU OC /
# memory timings; arieltune actuates the SMU at runtime.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.arieltune-tune;
in
{
  options.services.arieltune-tune = {
    enable = lib.mkEnableOption "apply an arieltune tuning profile on boot";
    profile = lib.mkOption {
      type = lib.types.enum [ "eco" "balanced" "performance" ];
      default = "balanced";
      description = "The arieltune profile applied at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.arieltune-tune = {
      description = "Apply the ${cfg.profile} arieltune profile";
      wantedBy = [ "multi-user.target" ];
      # NOT `after multi-user.target` - that with `wantedBy` is an ordering cycle
      # (multi-user wants us, so we can't come after it). Order after basic
      # system + udev so the GPU is enumerated; llmtune-serve orders after us.
      after = [ "sysinit.target" "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # TODO: confirm the exact apply subcommand/flags on the arieltune build
        # (profile apply is dry-run unless --write).
        ExecStart = "${pkgs.arieltune}/bin/arieltune apu profile apply ${cfg.profile} --write";
      };
    };
  };
}
