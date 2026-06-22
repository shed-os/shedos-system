#!/usr/bin/env bash
# Guard the FDE Phase 2 UKI build/sign/atomic-place pipeline. The placer
# (build-uki.sh, via the shared uki-place.sh) must place a signed UKI on every
# ESP, refuse to overwrite a good image with a bad signature / a placeholder
# cmdline / an oversized write, and degrade cleanly when the box has no Secure
# Boot key. The signing itself (mkinitcpio -> ukify) and firmware rejection of
# an unsigned UKI are bench/QEMU-only — see the Task 2 hardware gate.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tree=$repo_root/packaging/shedos-system/tree
placer=$tree/usr/lib/shedos/build-uki.sh
lib=$tree/usr/lib/shedos/uki-place.sh
migrate=$tree/usr/lib/shedos/migrate-mkinitcpio-hooks.sh
uki_conf=$tree/etc/kernel/uki.conf
preset=$tree/etc/mkinitcpio.d/linux-zen.preset
h94=$tree/usr/share/libalpm/hooks/94-shedos-uki-build.hook
h95=$tree/usr/share/libalpm/hooks/95-shedos-limine-update.hook

for tool in openssl sbsign sbverify; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: test/uki needs $tool (sbsigntools + openssl)"; exit 0; }
done
stub=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
[[ -f $stub ]] || { echo "SKIP: test/uki needs the systemd-stub PE to sign"; exit 0; }

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# A self-signed db keypair + a PCR keypair in $1.
_mk_keys() {
    local d=$1; mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/db.key" \
        -out "$d/db.pem" -subj '/CN=shedos-test-db/' -days 1 >/dev/null 2>&1
    openssl genrsa -out "$d/pcr-private.pem" 2048 >/dev/null 2>&1
    openssl rsa -in "$d/pcr-private.pem" -pubout -out "$d/pcr-public.pem" >/dev/null 2>&1
}
# A real PE (the stub) signed with the db key in $1, written to $2.
_sign_dummy() { sbsign --key "$1/db.key" --cert "$1/db.pem" --output "$2" "$stub" >/dev/null 2>&1; }
# The placer, run against a sandbox: no rebuild, lib + cert + dirs overridden.
# A throwaway modules dir gives the placer one kernel (linux-zen) to discover,
# unless the caller passes its own via $5. The placer gates sbverify on uki.conf
# being in signing form (not on the cert file existing), so synthesize one to
# match: signing when a real db cert is in play, keyless otherwise. UKI_FORM
# forces the divergent disable case — db.pem on disk yet a keyless conf.
_run_placer() { # $1=boot $2=esp $3=cert $4=cmdline [$5=modules_dir]; env: UKI_FORM=signing|keyless
    local mods=${5:-} own="" rc form conf
    form=${UKI_FORM:-}
    [[ -z $form ]] && { [[ -f $3 ]] && form=signing || form=keyless; }
    conf=$(mktemp)
    if [[ $form == signing ]]; then
        printf '[UKI]\nStub=%s\nSecureBootPrivateKey=%s\nSecureBootCertificate=%s\n' \
            "$stub" "${3%.pem}.key" "$3" > "$conf"
    else
        printf '[UKI]\nStub=%s\n' "$stub" > "$conf"
    fi
    if [[ -z $mods ]]; then
        mods=$(mktemp -d); own=$mods
        mkdir -p "$mods/9.9-zen"; echo linux-zen > "$mods/9.9-zen/pkgbase"
    fi
    SHEDOS_UKI_NO_REBUILD=1 SHEDOS_UKI_PLACE_LIB="$lib" SHEDOS_MODULES_DIR="$mods" \
    SHEDOS_UKI_CONF="$conf" \
    SHEDOS_BOOT_DIR="$1" SHEDOS_ESP_DIRS="$2" SHEDOS_DB_CERT="$3" \
    SHEDOS_KERNEL_CMDLINE_FILE="$4" bash "$placer" >/dev/null 2>&1
    rc=$?; rm -f "$conf"; [[ -n $own ]] && rm -rf "$own"; return $rc
}

# ---------------------------------------------------------------------------
# M0: the migration inserts the microcode hook before block, idempotently.
# ---------------------------------------------------------------------------
m0=$(mktemp -d)
printf 'HOOKS=(base systemd autodetect modconf keyboard sd-vconsole consolefont block plymouth shedos-recovery filesystems)\n' > "$m0/mkinitcpio.conf"
SHEDOS_MKINITCPIO_CONF="$m0/mkinitcpio.conf" bash "$migrate" >/dev/null 2>&1 || true
line1=$(grep -E '^HOOKS=' "$m0/mkinitcpio.conf")
SHEDOS_MKINITCPIO_CONF="$m0/mkinitcpio.conf" bash "$migrate" >/dev/null 2>&1 || true
line2=$(grep -E '^HOOKS=' "$m0/mkinitcpio.conf")
if [[ $line1 == *' microcode block'* && $line1 == "$line2" ]]; then
    _ok M0_microcode_hook_inserted
else
    _fail M0_microcode_hook_inserted "microcode not before block or non-idempotent: $line1"
fi
rm -rf "$m0"

# ---------------------------------------------------------------------------
# U1: the shipped uki.conf is KEYLESS — naming an absent key would hard-fail
# every keyless box's build, so enrollment adds the signing lines, not us.
# ---------------------------------------------------------------------------
if grep -qE '^[[:space:]]*Stub=' "$uki_conf" \
   && ! grep -qE '^[[:space:]]*SecureBootPrivateKey' "$uki_conf" \
   && ! grep -qE '^[[:space:]]*\[PCRSignature' "$uki_conf"; then
    _ok U1_uki_conf_keyless
else
    _fail U1_uki_conf_keyless "uki.conf must ship Stub-only (no SecureBoot/PCRSignature lines)"
fi

# ---------------------------------------------------------------------------
# U2: shipped cmdline files carry the placeholder sentinel.
# ---------------------------------------------------------------------------
for f in cmdline cmdline-fallback; do
    if grep -qE '^[^#]*\bSHEDOS_PLACEHOLDER_CMDLINE\b' "$tree/etc/kernel/$f"; then
        _ok "U2_placeholder_$f"
    else
        _fail "U2_placeholder_$f" "$tree/etc/kernel/$f missing the placeholder sentinel"
    fi
done

# ---------------------------------------------------------------------------
# U3: the preset stages UKIs to btrfs /boot + wires the cmdline files, keeping
# the kernel-absent PRESETS=() guard.
# ---------------------------------------------------------------------------
if grep -qF 'default_uki="/boot/shedos-linux-zen.efi"' "$preset" \
   && grep -qF 'fallback_uki="/boot/shedos-linux-zen-fallback.efi"' "$preset" \
   && grep -qF 'default_cmdline="/etc/kernel/cmdline"' "$preset" \
   && grep -qF 'fallback_cmdline="/etc/kernel/cmdline-fallback"' "$preset" \
   && grep -qF "PRESETS=('default' 'fallback')" "$preset"; then
    _ok U3_preset_stages_uki
else
    _fail U3_preset_stages_uki "preset not staging UKIs to /boot or missing cmdline/guard wiring"
fi

# ---------------------------------------------------------------------------
# U4: the placer places a signed UKI on the ESP and sbverify accepts it.
# ---------------------------------------------------------------------------
t4=$(mktemp -d); _mk_keys "$t4/sb"; mkdir -p "$t4/boot" "$t4/esp"
: > "$t4/esp/limine.conf"; printf 'root=UUID=test rw quiet\n' > "$t4/cmdline"
_sign_dummy "$t4/sb" "$t4/boot/shedos-linux-zen.efi"
_run_placer "$t4/boot" "$t4/esp" "$t4/sb/db.pem" "$t4/cmdline"; rc=$?
if (( rc == 0 )) && [[ -f $t4/esp/EFI/Linux/shedos-linux-zen.efi ]] \
   && sbverify --cert "$t4/sb/db.pem" "$t4/esp/EFI/Linux/shedos-linux-zen.efi" >/dev/null 2>&1; then
    _ok U4_places_signed_uki
else
    _fail U4_places_signed_uki "signed UKI not placed/verified (rc=$rc)"
fi
rm -rf "$t4"

# ---------------------------------------------------------------------------
# U4b: a placeholder cmdline must NOT clobber a good prior UKI.
# ---------------------------------------------------------------------------
t4b=$(mktemp -d); _mk_keys "$t4b/sb"; mkdir -p "$t4b/boot" "$t4b/esp/EFI/Linux"
: > "$t4b/esp/limine.conf"; printf 'SHEDOS_PLACEHOLDER_CMDLINE\n' > "$t4b/cmdline"
_sign_dummy "$t4b/sb" "$t4b/boot/shedos-linux-zen.efi"
printf 'GOOD-prior\n' > "$t4b/esp/EFI/Linux/shedos-linux-zen.efi"
_run_placer "$t4b/boot" "$t4b/esp" "$t4b/sb/db.pem" "$t4b/cmdline"; rc=$?
if (( rc != 0 )) && [[ "$(cat "$t4b/esp/EFI/Linux/shedos-linux-zen.efi")" == GOOD-prior ]]; then
    _ok U4b_placeholder_guard
else
    _fail U4b_placeholder_guard "placeholder cmdline clobbered the prior UKI (rc=$rc)"
fi
rm -rf "$t4b"

# ---------------------------------------------------------------------------
# U5: a UKI signed by the WRONG key is refused; the prior image survives.
# ---------------------------------------------------------------------------
t5=$(mktemp -d); _mk_keys "$t5/sb"; _mk_keys "$t5/other"; mkdir -p "$t5/boot" "$t5/esp/EFI/Linux"
: > "$t5/esp/limine.conf"; printf 'root=UUID=test rw\n' > "$t5/cmdline"
_sign_dummy "$t5/other" "$t5/boot/shedos-linux-zen.efi"          # signed by the wrong key
printf 'GOOD-prior\n' > "$t5/esp/EFI/Linux/shedos-linux-zen.efi"
_run_placer "$t5/boot" "$t5/esp" "$t5/sb/db.pem" "$t5/cmdline"; rc=$?
if (( rc != 0 )) && [[ "$(cat "$t5/esp/EFI/Linux/shedos-linux-zen.efi")" == GOOD-prior ]] \
   && [[ ! -e $t5/esp/EFI/Linux/shedos-linux-zen.efi.new ]]; then
    _ok U5_bad_signature_refused
else
    _fail U5_bad_signature_refused "wrong-key UKI placed or prior clobbered (rc=$rc)"
fi
rm -rf "$t5"

# ---------------------------------------------------------------------------
# U6: an out-of-space placement keeps the prior image (the #159 analog).
# ---------------------------------------------------------------------------
t6=$(mktemp -d); _mk_keys "$t6/sb"; mkdir -p "$t6/boot" "$t6/esp/EFI/Linux"
: > "$t6/esp/limine.conf"; printf 'root=UUID=test rw\n' > "$t6/cmdline"
_sign_dummy "$t6/sb" "$t6/boot/shedos-linux-zen.efi"
printf 'OLD\n' > "$t6/esp/EFI/Linux/shedos-linux-zen.efi"
SHEDOS_ESP_FAKE_AVAIL=0 _run_placer "$t6/boot" "$t6/esp" "$t6/sb/db.pem" "$t6/cmdline"; rc=$?
if (( rc != 0 )) && [[ "$(cat "$t6/esp/EFI/Linux/shedos-linux-zen.efi")" == OLD ]]; then
    _ok U6_refuses_when_too_small
else
    _fail U6_refuses_when_too_small "oversized place truncated/replaced the ESP image (rc=$rc)"
fi
rm -rf "$t6"

# ---------------------------------------------------------------------------
# U7: a box with no db cert places the unsigned UKI and skips the check.
# ---------------------------------------------------------------------------
t7=$(mktemp -d); mkdir -p "$t7/boot" "$t7/esp"
: > "$t7/esp/limine.conf"; printf 'root=UUID=test rw\n' > "$t7/cmdline"
printf 'unsigned-uki\n' > "$t7/boot/shedos-linux-zen.efi"
_run_placer "$t7/boot" "$t7/esp" "$t7/no-such-cert.pem" "$t7/cmdline"; rc=$?
if (( rc == 0 )) && cmp -s "$t7/boot/shedos-linux-zen.efi" "$t7/esp/EFI/Linux/shedos-linux-zen.efi"; then
    _ok U7_sb_off_places_unsigned
else
    _fail U7_sb_off_places_unsigned "no-key box did not place the unsigned UKI (rc=$rc)"
fi
rm -rf "$t7"

# ---------------------------------------------------------------------------
# U7b: the disable case — db.pem left on disk but a keyless uki.conf. The placer
#      must FOLLOW uki.conf, not the cert file: skip sbverify and place the
#      unsigned UKI, so kernel updates after `shedman secureboot disable` keep
#      working. The old db.pem-presence gate rejected this — the bug fixed here.
# ---------------------------------------------------------------------------
t7b=$(mktemp -d); _mk_keys "$t7b/sb"; mkdir -p "$t7b/boot" "$t7b/esp"
: > "$t7b/esp/limine.conf"; printf 'root=UUID=test rw\n' > "$t7b/cmdline"
printf 'unsigned-uki\n' > "$t7b/boot/shedos-linux-zen.efi"
UKI_FORM=keyless _run_placer "$t7b/boot" "$t7b/esp" "$t7b/sb/db.pem" "$t7b/cmdline"; rc=$?
if (( rc == 0 )) && [[ -f $t7b/sb/db.pem ]] \
   && cmp -s "$t7b/boot/shedos-linux-zen.efi" "$t7b/esp/EFI/Linux/shedos-linux-zen.efi"; then
    _ok U7b_keyless_conf_places_unsigned_despite_db_cert
else
    _fail U7b_keyless_conf_places_unsigned_despite_db_cert "keyless uki.conf with db.pem present did not place the unsigned UKI (rc=$rc)"
fi
rm -rf "$t7b"

# ---------------------------------------------------------------------------
# U9/U10: the hooks are wired — 94 runs both builders PostTransaction with the
# microcode triggers + AbortOnFail; 95 also triggers on microcode.
# ---------------------------------------------------------------------------
if grep -qF 'When = PostTransaction' "$h94" \
   && grep -qF 'Target = usr/lib/modules/*/vmlinuz' "$h94" \
   && grep -qF 'Target = boot/intel-ucode.img' "$h94" \
   && grep -qF '/usr/lib/shedos/build-uki.sh' "$h94" \
   && grep -qF '/usr/lib/shedos/build-recovery-uki.sh' "$h94" \
   && grep -qF 'AbortOnFail' "$h94"; then
    _ok U9_94_hook_wired
else
    _fail U9_94_hook_wired "94 hook missing a trigger/exec/abort directive"
fi
if grep -qF 'Target = boot/intel-ucode.img' "$h95" \
   && grep -qF 'Target = boot/amd-ucode.img' "$h95" \
   && grep -qF 'Exec = /usr/lib/shedos/render-limine-config.sh' "$h95"; then
    _ok U10_95_microcode_targets
else
    _fail U10_95_microcode_targets "95 hook missing microcode targets or changed Exec"
fi

# ---------------------------------------------------------------------------
# U11: multi-kernel — when both linux-zen and stock linux have staged UKIs the
#      placer places both (Option B: stock linux as a different-kernel fallback).
# ---------------------------------------------------------------------------
t11=$(mktemp -d); _mk_keys "$t11/sb"
mkdir -p "$t11/boot" "$t11/esp" "$t11/mods/9.9-zen" "$t11/mods/8.8-linux"
echo linux-zen > "$t11/mods/9.9-zen/pkgbase"
echo linux > "$t11/mods/8.8-linux/pkgbase"
: > "$t11/esp/limine.conf"; printf 'root=UUID=test rw quiet\n' > "$t11/cmdline"
_sign_dummy "$t11/sb" "$t11/boot/shedos-linux-zen.efi"
_sign_dummy "$t11/sb" "$t11/boot/shedos-linux.efi"
_run_placer "$t11/boot" "$t11/esp" "$t11/sb/db.pem" "$t11/cmdline" "$t11/mods"; rc=$?
if (( rc == 0 )) && [[ -f $t11/esp/EFI/Linux/shedos-linux-zen.efi ]] \
   && [[ -f $t11/esp/EFI/Linux/shedos-linux.efi ]]; then
    _ok U11_multi_kernel_places_both
else
    _fail U11_multi_kernel_places_both "stock linux UKI not placed alongside linux-zen (rc=$rc)"
fi
rm -rf "$t11"

# ---------------------------------------------------------------------------
# U12: sbctl's mkinitcpio post-hook signer is masked (ukify is the single
#      signer; a second sbctl signature would leave the UKI sbverify-dirty).
# ---------------------------------------------------------------------------
mask=$tree/etc/initcpio/post/sbctl
if [[ -x $mask ]] && bash "$mask" >/dev/null 2>&1; then
    _ok U12_sbctl_signer_masked
else
    _fail U12_sbctl_signer_masked "sbctl post-hook mask missing/non-exec or does not no-op"
fi

# ---------------------------------------------------------------------------
# U13: ensure-initramfs-current.sh rebuilds + re-signs the UKI between the
#      initramfs rebuild and the limine re-render, so a HOOKS migration never
#      leaves the menu pointing at a UKI built from the old initramfs.
# ---------------------------------------------------------------------------
ensure=$tree/usr/lib/shedos/ensure-initramfs-current.sh
l_rebuild=$(grep -n 'rebuild-initramfs.sh' "$ensure" | tail -1 | cut -d: -f1)
l_uki=$(grep -n 'build-uki.sh' "$ensure" | head -1 | cut -d: -f1)
l_render=$(grep -n 'render-limine-config.sh' "$ensure" | tail -1 | cut -d: -f1)
if [[ -n $l_uki ]] && (( l_rebuild < l_uki && l_uki < l_render )); then
    _ok U13_ensure_builds_uki_between_rebuild_and_render
else
    _fail U13_ensure_builds_uki_between_rebuild_and_render "ordering wrong: rebuild=$l_rebuild uki=$l_uki render=$l_render"
fi

# ---------------------------------------------------------------------------
# recover-esp.sh operates on the signed-UKI surface, not the retired raw
# kernel/initramfs ESP copies the pre-UKI tool wiped.
# ---------------------------------------------------------------------------
recover=$tree/usr/lib/shedos/recover-esp.sh

# R1: it globs the /EFI/Linux UKI surface.
if grep -q 'EFI/Linux/shedos-\*\.efi' "$recover"; then
    _ok R1_recover_targets_uki
else
    _fail R1_recover_targets_uki "recover-esp.sh does not glob /EFI/Linux/shedos-*.efi"
fi

# R2: the legacy kms refusal + vmlinuz/initramfs wipe are gone.
if grep -qE "'kms'|vmlinuz-\*|initramfs-\*\.img" "$recover"; then
    _fail R2_recover_legacy_dropped "recover-esp.sh still references kms / vmlinuz-* / initramfs-*.img"
else
    _ok R2_recover_legacy_dropped
fi

# R3: it rebuilds via build-uki.sh --rebuild and verifies with sbverify against
#     the box db cert (the reconciled /var/lib/sbctl path, not cmp-vs-/boot).
if grep -q 'build-uki.sh --rebuild' "$recover" \
   && grep -q 'sbverify' "$recover" \
   && grep -q '/var/lib/sbctl/keys/db/db.pem' "$recover"; then
    _ok R3_recover_rebuild_and_sbverify
else
    _fail R3_recover_rebuild_and_sbverify "missing build-uki.sh --rebuild / sbverify / db.pem in recover-esp.sh"
fi

total=$((pass + fail))
echo
echo "uki pipeline: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
