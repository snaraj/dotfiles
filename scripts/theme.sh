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
# Remote control (kitty.conf: allow_remote_control password + listen_on
# unix:/tmp/kitty-samuel + remote_control_password "" set-colors, i.e. a
# passwordless socket client may call set-colors and NOTHING else) is the
# reliable path — a running instance ignores SIGUSR1 on this machine, and its
# windows (old and new) keep the in-memory palette forever. set-colors
# --configured also updates the instance's stored config, so windows opened
# later inherit the new palette too. SIGUSR1 stays as a fallback for instances
# started before the socket config existed.
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
    local img mime
    if [ -n "$1" ]; then
        img=$(resolve_local "$1") || die "no such wallpaper '$1' (looked in $WALLPAPER_DIR)"
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
    local key url json img_url w h slug dl who
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
    scratch_new
    curl -fsL --max-time 90 -A "$UA" -o "$SCRATCH" "$img_url" || die "photo download failed"
    local mime; mime=$(file -b --mime-type "$SCRATCH")
    case "$mime" in image/*) ;; *) die "Unsplash served $mime, not an image" ;; esac
    # Name = your search prompt (when given) + the photo's own description —
    # a wallpaper you can find again, not a slug with an id tail. The
    # photographer is credited in the terminal note, not the filename.
    maybe_rotate "$SCRATCH"
    maybe_extend "$SCRATCH"
    save_wallpaper "$SCRATCH" "$mime" "${1:+$1 }$slug${ROTATE:+ rotated $ROTATE}${EXTEND:+ extended}"
    scratch_done
    # Unsplash API guideline: report the download so the photographer is credited.
    [ -n "$dl" ] && printf 'header = "Authorization: Client-ID %s"\n' "$key" |
        curl -fs --max-time 15 -K - -o /dev/null "$dl" 2>/dev/null
    [ -n "$who" ] && note "photo by $who on Unsplash"
    use_image "$SAVED"
}

cmd_url() {
    local link="$1" mime hint meta page_img page_title
    [ -n "$link" ] || die "usage: theme url <image-url | pinterest-pin-url>"
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

static_themes() { local f; for f in "$THEMES_DIR"/*.conf; do [ -e "$f" ] && basename "$f" .conf; done; return 0; }

cmd_list() {
    printf 'wallpapers (%s):\n' "$WALLPAPER_DIR"
    find "$WALLPAPER_DIR" -type f \( "${IMG_GLOB[@]}" \) 2>/dev/null |
        sed "s#^$WALLPAPER_DIR/#  #" | sort
    printf '\nstatic themes (%s):\n' "$THEMES_DIR"
    static_themes | sed 's/^/  /'
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

# The 16 colors of the active scheme, one hex per line — pywal cache or a
# static kitty theme file, whichever current-theme.conf points at.
scheme_colors() {
    local inc
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    *colors-kitty.conf) cat "$WAL_CACHE/colors" 2>/dev/null ;;
    ?*) awk '/^color([0-9]|1[0-5]) /{print $2}' "$inc" 2>/dev/null | head -16 ;;
    esac
}

cmd_status() {
    local inc mode current desk colors
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") mode="unset" ;;
    *colors-kitty.conf) mode="pywal" ;;
    *) mode="static ($(basename "${inc%.conf}"))" ;;
    esac
    current=$(cat "$WAL_CACHE/wal" 2>/dev/null)
    desk=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    printf 'current theme:   %s\n' "${desk:-${current:-<none>}}"
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
    printf 'palette source:  %s\n' "${inc:-<none>}"
    printf 'pywal image:     %s%s\n' "${current:-<none>}" \
        "$( [ -n "$current" ] && [ -f "$current" ] && printf ' (%s)' "$(img_size "$current")")"
    printf 'wallpaper dir:   %s (%s images)\n' "$WALLPAPER_DIR" \
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
    printf '  WALLPAPER_DIR         %s\n' "$WALLPAPER_DIR"
    printf '  WAL_CACHE             %s\n' "$WAL_CACHE"
}

# Library-only resolver for DESTRUCTIVE commands (rm / rename). Unlike
# resolve_local it takes bare NAMES only — any path separator is refused, so
# `..`, absolute paths, and nested paths can never reach a destructive verb —
# and the match is re-checked by canonical physical path (symlink-proof).
resolve_library() {
    local cand="" f real dirreal
    case "$1" in
    */* | .* ) return 1 ;;
    esac
    if [ -f "$WALLPAPER_DIR/$1" ]; then
        cand="$WALLPAPER_DIR/$1"
    else
        for f in "$WALLPAPER_DIR/$1".*; do
            [ -f "$f" ] && { cand="$f"; break; }
        done
    fi
    [ -n "$cand" ] || return 1
    dirreal=$(cd "$WALLPAPER_DIR" 2>/dev/null && pwd -P) || return 1
    real=$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P) || return 1
    [ "$real" = "$dirreal" ] || return 1
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
        [ "$img" = "$cur" ] && note "that was the current wallpaper — pick a new one with theme wal / theme set"
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
    [ -e "$dest" ] && die "$(basename "$dest") already exists"
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
  theme status           current theme, color-scheme swatches, variables
  theme rename <w> <n…>  rename a saved wallpaper, keeping the naming format
  theme rm <w…>          delete saved wallpapers by name (no path needed)
  theme help             this text  (theme <command> --help = per-command help)

  --rotate left|right    turn the image 90° first (any image command) — portrait
                         pins become landscape; desktop is set in fill mode
                         (crop to cover, never letterbox bars)
  --extend[=RRGGBB]      centre the design and grow the canvas to the screen's
                         shape in a solid color (default 000000) — for art on a
                         flat background: no crop, no zoom, no visible seams

static themes: $(static_themes | paste -sd' ' -)
docs: $CONFIG_DIR/scripts/README.md
EOF
}

# Per-subcommand help for `theme <cmd> --help`.
usage_cmd() {
    case "$1" in
    wal) cat <<EOF
theme wal [image] [--rotate left|right] [--extend[=RRGGBB]]

  Derive a pywal palette from a local image and apply it everywhere:
  desktop wallpaper + kitty recolor (live windows and future ones).
  [image] is a path or a name under $WALLPAPER_DIR (extension optional).
  No image = a random local wallpaper.

  Examples:
    theme wal                          # random local wallpaper
    theme wal night-sky-city-blue-lights
    theme wal ~/Downloads/pic.jpg --rotate right
EOF
        ;;
    random) cat <<EOF
theme random

  Same as \`theme wal\` with no image: random local wallpaper, applied.

  Example:
    theme random
EOF
        ;;
    set) cat <<EOF
theme set <image> [--rotate left|right] [--extend[=RRGGBB]]

  Apply a specific local wallpaper: desktop + pywal palette + kitty.
  <image> is a path or a name under $WALLPAPER_DIR (extension optional).

  Examples:
    theme set spain-city-mountains
    theme set nebulosa-red.png --extend
EOF
        ;;
    static) cat <<EOF
theme static [name]

  Switch kitty to a fixed theme from $THEMES_DIR (no pywal, wallpaper
  untouched). Default: catppuccin-mocha. Available: $(static_themes | paste -sd' ' -)

  Examples:
    theme static                       # catppuccin-mocha
    theme static catppuccin-mocha
EOF
        ;;
    unsplash) cat <<EOF
theme unsplash [query…]

  Fetch a random high-res (3840px+ preferred) Unsplash photo, save it
  into $WALLPAPER_DIR — named from your query plus the photo's own
  description — then apply it (desktop + pywal + kitty).

  The query needs no quotes. No query = fully random. Needs
  UNSPLASH_ACCESS_KEY or the 'unsplash-access-key' Keychain item
  (see scripts/README.md).

  Examples:
    theme unsplash                     # surprise me
    theme unsplash neon city rain
    theme unsplash mountain lake sunrise --rotate right
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
  --extend centres flat-background art on a matching-color canvas instead.

  Examples:
    theme url https://www.pinterest.com/pin/300685712645323833/
    theme url https://i.pinimg.com/1200x/39/76/d8/3976d….jpg --rotate right
    theme url https://i.pinimg.com/736x/cc/a1/35/cca13….jpg --extend
EOF
        ;;
    list) cat <<EOF
theme list

  List local wallpapers and static kitty themes.

  Example:
    theme list
EOF
        ;;
    status) cat <<EOF
theme status

  Show the current theme: wallpaper path, mode (pywal/static), the color
  scheme as truecolor swatches (like nvim/kitty theme pickers), palette
  source, and the variables the CLI reads (Unsplash key presence — never
  the value — wallpaper dir, pywal cache).

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

  Delete saved wallpapers by name — resolved in $WALLPAPER_DIR like
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
        printf 'theme: unknown command %s — full usage:\n\n' "'$1'" >&2
        usage
        return 1
        ;;
    esac
}

# --- dispatch --------------------------------------------------------------

# --rotate left|right turns the image 90° before it is saved and applied, so a
# portrait Pinterest pin becomes a landscape that fills the desktop. Parsed out
# here (any position) so the subcommands stay flag-free.
ROTATE=""
EXTEND=""
_args=()
_want=""
for _a in "$@"; do
    if [ -n "$_want" ]; then ROTATE="$_a"; _want=""; continue; fi
    case "$_a" in
    --rotate) _want=1 ;;
    --rotate=*) ROTATE="${_a#*=}" ;;
    --extend) EXTEND="000000" ;;
    --extend=*) EXTEND="${_a#*=}"; EXTEND="${EXTEND#\#}" ;;
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
rename) shift; [ -n "${1:-}" ] || die "usage: theme rename <wallpaper> <new name…>"; cmd_rename "$@" ;;
rm) shift; [ -n "${1:-}" ] || die "usage: theme rm <wallpaper…>"; cmd_rm "$@" ;;
help | -h | --help) usage ;;
*) die "unknown command '$1' — run 'theme help' for the list" ;;
esac
