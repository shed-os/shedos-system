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

exec /usr/bin/reflector \
    --save /etc/pacman.d/mirrorlist \
    --sort rate \
    --latest 20 \
    --protocol https \
    --age 12 \
    --threads 5
