#!/bin/bash
# Recover a ShedOS box whose ESP overflowed and bricked the default
# kernel — Limine panicking "fread: attempted out of bounds read", or the
# kernel panicking "VFS: Unable to mount root". The ESP is the small FAT
# volume Limine boots vmlinuz+initramfs from; a too-large initramfs got
# silently truncated onto it.
#
# Run from a chroot into the affected install: boot the ShedOS live ISO,
# mount the root and the ESP at /mnt and /mnt/boot/efi, arch-chroot /mnt,
# then run this. It clears the ESP, rebuilds the (now firmware-slim)
# initramfs, re-syncs, and verifies every ESP image byte-for-byte against
# /boot before declaring success. Idempotent.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "recover-esp: must run as root (inside an arch-chroot of the affected install)" >&2
    exit 1
fi

conf=/etc/mkinitcpio.conf
hooks=$(grep -E '^HOOKS=' "$conf" 2>/dev/null || true)
if [[ " $hooks " == *' kms '* ]]; then
    echo "recover-esp: the 'kms' hook is still in HOOKS, so the initramfs would rebuild too large to fit the ESP." >&2
    echo "recover-esp: update shedos-system first (it drops kms): pacman -Syu  — then re-run this." >&2
    exit 1
fi

# The ESP dirs Limine boots from are the ones holding a limine config.
esp_dirs=()
for d in /boot/efi /efi; do
    [[ -f $d/limine.conf || -f $d/EFI/limine/limine.conf ]] && esp_dirs+=("$d")
done
if (( ${#esp_dirs[@]} == 0 )); then
    echo "recover-esp: no ESP with a limine config found under /boot/efi or /efi." >&2
    echo "recover-esp: is the ESP mounted at /boot/efi inside the chroot?" >&2
    exit 1
fi

echo "recover-esp: clearing stale kernel images off the ESP(s): ${esp_dirs[*]}"
# Safe: the authoritative kernels live on btrfs /boot (which Limine can't
# read); render-limine-config.sh re-creates the ESP copies below, and the
# cmp pass proves they landed intact before any reboot.
for d in "${esp_dirs[@]}"; do
    rm -f -- "$d"/vmlinuz-* "$d"/initramfs-*.img
done

echo "recover-esp: rebuilding every kernel's initramfs (slim)..."
/usr/lib/shedos/rebuild-initramfs.sh

echo "recover-esp: re-rendering Limine config and re-syncing the ESP..."
/usr/lib/shedos/render-limine-config.sh

echo "recover-esp: verifying every ESP image matches /boot..."
fail=0
for d in "${esp_dirs[@]}"; do
    for img in "$d"/vmlinuz-* "$d"/initramfs-*.img; do
        [[ -e $img ]] || continue
        base=${img##*/}
        if cmp -s -- "/boot/$base" "$img"; then
            echo "  OK   $base"
        else
            echo "  FAIL $base (ESP copy differs from /boot)" >&2
            fail=1
        fi
    done
done

if (( fail )); then
    echo "recover-esp: some images failed verification — the ESP may still be too small. Retire an old kernel to free space and re-run." >&2
    exit 1
fi

echo "recover-esp: done. Reboot and pick 'ShedOS Linux' (linux-zen) at the menu. Once it boots cleanly you can retire the old kernel to reclaim its space."
