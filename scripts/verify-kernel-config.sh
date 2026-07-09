#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-kernel-config.sh: prove the flake's RESOLVED kernel .config still
# matches the validated board config (kernel/bc250-running.config).
#
# Why this exists: the kernel is now built by overriding
# xddxdd/nix-cachyos-kernel's linux-cachyos-bore. Our board config is dropped
# in as the defconfig, but the wrapper then layers its structuredExtraConfig
# (much of it mkForce'd) on top, with autoModules=true and
# ignoreConfigErrors=true. None of that is visible in the repo diff; THIS
# script is the compensating control. It builds the resolved .config, diffs it
# against the validated config, prints a categorized report, and fails on any
# unexplained delta in the critical set (amdgpu/DRM, scheduler/timer pack,
# THP, SMP/NR_CPUS, netboot path).
#
# Usage:
#   scripts/verify-kernel-config.sh                # nix build .#kernel.configfile, then diff
#   scripts/verify-kernel-config.sh /path/to/.config   # diff a prebuilt config
#
# Needs a nix host with flakes for the no-argument form; the one-argument form
# needs only coreutils + awk. Run from anywhere; paths resolve relative to the
# repo root. Exit 0 = no critical deltas; exit 1 = critical delta found;
# exit 2 = usage/build failure.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reference="$repo_root/kernel/bc250-running.config"
[ -r "$reference" ] || { echo "error: reference config not found: $reference" >&2; exit 2; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ $# -ge 1 ]; then
  resolved="$1"
  [ -r "$resolved" ] || { echo "error: cannot read resolved config: $resolved" >&2; exit 2; }
else
  command -v nix >/dev/null 2>&1 || {
    echo "error: nix not found; pass a prebuilt .config path instead" >&2
    exit 2
  }
  echo "==> building resolved kernel config (.#kernel.configfile)..."
  nix build "$repo_root#kernel.configfile" --out-link "$tmpdir/configfile"
  resolved="$tmpdir/configfile"
fi

# --- expected, deliberate deltas (documented in kernel/bc250-kernel.nix) ----
# A delta on these symbols is reported but never fails the check:
#   LOCALVERSION       "" -> "-cachyos": the wrapper's uname/modDirVersion
#                      suffix. Cosmetic (but see BUILD_AND_VALIDATE.md: tools
#                      that match uname must be re-checked once, on first boot).
#   X86_NATIVE_CPU /   the validated config was built ON the board with
#   GENERIC_CPU /      -march=native; the flake builds a reproducible generic
#   X86_64_VERSION     x86_64-v1 kernel (wrapper processorOpt default).
#   OVERLAY_FS_*       suboptions pinned to NixOS defaults by the wrapper so
#                      the NixOS etc-overlay works; feature-behavior only.
#   HSA_AMD_P2P        n -> y: a 7.0.9 GPU symbol kconfig defaults on once its
#                      deps are met (independent of autoModules). It enables
#                      GPU-to-GPU peer DMA for multi-GPU HSA; the BC-250 is a
#                      single-GPU board, so it is inert. Verified 2026-07-09 as
#                      the ONLY residual GPU-critical delta with autoModules
#                      off (empirical build via nix-portable on cache).
expected_exceptions='^CONFIG_(LOCALVERSION|X86_NATIVE_CPU|GENERIC_CPU|X86_64_VERSION|HSA_AMD_P2P|OVERLAY_FS_(REDIRECT_DIR|REDIRECT_ALWAYS_FOLLOW|INDEX|XINO_AUTO|METACOPY))$'

# --- the critical set: any OTHER delta here fails the check -----------------
# GPU / SDMA / DRM: the whole reason this kernel exists.
crit_gpu='^CONFIG_(DRM_AMDGPU|DRM_AMD|HSA_AMD|DRM_TTM|DRM_SCHED|DRM_BUDDY|DRM_DISPLAY|DRM_EXEC|DRM_SUBALLOC)'
# Scheduler / timer pack: bore + 1000Hz + full tick + full preempt (validated).
crit_sched='^CONFIG_(SCHED_BORE|HZ|HZ_[0-9]+|NO_HZ|NO_HZ_FULL|NO_HZ_IDLE|NO_HZ_COMMON|HZ_PERIODIC|PREEMPT|PREEMPT_DYNAMIC|PREEMPT_VOLUNTARY|PREEMPT_NONE|PREEMPT_LAZY)$'
# Memory: THP=always is the validated setting on the 16 GiB UMA board.
crit_mem='^CONFIG_(TRANSPARENT_HUGEPAGE|TRANSPARENT_HUGEPAGE_ALWAYS|TRANSPARENT_HUGEPAGE_MADVISE|ZSWAP|ZSMALLOC|ZRAM)'
# SMP / CPU topology.
crit_smp='^CONFIG_(SMP|NR_CPUS)$'
# Netboot path: NIC driver + NFS root + overlayfs presence.
crit_boot='^CONFIG_(R8169|NFS_FS|NFS_V[34]|ROOT_NFS|IP_PNP|IP_PNP_DHCP|OVERLAY_FS|SQUASHFS|BLK_DEV_INITRD)$'

critical_re="$crit_gpu|$crit_sched|$crit_mem|$crit_smp|$crit_boot"

# --- normalize: one "CONFIG_FOO=value" line per symbol; "is not set" -> =n --
normalize() {
  awk '
    /^# CONFIG_[A-Za-z0-9_]+ is not set$/ { print $2 "=n"; next }
    /^CONFIG_[A-Za-z0-9_]+=/ { print; next }
  ' "$1" | sort -u
}

normalize "$reference" > "$tmpdir/ref.norm"
normalize "$resolved" > "$tmpdir/new.norm"

# --- diff. Absent counts as =n (kconfig semantics for bool/tristate); a
# symbol absent on one side with =n on the other is NOT a delta. -------------
awk -F= -v OFS='\t' '
  NR == FNR { ref[$1] = substr($0, length($1) + 2); next }
  { new[$1] = substr($0, length($1) + 2) }
  END {
    for (k in ref) {
      r = ref[k]; n = (k in new) ? new[k] : "n"
      if (r != n) print k, r, n
    }
    for (k in new) {
      if (!(k in ref) && new[k] != "n") print k, "n", new[k]
    }
  }
' "$tmpdir/ref.norm" "$tmpdir/new.norm" | sort > "$tmpdir/deltas"

total=$(wc -l < "$tmpdir/deltas")
echo
echo "== kernel config fidelity: resolved vs kernel/bc250-running.config =="
echo "   reference: $reference"
echo "   resolved:  $resolved"
echo "   deltas:    $total (symbol, validated -> resolved)"
echo

category_of() {
  if   [[ "$1" =~ $crit_gpu ]];   then echo "GPU/DRM/amdgpu"
  elif [[ "$1" =~ $crit_sched ]]; then echo "sched/timer"
  elif [[ "$1" =~ $crit_mem ]];   then echo "memory/THP"
  elif [[ "$1" =~ $crit_smp ]];   then echo "SMP/CPU"
  elif [[ "$1" =~ $crit_boot ]];  then echo "netboot"
  else echo "other"
  fi
}

crit_fail=0
critical_out=""
review_out=""
expected_out=""
while IFS=$'\t' read -r sym refv newv; do
  cat_name=$(category_of "$sym")
  line="  [$cat_name] $sym: $refv -> $newv"
  if [[ "$sym" =~ $expected_exceptions ]]; then
    expected_out+="$line"$'\n'
  elif [[ "$sym" =~ $critical_re ]]; then
    critical_out+="$line"$'\n'
    crit_fail=1
  else
    review_out+="$line"$'\n'
  fi
done < "$tmpdir/deltas"

if [ "$total" -eq 0 ]; then
  echo "OK: resolved config is identical (modulo absent==n) to the validated board config."
  exit 0
fi

if [ -n "$critical_out" ]; then
  echo "-- CRITICAL deltas (FAIL the check):"
  printf '%s\n' "$critical_out"
fi
if [ -n "$review_out" ]; then
  echo "-- deltas for review (do not fail, look at them once):"
  printf '%s\n' "$review_out"
fi
if [ -n "$expected_out" ]; then
  echo "-- EXPECTED deltas (documented in kernel/bc250-kernel.nix, never fail):"
  printf '%s\n' "$expected_out"
fi

if [ "$crit_fail" -ne 0 ]; then
  echo "FAIL: critical config delta(s) vs the validated board config." >&2
  echo "Either the wrapper/structuredExtraConfig changed, autoModules answered" >&2
  echo "a new symbol, or an input bump moved the kernel. Do NOT boot-test past" >&2
  echo "this without understanding each delta; if a delta is validated on the" >&2
  echo "board, add it to expected_exceptions with a comment." >&2
  exit 1
fi

echo "OK: no critical deltas. Review the remaining deltas above once, then proceed."
exit 0
