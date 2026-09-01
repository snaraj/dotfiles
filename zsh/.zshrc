# Alias
source $ZDOTDIR/aliases.zsh

# Variables
source $ZDOTDIR/variables.zsh

# Use emacs-style line editing (EDITOR=nvim would otherwise switch zsh into vi mode)
bindkey -e

# History behavior: write each command as it runs, drop duplicates
setopt INC_APPEND_HISTORY HIST_IGNORE_ALL_DUPS

# Completion cache + the once-a-day compinit security audit. Its own file so
# zsh/completion-security-tests.zsh can exercise the shipped code directly.
source $ZDOTDIR/completion-init.zsh

# Auto Suggestions — type to see the inline history suggestion; RIGHT ARROW
# accepts it, UP/DOWN substring-search history for what you typed (below).
# Accepting is DELIBERATE and single-keyed: plain right arrow only. The
# plugin's defaults also let End swallow the whole suggestion and let
# option/ctrl+right (forward-word) pull it in word by word — navigation
# keys silently becoming input, which surfaced as truncated garbage
# commands. Set-before-source wins over the plugin's defaults.
ZSH_AUTOSUGGEST_ACCEPT_WIDGETS=(forward-char vi-forward-char)
ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS=()
source $ZDOTDIR/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# local binaries (the theme CLI installs here)
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
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
