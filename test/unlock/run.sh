#!/usr/bin/env bash
# Guard shedos-unlock: one boot prompt whose answer is handed to
# systemd-cryptsetup as a credential, so a PIN, the passphrase, or any
# recovery-key spelling all work and nothing is asked twice.
#
# The keyslot half runs against real LUKS containers on loop devices
# (stub-free); systemd-ask-password is stubbed so the test can feed an answer.
# Whether the TPM actually unseals from the PIN credential is a boot witness,
# not something a loop device can show -- what is checked here is that the
# right credentials are written, with the modes systemd insists on.
#
# Needs root + losetup for the real-container tests; SKIPs otherwise, like the
# cryptsetup e2e suites.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/tree/usr/lib/shedos/shedos-unlock

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

_summary() {
    echo
    echo "unlock: $pass/$((pass + fail)) passed"
    if (( fail > 0 )); then printf '  %s\n' "${failures[@]}" >&2; exit 1; fi
    exit 0
}

for t in cryptsetup losetup; do
    command -v "$t" >/dev/null 2>&1 || { echo "unlock: SKIP (missing $t)"; exit 0; }
done

# --- container parsing works unprivileged, so test it either way -----------
d=$(mktemp -d)
printf 'quiet rd.luks.name=AAA=luks-AAA rw rd.luks.name=BBB=luks-BBB splash\n' > "$d/cmdline"
out=$(SHEDOS_UNLOCK_CMDLINE="$d/cmdline" bash -c '
    source '"$tool"' 2>/dev/null || true
    _containers 2>/dev/null' 2>/dev/null | tr '\t' ':' | tr '\n' ' ')
if [[ $out == *"AAA:luks-AAA"* && $out == *"BBB:luks-BBB"* ]]; then
    _ok C1_parses_both_containers_from_cmdline
else
    _fail C1_parses_both_containers_from_cmdline "got [$out]"
fi
printf 'quiet rw splash\n' > "$d/nocrypt"
out=$(SHEDOS_UNLOCK_CMDLINE="$d/nocrypt" bash "$tool" arm 2>&1); rc=$?
if (( rc == 0 )); then
    _ok C2_unencrypted_box_is_a_noop
else
    _fail C2_unencrypted_box_is_a_noop "exited $rc on a box with no LUKS"
fi
rm -rf "$d"

if [[ $(id -u) -ne 0 ]]; then
    echo "unlock: SKIP the real-container tests (needs root + losetup)"
    _summary
fi

# --- real LUKS containers --------------------------------------------------
work=$(mktemp -d); loop=""
cleanup() {
    [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

PASS='the-real-passphrase'
RECOV='BVRD3-G44AC-PYR4E-JSB3E-RRACS'
truncate -s 64M "$work/img"
loop=$(losetup --find --show "$work/img")
printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --batch-mode "$loop" --key-file=- 2>/dev/null \
    || { echo "unlock: SKIP (luksFormat failed here)"; _summary; }
# a second keyslot standing in for the recovery key
printf '%s' "$RECOV" | cryptsetup luksAddKey --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --batch-mode "$loop" \
    --key-file=<(printf '%s' "$PASS") - 2>/dev/null

uuid=$(cryptsetup luksUUID "$loop")
printf 'quiet rd.luks.name=%s=shedosunlocktest rw\n' "$uuid" > "$work/cmdline"

mkdir -p "$work/bin"
# Counts how many times the user was asked, which is the whole point: the
# complaint was being asked twice.
_stub_ask() {  # $1 = what the user "types"
    cat > "$work/bin/systemd-ask-password" <<EOF
#!/usr/bin/env bash
echo x >> "$work/asked"
printf '%s\n' '$1'
EOF
    chmod +x "$work/bin/systemd-ask-password"
}

store=$work/credstore
_run_arm() {
    rm -rf "$store" "$work/asked"; : > "$work/asked"
    PATH="$work/bin:$PATH" \
    SHEDOS_UNLOCK_CMDLINE="$work/cmdline" \
    SHEDOS_UNLOCK_RUNDIR="$work/run" \
    SHEDOS_UNLOCK_CREDSTORE="$store" \
    SHEDOS_UNLOCK_SETTLE_SECONDS=5 \
        timeout 120 bash "$tool" arm >"$work/out" 2>&1
    return $?
}

_cred() { [[ -f $store/$1 ]] && printf '%s' "$(< "$store/$1")"; }
_asked() { wc -l < "$work/asked" | tr -d ' '; }

# --- passphrase and recovery key both land in the passphrase credential ----
for spec in "N1_passphrase:$PASS" "N2_recovery_key:$RECOV"; do
    label=${spec%%:*}; secret=${spec#*:}
    _stub_ask "$secret"; _run_arm; rc=$?
    got=$(_cred cryptsetup.passphrase)
    if (( rc == 0 )) && [[ $got == "$secret" ]]; then
        _ok "${label}_becomes_the_passphrase_credential"
    else
        _fail "${label}_becomes_the_passphrase_credential" \
              "rc=$rc cred=[$got] want=[$secret]: $(tail -2 "$work/out" | tr '\n' ' ')"
    fi
done

# One prompt. Not two.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
n=$(_asked)
if [[ $n == 1 ]]; then
    _ok N3_asks_exactly_once
else
    _fail N3_asks_exactly_once "asked $n times"
fi

# Without a TPM2 token there is nothing a non-keyslot answer could be, so the
# user gets re-asked rather than watching systemd fail the boot.
_stub_ask "definitely-wrong"; _run_arm; rc=$?
n=$(_asked)
if (( rc == 0 )) && [[ $n == 3 ]] && [[ ! -f $store/cryptsetup.passphrase ]]; then
    _ok N4_wrong_answer_reasks_three_times_and_stores_nothing
else
    _fail N4_wrong_answer_reasks_three_times_and_stores_nothing \
          "rc=$rc asked=$n cred=$([[ -f $store/cryptsetup.passphrase ]] && echo yes || echo no)"
fi

# No TPM2 token here, so writing a PIN credential would be a stray secret.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
if [[ ! -f $store/cryptsetup.tpm2-pin ]]; then
    _ok N5_no_pin_credential_without_a_tpm2_token
else
    _fail N5_no_pin_credential_without_a_tpm2_token "wrote a PIN credential anyway"
fi

# systemd silently ignores credstore entries anyone else can read.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
mode_f=$(stat -c '%a' "$store/cryptsetup.passphrase" 2>/dev/null)
mode_d=$(stat -c '%a' "$store" 2>/dev/null)
if [[ $mode_f == 400 && $mode_d == 700 ]]; then
    _ok N6_credential_modes_are_what_systemd_requires
else
    _fail N6_credential_modes_are_what_systemd_requires "file=$mode_f dir=$mode_d"
fi

# The prompt appends a newline; a keyslot secret does not contain one.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
if [[ $(stat -c '%s' "$store/cryptsetup.passphrase") == "${#PASS}" ]]; then
    _ok N7_trailing_newline_is_stripped
else
    _fail N7_trailing_newline_is_stripped "stored $(stat -c '%s' "$store/cryptsetup.passphrase") bytes for ${#PASS}"
fi

# Nothing may be left behind outside the credstore -- the empty scratch
# directory included, which otherwise sits in /run for the whole uptime.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
if [[ ! -e $work/run ]]; then
    _ok N8_scratch_dir_removed
else
    _fail N8_scratch_dir_removed "scratch dir still on disk: $(command ls -A "$work/run" 2>/dev/null)"
fi

# An empty answer means the agent gave up; leave systemd's own prompt to it.
_stub_ask ""; _run_arm; rc=$?
if (( rc == 0 )) && [[ ! -f $store/cryptsetup.passphrase ]]; then
    _ok N9_empty_answer_stores_nothing
else
    _fail N9_empty_answer_stores_nothing "rc=$rc"
fi

# disarm is what stops the passphrase living in /run for the whole uptime.
_stub_ask "$PASS"; _run_arm >/dev/null 2>&1
SHEDOS_UNLOCK_CREDSTORE="$store" bash "$tool" disarm >/dev/null 2>&1
if [[ ! -e $store/cryptsetup.passphrase && ! -e $store/cryptsetup.tpm2-pin ]]; then
    _ok N10_disarm_shreds_the_credentials
else
    _fail N10_disarm_shreds_the_credentials "credstore still populated"
fi

# A device that never appears must not be mistaken for a wrong passphrase.
printf 'quiet rd.luks.name=%s=shedosunlocktest rw\n' \
    'ffffffff-ffff-ffff-ffff-ffffffffffff' > "$work/cmdline"
_stub_ask "$PASS"; _run_arm; rc=$?
n=$(_asked)
if (( rc == 0 )) && [[ $n == 0 ]] && [[ ! -f $store/cryptsetup.passphrase ]]; then
    _ok N11_absent_device_is_not_a_wrong_answer
else
    _fail N11_absent_device_is_not_a_wrong_answer "rc=$rc asked=$n"
fi
printf 'quiet rd.luks.name=%s=shedosunlocktest rw\n' "$uuid" > "$work/cmdline"

# --- taking the TPM out of the boot ----------------------------------------
# The drop-in must differ from the generator's line in the options field and
# nowhere else: the device path and key file carry through untouched, because
# getting a device wrong here is an unbootable machine.
gen=$work/gen; rundir=$work/runsystemd
mkdir -p "$gen" "$rundir"
inst='systemd-cryptsetup@luks\x2dabc.service'
cat > "$gen/$inst" <<'UNIT'
[Unit]
Description=Cryptography Setup for %I
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-cryptsetup attach 'luks-abc' '/dev/disk/by-uuid/abc' 'none' 'discard,tries=0,tpm2-device=auto'
ExecStop=/usr/bin/systemd-cryptsetup detach 'luks-abc'
UNIT

out=$(SHEDOS_UNLOCK_GENDIR="$gen" SHEDOS_UNLOCK_RUNSYSTEMD="$rundir" \
      SHEDOS_UNLOCK_DAEMON_RELOAD=true bash -c '
        source '"$tool"'; _suppress_tpm2' 2>&1)
dropin="$rundir/$inst.d/50-shedos-no-tpm2.conf"
if [[ -f $dropin ]]; then
    line=$(grep '^ExecStart=/usr' "$dropin")
    if [[ $line == *"'/dev/disk/by-uuid/abc' 'none'"* ]] \
       && [[ $line == *"'discard,tries=0'"* ]] && [[ $line != *tpm2-device* ]]; then
        _ok S1_tpm2_option_dropped_and_device_preserved
    else
        _fail S1_tpm2_option_dropped_and_device_preserved "got [$line]"
    fi
    if grep -qx 'ExecStart=' "$dropin"; then
        _ok S2_dropin_resets_execstart_before_setting_it
    else
        _fail S2_dropin_resets_execstart_before_setting_it "no bare ExecStart= reset"
    fi
else
    _fail S1_tpm2_option_dropped_and_device_preserved "no drop-in written: $out"
    _fail S2_dropin_resets_execstart_before_setting_it "no drop-in written"
fi

# A container with no TPM option must be left completely alone.
rm -rf "$rundir"; mkdir -p "$rundir"
sed -i "s/,tpm2-device=auto//" "$gen/$inst"
SHEDOS_UNLOCK_GENDIR="$gen" SHEDOS_UNLOCK_RUNSYSTEMD="$rundir" \
    SHEDOS_UNLOCK_DAEMON_RELOAD=true bash -c '
      source '"$tool"'; _suppress_tpm2' >/dev/null 2>&1
if [[ -z $(find "$rundir" -name '50-shedos-no-tpm2.conf' 2>/dev/null) ]]; then
    _ok S3_container_without_tpm2_is_untouched
else
    _fail S3_container_without_tpm2_is_untouched "wrote a drop-in anyway"
fi

# --- two containers that disagree ------------------------------------------
# A credential is global. One that only some containers accept would be retried
# against the others forever under tries=0, so an answer that does not open
# every container must not be stored at all.
truncate -s 64M "$work/img2"
loop2=$(losetup --find --show "$work/img2")
cleanup2() { losetup -d "$loop2" 2>/dev/null; }
trap 'cleanup; cleanup2' EXIT
printf 'a-different-passphrase' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --batch-mode "$loop2" --key-file=- 2>/dev/null
uuid2=$(cryptsetup luksUUID "$loop2")
printf 'quiet rd.luks.name=%s=one rd.luks.name=%s=two rw\n' "$uuid" "$uuid2" > "$work/cmdline"

_stub_ask "$PASS"; _run_arm; rc=$?
if (( rc == 0 )) && [[ ! -f $store/cryptsetup.passphrase ]]; then
    _ok N12_answer_that_opens_only_some_containers_is_not_stored
else
    _fail N12_answer_that_opens_only_some_containers_is_not_stored \
          "rc=$rc stored=[$(_cred cryptsetup.passphrase)]"
fi
printf 'quiet rd.luks.name=%s=shedosunlocktest rw\n' "$uuid" > "$work/cmdline"

# The TPM2 half cannot be faked here: libcryptsetup's own handler validates a
# systemd-tpm2 token on import and rejects a hand-written one, which is why the
# check reads the token line exactly. tpm2.sh covers that branch against a real
# token on a software TPM, including the boot-hang regression.

_summary
