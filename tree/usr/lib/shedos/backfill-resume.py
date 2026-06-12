#!/usr/bin/env python3
"""Backfill resume= for hibernation on machines with disk swap.

Fresh installs get resume=UUID=<swap> baked into the cmdline by the
installer; machines installed before that need the token added to
system.toml's [kernel.cmdline].append so `shedman apply` renders it
into limine.conf. Idempotent: no disk swap, an existing resume=
anywhere, or a swapfile-only setup are all clean no-ops.

Invoked by shedos-system.install on upgrade; safe to run by hand.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import tomlkit

TOML = Path(os.environ.get("SHEDOS_APPLY_ETC_ROOT", "/etc")) / "shedos/system.toml"
FSTAB = Path(os.environ.get("SHEDOS_RESUME_FSTAB", "/etc/fstab"))
CMDLINE = Path(os.environ.get("SHEDOS_RESUME_CMDLINE", "/proc/cmdline"))


def disk_swap_uuid() -> str | None:
    """UUID of a swap PARTITION from fstab (swapfiles can't use plain
    resume= and zram can't hibernate at all)."""
    try:
        for line in FSTAB.read_text().splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[2] == "swap" \
                    and fields[0].startswith("UUID="):
                return fields[0].removeprefix("UUID=")
    except OSError:
        pass
    return None


def main() -> int:
    uuid = disk_swap_uuid()
    if not uuid:
        return 0
    try:
        if re.search(r"\bresume=", CMDLINE.read_text()):
            return 0
    except OSError:
        pass
    try:
        doc = tomlkit.parse(TOML.read_text())
    except OSError:
        return 0
    append = doc.get("kernel", {}).get("cmdline", {}).get("append")
    if append is None:
        return 0
    if any(str(tok).startswith("resume=") for tok in append):
        return 0
    append.append(f"resume=UUID={uuid}")
    TOML.write_text(tomlkit.dumps(doc))
    print(
        "shedos: hibernation swap found; resume= added to system.toml — "
        "run `sudo shedman apply` to render it into the boot config",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
