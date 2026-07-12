# bc250-nixos

NixOS images for the AMD BC-250, the cheap 16 GiB APU board (gfx1013,
"Cyan Skillfish") that shows up on the surplus market. Out of the box the
board is awkward: stock kernels drive it badly and stock mesa cannot see
the GPU. This repo fixes that. It builds ready-to-boot images with a
patched kernel, a working Vulkan GPU stack, and the
[arieltune](https://github.com/cachenetics/project-ariel) tuning tools, so
you can turn the board into a small Linux server, an LLM box, or a desktop
computer.

The whole thing is one Nix flake, and every piece (kernel source included)
is a flake input. That means there is nothing to download, patch, or place
by hand, and you do not even need to clone this repo. One command builds a
bootable image:

```sh
nix build github:cachenetics/bc250-nixos#standaloneIso
```

That gives you a ready-to-flash ISO that boots the board, sees the GPU, and
serves LLMs from its own disk. The desktop ISO works the same way
(`#desktopIso`). Both log in with a placeholder password, so they need no
configuration at all. The two netboot images also build from a bare
reference, but they are ssh-key-only, so they need one small piece of
configuration first: your ssh public key (see [Configure your
site](#configure-your-site)).

Everything is GPL-2.0-only (matching the kernel and patches). See `LICENSE`.

## Which image do I want?

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
- A Linux machine with [Nix](https://nixos.org/download/) and
  [flakes enabled](https://nixos.wiki/wiki/Flakes) to build the images.
  You do not need to run NixOS, and you do not need to know Nix: every
  command in this README is copy-paste. A rootless
  [nix-portable](https://github.com/DavHau/nix-portable) works too if you
  cannot install Nix. Budget roughly 15 GiB of disk for the kernel build.
- For the netboot variants: a machine on the same network to act as the
  boot server (llmtune's `netboot` commands can set one up for you), and
  for the LLM image an NFS export with your `.gguf` model files.
- For the desktop and standalone variants: a USB stick to flash the ISO
  onto, and a drive in the board to install to.

There is nothing to download or place by hand: the kernel source is a
flake input, fetched and patched automatically at build time.

## Binary cache (skip the kernel build)

The custom kernel and the Vulkan llama.cpp build are not on
`cache.nixos.org`, so by default you compile them yourself (~15 GiB of
disk, and slow on the board itself). CI builds them on every push and
pushes them to a [Cachix](https://www.cachix.org/) cache, so you can pull
the binaries instead:

    https://neoney.cachix.org
    public key: neoney.cachix.org-1:bsFaTdG04tfzci0osGfosbRX8KX94Ih/2hU0HpJ+qRM=

If you build with `nix build github:n3oney/bc250-nixos#...`, the flake
advertises this cache automatically (via its `nixConfig`) and Nix prompts
you once to trust it — say yes and the kernel is fetched, not built. The
images themselves ship this cache in their `/etc/nix/nix.conf`, so a
board doing its own later rebuilds substitutes from it too.

To enable it globally on your build machine instead:

```sh
# one-off, if you have the cachix CLI
cachix use neoney

# or add to /etc/nix/nix.conf (or ~/.config/nix/nix.conf) by hand
extra-substituters = https://neoney.cachix.org
extra-trusted-public-keys = neoney.cachix.org-1:bsFaTdG04tfzci0osGfosbRX8KX94Ih/2hU0HpJ+qRM=
```

The cache is a convenience, not a requirement: everything still builds
from source without it.

## Step 1: build an image

Straight from the flake reference, no clone needed:

```sh
# standalone single-box inference ISO (headless, models on local disk)
nix build github:cachenetics/bc250-nixos#standaloneIso

# KDE desktop live/install ISO
nix build github:cachenetics/bc250-nixos#desktopIso
```

Or from a checkout of this repo, run these from the repo root:

```sh
# base netboot image (the default, no LLM stack)
nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe

# netboot inference appliance
nix build .#netbootKernelLlmtune .#netbootRamdiskLlmtune .#netbootIpxeLlmtune

# standalone single-box inference ISO
nix build .#standaloneIso

# KDE desktop live/install ISO
nix build .#desktopIso
```

The netboot triples also build from a bare `github:` reference, but with
no ssh key baked in the resulting image has no remote login; to set your
key and network options without cloning, point a small consumer flake at
this one (see [Configure your site](#configure-your-site), Option A).

What you get:

- Netboot variants: three `result*` symlinks: the kernel, the ramdisk, and
  an iPXE script.
- Desktop and standalone ISOs: a `result` symlink holding the bootable
  `.iso`.

Building the kernel compiles a lot of modules and needs plenty of scratch
space. If the build fails with "No space left on device", your `/tmp` is
probably a small tmpfs; point the build at a disk-backed directory with
room to spare, for example `TMPDIR=/var/tmp nix build ...`.

There are also `netbootKernelMin`/`netbootRamdiskMin`/`netbootIpxeMin`
outputs (kernel only, no Rust packages) for a first QEMU smoke test, plus
a `qemu/` harness that validates the whole iPXE, HTTP, and boot chain in
software before you touch hardware. See `qemu/README.md`.

## Step 2a: netboot variants: serve and boot

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
  netconsole option (next section) and it will ship kernel and journal
  logs to your machine over UDP.

Once booted, the board names itself `bc250-<mac>` (the last six hex digits
of its MAC) and you log in as root over ssh with the key you configured
(next section).

## Step 2b: installable variants: flash and install

Write the ISO to a USB stick (with `dd`, GNOME Disks, balenaEtcher, or
similar) and boot the board from it. The desktop image runs the Calamares
installer; the standalone image is text mode, so install it with the
standard [NixOS manual install](https://nixos.org/manual/nixos/stable/#sec-installation-manual)
steps (partition, `nixos-generate-config`, `nixos-install`). Remember to
change the placeholder password.

On the standalone image, once installed, put your `.gguf` model files in
`/var/lib/llmtune/models` and the server picks them up: it serves on port
8080, and `bc250-swap <name>` switches the served model.

## Configure your site

The netboot images need to know a few things about your network: your ssh
public key (REQUIRED: the image is key-only, no password login), and for
the LLM image the NFS model export. None of that belongs in tracked files.
Put them in your own NixOS configuration or private consumer flake:

```nix
{
  # Your boot server's ssh public key. REQUIRED: the image is key-only
  # (no password login), so without this there is no remote login.
  bc250.netbootNode.sshAuthorizedKeys = [ "ssh-ed25519 AAAA... you@your-machine" ];

  # LLM image only: the NFS export holding your .gguf models,
  # and which model to serve at boot.
  bc250.llamaVulkan.modelsNfs = "10.0.0.10:/srv/nfs/models";
  bc250.llamaVulkan.modelFile = "your-model.gguf";

  # Where to ship boot logs (UDP port 6666). Optional but very handy,
  # because the board is headless with no serial console.
  # Capture on that machine with: socat -u udp-recvfrom:6666,fork -
  bc250.netconsole = {
    enable = true;
    targetIp = "10.0.0.10";
  };
}
```

Also available: `bc250.llamaVulkan.modelOverrides` (per-model llama.cpp
flag overrides, model filename to flag string) and
`bc250.netconsole.port`/`bc250.netconsole.targetMac` if the defaults do
not suit your network.

The standalone profile needs no site configuration: it has no boot server,
NFS, or netconsole dependency.

### Consumer flake

The primary API is `nixosModules`. The complete profiles supply the patched
kernel and pinned input packages themselves; no overlay, `specialArgs`,
`allowUnfree`, or impure lookup is required:

```nix
{
  inputs.bc250-nixos.url = "github:cachenetics/bc250-nixos";
  inputs.nixpkgs.follows = "bc250-nixos/nixpkgs";

  outputs = { self, nixpkgs, bc250-nixos, ... }: {
    nixosConfigurations.my-node = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        bc250-nixos.nixosModules.profile-inference-netboot
        {
          bc250.netbootNode.sshAuthorizedKeys = [
            "ssh-ed25519 AAAA... you@your-machine"
          ];
          bc250.llamaVulkan = {
            modelsNfs = "10.0.0.10:/srv/nfs/models";
            modelFile = "your-model.gguf";
          };
          bc250.netconsole = {
            enable = true;
            targetIp = "10.0.0.10";
          };
        }
      ];
    };

    packages.x86_64-linux = {
      netbootKernel = self.nixosConfigurations.my-node.config.system.build.kernel;
      netbootRamdisk = self.nixosConfigurations.my-node.config.system.build.netbootRamdisk;
      netbootIpxe = self.nixosConfigurations.my-node.config.system.build.netbootIpxeScript;
    };
  };
}
```

Then build the three outputs in your consumer flake. For a conventional
installed NixOS system, import the smaller `default`, `gpu-vulkan`,
`arieltune-tune`, `llama-vulkan`, `netboot-node`, or `netconsole-debug`
modules and enable only the features you want. `overlays.default` separately
exports `arieltune` and `llmtune` for configurations that want the packages
without their NixOS services.

For example, the reusable hardware, Vulkan, and tuning stack is:

```nix
{
  imports = [
    bc250-nixos.nixosModules.default
    bc250-nixos.nixosModules.gpu-vulkan
    bc250-nixos.nixosModules.arieltune-tune
  ];

  hardware.bc250 = {
    enable = true;
    vulkan.enable = true;
    # Explicit opt-ins; both are off in the reusable module defaults.
    disableMitigations = false;
    binaryCache.enable = false;
  };

  services.arieltune-tune = {
    enable = true;
    profile = "balanced";
  };
}
```

The hardware module also exposes the patched `kernelPackage`, GTT size,
compute-unit write mode, IOMMU policy, zswap, consoles, extra kernel parameters,
and binary-cache policy. The inference module exposes its llama.cpp and llmtune
packages, model source/directory, NFS export, model profiles, listen address,
port, firewall policy, and server flags. All input-backed package defaults are
overridable with ordinary NixOS options.

## Keeping it working: updates and reproducibility

This repo builds on a rolling `nixos-unstable` base, but the committed
`flake.lock` pins every input to an exact revision, so a plain `nix build`
is reproducible: you get the same nixpkgs, mesa, and kernel every time. The
kernel is additionally hard-pinned to 7.0.9 (the flake refuses to evaluate
against any other version), because 7.0.11+ regresses the board's SDMA
path.

The rest of the stack is not version-gated, and mesa and glibc are exactly
the parts this board is fussy about (mesa older than 26 cannot even see the
GPU). So treat `nix flake update` as a hardware event, not routine
maintenance:

- The `flake.lock` in this repo IS the validated pin. A fresh clone builds
  a known-good image without touching it.
- If you run `nix flake update` (or bump `nixpkgs`), you may pull a newer
  mesa/glibc/systemd that has never been tried on gfx1013. Re-run the board
  validation in `docs/BUILD_AND_VALIDATE.md` (section 4) before trusting the
  result, and be ready to roll the lock back if the GPU or SDMA regresses.
- To hold a single input still while updating others, use
  `nix flake lock --update-input <name>` rather than a blanket update.

## Under the hood

### The kernel

The kernel is `linux-cachyos-bore 7.0.9`, built by overriding
[xddxdd/nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel)
(pinned in `flake.nix` to a rev that provides exactly 7.0.9). That exact
version is validated on the board; kernels 7.0.11 and later regress the
BC-250's SDMA path, so the flake never tracks a stock or latest kernel,
and `kernel/bc250-kernel.nix` hard-asserts the version so a careless
input bump fails at evaluation time instead of producing a bad kernel.

On top of the stock cachyos-bore tree the flake layers the two BC-250
things: the 12 liberation patches in `kernel/patches/` (applied in 01..12
order) and the exact validated board config
(`kernel/bc250-running.config`). `scripts/verify-kernel-config.sh` proves
the resolved build config still matches the validated one; see
`docs/BUILD_AND_VALIDATE.md` for the full build-and-validate runbook.

### Validation

The pinned build has been validated end to end on real hardware, including
a real PXE boot: the 40-CU unlock takes effect, the GPU enumerates as
GFX1013 under mesa-26 RADV, and full-offload llama.cpp Vulkan inference
runs at production throughput with no SDMA errors. The runbook for
repeating that validation (after any input bump) is
`docs/BUILD_AND_VALIDATE.md`.

### Repo layout

```
flake.nix                     inputs, self-contained module wrappers, profiles, outputs
kernel/
  bc250-kernel.nix            the 7.0.9 cachy kernel override: config + 12 patches
  bc250-running.config        the validated kernel config
  patches/01..12-*.patch      the BC-250 liberation series (from project-ariel)
modules/
  bc250-hardware.nix          optional kernel, memory, console, and cache policy
  netboot-node.nix            optional key-only SSH + hostname-from-MAC
  arieltune-tune.nix          optional arieltune profile service
  gpu-vulkan.nix              optional mesa-26 RADV userspace
  llama-vulkan.nix            optional Vulkan llama.cpp service, NFS or local models
  netconsole-debug.nix        optional remote kernel/journal logging
  rocm.nix                    optional gfx1010-compatible ROCm package set
hosts/
  *.nix                       thin settings for the exported image profiles
pkgs/
  llmtune.nix  arieltune.nix  the two Rust tools, built from source
scripts/
  verify-kernel-config.sh     resolved-config vs validated-config gate
docs/
  BUILD_AND_VALIDATE.md       operator build + board-validation runbook
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

## Acknowledgments

- **[neoney](https://github.com/n3oney)** (Michal Minarowski) reworked the
  flake to build the kernel entirely from inputs:
  overriding [xddxdd/nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel)
  instead of a hand-supplied source tree, moving the base to a rolling
  nixpkgs, and pinning llama.cpp as a flake input. That is what lets you
  build straight from the flake reference with no `--impure` and nothing to
  place by hand.
- [xddxdd](https://github.com/xddxdd) for `nix-cachyos-kernel`, the CachyOS
  kernel packaging this repo builds on.

## License

GPL-2.0-only. SPDX identifiers are carried in the source files; the
kernel patches are derivative works of the Linux kernel (GPL-2.0-only).
