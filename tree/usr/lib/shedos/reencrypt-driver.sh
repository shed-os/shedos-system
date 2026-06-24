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
# The EFI System Partition type GUID — how we find the ESP to mount, since a
# systemd initrd does not mount it for us and the keyfile + state live there.
SHEDOS_REENCRYPT_ESP_PARTTYPE=${SHEDOS_REENCRYPT_ESP_PARTTYPE:-c12a7328-f81f-11d2-ba4b-00a0c93ec93b}
# Where device-mapper nodes live, and where the bridge drops its marker. /run is a
# tmpfs systemd carries across switch-root, so the marker reaches userspace finalize.
SHEDOS_REENCRYPT_DM_DIR=${SHEDOS_REENCRYPT_DM_DIR:-/dev/mapper}
SHEDOS_REENCRYPT_RUN=${SHEDOS_REENCRYPT_RUN:-/run/shedos-reencrypt}

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

# Partition N's node if it exists RIGHT NOW (no settle wait) — for the carve's
# idempotency probe, where a missing node means "not carved yet", not "wait".
_partnode_exists() {  # $1=disk $2=partnum  -> echoes the node, or returns 1
    # Tests pin SETTLE=0 and use fake device names; treat that as "not carved" so
    # the fresh-carve path runs (real-node idempotency is the swap loop-e2e's job).
    [[ ${SHEDOS_REENCRYPT_SETTLE:-1} == 0 ]] && return 1
    local cand
    for cand in "${1}${2}" "${1}p${2}"; do
        [[ -b $cand ]] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# How much free tail the shrink must leave at the partition end: 32M of header
# room always, plus a RAM-sized swap when we are going to carve one. The swap
# carve removes exactly the RAM-GiB part from the partition table afterwards, so
# the two derive from the same RAM rounding and stay in lock-step.
_effective_tail() {  # $1=swap(yes|no)  -> bytes
    if [[ $1 == yes ]]; then
        local memkb ramgib
        memkb=$(awk '/^MemTotal:/{print $2}' "$SHEDOS_REENCRYPT_MEMINFO")
        ramgib=$(( (memkb + 1048575) / 1048576 ))   # RAM rounded up to the next GiB
        printf '%s' "$(( ramgib * 1073741824 + SHEDOS_REENCRYPT_TAIL_BYTES ))"
    else
        printf '%s' "$SHEDOS_REENCRYPT_TAIL_BYTES"
    fi
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

    # Idempotent: if a prior (interrupted) run already carved the swap partition,
    # do not re-carve — sgdisk would append a SECOND swap. Just make sure it is a
    # formatted LUKS swap and export it.
    local existing
    if existing=$(_partnode_exists "$disk" "$(( rootpn + 1 ))"); then
        if ! cryptsetup isLuks "$existing" 2>/dev/null; then
            if ! { cryptsetup luksFormat --type luks2 -q --key-file="$kf" "$existing" \
                   && cryptsetup open --key-file="$kf" "$existing" luks-swap \
                   && mkswap /dev/mapper/luks-swap; }; then
                echo "reencrypt: could not format the existing swap partition $existing" >&2
                return 1
            fi
        fi
        export SHEDOS_REENCRYPT_SWAP_PART="$existing"
        echo "reencrypt: swap already carved on $existing"
        return 0
    fi

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
#   yes     flip-pending     -> bridge          (encrypt done; bridge the boot until sd-encrypt is proven)
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
            encrypting)   echo resume ;;
            flip-pending) echo bridge ;;
            *)            echo plaintext-passthrough ;;
        esac
    else
        case $phase in
            armed)      echo fresh-encrypt ;;
            encrypting) echo resume ;;
            *)          echo plaintext-passthrough ;;
        esac
    fi
}

# The keyfile and orchestration state live on the ESP, which a systemd initrd does
# not mount — so on a real boot the driver cannot read them without mounting it
# first. Discover the EFI System Partition that carries our state dir (a box can
# have more than one ESP) and mount it rw at the ESP's parent. A no-op when the
# state is already reachable: the tests and the loop e2es point ESP_STATE_FILE at a
# tmpdir, and a re-entrant call finds it already mounted. _ESP_SELF_MOUNTED records
# the mountpoint so the caller unmounts only what this mounted.
_ESP_SELF_MOUNTED=
_mount_esp() {
    [[ -f $ESP_STATE_FILE ]] && return 0
    local mp dev
    mp=$(dirname -- "$SHEDOS_REENCRYPT_ESP")
    mkdir -p -- "$mp"
    for dev in $(blkid -t "PARTTYPE=$SHEDOS_REENCRYPT_ESP_PARTTYPE" -o device 2>/dev/null); do
        mount -t vfat "$dev" "$mp" 2>/dev/null || continue
        if [[ -e $SHEDOS_REENCRYPT_ESP/state || -e $SHEDOS_REENCRYPT_ESP/key ]]; then
            _ESP_SELF_MOUNTED=$mp
            return 0
        fi
        umount "$mp" 2>/dev/null || true
    done
    echo "shedos-reencrypt: no ESP carrying the encryption state — booting normally" >&2
    return 1
}

# Flush and unmount what _mount_esp mounted, so the writes reach the partition the
# first-boot userspace services read after switch-root.
_umount_esp() {
    [[ -n $_ESP_SELF_MOUNTED ]] || return 0
    sync
    umount "$_ESP_SELF_MOUNTED" 2>/dev/null || true
    _ESP_SELF_MOUNTED=
}

# Flip-pending bridge. The encryption is done and the boot path has been
# reconfigured to unlock from sd-encrypt, but the flip is not committed yet, so the
# driver stays in this initramfs as a guaranteed bridge. If sd-encrypt already
# opened the mapper, leave it and drop no marker; otherwise open it ourselves so the
# box still boots, and record in /run that the driver — not sd-encrypt — did the
# unlock. Userspace finalize reads that marker to decide whether sd-encrypt has
# proven itself before it commits the flip. Whether the mapper-exists read is a
# reliable proof or a race is what the QEMU flip-pending boot settles; the bridge is
# brick-safe either way (the box boots whoever opens it).
_bridge_open() {  # $1=root container
    local dev=$1 uuid mapper run=$SHEDOS_REENCRYPT_RUN
    uuid=$(cryptsetup luksUUID "$dev" 2>/dev/null) || return 0
    mapper=luks-$uuid
    [[ -e $SHEDOS_REENCRYPT_DM_DIR/$mapper ]] && return 0   # sd-encrypt (or a prior open) already unlocked it
    if cryptsetup open --key-file="$SHEDOS_REENCRYPT_KEYFILE" "$dev" "$mapper" 2>/dev/null; then
        mkdir -p -- "$run"; : > "$run/bridged"
    fi
}

_drive() {
    local branch dev mapper swap tail rpn
    branch=$(_detect_state)
    # Ordinary boot: hand the device back to the normal path, no-op.
    [[ $branch == plaintext-passthrough ]] && return 0
    dev=$(_reencrypt_dev)
    # Flip-pending: the conversion is finished; just bridge the boot, nothing to
    # shrink/encrypt/grow. The flip itself commits from userspace once proven.
    [[ $branch == bridge ]] && { _bridge_open "$dev"; return 0; }
    swap=$(esp_state_get swap 2>/dev/null)
    if [[ $branch == fresh-encrypt ]]; then
        # Shrink the fs to leave the header tail (plus the RAM swap if carving),
        # then carve the encrypted swap from the freed tail while the root is still
        # PLAINTEXT — a table edit only; the fs already fits and there is no LUKS
        # header yet that the shrunk partition could outsize. The root then
        # reencrypts at its final size, so cryptsetup's data area (which ends at the
        # partition end) is never truncated by the carve. Advancing the phase last:
        # the header init below flips the device to LUKS, and a cut after this point
        # must boot into the resume branch, not hand a half-encrypted disk back.
        tail=$(_effective_tail "$swap")
        _do_shrink "$dev" "$tail" || return 0
        if [[ $swap == yes ]]; then
            _do_swap_carve "$(esp_state_get disk)" "$(esp_state_get rootpn)" "$SHEDOS_REENCRYPT_KEYFILE" || true
        fi
        esp_state_write "phase=encrypting"
    elif [[ $swap == yes ]]; then
        # Resume: the carve already happened on the fresh run; re-derive the swap
        # partition so the recovery enrol + boot wiring still see it.
        rpn=$(esp_state_get rootpn 2>/dev/null)
        SHEDOS_REENCRYPT_SWAP_PART=$(_partnode_exists "$(esp_state_get disk 2>/dev/null)" "$(( ${rpn:-0} + 1 ))" || true)
        export SHEDOS_REENCRYPT_SWAP_PART
    fi
    _do_root_reencrypt "$dev" "$SHEDOS_REENCRYPT_KEYFILE" || return 0
    mapper=luks-$(cryptsetup luksUUID "$dev" 2>/dev/null)
    cryptsetup open --key-file="$SHEDOS_REENCRYPT_KEYFILE" "$dev" "$mapper" 2>/dev/null
    _do_growback "/dev/mapper/$mapper"                         || true
    _record_containers "$dev" "${SHEDOS_REENCRYPT_SWAP_PART:-}" || true
    _do_reconfigure_boot                                       || true
    return 0
}

# Mount the ESP, drive the conversion, then unmount — so the keyfile read and the
# phase writes hit the real partition. A missing ESP degrades to a normal boot
# rather than a brick; the conversion just does not start this boot.
main() {
    _mount_esp || return 0
    _drive
    local rc=$?
    _umount_esp
    return "$rc"
}

# Run main only when executed as the unit's ExecStart, not when sourced by the
# tests (which call _detect_state directly).
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main
fi
