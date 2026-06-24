#!/usr/bin/env bash
# Real-container e2e for the SWAP path of the offline reencrypt driver: a GPT loop
# disk with a btrfs root, run the full fresh-encrypt main() with swap=yes, and prove
# the root reencrypts with its data intact AND a separate encrypted swap is carved.
# This is the gate for the carve-before-reencrypt geometry — stubs model argv, not
# the byte layout that decides whether the carve truncates the root. Stub-free.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
driver=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/reencrypt-driver.sh

if [[ $(id -u) -ne 0 ]] || ! command -v losetup >/dev/null 2>&1; then
    echo "swap-loop-e2e: SKIP (needs root + losetup; the stub layer covers logic in CI)"
    exit 0
fi

work=$(mktemp -d); img="$work/disk.img"; loop=""; mnt="$work/mnt"; esp="$work/esp"; rootpart=""
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
    cryptsetup close luks-swap 2>/dev/null || true
    [[ -n $rootpart ]] && cryptsetup close "luks-$(cryptsetup luksUUID "$rootpart" 2>/dev/null)" 2>/dev/null || true
    mountpoint -q "$mnt" && umount "$mnt" 2>/dev/null || true
    [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# A 3 GiB GPT disk with one btrfs root partition + a sentinel.
truncate -s 3G "$img"
loop=$(losetup --find --show --partscan "$img")
sgdisk -n 1:0:0 -t 1:8300 -c 1:root "$loop" >/dev/null
partx -u "$loop" 2>/dev/null || partprobe "$loop" 2>/dev/null || true; udevadm settle 2>/dev/null || true
rootpart="${loop}p1"
mkfs.btrfs -q "$rootpart"
mkdir -p "$mnt"; mount -t btrfs -o subvolid=5,rw "$rootpart" "$mnt"
echo "shedos-swap-e2e" > "$mnt/SENTINEL"; sync; umount "$mnt"

# Fake 256 MB RAM so the carved swap is a manageable 1 GiB, not host RAM.
printf 'MemTotal:         262144 kB\n' > "$work/meminfo"
mkdir -p "$esp/shedos-encrypt"
kf="$esp/key"; printf 'e2epass' > "$kf"; chmod 600 "$kf"

# shellcheck source=/dev/null
source "$repo_root/packaging/shedos-system/tree/usr/lib/shedos/esp-state.sh"
export ESP_STATE_FILE="$esp/shedos-encrypt/state"
esp_state_write "phase=armed" "containers=$rootpart" "disk=$loop" "rootpn=1" "swap=yes"

fail=0
SHEDOS_REENCRYPT_DEV="$rootpart" SHEDOS_REENCRYPT_ESP="$esp" SHEDOS_REENCRYPT_KEYFILE="$kf" \
SHEDOS_REENCRYPT_SCRATCH="$mnt" SHEDOS_REENCRYPT_MEMINFO="$work/meminfo" \
    bash -c "source '$driver'; main" || { echo "FAIL: main returned non-zero"; fail=1; }

# Root is now LUKS, opens with the passphrase, and its btrfs data survived.
if ! cryptsetup isLuks "$rootpart"; then echo "FAIL: root is not LUKS after the run"; fail=1; fi
ruuid=$(cryptsetup luksUUID "$rootpart" 2>/dev/null)
cryptsetup close "luks-$ruuid" 2>/dev/null || true   # main leaves the mapper open after growback
if [[ -n $ruuid ]] && cryptsetup open --key-file "$kf" "$rootpart" "luks-$ruuid" 2>/dev/null; then
    mount -t btrfs -o subvolid=5,rw "/dev/mapper/luks-$ruuid" "$mnt" 2>/dev/null
    if [[ "$(cat "$mnt/SENTINEL" 2>/dev/null)" != "shedos-swap-e2e" ]]; then echo "FAIL: root sentinel lost through the carve+encrypt"; fail=1; fi
    umount "$mnt" 2>/dev/null || true
    cryptsetup close "luks-$ruuid" 2>/dev/null || true
else
    echo "FAIL: encrypted root did not open with the passphrase"; fail=1
fi

# A second partition was carved and is a fresh encrypted swap.
swappart="${loop}p2"
if [[ -b $swappart ]] && cryptsetup isLuks "$swappart" 2>/dev/null; then :; else echo "FAIL: encrypted swap was not carved"; fail=1; fi

[[ $fail -eq 0 ]] && echo "swap-loop-e2e: PASS (carve-before-reencrypt; root data intact + encrypted swap carved)"
exit "$fail"
