#!/bin/bash
# Wipe each VT's kernel text buffer so fbcon paints empty/black during
# DRM-master gaps at compositor handoffs (Plymouth -> cage, cage ->
# Hyprland, Hyprland -> Plymouth-shutdown).
#
# Mechanism: write the "Reset Terminal" escape (ESC c) to each
# /dev/ttyN. The kernel's vt driver interprets it and clears the
# internal text buffer that /dev/vcsN reflects and that fbcon
# paints when DRM master is released.
#
# Per `man vcs`, /dev/vcsN is essentially a read-only mirror —
# writes to it don't clear the buffer. The writable interface is
# /dev/ttyN, and ESC c is the canonical "reset and clear" sequence.
#
# Defense-in-depth: shedos already silences every text source we've
# identified (greetd cage stdio -> journal, locale.conf encoding
# fix, ShowStatus=no, user-services stderr -> journal, masked
# getty@tty1). This script wipes any residue regardless of source,
# so a future regression doesn't reintroduce the visible flash.
set -u
for n in 1 2 3 4 5 6; do
    [[ -w "/dev/tty$n" ]] || continue
    printf '\033c' > "/dev/tty$n" 2>/dev/null || true
done
