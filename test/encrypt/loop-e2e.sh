#!/usr/bin/env bash
# Real-container e2e for the offline reencrypt driver: build a plain btrfs loop
# image, run _do_shrink -> _do_root_reencrypt -> _do_growback against it, and
# prove the encrypted device opens with the passphrase and keeps its data.
# Stub-free — this is the only place the actual cryptsetup/btrfs byte path runs.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
driver=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/reencrypt-driver.sh

if [[ $(id -u) -ne 0 ]] || ! command -v losetup >/dev/null 2>&1; then
    echo "loop-e2e: SKIP (needs root + losetup; the stub layer covers logic in CI)"
    exit 0
fi

work=$(mktemp -d); img="$work/root.img"; loop=""; mapper=""; mnt="$work/mnt"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
    [[ -n $mapper ]] && cryptsetup close "$mapper" 2>/dev/null
    mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null
    [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

# A 512 MiB plain btrfs image with a sentinel file to prove no data loss.
truncate -s 512M "$img"
loop=$(losetup --find --show "$img")
mkfs.btrfs -q "$loop"
mkdir -p "$mnt"; mount -t btrfs -o subvolid=5,rw "$loop" "$mnt"
echo "shedos-e2e-sentinel" > "$mnt/SENTINEL"; sync; umount "$mnt"

# shellcheck source=/dev/null
source "$driver"
export SHEDOS_REENCRYPT_SCRATCH="$mnt" SHEDOS_REENCRYPT_ESP="$work/esp"

kf="$work/key"; printf 'e2epass' > "$kf"; chmod 600 "$kf"

fail=0
_do_shrink "$loop"                || { echo "FAIL: _do_shrink"; fail=1; }
_do_root_reencrypt "$loop" "$kf"  || { echo "FAIL: _do_root_reencrypt"; fail=1; }

# The real assertion: the device is now LUKS2 and opens with the passphrase.
if ! cryptsetup isLuks "$loop"; then echo "FAIL: device is not LUKS after reencrypt"; fail=1; fi
if ! cryptsetup open --key-file "$kf" "$loop" e2e-luks 2>/dev/null; then
    echo "FAIL: encrypted device did not open with the passphrase"; fail=1
else
    mapper=e2e-luks
    _do_growback /dev/mapper/e2e-luks || { echo "FAIL: _do_growback"; fail=1; }
    mount -t btrfs -o subvolid=5,rw /dev/mapper/e2e-luks "$mnt"
    if [[ "$(cat "$mnt/SENTINEL" 2>/dev/null)" != "shedos-e2e-sentinel" ]]; then
        echo "FAIL: sentinel data lost through encryption"; fail=1
    fi
    umount "$mnt"
fi

[[ $fail -eq 0 ]] && echo "loop-e2e: PASS (shrink -> reencrypt -> growback, data intact, opens)"
exit "$fail"
