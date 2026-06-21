#!/usr/bin/env bash
# Build and place the signed recovery Unified Kernel Image at
# /EFI/Linux/shedos-recovery.efi — a verbose-cmdline image reachable as its own
# Limine entry (and its own firmware boot entry). Built directly with ukify so
# uki.conf signs it the same way kernel-transaction UKIs are signed, then placed
# with the shared atomic discipline. Run at install and on every kernel
# transaction, so the recovery image tracks the current kernel; it covers a
# broken limine.conf or a damaged primary UKI, not a bad kernel (the initrd
# auto-rollback handles that). Degrades to unsigned on a non-Secure-Boot box.
set -uo pipefail

BOOT_DIR=${SHEDOS_BOOT_DIR:-/boot}
# shellcheck disable=SC2034  # read by the sourced uki-place.sh (_place)
DB_CERT=${SHEDOS_DB_CERT:-/var/lib/sbctl/keys/db/db.pem}
UKI_CONF=${SHEDOS_UKI_CONF:-/etc/kernel/uki.conf}
KERNEL=${SHEDOS_RECOVERY_KERNEL:-$BOOT_DIR/vmlinuz-linux-zen}
INITRD=${SHEDOS_RECOVERY_INITRD:-$BOOT_DIR/initramfs-linux-zen-fallback.img}
CMDLINE_FILE=${SHEDOS_RECOVERY_CMDLINE_FILE:-/etc/kernel/cmdline-fallback}
STAGE=$BOOT_DIR/shedos-recovery.efi

# DB_CERT, _place, _esp_dirs are consumed by the sourced library.
# shellcheck source=uki-place.sh
source "${SHEDOS_UKI_PLACE_LIB:-/usr/lib/shedos/uki-place.sh}"

if [[ ! -r $KERNEL || ! -r $INITRD ]]; then
    echo "build-recovery-uki: kernel or recovery initramfs missing — skipping" >&2
    exit 0
fi
if grep -qE '^[^#]*\bSHEDOS_PLACEHOLDER_CMDLINE\b' "$CMDLINE_FILE" 2>/dev/null; then
    echo "build-recovery-uki: cmdline is still the unwritten placeholder — refusing to build" >&2
    exit 1
fi

cmdline=$(grep -haE '^[^#]' "$CMDLINE_FILE" | tr -s '\n' ' ')
ukify_args=(build --linux="$KERNEL" --initrd="$INITRD" --cmdline="$cmdline" --output="$STAGE")
[[ -f $UKI_CONF ]] && ukify_args+=(--config="$UKI_CONF")

if ! ukify "${ukify_args[@]}" >/dev/null 2>&1; then
    echo "build-recovery-uki: building the recovery boot image failed" >&2
    exit 1
fi

mapfile -t esp_dirs < <(_esp_dirs)
if (( ${#esp_dirs[@]} == 0 )); then
    echo "build-recovery-uki: no ESP with a limine config found — nothing to place" >&2
    rm -f -- "$STAGE"; exit 0
fi

failed=0
for d in "${esp_dirs[@]}"; do
    if _place "$STAGE" "$d/EFI/Linux/shedos-recovery.efi"; then
        echo "build-recovery-uki: placed shedos-recovery.efi on $d"
    else
        failed=1
    fi
done
rm -f -- "$STAGE"
(( failed )) && { echo "build-recovery-uki: ERROR: recovery image placement failed (see above)." >&2; exit 1; }
exit 0

# vim: set ft=sh ts=4 sw=4 et:
