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

# LUKS first: the classic `encrypt` hook is busybox-runtime and never
# runs under the systemd initrd, and its replacement (sd-encrypt)
# reads rd.luks.* tokens, not cryptdevice=. The cmdline translation
# MUST land in the same transaction as the HOOKS change — a reboot
# between the two would stop the root from unlocking. cryptdevice=
# stays alongside (each initrd style ignores the other's token).
if [[ $hooks_line == *encrypt* && $hooks_line != *sd-encrypt* ]]; then
    limine_conf=/boot/limine.conf
    cryptline=$(grep -m1 -oE 'cryptdevice=[^ ]+' "$limine_conf" 2>/dev/null || true)
    if [[ -z $cryptline ]]; then
        echo "shedos: LUKS hook present but no cryptdevice= found in $limine_conf;" >&2
        echo "shedos: refusing to migrate HOOKS (manual conversion needed)" >&2
        exit 0
    fi
    spec=${cryptline#cryptdevice=}            # UUID=x:name[:options]
    uuid=${spec%%:*}; uuid=${uuid#UUID=}
    rest=${spec#*:}; name=${rest%%:*}
    rdluks="rd.luks.name=${uuid}=${name}"
    [[ $spec == *:allow-discards* ]] && rdluks="$rdluks rd.luks.options=discard"
    if ! grep -q 'rd\.luks\.name=' "$limine_conf"; then
        cp -a "$limine_conf" "${limine_conf}.shedos-pre-migration"
        sed -i "s|cryptdevice=|${rdluks} cryptdevice=|" "$limine_conf"
        echo "shedos: added ${rdluks} to $limine_conf for sd-encrypt" >&2
    fi
fi

sed -i -E '
    /^HOOKS=/ {
        s/\budev\b/systemd/
        s/\bkeymap\b/sd-vconsole/
        s/\bencrypt\b/sd-encrypt/
        s/[[:space:]]+consolefont\b//
        s/\bconsolefont[[:space:]]+//
        s/  +/ /g
        s/\([[:space:]]+/(/
        s/[[:space:]]+\)/)/
    }
' "$conf"

echo "shedos: migrated /etc/mkinitcpio.conf HOOKS to systemd + sd-vconsole" >&2
echo "shedos: backup at ${conf}.shedos-pre-migration" >&2
