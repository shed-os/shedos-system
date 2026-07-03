#!/usr/bin/env bash
# Guard the shedos-kernel -> linux-zen migration invariants.
#
# ShedOS no longer vendors a kernel (Arch owns linux-zen's config), so there
# is no storage-driver config to contract-test. Instead we assert the wiring
# that keeps the migration correct: linux-zen is the primary kernel, stock
# linux is an installable fallback, shedos-kernel is fully retired, and the
# limine renderer + preset still produce a bootable default + recovery entry.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
base_txt=$repo_root/packages/official/base.txt
meta_render=$repo_root/scripts/render-meta-depends.sh
build_script=$repo_root/scripts/build-shedos-packages.sh
renderer=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/render-limine-config.sh
preset=$repo_root/packaging/shedos-system/tree/etc/mkinitcpio.d/linux-zen.preset

pass=0
fail=0
failures=()
_ok()   { printf 'ok: %s\n' "$1"; ((pass++)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); ((fail++)); }

# ---------------------------------------------------------------------------
# K1: linux-zen (primary) + stock linux (fallback), with their headers, are
#     explicit roots so all four install and land in closure/meta/airootfs.
# ---------------------------------------------------------------------------
for pkg in linux-zen linux-zen-headers linux linux-headers; do
    if grep -qxF "$pkg" "$base_txt"; then
        _ok "K1_base_has_$pkg"
    else
        _fail "K1_base_has_$pkg" "missing from packages/official/base.txt"
    fi
done

# ---------------------------------------------------------------------------
# K2: shedos-kernel is fully retired — no package tree, no build-order entry,
#     no meta-depends entry. (The shedos-system retirement one-shot may still
#     name it; we only scan the build/package-set wiring here.)
# ---------------------------------------------------------------------------
if [[ -e $repo_root/packaging/shedos-kernel ]]; then
    _fail K2_package_deleted "packaging/shedos-kernel/ still exists"
else
    _ok K2_package_deleted
fi
if grep -q 'shedos-kernel' "$build_script"; then
    _fail K2_build_clean "shedos-kernel still referenced in $build_script"
else
    _ok K2_build_clean
fi
if grep -q 'shedos-kernel' "$meta_render"; then
    _fail K2_meta_clean "shedos-kernel still referenced in $meta_render"
else
    _ok K2_meta_clean
fi

# ---------------------------------------------------------------------------
# K3: the fallback kernel can actually install — stock linux must NOT be
#     conflicted by shedos-meta (it was, while shedos-kernel was the only
#     kernel we shipped).
# ---------------------------------------------------------------------------
if awk '/^shedos_conflicts=\(/{c=1;next} /^\)/{c=0} c' "$meta_render" \
        | grep -qE "^[[:space:]]*'?linux'?[[:space:]]*$"; then
    _fail K3_linux_not_conflicted "stock linux is still in shedos_conflicts"
else
    _ok K3_linux_not_conflicted
fi

# ---------------------------------------------------------------------------
# K4: ShedOS ships a linux-zen.preset forcing BOTH default + fallback images.
#     mkinitcpio's stock template is default-only, so without this the limine
#     "(Fallback)" recovery entry would have no initramfs to load.
# ---------------------------------------------------------------------------
if [[ -f $preset ]] && grep -qF "PRESETS=('default' 'fallback')" "$preset"; then
    _ok K4_preset_enables_fallback
else
    _fail K4_preset_enables_fallback "linux-zen.preset missing or not enabling the fallback preset"
fi

# ---------------------------------------------------------------------------
# K5: functional — the limine renderer makes linux-zen the default entry,
#     labels stock linux as "(stock)", and omits a recovery entry for a
#     kernel whose fallback initramfs doesn't exist (default-only preset).
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
mkdir -p "$tmp/modules/9.9-zen" "$tmp/modules/9.9-stock" "$tmp/boot"
echo linux-zen > "$tmp/modules/9.9-zen/pkgbase"
echo linux     > "$tmp/modules/9.9-stock/pkgbase"
: > "$tmp/boot/initramfs-linux-zen.img"
: > "$tmp/boot/initramfs-linux-zen-fallback.img"
: > "$tmp/boot/initramfs-linux.img"   # default only; no -fallback
# SHEDOS_ESP_DIRS points at an ESP-less dir so the renderer takes the
# no-ESP path and never touches the host's real /boot/efi during the test.
SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" SHEDOS_FIRMWARE=bios \
SHEDOS_BOOT_DIR="$tmp/boot" SHEDOS_MODULES_DIR="$tmp/modules" \
SHEDOS_ESP_DIRS="$tmp/noesp" \
    bash "$renderer" >/dev/null 2>&1
conf=$tmp/boot/limine.conf

# linux-zen entry comes first (the default), labelled "ShedOS Linux".
if [[ -f $conf ]] && [[ "$(grep -m1 '^/' "$conf")" == "/ShedOS Linux" ]] \
   && grep -q 'vmlinuz-linux-zen' "$conf"; then
    _ok K5_default_is_linux_zen
else
    _fail K5_default_is_linux_zen "linux-zen is not the first/default limine entry"
fi
# linux-zen keeps its recovery entry (its fallback initramfs exists)...
if grep -qF '/ShedOS Linux (Fallback)' "$conf"; then
    _ok K5_linux_zen_has_fallback
else
    _fail K5_linux_zen_has_fallback "linux-zen recovery entry missing"
fi
# ...stock linux is present but its recovery entry is omitted (no initramfs).
if grep -qF '/ShedOS Linux (stock)' "$conf" \
   && ! grep -qF '/ShedOS Linux (stock) (Fallback)' "$conf"; then
    _ok K5_stock_fallback_omitted
else
    _fail K5_stock_fallback_omitted "stock linux entry wrong, or a dead fallback entry was emitted"
fi
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# K6: the renderer prunes images for kernels no longer installed off the
#     ESP (a retired shedos-kernel otherwise keeps the FAT volume full),
#     and syncs the live kernel's images across byte-for-byte.
# ---------------------------------------------------------------------------
t6=$(mktemp -d)
mkdir -p "$t6/modules/9.9-zen" "$t6/boot" "$t6/esp"
echo linux-zen > "$t6/modules/9.9-zen/pkgbase"
printf 'zen-vmlinuz\n'  > "$t6/boot/vmlinuz-linux-zen"
printf 'zen-default\n'  > "$t6/boot/initramfs-linux-zen.img"
printf 'zen-fallback\n' > "$t6/boot/initramfs-linux-zen-fallback.img"
: > "$t6/esp/limine.conf"                          # marks $t6/esp as a live ESP
printf 'stale\n' > "$t6/esp/vmlinuz-shedos-kernel"
printf 'stale\n' > "$t6/esp/initramfs-shedos-kernel.img"
printf 'stale\n' > "$t6/esp/initramfs-shedos-kernel-fallback.img"
SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" SHEDOS_FIRMWARE=bios \
SHEDOS_BOOT_DIR="$t6/boot" SHEDOS_MODULES_DIR="$t6/modules" \
SHEDOS_ESP_DIRS="$t6/esp" bash "$renderer" >/dev/null 2>&1
if [[ ! -e "$t6/esp/vmlinuz-shedos-kernel" \
   && ! -e "$t6/esp/initramfs-shedos-kernel.img" \
   && ! -e "$t6/esp/initramfs-shedos-kernel-fallback.img" ]]; then
    _ok K6_prunes_retired_kernel
else
    _fail K6_prunes_retired_kernel "stale shedos-kernel images left on the ESP"
fi
if cmp -s "$t6/boot/initramfs-linux-zen.img" "$t6/esp/initramfs-linux-zen.img"; then
    _ok K6_syncs_live_kernel
else
    _fail K6_syncs_live_kernel "linux-zen image not synced intact to the ESP"
fi
rm -rf "$t6"

# ---------------------------------------------------------------------------
# K6b: on UEFI the boot payload is UKIs, so ANY raw vmlinuz/initramfs on the
#      ESP is pre-UKI vestige from a migrated install — it strands space and
#      starves the UKIs on a tight ESP. Reap them all, including an installed
#      kernel's, while leaving the UKIs untouched. (Regression: the reap used
#      to run on BIOS only, so migrated UEFI boxes never reclaimed the space.)
# ---------------------------------------------------------------------------
t6b=$(mktemp -d)
mkdir -p "$t6b/modules/9.9-zen" "$t6b/boot" "$t6b/esp/EFI/Linux"
echo linux-zen > "$t6b/modules/9.9-zen/pkgbase"
: > "$t6b/esp/limine.conf"                        # marks $t6b/esp as a live ESP
: > "$t6b/esp/EFI/Linux/shedos-linux-zen.efi"     # the real UEFI boot payload
printf 'vestige\n' > "$t6b/esp/vmlinuz-linux-zen"          # installed, but vestige on UEFI
printf 'vestige\n' > "$t6b/esp/initramfs-linux-zen.img"
printf 'stale\n'   > "$t6b/esp/vmlinuz-shedos-kernel"      # retired
printf 'stale\n'   > "$t6b/esp/initramfs-shedos-kernel.img"
SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" SHEDOS_FIRMWARE=uefi \
SHEDOS_BOOT_DIR="$t6b/boot" SHEDOS_MODULES_DIR="$t6b/modules" \
SHEDOS_ESP_DIRS="$t6b/esp" bash "$renderer" >/dev/null 2>&1
leftover=$(find "$t6b/esp" -maxdepth 1 \( -name 'vmlinuz-*' -o -name 'initramfs-*.img' \) 2>/dev/null)
if [[ -z $leftover && -e "$t6b/esp/EFI/Linux/shedos-linux-zen.efi" ]]; then
    _ok K6b_uefi_reaps_all_raw_images
else
    _fail K6b_uefi_reaps_all_raw_images "leftover=[$leftover] uki_present=$([[ -e $t6b/esp/EFI/Linux/shedos-linux-zen.efi ]] && echo y || echo n)"
fi
rm -rf "$t6b"

# ---------------------------------------------------------------------------
# K7: the regression that bricked the fleet — when an image won't fit, the
#     renderer must FAIL LOUD (non-zero), never truncate the existing ESP
#     image, and leave the last-good config untouched. SHEDOS_ESP_FAKE_AVAIL=0
#     forces the out-of-space path deterministically.
# ---------------------------------------------------------------------------
t7=$(mktemp -d)
mkdir -p "$t7/modules/9.9-zen" "$t7/boot" "$t7/esp"
echo linux-zen > "$t7/modules/9.9-zen/pkgbase"
printf 'NEW-bigger-content\n'         > "$t7/boot/vmlinuz-linux-zen"
printf 'NEW-bigger-default-content\n' > "$t7/boot/initramfs-linux-zen.img"
printf 'GOOD-config\n' > "$t7/esp/limine.conf"
printf 'OLD\n' > "$t7/esp/vmlinuz-linux-zen"
printf 'OLD\n' > "$t7/esp/initramfs-linux-zen.img"
rc=0
SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" SHEDOS_FIRMWARE=bios \
SHEDOS_BOOT_DIR="$t7/boot" SHEDOS_MODULES_DIR="$t7/modules" \
SHEDOS_ESP_DIRS="$t7/esp" SHEDOS_ESP_FAKE_AVAIL=0 \
    bash "$renderer" >/dev/null 2>&1 || rc=$?
ok=1
(( rc != 0 )) || ok=0
[[ "$(cat "$t7/esp/vmlinuz-linux-zen")" == OLD ]] || ok=0
[[ "$(cat "$t7/esp/initramfs-linux-zen.img")" == OLD ]] || ok=0
[[ "$(cat "$t7/esp/limine.conf")" == GOOD-config ]] || ok=0
if (( ok )); then
    _ok K7_refuses_when_too_small
else
    _fail K7_refuses_when_too_small "out-of-space sync truncated the ESP or updated the config (rc=$rc)"
fi
rm -rf "$t7"

# ---------------------------------------------------------------------------
# K8: a second render with everything in place is a no-op that still exits
#     0 (idempotent) and leaves the synced config byte-identical.
# ---------------------------------------------------------------------------
t8=$(mktemp -d)
mkdir -p "$t8/modules/9.9-zen" "$t8/boot" "$t8/esp"
echo linux-zen > "$t8/modules/9.9-zen/pkgbase"
printf 'v\n' > "$t8/boot/vmlinuz-linux-zen"
printf 'd\n' > "$t8/boot/initramfs-linux-zen.img"
printf 'f\n' > "$t8/boot/initramfs-linux-zen-fallback.img"
: > "$t8/esp/limine.conf"
_run8() { SHEDOS_LIMINE_CMDLINE="root=UUID=test rw quiet" SHEDOS_FIRMWARE=bios \
    SHEDOS_BOOT_DIR="$t8/boot" SHEDOS_MODULES_DIR="$t8/modules" \
    SHEDOS_ESP_DIRS="$t8/esp" bash "$renderer" >/dev/null 2>&1; }
_run8; rc1=$?; sum1=$(cat "$t8/esp/limine.conf")
_run8; rc2=$?; sum2=$(cat "$t8/esp/limine.conf")
if (( rc1 == 0 && rc2 == 0 )) && [[ "$sum1" == "$sum2" ]] \
   && cmp -s "$t8/boot/initramfs-linux-zen.img" "$t8/esp/initramfs-linux-zen.img"; then
    _ok K8_idempotent_happy_path
else
    _fail K8_idempotent_happy_path "second render diverged or exited non-zero (rc1=$rc1 rc2=$rc2)"
fi
rm -rf "$t8"

# ---------------------------------------------------------------------------
# K9: UEFI — a placed UKI yields an efi_chainload entry (no protocol:linux,
#     no cmdline); the fallback UKI gets its own entry.
# ---------------------------------------------------------------------------
t9=$(mktemp -d)
mkdir -p "$t9/modules/9.9-zen" "$t9/boot" "$t9/esp/EFI/Linux"
echo linux-zen > "$t9/modules/9.9-zen/pkgbase"
: > "$t9/esp/limine.conf"
: > "$t9/esp/EFI/Linux/shedos-linux-zen.efi"
: > "$t9/esp/EFI/Linux/shedos-linux-zen-fallback.efi"
SHEDOS_FIRMWARE=uefi SHEDOS_BOOT_DIR="$t9/boot" SHEDOS_MODULES_DIR="$t9/modules" \
    SHEDOS_ESP_DIRS="$t9/esp" bash "$renderer" >/dev/null 2>&1
c9=$t9/esp/limine.conf
if grep -qF 'protocol: efi_chainload' "$c9" \
   && grep -qF 'image_path: boot():/EFI/Linux/shedos-linux-zen.efi' "$c9" \
   && ! grep -qF 'protocol: linux' "$c9" && ! grep -qF 'kernel_cmdline:' "$c9"; then
    _ok K9_uefi_chainloads_uki
else
    _fail K9_uefi_chainloads_uki "UEFI render did not emit a clean efi_chainload entry"
fi
if grep -qF '/ShedOS Linux (Fallback)' "$c9" \
   && grep -qF 'image_path: boot():/EFI/Linux/shedos-linux-zen-fallback.efi' "$c9"; then
    _ok K9_uefi_fallback_entry
else
    _fail K9_uefi_fallback_entry "fallback UKI entry missing or mispathed"
fi
rm -rf "$t9"

# ---------------------------------------------------------------------------
# K10: UEFI — an entry is gated on its UKI; a default UKI with no -fallback
#      gets a boot entry but no fallback one.
# ---------------------------------------------------------------------------
t10=$(mktemp -d)
mkdir -p "$t10/modules/9.9-zen" "$t10/boot" "$t10/esp/EFI/Linux"
echo linux-zen > "$t10/modules/9.9-zen/pkgbase"
: > "$t10/esp/limine.conf"; : > "$t10/esp/EFI/Linux/shedos-linux-zen.efi"
SHEDOS_FIRMWARE=uefi SHEDOS_BOOT_DIR="$t10/boot" SHEDOS_MODULES_DIR="$t10/modules" \
    SHEDOS_ESP_DIRS="$t10/esp" bash "$renderer" >/dev/null 2>&1
if grep -qF '/ShedOS Linux' "$t10/esp/limine.conf" \
   && ! grep -qF '/ShedOS Linux (Fallback)' "$t10/esp/limine.conf"; then
    _ok K10_uefi_gates_missing_fallback
else
    _fail K10_uefi_gates_missing_fallback "fallback entry emitted without its UKI on the ESP"
fi
rm -rf "$t10"

# ---------------------------------------------------------------------------
# K11: UEFI — no UKI on a live ESP means zero entries → last-known-good guard
#      fires (non-zero exit, existing config untouched).
# ---------------------------------------------------------------------------
t11=$(mktemp -d)
mkdir -p "$t11/modules/9.9-zen" "$t11/boot" "$t11/esp/EFI/Linux"
echo linux-zen > "$t11/modules/9.9-zen/pkgbase"
printf 'GOOD-config\n' > "$t11/esp/limine.conf"
rc=0
SHEDOS_FIRMWARE=uefi SHEDOS_BOOT_DIR="$t11/boot" SHEDOS_MODULES_DIR="$t11/modules" \
    SHEDOS_ESP_DIRS="$t11/esp" bash "$renderer" >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ "$(cat "$t11/esp/limine.conf")" == GOOD-config ]]; then
    _ok K11_uefi_guard_keeps_last_good
else
    _fail K11_uefi_guard_keeps_last_good "missing UKI did not trip the last-known-good guard (rc=$rc)"
fi
rm -rf "$t11"

# ---------------------------------------------------------------------------
# K12: UEFI — a present recovery UKI gets its own entry, and it does NOT
#      satisfy the guard on its own (recovery without a kernel keeps last-good).
# ---------------------------------------------------------------------------
t12=$(mktemp -d)
mkdir -p "$t12/modules/9.9-zen" "$t12/boot" "$t12/esp/EFI/Linux"
echo linux-zen > "$t12/modules/9.9-zen/pkgbase"
: > "$t12/esp/limine.conf"
: > "$t12/esp/EFI/Linux/shedos-linux-zen.efi"
: > "$t12/esp/EFI/Linux/shedos-recovery.efi"
SHEDOS_FIRMWARE=uefi SHEDOS_BOOT_DIR="$t12/boot" SHEDOS_MODULES_DIR="$t12/modules" \
    SHEDOS_ESP_DIRS="$t12/esp" bash "$renderer" >/dev/null 2>&1
if grep -qF '/ShedOS Recovery' "$t12/esp/limine.conf" \
   && grep -qF 'image_path: boot():/EFI/Linux/shedos-recovery.efi' "$t12/esp/limine.conf"; then
    _ok K12_uefi_recovery_entry
else
    _fail K12_uefi_recovery_entry "recovery UKI entry missing"
fi
# recovery-only (no kernel UKI) keeps last-known-good
t12b=$(mktemp -d); mkdir -p "$t12b/modules/9.9-zen" "$t12b/boot" "$t12b/esp/EFI/Linux"
echo linux-zen > "$t12b/modules/9.9-zen/pkgbase"
printf 'GOOD\n' > "$t12b/esp/limine.conf"; : > "$t12b/esp/EFI/Linux/shedos-recovery.efi"
rc=0
SHEDOS_FIRMWARE=uefi SHEDOS_BOOT_DIR="$t12b/boot" SHEDOS_MODULES_DIR="$t12b/modules" \
    SHEDOS_ESP_DIRS="$t12b/esp" bash "$renderer" >/dev/null 2>&1 || rc=$?
if (( rc != 0 )) && [[ "$(cat "$t12b/esp/limine.conf")" == GOOD ]]; then
    _ok K12b_recovery_only_keeps_last_good
else
    _fail K12b_recovery_only_keeps_last_good "recovery-only menu overwrote the good config (rc=$rc)"
fi
rm -rf "$t12" "$t12b"

# ---------------------------------------------------------------------------
# K13: UEFI — the verbatim extra-entries append (Windows chainload) still
#      lands after the efi_chainload kernel entries.
# ---------------------------------------------------------------------------
t13=$(mktemp -d)
mkdir -p "$t13/modules/9.9-zen" "$t13/boot" "$t13/esp/EFI/Linux"
echo linux-zen > "$t13/modules/9.9-zen/pkgbase"
: > "$t13/esp/limine.conf"; : > "$t13/esp/EFI/Linux/shedos-linux-zen.efi"
printf '/Windows\n    protocol: efi_chainload\n    image_path: uuid(AAAA):/EFI/Microsoft/Boot/bootmgfw.efi\n' \
    > "$t13/extra.conf"
SHEDOS_FIRMWARE=uefi SHEDOS_EXTRA_ENTRIES="$t13/extra.conf" \
    SHEDOS_BOOT_DIR="$t13/boot" SHEDOS_MODULES_DIR="$t13/modules" \
    SHEDOS_ESP_DIRS="$t13/esp" bash "$renderer" >/dev/null 2>&1
if grep -qF '/Windows' "$t13/esp/limine.conf"; then
    _ok K13_uefi_windows_append
else
    _fail K13_uefi_windows_append "Windows chainload entry not appended on the UEFI path"
fi
rm -rf "$t13"

# ---------------------------------------------------------------------------
# SB1: Secure Boot / TPM2 / UKI tooling is in the base closure roots so it
#      lands on every install — sbctl + tpm2-tools backends, and systemd-ukify
#      the single signer that sbsigns + PCR-11-signs the UKI.
# ---------------------------------------------------------------------------
for pkg in sbctl tpm2-tools systemd-ukify; do
    if grep -qxF "$pkg" "$base_txt"; then
        _ok "SB1_base_has_$pkg"
    else
        _fail "SB1_base_has_$pkg" "missing from packages/official/base.txt"
    fi
done

# ---------------------------------------------------------------------------
# SB2: shedos-system declares the same three as runtime depends so they're
#      present when the secureboot/tpm2 verbs shell out to them.
# ---------------------------------------------------------------------------
sys_pkgbuild=$repo_root/packaging/shedos-system/PKGBUILD
for pkg in sbctl tpm2-tools systemd-ukify; do
    if grep -qE "^\s*'$pkg'" "$sys_pkgbuild"; then
        _ok "SB2_depends_has_$pkg"
    else
        _fail "SB2_depends_has_$pkg" "missing from shedos-system depends()"
    fi
done

# ---------------------------------------------------------------------------
# SB3: the secureboot + tpm2 verbs are allowlisted AND their executables exist
#      — the package() install loop fails the build if a name has no tree/
#      file, so assert both halves together.
# ---------------------------------------------------------------------------
libexec_sys=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman
for verb in secureboot tpm2; do
    if awk '/_libexec_shedman=\(/,/^[[:space:]]*\)/' "$sys_pkgbuild" \
            | grep -qE "(^|[[:space:]])$verb([[:space:]]|\$)"; then
        _ok "SB3_allowlist_has_$verb"
    else
        _fail "SB3_allowlist_has_$verb" "not in _libexec_shedman allowlist"
    fi
    if [[ -x $libexec_sys/$verb ]]; then
        _ok "SB3_verb_file_$verb"
    else
        _fail "SB3_verb_file_$verb" "missing or non-executable $libexec_sys/$verb"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$((pass + fail))
echo
echo "kernel wiring: $pass/$total passed"
if (( fail > 0 )); then
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
