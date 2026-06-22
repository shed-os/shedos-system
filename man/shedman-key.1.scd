shedman-key(1) "ShedOS" "User Commands"

# NAME

shedman-key - manage the passphrase, keyslots, and recovery key on the encrypted disk

# SYNOPSIS

*sudo shedman key* change-passphrase [*-y*|*--yes*]++
*sudo shedman key* rotate-recovery [*-y*|*--yes*]++
*sudo shedman key* add-key [*--fido2*] [*-y*|*--yes*]++
*sudo shedman key* remove-key <slot> [*-y*|*--yes*]++
*shedman key* --status

# DESCRIPTION

*shedman key* manages the ways you unlock this machine's encrypted disk. Every
change applies to all boot-unlocked LUKS containers at once — the encrypted root
and the encrypted swap, when present — and keeps a working way in at every step.

A LUKS volume holds several keyslots. ShedOS uses them for the disk passphrase,
the paper recovery key (one slot per spelling, so it types at the blind boot
prompt regardless of Caps Lock or the grouping dashes), and any TPM2 or FIDO2
unlock you add. *--status* names what each slot is.

Secrets are read from the terminal or a pipe and handed to *cryptsetup* over
stdin — never on the command line, where they would show in the process list.

# COMMANDS

*change-passphrase*
	Change the disk unlock passphrase on every container. Asks for the
	current passphrase, then the new one twice. TPM2 unlock, if enrolled,
	keeps working — there is nothing to re-enroll. Needs root.

*rotate-recovery*
	Mint a fresh recovery key, show it once, and retire the old one. The new
	key is added and proven to open the disk *before* the old slots are
	removed, so the disk is never reachable only by a key you have not written
	down yet. Write the new key on paper; it is shown once and stored nowhere.
	Needs root.

*add-key* [*--fido2*]
	Add another way in. With no option, add a second passphrase. With
	*--fido2*, enroll a FIDO2 security key — a YubiKey or similar — that
	unlocks with a touch at boot. The passphrase and recovery key stay
	enrolled. Needs root.

*remove-key* <slot>
	Remove the keyslot with the given number (see *--status*). It refuses to
	remove your last keyslot, and your last passphrase or recovery key when
	only a TPM2 or FIDO2 slot would remain — those can fail on a firmware
	change or a lost key. A TPM2 slot is dropped with *shedman tpm2 remove*; a
	passphrase, recovery, or FIDO2 slot is removed here. Needs root.

*--status*
	List each keyslot and what it is — passphrase, recovery, added passphrase,
	tpm2, or fido2. Read-only.

# OPTIONS

*--fido2*
	With *add-key*: enroll a FIDO2 security key instead of a passphrase.

*-y*, *--yes*
	Skip the confirmation prompt (non-interactive).

*-h*, *--help*
	Show usage.

# RECOVERY KEY

The recovery key is a high-entropy key generated on the machine and shown to you
on paper at install. It is the fallback for a forgotten passphrase or a lost
hardware key. ShedOS stores it nowhere — keep the printout somewhere safe and
separate from the machine. *rotate-recovery* replaces it; there is no command
that reprints a lost one, by design.

# EXIT STATUS

*0*
	Success, or *--status* ran.

*1*
	A precondition failed — not root, no encrypted container, a wrong
	passphrase, or a guard refused to strand you — or an operation failed.

*2*
	Invalid usage.

# FILES

/etc/shedos/secureboot/containers
	The boot-unlocked LUKS containers every change applies to, recorded by the
	installer (root first, then encrypted swap). Falls back to _/etc/crypttab_
	on an older box without this file.

# SEE ALSO

*shedman*(1), *shedman-tpm2*(1), *shedman-secureboot*(1).

The full-disk-encryption model and the recovery paths are described in
_docs/boot-safety.md_.
