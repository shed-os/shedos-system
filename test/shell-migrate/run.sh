#!/usr/bin/env bash
# Guard shell-migrate: chsh only for zsh users, seed only stock or
# absent files, keep everything customized, always disarm.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/shell-migrate
skel=$repo_root/packaging/shedos-hyprland/tree/etc/skel

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }
_summary() {
    echo; echo "shell-migrate: $pass/$((pass + fail)) passed"
    if (( fail > 0 )); then printf '  %s\n' "${failures[@]}" >&2; exit 1; fi
    exit 0
}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/chsh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/chsh.log"
EOF
cat > "$work/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/systemctl.log"
EOF
chmod +x "$work/bin"/*

# The stock Arch pair, byte-identical to what the hashes in the tool
# name; taken from the live /etc/skel, which the bash package owns.
stock_rc=/etc/skel/.bashrc
stock_profile=/etc/skel/.bash_profile
[[ -f $stock_rc && -f $stock_profile ]] || { echo "shell-migrate: SKIP (no stock skel to compare)"; exit 0; }

_run() {
    : > "$work/chsh.log"; : > "$work/systemctl.log"
    PATH="$work/bin:$PATH" \
    SHEDOS_SM_PASSWD="$work/passwd" \
    SHEDOS_SM_SKEL="$skel" \
    SHEDOS_SM_HOME_ROOT="$work/homes" \
        bash "$tool" >"$work/out" 2>&1
}

# Fixture homes: zsh user with stock files, zsh user with a customized
# rc, a bash user, root on zsh, and a system account on zsh.
mkdir -p "$work/homes/home/alice" "$work/homes/home/bob" "$work/homes/home/carol" "$work/homes/root"
cp "$stock_rc" "$work/homes/home/alice/.bashrc"
cp "$stock_profile" "$work/homes/home/alice/.bash_profile"
printf '# my precious customizations\n' > "$work/homes/home/bob/.bashrc"
cat > "$work/passwd" <<EOF
root:x:0:0::/root:/usr/bin/zsh
sysacct:x:998:998::/var/empty:/usr/bin/zsh
alice:x:1000:1000::/home/alice:/usr/bin/zsh
bob:x:1001:1001::/home/bob:/usr/bin/zsh
carol:x:1002:1002::/home/carol:/usr/bin/bash
EOF
_run

if grep -qx -- '-s /usr/bin/bash alice' "$work/chsh.log" \
   && grep -qx -- '-s /usr/bin/bash bob' "$work/chsh.log" \
   && grep -qx -- '-s /usr/bin/bash root' "$work/chsh.log"; then
    _ok M1_zsh_users_and_root_migrated
else
    _fail M1_zsh_users_and_root_migrated "$(cat "$work/chsh.log")"
fi
if ! grep -q 'carol\|sysacct' "$work/chsh.log"; then
    _ok M2_bash_user_and_system_account_untouched
else
    _fail M2_bash_user_and_system_account_untouched "$(cat "$work/chsh.log")"
fi
if diff -q "$skel/.bashrc" "$work/homes/home/alice/.bashrc" >/dev/null; then
    _ok M3_stock_rc_replaced_with_the_shipped_one
else
    _fail M3_stock_rc_replaced_with_the_shipped_one "alice's rc not seeded"
fi
if [[ $(cat "$work/homes/home/bob/.bashrc") == '# my precious customizations' ]]; then
    _ok M4_customized_rc_kept
else
    _fail M4_customized_rc_kept "bob's rc was overwritten"
fi
if [[ -f $work/homes/home/carol/.bashrc ]]; then
    _fail M5_non_migrated_home_untouched "carol gained files"
else
    _ok M5_non_migrated_home_untouched
fi
if grep -q 'disable shedos-shell-migrate' "$work/systemctl.log"; then
    _ok M6_disarms
else
    _fail M6_disarms "unit never disabled"
fi

# A failing chsh leaves the user alone and never blocks the rest.
cat > "$work/bin/chsh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/chsh.log"
exit 1
EOF
cp "$stock_rc" "$work/homes/home/alice/.bashrc"
_run
if grep -q 'left on zsh' "$work/out" && diff -q "$stock_rc" "$work/homes/home/alice/.bashrc" >/dev/null; then
    _ok M7_chsh_failure_keeps_the_user_intact
else
    _fail M7_chsh_failure_keeps_the_user_intact "$(tail -3 "$work/out")"
fi

_summary
