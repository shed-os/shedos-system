#!/usr/bin/env bash
# Guard the "AppArmor on by default" invariants. Stock linux-zen's
# CONFIG_LSM omits apparmor, so ShedOS switches it on via the kernel lsm=
# cmdline — baked into the install-time cmdline for fresh installs and
# backfilled onto existing installs — with apparmor.service enabled to load
# the /etc/apparmor.d profile set at boot.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
base_txt=$repo_root/packages/official/base.txt
bootloader=$repo_root/installer/shedos_installer/core/bootloader.py
install_scriptlet=$repo_root/packaging/shedos-system/shedos-system.install

# Arch's default LSM order with apparmor inserted; lsm= is a full override,
# so the whole set must be present or an LSM would be silently dropped.
lsm_token="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# A1: apparmor is an explicit root, so it installs + lands in the closure,
#     meta, and airootfs.
if grep -qxF apparmor "$base_txt"; then
    _ok A1_apparmor_in_base
else
    _fail A1_apparmor_in_base "apparmor missing from packages/official/base.txt"
fi

# A2: the exact LSM token is baked into the install-time cmdline, so a fresh
#     install is enforcing from the very first boot (before any apply). The
#     exact-string match also guards against an LSM being dropped by a typo.
if grep -qF "$lsm_token" "$bootloader"; then
    _ok A2_lsm_baked_into_install_cmdline
else
    _fail A2_lsm_baked_into_install_cmdline \
        "exact lsm token not found in bootloader.py _build_cmdline"
fi

# A3: existing installs get the same token via the upgrade backfill.
if grep -q '_backfill_apparmor_lsm' "$install_scriptlet" \
   && grep -qF "$lsm_token" "$install_scriptlet"; then
    _ok A3_backfill_present
else
    _fail A3_backfill_present \
        "_backfill_apparmor_lsm / lsm token missing from shedos-system.install"
fi

# A4: apparmor.service is enabled on both the fresh-install and upgrade
#     scriptlet paths, so profiles load at boot.
enable_count=$(grep -c 'systemctl enable apparmor.service' "$install_scriptlet")
if (( enable_count >= 2 )); then
    _ok A4_service_enabled_both_paths
else
    _fail A4_service_enabled_both_paths \
        "apparmor.service enabled in $enable_count path(s); expected >=2 (post_install + post_upgrade)"
fi

total=$((pass + fail))
echo
echo "apparmor: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
