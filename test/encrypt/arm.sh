#!/usr/bin/env bash
# Guard the `shedman encrypt` arm step: it runs the preflight, captures the
# passphrase + disk geometry, stashes a 0600 keyfile + the armed ESP state, stages
# the reencrypt hook into the initramfs, rebuilds the boot images, and reboots —
# the offline driver rewrites the bytes next boot. Writers + reboot are PATH-stubbed;
# the passphrase never reaches argv.

set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
verb=$repo_root/tree/usr/libexec/shedman/encrypt
esp_lib=$repo_root/tree/usr/lib/shedos/esp-state.sh

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A standard-layout sandbox: @-subvol /proc/cmdline, a systemd HOOKS line, AC power,
# and stubs that log argv. cryptsetup isLuks reports not-LUKS so btrfs-plain passes.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin" "$d/etc" "$d/esp" "$d/power/ADP0"
    printf 'BOOT_IMAGE=/x root=UUID=inner rootflags=subvol=@ rootfstype=btrfs rw quiet\n' > "$d/proc-cmdline"
    printf 'HOOKS=(base systemd autodetect modconf keyboard sd-vconsole block plymouth shedos-recovery filesystems)\n' > "$d/etc/mkinitcpio.conf"
    printf 'Mains\n' > "$d/power/ADP0/type"; printf '1\n' > "$d/power/ADP0/online"
    printf 'MemTotal: 4194304 kB\n' > "$d/meminfo"
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
[[ \$1 == isLuks ]] && exit \${STUB_ISLUKS:-1}
exit 0
EOF
    cat > "$d/bin/findmnt" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *SOURCE*) printf '%s\n' "\${STUB_ROOTDEV:-/dev/sda2}[/@]" ;;
    *UUID*)   printf '%s\n' "\${STUB_UUID:-inner-fs-uuid}" ;;
    *FSTYPE*) printf '%s\n' "\${STUB_FSTYPE:-btrfs}" ;;
    *AVAIL*)  printf '%s\n' "\${STUB_AVAIL:-107374182400}" ;;
esac
exit 0
EOF
    cat > "$d/bin/blkid" <<EOF
#!/usr/bin/env bash
# arm captures the root PARTUUID with: blkid -s PARTUUID -o value <dev>
[[ " \$* " == *" PARTUUID "* ]] && { printf '%s\n' "\${STUB_PARTUUID:-1111aaaa-2222-3333-4444-555566667777}"; exit 0; }
exit 0
EOF
    local t
    for t in rebuild-initramfs.sh build-uki.sh render-limine-config.sh; do
        printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/writers.log"\nexit 0\n' "$t" "$d" > "$d/bin/$t"
    done
    cat > "$d/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/systemctl.log"
exit 0
EOF
    cat > "$d/bin/blockdev" <<EOF
#!/usr/bin/env bash
[[ \$1 == --getsize64 ]] && { echo "\${STUB_ROOTSIZE:-10737418240}"; exit 0; }
exit 0
EOF
    cat > "$d/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
    chmod +x "$d/bin/"*
    printf '%s\n' "$d"
}

# Source the verb in the sandbox and run one function (source-guard fires; the
# dispatch does NOT run). Extra env comes from the caller's prefix.
_srun() {  # $1=dir $2=call-string
    local d=$1 call=$2
    PATH="$d/bin:$PATH" bash -c "source \"\$1\"; $call" _ "$verb"
}

# Run the verb in the sandbox with the given stdin (real newlines) and args.
_run() {  # $1=dir $2=stdin ; $3.. = verb args
    local d=$1 input=$2; shift 2
    printf '%s' "$input" | PATH="$d/bin:$PATH" \
    SHEDOS_REENCRYPT_ESP="$d/esp" SHEDOS_REENCRYPT_KEYFILE="$d/esp/key" \
    ESP_STATE_FILE="$d/esp/state" SHEDOS_MKINITCPIO_CONF="$d/etc/mkinitcpio.conf" \
    SHEDMAN_ENCRYPT_PROC_CMDLINE="$d/proc-cmdline" SHEDOS_REENCRYPT_BINDIR="$d/bin" \
    SHEDMAN_ENCRYPT_ESP_STATE_LIB="$esp_lib" \
    SHEDMAN_ENCRYPT_POWER_DIR="$d/power" SHEDMAN_ENCRYPT_MEMINFO="$d/meminfo" \
    SHEDOS_FIRMWARE="${FW:-uefi}" \
        bash "$verb" "$@"
}

# The full arm with the passphrase entered twice; --yes skips the ack + reboot.
_run_arm() { local d=$1; shift; _run "$d" $'diskpw\ndiskpw\n' --yes "$@"; }

# AR1: the disk/partition split handles sdaN and the nvme p-form.
d=$(_mk_sandbox)
a=$(_srun "$d" '_disk_and_partn /dev/sda2'); b=$(_srun "$d" '_disk_and_partn /dev/nvme0n1p2')
if [[ $a == "/dev/sda 2" && $b == "/dev/nvme0n1 2" ]]; then _ok AR1_disk_partn; else _fail AR1_disk_partn "a=[$a] b=[$b]"; fi

# AR2: the standard-layout gate passes on @-subvol + systemd, refuses otherwise.
d=$(_mk_sandbox)
SHEDMAN_ENCRYPT_PROC_CMDLINE="$d/proc-cmdline" SHEDOS_MKINITCPIO_CONF="$d/etc/mkinitcpio.conf" _srun "$d" '_preflight_assert_standard_layout'; ok_std=$?
printf 'root=UUID=inner rw\n' > "$d/nf"
out_nf=$(SHEDMAN_ENCRYPT_PROC_CMDLINE="$d/nf" SHEDOS_MKINITCPIO_CONF="$d/etc/mkinitcpio.conf" _srun "$d" '_preflight_assert_standard_layout' 2>&1); rc_nf=$?
printf 'HOOKS=(base udev autodetect block filesystems)\n' > "$d/legacy"
out_lg=$(SHEDMAN_ENCRYPT_PROC_CMDLINE="$d/proc-cmdline" SHEDOS_MKINITCPIO_CONF="$d/legacy" _srun "$d" '_preflight_assert_standard_layout' 2>&1); rc_lg=$?
printf 'root=/dev/sda2 rootflags=subvol=@ rw\n' > "$d/dp"
out_dp=$(SHEDMAN_ENCRYPT_PROC_CMDLINE="$d/dp" SHEDOS_MKINITCPIO_CONF="$d/etc/mkinitcpio.conf" _srun "$d" '_preflight_assert_standard_layout' 2>&1); rc_dp=$?
if [[ $ok_std -eq 0 && $rc_nf -ne 0 && $out_nf == *rootflags* && $rc_lg -ne 0 && $out_lg == *legacy* && $rc_dp -ne 0 && $out_dp == *"root=UUID="* ]]; then
    _ok AR2_standard_layout
else
    _fail AR2_standard_layout "std=$ok_std nf=$rc_nf lg=$rc_lg dp=$rc_dp/$out_dp"
fi

# AR3: the new-secret read refuses a mismatch and an empty entry, returns a match.
d=$(_mk_sandbox)
m=$(printf 'a\nb\n' | _srun "$d" '_read_new_secret pass' 2>&1); rc_m=$?
printf '\n\n' | _srun "$d" '_read_new_secret pass' >/dev/null 2>&1; rc_e=$?
g=$(printf 'x\nx\n' | _srun "$d" '_read_new_secret pass' 2>/dev/null)
if [[ $rc_m -ne 0 && $m == *"did not match"* && $rc_e -ne 0 && $g == x ]]; then _ok AR3_new_secret; else _fail AR3_new_secret "m=$rc_m/$m e=$rc_e g=[$g]"; fi

# AR4: the reencrypt hook lands before shedos-recovery and a re-run adds none.
d=$(_mk_sandbox)
_srun "$d" "_stage_reencrypt_hook '$d/etc/mkinitcpio.conf'" >/dev/null 2>&1
hooks=$(grep -E '^HOOKS=' "$d/etc/mkinitcpio.conf")
_srun "$d" "_stage_reencrypt_hook '$d/etc/mkinitcpio.conf'" >/dev/null 2>&1
n=$(grep -o 'shedos-reencrypt' "$d/etc/mkinitcpio.conf" | wc -l)
if [[ $hooks == *"shedos-reencrypt shedos-recovery"* ]] && (( n == 1 )); then _ok AR4_stage_hook; else _fail AR4_stage_hook "hooks=[$hooks] n=$n"; fi

# AR5: the full arm stashes a 0600 keyfile + the armed state, stages the hook,
# rebuilds the UKI (UEFI), and reboots.
d=$(_mk_sandbox)
# blockdev 10G, MemTotal 4 GiB -> shrink_target = 10G - (4 GiB swap + 32M header).
exp_shrink=$(( 10737418240 - (4 * 1073741824 + 33554432) ))
FW=uefi _run_arm "$d" >/dev/null 2>&1; rc=$?
perm=$(stat -c '%a' "$d/esp/key" 2>/dev/null); key=$(cat "$d/esp/key" 2>/dev/null)
st=$(cat "$d/esp/state" 2>/dev/null)
if [[ $rc -eq 0 && $perm == 600 && $key == diskpw \
   && $st == *"phase=armed"* && $st == *"containers=/dev/sda2"* && $st == *"disk=/dev/sda"* && $st == *"rootpn=2"* && $st == *"swap=yes"* && $st == *"shrink_target=$exp_shrink"* && $st == *"inner_uuid=inner-fs-uuid"* \
   && $(grep -c shedos-reencrypt "$d/etc/mkinitcpio.conf") -ge 1 \
   ]] && grep -q 'rebuild-initramfs.sh' "$d/writers.log" && grep -q 'build-uki.sh --rebuild' "$d/writers.log" \
     && grep -q 'reboot' "$d/systemctl.log"; then
    _ok AR5_arm_full
else
    _fail AR5_arm_full "rc=$rc perm=$perm key=[$key] st=[$st] w=[$(cat "$d/writers.log" 2>/dev/null)]"
fi

# AR6: --no-swap records swap=no so the driver carves nothing.
d=$(_mk_sandbox)
_run_arm "$d" --no-swap >/dev/null 2>&1
if grep -q 'swap=no' "$d/esp/state" 2>/dev/null; then _ok AR6_no_swap; else _fail AR6_no_swap "$(cat "$d/esp/state" 2>/dev/null)"; fi

# AR7: the passphrase never reaches any tool's argv.
d=$(_mk_sandbox)
_run_arm "$d" >/dev/null 2>&1
if grep -rq diskpw "$d"/*.log 2>/dev/null; then _fail AR7_no_secret_argv "passphrase on argv"; else _ok AR7_no_secret_argv; fi

# AR8: a non-standard box (no rootflags=subvol=@) is refused before anything is
# stashed — no keyfile, no state, no writer, no reboot.
d=$(_mk_sandbox)
printf 'root=UUID=inner rw\n' > "$d/proc-cmdline"
out=$(_run_arm "$d" 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *rootflags* && ! -e $d/esp/key && ! -e $d/esp/state && ! -s $d/writers.log && ! -s $d/systemctl.log ]]; then
    _ok AR8_non_standard_refused
else
    _fail AR8_non_standard_refused "rc=$rc out=$out key=$([[ -e $d/esp/key ]]&&echo y)"
fi

# AR9: the encrypt verb ships — package() installs what the declarations name,
# so a verb with no declaration does not reach a box at all.
if [[ -f $repo_root/tree/usr/share/shedman/verbs.d/encrypt.toml ]]; then _ok AR9_packaged; else _fail AR9_packaged "no declaration names encrypt"; fi

# AR10: a boot-image rebuild failure arms NOTHING — the conf is reverted (no
# reencrypt hook), no keyfile, no state, no reboot — so a later kernel rebuild
# cannot bake a leftover hook into a silent encrypt.
d=$(_mk_sandbox)
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/build-uki.sh"; chmod +x "$d/bin/build-uki.sh"
FW=uefi _run_arm "$d" >/dev/null 2>&1; rc=$?
if [[ $rc -ne 0 && ! -e $d/esp/key && ! -e $d/esp/state ]] \
   && ! grep -q shedos-reencrypt "$d/etc/mkinitcpio.conf" \
   && ! grep -q reboot "$d/systemctl.log" 2>/dev/null; then
    _ok AR10_rebuild_fail_nothing_armed
else
    _fail AR10_rebuild_fail_nothing_armed "rc=$rc key=$([[ -e $d/esp/key ]] && echo y) hooks=[$(grep '^HOOKS' "$d/etc/mkinitcpio.conf")]"
fi

# AR11: --disarm cancels an armed conversion — unstages the hook, rebuilds, shreds
# the keyfile, clears the state.
d=$(_mk_sandbox)
_run_arm "$d" >/dev/null 2>&1
_run "$d" '' --disarm >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && ! -e $d/esp/key && ! -e $d/esp/state ]] && ! grep -q shedos-reencrypt "$d/etc/mkinitcpio.conf"; then
    _ok AR11_disarm
else
    _fail AR11_disarm "rc=$rc key=$([[ -e $d/esp/key ]] && echo y) state=$([[ -e $d/esp/state ]] && echo y) hooks=[$(grep '^HOOKS' "$d/etc/mkinitcpio.conf")]"
fi

# AR12: declining the reboot leaves the box armed (state written) but unbooted, and
# the message points at --disarm — never a misleading "aborted".
d=$(_mk_sandbox)
out=$(_run "$d" $'encrypt this disk\ndiskpw\ndiskpw\nno\n' 2>&1)
if grep -q 'phase=armed' "$d/esp/state" 2>/dev/null && ! grep -q reboot "$d/systemctl.log" 2>/dev/null && [[ $out == *--disarm* && $out != *"— aborted"* ]]; then
    _ok AR12_decline_stays_armed
else
    _fail AR12_decline_stays_armed "out=$out reboot=[$(cat "$d/systemctl.log" 2>/dev/null)]"
fi

# --- --status / --resume (#201) ------------------------------------------------
# Both read the ESP phase; --status reports it (read-only), --resume re-drives a
# stalled conversion. The phase is seeded straight into the ESP state file.

# ST1: phase=armed -> reports armed + the target device.
d=$(_mk_sandbox); printf 'phase=armed\ncontainers=/dev/sda2\n' > "$d/esp/state"
out=$(_run "$d" '' --status 2>&1)
if [[ $out == *armed* && $out == */dev/sda2* ]]; then _ok ST1_status_armed; else _fail ST1_status_armed "out=$out"; fi

# ST2: phase=encrypting -> reports the finalizing state.
d=$(_mk_sandbox); printf 'phase=encrypting\n' > "$d/esp/state"
out=$(_run "$d" '' --status 2>&1)
if [[ $out == *encrypting* ]]; then _ok ST2_status_encrypting; else _fail ST2_status_encrypting "out=$out"; fi

# ST3: phase=flip-pending -> reports the switchover state.
d=$(_mk_sandbox); printf 'phase=flip-pending\n' > "$d/esp/state"
out=$(_run "$d" '' --status 2>&1)
if [[ $out == *flip-pending* ]]; then _ok ST3_status_flip_pending; else _fail ST3_status_flip_pending "out=$out"; fi

# ST4: no state + root is an opened LUKS mapper -> already encrypted.
d=$(_mk_sandbox)
out=$(STUB_ROOTDEV=/dev/mapper/luks-abc _run "$d" '' --status 2>&1)
if [[ $out == *"already encrypted"* ]]; then _ok ST4_status_already_encrypted; else _fail ST4_status_already_encrypted "out=$out"; fi

# ST5: no state + a plain root -> nothing armed or in progress.
d=$(_mk_sandbox)
out=$(_run "$d" '' --status 2>&1)
if [[ $out == *"no in-place encryption"* ]]; then _ok ST5_status_none; else _fail ST5_status_none "out=$out"; fi

# ST6: non-root -> refused (the ESP state is on a root-only mount).
d=$(_mk_sandbox); printf 'phase=armed\n' > "$d/esp/state"
out=$(STUB_UID=1000 _run "$d" '' --status 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"requires root"* ]]; then _ok ST6_status_needs_root; else _fail ST6_status_needs_root "rc=$rc out=$out"; fi

# RS1: --resume on phase=armed with the hook already staged -> no rebuild, points at a reboot.
d=$(_mk_sandbox); printf 'phase=armed\n' > "$d/esp/state"
sed -i -E '/^HOOKS=/ s/\bshedos-recovery\b/shedos-reencrypt shedos-recovery/' "$d/etc/mkinitcpio.conf"
out=$(_run "$d" '' --resume 2>&1)
if [[ $out == *reboot* && ! -s "$d/writers.log" ]]; then _ok RS1_resume_armed_staged; else _fail RS1_resume_armed_staged "out=$out writers=[$(cat "$d/writers.log" 2>/dev/null)]"; fi

# RS2: --resume on phase=armed with the hook missing -> re-stage + rebuild.
d=$(_mk_sandbox); printf 'phase=armed\n' > "$d/esp/state"
out=$(_run "$d" '' --resume 2>&1)
if grep -q 'shedos-reencrypt' "$d/etc/mkinitcpio.conf" && [[ -s "$d/writers.log" && $out == *reboot* ]]; then _ok RS2_resume_armed_restages; else _fail RS2_resume_armed_restages "out=$out hooks=[$(grep '^HOOKS' "$d/etc/mkinitcpio.conf")] writers=[$(cat "$d/writers.log" 2>/dev/null)]"; fi

# RS3: --resume on phase=encrypting -> re-drives the finalize unit (which pulls enrol).
d=$(_mk_sandbox); printf 'phase=encrypting\n' > "$d/esp/state"
_run "$d" '' --resume >/dev/null 2>&1
if grep -q 'start shedos-encrypt-finalize.service' "$d/systemctl.log" 2>/dev/null; then _ok RS3_resume_encrypting_finalizes; else _fail RS3_resume_encrypting_finalizes "systemctl=[$(cat "$d/systemctl.log" 2>/dev/null)]"; fi

# RS4: --resume on phase=flip-pending -> same finalize re-drive.
d=$(_mk_sandbox); printf 'phase=flip-pending\n' > "$d/esp/state"
_run "$d" '' --resume >/dev/null 2>&1
if grep -q 'start shedos-encrypt-finalize.service' "$d/systemctl.log" 2>/dev/null; then _ok RS4_resume_flip_pending_finalizes; else _fail RS4_resume_flip_pending_finalizes "systemctl=[$(cat "$d/systemctl.log" 2>/dev/null)]"; fi

# RS5: --resume with no conversion in flight -> refuses.
d=$(_mk_sandbox)
out=$(_run "$d" '' --resume 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"nothing to resume"* ]]; then _ok RS5_resume_nothing; else _fail RS5_resume_nothing "rc=$rc out=$out"; fi

# RS6: --resume non-root -> refused.
d=$(_mk_sandbox); printf 'phase=armed\n' > "$d/esp/state"
out=$(STUB_UID=1000 _run "$d" '' --resume 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"requires root"* ]]; then _ok RS6_resume_needs_root; else _fail RS6_resume_needs_root "rc=$rc out=$out"; fi

total=$((pass + fail)); echo; echo "encrypt-arm: $pass/$total passed"
(( fail == 0 ))
