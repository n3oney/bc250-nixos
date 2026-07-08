#!/usr/bin/env bash
# Quick closure smoke: boot the NixOS netboot kernel+initrd DIRECTLY (no PXE),
# to watch it come up and see the boot-time services (arieltune-tune, hostname,
# llmtune-serve). Fastest iteration once `nix build` has produced the artifacts.
#
# Usage:
#   direct-boot.sh <kernel-bzImage> <netbootRamdisk> <netbootIpxeScript>
# where the three args are the result paths of:
#   nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe --impure
#
# The netbootIpxeScript is read only to lift the EXACT kernel cmdline it encodes
# (init=<toplevel>/init + our kernelParams), so a direct boot matches the netboot.
set -euo pipefail

KERNEL="${1:?path to bzImage (nix build .#netbootKernel)}"
INITRD="${2:?path to initrd (nix build .#netbootRamdisk)}"
IPXE="${3:?path to the netbootIpxeScript}"

command -v qemu-system-x86_64 >/dev/null || {
  echo "qemu-system-x86_64 not found - install qemu first" >&2
  exit 1
}

# The generated iPXE script's `kernel` line is: kernel <img> <cmdline...>.
# Everything after the image token is the cmdline we want.
CMDLINE=$(grep -m1 '^kernel ' "$IPXE" | cut -d' ' -f3-)
: "${CMDLINE:?could not read a kernel cmdline from $IPXE}"

echo ">> booting closure directly (cmdline: $CMDLINE)" >&2
qemu-system-x86_64 \
  -enable-kvm -cpu host -m "${MEM:-8192}" -smp "${SMP:-4}" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "console=ttyS0 $CMDLINE" \
  -nographic \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
