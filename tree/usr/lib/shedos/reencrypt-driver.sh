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
# The same tail in bytes, for the absolute-target shrink (an idempotent resize
# needs an exact target, not a relative -32M that double-shrinks on a retry).
SHEDOS_REENCRYPT_TAIL_BYTES=${SHEDOS_REENCRYPT_TAIL_BYTES:-33554432}   # 32 MiB
SHEDOS_REENCRYPT_SCRATCH=${SHEDOS_REENCRYPT_SCRATCH:-/run/shedos-reencrypt}
SHEDOS_REENCRYPT_ESP=${SHEDOS_REENCRYPT_ESP:-/boot/efi/shedos-encrypt}
# The arm step stashes the disk passphrase in a 0600 keyfile on the ESP for this
# unattended initramfs run; a resume reads the same file.
SHEDOS_REENCRYPT_KEYFILE=${SHEDOS_REENCRYPT_KEYFILE:-$SHEDOS_REENCRYPT_ESP/key}
# The RAM source for swap sizing.
SHEDOS_REENCRYPT_MEMINFO=${SHEDOS_REENCRYPT_MEMINFO:-/proc/meminfo}

# Still a placeholder — the live-box boot reconfigure lands in a later task
# against real devices.
_do_reconfigure_boot() { return 0; }

# Resolve partition N's device node after a table change, handling bare (sdaN)
# vs p-form (nvme0n1pN) naming and udev's async node creation. Polls up to 5s;
# SHEDOS_REENCRYPT_SETTLE=0 (tests) skips the wait and returns the bare name.
_wait_partnode() {  # $1=disk $2=partnum  -> echoes the node, or returns 1
    local disk=$1 pn=$2 i cand
    for cand in "${disk}${pn}" "${disk}p${pn}"; do
        [[ -b $cand ]] && { printf '%s\n' "$cand"; return 0; }
    done
    [[ ${SHEDOS_REENCRYPT_SETTLE:-1} == 0 ]] && { printf '%s\n' "${disk}${pn}"; return 0; }
    udevadm settle 2>/dev/null || true
    for ((i = 0; i < 50; i++)); do
        for cand in "${disk}${pn}" "${disk}p${pn}"; do
            [[ -b $cand ]] && { printf '%s\n' "$cand"; return 0; }
        done
        sleep 0.1
    done
    return 1
}

# Carve a RAM-sized encrypted swap from the disk tail and format it fresh. The
# btrfs fs was already shrunk by RAM+32M in _do_shrink, so the bytes past the new
# root end are free. Back up the GPT, shrink the root partition entry (same
# start, smaller end — a table edit only, data is never moved), carve the swap
# partition in the freed tail, luksFormat it fresh (swap holds no data to
# preserve), mkswap inside the mapper, and record it for enrol + boot wiring.
# Separately gated: any failure returns 1 and the caller keeps the box on zram.
_do_swap_carve() {  # $1=disk $2=root-partnum $3=keyfile
    local disk=$1 rootpn=$2 kf=$3
    install -d "$SHEDOS_REENCRYPT_ESP"
    local bak; bak="$SHEDOS_REENCRYPT_ESP/gpt-$(basename -- "$disk").bak"

    # Back up the partition table FIRST — recoverable via `sgdisk --load-backup`.
    sgdisk "--backup=$bak" "$disk" \
        || { echo "reencrypt: could not back up the GPT of $disk — leaving swap on zram" >&2; return 1; }

    local memkb ramgib
    memkb=$(awk '/^MemTotal:/{print $2}' "$SHEDOS_REENCRYPT_MEMINFO")
    ramgib=$(( (memkb + 1048575) / 1048576 ))   # RAM rounded up to the next GiB

    # Shrink the root partition by RAM-size: same start sector, end RAM-GiB
    # earlier; then carve swap in the freed tail. sgdisk only rewrites the table,
    # so partition data is never moved and the already-shrunk fs still fits.
    local start sectors_per_gib new_end
    start=$(sgdisk -i "$rootpn" "$disk" | awk '/First sector/{print $3}')
    sectors_per_gib=$(( 1024 * 1024 * 1024 / 512 ))
    new_end=$(( $(sgdisk -i "$rootpn" "$disk" | awk '/Last sector/{print $3}') - ramgib * sectors_per_gib ))
    sgdisk -d "$rootpn" \
           -n "$rootpn:$start:$new_end" -t "$rootpn:8300" -c "$rootpn:root" \
           -n "0:0:0" -t "0:8300" -c "0:swap" "$disk" \
        || { echo "reencrypt: GPT carve failed — restoring backup, swap stays on zram" >&2; sgdisk "--load-backup=$bak" "$disk"; return 1; }
    # Make the kernel pick up the new table, then wait for the swap node to
    # appear (udev is async, and a loop device needs an explicit re-read).
    partx -u "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    local swappn=$(( rootpn + 1 )) swapdev mapper=luks-swap
    swapdev=$(_wait_partnode "$disk" "$swappn") \
        || { echo "reencrypt: swap partition node never appeared after the carve" >&2; return 1; }
    cryptsetup luksFormat --type luks2 -q --key-file="$kf" "$swapdev" \
        || { echo "reencrypt: luksFormat of swap failed — swap stays on zram" >&2; return 1; }
    cryptsetup open --key-file="$kf" "$swapdev" "$mapper" \
        || { echo "reencrypt: could not open the new swap container" >&2; return 1; }
    mkswap "/dev/mapper/$mapper" \
        || { echo "reencrypt: mkswap failed on the swap container" >&2; return 1; }

    # Export the swap PARTITION (not the mapper — luksUUID needs the LUKS device)
    # so _record_containers records it by-uuid and the first-boot enrol service
    # adds the recovery key to it too (RCA: root-only strands the key at the swap
    # tries=0 prompt).
    export SHEDOS_REENCRYPT_SWAP_PART="$swapdev"
    echo "reencrypt: carved + formatted ${ramgib}G encrypted swap on $swapdev"
}

# Bytes of a mounted btrfs's "Device size" — the value btrfs resize moves.
_btrfs_dev_size() {
    btrfs filesystem usage -b "$1" 2>/dev/null \
        | awk '/Device size:/ { gsub(/[^0-9]/, "", $NF); print $NF; exit }'
}

# Shrink root to leave a tail of $2 free bytes at the partition end — header room
# (32M), plus the RAM-sized swap on the carve path. The target is ABSOLUTE
# (partition size minus the tail), not a relative -32M, so a re-run after a power
# cut is idempotent: a relative shrink would chop another tail off every retry and
# corrupt the fs. btrfs resize needs the fs mounted, so mount rw on a scratch dir,
# resize to the target, verify, and unmount. A resize that leaves the fs bigger
# than the target is a hard error: never write a header over an un-shrunk fs.
_do_shrink() {  # $1=dev $2=tail-bytes
    local dev=$1 tail=$2 psize target cur after slack=4194304
    psize=$(blockdev --getsize64 "$dev" 2>/dev/null)
    [[ $psize =~ ^[0-9]+$ ]] || { echo "shedos-reencrypt: cannot size $dev to shrink" >&2; return 1; }
    target=$(( psize - tail ))
    mkdir -p "$SHEDOS_REENCRYPT_SCRATCH"
    mount -t btrfs -o subvolid=5,rw "$dev" "$SHEDOS_REENCRYPT_SCRATCH" \
        || { echo "shedos-reencrypt: cannot mount $dev to shrink" >&2; return 1; }
    cur=$(_btrfs_dev_size "$SHEDOS_REENCRYPT_SCRATCH")
    # Idempotent: already at or below the target (within a btrfs-alignment slack).
    if [[ $cur =~ ^[0-9]+$ ]] && (( cur <= target + slack )); then
        umount "$SHEDOS_REENCRYPT_SCRATCH"; return 0
    fi
    if ! btrfs filesystem resize "1:$target" "$SHEDOS_REENCRYPT_SCRATCH"; then
        umount "$SHEDOS_REENCRYPT_SCRATCH"
        echo "shedos-reencrypt: btrfs resize failed on $dev" >&2
        return 1
    fi
    after=$(_btrfs_dev_size "$SHEDOS_REENCRYPT_SCRATCH")
    umount "$SHEDOS_REENCRYPT_SCRATCH"
    if [[ -z $after ]] || (( after > target + slack )); then
        echo "shedos-reencrypt: $dev did not shrink to target (after=$after target=$target)" >&2
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

# Hand the finalized container list off to userspace. Recovery-key enrolment runs
# on the booted system, not here: minting a key the user must write down and
# confirm is interactive, and this one-shot is headless and ordered before
# sysroot.mount. So we only record the containers (root first, then the carved
# swap) by their LUKS UUID into the ESP state; the first-boot enrol service reads
# enroll_containers=, writes /etc/shedos/secureboot/containers, and enrols. luksUUID
# reads the header directly, so the by-uuid path is computable with no udev symlink
# (which has not been created this early in boot).
_record_containers() {  # $1=root-part $2=swap-part(optional)
    local rootpart=$1 swappart=${2:-} list uuid
    uuid=$(cryptsetup luksUUID "$rootpart" 2>/dev/null) || return 1
    [[ -n $uuid ]] || return 1
    list="/dev/disk/by-uuid/$uuid"
    if [[ -n $swappart ]]; then
        uuid=$(cryptsetup luksUUID "$swappart" 2>/dev/null)
        [[ -n $uuid ]] && list="$list /dev/disk/by-uuid/$uuid"
    fi
    esp_state_write "enroll_containers=$list"
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
#   no      encrypting       -> resume          (cut after shrink, before the header)
#   no      (none)           -> plaintext-passthrough (ordinary box / done)
#   yes     encrypting       -> resume          (power-cut mid-encrypt)
#   yes     flip-pending     -> resume          (encrypt done, flip not committed)
#   yes     (none)           -> plaintext-passthrough (already encrypted + cleared)
#
# The no+encrypting row is load-bearing: the header is initialised only after the
# shrink, so a cut in that window leaves isLuks=no with the phase already advanced,
# and it must resume (re-init the header on the already-shrunk fs) rather than
# re-shrink. The inner btrfs UUID survives in-place encryption, so even a stale
# cmdline token still opens the right container — this brancher, not the cmdline,
# is the source of truth during the window.
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
            armed)      echo fresh-encrypt ;;
            encrypting) echo resume ;;
            *)          echo plaintext-passthrough ;;
        esac
    fi
}

main() {
    local branch dev mapper
    branch=$(_detect_state)
    # Ordinary boot: hand the device back to the normal path, no-op.
    [[ $branch == plaintext-passthrough ]] && return 0
    dev=$(_reencrypt_dev)
    # Only a fresh start needs the shrink; a resume re-enters past it (the shrink
    # is idempotent, but skipping it is cleaner). After the shrink, advance the
    # phase to encrypting: the header init below flips the device to LUKS, and a
    # cut anywhere after this point must boot into the resume branch instead of
    # handing a half-encrypted disk back to the normal path.
    if [[ $branch == fresh-encrypt ]]; then
        _do_shrink "$dev" "$SHEDOS_REENCRYPT_TAIL_BYTES" || return 0
        esp_state_write "phase=encrypting"
    fi
    _do_root_reencrypt "$dev" "$SHEDOS_REENCRYPT_KEYFILE" || return 0
    mapper=luks-$(cryptsetup luksUUID "$dev" 2>/dev/null)
    cryptsetup open --key-file="$SHEDOS_REENCRYPT_KEYFILE" "$dev" "$mapper" 2>/dev/null
    # Carve encrypted swap only when the arm step asked for it; a carve failure
    # leaves the box on encrypted-root + zram, never a half-written table.
    if [[ $(esp_state_get swap 2>/dev/null) == yes ]]; then
        _do_swap_carve "$(esp_state_get disk)" "$(esp_state_get rootpn)" "$SHEDOS_REENCRYPT_KEYFILE" || true
    fi
    _do_growback "/dev/mapper/$mapper"                         || true
    _record_containers "$dev" "${SHEDOS_REENCRYPT_SWAP_PART:-}" || true
    _do_reconfigure_boot                                       || true
    return 0
}

# Run main only when executed as the unit's ExecStart, not when sourced by the
# tests (which call _detect_state directly).
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main
fi
