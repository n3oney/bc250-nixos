# bc250-nixos

NixOS images for the AMD BC-250, the cheap 16 GiB APU board (gfx1013,
"Cyan Skillfish") that shows up on the surplus market. Out of the box the
board is awkward: stock kernels drive it badly and stock mesa cannot see
the GPU. This repo fixes that. It builds ready-to-boot images with a
patched kernel, a working Vulkan GPU stack, and the
[arieltune](https://github.com/cachenetics/project-ariel) tuning tools, so
you can turn the board into a small Linux server, an LLM box, or a desktop
computer.

Everything is GPL-2.0-only (matching the kernel and patches). See `LICENSE`.

## Which image should I pick?

There are four variants. All of them share the same base: the
cachyos-bore 7.0.9 kernel with the 12 BC-250 liberation patches, the
mesa-26 RADV Vulkan GPU stack, and arieltune.

| I want... | Image | How it runs |
|---|---|---|
| A headless Linux box for my own workloads | `bc250-nixos` (the default) | Diskless netboot |
| A box that serves LLMs on the GPU, as part of a fleet | `bc250-nixos-llmtune` | Diskless netboot |
| To run LLMs on one board, no network setup | `bc250-nixos-standalone` | ISO installed to the board's disk |
| A normal desktop computer | `bc250-nixos-desktop` | ISO installed to the board's disk |

In more detail:

- **`bc250-nixos`** (the default): the liberated board with a working
  Vulkan GPU (`vulkaninfo` sees the chip out of the box), arieltune for
  tuning, and key-only ssh with hostname-from-MAC. No LLM stack. A clean
  general-purpose node.

- **`bc250-nixos-llmtune`**: everything above plus
  [llmtune](https://github.com/cachenetics/llmtune) and llama.cpp. On boot
  it names itself `bc250-<mac>`, applies an arieltune tuning profile,
  mounts your NFS model library, and starts a GPU-accelerated
  `llama-server` on port 8080. Includes `bc250-swap <name>` to change the
  served model at runtime. The inference appliance.

- **`bc250-nixos-standalone`**: run LLMs on one board, installed to disk,
  no network setup. A headless live/install ISO: install it to the board's
  disk, drop your `.gguf` model files in `/var/lib/llmtune/models`, and it
  serves them on the GPU at port 8080. Same tuning and `bc250-swap` as the
  llmtune image, but fully self-contained: no boot server, no NFS, no
  fleet. The `nixos` user has the placeholder password `bc250`; change it
  after first login.

- **`bc250-nixos-desktop`**: an installable KDE Plasma 6 live/install ISO
  (Calamares installer), with arieltune so you can tune the board (GPU
  governor, CPU overclock, memory timings, BIOS) from the desktop. No LLM
  stack. The live `nixos` user has the placeholder password `bc250`;
  change it after first login.

The two netboot variants are diskless: the board loads everything over the
network on every boot and needs no drive at all. The other two install to
the board's own drive.

## What you need

- A BC-250 board (or a compatible Cyan Skillfish box).
- A Linux machine with Nix and flakes enabled to build the images. A
  rootless [nix-portable](https://github.com/DavHau/nix-portable) works
  too if you cannot install Nix.
- The kernel source tree placed at `kernel/src` (next section). Budget
  roughly 15 GiB of disk for the source copy plus the kernel build.
- For the netboot variants: a machine on the same network to act as the
  boot server (llmtune's `netboot` commands can set one up for you), and
  for the LLM image an NFS export with your `.gguf` model files.
- For the desktop and standalone variants: a USB stick to flash the ISO
  onto, and a drive in the board to install to.

## Step 1: get the kernel source (`kernel/src`)

This flake pins the kernel to `linux-cachyos-bore 7.0.9`. That exact
version is validated on the board; kernels 7.0.11 and later regress the
BC-250's SDMA path, so the flake never tracks a stock or latest kernel.

The prepared source tree is about 850 MB and is not shipped in this repo.
Put it at `kernel/src` (a symlink is fine; the path is gitignored):

```sh
# Obtain the linux-cachyos-bore 7.0.9 source, e.g. via the AUR package:
git clone https://aur.archlinux.org/linux-cachyos-bore.git
cd linux-cachyos-bore
# check out the 7.0.9-1 revision of the PKGBUILD, then let makepkg
# prepare the tree (download + patch, no build):
makepkg --nobuild
# point kernel/src at the prepared tree:
ln -sfn /path/to/linux-cachyos-bore/src/linux-7.0.9 /path/to/bc250-nixos/kernel/src
```

If you already have a prepared 7.0.9 tree, just symlink it. The 12
BC-250 liberation patches in `kernel/patches/` are applied on top
automatically (sorted 01..12), and `kernel/bc250-running.config` is the
exact validated kernel config, so the build reproduces the reference
board's kernel.

## Step 2: build an image

Run these from the repo root:

```sh
# base netboot image (the default, no LLM stack)
nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe --impure

# netboot inference appliance
nix build .#netbootKernelLlmtune .#netbootRamdiskLlmtune .#netbootIpxeLlmtune --impure

# standalone single-box inference ISO (headless, models on local disk)
nix build .#standaloneIso --impure

# KDE desktop live/install ISO
nix build .#desktopIso --impure
```

`--impure` is required because the untracked `kernel/src` tree is resolved
from the invocation directory and copied into the store (set
`BC250_KERNEL_SRC=/path/to/tree` to point somewhere else).

Building the kernel compiles a lot of modules and needs plenty of scratch
space. If the build fails with "No space left on device", your `/tmp` is
probably a small tmpfs; point the build at a disk-backed directory with
room to spare, for example `TMPDIR=/var/tmp nix build ...`.

For the netboot variants you get three `result*` symlinks: the kernel, the
ramdisk, and an iPXE script. For the desktop and standalone ISOs, the
`result` symlink holds the bootable `.iso`.

There are also `netbootKernelMin`/`netbootRamdiskMin`/`netbootIpxeMin`
outputs (kernel only, no Rust packages) for a first QEMU smoke test, plus
a `qemu/` harness that validates the whole iPXE, HTTP, and boot chain in
software before you touch hardware. See `qemu/README.md`.

## Step 3a: netboot variants: serve and boot

The three build artifacts are what a netboot server hands to a PXE-booting
BC-250, served as `/vmlinuz`, `/initramfs`, and `/boot.ipxe`. Any
dnsmasq (proxyDHCP) + HTTP setup works;
[llmtune](https://github.com/cachenetics/llmtune)'s `netboot` commands set
up that whole side for you and register booted boards as fleet nodes.

Two things to know:

- Boot the board with a full power cycle (off at the plug, then on), not a
  warm reboot. The board's network card does not reliably PXE boot after a
  warm reboot.
- The board is headless. To see what it is doing during boot, set the
  netconsole option (below) and it will ship kernel and journal logs to
  your machine over UDP.

Once booted, the board names itself `bc250-<mac>` and you log in as root
over ssh with the key you configured (next section).

## Step 3b: installable variants: flash and install

Write the ISO to a USB stick (with `dd`, GNOME Disks, balenaEtcher, or
similar) and boot the board from it. The desktop image runs the Calamares
installer; the standalone image is text mode, so install it with the
standard [NixOS manual install](https://nixos.org/manual/nixos/stable/#sec-installation-manual)
steps (partition, `nixos-generate-config`, `nixos-install`). Remember to
change the placeholder password.

On the standalone image, once installed, put your `.gguf` model files in
`/var/lib/llmtune/models` and the server picks them up: it serves on port
8080, and `bc250-swap <name>` switches the served model.

## Site configuration (`local.nix`)

The netboot images need to know a few things about your network. Put them
in a file called `local.nix` next to `flake.nix`. It is gitignored, so
your keys and addresses never end up in the repo. Example (replace
`10.0.0.10` with your server's address):

```nix
{
  # Your boot server's ssh public key. REQUIRED: the image is key-only
  # (no password login), so without this there is no remote login.
  bc250.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... you@your-machine" ];

  # LLM image only: the NFS export holding your .gguf models,
  # and which model to serve at boot.
  bc250.llamaVulkan.modelsNfs = "10.0.0.10:/srv/nfs/models";
  bc250.llamaVulkan.modelFile = "your-model.gguf";

  # Where to ship boot logs (UDP port 6666). Optional but very handy,
  # because the board is headless with no serial console.
  bc250.netconsole.targetIp = "10.0.0.10";
}
```

Every variant accepts the full option set and ignores what does not apply
to it, so one `local.nix` serves all the images. The standalone image
needs no `local.nix` at all: it has no boot server, NFS, or netconsole to
point at.

## Repo layout

```
flake.nix                     inputs + the four systems + image outputs
kernel/
  bc250-kernel.nix            pinned 7.0.9 source + config + the 12 patches
  bc250-running.config        the validated kernel config
  patches/01..12-*.patch      the BC-250 liberation series (from project-ariel)
  src/                        NOT tracked: place the kernel source tree here
modules/
  bc250-hardware.nix          the pinned kernel + kernel parameters
  netboot-node.nix            key-only root ssh + hostname-from-MAC
  arieltune-tune.nix          apply an arieltune profile on boot
  gpu-vulkan.nix              GPU userspace: mesa-26 RADV + vulkan-tools
  llama-vulkan.nix            GPU inference: Vulkan llama.cpp, NFS or local models
  netconsole-debug.nix        ship boot logs to a collector over UDP
hosts/
  bc250-nixos.nix             the default headless image
  bc250-nixos-llmtune.nix     the netboot inference appliance
  bc250-nixos-standalone.nix  the single-box local inference ISO
  bc250-nixos-desktop.nix     the KDE Plasma desktop ISO
  bc250-netboot-min.nix       kernel-only variant (QEMU smoke test)
pkgs/
  llmtune.nix  arieltune.nix  the two Rust tools, built from source
qemu/                         software-only boot-chain test harness
```

## Related projects

- [llmtune](https://github.com/cachenetics/llmtune): the BC-250 inference
  engine and netboot control plane. It runs the dnsmasq/HTTP/NFS server
  side and drives booted boards as fleet nodes; this repo builds the image
  those boards boot.
- [arieltune (project-ariel)](https://github.com/cachenetics/project-ariel):
  the BC-250 tuning suite (APU liberation, CU routing, GPU/CPU/memory
  tuning). The kernel patches here are its liberation series, and the
  images apply an arieltune profile on every boot.

Both are pinned as flake inputs and built from source into the images.

## License

GPL-2.0-only. SPDX identifiers are carried in the source files; the
kernel patches are derivative works of the Linux kernel (GPL-2.0-only).
