alias ..='cd ..'

alias k='kubectl'
alias kgp='kubectl get po'
alias kdp='kubectl describe po'
alias kn='kubectl config set-context --current --namespace'

alias vim='nvim'

# Turn exa off since its currently depracated
alias ls='eza --color=always --icons=always'
alias la='eza -a --color=always --icons=always'
alias ll='eza -l --color=always --icons=always'
alias lt='eza -aT --color=always --icons=always'

# Kitty's SSH wrapper transfers xterm-kitty terminfo and shell integration to
# remote hosts. Use `command ssh` when the stock OpenSSH client is desired.
if [[ -n "${KITTY_WINDOW_ID:-}" ]] && (( $+commands[kitten] )); then
    alias ssh='kitten ssh'
fi
