#!/usr/bin/env bash
# The end of the argument: drive the real systemd-cryptsetup against a real
# TPM2-with-PIN container and show that the credentials shedos-unlock leaves
# behind open it -- from the PIN, from the passphrase, or from the recovery
# key -- without a second prompt.
#
# The TPM is a software one (swtpm through the vtpm-proxy driver), so the token
# is genuine: systemd-cryptenroll writes it, systemd-cryptsetup unseals it.
# What is stubbed is only the user typing.
#
# Needs root, swtpm, and the tpm_vtpm_proxy module; SKIPs otherwise.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/tree/usr/lib/shedos/shedos-unlock

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }
_skip() { echo "unlock-tpm2: SKIP ($1)"; exit 0; }

[[ $(id -u) -eq 0 ]] || _skip "needs root"
for t in swtpm cryptsetup losetup systemd-cryptenroll; do
    command -v "$t" >/dev/null 2>&1 || _skip "missing $t"
done
modprobe tpm_vtpm_proxy 2>/dev/null || _skip "no tpm_vtpm_proxy"

work=$(mktemp -d); loop=""; swtpm_pid=""
cleanup() {
    cryptsetup close unlocktpmtest 2>/dev/null
    [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null
    [[ -n $swtpm_pid ]] && kill "$swtpm_pid" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/state"
swtpm chardev --vtpm-proxy --tpm2 --tpmstate dir="$work/state" \
      --flags startup-clear --daemon > "$work/swtpm.out" 2>&1
sleep 2
dev=$(sed -n 's|.*New TPM device: \(/dev/tpm[0-9]*\).*|\1|p' "$work/swtpm.out")
[[ -n $dev ]] || _skip "swtpm did not create a device"
swtpm_pid=$(pgrep -f "tpmstate dir=$work/state" | head -1)
tpm=${dev/tpm/tpmrm}

PASS='the-real-passphrase'
RECOV='BVRD3-G44AC-PYR4E-JSB3E-RRACS'
PIN='2468'

truncate -s 64M "$work/img"
loop=$(losetup --find --show "$work/img")
printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --batch-mode "$loop" --key-file=- 2>/dev/null \
    || _skip "luksFormat failed"
printf '%s' "$RECOV" | cryptsetup luksAddKey --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --batch-mode "$loop" \
    --key-file=<(printf '%s' "$PASS") - 2>/dev/null
# --tpm2-public-key= switches off the signed-PCR policy systemd would otherwise
# pick up from /run automatically. ShedOS does enroll that policy in the field,
# but it is bound to the PCR 11 of a real signed boot, which a scratch software
# TPM cannot reproduce -- and it is not what these cases are about. The PIN is.
PASSWORD=$PASS NEWPIN=$PIN systemd-cryptenroll \
    --tpm2-device="$tpm" --tpm2-with-pin=yes --tpm2-public-key= "$loop" >/dev/null 2>&1 \
    || _skip "cryptenroll refused"

cryptsetup luksDump "$loop" | grep -qE '^[[:space:]]+[0-9]+:[[:space:]]+systemd-tpm2[[:space:]]*$' \
    || _skip "no systemd-tpm2 token after enroll"

uuid=$(cryptsetup luksUUID "$loop")
printf 'quiet rd.luks.name=%s=unlocktpmtest rw\n' "$uuid" > "$work/cmdline"

# The header really does carry a TPM2 token, so the branch that treats an
# unmatched answer as a PIN must fire.
if (SHEDOS_UNLOCK_CMDLINE="$work/cmdline"; source "$tool"; _has_tpm2_token "$loop"); then
    _ok D1_real_tpm2_token_detected
else
    _fail D1_real_tpm2_token_detected "did not see the token systemd-cryptenroll wrote"
fi

mkdir -p "$work/bin"
_stub_ask() {
    cat > "$work/bin/systemd-ask-password" <<EOF
#!/usr/bin/env bash
echo x >> "$work/asked"
printf '%s\n' '$1'
EOF
    chmod +x "$work/bin/systemd-ask-password"
}

store=$work/credstore
gen=$work/gen; runsystemd=$work/runsystemd
inst=systemd-cryptsetup@unlocktpmtest.service
_cred() { [[ -f $store/$1 ]] && printf '%s' "$(< "$store/$1")"; }

# Stand in for the generator, so _suppress_tpm2 has a real unit to rewrite.
_write_generated_unit() {
    mkdir -p "$gen"
    cat > "$gen/$inst" <<UNIT
[Service]
Type=oneshot
ExecStart=/usr/bin/systemd-cryptsetup attach 'unlocktpmtest' '$loop' 'none' 'tries=0,tpm2-device=$tpm'
UNIT
}

_arm() {  # $1 = what the user types
    rm -rf "$store" "$runsystemd"; : > "$work/asked"
    _write_generated_unit
    _stub_ask "$1"
    PATH="$work/bin:$PATH" \
    SHEDOS_UNLOCK_CMDLINE="$work/cmdline" \
    SHEDOS_UNLOCK_RUNDIR="$work/run" \
    SHEDOS_UNLOCK_CREDSTORE="$store" \
    SHEDOS_UNLOCK_GENDIR="$gen" \
    SHEDOS_UNLOCK_RUNSYSTEMD="$runsystemd" \
    SHEDOS_UNLOCK_DAEMON_RELOAD=true \
    SHEDOS_UNLOCK_SETTLE_SECONDS=5 \
        timeout 120 bash "$tool" arm >"$work/arm.out" 2>&1
}

# The real thing, run the way systemd would: if the unlocker dropped in an
# override, its options are the ones that take effect -- which is exactly how
# the TPM gets left alone.
_attach() {
    cryptsetup close unlocktpmtest 2>/dev/null
    local dropin="$runsystemd/$inst.d/50-shedos-no-tpm2.conf" opts
    if [[ -f $dropin ]]; then
        opts=$(grep '^ExecStart=/usr' "$dropin" | sed -E "s/.*'([^']*)'[[:space:]]*$/\1/")
    else
        opts=$(grep '^ExecStart=/usr' "$gen/$inst" | sed -E "s/.*'([^']*)'[[:space:]]*$/\1/")
    fi
    CREDENTIALS_DIRECTORY="$store" \
    SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0 \
        timeout 90 systemd-cryptsetup attach unlocktpmtest "$loop" none \
        "$opts" </dev/null >"$work/attach.out" 2>&1
    return $?
}

_da_counter() {
    TPM2TOOLS_TCTI="device:$tpm" tpm2_getcap properties-variable 2>/dev/null \
        | sed -n 's/.*TPM2_PT_LOCKOUT_COUNTER: 0x\([0-9A-Fa-f]*\).*/\1/p'
}

# Feeding the chip a passphrase costs one dictionary-attack attempt, and this
# software TPM allows only three before it locks out. Cases would otherwise
# poison each other -- and the lockout is itself a property worth pinning down,
# so L1 below asserts it rather than working around it silently.
_reset_da() { TPM2TOOLS_TCTI="device:$tpm" tpm2_dictionarylockout --clear-lockout >/dev/null 2>&1; }

_case() {  # $1=label $2=typed $3=expect open|closed
    _reset_da
    _arm "$2"
    _attach; local rc=$?
    local state=closed; [[ -e /dev/mapper/unlocktpmtest ]] && state=open
    local asked; asked=$(wc -l < "$work/asked" | tr -d ' ')
    cryptsetup close unlocktpmtest 2>/dev/null
    if [[ $state == "$3" ]] && [[ $asked == 1 ]]; then
        _ok "$1"
    else
        _fail "$1" "expected $3 after 1 prompt, got $state after $asked (attach rc=$rc): $(tail -3 "$work/attach.out" | tr '\n' ' ')"
    fi
}

# This is the reported bug: a TPM2-with-PIN box that would not take the
# passphrase or the recovery key.
_case E1_passphrase_opens_a_tpm2_pin_box   "$PASS"   open
_case E2_recovery_key_opens_a_tpm2_pin_box "$RECOV"  open
_case E3_pin_opens_it_through_the_tpm      "$PIN"    open

# The heart of it. Offering the chip a passphrase does not cost one attempt --
# systemd retries the unseal on every container until the whole allowance is
# gone and the TPM locks out, which is how a passphrase boot came to disable
# the PIN. Deliberately no _reset_da around this: the reset is what hid the
# hammering last time, and a guard that tidies away the failure it exists to
# catch is worse than none.
before=$(_da_counter)
_arm "$PASS"; _attach >/dev/null 2>&1; cryptsetup close unlocktpmtest 2>/dev/null
after=$(_da_counter)
if [[ -n $before && -n $after ]] && (( 0x$after == 0x$before )); then
    _ok L1_passphrase_boot_costs_the_tpm_nothing
else
    _fail L1_passphrase_boot_costs_the_tpm_nothing \
          "lockout counter moved $before -> $after; the chip is still being offered the passphrase"
fi

# Same for the recovery key, and again with no reset in between, so a leak
# would accumulate across both rather than being wiped.
before=$(_da_counter)
_arm "$RECOV"; _attach >/dev/null 2>&1; cryptsetup close unlocktpmtest 2>/dev/null
after=$(_da_counter)
if [[ -n $before && -n $after ]] && (( 0x$after == 0x$before )); then
    _ok L2_recovery_key_boot_costs_the_tpm_nothing
else
    _fail L2_recovery_key_boot_costs_the_tpm_nothing "counter moved $before -> $after"
fi

# A wrong answer must still fail closed rather than open anything.
_reset_da
_arm "not-any-of-them"
_attach >/dev/null 2>&1
if [[ ! -e /dev/mapper/unlocktpmtest ]]; then
    _ok E4_wrong_answer_opens_nothing
else
    _fail E4_wrong_answer_opens_nothing "container opened on a wrong secret"
fi
cryptsetup close unlocktpmtest 2>/dev/null

# A wrong answer must never be stored as a passphrase. systemd prefers a
# credential over asking, so a wrong one under tries=0 is retried forever and
# the boot hangs on a silent spinner with no way back. Only the PIN may hold an
# unproven answer, because one wrong PIN takes the chip out of the running.
_reset_da
_arm "not-any-of-them"
if [[ ! -f $store/cryptsetup.passphrase ]] \
   && [[ $(_cred cryptsetup.tpm2-pin) == "not-any-of-them" ]]; then
    _ok E5_unproven_answer_is_never_stored_as_a_passphrase
else
    _fail E5_unproven_answer_is_never_stored_as_a_passphrase \
          "passphrase=[$(_cred cryptsetup.passphrase)] pin=[$(_cred cryptsetup.tpm2-pin)]"
fi

# The regression itself, under the box's real tries=0: attach must terminate.
# Spinning here is the 45-minute hang, and it looks identical to a slow boot.
_reset_da
_arm "not-any-of-them"
cryptsetup close unlocktpmtest 2>/dev/null
start=$SECONDS
CREDENTIALS_DIRECTORY="$store" SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0 \
    timeout 40 systemd-cryptsetup attach unlocktpmtest "$loop" none \
    "tpm2-device=$tpm,tries=0" </dev/null >"$work/spin.out" 2>&1
elapsed=$(( SECONDS - start ))
tries=$(grep -c 'Failed to activate with specified passphrase' "$work/spin.out")
cryptsetup close unlocktpmtest 2>/dev/null
# Blocking on a prompt is fine and is what should happen -- a person is meant
# to answer it. What must never happen is burning through attempts on a stored
# secret, which shows up as a large count and locks the user out of their own
# boot with no prompt to answer.
if (( tries < 10 )); then
    _ok E6_wrong_answer_does_not_spin_on_a_stored_secret
else
    _fail E6_wrong_answer_does_not_spin_on_a_stored_secret \
          "$tries failed attempts in ${elapsed}s — it is retrying a stored secret"
fi

# Positive control: plant the old bug and confirm E6 would have caught it.
# A guard that cannot fail is not a guard.
_reset_da
rm -rf "$store"; install -d -m 0700 "$store"
printf 'a-secret-no-keyslot-takes' > "$store/cryptsetup.passphrase"
chmod 0400 "$store/cryptsetup.passphrase"
cryptsetup close unlocktpmtest 2>/dev/null
CREDENTIALS_DIRECTORY="$store" SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0 \
    timeout 20 systemd-cryptsetup attach unlocktpmtest "$loop" none "tries=0" \
    </dev/null >"$work/ctl.out" 2>&1
ctl=$(grep -c 'Failed to activate with specified passphrase' "$work/ctl.out")
cryptsetup close unlocktpmtest 2>/dev/null
if (( ctl >= 10 )); then
    _ok E7_control_a_stored_wrong_passphrase_really_does_spin
else
    _fail E7_control_a_stored_wrong_passphrase_really_does_spin \
          "only $ctl attempts — E6 may not detect the regression"
fi

echo
echo "unlock-tpm2: $pass/$((pass + fail)) passed"
if (( fail > 0 )); then printf '  %s\n' "${failures[@]}" >&2; exit 1; fi
exit 0
