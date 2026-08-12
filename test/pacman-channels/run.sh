#!/usr/bin/env bash
# run.sh — tests for _add_shedos_repo in shedos-system.install: the managed
# [shedostest]+[shedos] pair in /etc/pacman.conf. [shedos] must always carry
# the stable channel; [shedostest] carries the canary, sits FIRST (pacman
# prefers the first repo that lists a package), ships enabled on RC installs,
# and a box bitten by the rc1/rc2 channel routing heals on upgrade without
# clobbering a later deliberate opt-out.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
install_file=$repo_root/shedos-system.install

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1" >&2; fail=1; }

# The scriptlet is pure function definitions; source it and drive
# _add_shedos_repo through its test-harness path overrides. The blocks it
# writes come from the library beside it rather than the installed one.
fence=$repo_root/tree/usr/lib/shedos/pacman-fence
export SHEDOS_PACMAN_FENCE=$fence
# shellcheck source=/dev/null
source "$install_file"

# The canonical pair, byte for byte, as it read before there was a library to
# write it. Anything the library changes about this text changes what lands in
# every /etc/pacman.conf on the fleet, so it is pinned rather than described.
read -r -d '' want_pair <<'EOF'
# >>> shedostest <<<
# ShedOS canary channel; RC packages land here before they are promoted
# to the stable channel behind [shedos]. Listed first: pacman prefers the
# first repo that carries a package, so enabling this is what makes an RC
# install track the canary. Enable or comment the three lines below as one
# to opt in or out; RC installs ship it enabled, stable installs commented.
#[shedostest]
#SigLevel = Required DatabaseRequired
#Server = https://repo.shedos.org/test/$arch
# <<< shedostest >>>

# >>> shedos <<<
# Managed by shedos-system; do not edit between these markers.
# Run `pacman -R shedos-system` to remove automatically.
[shedos]
SigLevel = Required DatabaseRequired
Server = https://repo.shedos.org/stable/$arch
# <<< shedos >>>
EOF

if [[ "$(bash "$fence" render canary --commented; echo; bash "$fence" render stable)" == "$want_pair" ]]; then
    _ok "T0 the library writes the block the scriptlet used to write"
else
    _bad "T0 the library writes the block the scriptlet used to write"
    diff <(printf '%s\n' "$want_pair") \
         <(bash "$fence" render canary --commented; echo; bash "$fence" render stable) >&2
fi

if [[ "$(SHEDMAN_CONFIG=/nonexistent bash "$fence" render stable)" \
      == "$(bash "$fence" render stable)" ]]; then
    _ok "T0 no config file changes nothing"
else
    _bad "T0 no config file changes nothing"
fi


td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT

printf 'repo = "mirror"\nrepo-url = "https://mirror.example/stable/$arch"\n' > "$td/cfg.toml"
if SHEDMAN_CONFIG=$td/cfg.toml bash "$fence" render stable \
        | grep -qxF 'Server = https://mirror.example/stable/$arch'; then
    _ok "T0 the channel comes out of the config when one names it"
else
    _bad "T0 the channel comes out of the config when one names it"
fi

_base_conf() {
    cat <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = x86_64

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
}

# Run the function against a fixture; args: <case-dir> [channel]
_run() {
    local dir=$1 channel=${2:-}
    mkdir -p "$dir/state"
    [[ -n $channel ]] && printf '%s\n' "$channel" > "$dir/channel"
    SHEDOS_PACMAN_CONF="$dir/pacman.conf" \
    SHEDOS_CHANNEL_FILE="$dir/channel" \
    SHEDOS_STATE_DIR="$dir/state" \
        _add_shedos_repo
}

_assert_stable_shedos() {
    local conf=$1 case=$2
    if grep -qE '^Server = https://repo\.shedos\.org/stable/\$arch$' \
        <(sed -n '/^# >>> shedos <<<$/,/^# <<< shedos >>>$/p' "$conf"); then
        _ok "$case: [shedos] points at stable"
    else
        _bad "$case: [shedos] does not point at stable"
    fi
}

_assert_testing() {
    local conf=$1 case=$2 want=$3   # want: enabled | disabled
    local block
    block=$(sed -n '/^# >>> shedostest <<<$/,/^# <<< shedostest >>>$/p' "$conf")
    local live=disabled
    grep -qE '^Server = ' <<<"$block" && live=enabled
    # A coherent block never mixes states: header, SigLevel and Server agree.
    local active_lines
    active_lines=$(grep -cE '^(\[shedostest\]|SigLevel|Server)' <<<"$block")
    if [[ $live == "$want" ]] \
        && { [[ $want == disabled && $active_lines -eq 0 ]] \
             || [[ $want == enabled && $active_lines -eq 3 ]]; }; then
        _ok "$case: [shedostest] $want and coherent"
    else
        _bad "$case: [shedostest] wanted $want, got $live ($active_lines active lines)"
    fi
}

_assert_order() {
    local conf=$1 case=$2
    local first
    first=$(grep -nE '^# >>> (shedostest|shedos) <<<$' "$conf" | head -1)
    if [[ $first == *shedostest* ]]; then
        _ok "$case: [shedostest] listed before [shedos]"
    else
        _bad "$case: [shedos] precedes [shedostest]"
    fi
}

_assert_parses() {
    local conf=$1 case=$2
    command -v pacman-conf >/dev/null 2>&1 || { _ok "$case: pacman-conf absent, parse check skipped"; return; }
    if pacman-conf --config "$conf" --repo-list >/dev/null 2>&1; then
        _ok "$case: pacman-conf parses the result"
    else
        _bad "$case: pacman-conf rejects the result"
    fi
}

# T1: fresh RC install (channel=test, no fences) — canary on, stable [shedos].
t1=$td/t1
mkdir -p "$t1"; _base_conf > "$t1/pacman.conf"
_run "$t1" test
_assert_stable_shedos "$t1/pacman.conf" "T1 fresh RC"
_assert_testing "$t1/pacman.conf" "T1 fresh RC" enabled
_assert_order "$t1/pacman.conf" "T1 fresh RC"
_assert_parses "$t1/pacman.conf" "T1 fresh RC"

# T2: fresh stable install (no channel marker) — canary commented.
t2=$td/t2
mkdir -p "$t2"; _base_conf > "$t2/pacman.conf"
_run "$t2"
_assert_stable_shedos "$t2/pacman.conf" "T2 fresh stable"
_assert_testing "$t2/pacman.conf" "T2 fresh stable" disabled
_assert_order "$t2/pacman.conf" "T2 fresh stable"
_assert_parses "$t2/pacman.conf" "T2 fresh stable"

# T3: the bitten rc2 box — [shedos] on the canary URL, commented [shedostest]
# AFTER it (the exact on-disk shape of the bug), channel=test. Heals to spec,
# is idempotent, and a later opt-out sticks across upgrades.
t3=$td/t3
mkdir -p "$t3"
{ _base_conf
  cat <<'EOF'

# >>> shedos <<<
# Managed by shedos-system; do not edit between these markers.
# Run `pacman -R shedos-system` to remove automatically.
[shedos]
SigLevel = Required DatabaseRequired
Server = https://repo.shedos.org/test/$arch
# <<< shedos >>>

# >>> shedostest <<<
# ShedOS canary channel; RC packages land here before reaching
# [shedos]. Uncomment the four lines below to opt in.
#[shedostest]
#SigLevel = Required DatabaseRequired
#Server = https://repo.shedos.org/test/$arch
# <<< shedostest >>>
EOF
} > "$t3/pacman.conf"
_run "$t3" test
_assert_stable_shedos "$t3/pacman.conf" "T3 bitten box heals"
_assert_testing "$t3/pacman.conf" "T3 bitten box heals" enabled
_assert_order "$t3/pacman.conf" "T3 bitten box heals"
_assert_parses "$t3/pacman.conf" "T3 bitten box heals"

cp "$t3/pacman.conf" "$t3/first-run"
_run "$t3" test
if cmp -s "$t3/pacman.conf" "$t3/first-run"; then
    _ok "T3 second run is byte-identical (idempotent)"
else
    _bad "T3 second run drifted"
fi

# Opt out after the heal: comment the three canary lines; the sentinel keeps
# the choice across every later upgrade even with channel=test still baked.
sed -i -E 's|^(\[shedostest\]\|SigLevel = Required DatabaseRequired)$|#\1|; s|^(Server = https://repo\.shedos\.org/test/\$arch)$|#\1|' "$t3/pacman.conf"
_run "$t3" test
_assert_testing "$t3/pacman.conf" "T3 post-heal opt-out sticks" disabled

# T4: half-uncommented [shedostest] (header live, Server commented) — a state
# pacman fatals on — normalizes to fully enabled.
t4=$td/t4
mkdir -p "$t4"
{ _base_conf
  cat <<'EOF'

# >>> shedostest <<<
[shedostest]
#SigLevel = Required DatabaseRequired
#Server = https://repo.shedos.org/test/$arch
# <<< shedostest >>>
EOF
} > "$t4/pacman.conf"
mkdir -p "$t4/state"; : > "$t4/state/.pacman-channels-seeded"
_run "$t4"
_assert_testing "$t4/pacman.conf" "T4 half-uncommented normalizes" enabled
_assert_parses "$t4/pacman.conf" "T4 half-uncommented normalizes"

# T5: a bare [shedos] block with NO blank line before an adjacent fence must
# not swallow it or anything after it.
t5=$td/t5
mkdir -p "$t5"
{ _base_conf
  cat <<'EOF'

[shedos]
SigLevel = Required DatabaseRequired
Server = https://repo.shedos.org/test/$arch
# >>> shedostest <<<
#[shedostest]
#SigLevel = Required DatabaseRequired
#Server = https://repo.shedos.org/test/$arch
# <<< shedostest >>>
[userrepo]
Server = https://example.org/$arch
EOF
} > "$t5/pacman.conf"
_run "$t5"
if grep -q '^\[userrepo\]$' "$t5/pacman.conf"; then
    _ok "T5 user repo after an adjacent fence survives"
else
    _bad "T5 user repo was swallowed by the bare-block strip"
fi
_assert_stable_shedos "$t5/pacman.conf" "T5 bare block replaced"
_assert_testing "$t5/pacman.conf" "T5 bitten bare block heals" enabled

# T6: legacy shedos-testing markers migrate then land as one canonical pair.
t6=$td/t6
mkdir -p "$t6"
{ _base_conf
  cat <<'EOF'

# >>> shedos <<<
[shedos]
SigLevel = Required DatabaseRequired
Server = https://repo.shedos.org/$arch
# <<< shedos >>>

# >>> shedos-testing <<<
#[shedos-testing]
#SigLevel = Required DatabaseRequired
#Server = https://repo.shedos.org/$arch-testing
# <<< shedos-testing >>>
EOF
} > "$t6/pacman.conf"
sed -i \
    -e 's|^# >>> shedos-testing <<<$|# >>> shedostest <<<|' \
    -e 's|^# <<< shedos-testing >>>$|# <<< shedostest >>>|' \
    -e 's|^\(#\?\)\[shedos-testing\]$|\1[shedostest]|' \
    "$t6/pacman.conf"
_run "$t6"
if [[ $(grep -c '^# >>> shedostest <<<$' "$t6/pacman.conf") -eq 1 \
   && $(grep -c '^# >>> shedos <<<$' "$t6/pacman.conf") -eq 1 ]]; then
    _ok "T6 legacy markers converge to one canonical pair"
else
    _bad "T6 duplicate fences after legacy migration"
fi
_assert_stable_shedos "$t6/pacman.conf" "T6 legacy box"
_assert_order "$t6/pacman.conf" "T6 legacy box"

if (( fail )); then
    echo "pacman-channels: FAILURES" >&2
    exit 1
fi
echo "pacman-channels: all tests passed"
