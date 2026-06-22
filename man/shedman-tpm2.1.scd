shedman-tpm2(1) "ShedOS" "User Commands"

# NAME

shedman-tpm2 - manage TPM2-backed passwordless unlock for the encrypted disk

# SYNOPSIS

*sudo shedman tpm2* enroll [*--with-pin*] [*-y*|*--yes*]++
*sudo shedman tpm2* re-enroll [*--with-pin*] [*-y*|*--yes*]++
*sudo shedman tpm2* remove [*-y*|*--yes*]++
*shedman tpm2* --status

# DESCRIPTION

*shedman tpm2* binds the encrypted root (and the encrypted swap, when present)
to this machine's TPM2 so the disk unlocks without a typed passphrase on a
trusted boot. It is opt-in and post-install: a fresh encrypted box asks for the
passphrase every boot until you enroll.

The passphrase and the recovery key are *never* removed — TPM2 unlock is an
added keyslot, not a replacement. If the measured boot state changes, the TPM
declines and you fall back to the passphrase.

TPM2 unlock only works under Secure Boot: the key is released against a signed
measurement of the boot chain (PCR 11), so the box must have its own keys
enrolled first. See *shedman-secureboot*(1).

# COMMANDS

*enroll*
	Add a TPM2 keyslot to every boot-unlocked container. Add-only: it never
	touches the passphrase or recovery slots. Needs root.

*re-enroll*
	Rotate the TPM2 slot after a key or boot-chain change — drop the old
	binding and add a fresh one. Needs root.

*remove*
	Drop the TPM2 keyslot and return to passphrase-on-every-boot. The
	passphrase and recovery key are untouched. Needs root.

*--status*
	Show whether TPM2 unlock is enrolled, and on which containers. Read-only.

# OPTIONS

*--with-pin*
	Also require a short PIN at unlock, in addition to the measured boot
	state. Restores resistance to the offline rollback described under THE
	PASSWORDLESS TRADEOFF; without it, unlock is fully passwordless.

*-y*, *--yes*
	Skip the confirmation prompt (non-interactive).

*-h*, *--help*
	Show usage.

# THE PASSWORDLESS TRADEOFF

Passwordless unlock (the default) binds the disk to a signed measurement of the
boot chain, so it opens automatically only when this box boots its own signed
kernel. It protects data at rest — a pulled disk stays encrypted — but not a
powered-on or running stolen machine, and a physical attacker who can roll the
box back to an older signed kernel can still auto-unlock. *--with-pin* closes
that gap at the cost of a short PIN at boot. This is the same tradeoff as
BitLocker's TPM-only default; choose by your threat model.

# EXIT STATUS

*0*
	Success, or *--status* ran.

*1*
	A precondition failed — not root, Secure Boot inactive, no Secure Boot
	key enrolled, or no encrypted container to bind — or an operation failed.

*2*
	Invalid usage.

# FILES

/etc/shedos/secureboot/containers
	The boot-unlocked LUKS containers *enroll* binds to the TPM, recorded by
	the installer (root first, then encrypted swap). Falls back to
	_/etc/crypttab_ on an older box without this file.

/etc/shedos/secureboot/pcr-public.pem
	The measured-boot signing key the TPM2 policy is bound to.

# SEE ALSO

*shedman*(1), *shedman-secureboot*(1).

The full-disk-encryption model and the recovery paths are described in
_docs/boot-safety.md_.
