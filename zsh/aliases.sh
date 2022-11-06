# Utility Aliases 

alias ls='exa --color=always --icons --group-directories-first'
alias la='exa -a --color=always --icons --group-directories-first'  # all files and dirs
alias ll='exa -l --color=always --icons --group-directories-first'  # long format
alias lt='exa -aT --color=always --icons --group-directories-first' # tree listing
alias df='duf'
alias cat='bat'
alias du='dust'
alias vim='nvim'

# Nagivation 
alias ..='cd ..'

# Python
alias py='python3'

# Kubernetes
alias k='kubectl'
alias kgp='kubectl get po'
alias kdp='kubectl describe po'
alias kx='f() { [ "$1" ] && kubectl config use-context $1 || kubectl config current-context ; } ; f'
alias kn='f() { [ "$1" ] && kubectl config set-context --current --namespace $1 || kubectl config view --minify | grep namespace | cut -d" " -f6 ; } ; f'

