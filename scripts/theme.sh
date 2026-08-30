#!/usr/bin/env bash
# theme — desktop wallpaper + terminal palette CLI (pywal).
# Full documentation: ~/.config/scripts/README.md
# Set THEME_NO_APPLY=1 to exercise every code path without touching the desktop.

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config}"
KITTY_DIR="${KITTY_CONFIG_DIRECTORY:-$CONFIG_DIR/kitty}"
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
    while [ -e "$dest" ]; do
        if [ "$(hash_of "$1")" = "$(hash_of "$dest")" ]; then
            SAVED="$dest"
            [ -n "$SOURCE_URL" ] && ! xattr -p theme.source "$dest" >/dev/null 2>&1 &&
                xattr -w theme.source "$SOURCE_URL" "$dest" 2>/dev/null
            note "already have $(basename "$dest") — reusing it"
            return 0
        fi
        dest="$WALLPAPER_DIR/$base-$n.$ext"
        n=$((n + 1))
    done
    cp "$1" "$dest" || die "cannot write $dest"
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
    dry && { note "[no-apply] would derive a palette from $1"; return 0; }
    command -v wal >/dev/null 2>&1 || die "pywal not installed (pipx install pywal)"
    # colorz refuses near-monochrome art ("not enough colors");
    # modern_colorthief (pipx inject pywal modern_colorthief) handles those.
    wal -i "$1" --backend colorz >/dev/null 2>&1 ||
        wal -i "$1" --backend modern_colorthief >/dev/null 2>&1 ||
        wal -i "$1" >/dev/null 2>&1 ||
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
for field in (
    u.get("raw") or u.get("full", ""), best.get("width", 0), best.get("height", 0),
    name,
    (best.get("links") or {}).get("download_location", ""),
    who):
    sys.stdout.write(str(field) + "\x00")
'

unsplash_key() {
    [ -n "${UNSPLASH_ACCESS_KEY:-}" ] && { printf '%s' "$UNSPLASH_ACCESS_KEY"; return 0; }
    command -v security >/dev/null 2>&1 &&
        security find-generic-password -s unsplash-access-key -w 2>/dev/null
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
    json=$(printf 'header = "Authorization: Client-ID %s"\n' "$key" |
        curl "${curl_args[@]}" "$url") || die "Unsplash request failed (bad key, rate limit, or no network)"
    # Read the six NUL-terminated fields into an array (a tab/newline in the
    # contributor-controlled name or photographer can no longer shift a later
    # field). read -d '' captures each up to its NUL; the final read hits EOF.
    local _f _fields=()
    while IFS= read -r -d '' _f; do _fields+=("$_f"); done < <(printf '%s' "$json" | python3 -c "$UNSPLASH_PY")
    [ "${#_fields[@]}" -ge 6 ] || die "Unsplash returned no usable photo"
    img_url=${_fields[0]}; w=${_fields[1]}; h=${_fields[2]}
    slug=${_fields[3]}; dl=${_fields[4]}; who=${_fields[5]}
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
    [ -n "$dl" ] && printf 'header = "Authorization: Client-ID %s"\n' "$key" |
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
    printf 'header = "Authorization: Client-ID %s"\n' "$key" |
        curl -fsg --max-time 15 -K - -D "$SCRATCH" -o /dev/null \
            "https://api.unsplash.com/photos?page=1&per_page=1" ||
        die "Unsplash request failed (bad key, rate limit exhausted, or no network)"
    limit=$(awk 'tolower($1)=="x-ratelimit-limit:"{sub("\r","",$2); print $2}' "$SCRATCH")
    remaining=$(awk 'tolower($1)=="x-ratelimit-remaining:"{sub("\r","",$2); print $2}' "$SCRATCH")
    scratch_done
    [ -n "$limit" ] || die "Unsplash answered without rate-limit headers"
    printf 'requests left this hour:  %s/%s (resets on the hour)\n' "$remaining" "$limit"
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
    printf 'account:                  application access key (Client-ID) — usage counts\n'
    printf '                          per app; no user is logged in over this key\n'
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
    case "$src" in
    '' | '(null)') printf -- '-' ;;
    *unsplash.com*) printf 'unsplash' ;;
    *pinimg.com* | *pinterest.*) printf 'pinterest' ;;
    *redd.it* | *reddit.com* | *redditmedia.com*) printf 'reddit' ;;
    *) printf '%s' "$src" | sed -E 's#^[a-zA-Z]+://##; s#^www\.##; s#[/:].*##' ;;
    esac
}

# The first 8 palette colors a wallpaper DERIVED when it was last applied,
# read from pywal's own scheme cache (path-mangled filename, any backend) in
# $WAL_CACHE/schemes — already outside the repo, so the render is a small
# JSON read per file, never an image reprocess. hex without '#', one per
# line. A wallpaper never applied has no cached scheme: the caller renders an
# honest dash rather than computing one at list time.
wall_scheme() { # $1 file
    local m s newest=""
    m=$(printf '%s' "$1" | tr '/.' '__')
    # The cached name is <mangled-path>_<light|dark>_<backend>_…json. Matching
    # the mode token too is not decoration: a bare `${m}_*` also matches the
    # cache of ANY wallpaper whose mangled name EXTENDS this one (`sky.jpg`
    # would match `sky_jpg_x.png`'s entry), and a newer neighbour would then
    # render as this row's scheme. Globbing in the shell — not `ls -t | head`
    # — because that pipeline reads a filename it cannot quote and needs a
    # ShellCheck exemption to say so; `-nt` picks the newest (latest backend)
    # with no assumption about the characters in the name at all.
    for s in "$WAL_CACHE/schemes/${m}"_dark_*.json "$WAL_CACHE/schemes/${m}"_light_*.json; do
        [ -f "$s" ] || continue
        if [ -z "$newest" ] || [ "$s" -nt "$newest" ]; then newest="$s"; fi
    done
    [ -n "$newest" ] || return 1
    # Exactly six hex digits, so a truncated or corrupt cache entry is simply
    # not a color here rather than an arithmetic error inside the caller's
    # 16#-conversion. "color1" cannot swallow "color10": the digit is followed
    # by the closing quote.
    tr ',' '\n' <"$newest" |
        sed -n 's/.*"color[0-9]": *"#\([0-9a-fA-F]\{6\}\)".*/\1/p' | head -8
}

# Wallpapers as a table, LATEST ADDED first (APFS birth time): truncated
# title plus a small render of the scheme that wallpaper derives — snappy,
# because the scheme comes from pywal's cache, not the image. Source (an
# xattr/mdls read per file), format, size, and date all live behind -v, so
# the default listing does no per-file metadata work and stays instant.
cmd_list() {
    local cols namew f name src fmt bytes added c r g b n
    cols=${COLUMNS:-$(tput cols 2>/dev/null || printf 100)}
    if [ -n "$VERBOSE" ]; then namew=$((cols - 71)); else namew=$((cols - 32)); fi
    [ "$namew" -gt 44 ] && namew=44
    [ "$namew" -lt 16 ] && namew=16
    printf 'wallpapers (%s), latest first:\n\n' "$WALLPAPER_DIR"
    if [ -n "$VERBOSE" ]; then
        printf '  %-*s  %-24s  %-10s  %-6s  %-7s  %s\n' "$namew" TITLE COLORSCHEME SOURCE FORMAT SIZE ADDED
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
            [ "${#name}" -gt "$namew" ] && name="$(printf '%.*s' $((namew - 1)) "$name")…"
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
                fmt="${f##*.}"
                bytes=$(stat -f %z "$f" 2>/dev/null || printf 0)
                bytes=$(awk -v b="$bytes" 'BEGIN{ if (b >= 1048576) printf "%.1fM", b/1048576; else printf "%.0fK", b/1024 }')
                added=$(stat -f '%SB' -t '%Y-%m-%d' "$f" 2>/dev/null)
                printf '  %-10s  %-6s  %-7s  %s' "$src" "$fmt" "$bytes" "$added"
            fi
            printf '\n'
        done
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
    local inc mode current desk colors
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") mode="unset" ;;
    *colors-kitty.conf) mode="derived from wallpaper" ;;
    *) mode="$(basename "${inc%.conf}")" ;;
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
    printf 'palette image:   %s%s\n' "${current:-<none>}" \
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
    local desk inc label colors term os
    desk=$(command -v wallpaper >/dev/null 2>&1 && wallpaper get 2>/dev/null | sed 's#^//#/#' | sort -u | head -1)
    inc=$(sed -n 's/^include //p' "$CURRENT" 2>/dev/null)
    case "$inc" in
    "") label="" ;;
    *colors-kitty.conf) label="" ;;
    *) label="$(basename "${inc%.conf}")" ;;
    esac
    printf '  current theme:      %s\n' "${desk:-<none>}"
    colors=$(scheme_colors)
    if [ -n "$colors" ]; then
        printf '  colorscheme:        '
        # shellcheck disable=SC2046
        swatch_row $(printf '%s\n' "$colors" | head -8)
        printf '%s\n' "${label:+ $label}"
    else
        printf '  colorscheme:        <none>\n'
    fi
    # In kitty the name is an OSC 8 hyperlink to its website.
    if [ -n "${KITTY_WINDOW_ID:-}" ]; then
        term=$(printf '\033]8;;https://sw.kovidgoyal.net/kitty/\akitty\033]8;;\a')
    else
        term="${TERM_PROGRAM:-$TERM}"
    fi
    printf '  terminal:           %s\n' "$term"
    if [ "$(uname -s)" = Darwin ]; then
        os="macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    else
        os=$(uname -srm)
    fi
    printf '  os:                 %s\n' "$os"
    cat <<EOF

  theme wal [image]      palette + desktop from a local image (random if omitted)
  theme random           random local wallpaper: desktop + palette
  theme set <image>      specific local wallpaper (path, or name under the wallpaper dir)
  theme unsplash [query…] fetch a random high-res Unsplash photo, save it, apply it
                         (multi-word queries work bare: theme unsplash neon city rain;
                          paste an unsplash.com/photos/… link for exactly that photo)
  theme unsplash status  Unsplash API usage: requests left this hour, key, tier
  theme url <link>       direct image URL or Pinterest pin: download, save, apply
                         (pinimg /NNNx/ downscales auto-upgrade to /originals/)
  theme list [-v]        wallpaper table, latest first: title + colorscheme;
                         -v adds source, format, size, date added
  theme status           current theme, color-scheme swatches, variables
  theme rename <w> <n…>  rename a saved wallpaper, keeping the naming format
  theme rm <w…>          delete saved wallpapers by name (no path needed)
  theme help             this text  (theme <command> --help = per-command help)

global flags (any image command):
  --rotate left|right    turn the image 90° before applying
  --extend[=RRGGBB]      centre flat art on a matching canvas (default 000000)
EOF
}

# Per-subcommand help for `theme <cmd> --help`.
usage_cmd() {
    case "$1" in
    wal) cat <<EOF
theme wal [image] [--rotate left|right] [--extend[=RRGGBB]]

  Derive a color palette from a local image and apply it everywhere:
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

  Apply a specific local wallpaper: desktop + palette + kitty.
  <image> is a path or a name under $WALLPAPER_DIR (extension optional).

  Examples:
    theme set spain-city-mountains
    theme set nebulosa-red.png --extend
EOF
        ;;
    unsplash) cat <<EOF
theme unsplash [query… | photo-url] [--rotate left|right] [--extend[=RRGGBB]]

  Fetch an Unsplash photo, save it into $WALLPAPER_DIR — named from your
  query plus the photo's own description — then apply it (desktop +
  palette + kitty). Always downloads the RAW original rendition (the
  highest quality Unsplash serves), preferring 3840px+ photos on search.

  A query needs no quotes; no query = fully random. Pasting a photo page
  link (unsplash.com/photos/…) fetches exactly that photo instead of
  searching. Needs UNSPLASH_ACCESS_KEY or the 'unsplash-access-key'
  Keychain item (see scripts/README.md).

  theme unsplash status shows the API window for your key — requests
  left this hour, tier, key source. The check itself costs 1 request.

  Examples:
    theme unsplash                     # surprise me
    theme unsplash neon city rain
    theme unsplash mountain lake sunrise --rotate right
    theme unsplash https://unsplash.com/photos/winged-person-with-halo-in-sky-coy_MhYMLHs
    theme unsplash status              # 39/50 requests remaining this hour
EOF
        ;;
    url) cat <<EOF
theme url <link> [--rotate left|right]

  Download an image from a direct URL or a Pinterest pin page, save it
  into $WALLPAPER_DIR, then apply it (desktop + palette + kitty).

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
  that wallpaper derived when it was last applied (from the palette
  cache — a wallpaper never applied shows "-", nothing is computed at
  list time, so the listing stays instant). -v adds source — the site
  it came from (unsplash, pinterest, reddit, …), recorded at download
  time or read from macOS download metadata, "-" when unknown —
  plus format, size, and date added.

  Examples:
    theme list
    theme list -v
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
wal) cmd_local "${2:-}" ;;
random) cmd_local "" ;;
set) [ -n "${2:-}" ] || die "usage: theme set <image>"; cmd_local "$2" ;;
unsplash)
    shift
    if [ "${1:-}" = status ] && [ $# -eq 1 ]; then cmd_unsplash_status; else cmd_unsplash "$*"; fi
    ;;
url) cmd_url "${2:-}" ;;
list) cmd_list ;;
status) cmd_status ;;
rename) shift; [ -n "${1:-}" ] || die "usage: theme rename <wallpaper> <new name…>"; cmd_rename "$@" ;;
rm) shift; [ -n "${1:-}" ] || die "usage: theme rm <wallpaper…>"; cmd_rm "$@" ;;
help | -h | --help) usage ;;
*) die "unknown command '$1' — run 'theme help' for the list" ;;
esac
