#!/usr/bin/env bash
# Guard the `shedman encrypt` subcommand's preflight: it must refuse to touch a disk
# that isn't plain btrfs, that's on low battery, or that's too full for the 32M
# header tail — and force a typed data-loss acknowledgement before arming. No
# byte is mutated here; cryptsetup/findmnt/sgdisk/systemctl are PATH-stubbed so
# the gauntlet runs unprivileged in CI and secrets are asserted off argv.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
verb=$repo_root/packaging/shedos-system/tree/usr/libexec/shedman/encrypt

pass=0; fail=0; failures=()
_ok()   { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; failures+=("$1"); fail=$((fail + 1)); }

# A sandbox of PATH-stubbed binaries. cryptsetup logs argv to $d/cryptsetup.log
# and, for `isLuks`, exits $STUB_ISLUKS (default 1 = not LUKS). findmnt answers
# from $STUB_ROOTDEV / $STUB_FSTYPE / $STUB_AVAIL. id -u reports $STUB_UID.
_mk_sandbox() {
    local d; d=$(mktemp -d); mkdir -p "$d/bin"
    cat > "$d/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/cryptsetup.log"
[[ \$1 == isLuks ]] && exit \${STUB_ISLUKS:-1}
exit 0
EOF
    cat > "$d/bin/findmnt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/findmnt.log"
src=\${STUB_ROOTDEV:-/dev/sda2}
case "\$*" in
    *SOURCE*) printf '%s\n' "\$src" ;;
    *FSTYPE*) printf '%s\n' "\${STUB_FSTYPE:-btrfs}" ;;
    *AVAIL*)  printf '%s\n' "\${STUB_AVAIL:-107374182400}" ;;
esac
exit 0
EOF
    for b in sgdisk systemctl; do
        cat > "$d/bin/$b" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/$b.log"
exit 0
EOF
    done
    cat > "$d/bin/id" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
    chmod +x "$d/bin/"*
    printf '%s\n' "$d"
}

# Run the verb directly in the sandbox (for the dispatch/help cases).
_run() {
    local d=$1; shift
    PATH="$d/bin:$PATH" \
    SHEDMAN_ENCRYPT_POWER_DIR="${POWER_DIR:-$d/power}" \
    SHEDMAN_ENCRYPT_MEMINFO="${MEMINFO:-$d/meminfo}" \
        bash "$verb" "$@"
}

# Source the verb in a sandbox subshell and run one function. Passing $verb as $1
# (not $0) keeps BASH_SOURCE[0] != $0 so the verb's source guard fires and the
# dispatch does NOT run — only the functions get defined.
_srun() {  # $1=dir $2=fn-call-string ; extra env via the caller's prefix
    local d=$1 call=$2
    PATH="$d/bin:$PATH" bash -c "source \"\$1\"; $call" _ "$verb"
}

# Seed a power-supply tree: $1=dir $2=type (Mains|Battery) $3=online/capacity.
_seed_power() {
    local d=$1 type=$2 val=$3
    local p="$d/power/BAT0"
    [[ $type == Mains ]] && p="$d/power/ADP0"
    mkdir -p "$p"; printf '%s\n' "$type" > "$p/type"
    if [[ $type == Mains ]]; then printf '%s\n' "$val" > "$p/online"
    else printf '%s\n' "$val" > "$p/capacity"; fi
}

# C1: --help exits 0 with the usage banner.
d=$(_mk_sandbox)
out=$(_run "$d" --help); rc=$?
if [[ $rc -eq 0 && $out == *"Usage: sudo shedman encrypt"* ]]; then _ok C1_help; else _fail C1_help "rc=$rc"; fi

# C2: an unknown subcommand exits 2.
_run "$d" frobnicate >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then _ok C2_unknown; else _fail C2_unknown "rc=$rc"; fi

# C3: completion lists the flags so the shell can offer them.
out=$(_run "$d" --complete-bash)
if [[ $out == *"--status"* && $out == *"--resume"* && $out == *"--yes"* ]]; then _ok C3_complete; else _fail C3_complete "$out"; fi

# C4: --help-summary is a single line for the umbrella `shedman` help.
out=$(_run "$d" --help-summary); rc=$?
if [[ $rc -eq 0 && $out == *encrypt* ]]; then _ok C4_summary; else _fail C4_summary "rc=$rc $out"; fi

# P1: the root device is read from findmnt SOURCE.
d=$(_mk_sandbox)
out=$(STUB_ROOTDEV=/dev/nvme0n1p2 _srun "$d" '_preflight_root_device')
if [[ $out == /dev/nvme0n1p2 ]]; then _ok P1_rootdev; else _fail P1_rootdev "$out"; fi

# P2: a plain btrfs root that is NOT LUKS passes (rc 0) and runs `isLuks <dev>`.
d=$(_mk_sandbox)
STUB_FSTYPE=btrfs STUB_ISLUKS=1 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2'; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'isLuks /dev/sda2' "$d/cryptsetup.log" 2>/dev/null; then _ok P2_btrfs_plain; else _fail P2_btrfs_plain "rc=$rc $(cat "$d/cryptsetup.log" 2>/dev/null)"; fi

# P3: an already-LUKS root is refused (rc 1, names the device).
d=$(_mk_sandbox)
out=$(STUB_FSTYPE=btrfs STUB_ISLUKS=0 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *"already encrypted"* ]]; then _ok P3_already_luks; else _fail P3_already_luks "rc=$rc $out"; fi

# P4: a non-btrfs root (ext4) is refused cleanly — out of scope by design.
d=$(_mk_sandbox)
out=$(STUB_FSTYPE=ext4 STUB_ISLUKS=1 _srun "$d" '_preflight_assert_btrfs_plain /dev/sda2' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *btrfs* ]]; then _ok P4_non_btrfs; else _fail P4_non_btrfs "rc=$rc $out"; fi

# PW1: on AC (Mains online=1) the gate passes.
d=$(_mk_sandbox); _seed_power "$d" Mains 1
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW1_ac_ok; else _fail PW1_ac_ok "rc=$rc"; fi

# PW2: on battery above 50% the gate passes.
d=$(_mk_sandbox); _seed_power "$d" Battery 73
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW2_batt_high_ok; else _fail PW2_batt_high_ok "rc=$rc"; fi

# PW3: on battery at 30% with no AC the gate refuses (rc 1).
d=$(_mk_sandbox); _seed_power "$d" Battery 30
out=$(SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" '_preflight_power_ok' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *power* ]]; then _ok PW3_batt_low_refused; else _fail PW3_batt_low_refused "rc=$rc $out"; fi

# PW4: the override flag bypasses the gate even at 30%.
d=$(_mk_sandbox); _seed_power "$d" Battery 30
SHEDMAN_ENCRYPT_POWER_DIR="$d/power" _srun "$d" 'FORCE_NO_AC=1 _preflight_power_ok'; rc=$?
if [[ $rc -eq 0 ]]; then _ok PW4_override; else _fail PW4_override "rc=$rc"; fi

# SP1: 100 GiB free easily covers the 32M tail, root-only.
d=$(_mk_sandbox)
STUB_AVAIL=107374182400 _srun "$d" '_preflight_space_ok no'; rc=$?
if [[ $rc -eq 0 ]]; then _ok SP1_root_ok; else _fail SP1_root_ok "rc=$rc"; fi

# SP2: only 8 MiB free can't fit the 32M tail — refuse, root-only.
d=$(_mk_sandbox)
out=$(STUB_AVAIL=8388608 _srun "$d" '_preflight_space_ok no' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *space* ]]; then _ok SP2_root_tight; else _fail SP2_root_tight "rc=$rc $out"; fi

# SP3: with swap in scope the requirement is RAM-size + 32M; 4 GiB RAM + 33 MiB free fails.
d=$(_mk_sandbox); printf 'MemTotal:        4194304 kB\n' > "$d/meminfo"
out=$(STUB_AVAIL=34603008 SHEDMAN_ENCRYPT_MEMINFO="$d/meminfo" _srun "$d" '_preflight_space_ok yes' 2>&1); rc=$?
if [[ $rc -eq 1 && $out == *swap* ]]; then _ok SP3_swap_tight; else _fail SP3_swap_tight "rc=$rc $out"; fi

# SP4: with swap in scope and RAM-size + 32M + headroom free, it passes.
d=$(_mk_sandbox); printf 'MemTotal:        4194304 kB\n' > "$d/meminfo"
STUB_AVAIL=8589934592 SHEDMAN_ENCRYPT_MEMINFO="$d/meminfo" _srun "$d" '_preflight_space_ok yes'; rc=$?
if [[ $rc -eq 0 ]]; then _ok SP4_swap_ok; else _fail SP4_swap_ok "rc=$rc"; fi

# DL1: typing the exact acknowledgement phrase passes (rc 0).
d=$(_mk_sandbox)
printf 'encrypt this disk\n' | _srun "$d" '_dataloss_ack'; rc=$?
if [[ $rc -eq 0 ]]; then _ok DL1_exact; else _fail DL1_exact "rc=$rc"; fi

# DL2: a wrong phrase (a bare "yes") is refused (rc 1).
d=$(_mk_sandbox)
out=$(printf 'yes\n' | _srun "$d" '_dataloss_ack' 2>&1); rc=$?
if [[ $rc -eq 1 ]]; then _ok DL2_wrong_refused; else _fail DL2_wrong_refused "rc=$rc $out"; fi

# DL3: --yes (ASSUME_YES) bypasses the prompt for an unattended run.
d=$(_mk_sandbox)
_srun "$d" 'ASSUME_YES=1 _dataloss_ack' </dev/null; rc=$?
if [[ $rc -eq 0 ]]; then _ok DL3_assume_yes; else _fail DL3_assume_yes "rc=$rc"; fi

# DL4: the prompt shown to a human spells out that there is no backup.
d=$(_mk_sandbox)
out=$(printf 'encrypt this disk\n' | _srun "$d" '_dataloss_ack' 2>&1)
if [[ $out == *"no backup"* || $out == *"cannot be undone"* ]]; then _ok DL4_warns; else _fail DL4_warns "$out"; fi

# S1: the captured passphrase never reaches a tool's argv. Read a secret, run a
# tool, then scan every stub log for it.
d=$(_mk_sandbox)
# shellcheck disable=SC2016  # the call string is evaluated inside bash -c, not here
printf 'hunter2-secret\n' | _srun "$d" 'pw=$(_read_secret "p: "); cryptsetup isLuks /dev/sda2 >/dev/null 2>&1 || true'
if grep -q 'hunter2-secret' "$d"/*.log 2>/dev/null; then _fail S1_no_secret_argv "secret on argv"; else _ok S1_no_secret_argv; fi

total=$((pass + fail)); echo; echo "encrypt: $pass/$total passed"; (( fail == 0 ))
