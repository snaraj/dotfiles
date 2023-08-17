# CONFIG ROOT DIR LOCATION
export CONFIG_DIR=$HOME/.config

# default text editor
export EDITOR=hx

# change default starship config location
export STARSHIP_CONFIG=$CONFIG_DIR/starship/starship.toml

# default wallpaper location
export WALLPAPER_DIR=$CONFIG_DIR/wallpapers/

# default location for BAT configuration
export BAT_CONFIG_PATH=$CONFIG_DIR/bat/bat.conf

# change nvm default config location
export NVM_DIR="$HOME/.config/nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"

eval "$(/opt/homebrew/bin/brew shellenv)"
