# SPDX-License-Identifier: GPL-2.0-only
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.bc250.netbootNode;
in {
  options.bc250.netbootNode = {
    enable = lib.mkEnableOption "BC-250 diskless-node identity and SSH control";

    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["ssh-ed25519 AAAA... boot-server"];
      description = "SSH public keys granted root access to the diskless node.";
    };

    hostnamePrefix = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9][a-z0-9-]*";
      default = "bc250";
      description = "Prefix for the hostname generated from the primary NIC MAC address.";
    };

    rootLogin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable key-only root SSH login for fleet control.";
    };

    useDHCP = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use DHCP for the node's network configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional (cfg.rootLogin && cfg.sshAuthorizedKeys == []) ''
      bc250.netbootNode is enabled with key-only root SSH but no
      sshAuthorizedKeys; the resulting node has no remote login.
    '';

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = lib.mkForce (
          if cfg.rootLogin
          then "prohibit-password"
          else "no"
        );
        PasswordAuthentication = lib.mkIf cfg.rootLogin (lib.mkForce false);
      };
    };

    users.users.root.openssh.authorizedKeys.keys = lib.mkIf cfg.rootLogin cfg.sshAuthorizedKeys;

    networking.useDHCP = lib.mkDefault cfg.useDHCP;
    networking.hostName = lib.mkDefault cfg.hostnamePrefix;

    systemd.services.bc250-hostname = {
      description = "Name this BC-250 from its MAC";
      wantedBy = ["network-pre.target"];
      before = ["network-pre.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.nettools
        pkgs.coreutils
      ];
      script = ''
        mac=""
        for d in /sys/class/net/*; do
          n=$(basename "$d")
          case "$n" in lo|sit*|tun*|veth*|docker*|virbr*|bond*) continue ;; esac
          [ -r "$d/address" ] || continue
          m=$(tr -d ':' < "$d/address")
          if [ -n "$m" ] && [ "$m" != "000000000000" ]; then mac="$m"; break; fi
        done
        if [ -n "$mac" ]; then
          hostname ${lib.escapeShellArg cfg.hostnamePrefix}-''${mac: -6}
        else
          echo "bc250-hostname: no usable NIC MAC found; leaving hostname unchanged" >&2
        fi
      '';
    };
  };
}
