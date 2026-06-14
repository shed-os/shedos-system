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
# SCOPE: this catches boots that reach the initrd but never reach the
# greeter — a broken userspace, a failed graphical target. It CANNOT
# catch a panic before the counter runs: a Limine error (a missing or
# truncated image on the ESP) or a kernel that can't mount root never
# gets here, so those never increment and never roll back. Keeping the
# ESP images intact (render-limine-config.sh) and the root driver in the
# initramfs (linux-zen.preset) is what guards that earlier failure class.
#
# It also can't help an fstab emergency: every snapshot carries the same
# /etc/fstab, so a missing-disk mount lands the rollback in the same
# emergency. That class is handled instead by nofail-by-default (apply +
# installer), the `shedman doctor` audit, and the guided emergency screen
# (emergency-recovery). See docs/boot-safety.md.
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

    local count=0 counter="$MNT/.shedos-bootcount" raw=""
    [[ -f $counter ]] && raw=$(< "$counter")
    raw=${raw//[!0-9]/}          # digits only — no `tr` in the initrd
    count=${raw:0:4}             # cap the width — no `head` in the initrd
    count=$(( 10#${count:-0} + 1 ))   # 10# so a leading zero isn't read as octal
    if ! printf '%s\n' "$count" > "$counter" 2>/dev/null; then
        echo "shedos-recovery: WARNING: cannot write $counter — auto-rollback can't track failed boots" \
            > /dev/kmsg 2>/dev/null || true
    fi

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

    # printf's strftime builtin — no `date` in the initrd.
    local clone ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    clone="@recovery-$ts"
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
    # printf, not a `cat` heredoc — keep the initrd dep surface to bash.
    printf '[Mount]\nOptions=subvol=/%s,rw\n' "$clone" \
        > /run/systemd/system/sysroot.mount.d/50-shedos-recovery.conf
    systemctl daemon-reload
    echo "shedos-recovery: $count failed boots — booting snapshot #$best (as $clone)" \
        > /dev/kmsg 2>/dev/null || true
    return 0
}

main
exit 0
