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

# Alias
alias ls='exa --color=always --icons --group-directories-first'
alias la='exa -a --color=always --icons --group-directories-first'  # all files and dirs
alias ll='exa -l --color=always --icons --group-directories-first'  # long format
alias lt='exa -aT --color=always --icons --group-directories-first' # tree listing

alias df='duf'
alias cat='bat'
alias du='dust'

alias vim='nvim'

alias ..='cd ..'

# starship init
eval "$(starship init zsh)"
