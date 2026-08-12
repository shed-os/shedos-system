#!/usr/bin/env bash
# Guard nvidia-reap: remove the stack only on proof there is no nvidia
# device; mark it explicit where there is one; keep on any doubt.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/tree/usr/lib/shedos/nvidia-reap
stack_file=$repo_root/tree/usr/share/shedos/nvidia-driver-stack

# The installer names the same set when it strips the stack off a box with no
# nvidia card, and it has no way to read this package's tree at build time, so
# the list is written down once here and generated there. These thirteen are
# what both carried before there was one file; the firmware package is not one
# of them because the installer decides separately whether to keep it.
want_stack=(
    nvidia-open-dkms nvidia-utils nvidia-settings nvidia-prime
    libva-nvidia-driver nvidia-container-toolkit libnvidia-container
    libxnvctrl egl-wayland egl-wayland2 egl-gbm egl-x11 eglexternalplatform
)

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }
_summary() {
    echo; echo "nvidia-reap: $pass/$((pass + fail)) passed"
    if (( fail > 0 )); then printf '  %s\n' "${failures[@]}" >&2; exit 1; fi
    exit 0
}

if [[ -f $stack_file ]] \
   && [[ "$(grep -vE '^[[:space:]]*(#|$)' "$stack_file")" == "$(printf '%s\n' "${want_stack[@]}")" ]]; then
    _ok N1_one_file_holds_the_driver_list
else
    _fail N1_one_file_holds_the_driver_list "$stack_file missing or not the thirteen"
fi

if grep -qE '(nvidia-open-dkms|egl-wayland|libxnvctrl)' "$tool"; then
    _fail N2_the_tool_keeps_no_list_of_its_own "package names are still spelled out in $tool"
else
    _ok N2_the_tool_keeps_no_list_of_its_own
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# pacman stub: -Qq answers from $work/installed; every call is logged.
cat > "$work/bin/pacman" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/pacman.log"
if [[ \$1 == -Qq ]]; then grep -qx "\$2" "$work/installed" 2>/dev/null; exit \$?; fi
exit 0
EOF
cat > "$work/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/systemctl.log"
EOF
chmod +x "$work/bin"/*

_gpu() {  # $1=vendor written into a single fake PCI device
    rm -rf "$work/sys"; mkdir -p "$work/sys/0000:00:02.0"
    printf '%s\n' "$1" > "$work/sys/0000:00:02.0/vendor"
}

_run() {
    : > "$work/pacman.log"; : > "$work/systemctl.log"
    PATH="$work/bin:$PATH" SHEDOS_NVIDIA_SYS="$work/sys" \
    SHEDOS_NVIDIA_STACK_FILE="${1:-$stack_file}" \
        bash "$tool" >"$work/out" 2>&1
}

# A name only the file could have supplied proves the tool reads it.
printf '# a fixture list\nnvidia-invented\n' > "$work/stack"
printf 'nvidia-invented\n' > "$work/installed"
_gpu 0x8086; _run "$work/stack"
if grep -q '^-Rns --noconfirm nvidia-invented$' "$work/pacman.log"; then
    _ok N3_the_tool_reaps_what_the_file_names
else
    _fail N3_the_tool_reaps_what_the_file_names "$(cat "$work/pacman.log")"
fi

printf 'nvidia-utils\nlinux-firmware-nvidia\n' > "$work/installed"
_gpu 0x8086; _run "$work/nosuch"
if ! grep -qE 'Rns|asexplicit' "$work/pacman.log" \
   && ! grep -q 'disable shedos-nvidia-reap' "$work/systemctl.log"; then
    _ok N4_no_list_reaps_nothing_and_stays_armed
else
    _fail N4_no_list_reaps_nothing_and_stays_armed "$(cat "$work/pacman.log" "$work/systemctl.log")"
fi


_gpu 0x8086; _run
if grep -q '^-Rns --noconfirm nvidia-utils linux-firmware-nvidia$' "$work/pacman.log"; then
    _ok R1_no_nvidia_removes_the_installed_subset
else
    _fail R1_no_nvidia_removes_the_installed_subset "$(grep Rns "$work/pacman.log" || echo 'no -Rns call')"
fi

_gpu 0x10de; _run
if grep -q '^-D --asexplicit nvidia-utils linux-firmware-nvidia$' "$work/pacman.log" \
   && ! grep -q Rns "$work/pacman.log"; then
    _ok R2_nvidia_present_marks_explicit_and_removes_nothing
else
    _fail R2_nvidia_present_marks_explicit_and_removes_nothing "$(cat "$work/pacman.log")"
fi

rm -rf "$work/sys"; mkdir -p "$work/sys"; _run
if ! grep -q Rns "$work/pacman.log"; then
    _ok R3_empty_sysfs_is_not_proof_and_keeps_everything
else
    _fail R3_empty_sysfs_is_not_proof_and_keeps_everything "removed on no evidence"
fi

: > "$work/installed"; _gpu 0x8086; _run
if ! grep -qE 'Rns|asexplicit' "$work/pacman.log" \
   && grep -q 'disable shedos-nvidia-reap' "$work/systemctl.log"; then
    _ok R4_nothing_installed_just_disarms
else
    _fail R4_nothing_installed_just_disarms "$(cat "$work/pacman.log" "$work/systemctl.log")"
fi

printf 'nvidia-utils\n' > "$work/installed"; _gpu 0x8086; _run
if grep -q 'disable shedos-nvidia-reap' "$work/systemctl.log"; then
    _ok R5_disarms_after_acting
else
    _fail R5_disarms_after_acting "unit never disabled"
fi

_summary
