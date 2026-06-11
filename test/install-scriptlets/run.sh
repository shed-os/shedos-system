#!/usr/bin/env bash
# run.sh — tests for the embedded migration helpers in
# shedos-system.install. The cmdline-baseline backfill once shredded
# comma'd kernel tokens (console=ttyS0,115200 became two items)
# because the shell passed token lists as CSV; this suite extracts the
# embedded Python verbatim from the .install and drives it directly.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
install_file=$repo_root/packaging/shedos-system/shedos-system.install

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1" >&2; fail=1; }

# Extract the baseline-editing Python between the heredoc markers.
py=$(awk '/add_nl.*rem_nl.*<<.PY./{flag=1; next} /^PY$/{flag=0} flag' "$install_file")
if [[ -z $py ]]; then
    _bad "could not extract the embedded Python from $install_file"
    exit 1
fi

td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
baseline=$td/cmdline.baseline.json

# T1: comma'd tokens survive whole, removals apply, adds land.
cat > "$baseline" <<'EOF'
{"items": [["console=tty1"], ["quiet"]]}
EOF
add=$(printf '%s\n' "console=ttyS0,115200" "splash")
rem=$(printf '%s\n' "console=tty1")
python3 -c "$py" "$baseline" "$add" "$rem"
out=$(python3 -c "
import json,sys
items = sorted(t[0] for t in json.load(open('$baseline'))['items'])
print('|'.join(items))")
expect="console=ttyS0,115200|quiet|splash"
if [[ $out == "$expect" ]]; then
    _ok "T1_comma_tokens_survive ($out)"
else
    _bad "T1_comma_tokens_survive: got '$out', want '$expect'"
fi

# T2: a token in both lists ends up present (removals run first).
cat > "$baseline" <<'EOF'
{"items": [["nowatchdog"]]}
EOF
add=$(printf '%s\n' "nowatchdog")
rem=$(printf '%s\n' "nowatchdog")
python3 -c "$py" "$baseline" "$add" "$rem"
out=$(python3 -c "
import json
print(len(json.load(open('$baseline'))['items']))")
if [[ $out == 1 ]]; then
    _ok "T2_add_wins_over_remove"
else
    _bad "T2_add_wins_over_remove: items=$out, want 1"
fi

# T3: no-op input leaves the file byte-identical (atomic-write skip).
cat > "$baseline" <<'EOF'
{"items": [["quiet"]]}
EOF
before=$(sha256sum "$baseline")
python3 -c "$py" "$baseline" "$(printf 'quiet\n')" ""
after=$(sha256sum "$baseline")
if [[ $before == "$after" ]]; then
    _ok "T3_noop_does_not_rewrite"
else
    _bad "T3_noop_does_not_rewrite: file changed on no-op"
fi

if (( fail )); then echo "Summary: FAILED"; exit 1; fi
echo "Summary: 3 passed, 0 failed"
