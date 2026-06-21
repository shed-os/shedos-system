#!/usr/bin/env bash
# Build (where needed) and place every installed kernel's Unified Kernel Image
# onto the ESP's /EFI/Linux/, for Limine to efi_chainload. linux-zen's UKI (with
# a verbose fallback) comes from its preset, which mkinitcpio -P stages. Every
# other installed kernel — stock linux, the worst-case fallback kernel — has no
# UKI preset (shipping one would collide with mkinitcpio's auto-generated,
# unowned preset and abort the upgrade), so we build it here directly with
# comprehensive modules and the same signing pass via uki.conf, making it a real
# Secure-Boot different-kernel fallback. Atomic, fail-loud, space-aware via the
# shared uki-place.sh.
#
#   build-uki.sh             place staged UKIs + build any missing/stale ones
#   build-uki.sh --rebuild   force a full rebuild first (a caller changed the
#                            cmdline: the apply reconciler, the backfill, recover-esp)
#
# Degrades on a non-Secure-Boot box (no db cert): places the unsigned UKI and
# skips the signature check; never bricks the box.
set -uo pipefail

BOOT_DIR=${SHEDOS_BOOT_DIR:-/boot}
MODULES_DIR=${SHEDOS_MODULES_DIR:-/usr/lib/modules}
PRESET_DIR=${SHEDOS_PRESET_DIR:-/etc/mkinitcpio.d}
# shellcheck disable=SC2034  # read by the sourced uki-place.sh (_place)
DB_CERT=${SHEDOS_DB_CERT:-/var/lib/sbctl/keys/db/db.pem}
CMDLINE_FILE=${SHEDOS_KERNEL_CMDLINE_FILE:-/etc/kernel/cmdline}
UKI_CONF=${SHEDOS_UKI_CONF:-/etc/kernel/uki.conf}

# DB_CERT, _place, _esp_dirs are consumed by the sourced library.
# shellcheck source=uki-place.sh
source "${SHEDOS_UKI_PLACE_LIB:-/usr/lib/shedos/uki-place.sh}"

# Installed kernels, by pkgbase (mkinitcpio convention).
mapfile -t pkgbases < <(
    for f in "$MODULES_DIR"/*/pkgbase; do [[ -r $f ]] && cat "$f"; done | sort -u
)

# Map a pkgbase to its kernel version (the modules dir name) for mkinitcpio -k.
_kver_for() {
    local k=$1 d
    for d in "$MODULES_DIR"/*/; do
        [[ -r ${d}pkgbase && "$(cat "${d}pkgbase")" == "$k" ]] && { basename -- "$d"; return; }
    done
}
# Does this pkgbase have a preset that already stages a UKI (linux-zen)?
_has_preset_uki() {
    local p=$PRESET_DIR/$1.preset
    [[ -f $p ]] && grep -qE '^[[:space:]]*default_uki=' "$p"
}
# Is pkgbase $1's staged default UKI missing or older than any input that feeds
# it? A microcode-only upgrade does NOT fire the stock mkinitcpio hook, so the
# UKI would otherwise ship stale microcode. Errs toward rebuilding.
_stale() {
    local k=$1 efi=$BOOT_DIR/shedos-$1.efi input
    [[ -f $efi ]] || return 0
    for input in "/boot/vmlinuz-$k" "$BOOT_DIR/initramfs-$k.img" "$BOOT_DIR/initramfs-$k-fallback.img" \
                 "$CMDLINE_FILE" /boot/intel-ucode.img /boot/amd-ucode.img; do
        [[ -e $input && $input -nt $efi ]] && return 0
    done
    return 1
}

# A placeholder cmdline means the installer hasn't written the real one yet; its
# UKI would be unbootable. sbverify checks the signature, not the cmdline, so a
# signed placeholder would pass and clobber a good image — guard before building.
if grep -qE '^[^#]*\bSHEDOS_PLACEHOLDER_CMDLINE\b' "$CMDLINE_FILE" 2>/dev/null; then
    echo "build-uki: cmdline is still the unwritten placeholder — refusing to build/place a UKI" >&2
    exit 1
fi

force=""; [[ ${1:-} == --rebuild ]] && force=1

if [[ -z ${SHEDOS_UKI_NO_REBUILD:-} ]]; then
    # Preset UKIs (linux-zen + its fallback) are staged by mkinitcpio -P. Rebuild
    # when forced or any preset kernel's staged UKI is stale (the stock hook
    # already rebuilt on a kernel txn, so the common path is a no-op here).
    _preset_rebuild=""
    for k in "${pkgbases[@]}"; do
        _has_preset_uki "$k" || continue
        if [[ -n $force ]] || _stale "$k"; then _preset_rebuild=1; break; fi
    done
    if [[ -n $_preset_rebuild ]]; then
        if ! mkinitcpio -P; then
            echo "build-uki: mkinitcpio -P failed — not placing a stale image" >&2
            exit 1
        fi
    fi
    # Non-preset kernels (stock linux): build a comprehensive UKI directly when
    # forced, missing, or stale. -S autodetect bundles every module so a kernel
    # built while linux-zen runs still boots itself (the cross-kernel root-driver
    # trap, #156). uki.conf does the signing.
    for k in "${pkgbases[@]}"; do
        _has_preset_uki "$k" && continue
        [[ -r /boot/vmlinuz-$k ]] || continue
        if [[ -z $force ]] && ! _stale "$k"; then continue; fi
        kver=$(_kver_for "$k")
        [[ -n $kver ]] || continue
        ukargs=(-U "$BOOT_DIR/shedos-$k.efi" -k "$kver" --cmdline "$CMDLINE_FILE" -S autodetect)
        [[ -f $UKI_CONF ]] && ukargs+=(--ukiconfig "$UKI_CONF")
        if ! mkinitcpio "${ukargs[@]}"; then
            echo "build-uki: building the $k unified kernel image failed" >&2
            exit 1
        fi
    done
fi

mapfile -t esp_dirs < <(_esp_dirs)
if (( ${#esp_dirs[@]} == 0 )); then
    # Fresh install before the ESP layout exists; nothing to place yet.
    echo "build-uki: no ESP with a limine config found — nothing to place" >&2
    exit 0
fi

failed=0
for k in "${pkgbases[@]}"; do
    for variant in "" "-fallback"; do
        src=$BOOT_DIR/shedos-$k$variant.efi
        [[ -f $src ]] || continue
        for d in "${esp_dirs[@]}"; do
            if _place "$src" "$d/EFI/Linux/shedos-$k$variant.efi"; then
                echo "build-uki: placed shedos-$k$variant.efi on $d"
            else
                failed=1
            fi
        done
    done
done

if (( failed )); then
    echo "build-uki: ERROR: one or more UKI placements failed (see the FATAL lines above). The system still boots the images that ARE present. Free ESP space and re-run: sudo /usr/lib/shedos/build-uki.sh" >&2
    exit 1
fi

# vim: set ft=sh ts=4 sw=4 et:
