#!/usr/bin/env bash
# The manual this package ships, and the verbs it ships it for.
#
# man/*.scd is the source; PKGBUILD's prepare() renders it with scdoc. This
# mirrors that render and checks each page came out, opens under `man -l`, and
# carries the NAME, SYNOPSIS and DESCRIPTION headers. A verb page also has to
# cross-reference shedman(1), which is the reader's way back to the dispatcher
# page the rest of the manual links through.
#
# The page list is the directory, not a list kept by hand: a page that nobody
# remembered to add to a list is exactly the page that goes unchecked.
#
# The same goes the other way for the verbs. Every declaration names an
# executable, a man page and the package that owns it, and every executable
# under libexec is declared — the build-time contract check says so about the
# built package, and this says so about the tree, where the fix is cheaper.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
srcdir=$repo_root/man
declsdir=$repo_root/tree/usr/share/shedman/verbs.d
libexec=$repo_root/tree/usr/libexec/shedman

mapfile -t PAGES < <(cd "$srcdir" && printf '%s\n' *.scd | sed 's/\.scd$//')

if ! command -v scdoc >/dev/null 2>&1; then
    echo "SKIP: scdoc not installed; cannot render the .scd sources"
    exit 0
fi

mandir=$(mktemp -d -t shedos-man.XXXXXX)
trap 'rm -rf -- "$mandir"' EXIT

pass=0
fail=0
failures=()

_ok()   { echo "ok: $1"; ((pass++)); }
_fail() { echo "FAIL: $1: $2" >&2; failures+=("$1"); ((fail++)); }

for p in "${PAGES[@]}"; do
    src=$srcdir/$p.scd
    rendered=$mandir/$p

    if scdoc < "$src" > "$rendered" 2>/dev/null; then
        _ok "renders_scdoc_$p"
    else
        _fail "renders_scdoc_$p" "scdoc failed to render $src"
        continue
    fi

    for sec in NAME SYNOPSIS DESCRIPTION; do
        if grep -q "^\.SH $sec" "$rendered"; then
            _ok "section_${sec}_$p"
        else
            _fail "section_${sec}_$p" "no .SH $sec in rendered $p"
        fi
    done

    if command -v man >/dev/null 2>&1; then
        if man -P cat -l "$rendered" >/dev/null 2>&1; then
            _ok "renders_man_$p"
        else
            _fail "renders_man_$p" "man -l failed on rendered $p"
        fi
    fi

    # Verb pages only. The file-format page is not a subcommand and points at
    # the verbs that read the file instead. The cross-reference is checked in
    # the source, where it is one legible string rather than groff escapes.
    if [[ $p == shedman-*.1 ]]; then
        if grep -q '\*shedman\*(1)' "$src"; then
            _ok "xref_$p"
        else
            _fail "xref_$p" "no shedman(1) cross-reference in $src"
        fi
    fi
done

for decl in "$declsdir"/*.toml; do
    name=$(sed -n 's/^name = "\(.*\)"$/\1/p' "$decl")
    page=$(sed -n 's/^man = "\(.*\)"$/\1/p' "$decl")
    owner=$(sed -n 's/^package = "\(.*\)"$/\1/p' "$decl")

    if [[ $name == "$(basename "$decl" .toml)" ]]; then
        _ok "declared_name_$name"
    else
        _fail "declared_name_$(basename "$decl")" "names $name"
    fi
    if [[ -x $libexec/$name ]]; then
        _ok "declared_verb_exists_$name"
    else
        _fail "declared_verb_exists_$name" "no executable at $libexec/$name"
    fi
    if [[ -f $srcdir/$page.scd ]]; then
        _ok "declared_page_exists_$name"
    else
        _fail "declared_page_exists_$name" "no source for $page"
    fi
    if [[ $owner == shedos-system ]]; then
        _ok "declared_owner_$name"
    else
        _fail "declared_owner_$name" "owned by $owner"
    fi
done

for verb in "$libexec"/*; do
    name=$(basename "$verb")
    if [[ -f $declsdir/$name.toml ]]; then
        _ok "verb_declared_$name"
    else
        _fail "verb_declared_$name" "ships with no declaration"
    fi
done

echo
total=$((pass + fail))
if (( fail == 0 )); then
    echo "PASS $pass/$total"
    exit 0
fi
echo "FAIL $fail/$total ($pass passed)"
for f in "${failures[@]}"; do echo "  - $f"; done
exit 1
