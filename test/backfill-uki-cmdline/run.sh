#!/usr/bin/env bash
# The cmdline backfill is exercised by a pytest module rather than a shell
# suite because that is what it was written as; rewriting it would have cost
# the history the carve kept. This is the wrapper the runner discovers.
#
# A missing pytest is a failure, not a bow-out: a suite that quietly declines
# to run is how a package ships with its own tests never having run.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! python3 -c 'import pytest' 2>/dev/null; then
    echo "pytest is not installed; the backfill tests cannot run" >&2
    exit 2
fi

exec python3 -m pytest "$here" -q
