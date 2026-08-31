# CONFIG ROOT DIR LOCATION
export CONFIG_DIR=$HOME/.config

# change default starship config location
export STARSHIP_CONFIG=$CONFIG_DIR/starship/starship.toml

# wallpaper library for the theme CLI — searched recursively, all subfolders
export THEME_WALLPAPER_DIR=$CONFIG_DIR/wallpapers

# text contrast
export THEME_CONTRAST=4.5

# Firefox CSS config file
export FIREFOX_USER_CHROME="/Users/samuel/Library/Application Support/Firefox/Profiles/wldjcvt7.default-release-1/chrome"

# kitty reads this env var to locate its config directory
export KITTY_CONFIG_DIRECTORY=$CONFIG_DIR/kitty

# pywal output cache (used by theme.sh for colors-kitty.conf)
export WAL_CACHE=$HOME/.cache/wal

# zsh history — keep alongside other zsh files, bump size from default 500
export HISTFILE=$CONFIG_DIR/zsh/.zsh_history
export HISTSIZE=100000
export SAVEHIST=100000
