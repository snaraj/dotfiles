# CONFIG ROOT DIR LOCATION
export CONFIG_DIR=$HOME/.config

# change default starship config location
export STARSHIP_CONFIG=$CONFIG_DIR/starship/starship.toml

# wallpaper library for the theme CLI — searched recursively, all subfolders
export THEME_WALLPAPER_DIR=$CONFIG_DIR/wallpapers

# text contrast
export THEME_CONTRAST=7

# Machine-only settings that stay out of this public repository live in
# zsh/local.zsh (gitignored), sourced here when present.
[[ -r $CONFIG_DIR/zsh/local.zsh ]] && source $CONFIG_DIR/zsh/local.zsh

# Firefox CSS config file. The profile directory name is per machine, so it
# comes from FIREFOX_PROFILE=<dir name> in zsh/local.zsh; without it, unset.
if [[ -n ${FIREFOX_PROFILE:-} ]]; then
    export FIREFOX_USER_CHROME="$HOME/Library/Application Support/Firefox/Profiles/$FIREFOX_PROFILE/chrome"
fi

# kitty reads this env var to locate its config directory
export KITTY_CONFIG_DIRECTORY=$CONFIG_DIR/kitty

# zsh history — in the XDG state directory, outside this repository's working
# copy, bumped from the default 500 entries. The file that used to live at
# zsh/.zsh_history moves there once, and only while the new file does not
# exist: never merged, never deleted. If the new place cannot be used, this
# session keeps the old file and says so on stderr.
() {
    local old=$CONFIG_DIR/zsh/.zsh_history
    local dir=${XDG_STATE_HOME:-$HOME/.local/state}/zsh
    local new=$dir/history
    [[ -d $dir ]] || command mkdir -p -m 700 -- $dir 2>/dev/null
    [[ -e $new || ! -e $old ]] || command mv -n -- $old $new 2>/dev/null
    if [[ -d $dir && -w $dir ]] &&
       [[ ( -f $new && -w $new ) || ( ! -e $new && ! -e $old ) ]]; then
        HISTFILE=$new
    else
        HISTFILE=$old
        print -ru2 -- "zsh: cannot use $new; history stays in $old this session"
    fi
}
export HISTFILE
export HISTSIZE=100000
export SAVEHIST=100000
