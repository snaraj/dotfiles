#!/usr/bin/env bash
# theme — desktop wallpaper + terminal palette CLI (pywal / static kitty themes).
# Full documentation: ~/.config/scripts/README.md
# Set THEME_NO_APPLY=1 to exercise every code path without touching the desktop.

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config}"
KITTY_DIR="${KITTY_CONFIG_DIRECTORY:-$CONFIG_DIR/kitty}"
THEMES_DIR="$KITTY_DIR/themes"
CURRENT="$KITTY_DIR/current-theme.conf"
WALLPAPER_DIR="${WALLPAPER_DIR:-$CONFIG_DIR/wallpapers/pc}"
WAL_CACHE="${WAL_CACHE:-$HOME/.cache/wal}"
MIN_WIDTH=2560
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
IMG_GLOB=(-iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif')

die() { printf 'theme: %s\n' "$*" >&2; exit 1; }
note() { printf 'theme: %s\n' "$*"; }
dry() { [ -n "${THEME_NO_APPLY:-}" ]; }

# --- small utilities -------------------------------------------------------

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

# "3840x2160", or empty when the dimensions cannot be read.
img_size() {
    if command -v sips >/dev/null 2>&1; then
        sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null |
            awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w) print w "x" h}'
    else
        file -b "$1" 2>/dev/null | grep -Eo '[0-9]+ ?x ?[0-9]+' | head -1 | tr -d ' '
    fi
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
    curl -fsL --max-time 60 -A "$UA" -o "$2" "$up" && return 0
    [ "$up" = "$1" ] && return 1
    curl -fsL --max-time 60 -A "$UA" -o "$2" "$1"
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
    while [ -e "$dest" ]; do
        if [ "$(hash_of "$1")" = "$(hash_of "$dest")" ]; then
            SAVED="$dest"
            note "already have $(basename "$dest") — reusing it"
            return 0
        fi
        dest="$WALLPAPER_DIR/$base-$n.$ext"
        n=$((n + 1))
    done
    cp "$1" "$dest" || die "cannot write $dest"
    chmod 644 "$dest"
    SAVED="$dest"
    local size w; size=$(img_size "$dest"); w="${size%%x*}"
    note "saved $(basename "$dest")${size:+ ($size)}"
    if [ -n "$w" ] && [ "$w" -lt "$MIN_WIDTH" ] 2>/dev/null; then
        note "warning: only ${w}px wide, below the ${MIN_WIDTH}px desktop floor"
    fi
    return 0
}

# --- applying --------------------------------------------------------------

# Recolor every RUNNING kitty instance. $1 = the colors file just activated.
# Remote control (kitty.conf: allow_remote_control socket-only + listen_on
# unix:/tmp/kitty-samuel) is the reliable path — a running instance ignores
# SIGUSR1 on this machine, and its windows (old and new) keep the in-memory
# palette forever. set-colors --configured also updates the instance's stored
# config, so windows opened later inherit the new palette too. SIGUSR1 stays
# as a fallback for instances started before the socket config existed.
reload_kitty() {
    local sock applied=0
    for sock in /tmp/kitty-samuel-*; do
        [ -S "$sock" ] || continue
        if kitten @ --to "unix:$sock" set-colors --all --configured "$1" 2>/dev/null; then
            applied=1
        fi
    done
    [ "$applied" = 1 ] || pkill -USR1 -x kitty 2>/dev/null
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
    dry && { note "[no-apply] would derive a pywal palette from $1"; return 0; }
    command -v wal >/dev/null 2>&1 || die "pywal not installed (pipx install pywal)"
    wal -i "$1" --backend colorz >/dev/null 2>&1 || wal -i "$1" >/dev/null 2>&1 ||
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

# --- local wallpapers ------------------------------------------------------

resolve_local() {
    local f
    [ -f "$1" ] && { printf '%s' "$1"; return 0; }
    [ -f "$WALLPAPER_DIR/$1" ] && { printf '%s' "$WALLPAPER_DIR/$1"; return 0; }
    for f in "$WALLPAPER_DIR/$1".*; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

random_local() {
    find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null |
        awk 'BEGIN {srand()} {print rand() "\t" $0}' | sort -n | cut -f2- | head -n 1
}

cmd_local() { # $1 = image argument, or empty for a random pick
    local img tmp mime
    if [ -n "$1" ]; then
        img=$(resolve_local "$1") || die "no such wallpaper '$1' (looked in $WALLPAPER_DIR)"
    else
        img=$(random_local)
        [ -n "$img" ] || die "no images found in $WALLPAPER_DIR"
    fi
    if [ -n "$ROTATE" ]; then
        # Never rotate the library file itself — save the turned copy as its
        # own wallpaper so both orientations stay available.
        tmp=$(mktemp -t theme) || die "mktemp failed"
        trap 'rm -f "$tmp"' EXIT
        cp "$img" "$tmp" || die "cannot copy $img"
        rotate_image "$tmp" "$ROTATE"
        mime=$(file -b --mime-type "$tmp")
        save_wallpaper "$tmp" "$mime" "$(basename "${img%.*}") rotated $ROTATE"
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
print("\t".join(str(x) for x in (
    u.get("full") or u.get("raw", ""), best.get("width", 0), best.get("height", 0),
    name,
    (best.get("links") or {}).get("download_location", ""),
    (best.get("user") or {}).get("name", ""))))
'

unsplash_key() {
    [ -n "${UNSPLASH_ACCESS_KEY:-}" ] && { printf '%s' "$UNSPLASH_ACCESS_KEY"; return 0; }
    command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-access-key -w 2>/dev/null
}

cmd_unsplash() {
    local key url json img_url w h slug dl who tmp
    key=$(unsplash_key)
    [ -n "$key" ] || die "no Unsplash key: export UNSPLASH_ACCESS_KEY, or run \`security add-generic-password -s unsplash-access-key -a \"\$USER\" -w\` after getting a free key at https://unsplash.com/oauth/applications"
    url="https://api.unsplash.com/photos/random?count=5&orientation=landscape&content_filter=high"
    [ -n "$1" ] && url="$url&query=$(printf '%s' "$1" | sed 's/ /%20/g')"
    # The key goes to curl via stdin config, never argv, so it stays out of `ps`.
    json=$(printf 'header = "Authorization: Client-ID %s"\n' "$key" |
        curl -fsL --max-time 30 -K - "$url") || die "Unsplash request failed (bad key, rate limit, or no network)"
    IFS=$'\t' read -r img_url w h slug dl who < <(printf '%s' "$json" | python3 -c "$UNSPLASH_PY") ||
        die "Unsplash returned no usable photo"
    [ -n "$img_url" ] || die "Unsplash returned no image URL"
    [ "$w" -ge 3840 ] 2>/dev/null || note "best of 5 candidates is ${w}x${h} (wanted 3840px+)"
    tmp=$(mktemp -t theme) || die "mktemp failed"
    trap 'rm -f "$tmp"' EXIT
    curl -fsL --max-time 90 -A "$UA" -o "$tmp" "$img_url" || die "photo download failed"
    local mime; mime=$(file -b --mime-type "$tmp")
    case "$mime" in image/*) ;; *) die "Unsplash served $mime, not an image" ;; esac
    # Name = your search prompt (when given) + the photo's own description —
    # a wallpaper you can find again, not a slug with an id tail. The
    # photographer is credited in the terminal note, not the filename.
    maybe_rotate "$tmp"
    save_wallpaper "$tmp" "$mime" "${1:+$1 }$slug${ROTATE:+ rotated $ROTATE}"
    # Unsplash API guideline: report the download so the photographer is credited.
    [ -n "$dl" ] && printf 'header = "Authorization: Client-ID %s"\n' "$key" |
        curl -fs --max-time 15 -K - -o /dev/null "$dl" 2>/dev/null
    [ -n "$who" ] && note "photo by $who on Unsplash"
    use_image "$SAVED"
}

cmd_url() {
    local link="$1" tmp mime hint meta page_img page_title
    [ -n "$link" ] || die "usage: theme url <image-url | pinterest-pin-url>"
    tmp=$(mktemp -t theme) || die "mktemp failed"
    trap 'rm -f "$tmp"' EXIT
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
    fetch_best "$link" "$tmp" || die "download failed: $link"
    link="$FETCHED"
    mime=$(file -b --mime-type "$tmp")
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
        meta=$(python3 -c "$OG_PY" <"$tmp") || die "could not parse the page at $link"
        page_img=$(printf '%s\n' "$meta" | sed -n 1p)
        page_title=$(printf '%s\n' "$meta" | sed -n 2p)
        [ -n "$page_img" ] || die "no og:image on that page — pass a direct image URL instead"
        fetch_best "$page_img" "$tmp" || die "download failed: $page_img"
        mime=$(file -b --mime-type "$tmp")
        case "$mime" in image/*) ;; *) die "resolved link is $mime, not an image" ;; esac
        hint="${page_title:-$(name_hint "$page_img")}"
        ;;
    *) die "that URL is $mime, not an image" ;;
    esac
    maybe_rotate "$tmp"
    save_wallpaper "$tmp" "$mime" "$hint${ROTATE:+ rotated $ROTATE}"
    use_image "$SAVED"
}

# --- reporting -------------------------------------------------------------

static_themes() { local f; for f in "$THEMES_DIR"/*.conf; do [ -e "$f" ] && basename "$f" .conf; done; return 0; }

cmd_list() {
    printf 'wallpapers (%s):\n' "$WALLPAPER_DIR"
    find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null |
        sed "s#^$WALLPAPER_DIR/#  #" | sort
    printf '\nstatic themes (%s):\n' "$THEMES_DIR"
    static_themes | sed 's/^/  /'
}

cmd_status() {
    local inc mode current desk
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") mode="unset" ;;
    *colors-kitty.conf) mode="pywal" ;;
    *) mode="static ($(basename "${inc%.conf}"))" ;;
    esac
    current=$(cat "$WAL_CACHE/wal" 2>/dev/null)
    desk=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#')
    printf 'mode:            %s\n' "$mode"
    printf 'palette source:  %s\n' "${inc:-<none>}"
    printf 'pywal image:     %s%s\n' "${current:-<none>}" \
        "$( [ -n "$current" ] && [ -f "$current" ] && printf ' (%s)' "$(img_size "$current")")"
    printf 'desktop image:   %s\n' "${desk:-<unknown on this platform>}"
    printf 'wallpaper dir:   %s (%s images)\n' "$WALLPAPER_DIR" \
        "$(find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
}

usage() {
    cat <<EOF
theme — wallpaper + terminal palette

  theme wal [image]      pywal colors + desktop from a local image (random if omitted)
  theme random           random local wallpaper: desktop + pywal
  theme set <image>      specific local wallpaper (path, or name under the wallpaper dir)
  theme static [name]    fixed kitty theme (default catppuccin-mocha)
  theme unsplash [query…] fetch a random high-res Unsplash photo, save it, apply it
                         (multi-word queries work bare: theme unsplash neon city rain)
  theme url <link>       direct image URL or Pinterest pin: download, save, apply
                         (pinimg /NNNx/ downscales auto-upgrade to /originals/)
  theme list             local wallpapers and static themes
  theme status           current mode, wallpaper, and palette source
  theme help             this text

  --rotate left|right    turn the image 90° first (any image command) — portrait
                         pins become landscape; desktop is set in fill mode
                         (crop to cover, never letterbox bars)

static themes: $(static_themes | paste -sd' ' -)
docs: $CONFIG_DIR/scripts/README.md
EOF
}

# Per-subcommand help for `theme <cmd> --help`.
usage_cmd() {
    case "$1" in
    wal) cat <<EOF
theme wal [image]

  Derive a pywal palette from a local image and apply it everywhere:
  desktop wallpaper + kitty recolor (live windows and future ones).
  [image] is a path or a name under $WALLPAPER_DIR (extension optional).
  No image = a random local wallpaper.
EOF
        ;;
    random) printf 'theme random\n\n  Same as `theme wal` with no image: random local wallpaper, applied.\n' ;;
    set) cat <<EOF
theme set <image>

  Apply a specific local wallpaper: desktop + pywal palette + kitty.
  <image> is a path or a name under $WALLPAPER_DIR (extension optional).
EOF
        ;;
    static) cat <<EOF
theme static [name]

  Switch kitty to a fixed theme from $THEMES_DIR (no pywal, wallpaper
  untouched). Default: catppuccin-mocha. Available: $(static_themes | paste -sd' ' -)
EOF
        ;;
    unsplash) cat <<EOF
theme unsplash [query…]

  Fetch a random high-res (3840px+ preferred) Unsplash photo, save it
  into $WALLPAPER_DIR — named from your query plus the photo's own
  description — then apply it (desktop + pywal + kitty).

  The query needs no quotes:  theme unsplash neon city rain
  No query = fully random. Needs UNSPLASH_ACCESS_KEY or the
  'unsplash-access-key' Keychain item (see scripts/README.md).
EOF
        ;;
    url) cat <<EOF
theme url <link> [--rotate left|right]

  Download an image from a direct URL or a Pinterest pin page, save it
  into $WALLPAPER_DIR, then apply it (desktop + pywal + kitty).

  Sharpness: direct i.pinimg.com /NNNx/ downscales are auto-upgraded to
  the full-resolution /originals/ variant when it exists, and the desktop
  is set in fill mode (crop to cover — never letterbox bars).
  --rotate turns a portrait pin 90° into a landscape before applying.
EOF
        ;;
    list) printf 'theme list\n\n  List local wallpapers and static kitty themes.\n' ;;
    status) printf 'theme status\n\n  Show current mode (pywal/static), wallpaper, and palette source.\n' ;;
    help | '') usage ;;
    *)
        # A typo like `theme unplash --help` should SAY so, not silently
        # answer with the global usage as if the command existed.
        printf 'theme: unknown command %s — full usage:\n\n' "'$1'" >&2
        usage
        ;;
    esac
}

# --- dispatch --------------------------------------------------------------

# --rotate left|right turns the image 90° before it is saved and applied, so a
# portrait Pinterest pin becomes a landscape that fills the desktop. Parsed out
# here (any position) so the subcommands stay flag-free.
ROTATE=""
_args=()
_want=""
for _a in "$@"; do
    if [ -n "$_want" ]; then ROTATE="$_a"; _want=""; continue; fi
    case "$_a" in
    --rotate) _want=1 ;;
    --rotate=*) ROTATE="${_a#*=}" ;;
    *) _args+=("$_a") ;;
    esac
done
[ -z "$_want" ] || die "--rotate takes left or right"
set -- "${_args[@]}"
case "$ROTATE" in '' | left | right) ;; *) die "--rotate takes left or right" ;; esac

# `theme <cmd> --help` means help for THAT command, never an argument — and no
# subcommand takes other flags, so any remaining leading dash is a mistake.
case "${2:-}" in
-h | --help) usage_cmd "${1:-}"; exit 0 ;;
-*) usage >&2; die "unknown option '${2}' for 'theme ${1}'" ;;
esac

case "${1:-help}" in
wal) cmd_local "${2:-}" ;;
random) cmd_local "" ;;
set) [ -n "${2:-}" ] || die "usage: theme set <image>"; cmd_local "$2" ;;
static)
    name="${2:-catppuccin-mocha}"
    file="$THEMES_DIR/$name.conf"
    [ -f "$file" ] || die "no such theme '$name' in $THEMES_DIR (have: $(static_themes | paste -sd' ' -))"
    if dry; then
        note "[no-apply] would select static theme '$name'"
    else
        printf 'include %s\n' "$file" >"$CURRENT" || die "cannot write $CURRENT"
        reload_kitty "$file"
    fi
    note "static theme '$name'"
    ;;
unsplash) shift; cmd_unsplash "$*" ;;
url) cmd_url "${2:-}" ;;
list) cmd_list ;;
status) cmd_status ;;
help | -h | --help) usage ;;
*) usage >&2; die "unknown command '$1'" ;;
esac
