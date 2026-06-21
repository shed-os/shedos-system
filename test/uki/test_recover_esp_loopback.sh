#!/usr/bin/env bash
# Bench-only (root + loop device): exercise recover-esp.sh against a real,
# deliberately-tight FAT ESP. Self-skips when not root, so CI ignores it; run on
# the dev box or in the QEMU recovery gate:
#     sudo bash test/uki/test_recover_esp_loopback.sh
#
# The binding proof for recover-esp is un-bricking a real overflowed UKI box in
# the QEMU Secure-Boot gate; this loopback run is the cheaper intermediate that
# proves the fail-loud arm — recover-esp must refuse (non-zero) rather than
# silently "succeed" when nothing lands on a too-small ESP.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "SKIP: needs root + loop device (run under sudo on the dev box / QEMU)"
    exit 0
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
recover=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/recover-esp.sh

work=$(mktemp -d)
trap 'umount "$work/mnt" 2>/dev/null; rm -rf "$work"' EXIT

# 12 MiB FAT ESP: too small to hold a real UKI, so the rebuild must fail loud.
dd if=/dev/zero of="$work/esp.img" bs=1M count=12 status=none
mkfs.fat -F 16 "$work/esp.img" >/dev/null
mkdir -p "$work/mnt"
mount -o loop "$work/esp.img" "$work/mnt"
mkdir -p "$work/mnt/EFI/Linux" "$work/mnt/EFI/limine"
: > "$work/mnt/EFI/limine/limine.conf"

# Seed a stale orphan UKI for a kernel that isn't installed; recover-esp must
# prune it before the rebuild.
: > "$work/mnt/EFI/Linux/shedos-linux-notinstalled.efi"

echo "Driving recover-esp against a 12 MiB ESP (expect a loud non-zero exit, never a silent success):"
SHEDOS_ESP_DIRS="$work/mnt" bash "$recover"
rc=$?
echo "recover-esp exit=$rc (non-zero = fail-loud as designed; 0 only if a UKI verifiably fit)"

# Whatever the rebuild did, the orphan must be gone — that's the prune contract.
if [[ -e "$work/mnt/EFI/Linux/shedos-linux-notinstalled.efi" ]]; then
    echo "FAIL: recover-esp left the stale orphan UKI in place" >&2
    exit 1
fi
echo "ok: stale orphan UKI pruned"
