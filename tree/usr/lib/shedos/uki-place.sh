#!/usr/bin/env bash
# Shared UKI placement onto the EFI System Partition. Sourced by build-uki.sh
# and build-recovery-uki.sh. The discipline mirrors render-limine-config.sh's
# ESP sync (#159): write a temp beside the target, fsync, verify the signature
# (only when uki.conf is in signing form — the same condition under which ukify
# signed the image; a keyless box ships its unsigned UKI as-is), then rename(2)
# over the target so the prior boot image survives until the new one is proven
# good. Space-aware: refuse rather than tear a UKI onto a full FAT volume. The
# caller sets UKI_CONF (the signing source of truth), DB_CERT (the sbverify
# cert) and SHEDOS_ESP_DIRS.

# Free bytes on the filesystem holding $1. SHEDOS_ESP_FAKE_AVAIL overrides for
# tests. Same contract as the renderer's helper.
_avail_bytes() {
    [[ -n ${SHEDOS_ESP_FAKE_AVAIL:-} ]] && { echo "$SHEDOS_ESP_FAKE_AVAIL"; return; }
    local d a s
    d=$(dirname -- "$1")
    a=$(stat -f -c %a -- "$d" 2>/dev/null) || return 1
    s=$(stat -f -c %S -- "$d" 2>/dev/null) || return 1
    echo $(( a * s ))
}

# Is the active uki.conf in signing form? ukify signs a UKI iff uki.conf names a
# SecureBootCertificate, so this is exactly "was this UKI built signed" — the
# condition that should gate sbverify. A keyless uki.conf (the shipped default,
# and the state `shedman secureboot disable` restores) means unsigned UKIs, so
# skip the check rather than reject them.
_uki_signing() {
    grep -qE '^[[:space:]]*SecureBootCertificate=' "${UKI_CONF:-/etc/kernel/uki.conf}" 2>/dev/null
}

# _place SRC DST — atomic, signature-verified (when uki.conf signs), space-aware.
# Keeps the prior DST until the new file verifies. Non-zero on any failure,
# leaving DST untouched.
_place() {
    local src=$1 dst=$2 tmp need cur avail
    cmp -s -- "$src" "$dst" 2>/dev/null && return 0
    need=$(stat -c %s -- "$src") || return 1
    cur=$(stat -c %s -- "$dst" 2>/dev/null || echo 0)
    avail=$(_avail_bytes "$dst")
    if [[ $avail =~ ^[0-9]+$ ]] && (( need - cur > avail )); then
        printf 'uki: FATAL: %s is %s MiB short of fitting its ESP — keeping the prior boot image\n' \
            "${dst##*/}" "$(( (need - cur - avail + 1048575) / 1048576 ))" >&2
        return 1
    fi
    install -d -- "$(dirname -- "$dst")" || return 1
    tmp=$dst.new
    if ! { cp -- "$src" "$tmp" && sync -- "$tmp"; }; then
        printf 'uki: FATAL: write of %s failed (ESP full?) — removed the partial\n' "$tmp" >&2
        rm -f -- "$tmp"; return 1
    fi
    # Signing uki.conf ⟹ ukify signed this UKI ⟹ verify before trusting it. A
    # signing conf with DB_CERT missing is an inconsistent state enroll/disable
    # never leave; sbverify fails closed there (keep the prior signed image) by
    # design — do not turn this into a skip.
    if _uki_signing && ! sbverify --cert "$DB_CERT" "$tmp" >/dev/null 2>&1; then
        printf 'uki: FATAL: %s boot signature could not be verified — kept the prior image\n' "${dst##*/}" >&2
        rm -f -- "$tmp"; return 1
    fi
    if ! mv -f -- "$tmp" "$dst"; then
        printf 'uki: FATAL: could not finalize %s — kept the prior image\n' "${dst##*/}" >&2
        rm -f -- "$tmp"; return 1
    fi
    return 0
}

# _esp_dirs — print the ESP roots that hold a limine config, one per line. Same
# discovery rule as render-limine-config.sh and recover-esp.sh.
_esp_dirs() {
    local d
    read -r -a _c <<< "${SHEDOS_ESP_DIRS:-/boot/efi /efi}"
    for d in "${_c[@]}"; do
        [[ -f $d/limine.conf || -f $d/EFI/limine/limine.conf ]] && echo "$d"
    done
}

# vim: set ft=sh ts=4 sw=4 et:
