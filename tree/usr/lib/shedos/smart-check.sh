#!/bin/bash
# Daily SMART verdict cache for shedman health (which runs
# unprivileged and can't open the disks itself). One JSON object per
# physical disk; "failed" key only present on a failing drive.
set -u
out=${1:-/var/lib/shedos/smart-health.json}
tmp=$(mktemp)
{
    echo '{"disks":['
    first=1
    while read -r name type; do
        [[ $type == disk ]] || continue
        verdict=$(smartctl -H "/dev/$name" 2>/dev/null \
            | sed -n 's/^SMART overall-health self-assessment test result: //p')
        [[ -z $verdict ]] && verdict=$(smartctl -H "/dev/$name" 2>/dev/null \
            | sed -n 's/^SMART Health Status: //p')
        [[ -z $verdict ]] && continue
        (( first )) || echo ','
        first=0
        if [[ $verdict == PASSED || $verdict == OK ]]; then
            printf '{"disk":"%s","status":"passed"}' "$name"
        else
            printf '{"disk":"%s","status":"%s","failed":"%s"}' "$name" "$verdict" "$name"
        fi
    done < <(lsblk -dno NAME,TYPE 2>/dev/null)
    echo
    echo ']}'
} > "$tmp"
install -Dm644 "$tmp" "$out"
rm -f "$tmp"
