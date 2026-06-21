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

total=$((pass + fail))
echo
echo "secureboot: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
