#!/usr/bin/env bash
# Guard shedman secureboot: status/verify wording, the verify exit contract,
# and that no underlying tool name (sbctl/sbverify/ukify) leaks into output.
#
# Each case builds a tmp ESP + key dir and points the verb at injected stub
# bootctl/sbverify, so behaviour is asserted without a real Secure Boot stack.
# Same shape as test/kernel/run.sh.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman/secureboot

if [[ ! -x $tool ]]; then
    echo "FATAL: $tool not executable" >&2
    exit 2
fi

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# Stub bootctl whose `status` Secure-Boot line is caller-chosen.
_stub_bootctl() {
    cat >"$1" <<EOF
#!/usr/bin/env bash
[[ "\$1" == status ]] && { echo "Secure Boot: $2 ($3)"; exit 0; }
exit 0
EOF
    chmod +x "$1"
}

# Stub sbverify: exits 0 only for a UKI whose bytes contain SIGNED-OK.
_stub_sbverify() {
    cat >"$1" <<'EOF'
#!/usr/bin/env bash
f=${@: -1}
grep -q SIGNED-OK "$f" 2>/dev/null && exit 0
exit 1
EOF
    chmod +x "$1"
}

# Populate the global E array with the verb's test env for tmp dir $1.
_env() {
    local td=$1
    E=(SHEDOS_SECUREBOOT_KEYDIR="$td/keys"
       SHEDOS_SECUREBOOT_BOOTCTL="$td/stubs/bootctl"
       SHEDOS_SECUREBOOT_SBVERIFY="$td/stubs/sbverify"
       SHEDOS_ESP_DIRS="$td/esp")
}

# Full env + stubs for the MUTATING verbs (enroll/sign/repair/disable). Stubs
# log argv so we can assert the brick-critical contract (enroll-keys never runs
# unless the chain verifies). $2 = SetupMode byte (1 = Setup Mode, 0 = User).
_mutator_setup() {
    local t=$1 sm=$2
    mkdir -p "$t/stubs" "$t/keys" "$t/pcr" "$t/esp/EFI/Linux" "$t/esp/EFI/BOOT"
    : > "$t/uki.conf"                                    # on the UKI path
    : > "$t/keys/db.pem"; : > "$t/keys/db.key"           # keys present (reuse)
    : > "$t/pcr/pcr-private.pem"; : > "$t/pcr/pcr-public.pem"
    if [[ $sm == 1 ]]; then printf '\x06\x00\x00\x00\x01' > "$t/setupmode"
    else                    printf '\x06\x00\x00\x00\x00' > "$t/setupmode"; fi
    cat >"$t/stubs/id" <<'IDEOF'
#!/usr/bin/env bash
[[ "$1" == -u ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
IDEOF
    cat >"$t/stubs/sbctl" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$t/sbctl.log"; echo >> "$t/sbctl.log"
[[ "\$1" == create-keys ]] && { : > "$t/keys/db.pem"; : > "$t/keys/db.key"; }
exit 0
EOF
    cat >"$t/stubs/build-uki" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$t/builduki.log"; echo >> "$t/builduki.log"
exit 0
EOF
    cat >"$t/stubs/build-recovery-uki" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$t/buildrecovery.log"; echo >> "$t/buildrecovery.log"
exit 0
EOF
    _stub_sbverify "$t/stubs/sbverify"
    chmod +x "$t/stubs/"*
}

_menv() {
    local t=$1
    E=(SHEDOS_SECUREBOOT_KEYDIR="$t/keys"
       SHEDOS_SECUREBOOT_PCR_DIR="$t/pcr"
       SHEDOS_SECUREBOOT_UKI_CONF="$t/uki.conf"
       SHEDOS_SECUREBOOT_SBCTL="$t/stubs/sbctl"
       SHEDOS_SECUREBOOT_SBVERIFY="$t/stubs/sbverify"
       SHEDOS_SECUREBOOT_BUILD_UKI="$t/stubs/build-uki"
       SHEDOS_SECUREBOOT_BUILD_RECOVERY_UKI="$t/stubs/build-recovery-uki"
       SHEDOS_SECUREBOOT_SETUP_EFIVAR="$t/setupmode"
       SHEDOS_ESP_DIRS="$t/esp"
       SHEDOS_SECUREBOOT_LIMINE_COPIES="$t/esp/EFI/BOOT/BOOTX64.EFI"
       PATH="$t/stubs:$PATH")
}

# --- C1: status, no keys, SB off (Setup Mode) ------------------------------
t=$(mktemp -d)
mkdir -p "$t/keys" "$t/stubs" "$t/esp/EFI/Linux"
_stub_bootctl "$t/stubs/bootctl" disabled setup
_stub_sbverify "$t/stubs/sbverify"
_env "$t"
out=$(env "${E[@]}" "$tool" status 2>&1); rc=$?
if (( rc == 0 )) && grep -qi 'Secure Boot: off' <<<"$out" \
   && grep -qi 'not set up' <<<"$out" \
   && ! grep -qiE 'sbctl|sbverify|ukify|cryptenroll' <<<"$out"; then
    _ok C1_status_off_no_keys
else
    _fail C1_status_off_no_keys "rc=$rc out=$out"
fi
rm -rf "$t"

# --- C2: verify passes when SB on and every UKI valid ----------------------
t=$(mktemp -d)
mkdir -p "$t/keys" "$t/stubs" "$t/esp/EFI/Linux"
_stub_bootctl "$t/stubs/bootctl" enabled user
_stub_sbverify "$t/stubs/sbverify"
: > "$t/keys/db.pem"; : > "$t/keys/db.key"
printf 'SIGNED-OK\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
_env "$t"
env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" verify >/dev/null 2>&1; rc=$?
if (( rc == 0 )); then _ok C2_verify_clean
else _fail C2_verify_clean "rc=$rc (expected 0)"; fi
rm -rf "$t"

# --- C3: verify fails (exit 1) when a UKI is unsigned -----------------------
t=$(mktemp -d)
mkdir -p "$t/keys" "$t/stubs" "$t/esp/EFI/Linux"
_stub_bootctl "$t/stubs/bootctl" enabled user
_stub_sbverify "$t/stubs/sbverify"
: > "$t/keys/db.pem"; : > "$t/keys/db.key"
printf 'UNSIGNED\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
_env "$t"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" verify 2>&1); rc=$?
if (( rc == 1 )) && grep -qi 'NOT valid' <<<"$out"; then _ok C3_verify_bad_uki
else _fail C3_verify_bad_uki "rc=$rc out=$out (expected 1)"; fi
rm -rf "$t"

# --- C4: verify refuses (exit 2) on a BIOS box -----------------------------
t=$(mktemp -d)
mkdir -p "$t/keys" "$t/stubs" "$t/esp/EFI/Linux"
_stub_bootctl "$t/stubs/bootctl" disabled setup
_stub_sbverify "$t/stubs/sbverify"
_env "$t"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_BIOS=1 "$tool" verify 2>&1); rc=$?
if (( rc == 2 )) && grep -qi 'BIOS' <<<"$out"; then _ok C4_verify_bios_refuses
else _fail C4_verify_bios_refuses "rc=$rc out=$out (expected 2)"; fi
rm -rf "$t"

# --- C5: verify with no placed images fails loud, never a vacuous pass -------
# (the root-only ESP means a non-root run finds zero — must not report success)
t=$(mktemp -d)
mkdir -p "$t/keys" "$t/stubs" "$t/esp/EFI/Linux"
_stub_bootctl "$t/stubs/bootctl" enabled user
_stub_sbverify "$t/stubs/sbverify"
: > "$t/keys/db.pem"; : > "$t/keys/db.key"
_env "$t"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" verify 2>&1); rc=$?
if (( rc == 1 )) && grep -qi 'no boot images' <<<"$out" \
   && ! grep -qi 'verified' <<<"$out"; then _ok C5_verify_no_images_not_vacuous
else _fail C5_verify_no_images_not_vacuous "rc=$rc out=$out (expected 1, no vacuous pass)"; fi
rm -rf "$t"

# --- M1: enroll refuses on a BIOS box (rc 2), even as root -----------------
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_BIOS=1 "$tool" enroll --yes 2>&1); rc=$?
if (( rc == 2 )) && grep -qi 'BIOS' <<<"$out"; then _ok M1_enroll_bios_refuses
else _fail M1_enroll_bios_refuses "rc=$rc out=$out"; fi
rm -rf "$t"

# --- M2: enroll refuses outside Setup Mode (rc 1) with firmware guidance ----
t=$(mktemp -d); _mutator_setup "$t" 0; _menv "$t"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" enroll --yes 2>&1); rc=$?
if (( rc == 1 )) && grep -qi 'Setup Mode' <<<"$out"; then _ok M2_enroll_needs_setup_mode
else _fail M2_enroll_needs_setup_mode "rc=$rc out=$out"; fi
rm -rf "$t"

# --- M3: VERIFY-BEFORE-ARM — a UKI that fails sbverify must NOT arm ----------
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
printf 'UNSIGNED\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
printf 'UNSIGNED\n' > "$t/esp/EFI/BOOT/BOOTX64.EFI"
env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" enroll --yes >/dev/null 2>&1; rc=$?
if (( rc != 0 )) && ! grep -q 'enroll-keys' "$t/sbctl.log" 2>/dev/null; then
    _ok M3_verify_before_arm
else
    _fail M3_verify_before_arm "rc=$rc sbctl.log=$(cat "$t/sbctl.log" 2>/dev/null)"
fi
rm -rf "$t"

# --- M4: enroll happy path arms with --microsoft (default) ------------------
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
printf 'SIGNED-OK\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
printf 'SIGNED-OK\n' > "$t/esp/EFI/BOOT/BOOTX64.EFI"
env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" enroll --yes >/dev/null 2>&1; rc=$?
if (( rc == 0 )) && grep -q 'enroll-keys' "$t/sbctl.log" \
   && grep -q -- '--microsoft' "$t/sbctl.log" \
   && grep -q -- '--ignore-immutable' "$t/sbctl.log"; then
    _ok M4_enroll_arms_with_microsoft
else
    _fail M4_enroll_arms_with_microsoft "rc=$rc sbctl.log=$(cat "$t/sbctl.log" 2>/dev/null)"
fi
# The recovery image is built by its own path; enroll must rebuild it under
# the signing config or verify rejects the chain (bit a real Latitude enroll).
if [[ -s $t/buildrecovery.log ]]; then
    _ok M4b_enroll_rebuilds_recovery_image
else
    _fail M4b_enroll_rebuilds_recovery_image "build-recovery-uki was never invoked"
fi
rm -rf "$t"

# --- M5: --shedos-only arms WITHOUT --microsoft -----------------------------
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
printf 'SIGNED-OK\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
printf 'SIGNED-OK\n' > "$t/esp/EFI/BOOT/BOOTX64.EFI"
env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" enroll --yes --shedos-only >/dev/null 2>&1
if grep -q 'enroll-keys' "$t/sbctl.log" && ! grep -q -- '--microsoft' "$t/sbctl.log"; then
    _ok M5_shedos_only_drops_microsoft
else
    _fail M5_shedos_only_drops_microsoft "sbctl.log=$(cat "$t/sbctl.log" 2>/dev/null)"
fi
rm -rf "$t"

# --- M6: disable resets the keys and never rebuilds unsigned under live keys -
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" disable --yes >/dev/null 2>&1; rc=$?
if (( rc == 0 )) && grep -q 'reset' "$t/sbctl.log" && [[ ! -s "$t/builduki.log" ]]; then
    _ok M6_disable_resets_no_rebuild
else
    _fail M6_disable_resets_no_rebuild "rc=$rc sbctl=$(cat "$t/sbctl.log" 2>/dev/null) builduki=$(cat "$t/builduki.log" 2>/dev/null)"
fi
rm -rf "$t"

# --- M7: enroll refuses non-interactively without --yes (no auto-confirm) ----
t=$(mktemp -d); _mutator_setup "$t" 1; _menv "$t"
printf 'SIGNED-OK\n' > "$t/esp/EFI/Linux/shedos-linux-zen.efi"
out=$(env "${E[@]}" SHEDOS_SECUREBOOT_FORCE_UEFI=1 "$tool" enroll </dev/null 2>&1); rc=$?
if (( rc == 1 )) && grep -qi 'confirmation' <<<"$out" \
   && ! grep -q 'enroll-keys' "$t/sbctl.log" 2>/dev/null; then
    _ok M7_enroll_no_autoconfirm
else
    _fail M7_enroll_no_autoconfirm "rc=$rc out=$out"
fi
rm -rf "$t"

total=$((pass + fail))
echo
echo "secureboot: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
