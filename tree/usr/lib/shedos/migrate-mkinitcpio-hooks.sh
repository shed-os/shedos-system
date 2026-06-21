#!/bin/bash
# Rewrite the legacy `udev`+`keymap`+`consolefont` HOOKS line to the
# systemd-based form. The legacy `keymap` hook bakes a keymap.bin in
# BusyBox's format, which kbd's current `loadkeys -b` output no longer
# matches — boot fails with "loadkmap: short read" → emergency mode.
# Idempotent; backs up the original to .shedos-pre-migration.

set -euo pipefail

conf=${SHEDOS_MKINITCPIO_CONF:-/etc/mkinitcpio.conf}
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

# linux-zen ships GPU drivers as modules; the kms hook then drags every
# DRM driver's firmware — ~145 MiB of NVIDIA GSP and friends — into the
# initramfs, overflowing the FAT ESP Limine boots from. Drop it: the
# splash falls to the builtin simpledrm framebuffer and the GPU driver
# loads from the root fs after mount. Proprietary-NVIDIA early KMS is
# unaffected (it rides MODULES=, not this hook). Runs independently of
# the systemd migration below, so it also fires on already-systemd boxes.
if [[ " $hooks_line " == *' kms '* ]]; then
    [[ -e "${conf}.shedos-pre-migration" ]] || cp -a "$conf" "${conf}.shedos-pre-migration"
    sed -i -E '/^HOOKS=/ { s/[[:space:]]+kms\b//; s/\bkms[[:space:]]+//; s/  +/ /g }' "$conf"
    mkdir -p /var/lib/shedos
    : > /var/lib/shedos/.mkinitcpio-regen-needed
    echo "shedos: removed kms from mkinitcpio HOOKS (firmware-slim initramfs)" >&2
    hooks_line=$(grep -E '^HOOKS=' "$conf" | head -1 || true)
fi

# A Unified Kernel Image is one signed file, so CPU microcode can no longer
# ride as a separate Limine module — it has to be bundled into the initramfs
# via the `microcode` hook. Insert it before `block` (it must precede the
# rootfs setup). Runs on already-systemd boxes too, so it sits before the exit
# below. Idempotent; flags a regen so the next build re-bundles the ucode.
if [[ " $hooks_line " != *' microcode '* ]]; then
    [[ -e "${conf}.shedos-pre-migration" ]] || cp -a "$conf" "${conf}.shedos-pre-migration"
    sed -i -E '/^HOOKS=/ s/\bblock\b/microcode block/' "$conf"
    mkdir -p /var/lib/shedos 2>/dev/null && : > /var/lib/shedos/.mkinitcpio-regen-needed 2>/dev/null || true
    echo "shedos: added microcode to mkinitcpio HOOKS (bundles CPU microcode into the UKI)" >&2
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

[[ -e "${conf}.shedos-pre-migration" ]] || cp -a "$conf" "${conf}.shedos-pre-migration"

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
    # tries=0 prompts forever; the default of 3 dead-ends in a blank screen.
    if [[ $spec == *:allow-discards* ]]; then
        rdluks="$rdluks rd.luks.options=discard,tries=0"
    else
        rdluks="$rdluks rd.luks.options=tries=0"
    fi
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
