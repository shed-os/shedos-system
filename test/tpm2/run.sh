#!/usr/bin/env bash
# Guard the `shedman tpm2` verb: it enrolls a passwordless TPM2 unlock slot
# (add-only, signed PCR-11 policy) only under Secure Boot, never touches the
# passphrase/recovery slots, and refuses every mutating path without consent.
# systemd-cryptenroll + cryptsetup are PATH-stubbed so they log their argv
# instead of touching a real disk; firmware/key/container state is faked via
# the verb's SHEDMAN_* overrides.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
verb=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman/tpm2

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# A sandbox with PATH-stubbed binaries. $1 = cryptenroll exit code (logs argv
# to $sb/enroll.log), $2 = luksDump body that `cryptsetup luksDump` prints.
# A stubbed `id -u` reports $STUB_UID (default 0) so the root-guarded paths run
# unprivileged in CI.
_mk_sandbox() {
    local d enroll_rc=${1:-0} dump=${2:-}
    d=$(mktemp -d)
    mkdir -p "$d/bin"
    cat > "$d/bin/systemd-cryptenroll" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/enroll.log"
exit $enroll_rc
EOF
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
if [[ \$1 == luksDump ]]; then
    cat <<'DUMP'
$dump
DUMP
fi
exit 0
EOF
    cat > "$d/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
    cat > "$d/bin/pin-boot" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/pinboot.log"
exit \${PINBOOT_RC:-0}
EOF
    chmod +x "$d/bin/systemd-cryptenroll" "$d/bin/cryptsetup" "$d/bin/id" "$d/bin/pin-boot"
    printf '%s\n' "$d"
}

# Firmware fixtures: a Secure-Boot-active efivar (5 bytes, byte[4]=1), an
# inactive one (byte[4]=0), an EFI sysfs dir, and a PCR public key.
_sb_on_efivar()  { printf '\006\000\000\000\001' > "$1"; }
_sb_off_efivar() { printf '\006\000\000\000\000' > "$1"; }

# Run the verb in a fully-faked environment. Named args via env:
#   SB=on|off|bios  PCR=present|absent  CONTAINERS=<file or "->" for crypttab>
# extra positional args after the action pass straight through.
_run() { # $1=sandbox $2=action ...flags  (env: SB, PCR, CONTAINERS, CRYPTTAB, STDIN)
    local d=$1 action=$2; shift 2
    local efi="$d/efi" efivar="$d/sb-efivar" pcr="$d/pcr-public.pem"
    local containers="${CONTAINERS:-$d/containers}" crypttab="${CRYPTTAB:-$d/crypttab}"
    rm -rf "$efi"
    case "${SB:-on}" in
        on)   mkdir -p "$efi"; _sb_on_efivar "$efivar" ;;
        off)  mkdir -p "$efi"; _sb_off_efivar "$efivar" ;;
        bios) rm -f "$efivar" ;;   # no /sys/firmware/efi dir
    esac
    case "${PCR:-present}" in
        present) printf 'PUBKEY\n' > "$pcr" ;;
        absent)  rm -f "$pcr" ;;
    esac
    PATH="$d/bin:$PATH" \
    SHEDMAN_TPM2_CONTAINERS="$containers" \
    SHEDMAN_PCR_PUBKEY="$pcr" \
    SHEDMAN_CRYPTTAB="$crypttab" \
    SHEDMAN_EFI_DIR="$efi" \
    SHEDMAN_SECUREBOOT_EFIVAR="$efivar" \
    SHEDMAN_TPM2_PIN_BOOT="$d/bin/pin-boot" \
    SHEDOS_TPM2_PIN_DROPIN="${PIN_DROPIN:-$d/pin-dropin.conf}" \
        bash "$verb" "$action" "$@"
}

# --------------------------------------------------------------------------
# T1: enroll refuses on SB-off and on BIOS — no cryptenroll call either way.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; SB=off _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T1a_enroll_refuses_sb_off
else
    _fail T1a_enroll_refuses_sb_off "SB-off enroll ran cryptenroll or exited 0 (rc=$rc)"
fi
rc=0; SB=bios _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T1b_enroll_refuses_bios
else
    _fail T1b_enroll_refuses_bios "BIOS enroll ran cryptenroll or exited 0 (rc=$rc)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T2: enroll refuses when the PCR signing key is missing.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; PCR=absent _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T2_enroll_refuses_no_key
else
    _fail T2_enroll_refuses_no_key "enroll proceeded without the signing key (rc=$rc)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T3: enroll runs cryptenroll once per container with the signed-policy flags
#     and NO --wipe-slot (add-only); the passphrase never reaches argv.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n/dev/mapper/swap\n' > "$d/containers"
rc=0; _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
log=$(cat "$d/enroll.log" 2>/dev/null)
calls=$(grep -c . <<<"$log")
if (( rc == 0 )) && (( calls == 2 )) \
   && grep -q -- '--tpm2-device=auto' <<<"$log" \
   && grep -q -- "--tpm2-public-key=$d/pcr-public.pem" <<<"$log" \
   && grep -q -- '--tpm2-public-key-pcrs=11' <<<"$log" \
   && grep -q '/dev/mapper/root' <<<"$log" \
   && grep -q '/dev/mapper/swap' <<<"$log" \
   && ! grep -q -- '--wipe-slot' <<<"$log" \
   && ! grep -q -- '--tpm2-with-pin' <<<"$log" \
   && ! grep -qiE 'pass|PASSWORD' <<<"$log"; then
    _ok T3_enroll_add_only_per_container
else
    _fail T3_enroll_add_only_per_container "enroll argv wrong (rc=$rc calls=$calls): $log"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T4: --with-pin appends --tpm2-with-pin=yes.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
_run "$d" enroll --yes --with-pin >/dev/null 2>&1
if grep -q -- '--tpm2-with-pin=yes' "$d/enroll.log"; then
    _ok T4_with_pin
else
    _fail T4_with_pin "--with-pin did not append --tpm2-with-pin=yes: $(cat "$d/enroll.log")"
fi
# The consent warning must say what the PIN does to the boot prompt.
err=$(_run "$d" enroll --yes --with-pin 2>&1 >/dev/null)
if grep -q 'gives up after five wrong entries' <<<"$err"; then
    _ok T4b_with_pin_warns_boot_prompt
else
    _fail T4b_with_pin_warns_boot_prompt "enroll --with-pin consent text missing the boot-prompt warning: $err"
fi
# --with-pin must configure the native boot path; a plain enroll must not.
if grep -qx 'configure' "$d/pinboot.log" 2>/dev/null; then
    _ok T4c_with_pin_configures_boot_path
else
    _fail T4c_with_pin_configures_boot_path "pin-boot configure never ran: $(cat "$d/pinboot.log" 2>/dev/null)"
fi
rm -f "$d/pinboot.log"
_run "$d" enroll --yes >/dev/null 2>&1
if [[ ! -f $d/pinboot.log ]]; then
    _ok T4d_plain_enroll_leaves_boot_path
else
    _fail T4d_plain_enroll_leaves_boot_path "plain enroll touched pin-boot: $(cat "$d/pinboot.log")"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T5: remove wipes the tpm2 slot and never enrolls.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; _run "$d" remove --yes >/dev/null 2>&1 || rc=$?
log=$(cat "$d/enroll.log" 2>/dev/null)
if (( rc == 0 )) \
   && grep -q -- '--wipe-slot=tpm2' <<<"$log" \
   && grep -q '/dev/mapper/root' <<<"$log" \
   && ! grep -q -- '--tpm2-public-key' <<<"$log"; then
    _ok T5_remove_wipes_only
else
    _fail T5_remove_wipes_only "remove did not wipe-only (rc=$rc): $log"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T6: re-enroll wipes the tpm2 slot THEN enrolls fresh, per container.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; _run "$d" re-enroll --yes >/dev/null 2>&1 || rc=$?
log=$(cat "$d/enroll.log" 2>/dev/null)
if (( rc == 0 )) \
   && [[ "$(head -n1 "$d/enroll.log")" == *'--wipe-slot=tpm2'* ]] \
   && grep -q -- '--tpm2-public-key' <<<"$log"; then
    _ok T6_reenroll_wipes_then_enrolls
else
    _fail T6_reenroll_wipes_then_enrolls "re-enroll order/flags wrong (rc=$rc): $log"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T7: container resolution falls back to /etc/crypttab when the containers
#     file is absent — UUID= sources resolve to /dev/disk/by-uuid/.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
rm -f "$d/containers"   # no install-written list
cat > "$d/crypttab" <<'EOF'
# <name>  <source>                <key>  <opts>
root   UUID=11111111-2222-3333-4444-555555555555  none  luks
swap   /dev/sda3                                  none  luks
EOF
rc=0; _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
log=$(cat "$d/enroll.log" 2>/dev/null)
if (( rc == 0 )) \
   && grep -q '/dev/disk/by-uuid/11111111-2222-3333-4444-555555555555' <<<"$log" \
   && grep -q '/dev/sda3' <<<"$log"; then
    _ok T7_crypttab_fallback
else
    _fail T7_crypttab_fallback "crypttab fallback did not resolve sources (rc=$rc): $log"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T8: the confirmation gate aborts (no cryptenroll) when stdin is a pipe and
#     no --yes flag is given; an interactive 'no' likewise aborts.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; _run "$d" enroll </dev/null >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T8a_aborts_without_yes
else
    _fail T8a_aborts_without_yes "enroll proceeded with no consent (rc=$rc)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T9: --status reports enrolled vs passphrase-only by reading luksDump.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0 $'Tokens:\n  0: systemd-tpm2')
printf '/dev/mapper/root\n' > "$d/containers"
out=$(_run "$d" --status 2>/dev/null)
if grep -q 'TPM2 unlock enrolled' <<<"$out"; then
    _ok T9a_status_enrolled
else
    _fail T9a_status_enrolled "status did not report the tpm2 slot: $out"
fi
rm -rf "$d"
d=$(_mk_sandbox 0 $'Keyslots:\n  0: luks2')
printf '/dev/mapper/root\n' > "$d/containers"
out=$(_run "$d" --status 2>/dev/null)
if grep -q 'passphrase only' <<<"$out"; then
    _ok T9b_status_passphrase_only
else
    _fail T9b_status_passphrase_only "status misreported a passphrase-only disk: $out"
fi
rm -rf "$d"
# A PIN-carrying token must be called out, and a missing passphrase
# fallback is the one state status must never stay quiet about.
d=$(_mk_sandbox 0 $'Tokens:\n  0: systemd-tpm2\n\ttpm2-pin: true')
printf '/dev/mapper/root\n' > "$d/containers"
out=$(_run "$d" --status 2>/dev/null)
if grep -q 'PIN required at boot' <<<"$out" \
   && grep -q 'passphrase fallback is not' <<<"$out"; then
    _ok T9c_status_warns_unconfigured_pin
else
    _fail T9c_status_warns_unconfigured_pin "status hid the missing fallback: $out"
fi
# With the drop-in in place, status reports the bounded prompt instead.
: > "$d/pin-dropin.conf"
out=$(_run "$d" --status 2>/dev/null)
if grep -q 'falls back to the passphrase prompt' <<<"$out"; then
    _ok T9d_status_reports_bounded_prompt
else
    _fail T9d_status_reports_bounded_prompt "status missed the configured fallback: $out"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T10: an empty container set fails loud (no cryptenroll) — never a silent
#      no-op when neither the file nor crypttab yields a device.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
: > "$d/containers"; : > "$d/crypttab"
rc=0; _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T10_empty_container_set_fails
else
    _fail T10_empty_container_set_fails "empty container set did not fail loud (rc=$rc)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T11: a per-container cryptenroll failure exits non-zero (no silent failure),
#      still attempting every container.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 1)   # cryptenroll always fails
printf '/dev/mapper/root\n/dev/mapper/swap\n' > "$d/containers"
rc=0; _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
calls=$(grep -c . "$d/enroll.log" 2>/dev/null)
if (( rc != 0 )) && (( calls == 2 )); then
    _ok T11_failure_exits_nonzero
else
    _fail T11_failure_exits_nonzero "enroll failure not surfaced (rc=$rc calls=$calls)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T12: a mutating action without root refuses before touching anything.
# --------------------------------------------------------------------------
d=$(_mk_sandbox 0)
printf '/dev/mapper/root\n' > "$d/containers"
rc=0; STUB_UID=1000 _run "$d" enroll --yes >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ ! -f $d/enroll.log ]]; then
    _ok T12_enroll_needs_root
else
    _fail T12_enroll_needs_root "enroll ran without root (rc=$rc)"
fi
rm -rf "$d"

# --------------------------------------------------------------------------
# T13: tpm2-pin-boot.sh — the native-path flip itself: drop-in written,
#      cmdline gains tpm2-device=auto, UKIs rebuild, all idempotent, and
#      deconfigure restores the exact original state.
# --------------------------------------------------------------------------
helper=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/tpm2-pin-boot.sh
d=$(mktemp -d); mkdir -p "$d/bin"
cat > "$d/bin/build-uki" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/builduki.log"; exit 0
EOF
cat > "$d/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$d/bin/build-uki" "$d/bin/cryptsetup"
printf 'rd.luks.name=U=lr rd.luks.options=discard,tries=0 root=/dev/mapper/lr rw quiet\n' > "$d/cmdline"
cp "$d/cmdline" "$d/cmdline.orig"
printf '/dev/mapper/root\n' > "$d/containers"
_helper() {
    SHEDOS_TPM2_PIN_DROPIN="$d/dropins/10-shedos-tpm2-pin.conf" \
    SHEDOS_TPM2_PIN_CMDLINES="$d/cmdline" \
    SHEDOS_TPM2_PIN_BUILD_UKI="$d/bin/build-uki" \
    SHEDOS_TPM2_PIN_CONTAINERS="$d/containers" \
    PATH="$d/bin:$PATH" \
        bash "$helper" "$@"
}
_helper configure
ok=1
grep -q 'SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0' "$d/dropins/10-shedos-tpm2-pin.conf" 2>/dev/null || ok=0
grep -q 'rd\.luks\.options=discard,tries=0,tpm2-device=auto' "$d/cmdline" || ok=0
[[ $(wc -l < "$d/builduki.log") -eq 1 ]] || ok=0
if (( ok )); then _ok T13a_configure; else _fail T13a_configure "dropin/cmdline/rebuild wrong: $(cat "$d/cmdline") | $(cat "$d/builduki.log" 2>/dev/null)"; fi
_helper configure
if [[ $(wc -l < "$d/builduki.log") -eq 1 ]]; then _ok T13b_configure_idempotent; else _fail T13b_configure_idempotent "rebuild ran again on a no-op configure"; fi
_helper deconfigure
ok=1
[[ ! -f $d/dropins/10-shedos-tpm2-pin.conf ]] || ok=0
cmp -s "$d/cmdline" "$d/cmdline.orig" || ok=0
[[ $(wc -l < "$d/builduki.log") -eq 2 ]] || ok=0
if (( ok )); then _ok T13c_deconfigure_restores; else _fail T13c_deconfigure_restores "revert incomplete: $(cat "$d/cmdline")"; fi
_helper deconfigure
if [[ $(wc -l < "$d/builduki.log") -eq 2 ]]; then _ok T13d_deconfigure_idempotent; else _fail T13d_deconfigure_idempotent "rebuild ran again on a no-op deconfigure"; fi
rm -rf "$d"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
total=$((pass + fail))
echo
echo "tpm2 verb: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
