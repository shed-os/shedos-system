#!/usr/bin/env bash
# Place the staged Unified Kernel Images (built + signed by mkinitcpio from the
# linux-zen preset) onto the ESP's /EFI/Linux/ — the only place Limine's
# efi_chainload can read them. This is a PLACER, not a signer: uki.conf drives
# the one signing pass at build time. Atomic, fail-loud, space-aware via the
# shared uki-place.sh.
#
#   build-uki.sh             place the already-staged UKIs (the 94 hook path,
#                            after the stock mkinitcpio hook has run -P)
#   build-uki.sh --rebuild   run `mkinitcpio -P linux-zen` first, then place —
#                            for callers that changed /etc/kernel/cmdline (the
#                            apply reconciler, the cmdline backfill, recover-esp)
#                            and need the UKI rebuilt before it is placed
#
# Degrades on a non-Secure-Boot box (no db cert): places the unsigned UKI and
# skips the signature check; never bricks the box.
set -uo pipefail

BOOT_DIR=${SHEDOS_BOOT_DIR:-/boot}
# shellcheck disable=SC2034  # read by the sourced uki-place.sh (_place)
DB_CERT=${SHEDOS_DB_CERT:-/var/lib/sbctl/keys/db/db.pem}
CMDLINE_FILE=${SHEDOS_KERNEL_CMDLINE_FILE:-/etc/kernel/cmdline}
PKGBASE=linux-zen   # the only kernel built as a UKI; stock linux stays raw

# DB_CERT, _place, _esp_dirs are consumed by the sourced library.
# shellcheck source=uki-place.sh
source "${SHEDOS_UKI_PLACE_LIB:-/usr/lib/shedos/uki-place.sh}"

# Is the staged default UKI missing or older than any input that feeds it? A
# microcode-only upgrade does NOT trigger the stock mkinitcpio hook, so without
# this the UKI would ship stale CPU microcode (it is bundled into the initramfs
# now, not loaded as a separate image). Errs toward rebuilding.
_staged_stale() {
    local efi=$BOOT_DIR/shedos-$PKGBASE.efi input
    [[ -f $efi ]] || return 0
    for input in "/boot/vmlinuz-$PKGBASE" "$BOOT_DIR/initramfs-$PKGBASE.img" \
                 "$CMDLINE_FILE" /boot/intel-ucode.img /boot/amd-ucode.img; do
        [[ -e $input && $input -nt $efi ]] && return 0
    done
    return 1
}

# Rebuild the staged UKI when forced (a caller changed the cmdline) or when it
# is stale. The 94 hook calls us bare: on a kernel transaction the stock hook
# already rebuilt (fresh, no rebuild here); on a ucode-only one it didn't
# (stale, we rebuild). SHEDOS_UKI_NO_REBUILD keeps the placer tests offline.
if [[ -z ${SHEDOS_UKI_NO_REBUILD:-} ]] && { [[ ${1:-} == --rebuild ]] || _staged_stale; }; then
    if ! mkinitcpio -P "$PKGBASE"; then
        echo "build-uki: mkinitcpio -P $PKGBASE failed — not placing a stale image" >&2
        exit 1
    fi
fi

# A placeholder cmdline means the installer hasn't written the real one yet;
# its UKI is unbootable. sbverify checks the signature, not the cmdline, so a
# signed placeholder would pass and clobber a good image — guard here instead.
if grep -qE '^[^#]*\bSHEDOS_PLACEHOLDER_CMDLINE\b' "$CMDLINE_FILE" 2>/dev/null; then
    echo "build-uki: cmdline is still the unwritten placeholder — refusing to place a UKI" >&2
    exit 1
fi

mapfile -t esp_dirs < <(_esp_dirs)
if (( ${#esp_dirs[@]} == 0 )); then
    # Fresh install before the ESP layout exists; nothing to place yet.
    echo "build-uki: no ESP with a limine config found — nothing to place" >&2
    exit 0
fi

failed=0
for variant in "" "-fallback"; do
    src=$BOOT_DIR/shedos-$PKGBASE$variant.efi
    [[ -f $src ]] || continue
    for d in "${esp_dirs[@]}"; do
        if _place "$src" "$d/EFI/Linux/shedos-$PKGBASE$variant.efi"; then
            echo "build-uki: placed shedos-$PKGBASE$variant.efi on $d"
        else
            failed=1
        fi
    done
done

if (( failed )); then
    echo "build-uki: ERROR: one or more UKI placements failed (see the FATAL lines above). The system still boots the images that ARE present. Free ESP space and re-run: sudo /usr/lib/shedos/build-uki.sh" >&2
    exit 1
fi

# vim: set ft=sh ts=4 sw=4 et:
