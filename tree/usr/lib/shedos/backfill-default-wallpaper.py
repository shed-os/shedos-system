#!/usr/bin/env python3
"""Move installs still on the old default wallpaper to the new one.

system.toml is a backup file, so a changed shipped default never
reaches an existing install — only a migration does. Conservative: it
switches the wallpaper ONLY when the install is still on a known
previous default (the user never chose their own). A custom choice is
left untouched. Stamp-gated so a user who later re-selects an old
default isn't yanked off it.

Invoked from shedos-system.install post_upgrade, before the theme is
re-rendered. Idempotent.
"""
from __future__ import annotations

import os
from pathlib import Path

import tomlkit

ETC = Path(os.environ.get("SHEDOS_APPLY_ETC_ROOT", "/etc"))
TOML = ETC / "shedos/system.toml"
STAMP = Path(os.environ.get("SHEDOS_STATE_ROOT", "/var/lib/shedos")) \
    / ".default-wallpaper-migrated"

NEW = "/usr/share/shedos/wallpapers/lumen.png"
# Every value that has ever shipped as the default. A machine on any
# of these never opted out, so it's safe to advance.
OLD_DEFAULTS = {"/usr/share/shedos/wallpapers/dusk.png"}


def main() -> int:
    if STAMP.exists():
        return 0
    try:
        doc = tomlkit.parse(TOML.read_text())
    except OSError:
        return 0
    theme = doc.get("theme")
    if theme is None:
        return 0
    current = str(theme.get("wallpaper", "")).strip()
    if current in OLD_DEFAULTS:
        theme["wallpaper"] = NEW
        TOML.write_text(tomlkit.dumps(doc))
        print("shedos: default wallpaper updated to lumen "
              "(you were on the previous default)", flush=True)
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    STAMP.write_text("")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
