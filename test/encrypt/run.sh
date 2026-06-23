#!/usr/bin/env bash
# Guard the `shedman encrypt` subcommand's preflight: it must refuse to touch a disk
# that isn't plain btrfs, that's on low battery, or that's too full for the 32M
# header tail — and force a typed data-loss acknowledgement before arming. No
# byte is mutated here; cryptsetup/findmnt/sgdisk/systemctl are PATH-stubbed so
# the gauntlet runs unprivileged in CI and secrets are asserted off argv.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
verb=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman/encrypt

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A sandbox of PATH-stubbed binaries. cryptsetup logs argv to $d/cryptsetup.log
# and, for `isLuks`, exits $STUB_ISLUKS (default 1 = not LUKS). findmnt answers
# from $STUB_ROOTDEV / $STUB_FSTYPE / $STUB_AVAIL. id -u reports $STUB_UID.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin"
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
[[ \$1 == isLuks ]] && exit \${STUB_ISLUKS:-1}
if [[ \$1 == open && \$2 == --test-passphrase ]]; then exit \${STUB_OPEN_RC:-0}; fi
exit 0
EOF
    cat > "$d/bin/findmnt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/findmnt.log"
src=\${STUB_ROOTDEV:-/dev/sda2}
case "\$*" in
    *SOURCE*) printf '%s\n' "\$src" ;;
    *FSTYPE*) printf '%s\n' "\${STUB_FSTYPE:-btrfs}" ;;
    *AVAIL*)  printf '%s\n' "\${STUB_AVAIL:-107374182400}" ;;
esac
exit 0
EOF
    for b in sgdisk systemctl mount umount; do
        cat > "$d/bin/$b" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/$b.log"
exit 0
EOF
    done
    # Default btrfs stub; the S*/GB* cases override it with size-specific ones.
    cat > "$d/bin/btrfs" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/btrfs.log"
[[ \$1 == filesystem && \$2 == usage ]] && echo "Device size:                10737418240"
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

# Run the verb directly in the sandbox (for the dispatch/help cases).
_run() {
    local d=$1; shift
    PATH="$d/bin:$PATH" \
    SHEDMAN_ENCRYPT_POWER_DIR="${POWER_DIR:-$d/power}" \
    SHEDMAN_ENCRYPT_MEMINFO="${MEMINFO:-$d/meminfo}" \
        bash "$verb" "$@"
}

# Source the verb in a sandbox subshell and run one function. Passing $verb as $1
# (not $0) keeps BASH_SOURCE[0] != $0 so the verb's source guard fires and the
# dispatch does NOT run — only the functions get defined.
_srun() {  # $1=dir $2=fn-call-string ; extra env via the caller's prefix
    local d=$1 call=$2
    PATH="$d/bin:$PATH" bash -c "source \"\$1\"; $call" _ "$verb"
}

# Seed a power-supply tree: $1=dir $2=type (Mains|Battery) $3=online/capacity.
_seed_power() {
    local d=$1 type=$2 val=$3
    local p="$d/power/BAT0"
    [[ $type == Mains ]] && p="$d/power/ADP0"
    mkdir -p "$p"; printf '%s\n' "$type" > "$p/type"
    if [[ $type == Mains ]]; then printf '%s\n' "$val" > "$p/online"
    else printf '%s\n' "$val" > "$p/capacity"; fi
}

# C1: --help exits 0 with the usage banner.
d=$(_mk_sandbox)
out=$(_run "$d" --help); rc=$?
if [[ $rc -eq 0 && $out == *"Usage: sudo shedman encrypt"* ]]; then _ok C1_help; else _fail C1_help "rc=$rc"; fi

# C2: an unknown subcommand exits 2.
_run "$d" frobnicate >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then _ok C2_unknown; else _fail C2_unknown "rc=$rc"; fi

# C3: completion lists the flags so the shell can offer them.
out=$(_run "$d" --complete-bash)
if [[ $out == *"--status"* && $out == *"--resume"* && $out == *"--yes"* ]]; then _ok C3_complete; else _fail C3_complete "$out"; fi

# C4: --help-summary is a single line for the umbrella `shedman` help.
out=$(_run "$d" --help-summary); rc=$?
if [[ $rc -eq 0 && $out == *encrypt* ]]; then _ok C4_summary; else _fail C4_summary "rc=$rc $out"; fi

# P1: the root device is read from findmnt SOURCE.
d=$(_mk_sandbox)
out=$(STUB_ROOTDEV=/dev/nvme0n1p2 _srun "$d" '_preflight_root_device')
if [[ $out == /dev/nvme0n1p2 ]]; then _ok P1_rootdev; else _fail P1_rootdev "$out"; fi

# P2: a plain btrfs root that is NOT LUKS passes (rc 0) and runs `isLuks <dev>`.
d=$(_mk_sandbox)
STUB_FSTYPE=btrfs STUB_ISLUKS=1 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2'; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'isLuks /dev/sda2' "$d/cryptsetup.log" 2>/dev/null; then _ok P2_btrfs_plain; else _fail P2_btrfs_plain "rc=$rc $(cat "$d/cryptsetup.log" 2>/dev/null)"; fi

# P3: an already-LUKS root is refused (rc 1, names the device).
d=$(_mk_sandbox)
out=$(STUB_FSTYPE=btrfs STUB_ISLUKS=0 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *"already encrypted"* ]]; then _ok P3_already_luks; else _fail P3_already_luks "rc=$rc $out"; fi

# P4: a non-btrfs root (ext4) is refused cleanly — out of scope by design.
d=$(_mk_sandbox)
out=$(STUB_FSTYPE=ext4 STUB_ISLUKS=1 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *btrfs* ]]; then _ok P4_non_btrfs; else _fail P4_non_btrfs "rc=$rc $out"; fi

# PW1: on AC (Mains online=1) the gate passes.
d=$(_mk_sandbox); _seed_power "$d" Mains 1
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW1_ac_ok; else _fail PW1_ac_ok "rc=$rc"; fi

# PW2: on battery above 50% the gate passes.
d=$(_mk_sandbox); _seed_power "$d" Battery 73
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW2_batt_high_ok; else _fail PW2_batt_high_ok "rc=$rc"; fi

# PW3: on battery at 30% with no AC the gate refuses (rc 1).
d=$(_mk_sandbox); _seed_power "$d" Battery 30
out=$(SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *power* ]]; then _ok PW3_batt_low_refused; else _fail PW3_batt_low_refused "rc=$rc $out"; fi

# PW4: the override flag bypasses the gate even at 30%.
d=$(_mk_sandbox); _seed_power "$d" Battery 30
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" 'FORCE_NO_AC=1 _preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW4_override; else _fail PW4_override "rc=$rc"; fi

# SP1: 100 GiB free easily covers the 32M tail, root-only.
d=$(_mk_sandbox)
STUB_AVAIL=107374182400 _srun "$d" '_preflight_space_ok no'; rc=$?
if [[ $rc -eq 0 ]]; then _ok SP1_root_ok; else _fail SP1_root_ok "rc=$rc"; fi

# SP2: only 8 MiB free can't fit the 32M tail — refuse, root-only.
d=$(_mk_sandbox)
out=$(STUB_AVAIL=8388608 _srun "$d" '_preflight_space_ok no' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *space* ]]; then _ok SP2_root_tight; else _fail SP2_root_tight "rc=$rc $out"; fi

# SP3: with swap in scope the requirement is RAM-size + 32M; 4 GiB RAM + 33 MiB free fails.
d=$(_mk_sandbox); printf 'MemTotal:        4194304 kB\n' > "$d/meminfo"
out=$(STUB_AVAIL=34603008 SHEDMAN_ENCRYPT_MEMINFO="$d/meminfo" _srun "$d" '_preflight_space_ok yes' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *swap* ]]; then _ok SP3_swap_tight; else _fail SP3_swap_tight "rc=$rc $out"; fi

# SP4: with swap in scope and RAM-size + 32M + headroom free, it passes.
d=$(_mk_sandbox); printf 'MemTotal:        4194304 kB\n' > "$d/meminfo"
STUB_AVAIL=8589934592 SHEDMAN_ENCRYPT_MEMINFO="$d/meminfo" _srun "$d" '_preflight_space_ok yes'; rc=$?
if [[ $rc -eq 0 ]]; then _ok SP4_swap_ok; else _fail SP4_swap_ok "rc=$rc"; fi

# DL1: typing the exact acknowledgement phrase passes (rc 0).
d=$(_mk_sandbox)
printf 'encrypt this disk\n' | _srun "$d" '_dataloss_ack'; rc=$?
if [[ $rc -eq 0 ]]; then _ok DL1_exact; else _fail DL1_exact "rc=$rc"; fi

# DL2: a wrong phrase (a bare "yes") is refused (rc 1).
d=$(_mk_sandbox)
out=$(printf 'yes\n' | _srun "$d" '_dataloss_ack' 2>&1); rc=$?
if [[ $rc -eq 1 ]]; then _ok DL2_wrong_refused; else _fail DL2_wrong_refused "rc=$rc $out"; fi

# DL3: --yes (ASSUME_YES) bypasses the prompt for an unattended run.
d=$(_mk_sandbox)
_srun "$d" 'ASSUME_YES=1 _dataloss_ack' </dev/null; rc=$?
if [[ $rc -eq 0 ]]; then _ok DL3_assume_yes; else _fail DL3_assume_yes "rc=$rc"; fi

# DL4: the prompt shown to a human spells out that there is no backup.
d=$(_mk_sandbox)
out=$(printf 'encrypt this disk\n' | _srun "$d" '_dataloss_ack' 2>&1)
if [[ $out == *"no backup"* || $out == *"cannot be undone"* ]]; then _ok DL4_warns; else _fail DL4_warns "$out"; fi

# S1: the captured passphrase never reaches a tool's argv. Read a secret, run a
# tool, then scan every stub log for it.
d=$(_mk_sandbox)
# shellcheck disable=SC2016  # the call string is evaluated inside bash -c, not here
printf 'hunter2-secret\n' | _srun "$d" 'pw=$(_read_secret "p: "); cryptsetup isLuks /dev/sda2 >/dev/null 2>&1 || true'
if grep -q 'hunter2-secret' "$d"/*.log 2>/dev/null; then _fail S1_no_secret_argv "secret on argv"; else _ok S1_no_secret_argv; fi

# U1-U2: the reencrypt one-shot is an initrd-only oneshot ordered before
# sysroot.mount and pulled in by initrd-root-fs.target — and must NOT order after
# cryptsetup.target (it decides the device's fate) or mount the live root.
unit=$repo_root/packaging/shedos-system/tree/usr/lib/systemd/system/shedos-reencrypt.service
if [[ -f $unit ]] \
   && grep -q '^DefaultDependencies=no$'                        "$unit" \
   && grep -q '^ConditionPathExists=/etc/initrd-release$'       "$unit" \
   && grep -q '^Before=sysroot.mount$'                          "$unit" \
   && grep -q '^WantedBy=initrd-root-fs.target$'                "$unit" \
   && grep -q '^Type=oneshot$'                                  "$unit" \
   && grep -q '^ExecStart=/usr/lib/shedos/reencrypt-driver.sh$' "$unit"; then
    _ok U1_unit_shape
else
    _fail U1_unit_shape "$(cat "$unit" 2>/dev/null)"
fi
# Only an ordering/dependency directive counts — the comment may name the target.
if grep -qiE '^(after|wants|requires|bindsto)=.*cryptsetup' "$unit" 2>/dev/null; then _fail U2_no_cryptsetup_target "orders after cryptsetup.target"; else _ok U2_no_cryptsetup_target; fi

# H1-H2: the install hook stages the offline-reencrypt toolchain and symlinks the
# unit into initrd-root-fs.target.wants (a unit not symlinked there never starts).
hook=$repo_root/packaging/shedos-system/tree/usr/lib/initcpio/install/shedos-reencrypt
_h() { grep -q "$1" "$hook" 2>/dev/null; }
if [[ -f $hook ]] \
   && _h "add_binary /usr/bin/cryptsetup" \
   && _h "add_binary /usr/bin/btrfs" \
   && _h "add_binary /usr/bin/bash" \
   && _h "add_module 'dm-crypt'" \
   && _h "add_all_modules '/crypto/'" \
   && _h "add_binary '/usr/lib/libgcc_s.so.1'" \
   && _h "add_file /usr/lib/shedos/esp-state.sh" \
   && _h "add_file /usr/lib/shedos/reencrypt-driver.sh" \
   && _h "add_systemd_unit shedos-reencrypt.service"; then
    _ok H1_hook_stages
else
    _fail H1_hook_stages "$(cat "$hook" 2>/dev/null)"
fi
if _h 'initrd-root-fs.target.wants/shedos-reencrypt.service'; then _ok H2_hook_enables; else _fail H2_hook_enables "$(grep -n target.wants "$hook" 2>/dev/null)"; fi

# DS1-DS5: _detect_state branches read-only on isLuks + the ESP phase.
driver=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/reencrypt-driver.sh
_ds() {  # $1=isluks-exit(1=plaintext,0=luks) $2=phase
    local dd; dd=$(_mk_sandbox); mkdir -p "$dd/esp/shedos-encrypt"
    [[ -n $2 ]] && printf 'phase=%s\n' "$2" > "$dd/esp/shedos-encrypt/state"
    PATH="$dd/bin:$PATH" STUB_ISLUKS="$1" \
    ESP_STATE_FILE="$dd/esp/shedos-encrypt/state" SHEDOS_REENCRYPT_DEV=/dev/fake-root \
        bash -c "source '$driver'; _detect_state"
}
got=$(_ds 1 armed);        if [[ $got == fresh-encrypt ]];         then _ok DS1_fresh;            else _fail DS1_fresh "$got"; fi
got=$(_ds 0 encrypting);   if [[ $got == resume ]];                then _ok DS2_resume;           else _fail DS2_resume "$got"; fi
got=$(_ds 1 '');           if [[ $got == plaintext-passthrough ]]; then _ok DS3_passthrough;      else _fail DS3_passthrough "$got"; fi
got=$(_ds 0 '');           if [[ $got == plaintext-passthrough ]]; then _ok DS4_done_passthrough; else _fail DS4_done_passthrough "$got"; fi
got=$(_ds 0 flip-pending); if [[ $got == resume ]];                then _ok DS5_flip_resume;      else _fail DS5_flip_resume "$got"; fi

# P1: the unit + hook + driver are actually installed by package() — a staged
# file PKGBUILD never installs ships nothing (the _libexec_shedman class of bug).
pkgbuild=$repo_root/packaging/shedos-system/PKGBUILD
if grep -q 'tree/usr/lib/systemd/system/shedos-reencrypt.service' "$pkgbuild" \
   && grep -q 'tree/usr/lib/initcpio/install/shedos-reencrypt' "$pkgbuild" \
   && grep -q 'tree/usr/lib/shedos/reencrypt-driver.sh' "$pkgbuild"; then
    _ok P1_pkgbuild_installs
else
    _fail P1_pkgbuild_installs "missing install line"
fi

# A shrinking btrfs stub: first `filesystem usage` reports the pre size, the next
# reports pre-32M, so the post-resize verify (device got smaller) passes.
_btrfs_shrink_stub() {  # $1=dir
    cat > "$1/bin/btrfs" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/btrfs.log"
if [[ \$1 == filesystem && \$2 == usage ]]; then
    n=\$(grep -c 'filesystem usage' "$1/btrfs.log")
    if [[ \$n -le 1 ]]; then echo "Device size:                10737418240"; else echo "Device size:                10703863808"; fi
fi
exit 0
EOF
    chmod +x "$1/bin/btrfs"
}

# S1-S2: _do_shrink resizes by exactly the tail and hard-fails if the device did
# not actually shrink (corruption guard before any header is written).
d=$(_mk_sandbox); _btrfs_shrink_stub "$d"
PATH="$d/bin:$PATH" SHEDOS_REENCRYPT_SCRATCH="$d/mnt" bash -c "source '$driver'; _do_shrink /dev/loopX" >/dev/null 2>&1
if grep -q 'filesystem resize 1:-32M' "$d/btrfs.log" 2>/dev/null; then _ok S1_resize_32M; else _fail S1_resize_32M "$(cat "$d/btrfs.log" 2>/dev/null)"; fi

# the default _mk_sandbox btrfs stub never shrinks → the guard must fire.
d=$(_mk_sandbox)
out=$(PATH="$d/bin:$PATH" SHEDOS_REENCRYPT_SCRATCH="$d/mnt" bash -c "source '$driver'; _do_shrink /dev/loopX" 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"did not shrink"* ]]; then _ok S2_verify_guard; else _fail S2_verify_guard "rc=$rc out=$out"; fi

# RE1-RE5: header-init -> test-open -> encrypt order (verify-before-encrypt), the
# key off argv, the pinned flags, the transient header backup, and the strand
# guard (never encrypt a keyslot that will not open).
d=$(_mk_sandbox); kf="$d/newkey"; printf 'diskpass' > "$kf"; chmod 600 "$kf"
PATH="$d/bin:$PATH" STUB_OPEN_RC=0 SHEDOS_REENCRYPT_ESP="$d/esp" bash -c "source '$driver'; _do_root_reencrypt /dev/loopXp1 '$kf'" >/dev/null 2>&1
init=$(grep -n 'reencrypt --encrypt' "$d/cryptsetup.log" | head -1 | cut -d: -f1)
topen=$(grep -n 'open --test-passphrase' "$d/cryptsetup.log" | head -1 | cut -d: -f1)
resume=$(grep -n 'reencrypt --resume-only' "$d/cryptsetup.log" | head -1 | cut -d: -f1)
if [[ -n $init && -n $topen && -n $resume && $init -lt $topen && $topen -lt $resume ]]; then _ok RE1_verify_before_encrypt; else _fail RE1_verify_before_encrypt "init=$init topen=$topen resume=$resume"; fi
if grep -q -- '--key-file=' "$d/cryptsetup.log" 2>/dev/null && ! grep -q 'diskpass' "$d/cryptsetup.log" 2>/dev/null; then _ok RE2_key_off_argv; else _fail RE2_key_off_argv "$(cat "$d/cryptsetup.log" 2>/dev/null)"; fi
if grep -qE 'reencrypt --encrypt --type luks2 --reduce-device-size 32M --force-offline-reencrypt' "$d/cryptsetup.log" 2>/dev/null; then _ok RE3_pinned_flags; else _fail RE3_pinned_flags "$(grep 'reencrypt --encrypt' "$d/cryptsetup.log" 2>/dev/null)"; fi
if grep -qE "luksHeaderBackup .*--header-backup-file $d/esp/header-.*\.img" "$d/cryptsetup.log" 2>/dev/null; then _ok RE4_header_backup; else _fail RE4_header_backup "$(grep luksHeaderBackup "$d/cryptsetup.log" 2>/dev/null)"; fi

d=$(_mk_sandbox); kf="$d/newkey"; printf 'diskpass' > "$kf"; chmod 600 "$kf"
out=$(PATH="$d/bin:$PATH" STUB_OPEN_RC=1 SHEDOS_REENCRYPT_ESP="$d/esp" bash -c "source '$driver'; _do_root_reencrypt /dev/loopXp1 '$kf'" 2>&1); rc=$?
if [[ $rc -ne 0 && $out == *"keyslot did not open"* ]] && ! grep -q 'reencrypt --resume-only' "$d/cryptsetup.log" 2>/dev/null; then _ok RE5_strand_guard; else _fail RE5_strand_guard "rc=$rc out=$out"; fi

# GB1-GB2: _do_growback grows the mapper back to max, idempotently.
d=$(_mk_sandbox)
PATH="$d/bin:$PATH" SHEDOS_REENCRYPT_SCRATCH="$d/mnt" bash -c "source '$driver'; _do_growback /dev/mapper/luks-test" >/dev/null 2>&1
if grep -q 'filesystem resize 1:max' "$d/btrfs.log" 2>/dev/null; then _ok GB1_resize_max; else _fail GB1_resize_max "$(cat "$d/btrfs.log" 2>/dev/null)"; fi
PATH="$d/bin:$PATH" SHEDOS_REENCRYPT_SCRATCH="$d/mnt" bash -c "source '$driver'; _do_growback /dev/mapper/luks-test" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then _ok GB2_idempotent; else _fail GB2_idempotent "rc=$rc"; fi

# MAIN1: on a fresh-encrypt box, main threads the device through the whole chain
# — shrink, reencrypt, open the mapper, grow back.
d=$(_mk_sandbox); _btrfs_shrink_stub "$d"; mkdir -p "$d/esp"
printf 'phase=armed\n' > "$d/esp/state"; printf 'e2e' > "$d/esp/key"
PATH="$d/bin:$PATH" STUB_ISLUKS=1 ESP_STATE_FILE="$d/esp/state" SHEDOS_REENCRYPT_DEV=/dev/fake-root \
  SHEDOS_REENCRYPT_SCRATCH="$d/mnt" SHEDOS_REENCRYPT_ESP="$d/esp" SHEDOS_REENCRYPT_KEYFILE="$d/esp/key" \
  bash -c "source '$driver'; main" >/dev/null 2>&1
if grep -q 'reencrypt --encrypt' "$d/cryptsetup.log" 2>/dev/null \
   && grep -q 'filesystem resize 1:-32M' "$d/btrfs.log" 2>/dev/null \
   && grep -q 'filesystem resize 1:max' "$d/btrfs.log" 2>/dev/null; then
    _ok MAIN1_fresh_chain
else
    _fail MAIN1_fresh_chain "cs=[$(cat "$d/cryptsetup.log" 2>/dev/null)] bt=[$(cat "$d/btrfs.log" 2>/dev/null)]"
fi

# Swap-carve stubs (sgdisk -p/--backup, mkswap, blockdev; cryptsetup/btrfs from
# _mk_sandbox). The geometry math is proven by the loop e2e, not the stubs.
_swap_stubs() {  # $1=dir
    cat > "$1/bin/sgdisk" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/sgdisk.log"
[[ "\$*" == *--backup=* ]] && { bk=\$(printf '%s' "\$*" | sed -n 's/.*--backup=\([^ ]*\).*/\1/p'); : > "\$bk"; }
exit 0
EOF
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/mkswap.log"\nexit 0\n' "$1" > "$1/bin/mkswap"
    cp "$1/bin/mkswap" "$1/bin/blockdev"
    chmod +x "$1/bin/sgdisk" "$1/bin/mkswap" "$1/bin/blockdev"
}

# SC1-SC4: GPT backed up before the table edit, swap is a fresh luksFormat (never
# reencrypt), mkswap runs with no secret on argv, and the mapper is appended to
# the container list for enrolment.
d=$(_mk_sandbox); _swap_stubs "$d"
printf 'diskpass' > "$d/kf"; chmod 600 "$d/kf"; : > "$d/containers"; printf 'MemTotal: 262144 kB\n' > "$d/meminfo"
PATH="$d/bin:$PATH" SHEDOS_REENCRYPT_SETTLE=0 SHEDOS_REENCRYPT_ESP="$d/esp" SHEDOS_REENCRYPT_CONTAINERS="$d/containers" SHEDOS_REENCRYPT_MEMINFO="$d/meminfo" \
  bash -c "source '$driver'; _do_swap_carve /dev/sda 2 '$d/kf'" >/dev/null 2>&1
if grep -q -- '--backup=' "$d/sgdisk.log" 2>/dev/null && [[ -e $d/esp/gpt-sda.bak ]]; then _ok SC1_gpt_backup; else _fail SC1_gpt_backup "$(cat "$d/sgdisk.log" 2>/dev/null)"; fi
if grep -q 'luksFormat' "$d/cryptsetup.log" 2>/dev/null && ! grep -q 'reencrypt' "$d/cryptsetup.log" 2>/dev/null; then _ok SC2_fresh_format; else _fail SC2_fresh_format "$(cat "$d/cryptsetup.log" 2>/dev/null)"; fi
if grep -q '/dev/mapper/luks-swap' "$d/mkswap.log" 2>/dev/null && ! grep -q diskpass "$d/cryptsetup.log" "$d/sgdisk.log" 2>/dev/null; then _ok SC3_mkswap_no_secret; else _fail SC3_mkswap_no_secret "$(cat "$d/cryptsetup.log" "$d/sgdisk.log" 2>/dev/null)"; fi
if grep -q 'luks-swap' "$d/containers" 2>/dev/null; then _ok SC4_container_appended; else _fail SC4_container_appended "$(cat "$d/containers" 2>/dev/null)"; fi

# MAIN2: with swap=yes in the ESP state, main carves swap after the reencrypt.
d=$(_mk_sandbox); _btrfs_shrink_stub "$d"; _swap_stubs "$d"; mkdir -p "$d/esp"
{ printf 'phase=armed\n'; printf 'swap=yes\n'; printf 'disk=/dev/sda\n'; printf 'rootpn=2\n'; } > "$d/esp/state"
printf 'e2e' > "$d/esp/key"; : > "$d/containers"; printf 'MemTotal: 262144 kB\n' > "$d/meminfo"
PATH="$d/bin:$PATH" STUB_ISLUKS=1 SHEDOS_REENCRYPT_SETTLE=0 ESP_STATE_FILE="$d/esp/state" SHEDOS_REENCRYPT_DEV=/dev/sda2 \
  SHEDOS_REENCRYPT_SCRATCH="$d/mnt" SHEDOS_REENCRYPT_ESP="$d/esp" SHEDOS_REENCRYPT_KEYFILE="$d/esp/key" \
  SHEDOS_REENCRYPT_CONTAINERS="$d/containers" SHEDOS_REENCRYPT_MEMINFO="$d/meminfo" \
  bash -c "source '$driver'; main" >/dev/null 2>&1
if grep -q 'luksFormat' "$d/cryptsetup.log" 2>/dev/null && grep -q 'luks-swap' "$d/containers" 2>/dev/null; then _ok MAIN2_swap_carved; else _fail MAIN2_swap_carved "cs=[$(cat "$d/cryptsetup.log" 2>/dev/null)] cont=[$(cat "$d/containers" 2>/dev/null)]"; fi

# esp-state.sh: pure-unit round-trip + parse-safety (no cryptsetup stubs).
esp_rc=0; bash "$here/esp-state.sh" || esp_rc=1

total=$((pass + fail)); echo; echo "encrypt: $pass/$total passed"
(( fail == 0 && esp_rc == 0 ))
