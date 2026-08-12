#!/usr/bin/env bash
# Guard the `shedman key` verb: it changes the passphrase, rotates the recovery
# key, and adds/removes keyslots on every encrypted container — secrets never on
# argv, never stranding a way in. cryptsetup + systemd-cryptenroll are
# PATH-stubbed so they log argv instead of touching a disk; container state is
# faked via the verb's SHEDMAN_* overrides and `luksDump` prints $DUMP_JSON.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
verb=$repo_root/tree/usr/libexec/shedman/key

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A sandbox with PATH-stubbed binaries. cryptsetup logs argv to
# $d/cryptsetup.log; `cryptsetup luksDump …` prints the $DUMP_JSON env so tests
# can fake the keyslot/token layout. A stubbed `id -u` reports $STUB_UID
# (default 0) so the root-guarded paths run unprivileged in CI.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin"
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
if [[ \$1 == luksDump ]]; then printf '%s\n' "\${DUMP_JSON:-}"; fi
exit 0
EOF
    cat > "$d/bin/systemd-cryptenroll" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/enroll.log"
exit 0
EOF
    cat > "$d/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
    chmod +x "$d/bin/cryptsetup" "$d/bin/systemd-cryptenroll" "$d/bin/id"
    printf '%s\n' "$d"
}

# Run the verb in the sandbox. $1=dir $2=action ...flags. STDIN flows from the
# caller; $DUMP_JSON / $CONTAINERS / $CRYPTTAB pass through to the verb + stubs.
_run() {
    local d=$1 action=$2; shift 2
    PATH="$d/bin:$PATH" \
    SHEDMAN_KEY_CONTAINERS="${CONTAINERS:-$d/containers}" \
    SHEDMAN_CRYPTTAB="${CRYPTTAB:-$d/crypttab}" \
    SHEDMAN_KEY_TMPDIR="$d" \
    DUMP_JSON="${DUMP_JSON:-}" \
        bash "$verb" "$action" "$@"
}

# C1: --help exits 0 with the usage banner.
d=$(_mk_sandbox)
out=$(_run "$d" --help); rc=$?
if [[ $rc -eq 0 && $out == *"Usage: sudo shedman key"* ]]; then _ok C1_help; else _fail C1_help "rc=$rc"; fi

# C2: an unknown subcommand exits 2.
_run "$d" frobnicate >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then _ok C2_unknown; else _fail C2_unknown "rc=$rc"; fi

# C3: no encrypted disks → exit 1, fail-loud.
printf '' > "$d/containers"
out=$(_run "$d" --status 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *"no encrypted disks"* ]]; then _ok C3_unencrypted; else _fail C3_unencrypted "rc=$rc out=$out"; fi

# C4: --status names each slot's role from the LUKS2 tokens.
printf '/dev/mapper/fake\n' > "$d/containers"
DUMP_JSON='{"keyslots":{"0":{},"1":{},"5":{}},"tokens":{"0":{"type":"shedos-recovery","keyslots":["1"]},"1":{"type":"systemd-tpm2","keyslots":["5"]}}}'
out=$(DUMP_JSON="$DUMP_JSON" _run "$d" --status)
if [[ $out == *"slot 0"*"passphrase"* && $out == *"slot 1"*"recovery"* && $out == *"slot 5"*"tpm2"* ]]; then
    _ok C4_status_roles
else
    _fail C4_status_roles "$out"
fi

# C5: --status can't read the header (non-root) → points at sudo, not empty slots.
printf '/dev/mapper/fake\n' > "$d/containers"
out=$(DUMP_JSON='' _run "$d" --status 2>&1)
if [[ $out == *"unable to read"* && $out == *"sudo shedman key --status"* && $out != *"slot "* ]]; then
    _ok C5_status_unreadable_hint
else
    _fail C5_status_unreadable_hint "$out"
fi

# CP1: change-passphrase runs luksChangeKey on every container.
d=$(_mk_sandbox)
printf '/dev/mapper/root\n/dev/mapper/swap\n' > "$d/containers"
printf 'oldpw\nnewpw\nnewpw\n' | _run "$d" change-passphrase --yes >/dev/null 2>&1
if grep -q 'luksChangeKey /dev/mapper/root' "$d/cryptsetup.log" 2>/dev/null \
   && grep -q 'luksChangeKey /dev/mapper/swap' "$d/cryptsetup.log" 2>/dev/null; then
    _ok CP1_both
else
    _fail CP1_both "$(cat "$d/cryptsetup.log" 2>/dev/null)"
fi

# CP2: no passphrase reaches argv (the cryptsetup stub logs $*).
if grep -qE 'oldpw|newpw' "$d/cryptsetup.log" 2>/dev/null; then
    _fail CP2_no_secret_argv "secret on argv"
else
    _ok CP2_no_secret_argv
fi

# G1-G3: the recovery-key generator — source the verb to reach its internals.
# shellcheck source=/dev/null
source "$verb"
key=$(_gen_recovery); stripped=${key//-/}
if [[ ${#stripped} -eq 25 && $stripped =~ ^[ABCDEFGHJKMNPRSTVWXYZ347]+$ ]]; then
    _ok G1_format
else
    _fail G1_format "$key"
fi
if [[ "$(_gen_recovery)" != "$(_gen_recovery)" ]]; then _ok G2_random; else _fail G2_random "identical draws"; fi
mapfile -t forms < <(_recovery_forms "AB-CD")
got=$(printf '%s\n' "${forms[@]}" | sort | tr '\n' ' ')
want=$(printf '%s\n' AB-CD ABCD ab-cd abcd | sort | tr '\n' ' ')
if [[ $got == "$want" ]]; then _ok G3_forms; else _fail G3_forms "got=$got"; fi

# TK1-TK3: token helpers (cryptsetup stubbed via PATH; luksDump prints $DUMP_JSON).
d=$(_mk_sandbox); _tk_old=$PATH; PATH="$d/bin:$PATH"
export DUMP_JSON='{"keyslots":{"0":{},"1":{},"2":{}},"tokens":{"0":{"type":"shedos-recovery","keyslots":["1"]},"1":{"type":"shedos-recovery","keyslots":["2"]}}}'
got=$(_slots_with_token /dev/x shedos-recovery | tr '\n' ' ')
if [[ $got == "1 2 " ]]; then _ok TK1_slots_with_token; else _fail TK1_slots_with_token "$got"; fi
SHEDMAN_KEY_TMPDIR=$d _tag_slot /dev/x 3 shedos-recovery
if grep -q 'token import --json-file=' "$d/cryptsetup.log" 2>/dev/null; then _ok TK2_tag_json_file; else _fail TK2_tag_json_file "$(cat "$d/cryptsetup.log" 2>/dev/null)"; fi
_untag_slot /dev/x 1   # token "0" references slot 1
if grep -q 'token remove --token-id 0 /dev/x' "$d/cryptsetup.log" 2>/dev/null; then _ok TK3_untag; else _fail TK3_untag "$(grep token "$d/cryptsetup.log" 2>/dev/null)"; fi
PATH=$_tk_old; unset DUMP_JSON

# R1-R3: rotate-recovery command structure (the full proof is the real-container
# run in the Makefile/dev box; the static stub can only check the sequence).
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
rjson='{"keyslots":{"0":{},"1":{},"2":{}},"tokens":{"0":{"type":"shedos-recovery","keyslots":["1"]},"1":{"type":"shedos-recovery","keyslots":["2"]}}}'
printf 'pw\n' | DUMP_JSON="$rjson" _run "$d" rotate-recovery --yes >/dev/null 2>&1
addline=$(grep -n luksAddKey "$d/cryptsetup.log" 2>/dev/null | tail -1 | cut -d: -f1)
killline=$(grep -n luksKillSlot "$d/cryptsetup.log" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -z $killline || ( -n $addline && $addline -lt $killline ) ]]; then _ok R1_add_before_kill; else _fail R1_add_before_kill "add@$addline kill@$killline"; fi
if grep -qE 'luksKillSlot.* 1$' "$d/cryptsetup.log" 2>/dev/null && grep -qE 'luksKillSlot.* 2$' "$d/cryptsetup.log" 2>/dev/null; then _ok R2_kills_old_recovery; else _fail R2_kills_old_recovery "$(grep luksKillSlot "$d/cryptsetup.log" 2>/dev/null)"; fi
# R3: an untagged box triggers the backfill (test-passphrase per slot).
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
printf 'pw\noldrec\n' | DUMP_JSON='{"keyslots":{"0":{},"1":{}},"tokens":{}}' _run "$d" rotate-recovery --yes >/dev/null 2>&1
if grep -q -- '--test-passphrase --key-slot' "$d/cryptsetup.log" 2>/dev/null; then _ok R3_backfill; else _fail R3_backfill "$(grep -i test "$d/cryptsetup.log" 2>/dev/null)"; fi

# A1-A2: add-key adds a passphrase slot on every container (the shedos-added
# tagging is proven by the real-container run; a static stub can't show the new
# slot appearing).
d=$(_mk_sandbox); printf '/dev/mapper/root\n/dev/mapper/swap\n' > "$d/containers"
printf 'authpw\nnewpw\nnewpw\n' | DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run "$d" add-key --yes >/dev/null 2>&1
c=$(grep -c luksAddKey "$d/cryptsetup.log" 2>/dev/null)
if [[ $c -eq 2 ]]; then _ok A1_addkey_each; else _fail A1_addkey_each "count=$c"; fi
if grep -qE 'authpw|newpw' "$d/cryptsetup.log" 2>/dev/null; then _fail A2_no_secret_argv "secret on argv"; else _ok A2_no_secret_argv; fi

# F1-F2: add-key --fido2 enrolls a FIDO2 token on every container and leaves
# crypttab alone. ShedOS unlocks from rd.luks.name on the cmdline, and
# systemd-cryptsetup auto-tries the enrolled header token at boot (proven against
# a software TPM), so there is nothing to wire into crypttab.
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
printf 'orig-crypttab\n' > "$d/crypttab"
printf 'authpw\n' | _run "$d" add-key --fido2 --yes >/dev/null 2>&1
if grep -q -- '--fido2-device=auto /dev/mapper/root' "$d/enroll.log" 2>/dev/null; then _ok F1_fido2_enroll; else _fail F1_fido2_enroll "$(cat "$d/enroll.log" 2>/dev/null)"; fi
if [[ "$(cat "$d/crypttab" 2>/dev/null)" == 'orig-crypttab' ]]; then _ok F2_crypttab_untouched; else _fail F2_crypttab_untouched "$(cat "$d/crypttab" 2>/dev/null)"; fi

# RM1-RM4: remove-key kills the named slot (auth over stdin, untags it) and
# refuses to strand the user — last keyslot, the tpm2 slot, or the last
# passphrase/recovery slot when only a tpm2/fido2 slot would remain.
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
printf 'authpw\n' | DUMP_JSON='{"keyslots":{"0":{},"3":{}},"tokens":{"0":{"type":"shedos-added","keyslots":["3"]}}}' _run "$d" remove-key 3 --yes >/dev/null 2>&1
if grep -q 'luksKillSlot --key-file=- /dev/mapper/root 3' "$d/cryptsetup.log" 2>/dev/null; then _ok RM1_kills; else _fail RM1_kills "$(cat "$d/cryptsetup.log" 2>/dev/null)"; fi
if grep -q 'authpw' "$d/cryptsetup.log" 2>/dev/null; then _fail RM1_no_secret_argv "secret on argv"; else _ok RM1_no_secret_argv; fi
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
out=$(DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run "$d" remove-key 0 --yes 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *last* ]] && ! grep -q luksKillSlot "$d/cryptsetup.log" 2>/dev/null; then _ok RM2_last_guard; else _fail RM2_last_guard "rc=$rc out=$out"; fi
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
out=$(DUMP_JSON='{"keyslots":{"0":{},"5":{}},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["5"]}}}' _run "$d" remove-key 5 --yes 2>&1)
if [[ $out == *"shedman tpm2"* ]] && ! grep -q luksKillSlot "$d/cryptsetup.log" 2>/dev/null; then _ok RM3_tpm2_defer; else _fail RM3_tpm2_defer "$out"; fi
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
out=$(DUMP_JSON='{"keyslots":{"0":{},"5":{}},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["5"]}}}' _run "$d" remove-key 0 --yes 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *last* ]] && ! grep -q luksKillSlot "$d/cryptsetup.log" 2>/dev/null; then _ok RM4_last_durable; else _fail RM4_last_durable "rc=$rc out=$out"; fi
# RM5: a FIDO2 slot is removed by remove-key itself — no raw-tool defer, and the
# last-durable guard does not fire on it (the passphrase remains).
d=$(_mk_sandbox); printf '/dev/mapper/root\n' > "$d/containers"
out=$(printf 'authpw\n' | DUMP_JSON='{"keyslots":{"0":{},"5":{}},"tokens":{"0":{"type":"systemd-fido2","keyslots":["5"]}}}' _run "$d" remove-key 5 --yes 2>&1)
if grep -q 'luksKillSlot --key-file=- /dev/mapper/root 5' "$d/cryptsetup.log" 2>/dev/null && [[ $out != *systemd-cryptenroll* ]]; then _ok RM5_fido2_removed; else _fail RM5_fido2_removed "$out | $(cat "$d/cryptsetup.log" 2>/dev/null)"; fi

total=$((pass + fail))
echo
echo "key: $pass/$total passed"
(( fail == 0 ))
