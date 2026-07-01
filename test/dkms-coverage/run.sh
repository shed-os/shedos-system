#!/usr/bin/env bash
# Contract-test the dkms-coverage helper: given a kernel, it names the installed
# DKMS modules with no build for it. retire-shedos-kernel and shedman doctor both
# rely on this to catch a driver (e.g. nvidia) built only for the old kernel.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
cov=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/dkms-coverage

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT

# A fake `dkms` whose `status` prints whatever the test stages in $DKMS_STATUS_FILE.
mkdir -p "$td/bin"
cat >"$td/bin/dkms" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == status ]] && cat "$DKMS_STATUS_FILE"
EOF
chmod +x "$td/bin/dkms"

run_cov() {   # run_cov <status-content> <kernel>; sets $out and $rc
    printf '%s' "$1" > "$td/status"
    out=$(DKMS_STATUS_FILE="$td/status" SHEDOS_DKMS="$td/bin/dkms" \
          "$cov" "$2" 2>/dev/null)
    rc=$?
}

# The real dev-box scenario: nvidia built for shedos-kernel only.
staged=$'nvidia/610.43.02, 7.0.5-zen1-2-shedos-kernel, x86_64: installed\n'

run_cov "$staged" 7.0.14-zen1-1-zen
if [[ $rc == 1 && $out == nvidia ]]; then
    _ok "names the module missing for an uncovered kernel"
else
    _fail "uncovered kernel" "rc=$rc out='$out'"
fi

run_cov "$staged" 7.0.5-zen1-2-shedos-kernel
if [[ $rc == 0 && -z $out ]]; then
    _ok "silent + exit 0 when the module is built for the kernel"
else
    _fail "covered kernel" "rc=$rc out='$out'"
fi

both=$'nvidia/610.43.02, 7.0.14-zen1-1-zen, x86_64: installed\nvirtualbox/7.1.4, 7.0.14-zen1-1-zen, x86_64: installed\n'
run_cov "$both" 7.0.14-zen1-1-zen
if [[ $rc == 0 && -z $out ]]; then
    _ok "all modules covered → exit 0"
else
    _fail "all covered" "rc=$rc out='$out'"
fi

run_cov "" 7.0.14-zen1-1-zen
if [[ $rc == 0 && -z $out ]]; then
    _ok "no dkms modules → exit 0"
else
    _fail "empty status" "rc=$rc out='$out'"
fi

DKMS_STATUS_FILE="$td/status" SHEDOS_DKMS="$td/bin/dkms" "$cov" >/dev/null 2>&1 && usage_rc=0 || usage_rc=$?
if [[ $usage_rc == 2 ]]; then
    _ok "no kernel arg → exit 2"
else
    _fail "usage" "expected exit 2, got $usage_rc"
fi

total=$((pass + fail))
echo
echo "dkms-coverage: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
