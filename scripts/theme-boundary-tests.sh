#!/usr/bin/env bash
# Regression fixture for theme.sh's destructive-command safety
# (Codex cybersecurity review, dotfiles PR):
#   - rm/rename act on library NAMES only: `..`, absolute paths, nested paths,
#     and out-of-library symlink targets are refused, victims untouched;
#   - positive cases assert the MUTATION happened, not just exit 0, so a
#     neutered `rm`/`mv` in production code turns this fixture red;
#   - an unknown trailing option aborts BEFORE any side effect;
#   - transformed-image runs leave no scratch file behind, on success or
#     failure;
#   - the unsplash network boundary, against a deterministic curl stub:
#     exact-HTTPS-host and slug-charset validation refuse lookalike hosts and
#     glob payloads BEFORE curl, one command makes one authenticated API
#     request with globbing off, the key never enters argv, and a hostile
#     search query travels as one --data-urlencode literal;
#   - the credential boundary: the Access Key is only ever sent to
#     api.unsplash.com — a photo description carrying tab/newline (the
#     field-shift exploit) and a malicious download_location both leave the
#     authenticated report on-host or unsent, while a clean photo's report
#     still fires exactly once.
# Runs entirely in a throwaway directory; exits 0 on pass.
set -u
THEME="$(cd "$(dirname "$0")" && pwd)/theme.sh"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

check() { # $1 description, $2 expected exit (0=ok nonzero=refused), then cmd…
    local desc="$1" want="$2" got
    shift 2
    if "$@" >/dev/null 2>&1; then got=0; else got=1; fi
    if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" != 0 ] && [ "$got" != 0 ]; }; then
        pass "$desc"
    else
        fail "$desc (exit $got, wanted $want)"
    fi
}

exists() { # $1 description, $2 yes|no, $3 path
    if [ "$2" = yes ] && [ -e "$3" ]; then pass "$1"
    elif [ "$2" = no ] && [ ! -e "$3" ]; then pass "$1"
    else fail "$1"; fi
}

fixture=$(mktemp -d -t theme-boundary) || exit 1
trap 'rm -rf "$fixture"' EXIT
lib="$fixture/library"
out="$fixture/outside"
mkdir -p "$lib" "$out" "$fixture/tmpdir"
printf 'x' >"$lib/in-lib.jpg"
printf 'x' >"$lib/renameme.jpg"
printf 'x' >"$lib/keepme.jpg"
printf 'x' >"$out/delete-victim.jpg"
printf 'x' >"$out/rename-victim.jpg"
ln -s "$out/delete-victim.jpg" "$lib/escape.jpg"
# A real 1x1 PNG so sips can transform it (scratch-leak coverage).
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' |
    base64 -d >"$lib/tiny.png"
printf 'not an image' >"$lib/broken.jpg"

# shellcheck disable=SC2317,SC2329  # run is reached indirectly via check()'s "$@"
run() { WALLPAPER_DIR="$1" THEME_NO_APPLY=1 TMPDIR="$fixture/tmpdir" bash "$THEME" "${@:2}"; }

# --- positive destructive ops must MUTATE, not merely exit 0 ---------------
check  "in-library rm succeeds"                0 run "$lib" rm in-lib.jpg
exists "in-library rm really deleted"          no "$lib/in-lib.jpg"
check  "in-library rename succeeds"            0 run "$lib" rename renameme renamed-fine
exists "rename source gone"                    no "$lib/renameme.jpg"
exists "rename destination exists"             yes "$lib/renamed-fine.jpg"

# --- boundary refusals, victims untouched ----------------------------------
check  "rm refuses ..-traversal"               1 run "$lib" rm ../outside/delete-victim.jpg
check  "rename refuses ..-traversal"           1 run "$lib" rename ../outside/rename-victim.jpg moved
check  "rm refuses absolute path"              1 run "$lib" rm "$out/delete-victim.jpg"
check  "rm refuses nested path"                1 run "$lib" rm outside/delete-victim.jpg
check  "rm of an in-library symlink succeeds"  0 run "$lib" rm escape.jpg
exists "symlink target beyond boundary intact" yes "$out/delete-victim.jpg"
exists "outside rename-victim untouched"       yes "$out/rename-victim.jpg"

# --- unknown trailing option: refused BEFORE any side effect ---------------
check  "rm with trailing unknown flag refused" 1 run "$lib" rm keepme.jpg --bogus
exists "no partial delete before flag error"   yes "$lib/keepme.jpg"
check  "set with trailing unknown flag refused" 1 run "$lib" set keepme.jpg --bogus

# --- scratch hygiene: no temp file left, success or failure ----------------
check  "transformed local set succeeds"        0 run "$lib" set tiny.png --rotate right
check  "transform of a broken image fails"     1 run "$lib" set broken.jpg --rotate right
leftovers=$(find "$fixture/tmpdir" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftovers" = "0" ]; then pass "no scratch files leaked"; else fail "scratch leak: $leftovers file(s) left in TMPDIR"; fi

# --- unsplash URL hardening (Codex round 3): exact host, slug allowlist, ----
# --- one request per command, no key in argv, hostile queries stay literal --
stubdir="$fixture/bin"
mkdir -p "$stubdir"
cat >"$stubdir/curl" <<'EOS'
#!/bin/bash
# Deterministic curl stand-in: records every argv to CURL_LOG, answers canned
# bytes, performs no network I/O. Drains stdin only for `-K -` (config mode),
# and when that config carries the sentinel Access Key it logs `KEYTO <url>`
# — so a test can prove the key is never sent off api.unsplash.com. The API
# body's description and download_location come from STUB_DESC / STUB_DL so a
# case can inject a hostile photo the way a contributor could.
printf 'ARGV: %s\n' "$*" >>"${CURL_LOG:?}"
url="" out="" prev="" kdash=0
for a in "$@"; do
    case "$a" in http://* | https://*) url="$a" ;; esac
    [ "$prev" = "-o" ] && out="$a"
    [ "$prev" = "--url" ] && url="$a"
    [ "$prev" = "-K" ] && [ "$a" = "-" ] && kdash=1
    prev="$a"
done
cfg=""
[ "$kdash" = 1 ] && cfg=$(cat)
case "$cfg" in *stub-sentinel-key*) printf 'KEYTO %s\n' "$url" >>"$CURL_LOG" ;; esac
case "$url" in
*api.unsplash.com/photos*)
    STUB_DESC="${STUB_DESC:-stub photo of a boundary test}" \
    STUB_DL="${STUB_DL:-https://api.unsplash.com/photos/stub123/download}" \
        python3 -c 'import json, os, sys
sys.stdout.write(json.dumps({
    "id": "stub123", "slug": "stub-photo-stub1234567",
    "alt_description": os.environ["STUB_DESC"],
    "width": 3840, "height": 2160,
    "urls": {"raw": "https://img.invalid/raw", "full": "https://img.invalid/full"},
    "links": {"download_location": os.environ["STUB_DL"]},
    "user": {"name": "Stub"}}))'
    ;;
*img.invalid/*)
    printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5CYII=' |
        base64 -d >"${out:?}"
    ;;
esac
exit 0
EOS
chmod +x "$stubdir/curl"

# shellcheck disable=SC2317,SC2329  # reached indirectly via check()'s "$@"
run_stub() { CURL_LOG="$1" PATH="$stubdir:$PATH" UNSPLASH_ACCESS_KEY=stub-sentinel-key \
    WALLPAPER_DIR="$lib" THEME_NO_APPLY=1 TMPDIR="$fixture/tmpdir" bash "$THEME" "${@:2}"; }

goodlog="$fixture/curl-good.log"; : >"$goodlog"
check  "unsplash photo-page URL accepted"      0 run_stub "$goodlog" unsplash https://unsplash.com/photos/winged-slug-coy_MhYMLHs
apihits=$(grep -c '^ARGV: .*api\.unsplash\.com/photos/winged-slug-coy_MhYMLHs' "$goodlog")
if [ "$apihits" = 1 ]; then pass "exactly one authenticated API request"; else fail "expected 1 API request, saw $apihits"; fi
if grep -q 'stub-sentinel-key' "$goodlog"; then fail "key leaked into curl argv"; else pass "key never in curl argv"; fi
# Bind the globoff assertion to the API line itself — the photo-download curl
# also carries -fsLg, and matching any line lets a glob-enabled API call hide.
if grep 'api\.unsplash\.com/photos/winged-slug' "$goodlog" | grep -q '^ARGV: -fsLg '; then
    pass "curl globbing off on the API request"
else fail "API request missing -g (globoff)"; fi
exists "photo saved under its description"     yes "$lib/stub-photo-of-a-boundary-test.png"

evillog="$fixture/curl-evil.log"; : >"$evillog"
check  "lookalike host refused"                1 run_stub "$evillog" unsplash https://evilunsplash.com/photos/x
check  "http (non-TLS) unsplash link refused"  1 run_stub "$evillog" unsplash http://unsplash.com/photos/abc
check  "glob-range slug refused"               1 run_stub "$evillog" unsplash "https://unsplash.com/photos/[1-3]"
if [ -s "$evillog" ]; then fail "refused inputs still reached curl"; else pass "refused inputs never reach curl"; fi

searchlog="$fixture/curl-search.log"; : >"$searchlog"
check  "hostile search query accepted"         0 run_stub "$searchlog" unsplash "cats&count=50[1-3]"
if grep -qF -- '--data-urlencode query=cats&count=50[1-3]' "$searchlog"; then
    pass "search text stays one literal encoded value"
else fail "hostile search not passed through --data-urlencode"; fi

# --- credential boundary (Codex round 5): contributor-controlled text or ----
# --- download_location can never send the Access Key off api.unsplash.com ---
dllog="$fixture/curl-dl.log"; : >"$dllog"
check  "clean photo: fetch + report succeed"   0 run_stub "$dllog" unsplash https://unsplash.com/photos/clean-slug-abcdef12345
dlhits=$(grep -c '^KEYTO https://api\.unsplash\.com/photos/stub123/download$' "$dllog")
if [ "$dlhits" = 1 ]; then pass "legit download endpoint reported exactly once"; else fail "expected 1 authenticated download report, saw $dlhits"; fi

# A photo description carrying a tab AND a newline — the exact field-shift
# exploit: under the old tab-joined transport this landed an attacker URL in
# the authenticated-report field.
STUB_DESC=$(printf 'safe name\thttps://evil.invalid/steal\nsecond line')
export STUB_DESC
tablog="$fixture/curl-tab.log"; : >"$tablog"
check  "tab/newline description still saves"   0 run_stub "$tablog" unsplash https://unsplash.com/photos/tabby-slug-abcdef12345
if grep '^KEYTO ' "$tablog" | grep -qv '^KEYTO https://api\.unsplash\.com/'; then
    fail "key sent off-host under a crafted description"
else pass "crafted description cannot retarget the key"; fi
unset STUB_DESC

STUB_DL="https://evil.invalid/dl"
export STUB_DL
evildllog="$fixture/curl-evildl.log"; : >"$evildllog"
check  "malicious download_location tolerated" 0 run_stub "$evildllog" unsplash https://unsplash.com/photos/evil-dl-abcdef123456
if grep '^KEYTO ' "$evildllog" | grep -qv '^KEYTO https://api\.unsplash\.com/'; then
    fail "key followed a non-api download_location"
else pass "non-api download_location never receives the key"; fi
unset STUB_DL

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILURES"; fi
exit "$fails"
