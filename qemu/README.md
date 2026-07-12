# QEMU netboot harness

Validate the whole boot chain in software, hardware-free, so a production
board is never a blocker. The BC-250-specific bits (the patched kernel on real
silicon, gfx1013 tuning) are the *only* parts that need hardware; the NixOS
closure, the iPXE->HTTP chain, and the boot-time services all prove out here.

## Prerequisites

1. **qemu** (`qemu-system-x86_64`) + KVM (`/dev/kvm`).
2. **Built artifacts**:
   ```sh
   nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe
   # result -> ./result (symlink per output; use result/ paths)
   ```

## Two harnesses

### `direct-boot.sh` - fast closure smoke
Boots the kernel+initrd directly with `-kernel/-initrd` (no PXE). Fastest way to
see the closure come up and watch `arieltune-tune`, the hostname-from-MAC
service, and the serve units fire. Lifts the exact cmdline from the iPXE script.
```sh
./direct-boot.sh <netbootKernel> <netbootRamdisk> <netbootIpxe>
```

### `netboot-test.sh` - full iPXE->HTTP chain
QEMU's built-in iPXE NIC ROM DHCPs via SLIRP, fetches our `netboot.ipxe`
bootfile, and chains over HTTP to a local `python -m http.server` serving the
kernel+initrd. Proves the production path minus the real dnsmasq (SLIRP's DHCP
stands in for llmtune's dnsmasq proxyDHCP).
```sh
./netboot-test.sh <netbootKernel> <netbootRamdisk> <netbootIpxe>
```
No root, no bridge. Once it's green, point the chain at llmtune's netboot
server `:8090` (instead of the throwaway http server) to validate the real
serving path.

## Bring-up order (de-risks in the right sequence)

1. **Harness itself** - build a *stock* nixpkgs netboot closure (no BC-250
   kernel) and run `netboot-test.sh` on it. Proves the harness + chain work
   before our kernel is involved.
2. **Our kernel** - swap in `bc250-netboot` (the pinned 7.0.9 kernel). `nix
   build .#netbootKernel` is the first real test of `kernel/bc250-kernel.nix`.
3. **Services** - confirm `arieltune-tune` / the serve units come up (they'll
   no-op or warn in a VM with no BC-250 silicon; that's expected).
4. **Real board** - only then, PXE-boot actual hardware.

Note: a VM has no gfx1013, so GPU tuning/inference won't actually run in QEMU -
that's fine; the harness proves boot + orchestration, not silicon.
