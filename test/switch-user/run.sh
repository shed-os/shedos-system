#!/usr/bin/env bash
# Validates the switch-user helper's username guarding and the polkit
# action/rule shape. No privileged action is taken — the helper runs in
# dry-run mode against a fixture passwd.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
sys=$repo_root/packaging/shedos-system/tree
helper=$sys/usr/lib/shedos/switch-user
rule=$sys/usr/share/polkit-1/rules.d/49-shedos-switch-user.rules
policy=$sys/usr/share/polkit-1/actions/org.shedos.switch-user.policy

pass=0; fail=0
_ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
_fail() { fail=$((fail+1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export SHEDOS_SWITCH_USER_DRYRUN=1
export SHEDOS_PASSWD=$tmp/passwd
cat >"$tmp/passwd" <<'EOF'
root:x:0:0::/root:/bin/bash
shedos:x:1000:1000::/home/shedos:/usr/bin/zsh
svc:x:999:999::/:/usr/bin/nologin
alice:x:1001:1001::/home/alice:/bin/bash
EOF

bash "$helper" alice >/dev/null 2>&1 && _ok accepts-real-user || _fail accepts-real-user "rejected alice"
bash "$helper" 'alice; rm -rf /' >/dev/null 2>&1 && _fail rejects-injection "accepted injection" || _ok rejects-injection
bash "$helper" nonexistent >/dev/null 2>&1 && _fail rejects-unknown "accepted unknown" || _ok rejects-unknown
bash "$helper" shedos >/dev/null 2>&1 && _fail rejects-shedos "accepted shedos" || _ok rejects-shedos
bash "$helper" svc >/dev/null 2>&1 && _fail rejects-service "accepted nologin user" || _ok rejects-service
bash "$helper" >/dev/null 2>&1 && _fail rejects-missing-arg "accepted no arg" || _ok rejects-missing-arg

grep -q 'org.shedos.switch-user' "$rule" && _ok rule-action || _fail rule-action "action id missing"
grep -q 'subject.local' "$rule" && grep -q 'subject.active' "$rule" && _ok rule-scope || _fail rule-scope "no local+active seat scope"
grep -q 'org.shedos.switch-user' "$policy" && _ok policy-action || _fail policy-action "action id missing"
grep -q '/usr/lib/shedos/switch-user' "$policy" && _ok policy-exec-path || _fail policy-exec-path "exec.path annotation missing"

# Teardown: the helper runs the supervisor in a collectible transient unit.
grep -q 'systemd-run' "$helper" && grep -q -- '--collect' "$helper" && _ok collectible-unit || _fail collectible-unit "not a collectible transient unit"
grep -q 'switch-greetd-once' "$helper" && _ok runs-supervisor || _fail runs-supervisor "helper does not run the supervisor"
[[ -x $sys/usr/lib/shedos/switch-greetd-once ]] && _ok supervisor-present || _fail supervisor-present "supervisor missing or not executable"

printf 'PASS %d/%d\n' "$pass" $((pass+fail))
[[ $fail -eq 0 ]]
