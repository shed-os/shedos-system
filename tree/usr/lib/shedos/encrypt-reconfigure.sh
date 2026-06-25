#!/usr/bin/env bash
# Reconfigure the boot path after an in-place encryption, on the booted system.
# The reencrypt initramfs got here by opening the LUKS mapper itself and letting
# the unchanged inner-fs UUID resolve sysroot; that is a one-time crutch. This
# builds the NORMAL encrypted boot path so future boots unlock from sd-encrypt
# like a fresh encrypted install: swap the cmdline's root= for the LUKS tokens,
# add sd-encrypt to the initramfs HOOKS, and rebuild the initramfs plus the signed
# UKI (UEFI) or the Limine menu (BIOS).
#
# It only stages the encrypted path; it does not flip the default entry or shred
# the conversion keyfile — that is the verify-before-commit step. The cmdline is a
# surgical transform of the live one, so user-tuned tokens (mitigations=, nvidia,
# [kernel.cmdline] appends) survive the conversion. Idempotent: a re-run re-derives
# the same cmdline and HOOKS.

set -uo pipefail

PROG=shedos-encrypt-reconfigure
KERNEL_CMDLINE_FILE=${SHEDOS_KERNEL_CMDLINE_FILE:-/etc/kernel/cmdline}
KERNEL_CMDLINE_FALLBACK=${SHEDOS_KERNEL_CMDLINE_FALLBACK:-/etc/kernel/cmdline-fallback}
MKINITCPIO_CONF=${SHEDOS_MKINITCPIO_CONF:-/etc/mkinitcpio.conf}
CONTAINERS_FILE=${SHEDMAN_KEY_CONTAINERS:-/etc/shedos/secureboot/containers}
BINDIR=${SHEDOS_REENCRYPT_BINDIR:-/usr/lib/shedos}
LIMINE_CONF=${SHEDOS_LIMINE_CONF:-${SHEDOS_BOOT_DIR:-/boot}/limine.conf}
FSTAB=${SHEDOS_ENCRYPT_FSTAB:-/etc/fstab}
# /etc/kernel/cmdline ships carrying this sentinel; a pre-UKI box keeps its real
# cmdline only in limine.conf's kernel_cmdline: line (same fact backfill-uki-cmdline.py
# relies on). Transforming the placeholder would brick the box.
_PLACEHOLDER=SHEDOS_PLACEHOLDER_CMDLINE

log() { echo "$PROG: $1" >&2; }

# The box's real current kernel cmdline, with comment lines dropped: prefer a real
# /etc/kernel/cmdline, else lift it from limine.conf's kernel_cmdline: line. Rc 1
# when neither yields a real line — the caller must refuse rather than transform a
# placeholder into an unbootable cmdline.
_current_cmdline() {
    local text line
    text=$(grep -vE '^[[:space:]]*#' "$KERNEL_CMDLINE_FILE" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
    text=${text# }; text=${text% }
    if [[ -n $text && $text != *"$_PLACEHOLDER"* ]]; then
        printf '%s' "$text"; return 0
    fi
    line=$(grep -m1 -E '^[[:space:]]*kernel_cmdline:' "$LIMINE_CONF" 2>/dev/null) || return 1
    line=${line#*kernel_cmdline:}; line=${line# }
    [[ -n $line && $line != *"$_PLACEHOLDER"* ]] || return 1
    printf '%s' "$line"
}

_firmware() {
    [[ -n ${SHEDOS_FIRMWARE:-} ]] && { printf '%s' "$SHEDOS_FIRMWARE"; return 0; }
    [[ -d /sys/firmware/efi ]] && printf 'uefi' || printf 'bios'
}

# The LUKS UUID of a container. The install-written list is by-uuid paths, so the
# UUID is the basename; fall back to reading the header for any other form.
_container_uuid() {  # $1=container path
    local p=$1
    if [[ $p == /dev/disk/by-uuid/* ]]; then printf '%s' "${p##*/}"; else cryptsetup luksUUID "$p"; fi
}

# The encrypted root (and swap) tokens, in the installer's order. The mapper name
# is luks-<uuid> for both, matching bootloader.py so an encrypted live box and a
# fresh encrypted install unlock the same way. cryptdevice= rides along so a
# legacy-initrd rescue image still boots; sd-encrypt reads rd.luks.* instead.
_luks_prefix() {  # $1=root-uuid $2=swap-uuid(optional)
    local ru=$1 su=${2:-} rmap="luks-$1"
    printf 'rd.luks.name=%s=%s rd.luks.options=discard,tries=0 cryptdevice=UUID=%s:%s:allow-discards root=/dev/mapper/%s' \
        "$ru" "$rmap" "$ru" "$rmap" "$rmap"
    [[ -n $su ]] && printf ' rd.luks.name=%s=luks-%s' "$su" "$su"
}

# Surgical cmdline transform: drop the tokens we re-derive (root, resume when swap
# is encrypted, and any stale rd.luks/cryptdevice), keep everything else, prepend
# the LUKS tokens, and point resume at the decrypted swap mapper.
_transform_cmdline() {  # $1=current $2=root-uuid $3=swap-uuid(optional)
    local current=$1 ru=$2 su=${3:-} tok out
    local -a kept=()
    # shellcheck disable=SC2086  # split the cmdline on spaces into tokens
    for tok in $current; do
        case $tok in
            root=*|rd.luks.name=*|rd.luks.options=*|cryptdevice=*) continue ;;
            resume=*) [[ -n $su ]] && continue ;;
        esac
        kept+=("$tok")
    done
    out=$(_luks_prefix "$ru" "$su")
    (( ${#kept[@]} )) && out="$out ${kept[*]}"
    [[ -n $su ]] && out="$out resume=/dev/mapper/luks-$su"
    printf '%s' "$out"
}

# The fallback cmdline shows boot detail: drop the two flash-suppression tokens so
# a failing boot is not hidden behind a silent splash (mirrors the installer).
_strip_quiet_splash() {
    local tok out=()
    # shellcheck disable=SC2086
    for tok in $1; do [[ $tok == quiet || $tok == splash ]] || out+=("$tok"); done
    printf '%s' "${out[*]}"
}

# Add sd-encrypt to the HOOKS array, right before shedos-recovery so the order is
# the installer's (… plymouth sd-encrypt shedos-recovery filesystems). Idempotent,
# and a verified post-condition: a cmdline that unlocks from rd.luks.* is a brick
# without the hook, so refuse loudly rather than return a silent no-op.
_add_sd_encrypt_hook() {  # $1=mkinitcpio.conf
    local conf=$1 hooks
    hooks=$(grep -E '^HOOKS=' "$conf" 2>/dev/null | head -1) || { log "no HOOKS= line in $conf"; return 1; }
    # sd-encrypt is the systemd-cryptsetup unlock path and is inert without the
    # systemd hook (a legacy busybox initramfs would bake an unlock-less boot).
    # Refuse rather than brick — such a box must run the mkinitcpio migration first.
    [[ $hooks =~ (^|[^[:alnum:]_])systemd([^[:alnum:]_]|$) ]] \
        || { log "HOOKS is not a systemd initramfs (no systemd hook) — run the mkinitcpio migration first"; return 1; }
    if [[ $hooks != *sd-encrypt* ]]; then
        if [[ $hooks == *shedos-recovery* ]]; then
            sed -i -E '/^HOOKS=/ s/\bshedos-recovery\b/sd-encrypt shedos-recovery/' "$conf"
        else
            sed -i -E '/^HOOKS=/ s/\bfilesystems\b/sd-encrypt filesystems/' "$conf"
        fi
    fi
    grep -qE '^HOOKS=.*\bsd-encrypt\b' "$conf" || { log "could not insert sd-encrypt into HOOKS (no anchor)"; return 1; }
}

# Add the encrypted swap to fstab so swapon activates it at boot. sd-encrypt opens it
# to /dev/mapper/luks-<uuid> from the cmdline, but nothing uses it as swap — and
# hibernation has nowhere to resume to — without this line. Idempotent: skip when a
# line already names this mapper.
_ensure_swap_fstab() {  # $1=swap-uuid
    local mapper="/dev/mapper/luks-$1"
    grep -qE "^[[:space:]]*${mapper}[[:space:]]" "$FSTAB" 2>/dev/null && return 0
    printf '%s none swap defaults 0 0\n' "$mapper" >> "$FSTAB" \
        || { log "could not add the encrypted swap to $FSTAB"; return 1; }
    log "added the encrypted swap to $FSTAB"
}

reconfigure_boot() {
    local -a containers
    mapfile -t containers < <(grep -vE '^[[:space:]]*(#|$)' "$CONTAINERS_FILE" 2>/dev/null)
    (( ${#containers[@]} )) || { log "no containers recorded — nothing to reconfigure"; return 1; }

    local root_uuid swap_uuid=""
    root_uuid=$(_container_uuid "${containers[0]}")
    [[ -n $root_uuid ]] || { log "could not resolve the root LUKS UUID"; return 1; }
    if (( ${#containers[@]} >= 2 )); then
        swap_uuid=$(_container_uuid "${containers[1]}")
        [[ -n $swap_uuid ]] || { log "could not resolve the swap LUKS UUID"; return 1; }
    fi

    # Source of truth for the live cmdline; refuse a placeholder, empty, or
    # non-standard line rather than transform it into an unbootable one. The
    # transform preserves tokens but never adds rootflags=subvol=@, and a cmdline
    # without it mounts the btrfs top-level read-only (no init) — so require it on
    # both the source and the result.
    local current new fallback
    current=$(_current_cmdline) || { log "no real kernel cmdline in $KERNEL_CMDLINE_FILE or $LIMINE_CONF — refusing"; return 1; }
    [[ $current == *root=* && $current == *"rootflags=subvol=@"* ]] \
        || { log "the cmdline source is not a standard ShedOS boot line (no rootflags=subvol=@) — refusing"; return 1; }

    new=$(_transform_cmdline "$current" "$root_uuid" "$swap_uuid")
    [[ $new == *"root=/dev/mapper/luks-"* && $new == *"rootflags=subvol=@"* ]] \
        || { log "the transform did not produce a bootable LUKS root — refusing"; return 1; }
    fallback=$(_strip_quiet_splash "$new")

    # Edit HOOKS first: if the conf has no anchor we refuse before writing the
    # cmdline, so a broken conf never strands a LUKS cmdline with no unlock hook.
    # Until a rebuild bakes them in, all of these edits are inert.
    _add_sd_encrypt_hook "$MKINITCPIO_CONF" || return 1
    printf '%s\n' "$new" > "$KERNEL_CMDLINE_FILE" || { log "could not write $KERNEL_CMDLINE_FILE"; return 1; }
    printf '%s\n' "$fallback" > "$KERNEL_CMDLINE_FALLBACK" || { log "could not write $KERNEL_CMDLINE_FALLBACK"; return 1; }

    # Wire the decrypted swap into fstab so swapon activates it (and hibernation has a
    # target); sd-encrypt only opens the mapper, it does not mount it as swap.
    [[ -n $swap_uuid ]] && { _ensure_swap_fstab "$swap_uuid" || return 1; }

    "$BINDIR/rebuild-initramfs.sh" || { log "initramfs rebuild failed"; return 1; }

    # UEFI bakes the cmdline into the signed UKI; BIOS hands it to the Limine
    # renderer, which does not read /etc/kernel/cmdline on its own.
    if [[ $(_firmware) == uefi ]]; then
        "$BINDIR/build-uki.sh" --rebuild || { log "UKI rebuild failed"; return 1; }
    else
        SHEDOS_LIMINE_CMDLINE="$new" "$BINDIR/render-limine-config.sh" || { log "Limine render failed"; return 1; }
    fi
    log "boot reconfigured to unlock the encrypted root from sd-encrypt"
}

# Run when executed; sourced (the unit tests) just defines the functions.
[[ ${BASH_SOURCE[0]} == "${0}" ]] && reconfigure_boot
