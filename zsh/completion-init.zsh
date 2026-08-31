# Completion cache + the once-a-day compinit security audit.
#
# The governing rule here: NOTHING an attacker can reach is allowed to decide
# whether the audit gets skipped. The dump does not qualify — compinit writes it
# after a FILTERED run too, and a writable completion directory can cause it to
# be created — so a separate stamp, written only by this file after an audit it
# verified was clean, is what arms the fast path.
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime

_zc_dir=$ZDOTDIR/completions
_zc_dump=$ZDOTDIR/.zcompdump
_zc_stamp=$ZDOTDIR/.zcompaudit-clean

# Trusted = exists, is NOT a symlink, is owned by us, and is not writable by
# group or other — the same ownership/permission test compaudit applies. zstat
# -L is an lstat, so a planted symlink is judged as the link, not its target
# (and the explicit -h test rejects it regardless of the link's own mode bits).
# Two traps live in these three lines: zstat takes only ONE +element, so a
# `+uid +mode` pair silently fails the whole call; and zsh arithmetic reads
# `022` as decimal 22, so the group/other-write mask must be written 8#22.
_zc_trusted() {
    [[ -e $1 && ! -h $1 ]] || return 1
    local -A st
    zstat -H st -L -- $1 2>/dev/null || return 1
    (( st[uid] == UID && (st[mode] & 8#22) == 0 ))
}

# kubectl/helm are pre-generated into fpath instead of `source <(... completion
# zsh)`, which spawned two subprocesses on every shell start; the cache
# regenerates itself when a binary is newer than it.
#
# Generation only ever runs against a directory that already passes the trust
# test. Writing first and auditing later let a world-writable directory capture
# the redirect through a planted symlink: `> $_zc_dir/_kubectl` FOLLOWS a
# dangling link and creates its target anywhere on the filesystem, including
# .zcompdump itself, which then armed the fast path. The write also goes to a
# fresh name and is renamed into place, because rename replaces a symlink
# instead of following it.
[[ -e $_zc_dir ]] || mkdir -p -m 700 $_zc_dir
if _zc_trusted $_zc_dir; then
    for _t in kubectl helm; do
        (( $+commands[$_t] )) || continue
        _zc_f=$_zc_dir/_$_t
        if [[ ! -f $_zc_f || -h $_zc_f ]] || [[ ${commands[$_t]} -nt $_zc_f ]]; then
            _zc_tmp=$_zc_dir/._$_t.$$
            rm -f -- $_zc_tmp
            if $_t completion zsh >| $_zc_tmp 2>/dev/null; then
                mv -f -- $_zc_tmp $_zc_f
            else
                rm -f -- $_zc_tmp
            fi
        fi
    done
fi
# An untrusted directory is still left on fpath so compaudit reports it rather
# than completions silently vanishing; it is simply never written to.
fpath=($_zc_dir $fpath)

autoload -Uz compinit

# The fast path needs a clean-audit stamp that is ours, unwritable by others,
# and aged into [0, 24h). The `>= 0` bound carries two jobs, and dropping it
# breaks both: a clock rollback or a planted future timestamp would otherwise
# read as "fresh" indefinitely, and -1 is also the "no trusted stamp" sentinel
# below, which without the bound would itself satisfy `< 86400`.
_zc_age=-1
if _zc_trusted $_zc_stamp; then
    typeset -A _zc_st
    zstat -H _zc_st -L -- $_zc_stamp 2>/dev/null &&
        _zc_age=$(( EPOCHSECONDS - _zc_st[mtime] ))
fi

if (( _zc_age >= 0 && _zc_age < 86400 )) && _zc_trusted $_zc_dump; then
    compinit -C -d $_zc_dump
else
    compinit -d $_zc_dump
    _zc_rc=$?
    # compinit returns 0 for a clean audit AND for a filtered one where the user
    # answered "ignore insecure directories and continue": that run drops the
    # bad directory from fpath for the current shell only, sets _comp_secure,
    # and still writes a dump. Stamping on exit status alone therefore let the
    # NEXT shell take -C, skip compaudit, and load completions from the
    # attacker-writable directory. compaudit finding nothing is the only thing
    # that arms the stamp; anything else removes it, so a dirty audit cannot
    # leave a usable fast path behind.
    if (( _zc_rc == 0 )) && [[ -z ${_comp_secure-} ]]; then
        rm -f -- $_zc_stamp && : >| $_zc_stamp && chmod 600 $_zc_stamp
    else
        rm -f -- $_zc_stamp
    fi
fi

unset _t _zc_dir _zc_dump _zc_stamp _zc_f _zc_tmp _zc_age _zc_st _zc_rc
unfunction _zc_trusted

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
