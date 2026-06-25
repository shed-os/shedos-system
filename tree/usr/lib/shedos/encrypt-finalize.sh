#!/usr/bin/env bash
# First-boot finalisation for in-place disk encryption. The reencrypt driver moved
# the bytes headless and recorded the containers; the enrol service added the paper
# recovery key. This runs on the booted system, after enrol: it builds the normal
# sd-encrypt boot path (via encrypt-reconfigure.sh), advances to flip-pending, and
# then — once sd-encrypt is proven to have unlocked the root on its own — commits the
# flip: drops the driver bridge and shreds the headless keyfile so the box becomes an
# ordinary encrypted install. Self-gates to a no-op on any box that never ran
# `shedman encrypt`, and is idempotent: a box already past a step just reports.
#
# The proof that sd-encrypt unlocked the root is the ABSENCE of the driver's /run
# bridge marker: the driver runs deterministically after systemd-cryptsetup (measured
# in QEMU) and only bridges — dropping the marker — when sd-encrypt did not do the
# unlock. The commit additionally rechecks the post-conditions affirmatively before
# shredding anything, so a stray no-marker boot can never strand the box.

set -uo pipefail

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/esp-state.sh"

PROG=shedos-encrypt-finalize
RECONFIGURE=${SHEDOS_ENCRYPT_RECONFIGURE:-/usr/lib/shedos/encrypt-reconfigure.sh}
ESP=${SHEDOS_REENCRYPT_ESP:-/boot/efi/shedos-encrypt}
KEYFILE=${SHEDOS_REENCRYPT_KEYFILE:-$ESP/key}
MKINITCPIO_CONF=${SHEDOS_MKINITCPIO_CONF:-/etc/mkinitcpio.conf}
BINDIR=${SHEDOS_REENCRYPT_BINDIR:-/usr/lib/shedos}
CONTAINERS_FILE=${SHEDMAN_KEY_CONTAINERS:-/etc/shedos/secureboot/containers}
BRIDGE_MARKER=${SHEDOS_REENCRYPT_RUN:-/run/shedos-reencrypt}/bridged

log() { echo "$PROG: $1" >&2; }

_firmware() {
    [[ -n ${SHEDOS_FIRMWARE:-} ]] && { printf '%s' "$SHEDOS_FIRMWARE"; return 0; }
    [[ -d /sys/firmware/efi ]] && printf 'uefi' || printf 'bios'
}

# Remove the reencrypt hook from HOOKS so the next initramfs carries no driver bridge.
_unstage_reencrypt_hook() {  # $1=mkinitcpio.conf
    sed -i -E '/^HOOKS=/ s/shedos-reencrypt[[:space:]]*//' "$1"
}

# Rebuild the initramfs + the boot image so the HOOKS change takes effect.
_rebuild_boot() {
    "$BINDIR/rebuild-initramfs.sh" || return 1
    if [[ $(_firmware) == uefi ]]; then "$BINDIR/build-uki.sh" --rebuild; else "$BINDIR/render-limine-config.sh"; fi
}

_shred() {  # $1=path
    [[ -e $1 ]] || return 0
    shred -u -- "$1" 2>/dev/null || rm -f -- "$1"
}

# Commit the conversion: drop the driver bridge and the headless keyfile so the box
# is an ordinary sd-encrypt install. Reached only when sd-encrypt is proven (no bridge
# marker) and enrol finished. Asserts the post-conditions FIRST — the running root is
# the LUKS mapper and the recovery key is enrolled — so the shred can never strand a
# box. Unstage + rebuild come BEFORE the shred: a rebuild failure leaves the keyfile
# and the bridge intact, and the box retries on the next boot.
_commit_flip() {
    local rootsrc cont
    rootsrc=$(findmnt -n -o SOURCE / 2>/dev/null)
    [[ $rootsrc == /dev/mapper/luks-* ]] \
        || { log "root is '$rootsrc', not a LUKS mapper — refusing to commit the flip"; return 1; }
    cont=$(grep -vE '^[[:space:]]*(#|$)' "$CONTAINERS_FILE" 2>/dev/null | head -1)
    if [[ -z $cont ]] || ! cryptsetup luksDump --dump-json-metadata "$cont" 2>/dev/null | grep -q 'shedos-recovery'; then
        log "no recovery keyslot on the root container — refusing to commit the flip"; return 1
    fi

    local conf_bak; conf_bak=$(mktemp)
    cp -- "$MKINITCPIO_CONF" "$conf_bak"
    _unstage_reencrypt_hook "$MKINITCPIO_CONF"
    if ! _rebuild_boot; then
        cp -- "$conf_bak" "$MKINITCPIO_CONF"; rm -f -- "$conf_bak"
        log "boot rebuild failed during the flip — staying bridged, retrying next boot"
        return 1
    fi
    rm -f -- "$conf_bak"

    _shred "$KEYFILE"
    local f
    for f in "$ESP"/header-*.img "$ESP"/gpt-*.bak; do _shred "$f"; done
    esp_state_clear
    log "flip committed — the box now boots from sd-encrypt; the conversion bridge is gone"
}

main() {
    local phase; phase=$(esp_state_get phase 2>/dev/null) || return 0
    case $phase in
        encrypting)
            # The byte-move is done and the box booted via the driver bridge. Build
            # the sd-encrypt boot path — but only once the recovery-key enrol has
            # finished: it writes the container list reconfigure reads and clears
            # enroll_containers when every container carries the key. Reconfigure is
            # idempotent, so a retry after a transient failure re-derives the same path.
            local pending; pending=$(esp_state_get enroll_containers 2>/dev/null)
            if [[ -n $pending ]]; then
                log "waiting for the recovery-key enrol to finish before reconfiguring the boot"
                return 0
            fi
            if ! "$RECONFIGURE"; then
                log "boot reconfigure failed — retrying on the next boot"
                return 0
            fi
            esp_state_write "phase=flip-pending"
            log "encrypted boot path staged — reboot to switch onto it"
            ;;
        flip-pending)
            # The box boots on the sd-encrypt cmdline now. A bridge marker means the
            # driver had to open the root (sd-encrypt did not), so do not commit — stay
            # bridged. No marker means sd-encrypt itself unlocked: commit once enrol is done.
            if [[ -e $BRIDGE_MARKER ]]; then
                log "the driver bridged this boot (sd-encrypt did not unlock) — staying flip-pending"
                return 0
            fi
            local pending; pending=$(esp_state_get enroll_containers 2>/dev/null)
            if [[ -n $pending ]]; then
                log "recovery-key enrol not finished — not committing the flip yet"
                return 0
            fi
            _commit_flip
            ;;
        *)
            return 0
            ;;
    esac
}

# Run only when executed; sourced (the unit tests) just defines the functions.
[[ ${BASH_SOURCE[0]} == "${0}" ]] && main
