#!/bin/bash
# Apply any pending mkinitcpio HOOKS migration and rebuild the initramfs.
# Runs from the 96 PostTransaction hook.
#
# This is the catch-up for the 05 PreTransaction migration: pacman runs a
# PreTransaction hook with the script that is installed BEFORE the
# transaction, so when shedos-system itself upgrades, 05 necessarily runs
# the OLD migrate (the new one lands mid-transaction) and a new HOOKS rule
# like the kms removal wouldn't take effect until the following upgrade.
# Re-running the migration here — PostTransaction, with the freshly
# installed code — applies it in the same transaction instead. migrate is
# idempotent and only flags a rebuild when HOOKS actually change, so this
# is a no-op on every upgrade that has nothing to migrate.

set -uo pipefail

sentinel=/var/lib/shedos/.mkinitcpio-regen-needed

if [[ -x /usr/lib/shedos/migrate-mkinitcpio-hooks.sh ]]; then
    /usr/lib/shedos/migrate-mkinitcpio-hooks.sh || true
fi

[[ -e $sentinel ]] || exit 0

if ! /usr/lib/shedos/rebuild-initramfs.sh; then
    echo "shedos: initramfs rebuild failed; will retry next transaction" >&2
    exit 1
fi

# The rebuilt initramfs has to be re-bundled (and re-signed where keys exist)
# into the UKI before the menu points at it — Limine chainloads the signed UKI
# off the ESP, so it must be in place first. build-uki is loud and non-zero on
# a full ESP or a verify miss; keep the sentinel so a failure retries next
# transaction.
if ! /usr/lib/shedos/build-uki.sh --rebuild; then
    echo "shedos: UKI rebuild failed; will retry next transaction" >&2
    exit 1
fi

# The initramfs + UKI now match the migrated HOOKS — the sentinel's job is done
# even if the ESP re-render below trips. render-limine-config.sh is loud and
# non-zero on a full ESP; let that surface rather than masking it, but don't
# re-run the rebuild for it.
rm -f "$sentinel"
exec /usr/lib/shedos/render-limine-config.sh
