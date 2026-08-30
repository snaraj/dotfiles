#!/usr/bin/env bash
# Regression fixture for the destructive-command library boundary
# (Codex cybersecurity review, dotfiles PR: rm/rename must act on library
# NAMES only — `..`, absolute paths, nested paths, and symlinked parents must
# all be refused). Runs entirely in a throwaway directory; exits 0 on pass.
set -u
THEME="$(cd "$(dirname "$0")" && pwd)/theme.sh"
fails=0
check() { # $1 description, $2 expected exit (0=ok nonzero=refused), then cmd…
    local desc="$1" want="$2"; shift 2
    if "$@" >/dev/null 2>&1; then got=0; else got=1; fi
    if [ "$want" = "0" ] && [ "$got" = "0" ]; then echo "PASS  $desc"
    elif [ "$want" != "0" ] && [ "$got" != "0" ]; then echo "PASS  $desc"
    else echo "FAIL  $desc (exit $got, wanted ${want})"; fails=$((fails + 1)); fi
}

fixture=$(mktemp -d -t theme-boundary) || exit 1
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/library" "$fixture/outside"
printf 'x' >"$fixture/library/in-lib.jpg"
printf 'x' >"$fixture/library/renameme.jpg"
printf 'x' >"$fixture/outside/delete-victim.jpg"
printf 'x' >"$fixture/outside/rename-victim.jpg"
ln -s "$fixture/outside/delete-victim.jpg" "$fixture/library/escape.jpg"

run() { WALLPAPER_DIR="$1" THEME_NO_APPLY=1 bash "$THEME" "${@:2}"; }

check "in-library rm succeeds"                 0 run "$fixture/library" rm in-lib.jpg
check "in-library rename succeeds"             0 run "$fixture/library" rename renameme renamed-fine
check "rm refuses ..-traversal"                1 run "$fixture/library" rm ../outside/delete-victim.jpg
check "rename refuses ..-traversal"            1 run "$fixture/library" rename ../outside/rename-victim.jpg moved
check "rm refuses absolute path"               1 run "$fixture/library" rm "$fixture/outside/delete-victim.jpg"
check "rm refuses nested path"                 1 run "$fixture/library" rm outside/delete-victim.jpg
# A symlink INSIDE the library pointing outside: rm may remove the LINK, but
# the target beyond the boundary must survive (asserted below).
check "rm of an in-library symlink succeeds"   0 run "$fixture/library" rm escape.jpg
[ -f "$fixture/outside/delete-victim.jpg" ] && echo "PASS  outside delete-victim untouched" ||
    { echo "FAIL  outside delete-victim was deleted"; fails=$((fails + 1)); }
[ -f "$fixture/outside/rename-victim.jpg" ] && echo "PASS  outside rename-victim untouched" ||
    { echo "FAIL  outside rename-victim was renamed"; fails=$((fails + 1)); }

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILURES"
exit "$fails"
