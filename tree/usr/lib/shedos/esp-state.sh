#!/usr/bin/env bash
# Orchestration state for in-place reencryption, on the ESP so the initramfs
# one-shot reads it before sysroot is mounted. The LUKS2 header owns reencrypt
# progress; this file owns the phase (armed/encrypting/flip-pending) plus the
# reencrypt flags resume must replay. Parsed line-by-line, never sourced —
# containers= holds device paths and this is read as root in early boot.
#
# Crash-atomicity is best-effort: rename gives a reader old-or-new, and sync
# pushes it out, but FAT has no journal. The real backstop is the one-shot
# re-probing isLuks on the device, so a lost write degrades to a re-probe.

ESP_STATE_FILE="${ESP_STATE_FILE:-/boot/efi/shedos-encrypt/state}"

esp_state_read() {
    [[ -f $ESP_STATE_FILE ]] && cat -- "$ESP_STATE_FILE"
}

esp_state_get() {
    local key=$1 line
    [[ -f $ESP_STATE_FILE ]] || return 1
    line=$(grep -m1 "^${key}=" -- "$ESP_STATE_FILE") || return 1
    printf '%s\n' "${line#*=}"
}

# Merge the given KEY=VALUE pairs over the existing file, then atomically swap.
# Unspecified keys survive (the transition path: phase= changes, flags=/
# containers=/created= persist).
esp_state_write() {
    local dir; dir=$(dirname -- "$ESP_STATE_FILE")
    mkdir -p -- "$dir"
    local -A kv=()
    local pair key line
    # seed from the current file so unspecified keys carry over
    if [[ -f $ESP_STATE_FILE ]]; then
        while IFS= read -r line; do
            [[ $line == *=* ]] || continue
            kv[${line%%=*}]=${line#*=}
        done < "$ESP_STATE_FILE"
    fi
    for pair in "$@"; do
        key=${pair%%=*}
        kv[$key]=${pair#*=}
    done
    local tmp; tmp=$(mktemp -- "${ESP_STATE_FILE}.XXXXXX")
    for key in "${!kv[@]}"; do
        printf '%s=%s\n' "$key" "${kv[$key]}"
    done > "$tmp"
    sync -- "$tmp"
    mv -f -- "$tmp" "$ESP_STATE_FILE"
    sync -- "$ESP_STATE_FILE"
}

esp_state_clear() {
    rm -f -- "$ESP_STATE_FILE"
}
