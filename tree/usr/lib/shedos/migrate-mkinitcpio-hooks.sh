#!/bin/bash
# Rewrite the legacy `udev`+`keymap`+`consolefont` HOOKS line to the
# systemd-based form. The legacy `keymap` hook bakes a keymap.bin in
# BusyBox's format, which kbd's current `loadkeys -b` output no longer
# matches — boot fails with "loadkmap: short read" → emergency mode.
# Idempotent; backs up the original to .shedos-pre-migration.

set -euo pipefail

conf=/etc/mkinitcpio.conf
[[ -f $conf ]] || exit 0

hooks_line=$(grep -E '^HOOKS=' "$conf" | head -1 || true)
[[ -n $hooks_line ]] || exit 0

# Idempotent regardless of udev/systemd style: the auto-recovery hook
# slots in before filesystems so the counter runs ahead of sysroot.
if [[ $hooks_line != *shedos-recovery* ]]; then
    sed -i -E '/^HOOKS=/ s/\bfilesystems\b/shedos-recovery filesystems/' "$conf"
    echo "shedos: added shedos-recovery to mkinitcpio HOOKS" >&2
    hooks_line=$(grep -E '^HOOKS=' "$conf" | head -1 || true)
fi

if [[ $hooks_line == *systemd* && $hooks_line == *sd-vconsole* ]]; then
    exit 0
fi

# Both space- and paren-delimited forms: a hook sitting at the end of
# the list reads `keymap)` and the space-only patterns missed it.
case " $hooks_line " in
    *' udev '*|*'(udev '*|*' udev)'*|\
    *' keymap '*|*'(keymap '*|*' keymap)'*|\
    *' consolefont '*|*'(consolefont '*|*' consolefont)'*) ;;
    *) exit 0 ;;
esac

cp -a "$conf" "${conf}.shedos-pre-migration"

sed -i -E '
    /^HOOKS=/ {
        s/\budev\b/systemd/
        s/\bkeymap\b/sd-vconsole/
        s/[[:space:]]+consolefont\b//
        s/\bconsolefont[[:space:]]+//
        s/  +/ /g
        s/\([[:space:]]+/(/
        s/[[:space:]]+\)/)/
    }
' "$conf"

echo "shedos: migrated /etc/mkinitcpio.conf HOOKS to systemd + sd-vconsole" >&2
echo "shedos: backup at ${conf}.shedos-pre-migration" >&2
