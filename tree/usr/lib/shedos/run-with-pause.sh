#!/bin/bash
# Run a command and wait for the user before closing the terminal.
# Used by the waybar update + conflict-review on-click handlers so a
# failed run is still readable instead of vanishing the moment kitty's
# child exits.

if (( $# == 0 )); then
    echo "usage: $0 <command> [args…]" >&2
    exit 2
fi

"$@"
rc=$?

echo
if (( rc == 0 )); then
    echo "Completed."
else
    echo "Failed (exit $rc)."
fi
read -n1 -rsp "Press any key to close… "
echo

exit $rc
