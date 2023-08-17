# Banner
echo "$(cat $ZDOTDIR/logos/dragon-1.txt)"

# Alias
if [ -e $ZDOTDIR/aliases.zsh ]; then
    source $ZDOTDIR/aliases.zsh
fi

# Variables
if [ -e $ZDOTDIR/variables.zsh ]; then
    source $ZDOTDIR/variables.zsh
fi

#PAC Variables
if [ -e $ZDOTDIR/pac-variables.zsh ]; then
    source $ZDOTDIR/pac-variables.zsh
fi

# Auto Completition
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Aa-z}'
source <(helm completion zsh) 
source <(kubectl completion zsh)

# Syntax Highlighting 
source $ZDOTDIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# History Substring Search
source $ZDOTDIR/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh

bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Auto Suggestions
source $ZDOTDIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# enable GPG Git Sign
export GPG_TTY=$(tty)

# starship init
eval "$(starship init zsh)"
