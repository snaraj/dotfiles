# Completion cache + the once-a-day compinit security audit.
#
# Two governing rules, both learned the hard way in review:
#   - nothing an attacker can reach may decide whether the audit is skipped, and
#   - nothing an attacker can reach may SUPPLY THE CODE that performs it.
# The dump is not a receipt (compinit writes it after a filtered run too), and
# fpath is not a safe place to park an untrusted directory (fpath is exactly what
# autoload resolves from).
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime

_zc_dir=$ZDOTDIR/completions
_zc_dump=$ZDOTDIR/.zcompdump
_zc_stamp=$ZDOTDIR/.zcompaudit-clean
# Payload written into the stamp, and required when reading it back. Metadata is
# forgeable: a superseded revision of this file wrote generated completions
# straight into $_zc_dir before auditing it, so a writer there could aim that
# redirect at this exact name and get a file owned by us with a plausible mode.
# Only content this file wrote counts. Bump the version to invalidate all stamps.
_zc_token='zcompaudit-clean v1'

# Load the audit machinery from the current, still-trusted fpath BEFORE any
# candidate directory is exposed. zsh resolves an autoload at CALL time, so a
# writable directory on fpath can supply `compinit` itself — or just `compaudit`,
# which the real compinit autoloads from that same fpath before it has audited
# anything. Either is arbitrary shell-startup code execution under exactly the
# capability this file exists to contain. +X forces the definitions to be read
# now; a deferred `autoload` would still resolve later, after the prepend.
autoload -Uz +X compinit compaudit

# Trusted = exists, is NOT a symlink, is owned by us, and is not writable by
# group or other — the same test compaudit applies. zstat -L is an lstat, so a
# planted symlink is judged as the link (and -h rejects it regardless).
# Two zsh traps live in these lines: zstat takes only ONE +element, so a
# `+uid +mode` pair silently fails the whole call; and zsh arithmetic reads `022`
# as DECIMAL 22, so the group/other-write mask must be written 8#22.
_zc_trusted() {
    [[ -e $1 && ! -h $1 ]] || return 1
    local -A st
    zstat -H st -L -- $1 2>/dev/null || return 1
    (( st[uid] == UID && (st[mode] & 8#22) == 0 ))
}

# The stamp is held to a stricter standard than the directory: owner-only (8#77,
# so a 0644 file created by that superseded redirect fails) AND carrying the
# token above. Provenance, not just permissions.
typeset -gA _zc_st
_zc_stamp_ok() {
    [[ -f $_zc_stamp && ! -h $_zc_stamp ]] || return 1
    zstat -H _zc_st -L -- $_zc_stamp 2>/dev/null || return 1
    (( _zc_st[uid] == UID && (_zc_st[mode] & 8#77) == 0 )) || return 1
    [[ "$(<$_zc_stamp)" == $_zc_token ]]
}

[[ -e $_zc_dir ]] || mkdir -p -m 700 $_zc_dir
_zc_dir_ok=0
_zc_trusted $_zc_dir && _zc_dir_ok=1

if (( _zc_dir_ok )); then
    # kubectl/helm are pre-generated into fpath instead of `source <(... completion
    # zsh)`, which spawned two subprocesses on every shell start; the cache
    # regenerates itself when a binary is newer than it. The write goes to a fresh
    # name and is renamed into place: a redirect FOLLOWS a planted symlink and can
    # create its target anywhere, while rename replaces the link itself.
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
    fpath=($_zc_dir $fpath)
else
    # Deliberately NOT added to fpath. Leaving it there so compaudit could report
    # it was the earlier design and it was wrong: it let the untrusted directory
    # supply the auditor. Losing these completions is the correct trade.
    print -u2 "zsh: ignoring ${_zc_dir} — not owned by you, or writable by others. Fix: chmod go-w ${_zc_dir}"
fi

# The fast path needs a valid stamp aged into [0, 24h) AND a completion directory
# that is still trusted RIGHT NOW. The stamp is only a receipt about the past:
# the directory can turn writable afterwards while the cached dump still names
# completions inside it, so re-checking here is what stops a once-clean shell
# from loading attacker files forever. The `>= 0` bound does two jobs and
# dropping it breaks both — it rejects clock-rollback and future timestamps, and
# -1 is the "no usable stamp" sentinel, which would otherwise satisfy `< 86400`.
_zc_age=-1
if (( _zc_dir_ok )) && _zc_stamp_ok; then
    _zc_age=$(( EPOCHSECONDS - _zc_st[mtime] ))
fi

if (( _zc_age >= 0 && _zc_age < 86400 )) && _zc_trusted $_zc_dump; then
    compinit -C -d $_zc_dump
else
    compinit -d $_zc_dump
    _zc_rc=$?
    # compinit returns 0 for a clean audit AND for a filtered one where the user
    # answered "ignore insecure directories and continue": that run drops the bad
    # directory from fpath for the current shell only, sets _comp_secure, and
    # still writes a dump. Arming on exit status alone therefore let the NEXT
    # shell take -C, skip compaudit, and load completions from the
    # attacker-writable directory. Only a clean audit over a trusted directory
    # arms the stamp; anything else removes it, so no dirty state leaves a usable
    # fast path behind.
    if (( _zc_rc == 0 && _zc_dir_ok )) && [[ -z ${_comp_secure-} ]]; then
        rm -f -- $_zc_stamp
        print -r -- $_zc_token >| $_zc_stamp && chmod 600 $_zc_stamp
    else
        rm -f -- $_zc_stamp
    fi
fi

unset _t _zc_dir _zc_dump _zc_stamp _zc_token _zc_f _zc_tmp _zc_age _zc_st _zc_rc _zc_dir_ok
unfunction _zc_trusted _zc_stamp_ok

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
