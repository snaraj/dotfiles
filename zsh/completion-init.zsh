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

# Run the FULL compinit — the one that runs compaudit over fpath — at most once
# a day, and trust the cached dump in between.
#
# The age test reads the mtime through zsh/stat rather than the usual
# `(#qN.mh-24)` glob qualifier. That qualifier form is inert unless EXTENDED_GLOB
# is set, and nothing here sets it: the expression stayed a non-empty literal, so
# the test was ALWAYS true, every shell took `compinit -C`, and `-C` skips
# compaudit outright — the daily scan never ran once. Repairing it by setting
# EXTENDED_GLOB globally would change interactive glob semantics, so the glob
# dependency is removed instead of worked around.
#
# The mtime is refreshed ONLY after a compinit that returned success. compinit
# returns non-zero when compaudit found insecure completion directories and the
# run was aborted; refreshing unconditionally would arm the 24h fast path with a
# dump whose audit was rejected, converting a refusal into a trusted cache.
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime
autoload -Uz compinit
_zcompdump=$ZDOTDIR/.zcompdump
_zcompdump_stat=()
if [[ -f $_zcompdump ]] &&
   zstat -A _zcompdump_stat +mtime -- $_zcompdump 2>/dev/null &&
   (( EPOCHSECONDS - _zcompdump_stat[1] < 86400 )); then
    compinit -C -d $_zcompdump
elif compinit -d $_zcompdump; then
    # compinit leaves an already-valid dump untouched, so the fast path only
    # re-arms with an explicit refresh.
    touch -- $_zcompdump
fi
unset _zcompdump _zcompdump_stat

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
