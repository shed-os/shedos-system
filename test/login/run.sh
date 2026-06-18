#!/usr/bin/env bash
# Tests for `shedman login`: status/show/hide round-trip + completion contract.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
login=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman/login

pass=0; fail=0
_ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
_fail() { fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# Point the subcommand at a scratch system.toml via env override so the
# test never touches /etc and never needs sudo.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/system.toml" <<'EOF'
schema = 1

[theme]
palette = "catppuccin-mocha-blue"
EOF
export SHEDOS_SYSTEM_TOML=$tmp/system.toml

out=$("$login" --help-summary 2>/dev/null)
[[ $out == *username* ]] && _ok help-summary || _fail help-summary "got: $out"

out=$("$login" --status 2>/dev/null)
[[ $out == *shown* || $out == *true* ]] && _ok status-default || _fail status-default "got: $out"

"$login" --hide-username >/dev/null 2>&1
grep -q 'show_username = false' "$tmp/system.toml" && _ok hide-writes || _fail hide-writes "no key"
grep -q 'palette = "catppuccin-mocha-blue"' "$tmp/system.toml" && _ok preserves-theme || _fail preserves-theme "theme lost"

out=$("$login" --status 2>/dev/null)
[[ $out == *hidden* || $out == *false* ]] && _ok status-hidden || _fail status-hidden "got: $out"

"$login" --show-username >/dev/null 2>&1
grep -q 'show_username = true' "$tmp/system.toml" && _ok show-writes || _fail show-writes "no key"

"$login" --bogus >/dev/null 2>&1; [[ $? -eq 2 ]] && _ok unknown-exit2 || _fail unknown-exit2 "wrong code"

for flag in --complete-bash --complete-zsh --complete-fish; do
    out=$("$login" "$flag" 2>/dev/null)
    [[ -n $out ]] && _ok "contract$flag" || _fail "contract$flag" "empty"
done

# --- record-last-login pam_exec marker (Task 10) ---
marker=$repo_root/packaging/shedos-system/tree/usr/lib/shedos/record-last-login
export SHEDOS_LAST_LOGIN_FILE=$tmp/last-login
PAM_TYPE=open_session PAM_USER=alice "$marker"
[[ $(cat "$tmp/last-login" 2>/dev/null) == alice ]] && _ok marker-open || _fail marker-open "got: $(cat "$tmp/last-login" 2>/dev/null)"
PAM_TYPE=close_session PAM_USER=bob "$marker"
[[ $(cat "$tmp/last-login") == alice ]] && _ok marker-close-noop || _fail marker-close-noop "overwrote on close"
PAM_TYPE=open_session PAM_USER= "$marker"
[[ $(cat "$tmp/last-login") == alice ]] && _ok marker-empty-noop || _fail marker-empty-noop "wrote empty"

printf 'PASS %d/%d\n' "$pass" $((pass+fail))
[[ $fail -eq 0 ]]
