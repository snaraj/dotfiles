# Plugins
if [ -e $ZDOTDIR/plugins.zsh ]; then
    source $ZDOTDIR/aliases.zsh
fi

# Alias
if [ -e $ZDOTDIR/aliases.zsh ]; then
    source $ZDOTDIR/aliases.zsh
fi

# starship init
eval "$(starship init zsh)"
