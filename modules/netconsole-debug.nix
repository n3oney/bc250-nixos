# SPDX-License-Identifier: GPL-2.0-only
#
# Remote boot-log capture for the headless diskless node (no serial console).
# netconsole ships the kernel ring buffer to a log collector over UDP; journald
# ForwardToKMsg=yes routes ALL systemd/userspace logs into that ring buffer, so
# the collector sees the full boot (kernel + services) live. Started as early
# as the network allows, before the app services that might hang.
#
# Capture on the collector with e.g.:
#   socat -u udp-recvfrom:6666,fork -
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.bc250.netconsole;
in {
  options.bc250.netconsole = {
    enable = lib.mkEnableOption "remote BC-250 kernel and journal logging with netconsole";
    targetIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.10";
      description = "IPv4 address the kernel+journal boot log is shipped to (UDP).";
    };
    targetMac = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "aa:bb:cc:dd:ee:ff";
      description = "MAC of the collector (or its gateway). null = broadcast, which works on a flat LAN.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 6666;
      description = "UDP port used for both local and remote netconsole ends.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.targetIp != null;
        message = "bc250.netconsole.targetIp must be set when netconsole is enabled";
      }
    ];

    # Route userspace journal into the kernel ring buffer so netconsole ships it too.
    services.journald.extraConfig = "ForwardToKMsg=yes";

    systemd.services.netconsole-debug = {
      description = "Ship kernel+journal to the log collector via netconsole";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Come up before the parts that might hang, so their logs are captured.
      before = ["llama-server.service"];
      path = [
        pkgs.kmod
        pkgs.iproute2
        pkgs.util-linux
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -u
        modprobe configfs 2>/dev/null || true
        mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true
        modprobe netconsole 2>/dev/null || true
        dev=$(ip -o -4 route show default | awk '{print $5}' | head -1)
        lip=$(ip -o -4 addr show dev "$dev" | awk '{print $4}' | cut -d/ -f1 | head -1)
        cfg=/sys/kernel/config/netconsole
        [ -d "$cfg" ] || { echo "netconsole configfs missing"; exit 0; }
        t="$cfg/bootlog"
        mkdir -p "$t" 2>/dev/null || true
        # order matters: identity fields before enabled=1
        echo "$dev"            > "$t/dev_name"     2>/dev/null || true
        echo "$lip"            > "$t/local_ip"     2>/dev/null || true
        echo ${toString cfg.port} > "$t/local_port"   2>/dev/null || true
        echo ${lib.escapeShellArg cfg.targetIp} > "$t/remote_ip" 2>/dev/null || true
        echo ${toString cfg.port} > "$t/remote_port"  2>/dev/null || true
        ${lib.optionalString (cfg.targetMac != null) ''
          echo ${cfg.targetMac}  > "$t/remote_mac"   2>/dev/null || true
        ''}
        echo 1                 > "$t/enabled"      2>/dev/null || true
        echo "netconsole -> ${cfg.targetIp}:${toString cfg.port} via $dev ($lip)"
      '';
    };
  };
}
