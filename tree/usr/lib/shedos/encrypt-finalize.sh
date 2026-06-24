#!/usr/bin/env bash
# First-boot finalisation for in-place disk encryption. The reencrypt driver moved
# the bytes headless and recorded the containers; the enrol service added the paper
# recovery key. This runs on the booted system, after enrol, to build the normal
# sd-encrypt boot path (via encrypt-reconfigure.sh) and advance the conversion to
# flip-pending, where the driver bridges every boot until sd-encrypt is proven to
# unlock unaided. It self-gates to a no-op on any box that never ran `shedman
# encrypt`, and is idempotent: a box already past a step just reports its state.
#
# Brick-safe by construction: it only stages the encrypted boot path and advances
# the phase. The verify-before-commit flip — shredding the keyfile and dropping the
# driver bridge — is the QEMU-validated finaliser and does not run here yet.

set -uo pipefail

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/esp-state.sh"

PROG=shedos-encrypt-finalize
RECONFIGURE=${SHEDOS_ENCRYPT_RECONFIGURE:-/usr/lib/shedos/encrypt-reconfigure.sh}

log() { echo "$PROG: $1" >&2; }

main() {
    local phase; phase=$(esp_state_get phase 2>/dev/null) || return 0
    case $phase in
        encrypting)
            # The byte-move is done and the box booted via the driver bridge. Build
            # the sd-encrypt boot path — but only once the recovery-key enrol has
            # finished: it writes the container list reconfigure reads and clears
            # enroll_containers when every container carries the key. Reconfigure is
            # idempotent, so a retry after a transient failure re-derives the same path.
            local pending; pending=$(esp_state_get enroll_containers 2>/dev/null)
            if [[ -n $pending ]]; then
                log "waiting for the recovery-key enrol to finish before reconfiguring the boot"
                return 0
            fi
            if ! "$RECONFIGURE"; then
                log "boot reconfigure failed — retrying on the next boot"
                return 0
            fi
            esp_state_write "phase=flip-pending"
            log "encrypted boot path staged — reboot to switch onto it"
            ;;
        flip-pending)
            # The box now boots on the sd-encrypt cmdline, bridged by the driver until
            # sd-encrypt is proven to unlock unaided. The flip commit lands with the
            # QEMU-validated finaliser; until then the driver keeps the box safe.
            log "encryption complete — verifying the sd-encrypt boot path before finalising"
            ;;
        *)
            return 0
            ;;
    esac
}

# Run only when executed; sourced (the unit tests) just defines the functions.
[[ ${BASH_SOURCE[0]} == "${0}" ]] && main
