#!/usr/bin/env bash
# Guard the "AppArmor on by default" invariants this package answers for.
# Stock linux-zen's CONFIG_LSM omits apparmor, so ShedOS switches it on via
# the kernel lsm= cmdline, backfilled onto existing installs by the scriptlet
# here with apparmor.service enabled to load the /etc/apparmor.d profile set
# at boot. The two other halves of the invariant belong to whoever owns them:
# apparmor being an explicit package root, and the same token being baked into
# the installer's install-time cmdline.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
install_scriptlet=$repo_root/shedos-system.install

# Arch's default LSM order with apparmor inserted; lsm= is a full override,
# so the whole set must be present or an LSM would be silently dropped.
lsm_token="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

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
