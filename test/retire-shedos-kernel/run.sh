#!/usr/bin/env bash
# Guard the driver-safety gate in retire-shedos-kernel: it must NOT drop the old
# kernel while linux-zen is still missing a DKMS module (e.g. nvidia built only
# for shedos-kernel), or the box loses its only working driver.
#
# Everything that would actually remove a package or touch /boot is stubbed —
# this never runs the real removal path (the dev box has shedos-kernel installed).
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
retire=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/retire-shedos-kernel

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

kver=7.0.14-zen1-1-zen
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
mkdir -p "$td/bin" "$td/modules/$kver"
echo linux-zen > "$td/modules/$kver/pkgbase"

# Stub pacman: every query says "installed"; -R records the attempt and returns
# $SIM_R_RC so the covered case stops at the "removal failed" branch, well before
# the real /boot cleanup and limine re-render.
cat >"$td/bin/pacman" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -Qq) exit 0 ;;
  -R)  shift 2; echo "R $*" >> "$PACMAN_LOG"; exit "${SIM_R_RC:-0}" ;;
esac
exit 0
EOF
cat >"$td/bin/uname" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -r ]] && echo "${KVER:?}"
EOF
cat >"$td/bin/dkms-coverage-stub" <<'EOF'
#!/usr/bin/env bash
[[ -n ${COV_OUT:-} ]] && printf '%s\n' "$COV_OUT"
exit "${COV_RC:-0}"
EOF
chmod +x "$td/bin/"*

run_retire() {   # env vars set by caller; sets $rc, leaves stderr in $td/err
    : > "$td/pacman.log"
    PATH="$td/bin:$PATH" \
    KVER="$kver" SHEDOS_MODULES_DIR="$td/modules" \
    SHEDOS_DKMS_COVERAGE="$td/bin/dkms-coverage-stub" \
    PACMAN_LOG="$td/pacman.log" \
    COV_RC="${1:-0}" COV_OUT="${2:-}" SIM_R_RC="${3:-0}" \
        bash "$retire" 2>"$td/err" >/dev/null
    rc=$?
}

# 1) nvidia not built for linux-zen → refuse to retire; no removal attempted.
run_retire 1 nvidia 0
if [[ $rc == 0 ]] && ! grep -q '^R ' "$td/pacman.log" && grep -q "missing DKMS" "$td/err"; then
    _ok "defers and never removes when a module is missing for linux-zen"
else
    _fail "defer on missing" "rc=$rc log='$(cat "$td/pacman.log")' err='$(cat "$td/err")'"
fi

# 2) dkms-coverage errored (rc 2) → conservative defer, no removal.
run_retire 2 "" 0
if [[ $rc == 0 ]] && ! grep -q '^R ' "$td/pacman.log"; then
    _ok "defers when coverage can't be verified"
else
    _fail "defer on error" "rc=$rc log='$(cat "$td/pacman.log")'"
fi

# 3) all modules covered → gate passes through to the removal (recorded here;
#    the stub returns 1 so the script stops before the real /boot cleanup).
run_retire 0 "" 1
if grep -q '^R shedos-kernel' "$td/pacman.log"; then
    _ok "proceeds to retire once linux-zen has every module"
else
    _fail "proceed when covered" "rc=$rc log='$(cat "$td/pacman.log")'"
fi

total=$((pass + fail))
echo
echo "retire-shedos-kernel: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
