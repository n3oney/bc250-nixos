# Build toolchain (Nix + qemu), consolidated + one-command removal

If your build host does not already run Nix, this sets it up so that
everything lives under **`/nix`** (Nix itself, qemu, and all build outputs)
and removal is a single command. It does not touch the host's own package
manager.

## Install

**1. Nix (privileged; needs root).** Determinate's installer: multi-user,
flakes enabled by default, and it ships a clean uninstaller.

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix | \
  sh -s -- install --no-confirm
```

`/nix` lands on the root filesystem (the kernel build wants ~15 GiB free). The
installer creates the `nix-daemon` systemd unit, the `nixbld` build users, and
shell hooks, all TRACKED by the uninstaller below.

Alternative, fully rootless: [nix-portable](https://github.com/DavHau/nix-portable)
(a static binary; store under a directory you choose via `NP_LOCATION`). This
repo builds fine under it.

**2. qemu (non-privileged; via the Nix daemon, lands under /nix).** Only
needed for the `qemu/` boot-chain harness.

```sh
nix profile install nixpkgs#qemu
```

## Verify

```sh
nix --version
nix profile list | grep qemu
qemu-system-x86_64 --version
```

## Remove (one command)

```sh
sudo /nix/nix-installer uninstall
```

This reverses everything the installer did: deletes `/nix` (Nix + qemu + every
build output) and removes the `nix-daemon` unit, the `nixbld` users, and the
shell hooks. Nothing else on the host is affected.

## Notes

- Builds are pure: the kernel source is fetched by the flake
  (nix-cachyos-kernel input), so no `--impure` is needed. Site-specific keys
  and addresses belong in a downstream consumer flake (see README).
