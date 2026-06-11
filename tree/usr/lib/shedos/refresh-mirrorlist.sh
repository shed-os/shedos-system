#!/bin/bash
# Refresh /etc/pacman.d/mirrorlist via reflector.
#
# Single source of truth for ShedOS's reflector flag set. Three
# callers exec this script:
#
#   /etc/systemd/system/shedos-mirrorlist.service
#       live ISO only; one-shot refresh at boot of the live
#       environment. Shipped from archiso/airootfs/.
#
#   /usr/lib/systemd/system/shedos-reflector.service
#       installed system; fired periodically by
#       shedos-reflector.timer. Shipped by shedos-system.
#
#   installer/calamares/modules-src/shedos_mirrors/main.py
#       Calamares module; runs once during install.
#
# Tune the flags here and every caller picks them up on the next
# run. Failure is non-fatal upstream; this script just exec's
# reflector and inherits its exit code.
#
# Optional $1 overrides the output path. `shedman update` uses it to
# rank into a user-owned temp file in the background (no root needed)
# and atomically install the result after the user consents to the
# upgrade — reflector's per-mirror timeout warnings are normal probing
# chatter, but on the update screen they read like an error storm.

exec /usr/bin/reflector \
    --save "${1:-/etc/pacman.d/mirrorlist}" \
    --sort rate \
    --latest 20 \
    --protocol https \
    --age 12 \
    --threads 5
