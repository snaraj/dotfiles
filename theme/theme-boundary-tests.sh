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
#   - the credential boundary, in BOTH its layers, each provable on its own:
#     a malicious download_location leaves the authenticated report unsent
#     (the exact-host allowlist), and a photo description carrying tab and
#     newline — the field-shift exploit — still reports to the photo's OWN
#     download endpoint exactly once and nowhere else (the NUL transport),
#     an assertion no key-absence check can satisfy for it;
#   - `theme list`'s colorscheme column reports the palette cache and never
#     guesses. A cache file is NAMED by a lossy mangling of the wallpaper path
#     ('/' and '.' both become '_'), so its name cannot establish ownership:
#     each way that fails gets its own target here — a plain name extension,
#     an extension beginning `_dark_`, one beginning `_light_`, and two
#     wallpapers whose mangled names are byte-identical, in both mtime orders.
#     An unapplied wallpaper renders a dash rather than invented colors, and a
#     corrupt entry degrades to that same dash with a silent stderr.
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
# That negative is satisfied by the exact-host allowlist ALONE. Roll the
# transport back to tab-joined + `IFS=$'\t' read` and the crafted description
# shifts https://evil.invalid/steal into the report field, where the allowlist
# blanks it: no report fires at all, nothing goes off-host, and a key-absence
# test stays green while the field shift is fully alive. So assert the
# transport FUNCTIONALLY — a hostile description must move nothing, leaving
# exactly the clean run's two authenticated calls (the photo lookup and the
# legitimate stub123 download report) and no third.
tabkeys=$(grep -c '^KEYTO ' "$tablog")
tabreport=$(grep -c '^KEYTO https://api\.unsplash\.com/photos/stub123/download$' "$tablog")
if [ "$tabreport" = 1 ] && [ "$tabkeys" = 2 ]; then
    pass "crafted description leaves the report on its own target"
else fail "crafted description shifted the report ($tabreport legit of $tabkeys authenticated calls)"; fi
unset STUB_DESC

STUB_DL="https://evil.invalid/dl"
export STUB_DL
evildllog="$fixture/curl-evildl.log"; : >"$evildllog"
check  "malicious download_location tolerated" 0 run_stub "$evildllog" unsplash https://unsplash.com/photos/evil-dl-abcdef123456
if grep '^KEYTO ' "$evildllog" | grep -qv '^KEYTO https://api\.unsplash\.com/'; then
    fail "key followed a non-api download_location"
else pass "non-api download_location never receives the key"; fi
unset STUB_DL

# --- `theme list` colorscheme column: reports the cache, never guesses ------
# The column claims "the scheme THIS wallpaper derived", and pywal's cache
# FILENAME cannot back that claim: it is the wallpaper path with '/' and '.'
# both collapsed to '_', then extended with mode/backend/size tokens joined by
# that same '_'. Each way a filename-shaped lookup gets ownership wrong gets
# its OWN target below — a plain name extension, an extension beginning with
# the dark delimiter, one beginning with the light delimiter, and two
# wallpapers whose mangled names are byte-identical — so no single case can
# mask another, and every one of them has an input that turns it red.
walcache="$fixture/wal"
mkdir -p "$walcache/schemes"
mangle() { printf '%s' "$1" | tr '/.' '__'; }
# A minimal pywal scheme file: NAMED with the lossy mangling, and RECORDING the
# wallpaper it belongs to exactly as pywal does. color0 is the caller's probe;
# color10 must never be read as color1, and color8 must fall outside the first
# eight.
scheme_json() { # $1 owning wallpaper, $2 color0 hex, $3 mode, $4 size token, $5 mtime
    local dest
    dest="$walcache/schemes/$(mangle "$1")_$3_colorz_None_$4_2.0.0.json"
    printf '{\n    "checksum": "x",\n    "wallpaper": "%s",\n    "alpha": "100",\n    "colors": {"color0": "#%s", "color1": "#111111", "color2": "#222222", "color3": "#333333", "color4": "#444444", "color5": "#555555", "color6": "#666666", "color7": "#777777", "color8": "#888888", "color10": "#aaaaaa"}\n}\n' \
        "$1" "$2" >"$dest"
    touch -t "$5" "$dest"
}
for w in hit-plain.jpg hit-plain_jpg_x.png hit-dark.jpg hit-dark.jpg_dark_x.png \
    hit-light.jpg hit-light.jpg_light_y.png collide.a.jpg collide_a.jpg \
    dup.b.jpg dup_b.jpg scheme-miss.jpg scheme-bad.jpg; do
    printf 'x' >"$lib/$w"
done
# Every target is deliberately the OLDEST of its pair, so "newest wins" alone
# never lands on the right answer by accident. Every attacker RECORDS its own
# path, and each of those paths begins with its target's path — which is why
# the ownership match has to carry the closing quote.
#
# hit-plain: a plain mangled-name extension. `hit-plain_jpg` is a prefix of
# `hit-plain_jpg_x_png`, so a bare `${mangled}_*` glob takes the attacker.
scheme_json "$lib/hit-plain.jpg"            010203 dark  1 202001010000
scheme_json "$lib/hit-plain_jpg_x.png"      0a0b0c dark  1 202601010000
# hit-dark: the extension itself BEGINS with the dark delimiter —
# `hit-dark_jpg_dark_x_png` — so requiring `_dark_` does not exclude it.
scheme_json "$lib/hit-dark.jpg"             141516 dark  1 202001010000
scheme_json "$lib/hit-dark.jpg_dark_x.png"  1e1f20 dark  1 202601010000
# hit-light: the same trick through the light delimiter.
scheme_json "$lib/hit-light.jpg"            282930 light 1 202001010000
scheme_json "$lib/hit-light.jpg_light_y.png" 323334 light 1 202601010000
# EXACT mangling collisions: '.'->'_' makes each of these pairs share one
# mangled name, so no filename test whatsoever can tell the two apart. Distinct
# size tokens only keep them from overwriting each other on disk. The pairs
# carry OPPOSITE mtime orders on purpose — with one order only, whichever
# wallpaper happened to own the newest entry would pass under a filename lookup
# too, and its assertion would be decoration. Here each direction is the loser
# of its own pair, so each has an input that turns it red.
scheme_json "$lib/collide.a.jpg"            3c3d3e dark  1 202001010000
scheme_json "$lib/collide_a.jpg"            464748 dark  2 202601010000
scheme_json "$lib/dup.b.jpg"                505152 dark  1 202601010000
scheme_json "$lib/dup_b.jpg"                5a5b5c dark  2 202001010000
# Truncated hex in every slot, under a correctly-owned entry: the dash here
# must come from the hex guard, not from a failed lookup. With a
# [0-9a-fA-F]* capture these all match and the caller's $((16#${c:4:2}))
# evaluates 16# — a bash arithmetic error per color, on stderr, mid-table.
printf '{\n    "wallpaper": "%s",\n    "colors": {"color0": "#0102", "color1": "#3", "color2": "#", "color3": "#12345"}\n}\n' \
    "$lib/scheme-bad.jpg" \
    >"$walcache/schemes/$(mangle "$lib/scheme-bad.jpg")_dark_colorz_None_1_2.0.0.json"

listout="$fixture/list.out"; listerr="$fixture/list.err"
# shellcheck disable=SC2317,SC2329  # reached indirectly via check()'s "$@"
run_list() { WAL_CACHE="$walcache" COLUMNS=200 WALLPAPER_DIR="$lib" THEME_NO_APPLY=1 \
    bash "$THEME" list >"$listout" 2>"$listerr"; }
row() { grep "^  $1  *" "$listout"; }   # one listing row, by its exact title
owns() { # $1 description, $2 title, $3 own rgb, $4 rgb it must never show
    local r
    r=$(row "$2")
    if printf '%s' "$r" | grep -q "48;2;$3m" && ! printf '%s' "$r" | grep -q "48;2;$4m"; then
        pass "$1"
    else fail "$1 (row: own $3 missing, or borrowed $4)"; fi
}
check "list renders"                           0 run_list
owns "a name-extending neighbour is not this wallpaper's scheme" \
    'hit-plain' '1;2;3' '10;11;12'
owns "a neighbour beginning _dark_ is not this wallpaper's scheme" \
    'hit-dark' '20;21;22' '30;31;32'
owns "a neighbour beginning _light_ is not this wallpaper's scheme" \
    'hit-light' '40;41;48' '50;51;52'
owns "dotted name keeps its own scheme under a mangling collision" \
    'collide\.a' '60;61;62' '70;71;72'
owns "underscored name keeps its own scheme under a mangling collision" \
    'dup_b' '90;91;92' '80;81;82'
# --- `list -v` must render in BOTH preview states ---------------------------
# Previews need kitty AND `kitten`; the width maths for the extra column was
# written as `$((cols - 71 - ${pvok:+9}))`, which expands to `cols - 71 - ` the
# moment previews are off — an arithmetic syntax error, so verbose listing died
# outright in every terminal that is not kitty. Both states are pinned here,
# with a deterministic `kitten` stand-in that emits a placeholder payload
# shaped like the real one and touches no graphics, no image and no terminal.
cat >"$stubdir/kitten" <<'EOS'
#!/bin/bash
printf '\033_Gf=100,t=f,i=1,c=7,r=2;QUJD\033\\'
printf '\033[38;5;1mPREVIEWA\n'
printf '\033[38;5;1mPREVIEWB\n'
exit 0
EOS
chmod +x "$stubdir/kitten"
listvout="$fixture/listv.out"; listverr="$fixture/listv.err"
pvout="$fixture/listpv.out"; pverr="$fixture/listpv.err"
# shellcheck disable=SC2317,SC2329  # reached indirectly via check()'s "$@"
run_listv() { WAL_CACHE="$walcache" COLUMNS=200 WALLPAPER_DIR="$lib" THEME_NO_APPLY=1 \
    KITTY_WINDOW_ID='' bash "$THEME" list -v >"$listvout" 2>"$listverr"; }
# shellcheck disable=SC2317,SC2329  # reached indirectly via check()'s "$@"
run_listpv() { WAL_CACHE="$walcache" COLUMNS=200 WALLPAPER_DIR="$lib" THEME_NO_APPLY=1 \
    KITTY_WINDOW_ID=1 PATH="$stubdir:$PATH" bash "$THEME" list -v >"$pvout" 2>"$pverr"; }
check "verbose list renders without previews"  0 run_listv
check "verbose list renders with previews"     0 run_listpv
if [ -s "$listverr" ] || [ -s "$pverr" ]; then
    fail "verbose list wrote to stderr"
else pass "verbose list is silent on stderr in both states"; fi
if grep -q 'PREVIEWA' "$pvout" && grep -q '^  .*PREVIEWB' "$pvout"; then
    pass "a rendered preview occupies both of its row's lines"
else fail "preview row did not render its two lines"; fi

if row 'scheme-miss' | grep -q '48;2;'; then
    fail "an unapplied wallpaper was given invented colors"
else pass "unapplied wallpaper lists an honest dash"; fi
if row 'scheme-bad' | grep -q '48;2;' || [ -s "$listerr" ]; then
    fail "a corrupt cache entry produced a swatch or an error"
else pass "corrupt cache entry degrades to a dash, silently"; fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILURES"; fi
exit "$fails"
