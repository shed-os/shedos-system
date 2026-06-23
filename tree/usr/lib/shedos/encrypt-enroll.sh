#!/usr/bin/env bash
# First-boot recovery-key enrolment for in-place disk encryption. The reencrypt
# driver runs headless before sysroot.mount, so it cannot mint a key the user has
# to write down and confirm. It hands the freshly-encrypted containers off in the
# ESP state (enroll_containers=, root first then swap, by-uuid); this runs on the
# booted system, writes the userspace container list, enrols the paper recovery
# key on every container, and stashes the key for the first-login display.
#
# One key for the whole machine, durable across retries: it is stashed before the
# first keyslot is touched and reused on a later boot, so a partial run never ends
# up showing a key that opens only some containers. Each spelling is added only if
# it is not already enrolled, and each new slot is tagged at once, so a failed add
# orphans nothing and a retry never duplicates a slot. Enrol failure is not fatal:
# the disk still unlocks with the passphrase and the next boot resumes on the same key.

set -uo pipefail

# Pull esp-state plus the shedman key enrolment library. Sourcing the verb hits
# its source-guard and returns early, defining _gen_recovery / _recovery_forms /
# _mk_keyfile / _tag_slot / _slots_with_token / _active_slots / _new_slot_after
# without dispatching.
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/esp-state.sh"
# shellcheck source=/dev/null
source "${SHEDMAN_KEY:-/usr/libexec/shedman/key}"

# Config after the sources so these win over anything the key verb set (it also
# defines PROG and CONTAINERS_FILE).
PROG=shedos-encrypt-enroll
ESP=${SHEDOS_REENCRYPT_ESP:-/boot/efi/shedos-encrypt}
AUTH_KEYFILE=${SHEDOS_REENCRYPT_KEYFILE:-$ESP/key}
CONTAINERS_FILE=${SHEDMAN_KEY_CONTAINERS:-/etc/shedos/secureboot/containers}
STASH=${SHEDOS_RECOVERY_STASH:-/var/lib/shedos/encrypt/recovery-key}

log() { echo "$PROG: $1" >&2; }

# The machine recovery key. Reusing the one a prior run stashed means a retry
# converges every container onto the SAME key the user is shown — never a split
# key. A fresh key is stashed up front, before any keyslot is touched, so an
# interrupted run is resumable. Echoes the key, or nothing (rc 0) when the machine
# is already fully enrolled and the key has been shown and the stash shredded. Rc 1
# is an unrecoverable split: some containers enrolled, the key gone — never silently
# strand the rest or mint a divergent second key.
_machine_key() {  # $1=container-list
    if [[ -s $STASH ]]; then printf '%s' "$(<"$STASH")"; return 0; fi
    local dev total=0 tagged=0
    for dev in $1; do
        total=$((total + 1))
        [[ -z $(_slots_with_token "$dev" shedos-recovery) ]] || tagged=$((tagged + 1))
    done
    if (( tagged == total )); then
        return 0   # every container already enrolled; key shown and stash shredded
    fi
    if (( tagged > 0 )); then
        log "containers are partially enrolled but the recovery key is gone — run: shedman key rotate-recovery"
        return 1
    fi
    local key; key=$(_gen_recovery)
    install -d -m700 -- "$(dirname -- "$STASH")"
    ( umask 077; printf '%s\n' "$key" > "$STASH" )
    printf '%s' "$key"
    return 0
}

main() {
    local list
    list=$(esp_state_get enroll_containers 2>/dev/null) || return 0
    [[ -n $list ]] || return 0

    # Record the userspace container list (root first, then swap) so the key/tpm2
    # verbs resolve the new containers — the format the installer writes. The
    # handoff is cleared once enrolment finishes, so this stops rewriting then.
    mkdir -p -- "$(dirname -- "$CONTAINERS_FILE")"
    # shellcheck disable=SC2086  # word-split each by-uuid path onto its own line
    printf '%s\n' $list > "$CONTAINERS_FILE"

    # luksAddKey needs an existing key to authorise the add; the reencrypt run left
    # the disk passphrase in a 0600 keyfile on the ESP, shredded only at the flip
    # commit. If it is gone, retry on a later boot rather than fail.
    if [[ ! -r $AUTH_KEYFILE ]]; then
        log "the authorising keyfile is not present yet — retrying enrolment next boot"
        return 0
    fi

    local minted rc
    minted=$(_machine_key "$list"); rc=$?
    (( rc == 0 )) || return 1                 # unrecoverable split — surfaced, not hidden
    if [[ -z $minted ]]; then                 # already enrolled and shown; freeze + done
        esp_state_write "enroll_containers="
        return 0
    fi

    local -a forms; mapfile -t forms < <(_recovery_forms "$minted")
    local dev f kf before s
    for dev in $list; do
        for f in "${forms[@]}"; do
            kf=$(_mk_keyfile "$f")   # 0600 tmpfile, no trailing newline
            # Skip a spelling already enrolled, so a retry never adds it twice.
            if cryptsetup open --test-passphrase --key-file="$kf" "$dev" 2>/dev/null; then
                rm -f -- "$kf"; continue
            fi
            before=$(_active_slots "$dev")
            if ! cryptsetup luksAddKey --key-file="$AUTH_KEYFILE" "$dev" "$kf" 2>/dev/null; then
                rm -f -- "$kf"
                log "could not add the recovery key to $dev — retrying enrolment next boot"
                return 1
            fi
            rm -f -- "$kf"
            # Tag this spelling's new slot at once. A failed add above creates no
            # slot to orphan; the only gap is a crash in the instant between this
            # add and its tag, which leaves one untagged-but-valid recovery slot —
            # harmless for unlocking, though a later rotate-recovery would not retire
            # that one spelling.
            s=$(_new_slot_after "$dev" "$before"); [[ -n $s ]] && _tag_slot "$dev" "$s" shedos-recovery
        done
        log "recovery key enrolled on $dev"
    done

    # Every container holds the key now. Freeze the handoff so later boots stop
    # rewriting the container list; the stash stays for the first-login display to
    # show once and shred.
    esp_state_write "enroll_containers="
    log "recovery key stashed for the first-login display"
    return 0
}

# Run only when executed; sourced (the unit tests) just defines the functions.
[[ ${BASH_SOURCE[0]} == "${0}" ]] && main
