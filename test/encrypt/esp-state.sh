#!/usr/bin/env bash
# esp-state.sh unit tests: a temp dir stands in for the FAT ESP. The lib is a
# leaf (no cryptsetup/sgdisk stubs) so these are pure round-trip + parse-safety
# checks. The atomic-rename-on-the-real-ESP behavior rides the same-dir tempfile
# assertion (E2) plus the e2e loop test; here ESP_STATE_FILE redirects the path
# the way SHEDMAN_KEY_CONTAINERS does for the key subcommand.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
lib=$repo_root/tree/usr/lib/shedos/esp-state.sh

pass=0; fail=0
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

# shellcheck source=/dev/null
source "$lib"

# E1: a phase transition keeps the persisted reencrypt flags/containers/created.
d=$(mktemp -d); export ESP_STATE_FILE="$d/esp/shedos-encrypt/state"
esp_state_write phase=armed flags=resilience=checksum,sector-size=512 \
                containers='/dev/sda2 /dev/sda3' created=1718000000
esp_state_write phase=encrypting
if [[ "$(esp_state_get phase)"      == encrypting ]] \
   && [[ "$(esp_state_get flags)"   == 'resilience=checksum,sector-size=512' ]] \
   && [[ "$(esp_state_get containers)" == '/dev/sda2 /dev/sda3' ]] \
   && [[ "$(esp_state_get created)" == 1718000000 ]]; then
    _ok E1_transition_preserves_keys
else
    _fail E1_transition_preserves_keys "$(esp_state_read | tr '\n' '|')"
fi

# E2: the tempfile is created in the state file's directory, not $TMPDIR — on a
# real FAT ESP that is what makes the mv a same-fs rename instead of a cross-fs
# copy+unlink (non-atomic over a power cut). Trap mktemp via PATH and record its
# template argument.
d=$(mktemp -d); export ESP_STATE_FILE="$d/esp/shedos-encrypt/state"
stub=$(mktemp -d)
cat > "$stub/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/mktemp.log"
exec /usr/bin/mktemp "\$@"
EOF
chmod +x "$stub/mktemp"
( PATH="$stub:$PATH"; esp_state_write phase=armed )
if grep -q "${ESP_STATE_FILE}.XXXXXX" "$d/mktemp.log" 2>/dev/null; then
    _ok E2_tempfile_same_dir
else
    _fail E2_tempfile_same_dir "$(cat "$d/mktemp.log" 2>/dev/null)"
fi

# E3: a value with shell metacharacters round-trips literally — proof the lib
# parses rather than sources (sourcing this as root in initramfs would execute
# the payload).
d=$(mktemp -d); export ESP_STATE_FILE="$d/esp/state"
# shellcheck disable=SC2016  # the metachars must stay literal — that's the test
esp_state_write containers='$(touch /tmp/pwned);`id`'
got=$(esp_state_get containers)
# shellcheck disable=SC2016
if [[ $got == '$(touch /tmp/pwned);`id`' ]] && [[ ! -e /tmp/pwned ]]; then
    _ok E3_no_source_exec
else
    _fail E3_no_source_exec "got=$got pwned=$([[ -e /tmp/pwned ]] && echo yes)"
fi

# E4: a missing state file → get returns empty + nonzero (the one-shot's
# plaintext-boot no-op branch keys off this), and read prints nothing.
d=$(mktemp -d); export ESP_STATE_FILE="$d/nope/state"
out=$(esp_state_get phase); rc=$?
if [[ $rc -ne 0 && -z $out && -z "$(esp_state_read)" ]]; then
    _ok E4_absent_file
else
    _fail E4_absent_file "rc=$rc out=$out"
fi

# E5: clear removes the file; a subsequent get is the absent case.
d=$(mktemp -d); export ESP_STATE_FILE="$d/esp/state"
esp_state_write phase=flip-pending
esp_state_clear
if [[ ! -f $ESP_STATE_FILE ]] && ! esp_state_get phase >/dev/null 2>&1; then
    _ok E5_clear
else
    _fail E5_clear "file still present or get succeeded"
fi

total=$((pass + fail))
echo
echo "esp-state: $pass/$total passed"
(( fail == 0 ))
