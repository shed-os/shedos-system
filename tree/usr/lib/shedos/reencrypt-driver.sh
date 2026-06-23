#!/bin/bash
# In-place reencryption driver. Runs as the shedos-reencrypt.service ExecStart in
# the transient reencrypt initramfs, before sysroot is mounted. On every boot it
# decides — read-only — whether this is an ordinary plaintext box (no-op), a
# fresh encrypt the arm step set up, or an interrupted run to resume, then drives
# the offline conversion. The _do_* steps land in later tasks.

set -u

# Source the sibling esp-state lib. Same directory in the package tree and on an
# installed box (/usr/lib/shedos), so resolve it relative to this file.
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/esp-state.sh"

# Placeholder conversion steps — implemented in later tasks against a real
# LUKS2/btrfs loop image. Defined before main so it resolves.
_do_shrink()           { return 0; }
_do_root_reencrypt()   { return 0; }
_do_swap_carve()       { return 0; }
_do_growback()         { return 0; }
_do_enroll()           { return 0; }
_do_reconfigure_boot() { return 0; }

# The root partition to convert. The arm step pins it into the ESP state
# (containers=, root first, space-separated); the override is for the tests.
_reencrypt_dev() {
    if [[ -n ${SHEDOS_REENCRYPT_DEV:-} ]]; then
        printf '%s\n' "$SHEDOS_REENCRYPT_DEV"; return
    fi
    esp_state_get containers | awk '{print $1}'
}

# Decide what this boot does, read-only — no byte is touched here. Two facts:
# is the device already a LUKS2 container, and what orchestration phase does the
# ESP record. The matrix:
#
#   isLuks  phase            -> branch
#   no      armed            -> fresh-encrypt   (first reencrypt boot)
#   no      (none)           -> plaintext-passthrough (ordinary box / done)
#   yes     encrypting       -> resume          (power-cut mid-encrypt)
#   yes     flip-pending     -> resume          (encrypt done, flip not committed)
#   yes     (none)           -> plaintext-passthrough (already encrypted + cleared)
#
# The inner btrfs UUID survives in-place encryption, so even a stale cmdline
# token still opens the right container — this brancher, not the cmdline, is the
# source of truth during the window.
_detect_state() {
    local dev phase
    dev=$(_reencrypt_dev)
    phase=$(esp_state_get phase 2>/dev/null)

    if cryptsetup isLuks "$dev" 2>/dev/null; then
        case $phase in
            encrypting|flip-pending) echo resume ;;
            *)                       echo plaintext-passthrough ;;
        esac
    else
        case $phase in
            armed) echo fresh-encrypt ;;
            *)     echo plaintext-passthrough ;;
        esac
    fi
}

main() {
    local branch
    branch=$(_detect_state)
    case $branch in
        plaintext-passthrough)
            # Ordinary boot: hand the device back to the normal path. The unit
            # is a no-op; sysroot.mount proceeds.
            return 0 ;;
        fresh-encrypt)
            _do_shrink            || return 0
            _do_root_reencrypt    || return 0
            _do_swap_carve        || true
            _do_growback          || true
            _do_enroll            || true
            _do_reconfigure_boot  || true
            ;;
        resume)
            # Re-enter from wherever the cut landed; each _do_* is idempotent
            # and re-detects its own sub-state.
            _do_root_reencrypt    || return 0
            _do_swap_carve        || true
            _do_growback          || true
            _do_enroll            || true
            _do_reconfigure_boot  || true
            ;;
    esac
    return 0
}

# Run main only when executed as the unit's ExecStart, not when sourced by the
# tests (which call _detect_state directly).
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main
fi
