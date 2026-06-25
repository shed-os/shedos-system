#!/usr/bin/env bash
# Guard the first-boot boot reconfigure (encrypt-reconfigure.sh): after in-place
# encryption it swaps the cmdline's root= for the LUKS tokens, adds sd-encrypt to
# HOOKS, and rebuilds the initramfs + UKI/Limine — mirroring bootloader.py so an
# encrypted live box and a fresh encrypted install unlock the same way. The three
# rebuild writers are PATH-stubbed; the cmdline/HOOKS transforms run for real.

set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
recon=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/encrypt-reconfigure.sh

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# Fixture /etc files + stubbed writers that log argv (and, for the renderer, the
# SHEDOS_LIMINE_CMDLINE it was handed). The default container list is root-only.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/etc/kernel" "$d/etc/shedos/secureboot" "$d/boot"
    printf 'root=UUID=aaaa rootflags=subvol=@ rootfstype=btrfs rw quiet splash loglevel=3 rd.udev.log_level=3 fbcon=nodefer lsm=landlock,lockdown,yama,integrity,apparmor,bpf\n' \
        > "$d/etc/kernel/cmdline"
    printf 'HOOKS=(base systemd autodetect modconf keyboard sd-vconsole block plymouth shedos-recovery filesystems)\n' \
        > "$d/etc/mkinitcpio.conf"
    printf '/dev/disk/by-uuid/RUUID\n' > "$d/etc/shedos/secureboot/containers"
    local t
    for t in rebuild-initramfs.sh build-uki.sh render-limine-config.sh; do
        cat > "$d/bin/$t" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$t" "\$*" >> "$d/writers.log"
[[ -n \${SHEDOS_LIMINE_CMDLINE:-} ]] && printf 'LIMINE_CMDLINE=%s\n' "\$SHEDOS_LIMINE_CMDLINE" >> "$d/writers.log"
exit 0
EOF
        chmod +x "$d/bin/$t"
    done
    printf '%s\n' "$d"
}

# Run the whole reconfigure in the sandbox; FW selects the firmware path.
_run() {
    local d=$1; shift
    PATH="$d/bin:$PATH" \
    SHEDOS_REENCRYPT_BINDIR="$d/bin" \
    SHEDOS_KERNEL_CMDLINE_FILE="$d/etc/kernel/cmdline" \
    SHEDOS_KERNEL_CMDLINE_FALLBACK="$d/etc/kernel/cmdline-fallback" \
    SHEDOS_MKINITCPIO_CONF="$d/etc/mkinitcpio.conf" \
    SHEDMAN_KEY_CONTAINERS="$d/etc/shedos/secureboot/containers" \
    SHEDOS_LIMINE_CONF="$d/boot/limine.conf" \
    SHEDOS_ENCRYPT_FSTAB="$d/etc/fstab" \
    SHEDOS_FIRMWARE="${FW:-uefi}" \
        bash "$recon" "$@"
}

# RC1: a root+swap conversion swaps root= for the full LUKS token set, adds the
# swap rd.luks.name, points resume at the decrypted swap mapper, and preserves
# every other token; the stale root=UUID and resume=UUID are gone.
d=$(_mk_sandbox)
printf '/dev/disk/by-uuid/RUUID\n/dev/disk/by-uuid/SUUID\n' > "$d/etc/shedos/secureboot/containers"
printf 'root=UUID=aaaa rootflags=subvol=@ rootfstype=btrfs rw quiet splash lsm=apparmor resume=UUID=oldswap\n' > "$d/etc/kernel/cmdline"
_run "$d" >/dev/null 2>&1
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null); ok=1
[[ $cl == *"rd.luks.name=RUUID=luks-RUUID"* ]] || ok=0
[[ $cl == *"rd.luks.options=discard,tries=0"* ]] || ok=0
[[ $cl == *"cryptdevice=UUID=RUUID:luks-RUUID:allow-discards"* ]] || ok=0
[[ $cl == *"root=/dev/mapper/luks-RUUID"* ]] || ok=0
[[ $cl == *"rd.luks.name=SUUID=luks-SUUID"* ]] || ok=0
[[ $cl == *"resume=/dev/mapper/luks-SUUID"* ]] || ok=0
[[ $cl == *"rootflags=subvol=@"* && $cl == *"lsm=apparmor"* ]] || ok=0
[[ $cl != *"root=UUID=aaaa"* && $cl != *"resume=UUID=oldswap"* ]] || ok=0
if (( ok )); then _ok RC1_cmdline_root_and_swap; else _fail RC1_cmdline_root_and_swap "$cl"; fi

# RCF1: a root+swap conversion adds the decrypted swap mapper to fstab so swapon
# activates it at boot, and a re-run does not duplicate the line.
d=$(_mk_sandbox)
printf '/dev/disk/by-uuid/RUUID\n/dev/disk/by-uuid/SUUID\n' > "$d/etc/shedos/secureboot/containers"
_run "$d" >/dev/null 2>&1
_run "$d" >/dev/null 2>&1
n=$(grep -cE '^/dev/mapper/luks-SUUID[[:space:]]+none[[:space:]]+swap' "$d/etc/fstab" 2>/dev/null)
if [[ $n == 1 ]]; then _ok RCF1_swap_fstab_idempotent; else _fail RCF1_swap_fstab_idempotent "n=$n fstab=[$(cat "$d/etc/fstab" 2>/dev/null)]"; fi

# RCF2: a root-only conversion writes no swap fstab line.
d=$(_mk_sandbox)
_run "$d" >/dev/null 2>&1
if ! grep -qE 'swap' "$d/etc/fstab" 2>/dev/null; then _ok RCF2_root_only_no_swap_fstab; else _fail RCF2_root_only_no_swap_fstab "fstab=[$(cat "$d/etc/fstab" 2>/dev/null)]"; fi

# RC2: a root-only conversion adds the root LUKS tokens, names no swap, and leaves
# the box's existing resume= untouched (swap was not encrypted).
d=$(_mk_sandbox)
printf 'root=UUID=aaaa rootflags=subvol=@ rw resume=UUID=keepme\n' > "$d/etc/kernel/cmdline"
_run "$d" >/dev/null 2>&1
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $cl == *"root=/dev/mapper/luks-RUUID"* && $cl != *SUUID* && $cl == *"resume=UUID=keepme"* ]]; then
    _ok RC2_cmdline_root_only
else
    _fail RC2_cmdline_root_only "$cl"
fi

# RC3: sd-encrypt lands right before shedos-recovery (the installer's order), and
# a re-run does not add it twice.
d=$(_mk_sandbox)
_run "$d" >/dev/null 2>&1
hooks=$(grep -E '^HOOKS=' "$d/etc/mkinitcpio.conf")
_run "$d" >/dev/null 2>&1
n=$(grep -o 'sd-encrypt' "$d/etc/mkinitcpio.conf" | wc -l)
if [[ $hooks == *"plymouth sd-encrypt shedos-recovery"* ]] && (( n == 1 )); then _ok RC3_hooks_sd_encrypt; else _fail RC3_hooks_sd_encrypt "hooks=[$hooks] n=$n"; fi

# RC4: the fallback cmdline drops quiet+splash but keeps the LUKS root.
d=$(_mk_sandbox)
_run "$d" >/dev/null 2>&1
fb=$(cat "$d/etc/kernel/cmdline-fallback" 2>/dev/null)
if [[ $fb == *"root=/dev/mapper/luks-RUUID"* && $fb != *quiet* && $fb != *splash* ]]; then _ok RC4_fallback_no_splash; else _fail RC4_fallback_no_splash "$fb"; fi

# RC5: UEFI rebuilds the signed UKI; BIOS renders Limine with the new cmdline.
d=$(_mk_sandbox); FW=uefi _run "$d" >/dev/null 2>&1
if grep -q 'rebuild-initramfs.sh' "$d/writers.log" 2>/dev/null \
   && grep -q 'build-uki.sh --rebuild' "$d/writers.log" 2>/dev/null \
   && ! grep -q 'render-limine' "$d/writers.log" 2>/dev/null; then _ok RC5a_uefi_uki; else _fail RC5a_uefi_uki "$(cat "$d/writers.log" 2>/dev/null)"; fi
d=$(_mk_sandbox); FW=bios _run "$d" >/dev/null 2>&1
if grep -q 'render-limine-config.sh' "$d/writers.log" 2>/dev/null \
   && grep -qE 'LIMINE_CMDLINE=.*root=/dev/mapper/luks-RUUID' "$d/writers.log" 2>/dev/null \
   && ! grep -q 'build-uki' "$d/writers.log" 2>/dev/null; then _ok RC5b_bios_limine; else _fail RC5b_bios_limine "$(cat "$d/writers.log" 2>/dev/null)"; fi

# RC6: idempotent — re-running re-derives the SAME cmdline (no doubled LUKS tokens).
d=$(_mk_sandbox)
_run "$d" >/dev/null 2>&1; first=$(cat "$d/etc/kernel/cmdline")
_run "$d" >/dev/null 2>&1; second=$(cat "$d/etc/kernel/cmdline")
nroot=$(grep -o 'root=/dev/mapper' <<<"$second" | wc -l)
if [[ $first == "$second" ]] && (( nroot == 1 )); then _ok RC6_idempotent; else _fail RC6_idempotent "first=[$first] second=[$second] nroot=$nroot"; fi

# RC7: user-tuned + nvidia tokens survive the conversion (surgical transform, not
# a rebuild from the install baseline).
d=$(_mk_sandbox)
printf 'root=UUID=aaaa rootflags=subvol=@ rw quiet splash nvidia_drm.modeset=1 mitigations=off lsm=apparmor\n' > "$d/etc/kernel/cmdline"
_run "$d" >/dev/null 2>&1
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $cl == *"nvidia_drm.modeset=1"* && $cl == *"mitigations=off"* && $cl == *"root=/dev/mapper/luks-RUUID"* ]]; then _ok RC7_preserves_tuning; else _fail RC7_preserves_tuning "$cl"; fi

# RC8: the PKGBUILD ships the reconfigure lib (the staged-but-not-installed bug).
pkgbuild=$repo_root/packaging/shedos-system/PKGBUILD
if grep -q 'tree/usr/lib/shedos/encrypt-reconfigure.sh' "$pkgbuild" 2>/dev/null; then _ok RC8_packaged; else _fail RC8_packaged "missing install line"; fi

# RC9: a placeholder /etc/kernel/cmdline is ignored; the real cmdline is lifted
# from limine.conf's kernel_cmdline: line (the pre-UKI box source of truth) so the
# preserved tokens (rootflags=subvol=@, lsm) survive.
d=$(_mk_sandbox)
printf '# Per-box kernel command line\nSHEDOS_PLACEHOLDER_CMDLINE\n' > "$d/etc/kernel/cmdline"
printf 'timeout: 3\n/ShedOS\n    protocol: linux\n    kernel_cmdline: root=UUID=aaaa rootflags=subvol=@ rootfstype=btrfs rw quiet splash lsm=apparmor\n' > "$d/boot/limine.conf"
_run "$d" >/dev/null 2>&1; rc=$?
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $rc -eq 0 && $cl == *"root=/dev/mapper/luks-RUUID"* && $cl == *"rootflags=subvol=@"* && $cl == *"lsm=apparmor"* && $cl != *PLACEHOLDER* ]]; then
    _ok RC9_placeholder_lifts_from_limine
else
    _fail RC9_placeholder_lifts_from_limine "rc=$rc cl=[$cl]"
fi

# RC10: a placeholder cmdline with no limine.conf fallback is REFUSED — no writer
# runs and the placeholder is left untouched (never transformed into a brick).
d=$(_mk_sandbox)
printf 'SHEDOS_PLACEHOLDER_CMDLINE\n' > "$d/etc/kernel/cmdline"
_run "$d" >/dev/null 2>&1; rc=$?
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $rc -ne 0 && $cl == *PLACEHOLDER* && ! -s $d/writers.log ]]; then
    _ok RC10_refuses_placeholder
else
    _fail RC10_refuses_placeholder "rc=$rc cl=[$cl] writers=[$(cat "$d/writers.log" 2>/dev/null)]"
fi

# RC11: a mkinitcpio.conf with no HOOKS= line is a hard error — refuse before the
# rebuild, so a cmdline that unlocks from rd.luks.* never ships without sd-encrypt.
d=$(_mk_sandbox)
printf 'MODULES=(btrfs)\n' > "$d/etc/mkinitcpio.conf"
_run "$d" >/dev/null 2>&1; rc=$?
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $rc -ne 0 ]] && ! grep -q 'rebuild-initramfs' "$d/writers.log" 2>/dev/null && [[ $cl == *"root=UUID=aaaa"* ]]; then
    _ok RC11_no_hooks_refused
else
    _fail RC11_no_hooks_refused "rc=$rc cl=[$cl] writers=[$(cat "$d/writers.log" 2>/dev/null)]"
fi

# RC12: two containers but the swap path can't be resolved → refuse, never silently
# drop swap-unlock + resume.
d=$(_mk_sandbox)
printf '/dev/disk/by-uuid/RUUID\n/dev/sda3\n' > "$d/etc/shedos/secureboot/containers"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/cryptsetup"; chmod +x "$d/bin/cryptsetup"
out=$(_run "$d" 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"swap LUKS UUID"* ]]; then _ok RC12_swap_unresolved_refused; else _fail RC12_swap_unresolved_refused "rc=$rc out=$out"; fi

# RC13: a source cmdline with no rootflags=subvol=@ is refused — the transform
# never adds it, so baking one without it would mount the btrfs top-level
# read-only (no init). No writer runs; the cmdline is left untouched.
d=$(_mk_sandbox)
printf 'root=UUID=aaaa rw quiet splash\n' > "$d/etc/kernel/cmdline"
out=$(_run "$d" 2>&1); rc=$?
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $rc -ne 0 && $out == *rootflags* && ! -s $d/writers.log && $cl == *"root=UUID=aaaa"* ]]; then
    _ok RC13_refuses_no_rootflags
else
    _fail RC13_refuses_no_rootflags "rc=$rc out=$out cl=[$cl]"
fi

# RC14: a legacy (non-systemd) HOOKS line is refused — sd-encrypt is inert without
# the systemd hook, so baking it would never unlock the root. No writer runs; the
# cmdline is left untouched.
d=$(_mk_sandbox)
printf 'HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)\n' > "$d/etc/mkinitcpio.conf"
out=$(_run "$d" 2>&1); rc=$?
cl=$(cat "$d/etc/kernel/cmdline" 2>/dev/null)
if [[ $rc -ne 0 && $out == *systemd* && ! -s $d/writers.log && $cl == *"root=UUID=aaaa"* ]]; then
    _ok RC14_refuses_legacy_hooks
else
    _fail RC14_refuses_legacy_hooks "rc=$rc out=$out cl=[$cl]"
fi

total=$((pass + fail)); echo; echo "encrypt-reconfigure: $pass/$total passed"
(( fail == 0 ))
