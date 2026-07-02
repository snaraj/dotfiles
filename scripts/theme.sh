#!/bin/sh
# theme — switch kitty colors between pywal (wallpaper-based) and static themes.
# See scripts/README.md for full usage.

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config}"
KITTY_DIR="$CONFIG_DIR/kitty"
THEMES_DIR="$KITTY_DIR/themes"
CURRENT="$KITTY_DIR/current-theme.conf"
WALLPAPER_DIR="${WALLPAPER_DIR:-$CONFIG_DIR/wallpapers/pc}"

reload_kitty() {
    # kitty re-reads kitty.conf (and its includes) on SIGUSR1
    pkill -USR1 -x kitty 2>/dev/null || true
}

usage() {
    echo "usage: theme wal [image]      wallpaper-based colors via pywal"
    echo "       theme static [name]    fixed theme from $THEMES_DIR"
    echo ""
    echo "available static themes:"
    for f in "$THEMES_DIR"/*.conf; do
        [ -e "$f" ] && echo "  - $(basename "$f" .conf)"
    done
    if [ -f "$CURRENT" ]; then
        echo ""
        echo "current: $(sed -n 's/^include //p' "$CURRENT")"
    fi
}

case "$1" in
wal)
    img="$2"
    if [ -z "$img" ]; then
        img=$(find "$WALLPAPER_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) |
            awk 'BEGIN {srand()} {print rand() "\t" $0}' | sort -n | cut -f2- | head -n 1)
    fi
    if [ -z "$img" ] || [ ! -f "$img" ]; then
        echo "theme: no image found (looked in $WALLPAPER_DIR)" >&2
        exit 1
    fi
    command -v wallpaper >/dev/null && wallpaper set "$img"
    wal -i "$img" --backend colorz || wal -i "$img"
    echo "include $HOME/.cache/wal/colors-kitty.conf" >"$CURRENT"
    reload_kitty
    echo "theme: pywal colors from $(basename "$img")"
    ;;
static)
    name="${2:-catppuccin-mocha}"
    file="$THEMES_DIR/$name.conf"
    if [ ! -f "$file" ]; then
        echo "theme: no such theme '$name' in $THEMES_DIR" >&2
        usage >&2
        exit 1
    fi
    echo "include $file" >"$CURRENT"
    reload_kitty
    echo "theme: static theme '$name'"
    ;;
*)
    usage
    ;;
esac
