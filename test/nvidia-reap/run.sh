#!/usr/bin/env bash
# Guard nvidia-reap: remove the stack only on proof there is no nvidia
# device; mark it explicit where there is one; keep on any doubt.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/nvidia-reap

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }
_summary() {
    echo; echo "nvidia-reap: $pass/$((pass + fail)) passed"
    if (( fail > 0 )); then printf '  %s\n' "${failures[@]}" >&2; exit 1; fi
    exit 0
}

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
        bash "$tool" >"$work/out" 2>&1
}

printf 'nvidia-utils\nlinux-firmware-nvidia\n' > "$work/installed"

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
