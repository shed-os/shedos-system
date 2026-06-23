#!/bin/bash
# In-place reencryption driver. Runs as the shedos-reencrypt.service ExecStart in
# the transient reencrypt initramfs, before sysroot is mounted. On every boot it
# decides — read-only — whether this is an ordinary plaintext box (no-op), a
# fresh encrypt the arm step set up, or an interrupted run to resume, then drives
# the offline conversion. The _do_* steps land in later tasks.

set -u

# Source the sibling esp-state lib. Same directory in the package tree and on an
# installed box (/usr/lib/shedos), so resolve it relative to this file.
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/esp-state.sh"

# Pinned tail: the btrfs shrink and cryptsetup --reduce-device-size both use this
# one value, so they cannot drift — a mismatch loses root data.
SHEDOS_REENCRYPT_TAIL=${SHEDOS_REENCRYPT_TAIL:-32M}
SHEDOS_REENCRYPT_SCRATCH=${SHEDOS_REENCRYPT_SCRATCH:-/run/shedos-reencrypt}
SHEDOS_REENCRYPT_ESP=${SHEDOS_REENCRYPT_ESP:-/boot/efi/shedos-encrypt}
# The arm step stashes the disk passphrase in a 0600 keyfile on the ESP for this
# unattended initramfs run; a resume reads the same file.
SHEDOS_REENCRYPT_KEYFILE=${SHEDOS_REENCRYPT_KEYFILE:-$SHEDOS_REENCRYPT_ESP/key}

# Still placeholders — the swap carve, recovery enrol, and boot reconfigure land
# in later tasks against real devices.
_do_swap_carve()       { return 0; }
_do_enroll()           { return 0; }
_do_reconfigure_boot() { return 0; }

# Bytes of a mounted btrfs's "Device size" — the value btrfs resize moves.
_btrfs_dev_size() {
    btrfs filesystem usage -b "$1" 2>/dev/null \
        | awk '/Device size:/ { gsub(/[^0-9]/, "", $NF); print $NF; exit }'
}

# Shrink root by exactly the header tail, in the fully reversible pre-header
# window (no LUKS header exists yet; the old plaintext cmdline still boots).
# btrfs resize is a kernel ioctl that needs the fs mounted, so mount rw on a
# scratch dir, resize, verify the device actually shrank, and unmount. A resize
# that did not shrink is a hard error: never write a header over an un-shrunk fs.
_do_shrink() {
    local dev=$1 before after
    mkdir -p "$SHEDOS_REENCRYPT_SCRATCH"
    mount -t btrfs -o subvolid=5,rw "$dev" "$SHEDOS_REENCRYPT_SCRATCH" \
        || { echo "shedos-reencrypt: cannot mount $dev to shrink" >&2; return 1; }
    before=$(_btrfs_dev_size "$SHEDOS_REENCRYPT_SCRATCH")
    if ! btrfs filesystem resize "1:-$SHEDOS_REENCRYPT_TAIL" "$SHEDOS_REENCRYPT_SCRATCH"; then
        umount "$SHEDOS_REENCRYPT_SCRATCH"
        echo "shedos-reencrypt: btrfs resize failed on $dev" >&2
        return 1
    fi
    after=$(_btrfs_dev_size "$SHEDOS_REENCRYPT_SCRATCH")
    umount "$SHEDOS_REENCRYPT_SCRATCH"
    if [[ -z $before || -z $after || $after -ge $before ]]; then
        echo "shedos-reencrypt: $dev did not shrink (before=$before after=$after)" >&2
        return 1
    fi
}

# Header-init + verify-before-encrypt + transient backup + resumable encrypt.
# $1 = the bare root partition, $2 = a 0600 keyfile with the disk passphrase (no
# trailing newline; cryptsetup cannot read a NEW key from a pipe). The freed tail
# from _do_shrink is where the header and shifted data land, so the reduce MUST
# equal the shrink. Order is load-bearing: init the header, TEST-OPEN the keyslot,
# and only then move a ciphertext byte — never encrypt data we cannot decrypt.
_do_root_reencrypt() {
    local part=$1 keyfile=$2 uuid hdr
    # A fresh start (still plaintext) inits the header, proves the keyslot opens,
    # and backs the header up before any byte moves. A resume (already LUKS, the
    # reencrypt caught mid-flight) skips straight to finishing it — re-running
    # init on a started reencrypt would error.
    if ! cryptsetup isLuks "$part" 2>/dev/null; then
        if ! cryptsetup reencrypt --encrypt --type luks2 \
                --reduce-device-size "$SHEDOS_REENCRYPT_TAIL" --force-offline-reencrypt -q \
                --key-file="$keyfile" --init-only "$part"; then
            echo "shedos-reencrypt: header init failed on $part" >&2
            return 1
        fi
        if ! cryptsetup open --test-passphrase --key-file="$keyfile" "$part"; then
            echo "shedos-reencrypt: keyslot did not open on $part — refusing to encrypt" >&2
            return 1
        fi
        uuid=$(cryptsetup luksUUID "$part" 2>/dev/null)
        mkdir -p "$SHEDOS_REENCRYPT_ESP"
        hdr="$SHEDOS_REENCRYPT_ESP/header-${uuid}.img"
        cryptsetup luksHeaderBackup "$part" --header-backup-file "$hdr" \
            || { echo "shedos-reencrypt: header backup failed" >&2; return 1; }
    fi
    if ! cryptsetup reencrypt --resume-only -q --key-file="$keyfile" "$part"; then
        echo "shedos-reencrypt: reencrypt run failed on $part (re-runnable)" >&2
        return 1
    fi
}

# Reclaim the slack left after encryption: grow the opened mapper's btrfs back to
# fill the device. Idempotent and retryable — the box is already encrypted and
# bootable by now, so a re-run on an already-max fs is a clean no-op.
_do_growback() {
    local mapper=$1
    mkdir -p "$SHEDOS_REENCRYPT_SCRATCH"
    mount -t btrfs -o subvolid=5,rw "$mapper" "$SHEDOS_REENCRYPT_SCRATCH" \
        || { echo "shedos-reencrypt: cannot mount $mapper to grow back" >&2; return 1; }
    btrfs filesystem resize 1:max "$SHEDOS_REENCRYPT_SCRATCH"
    umount "$SHEDOS_REENCRYPT_SCRATCH"
}

# The root partition to convert. The arm step pins it into the ESP state
# (containers=, root first, space-separated); the override is for the tests.
_reencrypt_dev() {
    if [[ -n ${SHEDOS_REENCRYPT_DEV:-} ]]; then
        printf '%s\n' "$SHEDOS_REENCRYPT_DEV"; return
    fi
    esp_state_get containers | awk '{print $1}'
}

# Decide what this boot does, read-only — no byte is touched here. Two facts:
# is the device already a LUKS2 container, and what orchestration phase does the
# ESP record. The matrix:
#
#   isLuks  phase            -> branch
#   no      armed            -> fresh-encrypt   (first reencrypt boot)
#   no      (none)           -> plaintext-passthrough (ordinary box / done)
#   yes     encrypting       -> resume          (power-cut mid-encrypt)
#   yes     flip-pending     -> resume          (encrypt done, flip not committed)
#   yes     (none)           -> plaintext-passthrough (already encrypted + cleared)
#
# The inner btrfs UUID survives in-place encryption, so even a stale cmdline
# token still opens the right container — this brancher, not the cmdline, is the
# source of truth during the window.
_detect_state() {
    local dev phase
    dev=$(_reencrypt_dev)
    phase=$(esp_state_get phase 2>/dev/null)

    if cryptsetup isLuks "$dev" 2>/dev/null; then
        case $phase in
            encrypting|flip-pending) echo resume ;;
            *)                       echo plaintext-passthrough ;;
        esac
    else
        case $phase in
            armed) echo fresh-encrypt ;;
            *)     echo plaintext-passthrough ;;
        esac
    fi
}

main() {
    local branch dev mapper
    branch=$(_detect_state)
    # Ordinary boot: hand the device back to the normal path, no-op.
    [[ $branch == plaintext-passthrough ]] && return 0
    dev=$(_reencrypt_dev)
    # Only a fresh start needs the shrink; a resume re-enters past it. After the
    # bytes are encrypted the steps are shared (each _do_* re-detects its own
    # sub-state, so a re-entered resume picks up where the cut landed).
    [[ $branch == fresh-encrypt ]] && { _do_shrink "$dev" || return 0; }
    _do_root_reencrypt "$dev" "$SHEDOS_REENCRYPT_KEYFILE" || return 0
    mapper=luks-$(cryptsetup luksUUID "$dev" 2>/dev/null)
    cryptsetup open --key-file="$SHEDOS_REENCRYPT_KEYFILE" "$dev" "$mapper" 2>/dev/null
    _do_swap_carve                     || true
    _do_growback "/dev/mapper/$mapper" || true
    _do_enroll                         || true
    _do_reconfigure_boot               || true
    return 0
}

# Run main only when executed as the unit's ExecStart, not when sourced by the
# tests (which call _detect_state directly).
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main
fi
