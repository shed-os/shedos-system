# shedos-system

The system half of [ShedOS](https://shedos.org): boot and UKI assembly, Limine
configuration, full-disk encryption, Secure Boot and TPM2 enrolment, the
session and login wiring, and the systemd units, udev rules and `/etc`
drop-ins that make a ShedOS box behave like one.

**Build-out in progress.** Production lives at
[Theshedman/shedos](https://github.com/Theshedman/shedos) until the multi-repo
cutover completes; this repo publishes to a staging channel.

## The verbs it ships

`shedman` itself lives in [shed-os/shedman](https://github.com/shed-os/shedman).
This package adds eight verbs to it — `encrypt`, `fingerprint`, `kernel`,
`key`, `lock`, `login`, `secureboot` and `tpm2` — each with a declaration at
`/usr/share/shedman/verbs.d/<name>.toml` naming itself, its owning package, its
man page and what it does. The dispatcher lists what is declared, and the
shared pipeline holds every shipped executable to that contract.

## The pacman channel blocks

`/etc/pacman.conf` carries the ShedOS channels between markers, and
`/usr/lib/shedos/pacman-fence` is the only thing that writes them. Ownership is
by repository name: `shedos` and `shedostest` are reserved to this package, and
declaring either in `/etc/shedos/system.toml` is refused rather than honoured —
they are the channels the install scriptlet keeps right. Every other name
belongs to whatever declares it there.

The order is fixed however the file was reached: the canary first, then stable,
then the declared repositories alphabetically. pacman hands a package to the
first repository that lists it, so that is what lets an enabled canary override
stable during an RC soak.

A block between the markers is ours. A hand-written one for a repository nobody
declared is reconciled away on the next run, and an edit inside one lasts until
then — declare the repository instead.

```
pacman-fence reserved
pacman-fence render <stable|canary> [--commented]
pacman-fence render-repo <name> <server> [siglevel]
pacman-fence rewrite [--canary-enabled]              < conf > conf
pacman-fence rewrite-repos [--repo <name> <server> [siglevel]]...  < conf > conf
```

## What it does not ship

Four things came out of this package and live on their own now: the `shedman`
dispatcher and its core verbs, the theme renderer and the palettes it reads,
the dock verb, and the system-wide GTK defaults that belong beside the rest of
the desktop configuration.

## Tests

Every suite runs from the checkout with no root and no network:

```
for s in test/*/run.sh; do bash "$s"; done
```

[shed-os/shedos-ci](https://github.com/shed-os/shedos-ci) builds and tests this
repo and requests publication;
[shed-os/shedos-release](https://github.com/shed-os/shedos-release) signs and
publishes.
