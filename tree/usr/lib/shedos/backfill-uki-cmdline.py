#!/usr/bin/env python3
"""Seed /etc/kernel/cmdline from the live boot config for the UKI swap.

Fresh installs bake the cmdline into /etc/kernel/cmdline at install time, where
ukify reads it into the signed UKI. Machines installed before the UKI cutover
ship the placeholder cmdline and carry their real one only in limine.conf's
kernel_cmdline: line; this lifts it across the first time they pick up a _uki
mkinitcpio preset, so the next UKI build bakes the right cmdline in.

Idempotent: a real (non-placeholder) /etc/kernel/cmdline, no active _uki preset,
or no limine.conf cmdline are all clean no-ops, so installer writes and hand
edits are never clobbered.

Invoked by shedos-system.install on upgrade; safe to run by hand.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

BOOT = Path(os.environ.get("SHEDOS_UKI_BOOT_DIR", "/boot"))
ETC = Path(os.environ.get("SHEDOS_UKI_ETC_ROOT", "/etc"))
CMDLINE = ETC / "kernel/cmdline"
CMDLINE_FALLBACK = ETC / "kernel/cmdline-fallback"
PRESET_DIR = ETC / "mkinitcpio.d"

# The packaged placeholder cmdline carries this sentinel until something writes
# the real one, so a file that still holds it counts as unwritten — without this
# the file always exists (it ships with the package) and the lift never runs.
_PLACEHOLDER = "SHEDOS_PLACEHOLDER_CMDLINE"
# Same word-boundary strip render-limine-config.sh uses for its fallback entries.
_NOISE = re.compile(r"\b(?:quiet|splash)\b")


def _already_written() -> bool:
    """True when /etc/kernel/cmdline holds a real cmdline, so we never clobber an
    installer write or a hand-edit. A missing file or the shipped placeholder
    both read as unwritten."""
    try:
        text = CMDLINE.read_text(encoding="utf-8")
    except OSError:
        return False
    return _PLACEHOLDER not in text and bool(text.strip())


def _uki_preset_active() -> bool:
    """True once any installed kernel's preset opts into a UKI output (a *_uki=
    line) — the mark that this box has reached the signed-UKI boot path."""
    try:
        presets = list(PRESET_DIR.glob("*.preset"))
    except OSError:
        return False
    for p in presets:
        try:
            if re.search(r"^\s*\w+_uki\s*=", p.read_text(), re.MULTILINE):
                return True
        except OSError:
            continue
    return False


def _live_cmdline() -> str | None:
    """First kernel_cmdline: in limine.conf — the default entry's line."""
    conf = BOOT / "limine.conf"
    try:
        for line in conf.read_text().splitlines():
            m = re.match(r"^\s*kernel_cmdline:\s*(.*)$", line)
            if m:
                return m.group(1).strip()
    except OSError:
        pass
    return None


def main() -> int:
    if _already_written():
        return 0
    if not _uki_preset_active():
        return 0
    cmdline = _live_cmdline()
    if not cmdline:
        return 0
    fallback = re.sub(r"\s+", " ", _NOISE.sub("", cmdline)).strip()
    CMDLINE.parent.mkdir(parents=True, exist_ok=True)
    CMDLINE.write_text(cmdline + "\n")
    CMDLINE_FALLBACK.write_text(fallback + "\n")
    print(
        "shedos: kernel cmdline lifted into /etc/kernel/cmdline for the "
        "signed-UKI boot path — it takes effect on the next kernel update",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
