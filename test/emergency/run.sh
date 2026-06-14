#!/usr/bin/env bash
# Guided emergency recovery checks. Auto-discovered by run-shell-tests.sh;
# hermetic + root-less.
#   E1  entrypoint + UI parse/compile
#   E2  fix-action logic (compute_offerable / apply_fix)
#   E3  mount-report detection (skip network/bind, report a missing local)
#   E4  drop-in structure (ExecStart reset before override, leading -)
#   E5  fallback is a clean root shell before sulogin, with a full PATH
#   E6  systemd-analyze verify of the composed unit (guarded)
#   E7  end-to-end QEMU proof (self-skips without qemu/kvm/image)
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
tree=$repo/packaging/shedos-system/tree
lib=$tree/usr/lib/shedos
ui=$lib/emergency-recovery-ui.py
entry=$lib/emergency-recovery
dropin=$tree/usr/lib/systemd/system/emergency.service.d/50-shedos-guided.conf

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }
_skip() { printf 'skip: %s — %s\n' "$1" "$2"; }

# E1 — syntax
if bash -n "$entry" 2>/dev/null && python3 -m py_compile "$ui" 2>/dev/null; then
    _ok E1_syntax
else
    _fail E1_syntax "entrypoint or UI failed to parse/compile"
fi

# E2 — fix-action logic
if SHEDOS_LIB_ROOT="$lib" python3 - "$lib" <<'PY'
import sys, importlib.util
lib = sys.argv[1]
spec = importlib.util.spec_from_file_location("erui", lib + "/emergency-recovery-ui.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fstab = (
    "UUID=R / btrfs subvol=/@ 0 0\n"
    "UUID=R /home btrfs subvol=/@home 0 0\n"
    "UUID=B /mnt/backup ext4 defaults 0 2\n"
)
off = m.compute_offerable(fstab, set())
assert [f.target for f in off] == ["/mnt/backup"], [f.target for f in off]
assert m.compute_offerable(fstab, {"/mnt/backup"}) == [], "required not excluded"
assert m.compute_offerable(fstab, {"/mnt/backup/"}) == [], "trailing-slash required not excluded"
new = m.apply_fix(fstab, ["/mnt/backup"])
assert "nofail" in new, new
assert len(new.splitlines()) == len(fstab.splitlines()), "line count changed"
PY
then _ok E2_fix_logic; else _fail E2_fix_logic "compute_offerable/apply_fix misbehaved"; fi

# E3 — mount-report skips network + bind, reports a missing local, ignores mounted
if SHEDOS_LIB_ROOT="$lib" python3 - "$lib" <<'PY'
import sys, os, importlib.util, importlib.machinery, tempfile
lib = sys.argv[1]
d = tempfile.mkdtemp()
fstab = os.path.join(d, "fstab"); proc = os.path.join(d, "mounts")
open(fstab, "w").write(
    "UUID=R / btrfs subvol=/@ 0 0\n"
    "UUID=L /mnt/local ext4 defaults 0 2\n"        # missing local -> report
    "//srv/s /mnt/cifs cifs nofail,_netdev 0 0\n"  # network -> skip
    "srv:/e /mnt/nfs nfs nofail,_netdev 0 0\n"     # network -> skip
    "/src /mnt/bind ext4 bind 0 0\n"               # bind -> skip
    "UUID=M /mnt/up ext4 defaults 0 2\n"           # present -> not missed
)
open(proc, "w").write("/dev/x / btrfs rw 0 0\n/dev/y /mnt/up ext4 rw 0 0\n")
os.environ["SHEDOS_APPLY_FSTAB_PATH"] = fstab
os.environ["SHEDOS_PROC_MOUNTS"] = proc
loader = importlib.machinery.SourceFileLoader("mr", lib + "/mount-report")
spec = importlib.util.spec_from_loader("mr", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
got = sorted(x["target"] for x in m.missed_mounts())
assert got == ["/mnt/local"], got
PY
then _ok E3_mount_report; else _fail E3_mount_report "missed_mounts flagged the wrong mounts"; fi

# E4 — drop-in: empty ExecStart= reset before the override, plus the force flag
reset_ln=$(grep -n '^ExecStart=$' "$dropin" | head -1 | cut -d: -f1)
over_ln=$(grep -n '^ExecStart=-/usr/lib/shedos/emergency-recovery emergency$' "$dropin" | head -1 | cut -d: -f1)
if grep -qx 'Environment=SYSTEMD_SULOGIN_FORCE=1' "$dropin" \
   && [[ -n $reset_ln && -n $over_ln && $reset_ln -lt $over_ln ]]; then
    _ok E4_dropin_structure
else
    _fail E4_dropin_structure "missing reset/dash/SULOGIN_FORCE or wrong order"
fi

# E5 — entrypoint runs the guided tool unconditionally (no systemctl --failed
# gate); the fallback opens a clean bash before sulogin, with a full PATH
bash_ln=$(grep -n 'exec /bin/bash' "$entry" | head -1 | cut -d: -f1)
sulogin_ln=$(grep -n 'systemd-sulogin-shell' "$entry" | head -1 | cut -d: -f1)
if grep -q 'emergency-recovery-ui.py' "$entry" \
   && ! grep -q 'systemctl --failed' "$entry" \
   && grep -q 'ShedOS recovery shell' "$entry" \
   && grep -qE '^export PATH=.*/usr/bin' "$entry" \
   && [[ -n $bash_ln && -n $sulogin_ln && $bash_ln -lt $sulogin_ln ]]; then
    _ok E5_entrypoint
else
    _fail E5_entrypoint "entrypoint must run the tool unconditionally + open bash before sulogin"
fi

# E6 — systemd-analyze verify of the composed unit (guarded + noise-filtered)
stock=/usr/lib/systemd/system/emergency.service
if ! command -v systemd-analyze >/dev/null 2>&1; then
    _skip E6_analyze_verify "systemd-analyze not installed"
elif [[ ! -f $stock ]]; then
    _skip E6_analyze_verify "stock emergency.service not present"
else
    tmp=$(mktemp -d)
    cp "$stock" "$tmp/emergency.service"
    mkdir -p "$tmp/emergency.service.d"
    cp "$dropin" "$tmp/emergency.service.d/50-shedos-guided.conf"
    if systemd-analyze verify "$tmp/emergency.service" 2>"$tmp/err"; then
        _ok E6_analyze_verify
    else
        # A man-less runner makes systemd-analyze exit non-zero just for
        # failing to render Documentation= links ("Can't show sulogin(8):
        # Protocol error") — not an override error. Drop those before judging.
        grep -vE "Can't show .*: Protocol error" "$tmp/err" > "$tmp/err.real" || true
        if grep -qiE 'ExecStart|shedos|emergency-recovery' "$tmp/err.real"; then
            _fail E6_analyze_verify "$(cat "$tmp/err.real")"
        else
            _skip E6_analyze_verify "verify noise unrelated to the override"
        fi
    fi
    rm -rf "$tmp"
fi

# E7 — end-to-end QEMU proof (exit 77 = skip)
qemu_assert=$repo/scripts/emergency-boot-assert.sh
if [[ -x $qemu_assert ]]; then
    if "$qemu_assert"; then
        _ok E7_qemu_end_to_end
    else
        rc=$?
        if (( rc == 77 )); then
            _skip E7_qemu_end_to_end "no qemu/kvm/base image"
        else
            _fail E7_qemu_end_to_end "emergency->fix->multi-user failed (rc=$rc)"
        fi
    fi
else
    _skip E7_qemu_end_to_end "scripts/emergency-boot-assert.sh not present yet"
fi

echo
echo "emergency: $pass/$((pass + fail)) passed (skips excluded)"
(( fail == 0 )) || { printf '  %s\n' "${failures[@]}"; exit 1; }
