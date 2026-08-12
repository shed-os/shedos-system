#!/usr/bin/env bash
# Guard the first-boot recovery-key enrolment (encrypt-enroll.sh): it writes the
# userspace container list, mints one paper key, and adds every spelling to each
# container — root AND the carved swap (the 2026-06-20 swap-prompt RCA) — then
# tags the slots. Secrets never reach argv; an already-enrolled container is left
# alone. cryptsetup is PATH-stubbed; the real shedman key library is sourced so
# the mint/forms/tag logic runs for real.

set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
enroller=$repo_root/tree/usr/lib/shedos/encrypt-enroll.sh
keyverb=$repo_root/tree/usr/libexec/shedman/key

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# Static sandbox: cryptsetup logs argv and `luksDump` prints $DUMP_JSON so a test
# can fake the keyslot/token layout.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/esp"
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
[[ \$1 == luksDump ]] && printf '%s\n' "\${DUMP_JSON:-}"
# open --test-passphrase pre-check: a form counts as enrolled only on a device
# named in STUB_ENROLLED_DEVS; default not-enrolled so a fresh enrol adds it.
if [[ \$1 == open ]]; then
    dev=\${@: -1}
    case " \${STUB_ENROLLED_DEVS:-} " in *" \$dev "*) exit 0 ;; *) exit 1 ;; esac
fi
exit 0
EOF
    chmod +x "$d/bin/cryptsetup"
    printf '%s\n' "$d"
}

# Growing sandbox: luksDump gains one keyslot per luksAddKey, so the before/after
# new-slot detection actually sees the added slots and the tag loop runs. The
# token-import JSON is captured so the role can be asserted.
_grow_stub() {  # $1=dir
    cat > "$1/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/cryptsetup.log"
cnt="$1/slotcount"; [[ -f \$cnt ]] || echo 0 > "\$cnt"
case "\$1" in
  luksAddKey) echo \$(( \$(<"\$cnt") + 1 )) > "\$cnt" ;;
  open) exit 1 ;;   # no form is pre-enrolled, so every add runs
  token)
    jf=\$(printf '%s' "\$*" | sed -n 's/.*--json-file=\([^ ]*\).*/\1/p')
    [[ -n \$jf && -f \$jf ]] && { cat "\$jf"; echo; } >> "$1/tokens.log" ;;
  luksDump)
    n=\$(<"\$cnt"); s='"0":{}'
    for ((i = 1; i <= n; i++)); do s="\$s,\"\$i\":{}"; done
    printf '{"keyslots":{%s},"tokens":{}}\n' "\$s" ;;
esac
exit 0
EOF
    chmod +x "$1/bin/cryptsetup"
}

# Run the whole enrol script in the sandbox; every path redirects into $d.
_run_enroll() {
    local d=$1; shift
    PATH="$d/bin:$PATH" \
    ESP_STATE_FILE="$d/esp/state" \
    SHEDOS_REENCRYPT_KEYFILE="$d/esp/key" \
    SHEDMAN_KEY="$keyverb" \
    SHEDMAN_KEY_CONTAINERS="$d/containers" \
    SHEDMAN_KEY_TMPDIR="$d" \
    SHEDOS_RECOVERY_STASH="$d/stash/recovery-key" \
    DUMP_JSON="${DUMP_JSON:-}" \
        bash "$enroller" "$@"
}

# Source the enroller (its source-guard skips main) and call _machine_key on the
# joined container list, with the token probe reporting a slot for any device in
# $2 (a space-separated list of "already enrolled" containers). Echoes "rc|key".
_mk_run() {  # $1=dir $2=tagged-devs $3...=containers
    local d=$1 tagged=$2; shift 2
    PATH="$d/bin:$PATH" SHEDOS_RECOVERY_STASH="$d/stash/recovery-key" \
    SHEDMAN_KEY="$keyverb" SHEDMAN_KEY_TMPDIR="$d" ESP_STATE_FILE="$d/esp/state" \
    TAGGED_DEVS="$tagged" \
        bash -c '
            source "'"$enroller"'" >/dev/null 2>&1
            _slots_with_token() { case " $TAGGED_DEVS " in *" $1 "*) echo 1 ;; esac; }
            out=$(_machine_key "$*"); rc=$?
            printf "%s|%s" "$rc" "$out"
        ' _ "$@"
}

# EN1: enrolment runs luksAddKey on EVERY container — root AND the carved swap.
# Enrolling root only is the 2026-06-20 swap-prompt RCA.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA /dev/disk/by-uuid/BB\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"   # no trailing newline
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1
if grep -qE 'luksAddKey .* /dev/disk/by-uuid/AA ' "$d/cryptsetup.log" 2>/dev/null \
   && grep -qE 'luksAddKey .* /dev/disk/by-uuid/BB ' "$d/cryptsetup.log" 2>/dev/null; then
    _ok EN1_enrol_root_and_swap
else
    _fail EN1_enrol_root_and_swap "$(grep luksAddKey "$d/cryptsetup.log" 2>/dev/null)"
fi

# EN2: EVERY added recovery slot is tagged shedos-recovery (token import via a
# file, never a pipe) — not just one. main enrols several spellings as separate
# slots, so under-tagging would leave old-key spellings that rotate-recovery cannot
# retire; assert one tag per add.
d=$(_mk_sandbox); _grow_stub "$d"
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
_run_enroll "$d" >/dev/null 2>&1
adds=$(grep -c 'luksAddKey' "$d/cryptsetup.log" 2>/dev/null)
tags=$(grep -c 'shedos-recovery' "$d/tokens.log" 2>/dev/null)
if grep -q 'token import --json-file=' "$d/cryptsetup.log" 2>/dev/null \
   && (( adds >= 2 )) && (( tags == adds )); then
    _ok EN2_tag_every_recovery_slot
else
    _fail EN2_tag_every_recovery_slot "adds=$adds tags=$tags"
fi

# EN3: a container already carrying a shedos-recovery token is skipped whole —
# zero luksAddKey. Models a re-run after a crash.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
DUMP_JSON='{"keyslots":{"0":{},"1":{}},"tokens":{"0":{"type":"shedos-recovery","keyslots":["1"]}}}' \
    _run_enroll "$d" >/dev/null 2>&1
if ! grep -q luksAddKey "$d/cryptsetup.log" 2>/dev/null; then _ok EN3_idempotent_skip; else _fail EN3_idempotent_skip "$(grep luksAddKey "$d/cryptsetup.log" 2>/dev/null)"; fi

# EN4: neither the authorising passphrase nor any spelling of the minted key
# reaches cryptsetup's argv; the new key is a --key-file PATH.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1
minted=$(cat "$d/stash/recovery-key" 2>/dev/null)
if grep -q 'diskpw' "$d/cryptsetup.log" 2>/dev/null; then
    _fail EN4_no_secret_argv "auth passphrase on argv"
elif [[ -n $minted ]] && grep -qiF "${minted//-/}" "$d/cryptsetup.log" 2>/dev/null; then
    _fail EN4_no_secret_argv "recovery key on argv"
elif grep -qE 'luksAddKey --key-file=[^ ]+ /dev/disk/by-uuid/AA [^ ]+$' "$d/cryptsetup.log" 2>/dev/null; then
    _ok EN4_no_secret_argv
else
    _fail EN4_no_secret_argv "$(grep luksAddKey "$d/cryptsetup.log" 2>/dev/null)"
fi

# EN5: /etc/shedos/secureboot/containers is written root-first then swap, one path
# per line with a trailing newline — the format the installer writes, so the
# post-boot key/tpm2 verbs resolve the new containers.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA /dev/disk/by-uuid/BB\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1
printf '/dev/disk/by-uuid/AA\n/dev/disk/by-uuid/BB\n' > "$d/want"
if diff -q "$d/want" "$d/containers" >/dev/null 2>&1; then _ok EN5_containers_file; else _fail EN5_containers_file "$(cat -A "$d/containers" 2>/dev/null)"; fi

# EN6: no handoff (no enroll_containers=) is a clean no-op — no luksAddKey, rc 0.
d=$(_mk_sandbox)
printf 'phase=encrypting\n' > "$d/esp/state"
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]] && ! grep -q luksAddKey "$d/cryptsetup.log" 2>/dev/null; then _ok EN6_noop_no_handoff; else _fail EN6_noop_no_handoff "rc=$rc $(grep luksAddKey "$d/cryptsetup.log" 2>/dev/null)"; fi

# EN7: with the handoff present but the auth keyfile gone, enrolment defers (no
# luksAddKey, rc 0) but the container list is still recorded for the retry.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"   # no $d/esp/key
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]] && ! grep -q luksAddKey "$d/cryptsetup.log" 2>/dev/null \
   && grep -qx '/dev/disk/by-uuid/AA' "$d/containers" 2>/dev/null; then
    _ok EN7_defer_no_auth
else
    _fail EN7_defer_no_auth "rc=$rc cont=[$(cat "$d/containers" 2>/dev/null)]"
fi

# EN8: when it enrols, the minted key is stashed 0660 in a 0755 dir so the first-login
# tour (a wheel desktop user) can read it then shred it; the chgrp to wheel is
# best-effort (root-only), so the test asserts only the modes.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1
perm=$(stat -c '%a' "$d/stash/recovery-key" 2>/dev/null)
dperm=$(stat -c '%a' "$d/stash" 2>/dev/null)
if [[ -s $d/stash/recovery-key && $perm == 660 && $dperm == 755 ]]; then _ok EN8_stash_minted; else _fail EN8_stash_minted "perm=$perm dir=$dperm exists=$([[ -f $d/stash/recovery-key ]] && echo y || echo n)"; fi

# EN11: a retry reuses the key a prior run stashed — every container converges on
# the SAME key, never a split key (the blocker the adversarial review caught). The
# prior run enrolled root (AA); this run must add to swap (BB) with the SAME key
# and never re-mint.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA /dev/disk/by-uuid/BB\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
mkdir -p "$d/stash"; printf 'PRIORKEY-FROM-LAST-RUN' > "$d/stash/recovery-key"
STUB_ENROLLED_DEVS='/dev/disk/by-uuid/AA' DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' \
    _run_enroll "$d" >/dev/null 2>&1
stash_after=$(cat "$d/stash/recovery-key" 2>/dev/null)
if grep -qE 'luksAddKey .* /dev/disk/by-uuid/BB ' "$d/cryptsetup.log" 2>/dev/null \
   && ! grep -qE 'luksAddKey .* /dev/disk/by-uuid/AA ' "$d/cryptsetup.log" 2>/dev/null \
   && [[ $stash_after == 'PRIORKEY-FROM-LAST-RUN' ]]; then
    _ok EN11_reuse_stashed_key
else
    _fail EN11_reuse_stashed_key "stash=[$stash_after] adds=[$(grep luksAddKey "$d/cryptsetup.log" 2>/dev/null)]"
fi

# EN12: once every container is enrolled, the ESP handoff (enroll_containers=) is
# cleared so later boots stop rewriting the userspace container list.
d=$(_mk_sandbox)
printf 'phase=flip-pending\nenroll_containers=/dev/disk/by-uuid/AA\n' > "$d/esp/state"
printf 'diskpw' > "$d/esp/key"; chmod 600 "$d/esp/key"
DUMP_JSON='{"keyslots":{"0":{}},"tokens":{}}' _run_enroll "$d" >/dev/null 2>&1
val=$(ESP_STATE_FILE="$d/esp/state" bash -c "source '$repo_root/tree/usr/lib/shedos/esp-state.sh'; esp_state_get enroll_containers")
if [[ -z $val ]]; then _ok EN12_clears_handoff; else _fail EN12_clears_handoff "enroll_containers=[$val]"; fi

# EN13a/b/c: _machine_key classifies a machine with NO stashed key — mint when
# none enrolled, no-op when all enrolled, and FAIL LOUD when partial (the
# swap-strand RCA class: a half-enrolled machine whose key is gone must never
# silently leave a container unprotected or mint a second divergent key).
d=$(_mk_sandbox)
r=$(_mk_run "$d" '' /dev/AA /dev/BB)                          # none tagged
if [[ ${r%%|*} == 0 && -n ${r#*|} && -s $d/stash/recovery-key ]]; then _ok EN13a_mint_when_none; else _fail EN13a_mint_when_none "r=[$r]"; fi
d=$(_mk_sandbox)
r=$(_mk_run "$d" '/dev/AA /dev/BB' /dev/AA /dev/BB)           # every dev tagged
if [[ ${r%%|*} == 0 && -z ${r#*|} && ! -s $d/stash/recovery-key ]]; then _ok EN13b_done_when_all; else _fail EN13b_done_when_all "r=[$r]"; fi
d=$(_mk_sandbox)
r=$(_mk_run "$d" '/dev/AA' /dev/AA /dev/BB)                   # AA tagged, BB not
if [[ ${r%%|*} == 1 && -z ${r#*|} ]]; then _ok EN13c_loud_on_partial; else _fail EN13c_loud_on_partial "r=[$r]"; fi

# EN9: the unit self-gates on the ESP state file, is a oneshot, runs the enroller,
# and is pulled into multi-user.target.
unit=$repo_root/tree/usr/lib/systemd/system/shedos-encrypt-enroll.service
if grep -q '^ConditionPathExists=/boot/efi/shedos-encrypt/state$' "$unit" 2>/dev/null \
   && grep -q '^Type=oneshot$' "$unit" 2>/dev/null \
   && grep -q '^ExecStart=/usr/lib/shedos/encrypt-enroll.sh$' "$unit" 2>/dev/null \
   && grep -q '^WantedBy=multi-user.target$' "$unit" 2>/dev/null; then
    _ok EN9_unit_shape
else
    _fail EN9_unit_shape "$(cat "$unit" 2>/dev/null)"
fi

# EN10: the scriptlet enables the unit on install AND upgrade, and the PKGBUILD
# ships both files (the staged-but-not-installed class of bug).
scriptlet=$repo_root/shedos-system.install
pkgbuild=$repo_root/PKGBUILD
n=$(grep -c 'systemctl enable shedos-encrypt-enroll.service' "$scriptlet" 2>/dev/null)
if (( n >= 2 )) \
   && grep -q 'tree/usr/lib/shedos/encrypt-enroll.sh' "$pkgbuild" 2>/dev/null \
   && grep -q 'tree/usr/lib/systemd/system/shedos-encrypt-enroll.service' "$pkgbuild" 2>/dev/null; then
    _ok EN10_packaged_enabled
else
    _fail EN10_packaged_enabled "enable_count=$n"
fi

total=$((pass + fail)); echo; echo "encrypt-enroll: $pass/$total passed"
(( fail == 0 ))
