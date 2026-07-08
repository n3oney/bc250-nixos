#!/usr/bin/env bash
# Full netboot chain in a VM, no root and no bridge. QEMU's built-in iPXE NIC
# ROM DHCPs via SLIRP, fetches our iPXE script as the bootfile, and chains over
# HTTP to a local server that serves the NixOS kernel + initrd. This proves the
# production path:  iPXE -> HTTP -> kernel/initrd -> the closure boots.
#
# SLIRP's DHCP stands in for dnsmasq here (dnsmasq proxyDHCP is validated
# separately in llmtune's netboot P1). This harness deliberately serves the
# artifacts with a plain HTTP server so "does the closure netboot" is decoupled
# from "does llmtune serve" - point it at llmtune's :8090 once that serves the
# Nix artifacts.
#
# Usage:
#   netboot-test.sh <kernel-bzImage> <netbootRamdisk> <netbootIpxeScript>
#     nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe --impure
set -euo pipefail

KERNEL="${1:?path to bzImage}"
INITRD="${2:?path to initrd}"
IPXE="${3:?path to the netbootIpxeScript}"

command -v qemu-system-x86_64 >/dev/null || { echo "install qemu first" >&2; exit 1; }

HOSTIP="10.0.2.2"          # the host as seen from inside QEMU SLIRP
PORT="${PORT:-8000}"

STAGE="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

cp -L "$KERNEL" "$STAGE/vmlinuz"
cp -L "$INITRD" "$STAGE/initrd"

# Rewrite the generated iPXE script's artifact refs to our HTTP server, keeping
# the exact kernel cmdline (init=, params) intact.
sed -e "s|^kernel [^ ]*|kernel http://$HOSTIP:$PORT/vmlinuz|" \
    -e "s|^initrd .*|initrd http://$HOSTIP:$PORT/initrd|" \
    "$IPXE" > "$STAGE/boot.ipxe"

# The tiny NBP the NIC's iPXE ROM fetches over SLIRP-TFTP: DHCP, then HTTP-chain
# to the real boot script above.
cat > "$STAGE/netboot.ipxe" <<EOF
#!ipxe
dhcp
chain http://$HOSTIP:$PORT/boot.ipxe
EOF

echo ">> serving artifacts on :$PORT (staging $STAGE)" >&2
( cd "$STAGE" && exec python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
HTTP_PID=$!

echo ">> launching VM (iPXE ROM -> SLIRP-TFTP netboot.ipxe -> HTTP chain)" >&2
qemu-system-x86_64 \
  -enable-kvm -cpu host -m "${MEM:-12288}" -smp "${SMP:-4}" \
  -nographic \
  -netdev "user,id=n0,tftp=$STAGE,bootfile=netboot.ipxe,hostfwd=tcp::${SSHFWD:-2222}-:22" \
  -device e1000,netdev=n0
