#!/usr/bin/env bash
# Guard shell-migrate: chsh only for zsh users, seed only stock or
# absent files, keep everything customized, always disarm.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
tool=$repo_root/tree/usr/lib/shedos/shell-migrate

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

# The stock pair the tool will overwrite, taken from the live /etc/skel that
# the bash package owns — and only if it still hashes to what the tool names,
# because a box whose skel another package has already replaced would hand
# this a file the tool is right to keep and the case would pass on the wrong
# reason. SHEDOS_SM_STOCK_SKEL points at a pristine pair on such a box.
stock_skel=${SHEDOS_SM_STOCK_SKEL:-/etc/skel}
stock_rc=$stock_skel/.bashrc
stock_profile=$stock_skel/.bash_profile
_is_stock() {
    [[ -f $1 ]] && grep -qF "$(sha256sum "$1" | cut -d' ' -f1)" "$tool"
}
if ! _is_stock "$stock_rc" || ! _is_stock "$stock_profile"; then
    echo "shell-migrate: SKIP (this box's /etc/skel is not the stock pair)"
    exit 0
fi

# What the tool seeds from. The files it seeds ship with the desktop package,
# and the tool's contract is the seeding, not their content — so the fixture
# is a skel of its own, which also keeps it reliably unlike the stock pair.
skel=$work/skel
mkdir -p "$skel"
printf '# the shell this box ships\n' > "$skel/.bashrc"
printf '# the profile this box ships\n' > "$skel/.bash_profile"

_run() {
    : > "$work/chsh.log"; : > "$work/systemctl.log"
    PATH="$work/bin:$PATH" \
    SHEDOS_SM_PASSWD="$work/passwd" \
    SHEDOS_SM_SKEL="$skel" \
    SHEDOS_SM_HOME_ROOT="$work/homes" \
        bash "$tool" >"$work/out" 2>&1
}

# Fixture homes: zsh user with stock files, zsh user with a customized
# rc, zsh user with no rc at all, a bash user, root on zsh, and a system
# account on zsh.
mkdir -p "$work/homes/home"/{alice,bob,carol,dave} "$work/homes/root"
cp "$stock_rc" "$work/homes/home/alice/.bashrc"
cp "$stock_profile" "$work/homes/home/alice/.bash_profile"
printf '# my precious customizations\n' > "$work/homes/home/bob/.bashrc"
cat > "$work/passwd" <<EOF
root:x:0:0::/root:/usr/bin/zsh
sysacct:x:998:998::/var/empty:/usr/bin/zsh
alice:x:1000:1000::/home/alice:/usr/bin/zsh
bob:x:1001:1001::/home/bob:/usr/bin/zsh
carol:x:1002:1002::/home/carol:/usr/bin/bash
dave:x:1003:1003::/home/dave:/usr/bin/zsh
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
if diff -q "$skel/.bashrc" "$work/homes/home/dave/.bashrc" >/dev/null; then
    _ok M3b_absent_rc_seeded
else
    _fail M3b_absent_rc_seeded "dave had no rc and did not get one"
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
