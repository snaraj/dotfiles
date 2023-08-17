WALLPAPER_DIR=~/.config/wallpapers

wp=$(find $WALLPAPER_DIR -type file | awk 'BEGIN {srand()} {print rand() "\t" $0}' | sort -n | cut -f2- | head -n 1)
wallpaper set $wp
wal -c
wal -i $wp --backend colorz
