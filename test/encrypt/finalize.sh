#!/usr/bin/env bash
# Guard the first-boot finalize (encrypt-finalize.sh): on phase=encrypting it waits
# for the recovery-key enrol, runs the boot reconfigure, and advances to
# flip-pending; on phase=flip-pending it only reports; on any other phase it is a
# no-op. The reconfigure step is stubbed; the phase transitions run for real against
# an ESP state file. The flip commit itself is the QEMU-validated finaliser, not here.

set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
fin=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/encrypt-finalize.sh

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A sandbox with an ESP state file and a reconfigure stub that records its call and
# fails only when a recon-fail marker is present (no env-propagation games).
_mk() {
    local d; d=$(mktemp -d); mkdir -p "$d/esp"
    cat > "$d/reconfigure" <<EOF
#!/usr/bin/env bash
touch "$d/reconfigure-called"
[[ -e "$d/recon-fail" ]] && exit 1
exit 0
EOF
    chmod +x "$d/reconfigure"
    printf '%s\n' "$d"
}
_run() {  # $1=dir
    ESP_STATE_FILE="$1/esp/state" SHEDOS_ENCRYPT_RECONFIGURE="$1/reconfigure" \
        bash -c "source '$fin'; main" >/dev/null 2>&1
}

# F1: phase=encrypting, enrol done (no enroll_containers) -> reconfigure + flip-pending.
d=$(_mk); printf 'phase=encrypting\n' > "$d/esp/state"
_run "$d"
if [[ -e $d/reconfigure-called ]] && grep -qx 'phase=flip-pending' "$d/esp/state"; then _ok F1_reconfigure_and_advance; else _fail F1_reconfigure_and_advance "called=$([[ -e $d/reconfigure-called ]] && echo y || echo n) state=[$(cat "$d/esp/state")]"; fi

# F2: phase=encrypting but enrol not finished (enroll_containers set) -> waits.
d=$(_mk); { printf 'phase=encrypting\n'; printf 'enroll_containers=/dev/disk/by-uuid/x\n'; } > "$d/esp/state"
_run "$d"
if [[ ! -e $d/reconfigure-called ]] && grep -qx 'phase=encrypting' "$d/esp/state"; then _ok F2_waits_for_enrol; else _fail F2_waits_for_enrol "called=$([[ -e $d/reconfigure-called ]] && echo y || echo n) state=[$(cat "$d/esp/state")]"; fi

# F3: phase=encrypting, reconfigure fails -> stays encrypting (retry next boot).
d=$(_mk); printf 'phase=encrypting\n' > "$d/esp/state"; touch "$d/recon-fail"
_run "$d"
if [[ -e $d/reconfigure-called ]] && grep -qx 'phase=encrypting' "$d/esp/state"; then _ok F3_reconfigure_fail_retries; else _fail F3_reconfigure_fail_retries "state=[$(cat "$d/esp/state")]"; fi

# F4: phase=flip-pending -> reports only, no reconfigure, no phase change.
d=$(_mk); printf 'phase=flip-pending\n' > "$d/esp/state"
_run "$d"
if [[ ! -e $d/reconfigure-called ]] && grep -qx 'phase=flip-pending' "$d/esp/state"; then _ok F4_flip_pending_reports; else _fail F4_flip_pending_reports "called=$([[ -e $d/reconfigure-called ]] && echo y || echo n) state=[$(cat "$d/esp/state")]"; fi

# F5: phase=armed (the driver has not run yet) -> no-op, no reconfigure.
d=$(_mk); printf 'phase=armed\n' > "$d/esp/state"
_run "$d"
if [[ ! -e $d/reconfigure-called ]]; then _ok F5_armed_noop; else _fail F5_armed_noop "reconfigure ran on armed"; fi

printf 'encrypt-finalize: %d/%d passed\n' "$pass" "$((pass + fail))"
(( fail == 0 )) || { printf 'failed: %s\n' "${failures[*]}" >&2; exit 1; }
