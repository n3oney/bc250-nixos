# SPDX-License-Identifier: GPL-2.0-only
#
# The diskless node's identity + control surface: key-only root ssh (so llmtune
# drives it the moment it boots) and a hostname-from-MAC first-boot so every
# identical netboot image gets a stable, discoverable name (llmtune registers
# ssh fleet nodes by it).
{ config, lib, pkgs, ... }:

{
  options.bc250.sshAuthorizedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "ssh-ed25519 AAAA... boot-server" ];
    description = ''
      SSH public keys granted root on every booted node. Set this to your boot
      server's control key; with the default (empty) the node has NO remote
      login (password auth is disabled below).
    '';
  };

  config = {
    services.openssh = {
      enable = true;
      # The installer netboot profile sets these for interactive install; override
      # to key-only for a production fleet node.
      settings = {
        PermitRootLogin = lib.mkForce "prohibit-password";
        PasswordAuthentication = lib.mkForce false;
      };
    };

    # The boot server's control key(s). Booted boards are ssh-driven with them.
    users.users.root.openssh.authorizedKeys.keys = config.bc250.sshAuthorizedKeys;

    networking.useDHCP = lib.mkDefault true;
    # Fallback name; the service below overrides it per-MAC. All boards share the
    # "bc250" prefix, which llmtune's discovery matches (hostname_prefix).
    networking.hostName = lib.mkDefault "bc250";

    # Name the board <prefix>-<last-3-mac-octets> from its primary NIC, early
    # enough that the DHCP lease carries the unique name.
    systemd.services.bc250-hostname = {
      description = "Name this BC-250 from its MAC";
      wantedBy = [ "network-pre.target" ];
      before = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.nettools pkgs.coreutils ];
      script = ''
        # Read the primary NIC's MAC straight from sysfs, which is available even
        # before the link is up (this runs pre-network), unlike `ip link show up`.
        mac=""
        for d in /sys/class/net/*; do
          n=$(basename "$d")
          case "$n" in lo|sit*|tun*|veth*|docker*|virbr*|bond*) continue ;; esac
          [ -r "$d/address" ] || continue
          m=$(tr -d ':' < "$d/address")
          if [ -n "$m" ] && [ "$m" != "000000000000" ]; then mac="$m"; break; fi
        done
        if [ -n "$mac" ]; then
          hostname "bc250-''${mac: -6}"
        else
          echo "bc250-hostname: no usable NIC MAC found; leaving hostname unchanged" >&2
        fi
      '';
    };
  };
}
