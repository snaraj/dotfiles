# Alias
source $ZDOTDIR/aliases.zsh

# Variables
source $ZDOTDIR/variables.zsh

# Use emacs-style line editing (EDITOR=nvim would otherwise switch zsh into vi mode)
bindkey -e

# History behavior: write each command as it runs, drop duplicates
setopt INC_APPEND_HISTORY HIST_IGNORE_ALL_DUPS

# Completions. kubectl/helm are pre-generated into fpath instead of
# `source <(... completion zsh)`, which spawned two subprocesses on every
# shell start; the cache regenerates itself when a binary is newer than it.
fpath=($ZDOTDIR/completions $fpath)
for _t in kubectl helm; do
    if (( $+commands[$_t] )) && [[ ! -e $ZDOTDIR/completions/_$_t || ${commands[$_t]} -nt $ZDOTDIR/completions/_$_t ]]; then
        mkdir -p $ZDOTDIR/completions
        $_t completion zsh > $ZDOTDIR/completions/_$_t
    fi
done
unset _t
autoload -Uz compinit
# full security scan at most once a day; -C trusts the cached dump otherwise
if [[ -n $ZDOTDIR/.zcompdump(#qN.mh-24) ]]; then
    compinit -C
else
    compinit
    # compinit leaves the dump untouched when it is already valid; refresh the
    # mtime or the 24h fast path above never re-arms and every shell rescans
    touch $ZDOTDIR/.zcompdump
fi
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Auto Suggestions — type to see the inline history suggestion; RIGHT ARROW
# accepts it, UP/DOWN substring-search history for what you typed (below).
source $ZDOTDIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# pipx-installed tools (pywal) and the theme command
export PATH="$HOME/.local/bin:$PATH"

# starship prompt — init script cached (was `eval "$(starship init zsh)"`, a
# subprocess per shell); regenerates when the starship binary updates
if [[ ! -e $ZDOTDIR/.starship-init.zsh || ${commands[starship]} -nt $ZDOTDIR/.starship-init.zsh ]]; then
    starship init zsh --print-full-init > $ZDOTDIR/.starship-init.zsh
fi
source $ZDOTDIR/.starship-init.zsh

# Syntax highlighting — after every other widget-creating plugin except
# history-substring-search, whose README requires loading after THIS.
source $ZDOTDIR/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# History Substring Search — UP/DOWN cycle through history entries containing
# what you typed. Loaded last per its README; duplicates are skipped so a
# history full of repeated `ssh pie5` lines doesn't look like a stuck cycle.
source $ZDOTDIR/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1
# Bind BOTH arrow encodings: CSI (^[[A) and application-mode SS3 (^[OA) —
# a fresh kitty window can use either — plus terminfo when it names another.
bindkey -M emacs '^[[A' history-substring-search-up
bindkey -M emacs '^[[B' history-substring-search-down
bindkey -M emacs '^[OA' history-substring-search-up
bindkey -M emacs '^[OB' history-substring-search-down
zmodload -i zsh/terminfo
[[ -n "${terminfo[kcuu1]-}" ]] && bindkey -M emacs -- "${terminfo[kcuu1]}" history-substring-search-up
[[ -n "${terminfo[kcud1]-}" ]] && bindkey -M emacs -- "${terminfo[kcud1]}" history-substring-search-down

# Keys kitty sends that zsh leaves unbound — without these, Home/End do
# nothing and fn+delete inserts a literal '~' into the line.
bindkey -M emacs '^[[H'    beginning-of-line   # Home
bindkey -M emacs '^[[F'    end-of-line         # End
bindkey -M emacs '^[[3~'   delete-char         # fn+delete (forward delete)
bindkey -M emacs '^[[1;3D' backward-word       # option+left
bindkey -M emacs '^[[1;3C' forward-word        # option+right
bindkey -M emacs '^[[1;5D' backward-word       # ctrl+left
bindkey -M emacs '^[[1;5C' forward-word        # ctrl+right
# Word-jumps stop at path separators instead of leaping whole paths
WORDCHARS=${WORDCHARS//\//}
