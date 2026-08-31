#!/usr/bin/env bash
# theme — desktop wallpaper + terminal palette CLI (pywal).
# Full documentation: ~/.config/theme/README.md
# Set THEME_NO_APPLY=1 to exercise every code path without touching the desktop.

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config}"
KITTY_DIR="${KITTY_CONFIG_DIRECTORY:-$CONFIG_DIR/kitty}"
CURRENT="$KITTY_DIR/current-theme.conf"
# Wallpaper library: EVERY image under this directory, subfolders included.
# THEME_WALLPAPER_DIR is the CLI's wallpaper knob (WALLPAPER_DIR still
# honored for older scripts; downloads save to the library root).
WALLPAPER_DIR="${THEME_WALLPAPER_DIR:-${WALLPAPER_DIR:-$CONFIG_DIR/wallpapers}}"
WAL_CACHE="${WAL_CACHE:-$HOME/.cache/wal}"
MIN_WIDTH=2560
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
# Every format the desktop setter AND pywal's backends both handle, so
# anything listed can actually be SET and derive a scheme. All included by
# default; THEME_FORMATS replaces the set, THEME_EXCLUDE_FORMATS subtracts
# (comma- or space-separated, case and leading dots ignored).
THEME_FORMATS_ALL="jpg jpeg png webp gif bmp tif tiff"

# EVERY message this tool prints passes through one of these two, so this is
# where control bytes stop — not at whichever call sites someone remembered.
# Filenames, paths, pywal's cached wallpaper record and contributor free text
# from the Unsplash API all end up interpolated into messages, and any of them
# can carry an OSC 52 clipboard write. Sanitizing per call site is how sinks
# get missed; sanitizing here means a new `note` cannot introduce one.
# display_text is defined below — order is irrelevant, every definition runs
# before any call.
die() { printf 'theme: %s\n' "$(display_text "$*")" >&2; exit 1; }
note() { printf 'theme: %s\n' "$(display_text "$*")"; }
dry() { [ -n "${THEME_NO_APPLY:-}" ]; }

# --- small utilities -------------------------------------------------------

# IMG_GLOB (find(1) -iname clauses) built from THEME_FORMATS minus
# THEME_EXCLUDE_FORMATS. An emptied set is refused loudly rather than
# silently listing nothing.
build_img_glob() {
    local inc exc e x skip
    inc=$(printf '%s' "${THEME_FORMATS:-$THEME_FORMATS_ALL}" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')
    exc=$(printf '%s' "${THEME_EXCLUDE_FORMATS:-}" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')
    IMG_GLOB=()
    for e in $inc; do
        e="${e#.}"
        [ -n "$e" ] || continue
        skip=""
        for x in $exc; do [ "${x#.}" = "$e" ] && { skip=1; break; }; done
        [ -n "$skip" ] && continue
        [ "${#IMG_GLOB[@]}" -gt 0 ] && IMG_GLOB+=(-o)
        IMG_GLOB+=(-iname "*.$e")
    done
    [ "${#IMG_GLOB[@]}" -gt 0 ] || die "THEME_FORMATS/THEME_EXCLUDE_FORMATS leave no formats to list"
}

slugify() {
    local s
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
        sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//')
    # Cap long names at a WORD boundary — never a mid-word chop like "at-s".
    if [ "${#s}" -gt 72 ]; then
        s=$(printf '%.72s' "$s")
        s="${s%-*}"
    fi
    printf '%s' "$s"
}

hash_of() { { shasum -a 256 || sha256sum; } <"$1" 2>/dev/null | cut -d' ' -f1; }

# A filename is DATA from disk, never terminal protocol. macOS accepts every
# byte but '/' and NUL in a name, so a wallpaper can be called
# ESC ] 52 ; c ; <base64> BEL — and a terminal that receives those bytes
# writes the user's clipboard instead of printing a title. Every
# filesystem-derived value therefore gets a display copy with control bytes
# removed. The OPERATIONAL path is never the sanitized string: what we open,
# copy, move and delete stays byte-exact, so sanitizing can change what is
# shown but never what is touched.
display_text() { printf '%s' "$1" | tr -d '[:cntrl:]'; }

# The lowercased hostname of an http(s) URL, or nothing. Userinfo is stripped
# BEFORE the host is read, because the host of
# `https://unsplash.com@evil.invalid/x` is evil.invalid; the port goes after.
url_host() { # $1 url
    local h=$1
    case "$h" in
    http://*) h=${h#http://} ;;
    https://*) h=${h#https://} ;;
    *) return 1 ;;
    esac
    h=${h%%/*}; h=${h%%\?*}; h=${h%%#*}
    h=${h##*@}
    h=${h%%:*}
    [ -n "$h" ] || return 1
    printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# Is $1 the domain $2, or a subdomain of it? This is deliberately NOT a
# substring test: `evilunsplash.com` contains `unsplash.com`, and labelling it
# `unsplash` hands a hostile source the provenance of a trusted one. The dot
# in `*."$2"` is what makes the boundary real, and `unsplash.com.evil.invalid`
# fails both arms.
host_under() { # $1 host, $2 domain
    case "$1" in "$2" | *."$2") return 0 ;; esac
    return 1
}

# One SCRIPT-GLOBAL scratch file with one top-level EXIT trap. A per-function
# `local tmp` + `trap ... EXIT` leaks: at shell exit the local is out of scope
# and the trap deletes nothing (Codex re-review finding 2). Functions assign
# SCRATCH, and scratch_done both deletes eagerly and disarms the trap's target.
SCRATCH=""
trap 'rm -f "$SCRATCH"' EXIT
scratch_new() { SCRATCH=$(mktemp -t theme) || die "mktemp failed"; }
scratch_done() { rm -f "$SCRATCH"; SCRATCH=""; }

# Rotate $1 in place 90° ($2 = left|right). sips ships with macOS; imagemagick
# is the Linux fallback. Lets portrait images (Pinterest pins) fill a desktop.
rotate_image() {
    local deg
    case "$2" in right) deg=90 ;; left) deg=270 ;; *) die "--rotate takes left or right" ;; esac
    if command -v sips >/dev/null 2>&1; then
        sips --rotate "$deg" "$1" >/dev/null 2>&1 || die "rotation failed on $1"
    elif command -v magick >/dev/null 2>&1; then
        magick "$1" -rotate "$deg" "$1" || die "rotation failed on $1"
    else
        die "no rotation tool found (need sips or imagemagick)"
    fi
    return 0
}

# Apply the global --rotate flag, if given, to a file about to be saved.
maybe_rotate() { [ -n "$ROTATE" ] && rotate_image "$1" "$ROTATE"; return 0; }

# The primary display's aspect ratio (width/height, 3 decimals). Finder's
# desktop bounds are logical points, but the RATIO matches the pixels.
screen_aspect() {
    local b w h
    b=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null)
    w=$(printf '%s' "$b" | awk -F', ' '{print $3}')
    h=$(printf '%s' "$b" | awk -F', ' '{print $4}')
    if [ -n "$w" ] && [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null; then
        awk -v w="$w" -v h="$h" 'BEGIN {printf "%.3f", w/h}'
    else
        printf '1.600'
    fi
}

# Extend $1's canvas to the screen's aspect ratio, design centred, padding in
# solid color $2 (RRGGBB) — for art on a flat background: no crop, no zoom,
# the surround just grows in the same color. sips pads natively.
extend_image() {
    local w h aspect tw th
    w=$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    [ -n "$w" ] && [ -n "$h" ] || die "cannot read image size of $1"
    aspect=$(screen_aspect)
    tw=$(awk -v h="$h" -v a="$aspect" 'BEGIN {printf "%d", h*a}')
    if [ "$tw" -ge "$w" ]; then
        th="$h"
    else
        tw="$w"
        th=$(awk -v w="$w" -v a="$aspect" 'BEGIN {printf "%d", w/a}')
    fi
    command -v sips >/dev/null 2>&1 || die "canvas extension needs sips (macOS)"
    sips --padToHeightWidth "$th" "$tw" --padColor "$2" "$1" >/dev/null 2>&1 ||
        die "canvas extension failed on $1"
    return 0
}

maybe_extend() { [ -n "$EXTEND" ] && extend_image "$1" "$EXTEND"; return 0; }

# "3840x2160", or empty when the dimensions cannot be read.
img_size() {
    local size
    if command -v sips >/dev/null 2>&1; then
        size=$(sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null |
            awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w) print w "x" h}')
    else
        size=$(file -b "$1" 2>/dev/null | grep -Eo '[0-9]+ ?x ?[0-9]+' | head -1 | tr -d ' ')
    fi
    # Both readers scrape a tool that also echoes the FILENAME, so the shape is
    # asserted rather than assumed: a size is digits, an x, digits — or it is
    # nothing at all and every caller already renders that honestly.
    case "$size" in
    '' | *[!0-9x]* | x* | *x) printf '' ;;
    *x*) printf '%s' "$size" ;;
    *) printf '' ;;
    esac
}

# i.pinimg.com/736x/... -> i.pinimg.com/originals/...  (identity for other hosts)
pinimg_original() {
    printf '%s' "$1" | sed 's#\(i\.pinimg\.com\)/[0-9]\{2,4\}x[0-9]*/#\1/originals/#'
}

# A descriptive filename hint from a URL: its basename, or — when that carries
# no letters at all (".../3840/2160.jpg") — the whole host-and-path.
name_hint() {
    local path="${1#*://}" base
    path="${path%%\?*}"
    base=$(basename "$path")
    case "$(slugify "${base%.*}")" in
    *[a-z]*) printf '%s' "$base" ;;
    *) printf '%s' "$path" ;;
    esac
}

# Try the upgraded URL first, fall back to exactly what was asked for.
fetch_img() {
    local up; up=$(pinimg_original "$1")
    curl -fsLg --max-time 60 -A "$UA" -o "$2" "$up" && return 0
    [ "$up" = "$1" ] && return 1
    curl -fsLg --max-time 60 -A "$UA" -o "$2" "$1"
}

# Save $1 (temp file, mime $2, name hint $3) into WALLPAPER_DIR; sets $SAVED.
# Identical content under the same name is reused; different content never
# overwrites — it takes the next free -2, -3, ... suffix.
save_wallpaper() {
    local ext base dest n
    case "$2" in
    image/jpeg) ext=jpg ;; image/png) ext=png ;; image/webp) ext=webp ;;
    image/gif) ext=gif ;; image/avif) ext=avif ;; *) ext="${2#image/}" ;;
    esac
    base=$(slugify "${3%.*}")
    [ -n "$base" ] || base="wallpaper-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$WALLPAPER_DIR" || die "cannot create $WALLPAPER_DIR"
    dest="$WALLPAPER_DIR/$base.$ext"
    n=2
    # ONE mechanism answers both "is this name free?" and "write it": bash's
    # noclobber redirect opens O_CREAT|O_EXCL, which fails on anything already
    # at the path — regular file, directory, or symlink, INCLUDING a dangling
    # one. Asking with `[ -e ]` first would be two mistakes at once: `-e`
    # FOLLOWS symlinks, so a dangling symlink planted in the library reads as a
    # vacant slot and a plain `cp` writes straight through it to a target
    # outside the library; and a separate check leaves a window in which the
    # answer can change before the write. There is no window here because there
    # is no separate check.
    until ( set -C; cat "$1" >"$dest" ) 2>/dev/null; do
        # The redirect failed. If nothing is at the path, the cause was not an
        # occupied name — the directory is unwritable, or worse — and trying
        # suffixes would just spin.
        [ -e "$dest" ] || [ -L "$dest" ] || die "cannot write $dest"
        # Occupied. Reuse only a byte-identical PLAIN file: `-f` follows
        # symlinks, so `-L` is what stops an alias to an identical file from
        # being adopted as the saved wallpaper.
        if [ -f "$dest" ] && [ ! -L "$dest" ] &&
            [ "$(hash_of "$1")" = "$(hash_of "$dest")" ]; then
            SAVED="$dest"
            [ -n "$SOURCE_URL" ] && ! xattr -p theme.source "$dest" >/dev/null 2>&1 &&
                xattr -w theme.source "$SOURCE_URL" "$dest" 2>/dev/null
            note "already have $(basename "$dest") — reusing it"
            return 0
        fi
        [ "$n" -le 99 ] ||
            die "cannot save into $WALLPAPER_DIR — 99 names starting $base are taken"
        dest="$WALLPAPER_DIR/$base-$n.$ext"
        n=$((n + 1))
    done
    chmod 644 "$dest"
    SAVED="$dest"
    # Provenance for `theme list`: where this wallpaper came from, recorded on
    # the file itself. Read back by wall_source(); best-effort, never fatal.
    [ -n "$SOURCE_URL" ] && xattr -w theme.source "$SOURCE_URL" "$dest" 2>/dev/null
    local size w; size=$(img_size "$dest"); w="${size%%x*}"
    note "saved $(basename "$dest")${size:+ ($size)}"
    if [ -n "$w" ] && [ "$w" -lt "$MIN_WIDTH" ] 2>/dev/null; then
        note "warning: only ${w}px wide, below the ${MIN_WIDTH}px desktop floor"
    fi
    return 0
}

# --- applying --------------------------------------------------------------

# Recolor every RUNNING kitty instance. $1 = the colors file just activated.
# Remote control (kitty.conf: allow_remote_control password + listen_on
# unix:/tmp/kitty-samuel + remote_control_password "" set-colors, i.e. a
# passwordless socket client may call set-colors and NOTHING else) is the
# reliable path. The removed `pkill -USR1 -x kitty` fallback was never a second
# path: macOS reports the process name as the full bundle path, so the -x exact
# match never matched and the signal was never delivered. set-colors
# --configured also updates the instance's stored config, so windows opened
# later inherit the new palette too. NO SIGUSR1 fallback (owner directive
# 2026-08-30): a full config reload resets runtime state — font-size zoom,
# resized panes — and a theme change may touch colors ONLY. An instance no
# socket reaches keeps its old palette; its next window reads the include.
reload_kitty() {
    local sock
    for sock in /tmp/kitty-samuel-*; do
        [ -S "$sock" ] || continue
        kitten @ --to "unix:$sock" set-colors --all --configured "$1" 2>/dev/null || true
    done
    return 0
}

set_desktop() {
    dry && { note "[no-apply] would set the desktop wallpaper to $1"; return 0; }
    if command -v wallpaper >/dev/null 2>&1; then
        # fill = cover the screen and crop the overflow: maximum zoom that
        # still fills every pixel, never letterbox bars.
        wallpaper set "$1" --scale fill 2>/dev/null ||
            wallpaper set "$1" || die "wallpaper set failed for $1"
    elif [ -n "${XDG_CURRENT_DESKTOP:-}" ] && command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.background picture-uri "file://$1"
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$1"
    elif command -v feh >/dev/null 2>&1; then
        feh --bg-fill "$1"
    else
        note "desktop wallpaper not supported here (install the 'wallpaper' brew formula, feh, or GNOME)"
    fi
    return 0
}

set_palette() {
    dry && { note "[no-apply] would derive a palette from $1"; return 0; }
    command -v wal >/dev/null 2>&1 || die "pywal not installed (pipx install pywal)"
    # --contrast below is implemented through ImageMagick averaging (pywal calls
    # magick, or convert on older builds). Without it all three rungs fail the
    # same way and the only message is a generic "pywal failed"; check once, up
    # front, and say what to install.
    command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 ||
        die "ImageMagick not installed (brew install imagemagick / apt install imagemagick) — required for the --contrast palette floor"
    # colorz refuses near-monochrome art ("not enough colors");
    # modern_colorthief (pipx inject pywal modern_colorthief) handles those.
    # --contrast 3.0 floors accent-vs-background contrast (needs imagemagick);
    # dark art otherwise yields ~1.6:1 accents — invisible typed text. A 3.0
    # request lands ~4.5:1 measured while staying in the image's hue family.
    # -s -t -e: derivation + cache export ONLY. pywal's live-reload otherwise
    # sprays Linux-console/urxvt escapes (ESC]P…, OSC 708) into EVERY open
    # tty — kitty misparses them (tab title became the palette bytes) — and
    # runs its own kitty reload; reload_kitty below is the one sanctioned
    # path to a live terminal, and it touches colors only.
    wal -i "$1" -s -t -e --backend colorz --contrast 3.0 >/dev/null 2>&1 ||
        wal -i "$1" -s -t -e --backend modern_colorthief --contrast 3.0 >/dev/null 2>&1 ||
        wal -i "$1" -s -t -e --contrast 3.0 >/dev/null 2>&1 ||
        die "pywal failed on $1"
    [ -f "$WAL_CACHE/colors-kitty.conf" ] ||
        die "pywal wrote no kitty colors in $WAL_CACHE — point WAL_CACHE at pywal's own cache dir"
    printf 'include %s/colors-kitty.conf\n' "$WAL_CACHE" >"$CURRENT" || die "cannot write $CURRENT"
    reload_kitty "$WAL_CACHE/colors-kitty.conf"
    return 0
}

use_image() {
    set_desktop "$1"
    set_palette "$1"
    note "now: $(basename "$1")$( [ -n "$(img_size "$1")" ] && printf ' (%s)' "$(img_size "$1")")"
}

# Cache-only scheme derivation for a wallpaper that is NOT being applied:
# same backend ladder and contrast floor as set_palette so list/preview show
# the palette `theme set` would produce, but with -n (never touch the
# desktop) and no CURRENT write / kitty reload.
derive_scheme() { # $1 file
    command -v wal >/dev/null 2>&1 || return 1
    wal -n -i "$1" -s -t -e --backend colorz --contrast 3.0 >/dev/null 2>&1 ||
        wal -n -i "$1" -s -t -e --backend modern_colorthief --contrast 3.0 >/dev/null 2>&1 ||
        wal -n -i "$1" -s -t -e --contrast 3.0 >/dev/null 2>&1
}

# Every library wallpaper gets a scheme, not just the ones already applied:
# derive whatever is missing, then re-derive the CURRENT wallpaper so wal's
# per-run export files (colors-kitty.conf and friends — what a fresh kitty
# window reads through $CURRENT) describe the applied theme again, not the
# last backfilled image. Re-deriving a cached wallpaper is a cache read, not
# an image reprocess, so the restore is cheap. Skipped under THEME_NO_APPLY
# (it mutates the wal cache).
backfill_schemes() {
    dry && return 0
    local f cur n=0 miss=()
    while IFS= read -r f; do
        wall_scheme "$f" >/dev/null 2>&1 || miss+=("$f")
    done < <(find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null)
    [ "${#miss[@]}" -eq 0 ] && return 0
    note "deriving ${#miss[@]} missing colorscheme(s)…"
    for f in "${miss[@]}"; do derive_scheme "$f" && n=$((n + 1)); done
    cur=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    [ -n "$cur" ] && [ -f "$cur" ] && derive_scheme "$cur"
    [ "$n" -lt "${#miss[@]}" ] && note "$((${#miss[@]} - n)) wallpaper(s) resisted every backend — still shown as -"
    return 0
}

# --- local wallpapers ------------------------------------------------------

# A title copied from `theme list` may be TRUNCATED (trailing … or cut
# mid-word). Resolve it anyway when it is the prefix of exactly ONE library
# file; zero or several matches fail — never a guess between candidates.
# find(1), not a shell glob, so names in subfolders resolve too — the list
# is recursive, so resolution must be. User input is escaped: a '*' or '['
# in a typed name must match itself, never widen into a pattern.
glob_escape() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }
prefix_match() { # $1 name-or-prefix
    local p="${1%…}" f hit="" n=0
    p="${p%...}"
    [ -n "$p" ] || return 1
    while IFS= read -r f; do
        [ -f "$f" ] && { hit="$f"; n=$((n + 1)); }
    done < <(find "$WALLPAPER_DIR" -type f -name "$(glob_escape "$p")*" 2>/dev/null)
    [ "$n" -eq 1 ] || return 1
    printf '%s' "$hit"
}

# One cardinality-checked resolution for every non-exact name: a bare stem
# ("foo" for foo.jpg) resolves only while it names exactly ONE file — with
# foo.jpg AND foo.png present it refuses instead of picking one (Codex
# round-8 finding 1: a first-glob-match here deleted an arbitrary sibling) —
# then a truncated title falls through to the same unique-prefix rule.
library_match() { # $1 stem-or-prefix
    local f hit="" n=0
    while IFS= read -r f; do
        [ -f "$f" ] && { hit="$f"; n=$((n + 1)); }
    done < <(find "$WALLPAPER_DIR" -type f -name "$(glob_escape "$1").*" 2>/dev/null)
    [ "$n" -eq 1 ] && { printf '%s' "$hit"; return 0; }
    [ "$n" -gt 1 ] && return 1
    prefix_match "$1"
}

resolve_local() {
    local f
    [ -f "$1" ] && { printf '%s' "$1"; return 0; }
    [ -f "$WALLPAPER_DIR/$1" ] && { printf '%s' "$WALLPAPER_DIR/$1"; return 0; }
    f=$(library_match "$1") && { printf '%s' "$f"; return 0; }
    return 1
}

random_local() {
    find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null |
        awk 'BEGIN {srand()} {print rand() "\t" $0}' | sort -n | cut -f2- | head -n 1
}

cmd_local() { # $1 = image argument, or empty for a random pick
    local img mime
    if [ -n "$1" ]; then
        img=$(resolve_local "$1") || die "no wallpaper uniquely matching '$1' (looked in $WALLPAPER_DIR; a truncated name from theme list works when only one wallpaper starts with it)"
    else
        img=$(random_local)
        [ -n "$img" ] || die "no images found in $WALLPAPER_DIR"
    fi
    if [ -n "$ROTATE" ] || [ -n "$EXTEND" ]; then
        # Never modify the library file itself — save the transformed copy as
        # its own wallpaper so the original stays available.
        scratch_new
        cp "$img" "$SCRATCH" || die "cannot copy $img"
        maybe_rotate "$SCRATCH"
        maybe_extend "$SCRATCH"
        mime=$(file -b --mime-type "$SCRATCH")
        save_wallpaper "$SCRATCH" "$mime" "$(basename "${img%.*}")${ROTATE:+ rotated $ROTATE}${EXTEND:+ extended}"
        scratch_done
        img="$SAVED"
    fi
    use_image "$img"
}

# --- remote sources --------------------------------------------------------

OG_PY='
import re, sys
h = sys.stdin.read()
def og(p):
    for pat in (r"<meta[^>]+(?:property|name)=[\"\x27]og:%s[\"\x27][^>]*content=[\"\x27]([^\"\x27]+)",
                r"<meta[^>]+content=[\"\x27]([^\"\x27]+)[\"\x27][^>]*(?:property|name)=[\"\x27]og:%s[\"\x27]"):
        m = re.search(pat % p, h, re.I)
        if m: return m.group(1)
    return ""
print(og("image")); print(og("title"))
'

UNSPLASH_PY='
import json, sys
d = json.load(sys.stdin)
d = d if isinstance(d, list) else [d]
if not d: sys.exit(1)
best = max([p for p in d if p.get("width", 0) >= 3840] or d, key=lambda p: p.get("width", 0))
u = best.get("urls", {})
# The filename hint: prefer the human description ("a city street at night");
# an Unsplash slug carries the 11-char photo id as its last token — strip it.
import re
name = best.get("alt_description") or best.get("description") or ""
if not name:
    name = re.sub(r"-[A-Za-z0-9_-]{11}$", "", best.get("slug") or "") or best.get("id") or "photo"
# raw = the untouched original upload (highest quality); full is a q=85
# re-compressed jpg. Sharpness first: raw, then full as the fallback.
#
# Fields are emitted NUL-TERMINATED, not tab-joined: name and the
# photographer are contributor-controlled free text, and a tab or newline in
# them under the old \\t transport shifted every later field — including the
# authenticated download-report URL, which then received the Access Key. NUL
# cannot occur in these strings (stripped below), so each field stays put.
name = name.replace("\x00", "")
who = ((best.get("user") or {}).get("name") or "").replace("\x00", "")
# The API carries no premium boolean — the signal is the image HOST:
# Unsplash+ files are served from plus.unsplash.com (exact hostname, not a
# substring: evilplus.unsplash.com.example must not qualify).
from urllib.parse import urlparse
img = u.get("raw") or u.get("full", "")
premium = 1 if urlparse(img).hostname == "plus.unsplash.com" else 0
for field in (
    img, best.get("width", 0), best.get("height", 0),
    name,
    (best.get("links") or {}).get("download_location", ""),
    who,
    premium):
    sys.stdout.write(str(field) + "\x00")
'

unsplash_key() {
    [ -n "${UNSPLASH_ACCESS_KEY:-}" ] && { printf '%s' "$UNSPLASH_ACCESS_KEY"; return 0; }
    command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-access-key -w 2>/dev/null
}

# The application Client-ID authenticates the APP, so Unsplash+ photos come
# back WATERMARKED. Entitlement is account-based: a one-time OAuth exchange
# (theme unsplash auth) stores the owner-account bearer token in the
# Keychain, and every API call then runs as the subscriber — premium files
# arrive clean, exactly like the website's Download button.
unsplash_user_token() {
    [ -n "${UNSPLASH_USER_TOKEN:-}" ] && { printf '%s' "$UNSPLASH_USER_TOKEN"; return 0; }
    command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-user-token -w 2>/dev/null
}

# ONE curl -K config line carrying the strongest available credential —
# stdin config, never argv, so neither token nor key ever reaches `ps`.
unsplash_auth_line() {
    local tok
    tok=$(unsplash_user_token)
    if [ -n "$tok" ]; then printf 'header = "Authorization: Bearer %s"\n' "$tok"
    else printf 'header = "Authorization: Client-ID %s"\n' "$(unsplash_key)"
    fi
}

# One-time account link: OAuth authorization-code exchange with the out-of-
# band redirect (the code shows in the browser; the user pastes it here).
# Needs the app's SECRET key once, from the same dashboard page as the
# access key. Secret, code and token all travel via stdin (curl -K data
# lines / `security -i`), never argv; code and token are charset-checked
# before they may sit in URL/command position.
cmd_unsplash_auth() {
    local key secret authurl code json tok
    key=$(unsplash_key)
    [ -n "$key" ] || die "no Unsplash key: export UNSPLASH_ACCESS_KEY, or run \`security add-generic-password -s unsplash-access-key -a \"\$USER\" -w\` after getting a free key at https://unsplash.com/oauth/applications"
    secret="${UNSPLASH_SECRET_KEY:-}"
    [ -n "$secret" ] || secret=$(command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-secret-key -w 2>/dev/null)
    [ -n "$secret" ] || die "the exchange needs your app's SECRET key (shown beside the access key at https://unsplash.com/oauth/applications): export UNSPLASH_SECRET_KEY, or store it once with \`security add-generic-password -s unsplash-secret-key -a \"\$USER\" -w\`"
    authurl="https://unsplash.com/oauth/authorize?client_id=$key&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=public"
    note "opening the authorize page — sign in as your Unsplash+ account and approve"
    if command -v open >/dev/null 2>&1; then open "$authurl"; else note "open: $authurl"; fi
    printf 'paste the code shown after approving: '
    # -e gives readline editing on a tty (arrow keys edit instead of
    # injecting ESC[D into the buffer); harmlessly ignored on a pipe.
    IFS= read -r -e code
    # Browser copies arrive padded — leading/trailing spaces, tabs, or a
    # stray CR are transport noise, not part of the code: strip them BEFORE
    # the charset gate so a padded paste of a valid code is not refused.
    code=$(printf '%s' "$code" | tr -d ' \t\r\n')
    case "$code" in '' | *[!A-Za-z0-9_-]*) die "that does not look like an authorization code (letters, digits, - and _ only) — copy just the code text, without surrounding characters" ;; esac
    json=$(printf 'data = "client_id=%s"\ndata = "client_secret=%s"\ndata = "redirect_uri=urn:ietf:wg:oauth:2.0:oob"\ndata = "code=%s"\ndata = "grant_type=authorization_code"\n' "$key" "$secret" "$code" |
        curl -fsg --max-time 30 -K - "https://unsplash.com/oauth/token") ||
        die "token exchange failed — wrong/expired code, or the app's redirect URIs do not include urn:ietf:wg:oauth:2.0:oob (add it on the dashboard)"
    tok=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
    [ -n "$tok" ] || die "Unsplash answered without an access token"
    case "$tok" in *[!A-Za-z0-9._~+/=-]*) die "unexpected token shape — refusing to store it" ;; esac
    command -v security >/dev/null 2>&1 || die "no macOS Keychain (security) available to store the token"
    printf 'add-generic-password -U -a %s -s unsplash-user-token -w %s\n' "$USER" "$tok" | security -i >/dev/null 2>&1 ||
        die "could not store the token in the Keychain"
    note "linked — Unsplash+ downloads are now watermark-free (Keychain: unsplash-user-token)"
    return 0
}

cmd_unsplash() {
    local key url json img_url w h slug dl who query="$1" pick=""
    key=$(unsplash_key)
    [ -n "$key" ] || die "no Unsplash key: export UNSPLASH_ACCESS_KEY, or run \`security add-generic-password -s unsplash-access-key -a \"\$USER\" -w\` after getting a free key at https://unsplash.com/oauth/applications"
    case "$1" in
    *://*)
        # A pasted link fetches THAT photo via the API's /photos/:id (which
        # accepts the page slug) — but only an EXACT https Unsplash photo
        # page qualifies (a substring match admitted evilunsplash.com), and
        # the slug is charset-allowlisted before it may sit in URL position,
        # so bracket/brace/ampersand payloads never reach curl as syntax.
        case "$1" in
        https://unsplash.com/photos/?* | https://www.unsplash.com/photos/?*) ;;
        *) die "only https://unsplash.com/photos/… links work here — for other links use: theme url" ;;
        esac
        pick="${1##*/photos/}"
        pick="${pick%%\?*}"
        pick="${pick%%/*}"
        case "$pick" in
        '' | *[!A-Za-z0-9_-]*) die "that link carries no valid photo id (letters, digits, - and _ only)" ;;
        esac
        url="https://api.unsplash.com/photos/$pick"
        query=""
        SOURCE_URL="$1"
        ;;
    *)
        url="https://api.unsplash.com/photos/random?count=5&orientation=landscape&content_filter=high"
        ;;
    esac
    # The key goes to curl via stdin config, never argv, so it stays out of
    # `ps`; -g (globoff) keeps [] and {} in any input literal — one command is
    # one request; -G --data-urlencode encodes the WHOLE query, not just
    # spaces, so & or [] in a search stays search text.
    local curl_args=(-fsLg --max-time 30 -K -)
    [ -n "$query" ] && curl_args+=(-G --data-urlencode "query=$query")
    json=$(unsplash_auth_line |
        curl "${curl_args[@]}" "$url") || die "Unsplash request failed (bad key, rate limit, or no network)"
    # Read the six NUL-terminated fields into an array (a tab/newline in the
    # contributor-controlled name or photographer can no longer shift a later
    # field). read -d '' captures each up to its NUL; the final read hits EOF.
    local _f _fields=()
    while IFS= read -r -d '' _f; do _fields+=("$_f"); done < <(printf '%s' "$json" | python3 -c "$UNSPLASH_PY")
    [ "${#_fields[@]}" -ge 7 ] || die "Unsplash returned no usable photo"
    img_url=${_fields[0]}; w=${_fields[1]}; h=${_fields[2]}
    slug=${_fields[3]}; dl=${_fields[4]}; who=${_fields[5]}
    # Unsplash+ content downloaded over the application key is WATERMARKED —
    # say so BEFORE spending the download, and name the one-time fix.
    if [ "${_fields[6]:-0}" = 1 ] && [ -z "$(unsplash_user_token)" ]; then
        note "Unsplash+ photo over application-key auth: the file WILL carry the watermark"
        note "one-time fix: theme unsplash auth (links your Unsplash+ account, clean files after)"
    fi
    # The download-report call attaches the Access Key, so its target must be
    # an api.unsplash.com HTTPS URL and nothing else — defence in depth beside
    # the NUL transport: even a malicious download_location cannot redirect the
    # key off-host.
    case "$dl" in https://api.unsplash.com/*) ;; *) dl="" ;; esac
    [ -n "$img_url" ] || die "Unsplash returned no image URL"
    [ -n "$SOURCE_URL" ] || SOURCE_URL="$img_url"
    if [ "$w" -ge 3840 ] 2>/dev/null; then :
    elif [ -n "$pick" ]; then note "that photo's original is ${w}x${h} (under 3840px)"
    else note "best of 5 candidates is ${w}x${h} (wanted 3840px+)"
    fi
    scratch_new
    curl -fsLg --max-time 90 -A "$UA" -o "$SCRATCH" "$img_url" || die "photo download failed"
    local mime; mime=$(file -b --mime-type "$SCRATCH")
    case "$mime" in image/*) ;; *) die "Unsplash served $mime, not an image" ;; esac
    # Name = your search prompt (when given) + the photo's own description —
    # a wallpaper you can find again, not a slug with an id tail. The
    # photographer is credited in the terminal note, not the filename.
    maybe_rotate "$SCRATCH"
    maybe_extend "$SCRATCH"
    save_wallpaper "$SCRATCH" "$mime" "${query:+$query }$slug${ROTATE:+ rotated $ROTATE}${EXTEND:+ extended}"
    scratch_done
    # Unsplash API guideline: report the download so the photographer is
    # credited. $dl is validated to api.unsplash.com above; --url draws an
    # explicit boundary so it can never be read as another curl option.
    [ -n "$dl" ] && unsplash_auth_line |
        curl -fsg --max-time 15 -K - -o /dev/null --url "$dl" 2>/dev/null
    [ -n "$who" ] && note "photo by $who on Unsplash"
    use_image "$SAVED"
}

# Unsplash API usage for the configured key. The API reports the hourly
# window only in response headers (X-Ratelimit-Limit / -Remaining), so this
# makes ONE cheap list request to read them — and says so, since that request
# itself comes out of the budget. Access keys are per-APPLICATION Client-IDs:
# there is no logged-in user to show, and claiming one would be invented data.
cmd_unsplash_status() {
    local key limit remaining
    key=$(unsplash_key)
    [ -n "$key" ] || die "no Unsplash key: export UNSPLASH_ACCESS_KEY, or run \`security add-generic-password -s unsplash-access-key -a \"\$USER\" -w\` after getting a free key at https://unsplash.com/oauth/applications"
    scratch_new
    unsplash_auth_line |
        curl -fsg --max-time 15 -K - -D "$SCRATCH" -o /dev/null \
            "https://api.unsplash.com/photos?page=1&per_page=1" ||
        die "Unsplash request failed (bad key, rate limit exhausted, or no network)"
    limit=$(awk 'tolower($1)=="x-ratelimit-limit:"{sub("\r","",$2); print $2}' "$SCRATCH")
    remaining=$(awk 'tolower($1)=="x-ratelimit-remaining:"{sub("\r","",$2); print $2}' "$SCRATCH")
    scratch_done
    # Header values come off the wire; these two are printed as facts, so the
    # shape is checked rather than trusted. A non-numeric limit is a broken or
    # hostile answer, not a number to render.
    case "$limit" in '' | *[!0-9]*) die "Unsplash answered without usable rate-limit headers" ;; esac
    # A window driven negative (overage) is a real answer — show it, with
    # the recovery fact; anything else non-numeric is not a number to render.
    case "${remaining#-}" in '' | *[!0-9]*) remaining="" ;; esac
    case "$remaining" in
    -*) printf 'requests left this hour:  %s/%s (window EXCEEDED — resets on the hour)\n' "$remaining" "$limit" ;;
    *)  printf 'requests left this hour:  %s/%s (resets on the hour)\n' "$remaining" "$limit" ;;
    esac
    case "$limit" in
    50) printf 'tier:                     demo (50/hour; production raises it to 5000)\n' ;;
    5000) printf 'tier:                     production (5000/hour)\n' ;;
    *) printf 'tier:                     custom limit %s/hour\n' "$limit" ;;
    esac
    if [ -n "${UNSPLASH_ACCESS_KEY:-}" ]; then
        printf 'key:                      set (env UNSPLASH_ACCESS_KEY)\n'
    else
        printf 'key:                      set (Keychain: unsplash-access-key)\n'
    fi
    if [ -n "$(unsplash_user_token)" ]; then
        printf 'account:                  user token linked (Bearer) — Unsplash+ files come clean\n'
    else
        printf 'account:                  application access key (Client-ID); no user is logged\n'
        printf '                          in, so Unsplash+ photos arrive WATERMARKED — see: theme unsplash auth\n'
    fi
    printf 'note:                     this check spent 1 request of the window above\n'
    return 0
}

cmd_url() {
    local link="$1" mime hint meta page_img page_title
    [ -n "$link" ] || die "usage: theme url <image-url | pinterest-pin-url>"
    SOURCE_URL="$1"
    scratch_new
    # A direct i.pinimg.com /NNNx/ link is a Pinterest downscale; the same path
    # under /originals/ is the full-resolution upload when it exists. Sharpness
    # first: try originals, fall back to the given link.
    # fetch_best <url> <dest>: like fetch_img, but a pinimg /NNNx/ downscale is
    # first tried at /originals/ — sets FETCHED to the URL that actually served.
    fetch_best() {
        local orig=""
        FETCHED="$1"
        case "$1" in
        *://i.pinimg.com/*x/*)
            orig=$(printf '%s' "$1" | sed -E 's#(//i\.pinimg\.com)/[0-9]+x/#\1/originals/#')
            ;;
        esac
        if [ -n "$orig" ] && [ "$orig" != "$1" ] && fetch_img "$orig" "$2"; then
            note "upgraded the pinimg downscale to /originals/"
            FETCHED="$orig"
            return 0
        fi
        fetch_img "$1" "$2"
    }
    fetch_best "$link" "$SCRATCH" || die "download failed: $link"
    link="$FETCHED"
    mime=$(file -b --mime-type "$SCRATCH")
    # Name hint without its extension (save_wallpaper strips from the LAST dot,
    # which would otherwise eat any suffix appended after ".jpg"). A bare CDN
    # hash is not a name — date-stamp those; a pin PAGE link gives a real title.
    hint=$(name_hint "$link")
    hint="${hint%.*}"
    if printf '%s' "$hint" | grep -qE '^[0-9a-f]{16,}$'; then
        hint="pinterest-$(date +%Y%m%d-%H%M%S)"
    fi
    case "$mime" in
    image/*) ;;
    text/html | application/xhtml*)
        # Pinterest pins (and any og:image page) resolve one level to the real image.
        meta=$(python3 -c "$OG_PY" <"$SCRATCH") || die "could not parse the page at $link"
        page_img=$(printf '%s\n' "$meta" | sed -n 1p)
        page_title=$(printf '%s\n' "$meta" | sed -n 2p)
        [ -n "$page_img" ] || die "no og:image on that page — pass a direct image URL instead"
        fetch_best "$page_img" "$SCRATCH" || die "download failed: $page_img"
        mime=$(file -b --mime-type "$SCRATCH")
        case "$mime" in image/*) ;; *) die "resolved link is $mime, not an image" ;; esac
        hint="${page_title:-$(name_hint "$page_img")}"
        ;;
    *) die "that URL is $mime, not an image" ;;
    esac
    maybe_rotate "$SCRATCH"
    maybe_extend "$SCRATCH"
    save_wallpaper "$SCRATCH" "$mime" "$hint${ROTATE:+ rotated $ROTATE}${EXTEND:+ extended}"
    scratch_done
    use_image "$SAVED"
}

# --- reporting -------------------------------------------------------------

# Where a wallpaper came from, as a short label: the theme.source xattr our
# own downloads record, falling back to macOS's kMDItemWhereFroms for files a
# browser downloaded. Unknown is an honest "-", never a guess.
wall_source() { # $1 file
    local src
    src=$(xattr -p theme.source "$1" 2>/dev/null)
    if [ -z "$src" ]; then
        src=$(mdls -raw -name kMDItemWhereFroms "$1" 2>/dev/null |
            sed -n 's/^[[:space:]]*"\([^"]*\)".*$/\1/p' | head -1)
    fi
    # The xattr is data from disk, not trusted layout input: control bytes
    # (newlines, escapes) could otherwise reach the aligned tables raw.
    src=$(display_text "$src")
    case "$src" in
    '' | '(null)') printf -- '-'; return 0 ;;
    esac
    # A provider label is a claim about WHERE a file came from, so it is
    # decided by the parsed hostname and never by a substring: `*unsplash.com*`
    # matched `https://evilunsplash.com/payload` and rendered it `unsplash`,
    # which is exactly the provenance an attacker would want to borrow.
    local host dom
    if host=$(url_host "$src"); then
        for dom in unsplash.com images.unsplash.com; do
            host_under "$host" "$dom" && { printf 'unsplash'; return 0; }
        done
        for dom in pinimg.com pinterest.com; do
            host_under "$host" "$dom" && { printf 'pinterest'; return 0; }
        done
        for dom in redd.it reddit.com redditmedia.com; do
            host_under "$host" "$dom" && { printf 'reddit'; return 0; }
        done
        # Anything else is shown as the host it actually is. A Pinterest
        # country domain (pinterest.co.uk) lands here rather than in the label
        # above: naming it honestly beats widening the match to a shape that
        # `pinterest.evil.invalid` also fits.
        printf '%s' "${host#www.}"
        return 0
    fi
    printf '%s' "$src" | sed -E 's#^[a-zA-Z]+://##; s#^www\.##; s#[/:].*##'
}

# The first 8 palette colors a wallpaper DERIVED when it was last applied,
# read from pywal's own scheme cache in $WAL_CACHE/schemes — already outside
# the repo, so the render is a small JSON read per file, never an image
# reprocess. hex without '#', one per line. A wallpaper never applied has no
# cached scheme: the caller renders an honest dash rather than computing one.
wall_scheme() { # $1 file
    local s newest=""
    # OWNERSHIP IS THE WHOLE PROBLEM here, and the cache FILENAME cannot
    # establish it. pywal names a cache file after the wallpaper path with '/'
    # and '.' both collapsed to '_' — a lossy, non-injective mangling — then
    # appends mode, backend, alpha, size and version tokens joined by that same
    # '_'. Three demonstrated ways a filename-shaped lookup gets it wrong:
    #   * `sky.jpg` and `sky_jpg_x.png` mangle to `sky_jpg` and `sky_jpg_x_png`,
    #     so a `sky_jpg_*` glob matches the neighbour's entry;
    #   * requiring the mode token does not repair that, because a NAME may
    #     contain it: `sky.jpg_dark_x.png` mangles to `sky_jpg_dark_x_png`,
    #     which `sky_jpg_dark_*` still matches;
    #   * and the mangling itself collides — `a.b.jpg` and `a_b.jpg` both
    #     mangle to `a_b_jpg`, so even an EXACT filename match is not ownership.
    # pywal records the absolute source path INSIDE the file, as `"wallpaper"`,
    # and that is the collision-free key. Match it literally with both quotes,
    # so one recorded path can be neither a prefix nor an extension of another.
    # A name the JSON has to escape (a quote or a backslash) is not provable by
    # a literal match, so it finds nothing and renders the dash — unknown is a
    # dash here, never a guess.
    case "$1" in *'"'* | *\\*) return 1 ;; esac
    # One grep over the cache directory per wallpaper, not one per PAIR: `-l`
    # names the owning files and `-nt` picks the newest of them (the latest
    # backend). The `-f` guard is what makes reading line-delimited names safe
    # — the only name it could split is one containing a newline, and a split
    # name is not a file, so that candidate is dropped rather than half-read.
    while IFS= read -r s; do
        [ -f "$s" ] || continue
        if [ -z "$newest" ] || [ "$s" -nt "$newest" ]; then newest="$s"; fi
    done < <(grep -lF -- "\"wallpaper\": \"$1\"" "$WAL_CACHE"/schemes/*.json 2>/dev/null)
    [ -n "$newest" ] || return 1
    # Exactly six hex digits, so a truncated or corrupt cache entry is simply
    # not a color here rather than an arithmetic error inside the caller's
    # 16#-conversion. "color1" cannot swallow "color10": the digit is followed
    # by the closing quote.
    tr ',' '\n' <"$newest" |
        sed -n 's/.*"color[0-9]": *"#\([0-9a-fA-F]\{6\}\)".*/\1/p' | head -8
}

# An inline picture preview via kitty's graphics protocol in
# unicode-placeholder mode: icat transmits a downscaled image and emits
# placeholder cells that flow with text. icat's own output positions
# absolutely (meant for preview panes), so we strip the cursor choreography
# and re-emit just the transmission plus each line of cells, re-applying the
# image-id color per line. render_preview <file> <cols> <rows> sets PV_APC
# (transmit once), PV_ROWS[] (one padded, color-wrapped line of cells per
# row) and PV_H (row count). kitty-only by its nature.
PREVIEW_COLS=7
render_preview() { # $1 file  $2 cols  $3 rows
    [ -n "${KITTY_WINDOW_ID:-}" ] || return 1
    command -v kitten >/dev/null 2>&1 || return 1
    local out rest color line w pad i
    out=$(kitten icat --unicode-placeholder --transfer-mode=file --stdin=no \
        --use-window-size 100,50,2000,1000 \
        --place="${2}x${3}@0x0" "$1" 2>/dev/null) || return 1
    case "$out" in *$'\e\\'*) ;; *) return 1 ;; esac
    PV_APC="${out%%$'\e\\'*}"$'\e\\'
    PV_APC="${PV_APC#$'\r'}"
    rest="${out#*$'\e\\'}"
    color=$(printf '%s' "$rest" | grep -o $'\e\[38[:;][0-9:;]*m' | head -1)
    rest=$(printf '%s' "$rest" | sed $'s/\e7//g; s/\e8//g; s/\e\[[0-9;]*H//g; s/\r//g; s/\e\[[0-9]*C//g; s/\e\[39m//g; s/\e\[38[:;][0-9:;]*m//g')
    w=$(printf '%s' "$PV_APC" | sed -n 's/.*[,;]c=\([0-9]*\).*/\1/p')
    case "$w" in '' | *[!0-9]*) w=$2 ;; esac
    pad=$(( $2 - w ))
    PV_ROWS=(); PV_H=0
    i=1
    while [ "$i" -le "$3" ]; do
        line=$(printf '%s' "$rest" | sed -n "${i}p")
        [ -n "$line" ] || break
        [ "$pad" -gt 0 ] && line="$line$(printf '%*s' "$pad" '')"
        PV_ROWS+=("${color}${line}"$'\e[39m')
        PV_H=$((PV_H + 1))
        i=$((i + 1))
    done
    [ "$PV_H" -gt 0 ] || return 1
    return 0
}

# The list row's two-line thumbnail, in terms of render_preview. Keeps the
# PV_APC/PV1/PV2 shape cmd_list already prints.
wall_preview() { # $1 file
    render_preview "$1" "$PREVIEW_COLS" 2 || return 1
    PV1="${PV_ROWS[0]}"
    PV2="${PV_ROWS[1]:-$(printf '%*s' "$PREVIEW_COLS" '')}"
    return 0
}

# Wallpapers as a table, LATEST ADDED first (APFS birth time): truncated
# title plus a small render of the scheme that wallpaper derives. Schemes
# render from pywal's cache; anything missing is derived first by
# backfill_schemes (one-time ~1s per new wallpaper, instant after). Source
# (an xattr/mdls read per file), format, size, date, and the inline picture
# preview all live behind -v, so the default listing does no per-file
# metadata work beyond that.
cmd_list() {
    local cols namew f name src fmt bytes added c r g b n
    backfill_schemes
    cols=${COLUMNS:-$(tput cols 2>/dev/null || printf 100)}
    local pvok="" pvw=0
    [ -n "$VERBOSE" ] && [ -n "${KITTY_WINDOW_ID:-}" ] && command -v kitten >/dev/null 2>&1 && { pvok=1; pvw=9; }
    if [ -n "$VERBOSE" ]; then namew=$((cols - 71 - pvw)); else namew=$((cols - 32)); fi
    [ "$namew" -gt 44 ] && namew=44
    [ "$namew" -lt 16 ] && namew=16
    printf 'wallpapers\n\n'
    if [ -n "$VERBOSE" ]; then
        printf '  %s%-*s  %-24s  %-10s  %-6s  %-7s  %s\n' "${pvok:+$(printf '%-9s' PICTURE)}" "$namew" TITLE COLORSCHEME SOURCE FORMAT SIZE ADDED
    else
        printf '  %-*s  %s\n' "$namew" TITLE COLORSCHEME
    fi
    find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null |
        while IFS= read -r f; do
            printf '%s\t%s\n' "$(stat -f %B "$f" 2>/dev/null || printf 0)" "$f"
        done | sort -rn | cut -f2- |
        while IFS= read -r f; do
            name=$(basename "$f")
            name="${name%.*}"
            # Sanitize BEFORE measuring: a stripped byte must not be counted
            # against the column, and the row must never carry disk bytes to
            # the terminal as protocol.
            name=$(display_text "$name")
            [ "${#name}" -gt "$namew" ] && name="$(printf '%.*s' $((namew - 1)) "$name")…"
            PV_APC=""; PV1=""; PV2=""
            if [ -n "$pvok" ] && wall_preview "$f"; then
                printf '%s' "$PV_APC"
                printf '  %s' "$PV1"
            elif [ -n "$pvok" ]; then
                printf '  %-7s' ''
            fi
            printf '  %-*s  ' "$namew" "$name"
            # 8 swatches of 2 cells + a trailing space = exactly 24 columns of
            # visible width, so the -v columns after stay aligned; a wallpaper
            # with no cached scheme shows a single dash in that width.
            n=0
            for c in $(wall_scheme "$f"); do
                r=$((16#${c:0:2})); g=$((16#${c:2:2})); b=$((16#${c:4:2}))
                printf '\033[48;2;%d;%d;%dm  \033[0m ' "$r" "$g" "$b"
                n=$((n + 1))
            done
            [ "$n" -eq 0 ] && printf '%-24s' '-'
            [ "$n" -gt 0 ] && [ -n "$VERBOSE" ] && { while [ "$n" -lt 8 ]; do printf '   '; n=$((n + 1)); done; }
            if [ -n "$VERBOSE" ]; then
                src=$(wall_source "$f")
                # The SOURCE field is 10 wide; a longer custom host would
                # push every later column out of line.
                [ "${#src}" -gt 10 ] && src="$(printf '%.9s' "$src")…"
                fmt="${f##*.}"
                bytes=$(stat -f %z "$f" 2>/dev/null || printf 0)
                bytes=$(awk -v b="$bytes" 'BEGIN{ if (b >= 1048576) printf "%.1fM", b/1048576; else printf "%.0fK", b/1024 }')
                added=$(stat -f '%SB' -t '%Y-%m-%d' "$f" 2>/dev/null)
                printf '  %-10s  %-6s  %-7s  %s' "$src" "$fmt" "$bytes" "$added"
            fi
            printf '\n'
            # Second line of the picture preview, when one rendered.
            if [ -n "$PV2" ]; then printf '  %s\n' "$PV2"; fi
        done
}

# One wallpaper up close, styled like the list: a larger picture on the
# left (kitty graphics; skipped gracefully elsewhere) and, on the right,
# the labeled facts plus a larger render of its colorscheme. No argument
# previews the CURRENT wallpaper; a name (truncated titles welcome)
# previews that one.
cmd_preview() { # $1 optional wallpaper name/path
    local img name loc src dims bytes sw c r g b i line
    if [ -n "$1" ]; then
        img=$(resolve_local "$1") || die "no wallpaper uniquely matching '$1' (looked in $WALLPAPER_DIR)"
    else
        img=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
        [ -n "$img" ] && [ -f "$img" ] || die "no current wallpaper to preview — name one: theme preview <wallpaper>"
    fi
    backfill_schemes
    # Display copies only. $img stays byte-exact — it is what render_preview,
    # img_size, stat and wall_scheme open.
    name=$(basename "$img"); name="${name%.*}"
    name=$(display_text "$name")
    loc="$img"
    case "$loc" in "$HOME"/*) loc="~${loc#"$HOME"}" ;; esac
    loc=$(display_text "$loc")
    src=$(wall_source "$img")
    dims=$(img_size "$img")
    bytes=$(stat -f %z "$img" 2>/dev/null || printf 0)
    bytes=$(awk -v b="$bytes" 'BEGIN{ if (b >= 1048576) printf "%.1fM", b/1048576; else printf "%.0fK", b/1024 }')
    sw=""
    for c in $(wall_scheme "$img"); do
        r=$((16#${c:0:2})); g=$((16#${c:2:2})); b=$((16#${c:4:2}))
        sw="$sw$(printf '\033[48;2;%d;%d;%dm    \033[0m ' "$r" "$g" "$b")"
    done
    [ -n "$sw" ] || sw='-'
    # Values must FIT the right-hand column — a wrapped line lands at column
    # 0 and shreds the whole block — so the title truncates with … (a
    # truncated title still resolves via prefix match). LOCATION gets its own
    # full-width line under the block instead: paths are the one value too
    # long to truncate honestly, and down there a narrow window wraps nothing
    # that has to stay aligned.
    local cols availw
    cols=${COLUMNS:-$(tput cols 2>/dev/null || printf 100)}
    availw=$((cols - 22 - 13))
    [ "$availw" -lt 12 ] && availw=12
    [ "${#name}" -gt "$availw" ] && name="$(printf '%.*s' $((availw - 1)) "$name")…"
    # EVERY value in the aligned block is bounded, not just the title — a
    # custom download host in the source xattr is arbitrary-length too.
    [ "${#src}" -gt "$availw" ] && src="$(printf '%.*s' $((availw - 1)) "$src")…"
    local rlines=(
        ""
        "$(printf '%-12s %s' TITLE "$name")"
        "$(printf '%-12s %s' SOURCE "$src")"
        "$(printf '%-12s %s' SIZE "${dims:-?}${bytes:+ ($bytes)}")"
        ""
        "COLORSCHEME"
        "$sw"
        ""
    )
    printf 'wallpaper preview\n\n'
    PV_APC=""; PV_ROWS=(); PV_H=0
    if render_preview "$img" 18 8; then
        printf '%s' "$PV_APC"
        i=0
        while [ "$i" -lt 8 ]; do
            line="${PV_ROWS[$i]:-$(printf '%-18s' '')}"
            printf '  %s  %s\n' "$line" "${rlines[$i]:-}"
            i=$((i + 1))
        done
    else
        for line in "${rlines[@]}"; do
            printf '  %s\n' "$line"
        done
    fi
    printf '  %-12s %s\n' LOCATION "$loc"
    return 0
}

# Print the 16 palette colors as truecolor blocks, 8 per row — the same
# at-a-glance scheme preview kitty/nvim theme pickers give.
swatch_row() { # $@ = hex colors (with or without #)
    local c r g b i=0 total=$#
    for c in "$@"; do
        c="${c#\#}"
        r=$((16#${c:0:2})); g=$((16#${c:2:2})); b=$((16#${c:4:2}))
        printf '\033[48;2;%d;%d;%dm   \033[0m ' "$r" "$g" "$b"
        i=$((i + 1))
        [ $((i % 8)) -eq 0 ] && [ "$i" -lt "$total" ] && printf '\n                 '
    done
    return 0
}

# The 16 colors of the active scheme, one hex per line — the pywal cache, or
# whatever other conf current-theme.conf still points at.
scheme_colors() {
    local inc
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    *colors-kitty.conf) cat "$WAL_CACHE/colors" 2>/dev/null ;;
    ?*) awk '/^color([0-9]|1[0-5]) /{print $2}' "$inc" 2>/dev/null | head -16 ;;
    esac
}

cmd_status() {
    local inc mode current desk colors inc_d current_d desk_d
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") mode="unset" ;;
    *colors-kitty.conf) mode="derived from wallpaper" ;;
    *) mode="$(basename "${inc%.conf}")" ;;
    esac
    current=$(cat "$WAL_CACHE/wal" 2>/dev/null)
    desk=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    # This block prints with printf rather than note(), so it needs its own
    # display copies. $current stays byte-exact — it is the path stat'ed and
    # measured below; only what is SHOWN is sanitized. Every value here comes
    # off disk: pywal's cached wallpaper record, the desktop's own answer, and
    # the include line of current-theme.conf.
    inc_d=$(display_text "$inc"); current_d=$(display_text "$current")
    desk_d=$(display_text "$desk"); mode=$(display_text "$mode")
    printf 'current theme:   %s\n' "${desk_d:-${current_d:-<none>}}"
    printf 'mode:            %s\n' "$mode"
    colors=$(scheme_colors)
    if [ -n "$colors" ]; then
        printf 'color scheme:    '
        # shellcheck disable=SC2046
        swatch_row $(printf '%s\n' "$colors")
        printf '\n'
    else
        printf 'color scheme:    <none>\n'
    fi
    printf 'palette source:  %s\n' "${inc_d:-<none>}"
    printf 'palette image:   %s%s\n' "${current_d:-<none>}" \
        "$( [ -n "$current" ] && [ -f "$current" ] && printf ' (%s)' "$(img_size "$current")")"
    printf 'wallpaper dir:   %s (%s images)\n' "$(display_text "$WALLPAPER_DIR")" \
        "$(find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
    printf 'variables:\n'
    if [ -n "${UNSPLASH_ACCESS_KEY:-}" ]; then
        printf '  UNSPLASH_ACCESS_KEY   set (env)\n'
    elif command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-access-key -w >/dev/null 2>&1; then
        printf '  UNSPLASH_ACCESS_KEY   set (Keychain: unsplash-access-key)\n'
    else
        printf '  UNSPLASH_ACCESS_KEY   not set (theme unsplash --help)\n'
    fi
    printf '  THEME_WALLPAPER_DIR   %s\n' "$(display_text "$WALLPAPER_DIR")"
    printf '  THEME_FORMATS         %s\n' "$(display_text "${THEME_FORMATS:-$THEME_FORMATS_ALL} ${THEME_EXCLUDE_FORMATS:+(minus: $THEME_EXCLUDE_FORMATS)}")"
    printf '  WAL_CACHE             %s\n' "$(display_text "$WAL_CACHE")"
}

# Library-only resolver for DESTRUCTIVE commands (rm / rename). Unlike
# resolve_local it takes bare NAMES only — any path separator is refused, so
# `..`, absolute paths, and nested paths can never reach a destructive verb —
# and the match is re-checked by canonical physical path (symlink-proof).
resolve_library() {
    local cand="" real dirreal
    case "$1" in
    */* | .* ) return 1 ;;
    esac
    # An EXACT filename resolves directly. Anything else — a bare stem or a
    # truncated title copied from `theme list` — goes through library_match's
    # cardinality checks, so a destructive verb resolves ONLY when exactly
    # one library file matches; foo.jpg beside foo.png refuses rather than
    # deleting an arbitrary one. The canonical containment check below still
    # applies to whatever was found.
    if [ -f "$WALLPAPER_DIR/$1" ]; then
        cand="$WALLPAPER_DIR/$1"
    else
        cand=$(library_match "$1") || return 1
    fi
    [ -n "$cand" ] || return 1
    # Canonical containment: the file's physical directory must be the
    # library root or a descendant of it (the library is recursive now).
    # A symlink pointing outside still canonicalizes outside and is refused.
    dirreal=$(cd "$WALLPAPER_DIR" 2>/dev/null && pwd -P) || return 1
    real=$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P) || return 1
    case "$real" in
    "$dirreal" | "$dirreal"/*) ;;
    *) return 1 ;;
    esac
    printf '%s' "$cand"
    return 0
}

# Delete wallpapers by NAME. Destructive, so names only — never paths: the
# library-only resolver refuses separators, `..`, absolute paths, and
# out-of-library symlink targets. Deleting the on-screen wallpaper is allowed —
# macOS keeps its cached copy up until the next `theme` run.
cmd_rm() {
    local name img cur
    cur=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    for name in "$@"; do
        img=$(resolve_library "$name") ||
            die "no wallpaper named '$name' in $WALLPAPER_DIR (rm takes library NAMES, never paths)"
        rm "$img" || die "could not delete $img"
        note "successfully deleted \"$(basename "$img")\""
        [ "$img" = "$cur" ] && note "that was the current wallpaper — pick a new one with theme set / theme random"
    done
    return 0
}

# Rename a wallpaper, keeping the library's naming format (slug + original
# extension). If it is the CURRENT wallpaper, the desktop is re-pointed so the
# rename never breaks what is on screen.
cmd_rename() {
    local img new base dest cur
    img=$(resolve_library "$1") ||
        die "no wallpaper named '$1' in $WALLPAPER_DIR (rename takes library NAMES, never paths)"
    shift
    new="$*"
    [ -n "$new" ] || die "usage: theme rename <wallpaper> <new name…>   (see theme rename --help)"
    base=$(slugify "$new")
    [ -n "$base" ] || die "that name slugifies to nothing — give it at least one letter or digit"
    dest="$(dirname "$img")/$base.${img##*.}"
    [ "$dest" = "$img" ] && { note "already named $(basename "$img")"; return 0; }
    # `-L` for the same reason as save_wallpaper: a dangling symlink is an
    # occupied name, not a free one.
    { [ -e "$dest" ] || [ -L "$dest" ]; } &&
        die "$(basename "$dest") already exists"
    mv "$img" "$dest" || die "rename failed"
    note "successfully renamed \"$(basename "$img")\" to \"$(basename "$dest")\""
    cur=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    if [ "$cur" = "$img" ]; then
        set_desktop "$dest"
        note "desktop re-pointed at the new name"
    fi
    # Keep pywal's record accurate too, so `theme status` stays truthful.
    if [ "$(cat "$WAL_CACHE/wal" 2>/dev/null)" = "$img" ]; then
        printf '%s' "$dest" >"$WAL_CACHE/wal" 2>/dev/null || true
    fi
    return 0
}

usage() {
    local desk inc label colors term os
    desk=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") label="" ;;
    *colors-kitty.conf) label="" ;;
    *) label="$(basename "${inc%.conf}")" ;;
    esac
    printf '  current theme:      %s\n' "$(display_text "${desk:-<none>}")"
    colors=$(scheme_colors)
    if [ -n "$colors" ]; then
        printf '  colorscheme:        '
        # shellcheck disable=SC2046
        swatch_row $(printf '%s\n' "$colors" | head -8)
        printf '%s\n' "${label:+ $(display_text "$label")}"
    else
        printf '  colorscheme:        <none>\n'
    fi
    # This header printfs directly instead of going through note(), so each
    # runtime value needs its own display copy — $desk and $label above, $term
    # and $os here. The kitty branch is the ONE trusted exception: that OSC 8
    # hyperlink is our own literal, so it is assigned WITHOUT display_text,
    # which would otherwise strip the very sequence it exists to emit.
    if [ -n "${KITTY_WINDOW_ID:-}" ]; then
        term=$(printf '\033]8;;https://sw.kovidgoyal.net/kitty/\akitty\033]8;;\a')
    else
        # TERM_PROGRAM and TERM are environment data — a terminal profile, an
        # inherited ssh environment or a hostile parent can put an OSC 52
        # clipboard write in either, and this line prints it as a fact.
        term=$(display_text "${TERM_PROGRAM:-$TERM}")
    fi
    printf '  terminal:           %s\n' "$term"
    # uname/sw_vers are resolved through PATH, so this output is not ours to
    # trust either, and being sure costs one call.
    if [ "$(uname -s)" = Darwin ]; then
        os="macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    else
        os=$(uname -srm)
    fi
    printf '  os:                 %s\n' "$(display_text "$os")"
    cat <<EOF

Apply Commands:
  set             apply a wallpaper: local name/path, or any actionable link
  random          random wallpaper from the configured wallpaper folder
  unsplash        Unsplash photos: search, page-url, random; auth and status
  url             download a direct image URL or Pinterest pin, save it, apply it

Library Commands:
  list            wallpaper table: title + colorscheme (-v adds source, format, size, date)
  preview         one wallpaper up close: picture, colorscheme, title, location
  rename          rename a saved wallpaper, keeping the naming format
  rm              delete saved wallpapers by name

Info Commands:
  status          current theme, color-scheme swatches, variables
  help            this text (per-command: theme <command> --help)

Usage:
  theme <command> [flags]

Global Flags (any image command):
  --rotate left|right    turn the image 90° before applying
  --extend[=RRGGBB]      centre flat art on a matching canvas (default 000000)

Use "theme <command> --help" for more information about a given command.
EOF
}

# Per-subcommand help for `theme <cmd> --help`.
#
# These blocks are heredocs, so they interpolate straight to the terminal
# without passing through note()/die(). WALLPAPER_DIR is configuration data —
# an environment variable, or a directory whose own name may legally contain
# an OSC 52 clipboard write — so it is sanitized ONCE here and every block
# below prints $wdir. One point of sanitization is what keeps this from
# becoming five per-sink patches that a sixth block forgets; the help sweep in
# the fixture is what proves no block prints the raw value.
#
# $wdir is display-only and is never opened, listed or written: the
# operational WALLPAPER_DIR is untouched, exactly as everywhere else.
# Per-command help. Every body below is an UNQUOTED heredoc, because $wdir has
# to expand — which means backticks and $(…) inside them are LIVE COMMAND
# SUBSTITUTION, executed just by rendering the help. Quote example commands
# with 'single quotes', never backticks: a backticked `theme unsplash random`
# here would fetch and apply a wallpaper on every --help, and any example that
# renders help again would recurse. Escape a backtick (\`) if one is truly
# needed. Keep help text generic and extensible, and never let it grow —
# additions pay for themselves by consolidating something else (owner
# directive 2026-08-30).
usage_cmd() {
    local wdir
    wdir=$(display_text "$WALLPAPER_DIR")
    case "$1" in
    random) cat <<EOF
theme random [--rotate left|right] [--extend[=RRGGBB]]

  Pick a random wallpaper from $wdir and apply it everywhere:
  desktop wallpaper + kitty recolor (live windows and future ones).

  Examples:
    theme random
    theme random --rotate right
EOF
        ;;
    set) cat <<EOF
theme set <image | url> [--rotate left|right] [--extend[=RRGGBB]]

  Apply a specific wallpaper: desktop + palette + kitty. <image> is a
  path or a name under $wdir (extension optional). set also
  understands actionable links: an unsplash.com/photos/… page routes
  through 'theme unsplash', any other URL through 'theme url'.

  Examples:
    theme set spain-city-mountains
    theme set nebulosa-red.png --extend
    theme set https://unsplash.com/photos/a-computer-screen-with-a-wave-on-it-mOpfECCgeC4
EOF
        ;;
    unsplash) cat <<EOF
theme unsplash <query… | photo-url | subcommand> [--rotate left|right] [--extend[=RRGGBB]]

  Fetch an Unsplash photo into $wdir — named from your query plus
  the photo's own description — then apply it (desktop + palette +
  kitty). Downloads the RAW original rendition, preferring 3840px+ on
  search. A query needs no quotes; a photo page link
  (unsplash.com/photos/…) fetches exactly that photo. Bare
  'theme unsplash' shows this help.

  Subcommands:
    random    fully random photo (landscape, high resolution)
    auth      one-time account link (OAuth): Unsplash+ photos then
              download watermark-free, like the site's Download button —
              without it they arrive WATERMARKED. Needs the app secret
              once (env UNSPLASH_SECRET_KEY / Keychain 'unsplash-secret-key')
    status    API window: requests left, tier, key source, linked
              account (costs 1 request)

  Needs UNSPLASH_ACCESS_KEY or the 'unsplash-access-key' Keychain item.

  Examples:
    theme unsplash random
    theme unsplash neon city rain
    theme unsplash https://unsplash.com/photos/winged-person-with-halo-in-sky-coy_MhYMLHs
    theme unsplash auth
EOF
        ;;
    url) cat <<EOF
theme url <link> [--rotate left|right]

  Download an image from a direct URL or a Pinterest pin page, save it
  into $wdir, then apply it (desktop + palette + kitty).

  Sharpness: direct i.pinimg.com /NNNx/ downscales are auto-upgraded to
  the full-resolution /originals/ variant when it exists, and the desktop
  is set in fill mode (crop to cover — never letterbox bars).
  --rotate turns a portrait pin 90° into a landscape before applying.
  --extend centres flat-background art on a matching-color canvas instead.

  Examples:
    theme url https://www.pinterest.com/pin/300685712645323833/
    theme url https://i.pinimg.com/1200x/39/76/d8/3976d….jpg --rotate right
    theme url https://i.pinimg.com/736x/cc/a1/35/cca13….jpg --extend
EOF
        ;;
    list) cat <<EOF
theme list [-v]

  Wallpapers as a table sorted by LATEST ADDED. Columns: title
  (truncated to the terminal) and a small render of the colorscheme
  that wallpaper derives (cached; anything missing is derived once on
  the first listing, instant after). -v adds a small picture preview
  (kitty graphics; in kitty only) plus source — the site it came from,
  recorded at download time or read from macOS download metadata, "-"
  when unknown — format, size, and date added.

  A truncated title copied from the table (with or without the …)
  works in set/rename/rm when only one wallpaper starts with it.

  Examples:
    theme list
    theme list -v
EOF
        ;;
    preview) cat <<EOF
theme preview [name]

  One wallpaper up close, styled like the list: a larger picture on the
  left (kitty only; skipped elsewhere) and the labeled facts on the
  right — title, location (~/path), source, size — plus a larger render
  of its colorscheme. With no name it previews the CURRENT wallpaper; a
  truncated title copied from theme list works when uniquely matched.

  Examples:
    theme preview
    theme preview neon-pink-and-purple-light-particles
    theme preview trees-on-forest…
EOF
        ;;
    status) cat <<EOF
theme status

  Show the current theme: wallpaper path, mode, the color
  scheme as truecolor swatches (like nvim/kitty theme pickers), palette
  source, and the variables the CLI reads (Unsplash key presence — never
  the value — wallpaper dir, palette cache).

  Example:
    theme status
EOF
        ;;
    rename) cat <<EOF
theme rename <wallpaper> <new name…>

  Rename a saved wallpaper, keeping the library's naming format (the new
  name is slugified, the extension stays). The new name needs no quotes.
  If it is the current wallpaper, the desktop is re-pointed automatically.

  Examples:
    theme rename pinterest-20260829-181509-extended.jpg red-samurai-poster
    theme rename starry-boat-3840x2160-v0-uyzg0992aegb1 starry boat painting
EOF
        ;;
    rm) cat <<EOF
theme rm <wallpaper…>

  Delete saved wallpapers by name — resolved in $wdir like
  \`set\`/\`rename\` (extension optional), so no path is needed. Only
  library files can be deleted. Several names at once are fine.

  Examples:
    theme rm albedo-wings-black
    theme rm old-one.jpg other-old-one
EOF
        ;;
    help | '') usage ;;
    *)
        # A typo like `theme unplash --help` should SAY so, not silently
        # answer with the global usage as if the command existed — and it is
        # an ERROR, so the exit status says so too.
        printf 'theme: unknown command %s — full usage:\n\n' "'$(display_text "$1")'" >&2
        usage
        return 1
        ;;
    esac
}

# --- dispatch --------------------------------------------------------------

# Built here, not at the top of the file: an emptied format set dies through
# display_text, which (like every helper) is only guaranteed defined once the
# whole file has been read.
build_img_glob


# --rotate left|right turns the image 90° before it is saved and applied, so a
# portrait Pinterest pin becomes a landscape that fills the desktop. Parsed out
# here (any position) so the subcommands stay flag-free.
ROTATE=""
EXTEND=""
VERBOSE=""
SOURCE_URL=""
_args=()
_want=""
for _a in "$@"; do
    if [ -n "$_want" ]; then ROTATE="$_a"; _want=""; continue; fi
    case "$_a" in
    --rotate) _want=1 ;;
    --rotate=*) ROTATE="${_a#*=}" ;;
    --extend) EXTEND="000000" ;;
    --extend=*) EXTEND="${_a#*=}"; EXTEND="${EXTEND#\#}" ;;
    -v | --verbose) VERBOSE=1 ;;
    *) _args+=("$_a") ;;
    esac
done
[ -z "$_want" ] || die "--rotate takes left or right"
set -- "${_args[@]}"
case "$ROTATE" in '' | left | right) ;; *) die "--rotate takes left or right" ;; esac
case "$EXTEND" in
'' ) ;;
[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
*) die "--extend takes a 6-digit hex color (default 000000)" ;;
esac

# Validate the ENTIRE normalized argv before dispatch: `--help` anywhere means
# help for the command, and any other leading-dash token anywhere is refused
# HERE — before a single side effect, so `theme rm victim --bogus` deletes
# nothing (Codex re-review finding 1: the old ${2}-only check let trailing
# junk through, or fired only after earlier arguments had already mutated).
_first=1
_help=0
for _a in "$@"; do
    if [ "$_first" = 1 ]; then _first=0; continue; fi
    case "$_a" in
    -h | --help) _help=1 ;;
    -*) die "unknown option '$_a' for 'theme ${1}' — try: theme ${1} --help" ;;
    esac
done
if [ "$_help" = 1 ]; then
    usage_cmd "${1:-}"
    exit $?
fi

case "${1:-help}" in
random) cmd_local "" ;;
set)
    # set is generic over SOURCES: an Unsplash photo page routes through the
    # unsplash path (API metadata, credit, clean Unsplash+ files once
    # linked), any other URL through the url path, anything else is a
    # library name. Same validation as calling those commands directly.
    [ -n "${2:-}" ] || die "usage: theme set <image | url>"
    case "$2" in
    https://unsplash.com/photos/?* | https://www.unsplash.com/photos/?*) cmd_unsplash "$2" ;;
    *://*) cmd_url "$2" ;;
    *) cmd_local "$2" ;;
    esac
    ;;
unsplash)
    shift
    # kubectl-style root: bare `theme unsplash` is the command's help, not a
    # surprise download — the random fetch is the explicit `random` subcommand.
    if [ $# -eq 0 ]; then usage_cmd unsplash
    elif [ "$1" = status ] && [ $# -eq 1 ]; then cmd_unsplash_status
    elif [ "$1" = auth ] && [ $# -eq 1 ]; then cmd_unsplash_auth
    elif [ "$1" = random ] && [ $# -eq 1 ]; then cmd_unsplash ""
    else cmd_unsplash "$*"; fi
    ;;
url) cmd_url "${2:-}" ;;
list) cmd_list ;;
preview) cmd_preview "${2:-}" ;;
status) cmd_status ;;
rename) shift; [ -n "${1:-}" ] || die "usage: theme rename <wallpaper> <new name…>"; cmd_rename "$@" ;;
rm) shift; [ -n "${1:-}" ] || die "usage: theme rm <wallpaper…>"; cmd_rm "$@" ;;
help | -h | --help) usage ;;
*) die "unknown command '$1' — run 'theme help' for the list" ;;
esac
