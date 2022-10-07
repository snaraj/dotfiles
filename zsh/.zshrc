# Alias
if [ -e $ZDOTDIR/aliases.sh ]; then
    source $ZDOTDIR/aliases.sh
fi

if [ -e $ZDOTDIR/variables.sh ]; then
    source $ZDOTDIR/variables.sh
fi

# Auto Completition
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Aa-z}'

# Syntax Highlighting 
source $ZDOTDIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# History Substring Search
source /opt/homebrew/Cellar/zsh-history-substring-search/1.0.2/share/zsh-history-substring-search/zsh-history-substring-search.zsh

bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

# Auto Suggestions
source $ZDOTDIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# starship init
eval "$(starship init zsh)"
