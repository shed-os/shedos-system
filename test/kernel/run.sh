#!/usr/bin/env bash
# Guard the shedos-kernel -> linux-zen migration invariants.
#
# ShedOS no longer vendors a kernel (Arch owns linux-zen's config), so there
# is no storage-driver config to contract-test. Instead we assert the wiring
# that keeps the migration correct: linux-zen is the primary kernel, stock
# linux is an installable fallback, shedos-kernel is fully retired, and the
# limine renderer + preset still produce a bootable default + recovery entry.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
base_txt=$repo_root/packages/official/base.txt
meta_render=$repo_root/scripts/render-meta-depends.sh
build_script=$repo_root/scripts/build-shedos-packages.sh
renderer=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/render-limine-config.sh
preset=$repo_root/packaging/shedos-system/tree/etc/mkinitcpio.d/linux-zen.preset

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# ---------------------------------------------------------------------------
# K1: linux-zen (primary) + stock linux (fallback), with their headers, are
#     explicit roots so all four install and land in closure/meta/airootfs.
# ---------------------------------------------------------------------------
for pkg in linux-zen linux-zen-headers linux linux-headers; do
    if grep -qxF "$pkg" "$base_txt"; then
        _ok "K1_base_has_$pkg"
    else
        _fail "K1_base_has_$pkg" "missing from packages/official/base.txt"
    fi
done

# ---------------------------------------------------------------------------
# K2: shedos-kernel is fully retired — no package tree, no build-order entry,
#     no meta-depends entry. (The shedos-system retirement one-shot may still
#     name it; we only scan the build/package-set wiring here.)
# ---------------------------------------------------------------------------
if [[ -e $repo_root/packaging/shedos-kernel ]]; then
    _fail K2_package_deleted "packaging/shedos-kernel/ still exists"
else
    _ok K2_package_deleted
fi
if grep -q 'shedos-kernel' "$build_script"; then
    _fail K2_build_clean "shedos-kernel still referenced in $build_script"
else
    _ok K2_build_clean
fi
if grep -q 'shedos-kernel' "$meta_render"; then
    _fail K2_meta_clean "shedos-kernel still referenced in $meta_render"
else
    _ok K2_meta_clean
fi

# ---------------------------------------------------------------------------
# K3: the fallback kernel can actually install — stock linux must NOT be
#     conflicted by shedos-meta (it was, while shedos-kernel was the only
#     kernel we shipped).
# ---------------------------------------------------------------------------
if awk '/^shedos_conflicts=\(/{c=1;next} /^\)/{c=0} c' "$meta_render" \
        | grep -qE "^[[:space:]]*'?linux'?[[:space:]]*$"; then
    _fail K3_linux_not_conflicted "stock linux is still in shedos_conflicts"
else
    _ok K3_linux_not_conflicted
fi

# ---------------------------------------------------------------------------
# K4: ShedOS ships a linux-zen.preset forcing BOTH default + fallback images.
#     mkinitcpio's stock template is default-only, so without this the limine
#     "(Fallback)" recovery entry would have no initramfs to load.
# ---------------------------------------------------------------------------
if [[ -f $preset ]] && grep -qF "PRESETS=('default' 'fallback')" "$preset"; then
    _ok K4_preset_enables_fallback
else
    _fail K4_preset_enables_fallback "linux-zen.preset missing or not enabling the fallback preset"
fi

# ---------------------------------------------------------------------------
# K5: functional — the limine renderer makes linux-zen the default entry,
#     labels stock linux as "(stock)", and omits a recovery entry for a
#     kernel whose fallback initramfs doesn't exist (default-only preset).
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
mkdir -p "$tmp/modules/9.9-zen" "$tmp/modules/9.9-stock" "$tmp/boot"
echo linux-zen > "$tmp/modules/9.9-zen/pkgbase"
echo linux     > "$tmp/modules/9.9-stock/pkgbase"
: > "$tmp/boot/initramfs-linux-zen.img"
: > "$tmp/boot/initramfs-linux-zen-fallback.img"
: > "$tmp/boot/initramfs-linux.img"   # default only; no -fallback
SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" \
SHEDOS_BOOT_DIR="$tmp/boot" SHEDOS_MODULES_DIR="$tmp/modules" \
    bash "$renderer" >/dev/null 2>&1
conf=$tmp/boot/limine.conf

# linux-zen entry comes first (the default), labelled "ShedOS Linux".
if [[ -f $conf ]] && [[ "$(grep -m1 '^/' "$conf")" == "/ShedOS Linux" ]] \
   && grep -q 'vmlinuz-linux-zen' "$conf"; then
    _ok K5_default_is_linux_zen
else
    _fail K5_default_is_linux_zen "linux-zen is not the first/default limine entry"
fi
# linux-zen keeps its recovery entry (its fallback initramfs exists)...
if grep -qF '/ShedOS Linux (Fallback)' "$conf"; then
    _ok K5_linux_zen_has_fallback
else
    _fail K5_linux_zen_has_fallback "linux-zen recovery entry missing"
fi
# ...stock linux is present but its recovery entry is omitted (no initramfs).
if grep -qF '/ShedOS Linux (stock)' "$conf" \
   && ! grep -qF '/ShedOS Linux (stock) (Fallback)' "$conf"; then
    _ok K5_stock_fallback_omitted
else
    _fail K5_stock_fallback_omitted "stock linux entry wrong, or a dead fallback entry was emitted"
fi
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$((pass + fail))
echo
echo "kernel wiring: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
