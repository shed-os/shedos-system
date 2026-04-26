#!/usr/bin/env bash
# Verify shedos-kernel ships a config that supports the storage devices
# every ShedOS user is likely to touch — and verify the build-infra
# entries that wire shedos-kernel into the wider package set haven't
# regressed.
#
# Storage-driver contract: every entry below MUST resolve to =y or =m
# in packaging/shedos-kernel/config.x86_64. Dropping one would silently
# break HDD users, USB-stick boot, btrfs/ext4 root, etc. CI fails the
# kernel build job loudly when the config falls out of compliance.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
config_file=$repo_root/packaging/shedos-kernel/config.x86_64
build_script=$repo_root/scripts/build-shedos-packages.sh
meta_render=$repo_root/scripts/render-meta-depends.sh

if [[ ! -f $config_file ]]; then
    echo "FATAL: $config_file missing — has shedos-kernel been removed?" >&2
    exit 2
fi

pass=0
fail=0
failures=()

_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# ---------------------------------------------------------------------------
# T1: storage-driver non-removal contract
# ---------------------------------------------------------------------------
storage_required=(
    CONFIG_SATA_AHCI            # every modern SATA controller
    CONFIG_SATA_AHCI_PLATFORM   # platform SATA (some embedded laptops)
    CONFIG_ATA_PIIX             # 2010-era Intel + most VMs
    CONFIG_BLK_DEV_SD           # SCSI disk; covers SATA via libata
    CONFIG_USB_STORAGE          # USB sticks, external HDD enclosures, SD readers
    CONFIG_BLK_DEV_NVME         # NVMe SSDs
    CONFIG_BTRFS_FS             # root fs; non-negotiable
    CONFIG_EXT4_FS              # data partitions, external drives
    CONFIG_XFS_FS               # workstation/server data drives
    CONFIG_VFAT_FS              # USB sticks, ESP, FAT32
    CONFIG_EXFAT_FS             # large USB sticks, modern SD cards
    CONFIG_NTFS3_FS             # Windows-formatted external drives
    CONFIG_BLOCK_LEGACY_AUTOLOAD # some HDD controllers need this
    CONFIG_IOSCHED_BFQ          # default scheduler for HDD per udev rules
    CONFIG_MQ_IOSCHED_DEADLINE  # default scheduler for SSD per udev rules
)

for sym in "${storage_required[@]}"; do
    val=$(awk -F= -v s="$sym" '$1 == s {print $2; exit}' "$config_file")
    if [[ $val == y || $val == m ]]; then
        _ok "T1_storage_$sym"
    else
        _fail "T1_storage_$sym" "expected =y or =m, got '${val:-MISSING}'"
    fi
done

# ---------------------------------------------------------------------------
# T2: developer-tuning knobs the README promises (HZ_1000, IKCONFIG, BPF,
#     ftrace) all stay enabled.
# ---------------------------------------------------------------------------
dev_required=(
    "CONFIG_HZ_1000=y"
    "CONFIG_PREEMPT=y"
    "CONFIG_BPF=y"
    "CONFIG_BPF_JIT=y"
    "CONFIG_DEBUG_INFO_BTF=y"
    "CONFIG_KPROBES=y"
    "CONFIG_FTRACE=y"
    "CONFIG_DYNAMIC_FTRACE=y"
    "CONFIG_IKCONFIG=y"
    "CONFIG_IKCONFIG_PROC=y"
)

for line in "${dev_required[@]}"; do
    if grep -qxF "$line" "$config_file"; then
        _ok "T2_dev_${line%%=*}"
    else
        _fail "T2_dev_${line%%=*}" "config line '$line' not found"
    fi
done

# ---------------------------------------------------------------------------
# T3: build-shedos-packages.sh wires shedos-kernel into BUILD_ORDER and
#     drops --nodeps for it (kernel needs --syncdeps to pull gcc/etc.).
# ---------------------------------------------------------------------------
if grep -qE "^[[:space:]]*shedos-kernel\b" "$build_script"; then
    _ok T3_build_order_lists_shedos_kernel
else
    _fail T3_build_order_lists_shedos_kernel \
        "shedos-kernel missing from BUILD_ORDER in $build_script"
fi

if grep -qE 'pkgname == shedos-kernel' "$build_script" \
   && grep -qE -- '--syncdeps' "$build_script"; then
    _ok T3_build_drops_nodeps_for_shedos_kernel
else
    _fail T3_build_drops_nodeps_for_shedos_kernel \
        "expected a 'pkgname == shedos-kernel' branch with --syncdeps in $build_script"
fi

# ---------------------------------------------------------------------------
# T4: render-meta-depends.sh includes shedos-kernel so it lands in
#     shedos-meta's depends=. Stock 'linux' must also remain depended-on
#     for the fallback boot entry to keep working — that comes from
#     packages/official/base.txt; we sanity-check it.
# ---------------------------------------------------------------------------
if grep -qE "^[[:space:]]*shedos-kernel[[:space:]]*$" "$meta_render"; then
    _ok T4_meta_lists_shedos_kernel
else
    _fail T4_meta_lists_shedos_kernel \
        "shedos-kernel missing from shedos_pkgs in $meta_render"
fi

if grep -qxE "^linux$" "$repo_root/packages/official/base.txt"; then
    _ok T4_base_keeps_linux
else
    _fail T4_base_keeps_linux \
        "stock 'linux' missing from packages/official/base.txt — fallback kernel would not be installed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$((pass + fail))
echo
echo "shedos-kernel: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
