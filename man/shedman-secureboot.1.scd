shedman-secureboot(1) "ShedOS" "User Commands"

# NAME

shedman-secureboot - manage this machine's Secure Boot keys and signed boot images

# SYNOPSIS

*shedman secureboot* status | verify++
*sudo shedman secureboot* enroll [*--shedos-only*] [*-y*|*--yes*]++
*sudo shedman secureboot* sign | repair++
*sudo shedman secureboot* disable [*--keyless*] [*-y*|*--yes*]

# DESCRIPTION

*shedman secureboot* manages this machine's own Secure Boot keys and the
signed Unified Kernel Images that Limine chainloads. ShedOS enrolls a per-box
key into firmware rather than trusting a vendor chain, so the keys live only on
this disk.

*enroll* arms the firmware as its *last* step, only after every boot image and
both Limine copies have been signed and verified. A failure at any earlier
point leaves Secure Boot off and the box still bootable — it never strands you
with firmware that rejects its own boot images.

*status* and *verify* are read-only. *verify* only sees the placed images when
run as root, because the ESP is root-only; the mutating commands need root.

# COMMANDS

*status*
	Print the firmware Secure Boot state (on, off, or Setup Mode), whether
	this box has its own keys, and whether the placed images are signed and
	valid.

*verify*
	Check every placed boot image against this box's key and report the live
	Secure Boot state. Exits non-zero if Secure Boot is off while keys are
	enrolled, any image fails its signature, or no images are found.

*enroll*
	Sign the whole boot chain and enroll this box's keys into firmware.
	Mints the keys if absent, rewrites _/etc/kernel/uki.conf_ to its signing
	form, rebuilds and signs every UKI and Limine copy, verifies the chain,
	and only then arms the firmware. Needs root and firmware in Setup Mode —
	clear the platform keys from your firmware setup first.

*sign*
	Re-sign the placed boot images after a key change. Needs keys already
	present; does not touch firmware.

*repair*
	Rebuild and re-sign a missing or unsigned image — the recovery path when
	an image was lost or a build left one unsigned.

*disable*
	Clear this box's keys so the firmware stops enforcing Secure Boot
	(returns it to Setup Mode). The already-signed images still boot.

# OPTIONS

*--shedos-only*
	*enroll* only: enroll without also trusting the Microsoft CA. Advanced —
	a single-boot box's signed option ROMs (some discrete GPUs, NICs) may not
	initialise without it.

*--keyless*
	*disable* only: also revert _uki.conf_ so later kernels build unsigned.
	Without it, *disable* leaves the signing config in place.

*-y*, *--yes*
	Skip the confirmation prompt (*enroll* and *disable*).

*-h*, *--help*
	Show usage.

# EXIT STATUS

*0*
	Success, or *verify* found a sound, fully-signed chain.

*1*
	A precondition failed (not root, firmware not in Setup Mode, not yet on
	the signed-UKI boot path), an operation failed, or *verify* found a
	problem.

*2*
	Secure Boot does not apply (a BIOS box), or invalid usage.

# FILES

/var/lib/sbctl/keys/db/db.pem, db.key
	This machine's Secure Boot certificate and signing key.

/etc/kernel/uki.conf
	The ukify config. Its signing form names the key so each kernel build
	produces a signed UKI; *disable --keyless* reverts it.

/boot/efi/EFI/Linux/shedos-\*.efi
	The signed Unified Kernel Images Limine chainloads.

# SEE ALSO

*shedman*(1), *shedman-tpm2*(1), *shedman-doctor*(1).

The boot model, the unsigned-media recovery path, and the passwordless-unlock
tradeoff are described in _docs/boot-safety.md_.
