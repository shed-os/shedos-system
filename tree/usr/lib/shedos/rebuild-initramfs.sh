#!/bin/bash
# Rebuild every installed kernel's initramfs. Wraps `mkinitcpio -P` (the
# active presets, i.e. linux-zen) and adds shedos-kernel, which during the
# migration ships no active preset — the package dropped it and the old
# one is .pacsave, so `mkinitcpio -P` skips it and its initramfs would
# stay frozen at the firmware-fat size, wedging the small ESP. Rebuild it
# slim too while it's still installed; -S autodetect (all modules) keeps
# it correct regardless of which kernel is running the rebuild. It reaps
# itself once shedos-kernel is retired and its vmlinuz is gone.
#
# Exits non-zero if the `mkinitcpio -P` of the active presets fails (the
# caller treats that as fatal); a shedos-kernel rebuild failure is only
# warned, since render-limine-config.sh will refuse loudly if the result
# doesn't fit the ESP anyway.
set -uo pipefail

mkinitcpio -P || exit $?

if [[ -e /boot/vmlinuz-shedos-kernel ]]; then
    for _img in initramfs-shedos-kernel.img initramfs-shedos-kernel-fallback.img; do
        mkinitcpio -S autodetect -k /boot/vmlinuz-shedos-kernel -g "/boot/$_img" \
            || echo "shedos: rebuild of $_img failed" >&2
    done
fi
