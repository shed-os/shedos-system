#!/usr/bin/env python3
# Guided emergency recovery, run by /usr/lib/shedos/emergency-recovery when a
# mount fails. Plain stdlib (no curses on a bare tty); reuses apply_core's
# fstab audit + nofail writer. Only softens mounts not marked required=true.
# Any error exits non-zero so the entrypoint opens a shell instead.
import os
import sys

sys.path.insert(0, os.environ.get("SHEDOS_LIB_ROOT", "/usr/lib/shedos"))
# An import failure exits non-zero; the entrypoint then opens a shell.
import apply_core as ac  # noqa: E402

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


def _required_targets():
    """Targets marked required=true in system.toml. MountEntry drops the flag
    at validation, so read the raw [[fs.mounts]] tables."""
    if tomllib is None:
        return set()
    try:
        with open(ac.config_path(), "rb") as fh:
            doc = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return set()
    mounts = doc.get("fs", {}).get("mounts", [])
    return {m["target"] for m in mounts
            if isinstance(m, dict) and m.get("required") is True
            and isinstance(m.get("target"), str)}


def _norm(target):
    """Collapse a trailing slash so /mnt/data and /mnt/data/ match."""
    return target.rstrip("/") or "/"


def compute_offerable(fstab_text, required):
    """Audit findings safe to make optional: non-root, nofail-missing,
    excluding required targets. Trailing slashes normalized."""
    req = {_norm(t) for t in required}
    return [f for f in ac.audit_fstab_mount_safety(fstab_text)
            if _norm(f.target) not in req]


def apply_fix(fstab_text, targets):
    """fstab with nofail folded into `targets`. Raises if the line count
    changes, so a bad rewrite never lands."""
    new = ac.add_nofail_to_fstab(fstab_text, list(targets))
    if len(new.splitlines()) != len(fstab_text.splitlines()):
        raise RuntimeError("fstab line count changed -- refusing to write")
    return new


# --- interactive layer ---

def _flush(msg=""):
    if msg:
        sys.stdout.write(msg)
    sys.stdout.flush()


def _stamp():
    import datetime
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def _render(offerable):
    bar = "=" * 64
    _flush("\n  %s\n  ShedOS guided recovery\n  %s\n\n" % (bar, bar))
    _flush("  Your system stopped at emergency mode because fstab requires a\n")
    _flush("  disk that isn't available right now:\n\n")
    for f in offerable:
        _flush("    * %s   (from %s)\n" % (f.target, f.device))
        _flush("      %s\n" % f.reason)
    _flush("\n  ShedOS can mark these mounts optional (nofail) so the system\n")
    _flush("  boots without them. The disks stay configured -- reconnect or\n")
    _flush("  repair them later. Your /etc/fstab is backed up first.\n")


def _write_marker(targets, backup):
    try:
        os.makedirs("/etc/shedos", exist_ok=True)
        with open("/etc/shedos/recovered-from", "w") as fh:
            fh.write("kind=fstab\n")
            fh.write("targets=%s\n" % ",".join(targets))
            fh.write("backup=%s\n" % backup)
    except OSError:
        pass  # the desktop notice is best-effort


def _do_fix(text, offerable, fstab_p):
    """Apply the fix and continue boot. Returns False on failure; on success
    execs `systemctl default` and doesn't return."""
    import subprocess
    targets = [f.target for f in offerable]
    try:
        new = apply_fix(text, targets)
    except Exception as exc:
        _flush("\n  refusing to write fstab: %s\n" % exc)
        return False
    backup = "%s.shedos-emergency-bak-%s" % (fstab_p, _stamp())
    try:
        subprocess.run(["mount", "-o", "remount,rw", "/"], check=False)
        with open(backup, "w") as fh:
            fh.write(text)
        with open(fstab_p, "w") as fh:
            fh.write(new)
    except OSError as exc:
        _flush("\n  could not write fstab (%s).\n" % exc)
        return False
    _write_marker(targets, backup)
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    _flush("\n  Done. Those mounts are now optional; backup at %s\n" % backup)
    _flush("  Continuing boot...\n\n")
    _flush()
    os.execvp("systemctl", ["systemctl", "default"])


def main():
    # main() never returns 0: it returns non-zero (entrypoint opens a shell)
    # or execs. So the entrypoint reading exit 0 means a handoff happened.
    fstab_p = str(ac.fstab_path())
    try:
        text = open(fstab_p).read()
    except OSError:
        return 1  # can't read fstab
    offerable = compute_offerable(text, _required_targets())
    if not offerable:
        return 1  # nothing to fix
    _render(offerable)
    prompt = "\n  [f] make optional and continue   [s] root shell   [r] reboot > "
    while True:
        _flush(prompt)
        try:
            choice = input().strip().lower()
        except EOFError:
            return 1  # no tty
        if choice == "f":
            if not _do_fix(text, offerable, fstab_p):
                _flush("  Try [s] for a shell to fix it by hand.\n")
        elif choice == "s":
            _flush("  Opening a root shell. Run `systemctl default` to continue boot.\n")
            _flush()
            os.execvp("bash", ["bash"])
        elif choice == "r":
            os.execvp("systemctl", ["systemctl", "reboot"])
        else:
            _flush("  Please type f, s, or r.\n")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail-open: exit non-zero, entrypoint opens a shell
        sys.stderr.write("shedos emergency-recovery: %s\n" % exc)
        sys.exit(1)
