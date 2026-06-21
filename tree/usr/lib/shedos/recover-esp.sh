#!/bin/bash
# Recover a ShedOS box whose ESP overflowed and bricked the default kernel —
# Limine panicking "fread: attempted out of bounds read", or the firmware
# rejecting an unsigned/truncated image at the Secure Boot gate. ShedOS
# chainloads a signed UKI (kernel + initramfs + cmdline in one PE binary) from
# /EFI/Linux/shedos-<pkgbase>.efi on the FAT ESP; a too-large UKI got silently
# truncated onto it.
#
# Run from a chroot into the affected install: boot the ShedOS live ISO, mount
# the root and the ESP at /mnt and /mnt/boot/efi, arch-chroot /mnt, then run
# this. It prunes UKIs for retired kernels, rebuilds + re-signs every live
# kernel's UKI, and verifies each one against the box's Secure Boot key (when
# the box has one) before declaring success. Idempotent.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "recover-esp: must run as root (inside an arch-chroot of the affected install)" >&2
    exit 1
fi

db_cert=${SHEDOS_DB_CERT:-/var/lib/sbctl/keys/db/db.pem}

# The ESP dirs Limine boots from are the ones holding a limine config.
esp_dirs=()
read -r -a _esp_candidates <<< "${SHEDOS_ESP_DIRS:-/boot/efi /efi}"
for d in "${_esp_candidates[@]}"; do
    [[ -f $d/limine.conf || -f $d/EFI/limine/limine.conf ]] && esp_dirs+=("$d")
done
if (( ${#esp_dirs[@]} == 0 )); then
    echo "recover-esp: no ESP with a limine config found under ${_esp_candidates[*]}." >&2
    echo "recover-esp: is the ESP mounted at /boot/efi inside the chroot?" >&2
    exit 1
fi

# Prune UKIs for kernels no longer installed so the FAT volume has room for the
# live set. build-uki.sh keeps the current set's prior copy until its
# replacement verifies, so we only reap the orphans here.
mapfile -t live_pkgbases < <(
    for f in /usr/lib/modules/*/pkgbase; do [[ -r $f ]] && cat "$f"; done | sort -u
)
echo "recover-esp: pruning stale UKIs off the ESP(s): ${esp_dirs[*]}"
for d in "${esp_dirs[@]}"; do
    for uki in "$d"/EFI/Linux/shedos-*.efi; do
        [[ -e $uki ]] || continue
        base=${uki##*/}; k=${base#shedos-}; k=${k%.efi}; k=${k%-fallback}
        [[ $k == recovery ]] && continue   # the pinned recovery UKI is not a pkgbase
        keep=0
        for pb in "${live_pkgbases[@]}"; do [[ $pb == "$k" ]] && keep=1; done
        (( keep )) || { rm -f -- "$uki" && echo "  pruned $base from $d"; }
    done
done

echo "recover-esp: rebuilding + re-signing every kernel's UKI..."
/usr/lib/shedos/build-uki.sh --rebuild \
    || { echo "recover-esp: UKI rebuild/placement failed — aborting before reboot" >&2; exit 1; }
# The pinned recovery UKI is supplementary; never fail the recovery if a tight
# ESP can't also hold it — the per-kernel UKIs above are what boots the menu.
if [[ -x /usr/lib/shedos/build-recovery-uki.sh ]]; then
    /usr/lib/shedos/build-recovery-uki.sh || \
        echo "recover-esp: recovery UKI did not fit (non-fatal); the kernel menu still boots" >&2
fi

echo "recover-esp: re-rendering Limine config..."
/usr/lib/shedos/render-limine-config.sh \
    || { echo "recover-esp: Limine re-render failed — aborting before reboot" >&2; exit 1; }

echo "recover-esp: verifying every placed UKI against the box Secure Boot key..."
fail=0
checked=0
for d in "${esp_dirs[@]}"; do
    for uki in "$d"/EFI/Linux/shedos-*.efi; do
        [[ -e $uki ]] || continue
        checked=$((checked + 1))
        base=${uki##*/}
        # On a Secure Boot box the UKI must verify against the box db cert; with
        # SB off there is no db cert and an intact placed UKI is enough
        # (build-uki already byte-verified the copy).
        if [[ -f $db_cert ]]; then
            if sbverify --cert "$db_cert" "$uki" >/dev/null 2>&1; then
                echo "  OK   $base (signature verified)"
            else
                echo "  FAIL $base (signature does not verify)" >&2
                fail=1
            fi
        else
            echo "  OK   $base (Secure Boot off; signature check skipped)"
        fi
    done
done

# A prune that left nothing to verify is failure, not success — the rebuild
# placed no UKI and the box would reboot into the same brick.
if (( checked == 0 )); then
    echo "recover-esp: no UKI landed on the ESP — it is still too small. Retire an old kernel to free space and re-run." >&2
    exit 1
fi
if (( fail )); then
    echo "recover-esp: some UKIs failed verification — the ESP may still be too small, or the box Secure Boot key is missing. Retire an old kernel to free space and re-run." >&2
    exit 1
fi

echo "recover-esp: done. Reboot and pick 'ShedOS Linux' (linux-zen) at the menu. Once it boots cleanly you can retire the old kernel to reclaim its space."
