#!/usr/bin/env bash
# Re-emit /boot/limine.conf with one entry per installed kernel (plus a
# fallback entry per kernel) and a default timeout that makes the menu
# visible. Idempotent; running twice in a row produces a byte-identical
# output.
#
# Discovers kernels via /usr/lib/modules/*/pkgbase. Each kernel package
# writes its own pkgbase file when installed (mkinitcpio convention);
# the renderer reads them all to build the entry list.
#
# Cmdline resolution, in order:
#   1. SHEDOS_LIMINE_CMDLINE env; used by the installer at fresh-install
#      time, when /boot/limine.conf doesn't exist yet
#   2. First kernel_cmdline: line in the existing /boot/limine.conf —
#      preserves anything the [kernel.cmdline] reconciler in apply_core
#      manages, plus any user hand-edits
#   3. Fail with a non-zero exit if neither is available
#
# Default boot priority (first wins):
#   1. /var/lib/shedos/kernel-default contents (if the file exists and
#      names an installed kernel); `shedman kernel --set-default` writes
#      it
#   2. linux-zen (if installed)
#   3. linux
#   4. Anything else, alphabetical

set -uo pipefail

BOOT_DIR=${SHEDOS_BOOT_DIR:-/boot}
MODULES_DIR=${SHEDOS_MODULES_DIR:-/usr/lib/modules}
LIMINE_CONF=$BOOT_DIR/limine.conf
DEFAULT_FILE=${SHEDOS_KERNEL_DEFAULT_FILE:-/var/lib/shedos/kernel-default}
TIMEOUT=${SHEDOS_LIMINE_TIMEOUT:-3}

# uefi → efi_chainload a signed UKI (build-uki.sh placed + verified it on the
# ESP; its presence here IS the verified contract — the renderer never copies
# or re-verifies it). bios → copy raw vmlinuz/initramfs and boot protocol:
# linux. The installer passes the target's firmware explicitly; a bare run
# self-detects from the running host.
FIRMWARE=${SHEDOS_FIRMWARE:-$([[ -d /sys/firmware/efi ]] && echo uefi || echo bios)}

# Discover installed kernel pkgbases.
mapfile -t pkgbases < <(
    for f in "$MODULES_DIR"/*/pkgbase; do
        [[ -r $f ]] && cat "$f"
    done | sort -u
)

if (( ${#pkgbases[@]} == 0 )); then
    echo "render-limine-config: no kernels found under $MODULES_DIR/*/pkgbase" >&2
    exit 1
fi

# Build the boot order. User-chosen default first, then linux-zen,
# then linux, then everything else alphabetical. Each pkgbase appears
# exactly once.
user_default=""
[[ -r $DEFAULT_FILE ]] && user_default=$(<"$DEFAULT_FILE")

declare -A added=()
ordered=()

_add() {
    local k=$1
    [[ -n ${added[$k]:-} ]] && return
    added[$k]=1
    ordered+=("$k")
}

_have_pkgbase() {
    local needle=$1 k
    for k in "${pkgbases[@]}"; do
        [[ $k == "$needle" ]] && return 0
    done
    return 1
}

if [[ -n $user_default ]] && _have_pkgbase "$user_default"; then
    _add "$user_default"
fi
_have_pkgbase linux-zen && _add linux-zen
_have_pkgbase linux && _add linux
for k in "${pkgbases[@]}"; do
    _add "$k"
done

# Resolve cmdline. UEFI bakes it into the signed UKI, so this is BIOS-only.
cmdline=""
cmdline_fallback=""
if [[ $FIRMWARE == bios ]]; then
    cmdline=${SHEDOS_LIMINE_CMDLINE:-}
    if [[ -z $cmdline && -f $LIMINE_CONF ]]; then
        cmdline=$(awk '
            /^[[:space:]]*kernel_cmdline:/ {
                sub(/^[[:space:]]*kernel_cmdline:[[:space:]]*/, "", $0)
                print
                exit
            }' "$LIMINE_CONF")
    fi
    if [[ -z $cmdline ]]; then
        echo "render-limine-config: no cmdline available — set SHEDOS_LIMINE_CMDLINE or seed $LIMINE_CONF first" >&2
        exit 1
    fi
    # Fallback entries strip quiet/splash so the boot log is visible. Use
    # word-boundary matches so removing `quiet` doesn't consume the trailing
    # space `splash` would otherwise match against.
    cmdline_fallback=$(printf '%s\n' "$cmdline" \
        | sed -E 's/\<(quiet|splash)\>//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
fi

_display_name() {
    case "$1" in
        linux-zen)     echo "ShedOS Linux" ;;
        linux)         echo "ShedOS Linux (stock)" ;;
        *)             echo "ShedOS Linux ($1)" ;;
    esac
}

# ── ESP transport helpers ─────────────────────────────────────────────
# Limine boots vmlinuz + initramfs AND reads its config from a FAT volume
# (its drivers read only FAT/ISO9660; /boot on btrfs is invisible). We
# copy both there. The ESP is small, so a copy that doesn't fit must fail
# LOUD and leave the previous image intact — a silently truncated
# initramfs is an unbootable default kernel (the bug this rewrite closes).

# Free bytes on the filesystem holding $1's directory, via statfs (no df
# parsing — df may be shell-aliased, statfs can't be). SHEDOS_ESP_FAKE_AVAIL
# overrides it for tests that need to exercise the out-of-space refusal.
_avail_bytes() {
    [[ -n ${SHEDOS_ESP_FAKE_AVAIL:-} ]] && { echo "$SHEDOS_ESP_FAKE_AVAIL"; return; }
    local d a s
    d=$(dirname -- "$1")
    a=$(stat -f -c %a -- "$d" 2>/dev/null) || return 1
    s=$(stat -f -c %S -- "$d" 2>/dev/null) || return 1
    echo $(( a * s ))
}

# Copy SRC→DST (mode $1) when they differ; refuse rather than truncate if
# the ESP can't hold it, and verify the copy landed byte-for-byte. Never
# leaves a partial file behind. Returns non-zero on any failure.
_esp_put() {
    local mode=$1 src=$2 dst=$3 need cur avail
    cmp -s -- "$src" "$dst" 2>/dev/null && return 0
    need=$(stat -c %s -- "$src")
    cur=$(stat -c %s -- "$dst" 2>/dev/null || echo 0)
    avail=$(_avail_bytes "$dst")
    if [[ $avail =~ ^[0-9]+$ ]] && (( need - cur > avail )); then
        printf 'render-limine-config: FATAL: %s is %s MiB short of fitting its ESP — refusing to write a truncated boot image\n' \
            "${dst##*/}" "$(( (need - cur - avail + 1048575) / 1048576 ))" >&2
        return 1
    fi
    if ! install -D -m "$mode" -- "$src" "$dst"; then
        printf 'render-limine-config: FATAL: write of %s failed (ESP full?) — removed partial\n' "$dst" >&2
        rm -f -- "$dst"
        return 1
    fi
    if [[ "$(stat -c %s -- "$dst")" != "$need" ]] || ! cmp -s -- "$src" "$dst"; then
        printf 'render-limine-config: FATAL: %s is truncated/corrupt after copy — removed it\n' "$dst" >&2
        rm -f -- "$dst"
        return 1
    fi
    return 0
}

_is_ordered() { local k; for k in "${ordered[@]}"; do [[ $1 == "$k" ]] && return 0; done; return 1; }

# ESP image dirs (roots that already hold a limine config — we never
# create a new ESP layout) and the config paths within them. Defaults to
# the two real mount points, matching apply_core._ESP_LIMINE_MIRRORS;
# SHEDOS_ESP_DIRS overrides the roots for tests.
read -r -a _esp_candidates <<< "${SHEDOS_ESP_DIRS:-/boot/efi /efi}"
esp_img_dirs=()
esp_conf_paths=()
for d in "${_esp_candidates[@]}"; do
    if [[ -f $d/limine.conf || -f $d/EFI/limine/limine.conf ]]; then
        esp_img_dirs+=("$d")
    fi
    [[ -f $d/EFI/limine/limine.conf ]] && esp_conf_paths+=("$d/EFI/limine/limine.conf")
    [[ -f $d/limine.conf ]] && esp_conf_paths+=("$d/limine.conf")
done

failed=0

# ── Reap raw kernel images ────────────────────────────────────────────
# On BIOS these raw images are the boot payload, so keep the ones for an
# installed kernel and drop only orphans (e.g. a retired shedos-kernel).
# On UEFI the payload is UKIs and no entry ever references a raw image, so
# any that exist are pre-UKI vestige from a migrated install — reap them
# all. Either way this frees the FAT volume before the current set lands.
for d in "${esp_img_dirs[@]}"; do
    for img in "$d"/vmlinuz-* "$d"/initramfs-*.img; do
        [[ -e $img ]] || continue
        base=${img##*/}
        case $base in
            vmlinuz-*)                k=${base#vmlinuz-} ;;
            initramfs-*-fallback.img) k=${base#initramfs-}; k=${k%-fallback.img} ;;
            initramfs-*.img)          k=${base#initramfs-}; k=${k%.img} ;;
            *) continue ;;
        esac
        [[ $FIRMWARE == bios ]] && _is_ordered "$k" && continue
        rm -f -- "$img" && echo "render-limine-config: pruned stale $base from $d"
    done
done

# ── Sync the live kernels' images, shrink-first, fail loud ────────────
# Bucket every needed copy by whether it grows or shrinks the ESP, then
# do the shrinking/equal ones first. On a full ESP an in-place replace
# only fits once the images it's replacing have freed their space, so a
# growing default (truncated → full) must wait for a shrinking sibling.
declare -a _shrink=() _grow=()
for k in "${ordered[@]}"; do
    [[ $FIRMWARE == bios ]] || continue   # UEFI: build-uki.sh owns ESP placement
    for f in "vmlinuz-$k" "initramfs-$k.img" "initramfs-$k-fallback.img"; do
        src=$BOOT_DIR/$f
        [[ -f $src ]] || continue
        for d in "${esp_img_dirs[@]}"; do
            dst=$d/$f
            cmp -s -- "$src" "$dst" 2>/dev/null && continue
            need=$(stat -c %s -- "$src")
            cur=$(stat -c %s -- "$dst" 2>/dev/null || echo 0)
            if (( need <= cur )); then _shrink+=("$src|$dst"); else _grow+=("$src|$dst"); fi
        done
    done
done
for item in "${_shrink[@]}" "${_grow[@]}"; do
    _esp_put 600 "${item%|*}" "${item#*|}" || failed=1
done

# A kernel variant is bootable only when vmlinuz AND its initramfs are
# byte-identical to /boot on EVERY ESP. (With no ESP — fresh install
# before the layout exists — the loop is empty and everything counts as
# present, preserving the old "emit all entries" behaviour.)
_on_all_esps() {
    local f=$1 d
    for d in "${esp_img_dirs[@]}"; do
        cmp -s -- "$BOOT_DIR/$f" "$d/$f" 2>/dev/null || return 1
    done
    return 0
}
# A UEFI UKI is bootable when build-uki.sh has placed it on EVERY ESP. The
# renderer never copies or re-verifies it — its presence is the contract.
_uki_on_all_esps() {
    local f=$1 d
    for d in "${esp_img_dirs[@]}"; do
        [[ -f $d/EFI/Linux/$f ]] || return 1
    done
    (( ${#esp_img_dirs[@]} > 0 ))
}
declare -A img_ok=()
if [[ $FIRMWARE == bios ]]; then
    for k in "${ordered[@]}"; do
        _on_all_esps "vmlinuz-$k" || continue
        [[ -f $BOOT_DIR/initramfs-$k.img ]] && _on_all_esps "initramfs-$k.img" \
            && img_ok[$k:default]=1
        [[ -f $BOOT_DIR/initramfs-$k-fallback.img ]] && _on_all_esps "initramfs-$k-fallback.img" \
            && img_ok[$k:fallback]=1
    done
else
    for k in "${ordered[@]}"; do
        _uki_on_all_esps "shedos-$k.efi" && img_ok[$k:default]=1
        _uki_on_all_esps "shedos-$k-fallback.efi" && img_ok[$k:fallback]=1
    done
fi
# The recovery UKI (when present) is its own entry — see the render loop.
recovery_ok=""
_uki_on_all_esps "shedos-recovery.efi" && recovery_ok=1

# ── Render the config, gating each entry on its image being present ───
tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT

entries=0
{
    echo "# Generated by /usr/lib/shedos/render-limine-config.sh."
    echo "# Edits to kernel_cmdline survive regeneration; entries are"
    echo "# rewritten on every kernel install/upgrade. To change the"
    echo "# default entry: sudo shedman kernel --set-default <pkgbase>"
    echo "timeout: $TIMEOUT"
    echo
    for k in "${ordered[@]}"; do
        name=$(_display_name "$k")
        if [[ -n ${img_ok[$k:default]:-} ]]; then
            if [[ $FIRMWARE == uefi ]]; then
                cat <<EOF
/$name
    protocol: efi_chainload
    image_path: boot():/EFI/Linux/shedos-$k.efi

EOF
            else
                cat <<EOF
/$name
    protocol: linux
    kernel_path: boot():/vmlinuz-$k
    kernel_cmdline: $cmdline
    module_path: boot():/initramfs-$k.img

EOF
            fi
            entries=$((entries + 1))
        fi
        # Fallback entry only when its image/UKI is on the ESP: a stock-linux
        # kernel ships none, and a failed or oversized copy must never
        # dead-end the boot.
        if [[ -n ${img_ok[$k:fallback]:-} ]]; then
            if [[ $FIRMWARE == uefi ]]; then
                cat <<EOF
/$name (Fallback)
    protocol: efi_chainload
    image_path: boot():/EFI/Linux/shedos-$k-fallback.efi

EOF
            else
                cat <<EOF
/$name (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-$k
    kernel_cmdline: $cmdline_fallback
    module_path: boot():/initramfs-$k-fallback.img

EOF
            fi
            entries=$((entries + 1))
        fi
    done

    # The pinned recovery UKI (UEFI), reachable when a kernel/config update
    # leaves the primary menu broken. It does NOT count toward `entries`:
    # recovery supplements the kernel menu, it never justifies overwriting a
    # good menu with a recovery-only one (the entries==0 guard below).
    if [[ -n $recovery_ok ]]; then
        cat <<EOF
/ShedOS Recovery
    protocol: efi_chainload
    image_path: boot():/EFI/Linux/shedos-recovery.efi

EOF
    fi

    # Verbatim extra entries (e.g. the Windows chainload the installer
    # writes on dual-boot machines). Appended on every render so they
    # survive the wholesale rewrite above.
    extra=${SHEDOS_EXTRA_ENTRIES:-/etc/shedos/limine-extra-entries.conf}
    if [[ -f $extra ]]; then
        echo
        cat "$extra"
    fi
} > "$tmp"

# Never overwrite a working menu with a dead one: if not a single kernel
# image could be placed on a real ESP, keep the last-known-good config.
if (( entries == 0 && ${#esp_img_dirs[@]} > 0 )); then
    echo "render-limine-config: FATAL: no kernel image could be placed on the ESP — keeping the existing boot menu" >&2
    exit 1
fi

if ! install -Dm644 "$tmp" "$LIMINE_CONF"; then
    echo "render-limine-config: FATAL: failed to write $LIMINE_CONF" >&2
    exit 1
fi
echo "render-limine-config: wrote $LIMINE_CONF ($entries entries, timeout=$TIMEOUT, default=${ordered[0]})"

# Mirror the config to each ESP config path LAST — only after every image
# it names is confirmed in place, so the firmware never reads a menu
# pointing at a missing kernel.
for esp in "${esp_conf_paths[@]}"; do
    if _esp_put 644 "$tmp" "$esp"; then
        echo "render-limine-config: mirrored config to $esp"
    else
        failed=1
    fi
done

if (( failed )); then
    echo "render-limine-config: ERROR: one or more ESP writes failed (see FATAL lines above)." >&2
    echo "render-limine-config: the system still boots the entries that ARE present. Free ESP space (e.g. retire an old kernel) and re-run: sudo /usr/lib/shedos/render-limine-config.sh" >&2
    exit 1
fi
