#!/bin/bash
# Boot-failure auto-recovery. Runs inside the systemd initrd, after
# the root device exists (LUKS already open), before sysroot.mount.
#
# Every boot increments a counter on the btrfs top level; the
# boot-success unit (shedos-boot-success.service) resets it once the
# greeter is up. When THRESHOLD consecutive boots never got that far,
# this script clones the newest snapper snapshot to a writable
# @recovery-* subvolume and redirects sysroot.mount onto it via a
# runtime drop-in — the machine comes up on the last-good system and
# the desktop explains what happened (marker in /etc/shedos/).
#
# FAIL-OPEN BY DESIGN: any unexpected condition leaves the normal
# boot untouched. Recovering wrongly is worse than not recovering.
set -u

THRESHOLD=3
MNT=/run/shedos-toplevel

_root_device() {
    # root= from the kernel cmdline; the mapper path for LUKS roots.
    local tok
    for tok in $(< /proc/cmdline); do
        case $tok in
            root=UUID=*) echo "/dev/disk/by-uuid/${tok#root=UUID=}"; return ;;
            root=*)      echo "${tok#root=}"; return ;;
        esac
    done
}

main() {
    local dev
    dev=$(_root_device) || return 0
    [[ -n $dev && -e $dev ]] || return 0

    mkdir -p "$MNT"
    mount -t btrfs -o subvolid=5,rw "$dev" "$MNT" 2>/dev/null || return 0
    # Everything past here must umount on the way out.

    local count=0 counter="$MNT/.shedos-bootcount"
    [[ -f $counter ]] && count=$(tr -dc '0-9' < "$counter" | head -c 4)
    count=$(( ${count:-0} + 1 ))
    printf '%s\n' "$count" > "$counter" 2>/dev/null

    if (( count < THRESHOLD )); then
        umount "$MNT"; return 0
    fi

    # Threshold hit: find the newest snapper snapshot of root.
    local newest="" n best=0
    for d in "$MNT"/@snapshots/*/snapshot; do
        [[ -d $d ]] || continue
        n=${d#"$MNT"/@snapshots/}; n=${n%%/*}
        [[ $n =~ ^[0-9]+$ ]] || continue
        if (( n > best )); then best=$n; newest=$d; fi
    done
    if [[ -z $newest ]]; then
        umount "$MNT"; return 0
    fi

    local clone
    clone="@recovery-$(date +%Y%m%d-%H%M%S)"
    if ! btrfs subvolume snapshot "$newest" "$MNT/$clone" >/dev/null 2>&1; then
        umount "$MNT"; return 0
    fi

    # Tell the booted system what happened (the clone is writable).
    mkdir -p "$MNT/$clone/etc/shedos"
    printf 'snapshot=%s\nclone=%s\nfailed_boots=%s\n' \
        "$best" "$clone" "$count" > "$MNT/$clone/etc/shedos/recovered-from"
    # Give the next cycle a fresh start; success on the clone resets
    # normally, and repeated failure on the clone re-recovers from the
    # same snapshot rather than looping on a broken @.
    printf '0\n' > "$counter"
    umount "$MNT"

    # Redirect sysroot onto the clone. systemd-fstab-generator built
    # sysroot.mount from root=/rootflags=; a runtime drop-in overrides
    # just the subvolume.
    mkdir -p /run/systemd/system/sysroot.mount.d
    cat > /run/systemd/system/sysroot.mount.d/50-shedos-recovery.conf <<DROPIN
[Mount]
Options=subvol=/$clone,rw
DROPIN
    systemctl daemon-reload
    echo "shedos-recovery: $count failed boots — booting snapshot #$best (as $clone)" \
        > /dev/kmsg 2>/dev/null || true
    return 0
}

main
exit 0
