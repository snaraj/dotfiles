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

# Resolve the audit machinery from an fpath with the cache directory REMOVED,
# rather than assuming it is not there yet. It can already be present three ways:
# zsh/zshenv exports FPATH, so a child shell inherits the prepend; a second
# `source` in the same shell still carries the first source's prepend; and zsh
# returns compinit/compaudit to DEFERRED autoloads when compinit finishes, so a
# later call re-resolves them from fpath. Any of those lets the cache directory
# supply `compinit` itself — or just `compaudit`, which the real compinit
# autoloads from that same fpath before it has audited anything — which is
# arbitrary shell-startup code execution under exactly the capability this file
# exists to contain. +X forces the definitions to be read now; a deferred
# `autoload` would still resolve later.
# Compare fpath entries by FILESYSTEM IDENTITY, not spelling. `${d:A}` makes an
# entry absolute and resolves symlinks, so a trailing slash, a `/.`, a symlinked
# alias or a duplicate all collapse to the same string — a raw `:#$_zc_dir`
# filter let `<cache>/` through and the auditor was pinned from it.
_zc_dir_phys=${_zc_dir:A}
_zc_strip_cache() {
    local -a keep
    local d
    for d in $fpath; do
        [[ ${d:A} == $_zc_dir_phys ]] && continue
        keep+=($d)
    done
    fpath=($keep)
}

# macOS ACLs grant write to another principal while the POSIX mode still reads
# 0600 and zstat still reports us as the owner, and there is no zstat for ACLs.
# This cache has no legitimate use for one, so ANY ACL fails closed — as does an
# unreadable path.
#
# The probe is platform-specific. macOS `ls -lde` prints a numbered ACE line per
# ACL entry; GNU/coreutils `ls` has NO -e option, so running it unconditionally
# failed on the documented Ubuntu install and rejected every clean cache,
# disabling completions entirely. GNU `ls -l` instead appends '+' to the mode
# field. (The '@' macOS shows means extended ATTRIBUTES, not an ACL, which is
# why the marker test cannot be used on darwin.)
#
# The binary is resolved to an absolute path ONCE and invoked through a
# parameter. A bare `ls` would be alias-expanded AT PARSE TIME — zsh/.zshrc
# sources zsh/aliases.zsh first, where `alias ls='eza …'` is defined — so the
# production shell would have probed ACLs with eza, whose output contract is
# nothing like the one this code reads.
_zc_ls=
for _zc_c in /bin/ls /usr/bin/ls; do
    [[ -x $_zc_c ]] && { _zc_ls=$_zc_c; break }
done
unset _zc_c

_zc_no_acl() {
    (( $# )) || return 0
    [[ -n $_zc_ls ]] || return 1
    local out line
    if [[ $OSTYPE == darwin* ]]; then
        out=$($_zc_ls -lde -- "$@" 2>/dev/null) || return 1
        for line in ${(f)out}; do
            [[ ${line//[[:space:]]/} == <->:* ]] && return 1
        done
    else
        out=$($_zc_ls -ld -- "$@" 2>/dev/null) || return 1
        for line in ${(f)out}; do
            [[ ${${(z)line}[1]} == *+ ]] && return 1
        done
    fi
    return 0
}

_zc_pin_auditors() {
    local -a saved
    saved=($fpath)
    _zc_strip_cache
    unfunction compinit compaudit 2>/dev/null
    autoload -Uz +X compinit compaudit
    fpath=($saved)
}

# Canonicalize fpath ONCE, permanently, before anything is resolved from it:
# every occurrence of the cache directory is dropped, whether inherited through
# the exported FPATH or left behind by an earlier source in this shell. Stripping
# only inside _zc_pin_auditors was not enough — it restores the array, so an
# INHERITED occurrence survived, and declining to add another one later did not
# remove it. The directory is re-added exactly once, below, and only after every
# gate has passed. Entries are matched by resolved physical path, so alternate
# spellings of the same directory are removed too.
_zc_strip_cache
_zc_pin_auditors

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

# This cache holds completion functions and nothing else. An entry without the
# leading underscore — notably `compinit` or `compaudit` — is NOT audited by
# compaudit (it only looks at completion names), yet would shadow the audit
# machinery once the directory is on fpath. Its presence disqualifies the
# directory outright, which also covers a world-writable FILE inside an
# otherwise correctly-permissioned directory.
_zc_why=
_zc_dir_clean() {
    local f
    local -a entries
    for f in $_zc_dir/*(N); do
        # the name must be a completion name, AND the file itself must be a
        # regular, non-symlink, owner-controlled, non-group/world-writable file.
        # A correctly-permissioned directory is traversable, so a 0666 _kubectl
        # inside it is still attacker-writable and gets autoloaded on use.
        if [[ ${f:t} != _* ]] || [[ ! -f $f ]] || ! _zc_trusted $f; then
            _zc_why="entry ${f:t} is not a safe completion file (wrong name, not a regular file, or writable by others). Inspect: ${_zc_dir}/${f:t}"
            return 1
        fi
        entries+=($f)
    done
    # one batched ACL check for the directory and everything it holds
    if ! _zc_no_acl $_zc_dir $entries; then
        _zc_why="it (or an entry in it) carries an extended ACL, which can grant write access that the mode bits do not show. Inspect: ls -lde ${_zc_dir} ${_zc_dir}/*"
        return 1
    fi
    return 0
}

[[ -e $_zc_dir ]] || mkdir -p -m 700 $_zc_dir
_zc_dir_ok=0
if ! _zc_trusted $_zc_dir; then
    print -u2 "zsh: ignoring ${_zc_dir} — not owned by you, or writable by others. Fix: chmod go-w ${_zc_dir}"
elif ! _zc_dir_clean; then
    print -u2 "zsh: ignoring ${_zc_dir} — ${_zc_why}"
else
    _zc_dir_ok=1
fi

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
            # explicit mode: under a permissive umask the redirect would
            # otherwise create a world-writable completion, which the gate above
            # would then (correctly) reject on the next startup. No `--` here:
            # BSD/macOS chmod treats it as a filename, and the failure would
            # short-circuit generation entirely.
            if $_t completion zsh >| $_zc_tmp 2>/dev/null && chmod 644 $_zc_tmp; then
                mv -f -- $_zc_tmp $_zc_f
            else
                rm -f -- $_zc_tmp
            fi
        fi
    done
    fpath=($_zc_dir $fpath)
fi
# A rejected directory is deliberately NOT added to fpath. Leaving it there so
# compaudit could report it was the earlier design and it was wrong: fpath is
# what autoload resolves from, so it let the rejected directory supply the
# auditor. Losing these completions is the correct trade.

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

# A dump must be a REGULAR file. The generic node predicate accepts a DIRECTORY
# named .zcompdump, and compinit then moves each generated dump INTO it instead
# of replacing it, while this code happily certified the directory as trusted.
_zc_dump_ok() {
    [[ -f $_zc_dump && ! -h $_zc_dump ]] || return 1
    _zc_trusted $_zc_dump && _zc_no_acl $_zc_dump
}

# Disposal must be PROVEN, not attempted. `compinit -d` SOURCES an existing dump
# whenever its header's file count and zsh version still match, and it does not
# check that file's permissions — so declining the -C fast path while handing
# the same path to the full path still executes attacker code appended below a
# genuine header. And the removal itself can fail: a macOS ACL can grant write
# while DENYING delete, so `rm -f` returns non-zero and the hostile dump
# survives. Ignoring rm's result and passing the path on is the bug this closes.
# Anything still present afterwards — a deny-delete file, or a directory, which
# is never recursively deleted here — is a failed-disposal state: initialise
# with NO dump at all rather than hand compinit something unproven.
_zc_nodump=0
if [[ -e $_zc_dump || -h $_zc_dump ]] && ! _zc_dump_ok; then
    rm -f -- $_zc_dump 2>/dev/null
    rm -f -- $_zc_stamp 2>/dev/null
    _zc_age=-1
    if [[ -e $_zc_dump || -h $_zc_dump ]]; then
        _zc_nodump=1
        print -u2 "zsh: refusing to use ${_zc_dump} — it failed the trust check and could not be removed (a deny-delete ACL, or a directory). Completions start without a cache this session. Inspect: ls -lde ${_zc_dump}"
    fi
fi

if (( _zc_nodump )); then
    # -D: run the full audit but neither read nor write any dump file.
    compinit -D
    rm -f -- $_zc_stamp 2>/dev/null
elif (( _zc_age >= 0 && _zc_age < 86400 )) && _zc_dump_ok &&
     _zc_no_acl $_zc_stamp; then
    compinit -C -d $_zc_dump
else
    # fixed umask: compinit creates the dump, and under a permissive ambient
    # umask it would otherwise write a world-writable one that this same file
    # would then (correctly) unlink on the next startup — after having stamped it.
    _zc_umask=$(umask)
    umask 077
    compinit -d $_zc_dump
    _zc_rc=$?
    umask $_zc_umask
    # compinit returns 0 for a clean audit AND for a filtered one where the user
    # answered "ignore insecure directories and continue": that run drops the bad
    # directory from fpath for the current shell only, sets _comp_secure, and
    # still writes a dump. Arming on exit status alone therefore let the NEXT
    # shell take -C, skip compaudit, and load completions from the
    # attacker-writable directory. Only a clean audit over a trusted directory
    # arms the stamp; anything else removes it, so no dirty state leaves a usable
    # fast path behind.
    # the freshly written dump must itself pass every trust check before it is
    # certified; a clean audit over a dump we cannot vouch for is not a receipt.
    if (( _zc_rc == 0 && _zc_dir_ok )) && [[ -z ${_comp_secure-} ]] &&
       _zc_dump_ok; then
        rm -f -- $_zc_stamp
        print -r -- $_zc_token >| $_zc_stamp && chmod 600 $_zc_stamp
    else
        rm -f -- $_zc_stamp
    fi
fi

# compinit hands compinit/compaudit back to deferred autoloads on its way out,
# so without this a later call in this shell would resolve them from the cache
# directory now sitting on fpath.
_zc_pin_auditors

unset _t _zc_dir _zc_dir_phys _zc_dump _zc_stamp _zc_token _zc_f _zc_tmp _zc_age _zc_st _zc_rc _zc_umask _zc_dir_ok _zc_why _zc_ls _zc_nodump
unfunction _zc_trusted _zc_stamp_ok _zc_dump_ok _zc_dir_clean _zc_pin_auditors _zc_strip_cache _zc_no_acl

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
