shedman-encrypt(1) "ShedOS" "User Commands"

# NAME

shedman-encrypt - encrypt this machine's existing unencrypted disk in place

# SYNOPSIS

*sudo shedman encrypt* [*--no-swap*] [*--force-no-ac*] [*-y*|*--yes*]++
*sudo shedman encrypt* --resume++
*sudo shedman encrypt* --status++
*sudo shedman encrypt* --disarm

# DESCRIPTION

*shedman encrypt* converts this machine's unencrypted root to an encrypted LUKS2
disk in place — no reinstall, no external media, no copying your data off and
back. It also carves a small encrypted swap for hibernation unless you opt out.

The rewrite cannot run while the root is mounted, so the command does not encrypt
anything itself. It runs a preflight, takes your unlock passphrase, and *arms* the
conversion; the next reboot drops into the initramfs, rewrites the disk offline
while nothing is mounted, and boots back into your desktop encrypted. A rewrite of
a full disk takes a while — the machine is unusable until it finishes, so start it
when you can leave it alone.

Only a standard ShedOS layout converts: a plain *btrfs* root on the *@* subvolume,
booted under the systemd initramfs. An already-encrypted disk, a non-btrfs root,
or a non-standard boot line is turned away by the preflight before any byte is
touched.

# THE CONVERSION

With no subcommand, *shedman encrypt* runs the preflight and arms it:

- the root must be plain btrfs and not already a LUKS container;
- the machine must be on AC power or above 50% battery — a power cut mid-rewrite
  is the one real risk (*--force-no-ac* overrides);
- there must be room for the 32 MiB header, and for a RAM-sized swap when carving;
- you type a phrase to acknowledge the disk is rewritten in place with no backup;
- you set the disk unlock passphrase.

It then reboots and rewrites the disk offline. The rewrite is *resumable*: a power
cut leaves the disk part-encrypted, and the next boot picks up where it stopped,
at the passphrase prompt (see *RECOVERY*). When it finishes, the first desktop
login shows a recovery key once — write it down (see *RECOVERY KEY*).

# COMMANDS

*--resume*
	Re-drive a conversion that stalled. The offline rewrite already resumes on
	its own each boot, and the first-boot wiring runs on its own; this is the
	manual lever for when that automatic flow gets stuck. Idempotent. Needs root.

*--status*
	Report where a conversion stands — armed, encrypting, or switching onto the
	encrypted boot path — or that the disk is already encrypted, or that nothing
	is in flight. Needs root.

*--disarm*
	Cancel a conversion that is armed but has not started yet, before the reboot.
	Once the rewrite has begun the disk is LUKS and the way forward is *--resume*,
	not *--disarm*. Needs root.

# OPTIONS

*--no-swap*
	Do not carve an encrypted swap. The root is still encrypted, but there is no
	disk swap and so no hibernation; a zram swap, if configured, is unaffected.

*--force-no-ac*
	Arm without the AC-power / battery check, for a machine on a UPS or one whose
	battery reads wrong. A power cut during the rewrite can lose data.

*-y*, *--yes*
	Skip the typed acknowledgement and the reboot prompt (non-interactive).

*-h*, *--help*
	Show usage.

# RECOVERY KEY

When the conversion finishes, the first login shows a recovery key once, on a
screen you cannot skip until you confirm you saved it. It is a high-entropy
fallback for a forgotten passphrase, stored nowhere on the machine — write it on
paper and keep it away from the box. *shedman key rotate-recovery* replaces it
later; nothing reprints a lost one, by design.

# RECOVERY

A power cut during the rewrite does not lose the disk. The LUKS header carries the
progress, and the next boot resumes the rewrite — stopping at the normal
passphrase prompt rather than continuing unattended. A box that can no longer boot
far enough to resume on its own is recovered from a ShedOS live USB; the
step-by-step is _docs/recovering-from-an-interrupted-encryption.md_.

# EXIT STATUS

*0*
	Armed, or *--status* / *--disarm* ran.

*1*
	A precondition failed — not root, not a convertible layout, low power, too
	full, or a declined acknowledgement — or an operation failed.

*2*
	Invalid usage.

# FILES

/boot/efi/shedos-encrypt/state
	The conversion's phase and geometry, on the ESP so the offline rewrite reads
	it before anything is mounted. Removed when the conversion completes.

/var/lib/shedos/encrypt/recovery-key
	The recovery key, held until the first-login screen shows it, then shredded.

/etc/shedos/secureboot/containers
	The encrypted containers recorded for *shedman key* and *shedman tpm2*.

# SEE ALSO

*shedman*(1), *shedman-key*(1), *shedman-tpm2*(1), *shedman-secureboot*(1).

The full-disk-encryption model and the recovery paths are described in
_docs/boot-safety.md_.
