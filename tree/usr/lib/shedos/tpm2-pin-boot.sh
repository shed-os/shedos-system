#!/bin/bash
# Boot-flow companion for TPM2 PIN enrollments.
#
# The default token-plugin unlock path re-prompts a wrong PIN forever and
# never falls back to the passphrase, which locks the user out of their
# own passphrase and recovery key at boot. systemd-cryptsetup's native
# path asks the PIN at most five times and then falls through to the
# passphrase prompt. `configure` flips a PIN-enrolled box onto the native
# path (a service drop-in plus tpm2-device=auto on the kernel cmdline)
# and rebuilds the UKIs so it reaches the initrd; `deconfigure` restores
# the default. Both are idempotent and only rebuild when something
# actually changed.
set -uo pipefail

DROPIN=${SHEDOS_TPM2_PIN_DROPIN:-/etc/systemd/system/systemd-cryptsetup@.service.d/10-shedos-tpm2-pin.conf}
read -r -a CMDLINES <<< "${SHEDOS_TPM2_PIN_CMDLINES:-/etc/kernel/cmdline /etc/kernel/cmdline-fallback}"
BUILD_UKI=${SHEDOS_TPM2_PIN_BUILD_UKI:-/usr/lib/shedos/build-uki.sh}
CONTAINERS_FILE=${SHEDOS_TPM2_PIN_CONTAINERS:-/etc/shedos/secureboot/containers}

_die() { echo "tpm2-pin-boot: $*" >&2; exit 1; }

_has_fido2() {
    [[ -r $CONTAINERS_FILE ]] || return 1
    local dev
    while IFS= read -r dev; do
        [[ -z $dev || $dev == \#* ]] && continue
        cryptsetup luksDump "$dev" 2>/dev/null | grep -q 'systemd-fido2' && return 0
    done < "$CONTAINERS_FILE"
    return 1
}

_patch_cmdline() {  # $1=file $2=option — append into every rd.luks.options list
    local f=$1 opt=$2
    [[ -f $f ]] || return 1
    grep -q "rd\.luks\.options=[^ ]*\b${opt}\b" "$f" && return 1
    grep -q "rd\.luks\.options=" "$f" || return 1
    sed -i "s/rd\.luks\.options=\([^ ]*\)/rd.luks.options=\1,${opt}/g" "$f"
    return 0
}

_strip_cmdline() {  # $1=file $2=option
    local f=$1 opt=$2
    [[ -f $f ]] || return 1
    grep -q "${opt}" "$f" || return 1
    sed -i "s/,${opt}\b//g; s/rd\.luks\.options=${opt},/rd.luks.options=/g" "$f"
    return 0
}

configure() {
    local changed="" f
    if [[ ! -f $DROPIN ]]; then
        mkdir -p "$(dirname "$DROPIN")"
        cat > "$DROPIN" <<'EOF'
[Service]
# Native unlock path: at most five PIN attempts, then the passphrase
# prompt. The token-plugin path re-prompts a wrong PIN forever.
Environment=SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0
EOF
        changed=1
    fi
    local opts="tpm2-device=auto"
    _has_fido2 && opts="$opts fido2-device=auto"
    for f in "${CMDLINES[@]}"; do
        local o
        for o in $opts; do
            _patch_cmdline "$f" "$o" && changed=1
        done
    done
    if [[ -n $changed ]]; then
        "$BUILD_UKI" --rebuild || _die "the boot images did not rebuild; re-run: sudo $0 configure"
    fi
}

deconfigure() {
    local changed="" f o
    if [[ -f $DROPIN ]]; then
        rm -f "$DROPIN"
        rmdir --ignore-fail-on-non-empty "$(dirname "$DROPIN")" 2>/dev/null || true
        changed=1
    fi
    for f in "${CMDLINES[@]}"; do
        for o in tpm2-device=auto fido2-device=auto; do
            _strip_cmdline "$f" "$o" && changed=1
        done
    done
    if [[ -n $changed ]]; then
        "$BUILD_UKI" --rebuild || _die "the boot images did not rebuild; re-run: sudo $0 deconfigure"
    fi
}

case "${1:-}" in
    configure)   configure ;;
    deconfigure) deconfigure ;;
    *) _die "usage: $0 configure|deconfigure" ;;
esac
