#!/usr/bin/env bash
# Guard the first-boot finalize (encrypt-finalize.sh): on phase=encrypting it waits
# for the recovery-key enrol, runs the boot reconfigure, and advances to
# flip-pending; on phase=flip-pending it only reports; on any other phase it is a
# no-op. The reconfigure step is stubbed; the phase transitions run for real against
# an ESP state file. The flip commit itself is the QEMU-validated finaliser, not here.

set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
fin=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/encrypt-finalize.sh

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A sandbox with an ESP state file and a reconfigure stub that records its call and
# fails only when a recon-fail marker is present (no env-propagation games).
_mk() {
    local d; d=$(mktemp -d); mkdir -p "$d/esp"
    cat > "$d/reconfigure" <<EOF
#!/usr/bin/env bash
touch "$d/reconfigure-called"
[[ -e "$d/recon-fail" ]] && exit 1
exit 0
EOF
    chmod +x "$d/reconfigure"
    printf '%s\n' "$d"
}
_run() {  # $1=dir
    ESP_STATE_FILE="$1/esp/state" SHEDOS_ENCRYPT_RECONFIGURE="$1/reconfigure" \
        bash -c "source '$fin'; main" >/dev/null 2>&1
}

# F1: phase=encrypting, enrol done (no enroll_containers) -> reconfigure + flip-pending.
d=$(_mk); printf 'phase=encrypting\n' > "$d/esp/state"
_run "$d"
if [[ -e $d/reconfigure-called ]] && grep -qx 'phase=flip-pending' "$d/esp/state"; then _ok F1_reconfigure_and_advance; else _fail F1_reconfigure_and_advance "called=$([[ -e $d/reconfigure-called ]] && echo y || echo n) state=[$(cat "$d/esp/state")]"; fi

# F2: phase=encrypting but enrol not finished (enroll_containers set) -> waits.
d=$(_mk); { printf 'phase=encrypting\n'; printf 'enroll_containers=/dev/disk/by-uuid/x\n'; } > "$d/esp/state"
_run "$d"
if [[ ! -e $d/reconfigure-called ]] && grep -qx 'phase=encrypting' "$d/esp/state"; then _ok F2_waits_for_enrol; else _fail F2_waits_for_enrol "called=$([[ -e $d/reconfigure-called ]] && echo y || echo n) state=[$(cat "$d/esp/state")]"; fi

# F3: phase=encrypting, reconfigure fails -> stays encrypting (retry next boot).
d=$(_mk); printf 'phase=encrypting\n' > "$d/esp/state"; touch "$d/recon-fail"
_run "$d"
if [[ -e $d/reconfigure-called ]] && grep -qx 'phase=encrypting' "$d/esp/state"; then _ok F3_reconfigure_fail_retries; else _fail F3_reconfigure_fail_retries "state=[$(cat "$d/esp/state")]"; fi

# F5: phase=armed (the driver has not run yet) -> no-op, no reconfigure.
d=$(_mk); printf 'phase=armed\n' > "$d/esp/state"
_run "$d"
if [[ ! -e $d/reconfigure-called ]]; then _ok F5_armed_noop; else _fail F5_armed_noop "reconfigure ran on armed"; fi

# --- flip commit (phase=flip-pending) -------------------------------------------
# A flip-pending sandbox primed to commit: no bridge marker (sd-encrypt proven), enrol
# done, root is a LUKS mapper, the container carries a recovery token. Stubs: findmnt
# (root source), cryptsetup (luksDump token), the three rebuild writers. The caller
# tweaks one precondition per test.
_mk_flip() {
    local d; d=$(mktemp -d); mkdir -p "$d/esp" "$d/run" "$d/bin"
    printf 'phase=flip-pending\n' > "$d/esp/state"
    printf 'diskpass' > "$d/esp/key"
    printf '/dev/disk/by-uuid/RUUID\n' > "$d/containers"
    printf 'HOOKS=(base systemd autodetect block plymouth shedos-reencrypt sd-encrypt shedos-recovery filesystems)\n' > "$d/mkinitcpio.conf"
    : > "$d/esp/header-RUUID.img"; : > "$d/esp/gpt-vda.bak"
    cat > "$d/bin/findmnt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${STUB_ROOTSRC:-/dev/mapper/luks-RUUID[/@]}"
EOF
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
[[ \$1 == luksDump ]] && { [[ -z \${STUB_NO_TOKEN:-} ]] && printf '"type": "shedos-recovery"\n'; exit 0; }
exit 0
EOF
    local t
    for t in rebuild-initramfs.sh build-uki.sh render-limine-config.sh; do
        cat > "$d/bin/$t" <<EOF
#!/usr/bin/env bash
echo "$t \$*" >> "$d/rebuild.log"
[[ -e "$d/rebuild-fail" ]] && exit 1
exit 0
EOF
    done
    chmod +x "$d/bin/"*
    printf '%s\n' "$d"
}
_run_flip() {  # $1=dir ; extra env via the caller's prefix
    PATH="$1/bin:$PATH" SHEDOS_FIRMWARE=uefi SHEDOS_REENCRYPT_RUN="$1/run" \
    ESP_STATE_FILE="$1/esp/state" SHEDOS_REENCRYPT_ESP="$1/esp" SHEDOS_REENCRYPT_KEYFILE="$1/esp/key" \
    SHEDOS_MKINITCPIO_CONF="$1/mkinitcpio.conf" SHEDOS_REENCRYPT_BINDIR="$1/bin" \
    SHEDMAN_KEY_CONTAINERS="$1/containers" \
        bash -c "source '$fin'; main" >/dev/null 2>&1
}

# FC1: a bridge marker means the driver opened the root, not sd-encrypt -> do NOT commit.
d=$(_mk_flip); : > "$d/run/bridged"
_run_flip "$d"
if [[ ! -s $d/rebuild.log && -e $d/esp/key ]] && grep -qx 'phase=flip-pending' "$d/esp/state"; then _ok FC1_marker_no_commit; else _fail FC1_marker_no_commit "rebuild=[$(cat "$d/rebuild.log" 2>/dev/null)] key=$([[ -e $d/esp/key ]] && echo y) state=[$(cat "$d/esp/state")]"; fi

# FC2: no marker but enrol not finished -> do NOT commit.
d=$(_mk_flip); { printf 'phase=flip-pending\n'; printf 'enroll_containers=/dev/disk/by-uuid/RUUID\n'; } > "$d/esp/state"
_run_flip "$d"
if [[ ! -s $d/rebuild.log && -e $d/esp/key ]]; then _ok FC2_enrol_pending_no_commit; else _fail FC2_enrol_pending_no_commit "rebuild=[$(cat "$d/rebuild.log" 2>/dev/null)]"; fi

# FC3: no marker + enrol done + root is the LUKS mapper + recovery token -> COMMIT:
# hook unstaged, boot rebuilt, keyfile + backups shredded, state cleared.
d=$(_mk_flip)
_run_flip "$d"
if [[ -s $d/rebuild.log && ! -e $d/esp/key && ! -e $d/esp/state && ! -e $d/esp/header-RUUID.img ]] \
   && ! grep -q 'shedos-reencrypt' "$d/mkinitcpio.conf"; then _ok FC3_commit; else _fail FC3_commit "rebuild=[$(cat "$d/rebuild.log" 2>/dev/null)] key=$([[ -e $d/esp/key ]] && echo y) state=$([[ -e $d/esp/state ]] && echo y) hooks=[$(grep ^HOOKS "$d/mkinitcpio.conf")]"; fi

# FC4: root is NOT a LUKS mapper -> refuse (affirmative recheck), nothing shredded.
d=$(_mk_flip)
STUB_ROOTSRC='/dev/vda2[/@]' _run_flip "$d"
if [[ ! -s $d/rebuild.log && -e $d/esp/key ]] && grep -q 'shedos-reencrypt' "$d/mkinitcpio.conf"; then _ok FC4_non_luks_root_refused; else _fail FC4_non_luks_root_refused "rebuild=[$(cat "$d/rebuild.log" 2>/dev/null)] key=$([[ -e $d/esp/key ]] && echo y)"; fi

# FC5: no recovery keyslot on the container -> refuse, nothing shredded.
d=$(_mk_flip)
STUB_NO_TOKEN=1 _run_flip "$d"
if [[ ! -s $d/rebuild.log && -e $d/esp/key ]] && grep -q 'shedos-reencrypt' "$d/mkinitcpio.conf"; then _ok FC5_no_recovery_token_refused; else _fail FC5_no_recovery_token_refused "rebuild=[$(cat "$d/rebuild.log" 2>/dev/null)] key=$([[ -e $d/esp/key ]] && echo y)"; fi

# FC6: rebuild fails -> revert (hook re-staged), keyfile intact, state NOT cleared.
d=$(_mk_flip); touch "$d/rebuild-fail"
_run_flip "$d"
if [[ -e $d/esp/key && -e $d/esp/state ]] && grep -q 'shedos-reencrypt' "$d/mkinitcpio.conf"; then _ok FC6_rebuild_fail_reverts; else _fail FC6_rebuild_fail_reverts "key=$([[ -e $d/esp/key ]] && echo y) state=$([[ -e $d/esp/state ]] && echo y) hooks=[$(grep ^HOOKS "$d/mkinitcpio.conf")]"; fi

printf 'encrypt-finalize: %d/%d passed\n' "$pass" "$((pass + fail))"
(( fail == 0 )) || { printf 'failed: %s\n' "${failures[*]}" >&2; exit 1; }
