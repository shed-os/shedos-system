#!/bin/bash
# Reset the boot-failure counter shedos-initrd-recovery.sh increments.
set -u
MNT=/run/shedos-toplevel-reset
dev=$(findmnt -no SOURCE / | sed 's/\[.*//') || exit 0
[[ -n $dev ]] || exit 0
mkdir -p "$MNT"
mount -t btrfs -o subvolid=5,rw "$dev" "$MNT" 2>/dev/null || exit 0
printf '0\n' > "$MNT/.shedos-bootcount" 2>/dev/null
umount "$MNT"
rmdir "$MNT" 2>/dev/null
exit 0
