# Build and validate: from a nix host to a proven board

The operator runbook for taking a change to this repo (or a fresh checkout)
through build, config verification, and hardware validation. Everything in
sections 1-3 runs on any x86_64 Linux machine with Nix + flakes; section 4
runs on the BC-250 itself.

Background: the kernel is an override of xddxdd/nix-cachyos-kernel's
`linux-cachyos-bore` (see `kernel/bc250-kernel.nix`). Two properties are
load-bearing and each has a gate:

- version 7.0.9 exactly (7.0.11+ regresses the board's SDMA path): gated by
  an eval-time assert in `kernel/bc250-kernel.nix`;
- the resolved build config matches the validated board config: gated by
  `scripts/verify-kernel-config.sh`.

## 1. Evaluation gates (fast, no build)

From the repo root:

```sh
# lock graph is consistent (the llama-cpp nixpkgs follows was hand-edited;
# this confirms nix agrees). 'nix flake lock' may renumber node names, which
# is harmless; it must NOT change any locked rev.
nix flake metadata

# the outputs all evaluate
nix flake show

# the 7.0.9 assert holds (prints "7.0.9"; a bumped input fails HERE
# with a message explaining what to do)
nix eval .#kernel.version
```

## 2. Config fidelity (builds only the .config, not the kernel)

```sh
scripts/verify-kernel-config.sh
```

This builds `.#kernel.configfile`, diffs it against
`kernel/bc250-running.config`, and prints a categorized report
(GPU/DRM/amdgpu, sched/timer, memory/THP, SMP/CPU, netboot, other).

- Exit 0 with only EXPECTED deltas (LOCALVERSION `-cachyos`, the
  native->generic-v1 processor options, the NixOS overlayfs suboptions):
  proceed.
- "review" deltas: look at each once. On the FIRST run after the
  nix-cachyos-kernel refactor some noise is possible (autoModules answering
  symbols the defconfig leaves open); anything touching amdgpu, scheduler,
  THP, or the netboot path should be treated as critical even if the
  categorizer put it in "other".
- Exit 1 (critical delta): stop. Do not boot-test past a red config check.

## 3. Build

```sh
# kernel alone first: the long pole, and the patches gate.
# If /tmp is a small tmpfs: TMPDIR=/var/tmp nix build .#kernel
nix build .#kernel
```

VERIFY ON FIRST BUILD: the 12 liberation patches were authored against the
prepared AUR `linux-cachyos-bore` 7.0.9-1 tree; the wrapper builds from the
CachyOS release tarball + the pinned kernel-patches repo. Both are verified
byte-identical to what the validated board build used (tarball sha256
e1469e8e..., bore patch sha256 f594e3a0..., full hashes in
`kernel/bc250-kernel.nix`), so the 12 should apply exactly as before; the one
untested difference is nixpkgs' extra bridge_stp/request_key helper patches
applied first (disjoint files, conflict not expected). If any of the 12 fails
to apply, the failure is in the `applyPatches` phase of `linux-src-patched`;
report the hunk, do not fuzz it.

Then the images (pure; `--impure` ONLY if you use the `local.nix` site-config
option, see README):

```sh
# QEMU smoke-test triple (kernel only, no Rust packages)
nix build .#netbootKernelMin .#netbootRamdiskMin .#netbootIpxeMin

# the real netboot triples / ISOs
nix build .#netbootKernel .#netbootRamdisk .#netbootIpxe
nix build .#netbootKernelLlmtune .#netbootRamdiskLlmtune .#netbootIpxeLlmtune
nix build .#standaloneIso
nix build .#desktopIso
```

Before touching hardware, run the software boot chain: `qemu/README.md`
validates iPXE + HTTP + boot end to end with the Min triple.

## 4. Board validation (the BC-250)

Run this whole section on first build AND after any `nix flake update` or
nixpkgs bump: the base is rolling nixos-unstable, so an update can move
mesa/glibc/systemd under gfx1013 (mesa is the historically fragile part on
this chip). A green build proves nothing about the GPU until the board says
so. If the GPU or SDMA regresses, roll `flake.lock` back to the pinned
revision that last passed here.

Boot the board with a FULL power cycle (off at the plug), not a warm reboot:
the NIC does not reliably PXE after a warm reboot.

### 4.1 Identity: the new uname

```sh
uname -r        # expect: 7.0.9-cachyos
```

This build's uname is `7.0.9-cachyos` (the wrapper's LOCALVERSION), NOT the
old board kernel's `-cachyos-bore` style suffix. One-time check: anything
that matches on uname or `/lib/modules/<ver>` (scripts, monitoring, tuning
profiles) must be re-checked against the new string.

### 4.2 Liberation surface: 40-CU unlock + SMU debugfs

The images pass `amdgpu.bc250_cc_write_mode=3` on the cmdline
(`modules/bc250-hardware.nix`); the kernel side is liberation patch 12
(`12-unlock-all-40-compute-units.patch`). Verify:

```sh
# 40 CUs visible to the driver (40, not the factory 24)
grep -H . /sys/class/drm/card*/device/gpu_info 2>/dev/null || true
vulkaninfo 2>/dev/null | grep -i 'compute\|deviceName' | head
arieltune node status   # shape/CU view if arieltune is on the image
```

The SMU debugfs surface comes from patches 07-09 and 11
(`07-cac-weight-and-sendraw-debugfs`, `08-smu-cmn-send-raw-debugfs-definitions`,
`09-cpu-cclk-soft-limits-debugfs`, `11-full-telemetry-dump-debugfs`). All five
entries must exist:

```sh
ls /sys/kernel/debug/dri/*/ | grep -E \
  'amdgpu_smu_send_raw|cyan_skillfish_(cclk_soft_max|cclk_soft_min|gfx_cac_weight|l3_cac_weight|telemetry)'
cat /sys/kernel/debug/dri/*/cyan_skillfish_telemetry | head
```

Also confirm the full 16 GiB GTT took effect:

```sh
dmesg | grep -iE 'amdgpu.*(gtt|gart)'   # expect 16384M GTT / GART
```

### 4.3 SDMA-heavy validation (the 7.0.9-vs-7.0.11 tell)

The SDMA regression shows up under sustained full-offload inference
(hangs/ring timeouts), not at idle. Run a full-offload llama bench and let it
sustain:

```sh
# llmtune image: bench through the stack
llmtune bench            # or from the fleet controller: llmtune fleet bench-all

# or raw llama.cpp, full offload, any model that fits
llama-bench -m /var/lib/llmtune/models/<model>.gguf -ngl 99 -p 512 -n 128
```

Pass criteria:

- no `amdgpu` ring timeout / GPU reset / SDMA errors in `dmesg -w` during the
  run;
- throughput in line with the previous validated build on the same board and
  model (regenerate your own baseline; absolute numbers vary with tuning);
- board stays up through at least several consecutive bench runs and one
  `bc250-swap` model swap (exercises model load, an SDMA-heavy path).

### 4.4 Sign-off

A build is validated when 4.1-4.3 all pass. Record the kernel store path and
`uname -r` with the result. If any step fails, capture `dmesg` and the
verify-kernel-config.sh report before rebooting.

## CI (intended job)

The repo has no `.gitlab-ci.yml`: the GitLab runners on the forge do not have
nix, and a permanently-red pipeline would block the forge autopilot's
automerge. When a nix-capable runner (tag `nix`) exists, add exactly this:

```yaml
kernel-config-fidelity:
  stage: test
  tags: [nix]
  script:
    - nix flake metadata
    - nix eval .#kernel.version
    - scripts/verify-kernel-config.sh
```

Until then, running `scripts/verify-kernel-config.sh` on the build host is a
REQUIRED step of every kernel-affecting MR (this document is the control).
