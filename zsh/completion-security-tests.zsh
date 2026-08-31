#!/usr/bin/env zsh
# Regressions for the compinit security audit in zsh/completion-init.zsh.
#
# Bugs pinned here, all of which shipped at some point in this PR:
#   1. `(#qN.mh-24)` is inert without EXTENDED_GLOB, so the age test was always
#      true and `compinit -C` (which skips compaudit) always ran;
#   2. an unconditional refresh armed the fast path even when compinit ABORTED;
#   3. a filtered audit ("ignore insecure directories" -> y) returns 0 and
#      writes a dump, so arming on exit status alone let the NEXT shell skip
#      compaudit and load completions from the attacker-writable directory;
#   4. generated completions were written into the directory BEFORE it was
#      audited, so a planted dangling symlink captured the redirect and created
#      files outside the directory — including .zcompdump itself;
#   5. a future-dated timestamp read as "fresh" until the wall clock caught up.
#
# Run: zsh zsh/completion-security-tests.zsh
set -u
emulate -L zsh
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime

SRC=${0:A:h}/completion-init.zsh
[[ -r $SRC ]] || { print -u2 "cannot read $SRC"; exit 2 }

typeset -g FAILED=0
pass() { print "PASS  $1" }
fail() { print "FAIL  $1"; FAILED=1 }
check() { [[ $2 == $3 ]] && pass "$1" || { fail "$1"; print "        expected: $3"; print "        actual:   $2" } }

STAMP=.zcompaudit-clean
TOKEN='zcompaudit-clean v1'
# Arm a stamp the way the shipped file does: exact token payload, owner-only.
arm_stamp() { print -r -- $TOKEN >| $1/$STAMP; chmod 600 $1/$STAMP }

# Sandbox with a recording `compinit` stub earlier in fpath than the real one,
# so the BRANCH the shipped code selects is observable. STUB_RC fakes the return
# status; STUB_SECURE fakes the "insecure directories were filtered" marker.
new_sandbox() {
    local d=$(mktemp -d)
    mkdir -p $d/zd/completions $d/stub
    cat > $d/stub/compinit <<'STUB'
print -r -- "$*" >> $STUB_RECORD
[[ -n ${STUB_SECURE:-} ]] && typeset -g _comp_secure=yes
# a full run writes a dump, like the real one (STUB_NODUMP isolates the
# generation step in tests that assert the dump was never created)
[[ $* == *-C* || -n ${STUB_NODUMP:-} ]] || : >| ${${(z)*}[-1]}
return ${STUB_RC:-0}
STUB
    print -r -- $d
}

run_shipped() {  # $1 sandbox, $2 rc, $3 secure-marker
    local sandbox=$1
    (
        export ZDOTDIR=$sandbox/zd STUB_RECORD=$sandbox/record
        export STUB_RC=${2:-0} STUB_SECURE=${3:-} STUB_NODUMP=${4:-}
        fpath=($sandbox/stub)
        source $SRC >/dev/null 2>&1
    )
}

branch_of() {
    local rec=$1
    [[ ! -s $rec ]] && { print "none"; return }
    [[ "$(<$rec)" == *-C* ]] && print "fast" || print "full"
}

# --- 1. ABSENT: nothing stamped yet must run the FULL audit -------------------
s=$(new_sandbox)
run_shipped $s
check "absent stamp runs the full compaudit, not the -C fast path" \
      "$(branch_of $s/record)" "full"
check "a clean audit arms the stamp" \
      "$([[ -f $s/zd/$STAMP ]] && print yes || print no)" "yes"
rm -rf $s

# --- 2. FRESH: a fresh stamp + trusted dump takes the fast path ---------------
s=$(new_sandbox); arm_stamp $s/zd; : >| $s/zd/.zcompdump
run_shipped $s
check "a fresh clean-audit stamp takes the -C fast path" "$(branch_of $s/record)" "fast"
rm -rf $s

# --- 3. STALE: a stamp over 24h old re-runs the full audit --------------------
s=$(new_sandbox); arm_stamp $s/zd
touch -t 202501010000 $s/zd/$STAMP
run_shipped $s
check "a stale stamp re-runs the full compaudit" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 4. ABORTED audit must not leave a usable fast path ----------------------
s=$(new_sandbox); arm_stamp $s/zd
touch -t 202501010000 $s/zd/$STAMP
run_shipped $s 1
check "an ABORTED audit removes the stamp" \
      "$([[ -e $s/zd/$STAMP ]] && print present || print removed)" "removed"
rm -f $s/record; run_shipped $s 1
check "the shell after an aborted audit still runs the full audit" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 5. FILTERED audit ("ignore insecure dirs" -> y) must not arm anything ----
# compinit returns 0 here and writes a dump, which is exactly what made arming
# on exit status alone unsafe.
s=$(new_sandbox); arm_stamp $s/zd
touch -t 202501010000 $s/zd/$STAMP
run_shipped $s 0 yes
check "a FILTERED audit (rc=0 + _comp_secure) does not arm the stamp" \
      "$([[ -e $s/zd/$STAMP ]] && print present || print removed)" "removed"
check "a filtered audit still wrote a dump (why the dump is not the receipt)" \
      "$([[ -f $s/zd/.zcompdump ]] && print yes || print no)" "yes"
rm -f $s/record; run_shipped $s 0 yes
check "the shell after a filtered audit still runs the full audit" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 6. FUTURE-DATED stamp must fail closed ----------------------------------
s=$(new_sandbox); arm_stamp $s/zd
touch -t 203501010000 $s/zd/$STAMP; : >| $s/zd/.zcompdump
run_shipped $s
check "a FUTURE-dated stamp is not accepted as fresh" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 7. A stamp that is not ours/not a regular file is not trusted -----------
s=$(new_sandbox); print -r -- $TOKEN >| $s/zd/real-stamp; chmod 600 $s/zd/real-stamp
ln -s $s/zd/real-stamp $s/zd/$STAMP
: >| $s/zd/.zcompdump
run_shipped $s
check "a SYMLINKED stamp is not trusted" "$(branch_of $s/record)" "full"
rm -rf $s

s=$(new_sandbox); arm_stamp $s/zd; chmod 666 $s/zd/$STAMP; : >| $s/zd/.zcompdump
run_shipped $s
check "a world-writable stamp is not trusted" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 8. Never write generated completions through a planted symlink ----------
s=$(new_sandbox); mkdir -p $s/victim
chmod 0777 $s/zd/completions
ln -s $s/victim/OUTSIDE $s/zd/completions/_kubectl
run_shipped $s
check "a dangling _kubectl symlink does NOT get a file created outside the dir" \
      "$([[ -e $s/victim/OUTSIDE ]] && print CREATED || print absent)" "absent"
rm -rf $s

# --- 9. ...including a symlink aimed at the dump itself ----------------------
s=$(new_sandbox)
chmod 0777 $s/zd/completions
rm -f $s/zd/.zcompdump
ln -s $s/zd/.zcompdump $s/zd/completions/_kubectl
run_shipped $s 0 "" nodump
check "a _kubectl symlink aimed at .zcompdump does not create the dump" \
      "$([[ -e $s/zd/.zcompdump ]] && print CREATED || print absent)" "absent"
check "and that startup still runs the full audit" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 10. An untrusted completion directory is never written to ---------------
s=$(new_sandbox)
chmod 0777 $s/zd/completions
run_shipped $s
check "no completion file is generated into a world-writable directory" \
      "$(print -r -- $s/zd/completions/_*(N) | wc -w | tr -d ' ')" "0"
rm -rf $s

# --- 11. REAL compinit: answering "y" must not arm the next shell ------------
# The genuine two-start transition from the verdict, driven over a pty.
if (( $+commands[python3] )); then
    s=$(mktemp -d); mkdir -p $s/zd/completions $s/evil
    chmod 0777 $s/evil; : >| $s/evil/_complete; chmod 0777 $s/evil/_complete
    cat > $s/start.zsh <<EOF
ZDOTDIR=$s/zd
fpath=($s/evil \$fpath)
source $SRC
print "AUDIT_PROMPTED=\${_comp_secure:-no}"
print "EVIL_ON_FPATH=\${\${fpath[(r)$s/evil]}:+YES}"
print "STAMP=\$([[ -f $s/zd/$STAMP ]] && print armed || print absent)"
EOF
    cat > $s/ptydrive.py <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("zsh", ["zsh", "-f", sys.argv[1]]); os._exit(1)
out=b""; sent=False; t0=time.time()
while time.time()-t0 < 25:
    r,_,_ = select.select([fd], [], [], 0.4)
    if r:
        try: c = os.read(fd, 4096)
        except OSError: break
        if not c: break
        out += c
        if not sent and b"Ignore insecure" in out:
            time.sleep(0.2); os.write(fd, b"y"); sent=True
    else:
        try:
            p,_ = os.waitpid(pid, os.WNOHANG)
            if p: break
        except ChildProcessError: break
try: os.waitpid(pid,0)
except Exception: pass
sys.stdout.write(out.decode(errors="replace"))
PY
    first=$(python3 $s/ptydrive.py $s/start.zsh 2>/dev/null)
    check "real compinit: answering y reports a filtered audit" \
          "$([[ $first == *"AUDIT_PROMPTED=yes"* ]] && print yes || print no)" "yes"
    check "real compinit: a filtered audit leaves NO stamp" \
          "$([[ $first == *"STAMP=absent"* ]] && print absent || print armed)" "absent"
    second=$(python3 $s/ptydrive.py $s/start.zsh 2>/dev/null)
    check "real compinit: the SECOND shell audits again instead of taking -C" \
          "$([[ $second == *"Ignore insecure"* ]] && print re-audited || print skipped)" "re-audited"
    rm -rf $s
else
    print "SKIP  real-compinit pty regression (python3 unavailable)"
fi


# --- 12. The audit machinery must never resolve out of the candidate directory
# A writable completion dir on fpath can supply `compinit` itself, or just
# `compaudit`, which the real compinit autoloads before it has audited anything.
for _victimfn in compinit compaudit; do
    s=$(mktemp -d); mkdir -p $s/zd/completions
    chmod 0777 $s/zd/completions
    print -r -- "print ATTACKER-$_victimfn-RAN" > $s/zd/completions/$_victimfn
    [[ $_victimfn == compaudit ]] && print -r -- "return 0" >> $s/zd/completions/$_victimfn
    out=$( ZDOTDIR=$s/zd zsh -f -c "ZDOTDIR=$s/zd; source $SRC" </dev/null 2>&1 )
    check "an attacker-supplied $_victimfn in the completion dir is never executed" \
          "$([[ $out == *ATTACKER-$_victimfn-RAN* ]] && print RAN || print blocked)" "blocked"
    check "and that startup arms no stamp (attacker $_victimfn)" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "absent"
    rm -rf $s
done
unset _victimfn

# --- 12b. Even a TRUSTED completion dir must not supply the audit machinery ---
# The dir is on fpath by design, so without the +X force-load an ordinary file
# named compinit/compaudit there would be autoloaded in place of the real one.
for _victimfn in compinit compaudit; do
    s=$(mktemp -d); mkdir -p $s/zd/completions      # left at safe 0700/0755
    print -r -- "print ATTACKER-$_victimfn-RAN" > $s/zd/completions/$_victimfn
    [[ $_victimfn == compaudit ]] && print -r -- "return 0" >> $s/zd/completions/$_victimfn
    out=$( ZDOTDIR=$s/zd zsh -f -c "ZDOTDIR=$s/zd; source $SRC" </dev/null 2>&1 )
    check "a $_victimfn file in a TRUSTED completion dir is still never executed" \
          "$([[ $out == *ATTACKER-$_victimfn-RAN* ]] && print RAN || print blocked)" "blocked"
    rm -rf $s
done
unset _victimfn

# --- 13. An untrusted completion directory is kept OFF fpath entirely ---------
s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 0777 $s/zd/completions
out=$( ZDOTDIR=$s/zd zsh -f -c "ZDOTDIR=$s/zd; source $SRC; print FPATH0=\$fpath[1]" </dev/null 2>/dev/null )
check "a world-writable completion dir is not placed on fpath" \
      "$([[ $out == *"FPATH0=$s/zd/completions"* ]] && print ON-FPATH || print excluded)" "excluded"
rm -rf $s

# --- 14. A fresh stamp must not survive the directory turning writable --------
s=$(new_sandbox); arm_stamp $s/zd; : >| $s/zd/.zcompdump
chmod 0777 $s/zd/completions
run_shipped $s
check "a fresh stamp does NOT arm the fast path once the dir is world-writable" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 15. A stamp this file did not write is rejected (upgrade provenance) -----
# The superseded pre-audit redirect could aim at the stamp NAME and create it
# owned by us with mode 0644 — correct metadata, wrong provenance.
s=$(new_sandbox); print -r -- "#compdef kubectl" >| $s/zd/$STAMP; chmod 644 $s/zd/$STAMP
: >| $s/zd/.zcompdump
run_shipped $s
check "a stamp forged by the old pre-audit redirect is rejected" \
      "$(branch_of $s/record)" "full"
rm -rf $s

s=$(new_sandbox); arm_stamp $s/zd; chmod 644 $s/zd/$STAMP; : >| $s/zd/.zcompdump
run_shipped $s
check "a correct-token stamp that is not owner-only is rejected" \
      "$(branch_of $s/record)" "full"
rm -rf $s

s=$(new_sandbox); print -r -- "zcompaudit-clean v0" >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP
: >| $s/zd/.zcompdump
run_shipped $s
check "a stamp carrying a different token version is rejected" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 16. The exact superseded-revision -> current upgrade transition ---------
# The superseded revision wrote generated completions into the directory BEFORE
# auditing it, with a plain redirect. Reproduced faithfully here: a writer in a
# world-writable completion dir aims that redirect at the stamp NAME, so the
# stamp is created by the *previous* shell, as the real user, with a normal
# mode. The current file must not treat that as its own clean-audit receipt.
s=$(new_sandbox); chmod 0777 $s/zd/completions
ln -s $s/zd/$STAMP $s/zd/completions/_kubectl
print -r -- "#compdef kubectl" > $s/zd/completions/_kubectl   # the superseded pre-audit redirect
check "the superseded pre-audit redirect does create the stamp name" \
      "$([[ -e $s/zd/$STAMP && ! -h $s/zd/$STAMP ]] && print created || print absent)" "created"
check "and it is owned by us with ordinary metadata (so metadata alone is not proof)" \
      "$(zsh -fc "zmodload -F zsh/stat b:zstat; typeset -A st; zstat -H st -L -- $s/zd/$STAMP; print \$(( st[uid] == UID ))")" "1"
rm -f $s/zd/completions/_kubectl $s/record
run_shipped $s
check "the current file does NOT honour that inherited stamp" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 16b. The auditor boundary must hold across source/child lifecycles -------
# fpath can already carry the cache dir when this file is reached: zshenv exports
# FPATH (child shells inherit it) and a second `source` still has the first
# prepend. compinit also re-defers compinit/compaudit on the way out.

# (i) sourced TWICE in the same shell
s=$(mktemp -d); mkdir -p $s/zd/completions
print -r -- "print ATTACKER-RAN" > $s/zd/completions/compinit; chmod 0666 $s/zd/completions/compinit
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC; source $SRC" </dev/null 2>&1 )
check "an attacker compinit never runs when the file is sourced twice" \
      "$([[ $out == *ATTACKER-RAN* ]] && print RAN || print blocked)" "blocked"
rm -rf $s

# (ii) a CHILD zsh inheriting the exported FPATH
s=$(mktemp -d); mkdir -p $s/zd/completions
print -r -- "print ATTACKER-RAN" > $s/zd/completions/compinit; chmod 0666 $s/zd/completions/compinit
print -r -- "ZDOTDIR=$s/zd
fpath=(\${(s.:.)FPATH})
source $SRC" > $s/child.zsh
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC; export FPATH=\"\${(j.:.)fpath}\"; zsh -f $s/child.zsh" </dev/null 2>&1 )
check "an attacker compinit never runs in a child shell inheriting FPATH" \
      "$([[ $out == *ATTACKER-RAN* ]] && print RAN || print blocked)" "blocked"
rm -rf $s

# (iii) present BEFORE the source, then the auditor is called AFTER it.
# compinit hands both names back to deferred autoloads on its way out, so
# without the re-pin the later call resolves them from the cache directory.
# Two layered controls cover this: the cleanliness gate keeps such a directory
# off fpath at all, and the re-pin keeps the auditors resolved even if it were
# on. (Mutation shows the re-pin still blocks when the gate is bypassed.)
for _victimfn in compinit compaudit; do
    s=$(mktemp -d); mkdir -p $s/zd/completions
    print -r -- "print ATTACKER-RAN" > $s/zd/completions/$_victimfn
    [[ $_victimfn == compaudit ]] && print -r -- "return 0" >> $s/zd/completions/$_victimfn
    out=$( zsh -f -c "
ZDOTDIR=$s/zd
source $SRC >/dev/null 2>&1
$_victimfn -d $s/zd/.zcompdump 2>&1" </dev/null 2>&1 )
    check "$_victimfn is not resolved from the cache when called after startup" \
          "$([[ $out == *ATTACKER-RAN* ]] && print RAN || print blocked)" "blocked"
    rm -rf $s
done
unset _victimfn

# (iv) a directory holding a non-completion entry is rejected and kept off fpath
s=$(mktemp -d); mkdir -p $s/zd/completions
print -r -- "print hi" > $s/zd/completions/notacompletion
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC; print FPATH0=\$fpath[1]" </dev/null 2>&1 )
check "a cache dir holding a non-completion entry is kept off fpath" \
      "$([[ $out == *"FPATH0=$s/zd/completions"* ]] && print ON-FPATH || print excluded)" "excluded"
rm -rf $s

# --- 16c. Entry-level validation and inherited-cache purging -----------------

# (i) an existing 0666 _kubectl inside an otherwise accepted 0755 directory.
# The directory is traversable, so the file is attacker-writable through it.
s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 755 $s/zd/completions
print -r -- '#compdef kubectl' > $s/zd/completions/_kubectl
print -r -- 'print ATTACKER-COMPLETION-RAN' >> $s/zd/completions/_kubectl
chmod 0666 $s/zd/completions/_kubectl
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1; autoload -Uz _kubectl 2>/dev/null; _kubectl 2>/dev/null" </dev/null 2>&1 )
check "a world-writable _kubectl is neither accepted nor loadable" \
      "$([[ $out == *ATTACKER-COMPLETION-RAN* ]] && print RAN || print blocked)" "blocked"
check "and a world-writable completion arms no stamp" \
      "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "absent"
rm -rf $s

# (ii) generation under a permissive umask must still land a safe mode
if (( $+commands[kubectl] || $+commands[helm] )); then
    s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 755 $s/zd/completions
    zsh -f -c "umask 000; ZDOTDIR=$s/zd; source $SRC" </dev/null >/dev/null 2>&1
    typeset -i _bad=0 _seen=0
    for _f in $s/zd/completions/_*(N); do
        typeset -A _m; zstat -H _m -L -- $_f 2>/dev/null || continue
        (( _seen++ )); (( (_m[mode] & 8#22) == 0 )) || _bad=1
    done
    check "generation under umask 000 produced at least one completion" \
          "$(( _seen > 0 ))" "1"
    check "generated completions are never group/world-writable" "$_bad" "0"
    unset _f _m _bad _seen
    rm -rf $s
else
    print "SKIP  umask generation case (neither kubectl nor helm installed)"
fi

# (iii) the cache is ALREADY on fpath (as an exported FPATH delivers it) and the
# gate then rejects it: the inherited occurrence must be purged, not merely
# "not re-added", and nothing from it may be registered or loadable.
s=$(mktemp -d); mkdir -p $s/zd/completions
print -r -- '#compdef kubectl' > $s/zd/completions/_kubectl
print -r -- 'print ATTACKER-COMPLETION-RAN' >> $s/zd/completions/_kubectl
chmod 0666 $s/zd/completions/_kubectl
# fpath is pinned to the cache plus zsh's own function dir only, so an
# ambient/system _kubectl cannot mask what is being measured here.
_sysfns=(${(M)fpath:#*/zsh/*/functions})
out=$( zsh -f -c "
ZDOTDIR=$s/zd
fpath=($s/zd/completions ${_sysfns[1]:-/usr/share/zsh/5.9/functions})
source $SRC 2>&1
n=0; for d in \$fpath; do [[ \$d == $s/zd/completions ]] && (( n++ )); done
print CACHE_COUNT=\$n
print COMPS=\${+_comps[kubectl]}
print RESOLVED=\${\${:-\$(for d in \$fpath; do [[ -e \$d/_kubectl ]] && print \$d; done)}:-none}
autoload -Uz _kubectl 2>/dev/null; _kubectl 2>/dev/null" </dev/null 2>&1 )
check "an inherited cache occurrence is purged from fpath when the gate rejects it" \
      "$([[ $out == *CACHE_COUNT=0* ]] && print 0 || print nonzero)" "0"
check "no completion from a rejected inherited cache is registered" \
      "$([[ $out == *COMPS=0* ]] && print unregistered || print registered)" "unregistered"
check "and _kubectl resolves from nowhere once the cache is purged" \
      "$([[ $out == *RESOLVED=none* ]] && print none || print "$out[(ws:RESOLVED=:)2]")" "none"
check "no completion from a rejected inherited cache is loadable" \
      "$([[ $out == *ATTACKER-COMPLETION-RAN* ]] && print RAN || print blocked)" "blocked"
rm -rf $s

# --- 16d. macOS ACL grants, and fpath aliases by physical identity -----------

# (i) an ACL-writable completion whose POSIX mode still reads 0600.
# `chmod +a` is macOS-only, so the ACL cases skip elsewhere.
if [[ $OSTYPE == darwin* ]]; then
    s=$(mktemp -d); mkdir -p $s/zd/completions
    print -r -- '#compdef kubectl' > $s/zd/completions/_kubectl
    print -r -- 'print ACL-COMPLETION-RAN' >> $s/zd/completions/_kubectl
    chmod 600 $s/zd/completions/_kubectl
    chmod +a 'everyone allow write' $s/zd/completions/_kubectl 2>/dev/null
    out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1; autoload -Uz _kubectl 2>/dev/null; _kubectl 2>/dev/null" </dev/null 2>&1 )
    check "an ACL-writable completion (mode still 0600) is not loadable" \
          "$([[ $out == *ACL-COMPLETION-RAN* ]] && print RAN || print blocked)" "blocked"
    check "and an ACL-writable completion arms no stamp" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "absent"
    rm -rf $s

    # (ii) an ACL-writable .zcompdump reached from a genuinely fresh stamp.
    # The payload is APPENDED so the real header survives: compinit sources an
    # existing dump only while its header's file count and zsh version match, so
    # overwriting the dump destroys the very condition the attack needs and the
    # test would pass for the wrong reason.
    s=$(mktemp -d); mkdir -p $s/zd/completions
    zsh -f -c "ZDOTDIR=$s/zd; source $SRC" </dev/null >/dev/null 2>&1
    check "the clean start armed a real stamp (precondition for the dump cases)" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "armed"
    check "and wrote a dump with a real header" \
          "$(( $(wc -l < $s/zd/.zcompdump) > 10 ))" "1"
    print -r -- '' >> $s/zd/.zcompdump
    print -r -- 'print ACL-DUMP-RAN' >> $s/zd/.zcompdump
    chmod 600 $s/zd/.zcompdump
    chmod +a 'everyone allow write' $s/zd/.zcompdump 2>/dev/null
    out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1" </dev/null 2>&1 )
    check "an ACL-writable dump with a VALID header is never executed" \
          "$([[ $out == *ACL-DUMP-RAN* ]] && print RAN || print blocked)" "blocked"
    rm -rf $s
else
    print "SKIP  macOS ACL cases (not darwin)"
fi

# (ii-b) a mode-writable dump with a valid header, on the FULL compinit path.
# Failing the -C trust check is not enough: compinit -d sources the same file.
s=$(mktemp -d); mkdir -p $s/zd/completions
zsh -f -c "ZDOTDIR=$s/zd; source $SRC" </dev/null >/dev/null 2>&1
print -r -- '' >> $s/zd/.zcompdump
print -r -- 'print MODE-DUMP-RAN' >> $s/zd/.zcompdump
chmod 0666 $s/zd/.zcompdump
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1" </dev/null 2>&1 )
check "a 0666 dump with a VALID header is never executed" \
      "$([[ $out == *MODE-DUMP-RAN* ]] && print RAN || print blocked)" "blocked"
check "an untrusted dump is unlinked and regenerated safely" \
      "$(zsh -fc "zmodload -F zsh/stat b:zstat; typeset -A st; zstat -H st -L -- $s/zd/.zcompdump 2>/dev/null && print \$(( (st[mode] & 8#22) == 0 )) || print missing")" "1"
rm -rf $s

# (ii-c) the dump this code creates under a permissive umask must be safe.
# Previously it wrote a world-writable dump and then stamped it as clean.
s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 755 $s/zd/completions
zsh -f -c "umask 000; ZDOTDIR=$s/zd; source $SRC" </dev/null >/dev/null 2>&1
check "a dump created under umask 000 is not group/world-writable" \
      "$(zsh -fc "zmodload -F zsh/stat b:zstat; typeset -A st; zstat -H st -L -- $s/zd/.zcompdump 2>/dev/null && print \$(( (st[mode] & 8#22) == 0 )) || print missing")" "1"
check "and that startup still armed the stamp" \
      "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "armed"
rm -rf $s

# (ii-d) the ACL probe must be platform-correct. GNU/coreutils ls has no -e, so
# an unconditional `ls -lde` fails there and rejects every clean cache, killing
# completions on the documented Ubuntu install. Simulated with a GNU-like ls.
s=$(mktemp -d); mkdir -p $s/zd/completions $s/bin
print -r -- '#!/bin/sh' > $s/bin/ls
print -r -- 'for a in "$@"; do case "$a" in -*e*) echo "ls: invalid option -- e" >&2; exit 2;; esac; done' >> $s/bin/ls
print -r -- 'exec /bin/ls "$@"' >> $s/bin/ls
chmod +x $s/bin/ls
out=$( zsh -f -c "OSTYPE=linux-gnu; PATH=$s/bin:\$PATH; ZDOTDIR=$s/zd; source $SRC 2>&1" </dev/null 2>&1 )
check "a clean cache is NOT rejected on a GNU-ls platform (no -e option)" \
      "$([[ $out == *ignoring* ]] && print rejected || print accepted)" "accepted"
check "and the fast path still arms there" \
      "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "armed"
rm -rf $s

# (ii-e) a dump that CANNOT be deleted must never reach compinit.
# macOS ACLs can grant write while denying delete, so `rm -f` fails on exactly
# the file that must go. The payload is appended below the genuine header.
if [[ $OSTYPE == darwin* ]]; then
    s=$(mktemp -d); mkdir -p $s/zd/completions
    zsh -f -c "ZDOTDIR=$s/zd; source $SRC" </dev/null >/dev/null 2>&1
    print -r -- '' >> $s/zd/.zcompdump
    print -r -- 'print DENY-DELETE-PAYLOAD-RAN' >> $s/zd/.zcompdump
    chmod 600 $s/zd/.zcompdump
    chmod +a 'everyone allow write' $s/zd/.zcompdump 2>/dev/null
    chmod +a 'everyone deny delete' $s/zd/.zcompdump 2>/dev/null
    out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1; print COMPS=\${#_comps}" </dev/null 2>&1 )
    check "an undeletable hostile dump is never sourced" \
          "$([[ $out == *DENY-DELETE-PAYLOAD-RAN* ]] && print RAN || print blocked)" "blocked"
    check "and its stamp is not armed" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "absent"
    check "and completions still initialise without a cache" \
          "$([[ $out == *COMPS=0* || $out != *COMPS=* ]] && print broken || print working)" "working"
    chmod -N $s/zd/.zcompdump 2>/dev/null; rm -rf $s
else
    print "SKIP  deny-delete ACL case (not darwin)"
fi

# (ii-f) a DIRECTORY named .zcompdump must not be certified, nor deleted
# recursively, nor used as a destination for generated dumps.
s=$(mktemp -d); mkdir -p $s/zd/completions; mkdir -p -m 700 $s/zd/.zcompdump
out=$( zsh -f -c "ZDOTDIR=$s/zd; source $SRC 2>&1; print COMPS=\${#_comps}" </dev/null 2>&1 )
check "a .zcompdump DIRECTORY is not certified with a stamp" \
      "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "absent"
check "and it is not recursively deleted" \
      "$([[ -d $s/zd/.zcompdump ]] && print preserved || print DELETED)" "preserved"
check "and compinit does not deposit a dump inside it" \
      "$(command ls -1 $s/zd/.zcompdump 2>/dev/null | wc -l | tr -d ' ')" "0"
check "and completions still initialise" \
      "$([[ $out == *COMPS=0* || $out != *COMPS=* ]] && print broken || print working)" "working"
rm -rf $s

# (ii-g) the ACL probe must not be alias-expanded. zsh/.zshrc sources
# zsh/aliases.zsh BEFORE this file, and that defines `alias ls='eza …'`; zsh
# expands aliases at PARSE time, so a bare `ls` inside the function would run
# eza in production. Loads the real shipped aliases, then this file.
#
# The observable is the DOWNSTREAM effect, not the stub's output: the probe
# captures its command's stdout into a function-local, so a "did the stub run"
# assertion could never see it and would be vacuous. If the wrong binary is
# used, its output does not match the expected contract, the ACL check fails
# closed, and the cache is rejected — so "is the cache still accepted" is the
# assertion with real content.
s=$(mktemp -d); mkdir -p $s/zd/completions
_aliases=${SRC:h}/aliases.zsh
if [[ -r $_aliases ]]; then
    out=$( zsh -f -c "
ZDOTDIR=$s/zd
CONFIG_DIR=${SRC:h:h}
source $_aliases 2>/dev/null
alias ls='print EZA-STUB-RAN;'
source $SRC 2>&1
print COMPS=\${#_comps}" </dev/null 2>&1 )
    check "and a clean cache is still accepted with aliases loaded" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "armed"
    # ...and the same on the NON-darwin branch, which is where the bare `ls`
    # actually lived. On macOS the darwin branch already used an absolute path,
    # so only this variant exercises the defect.
    rm -rf $s; s=$(mktemp -d); mkdir -p $s/zd/completions
    out=$( zsh -f -c "
OSTYPE=linux-gnu
ZDOTDIR=$s/zd
source $_aliases 2>/dev/null
alias ls='print EZA-STUB-RAN;'
source $SRC 2>&1
print COMPS=\${#_comps}" </dev/null 2>&1 )
    check "and a clean cache is accepted on the linux branch with aliases loaded" \
          "$([[ -f $s/zd/$STAMP ]] && print armed || print absent)" "armed"
else
    print "SKIP  alias-expansion case (aliases.zsh not readable)"
fi
unset _aliases
rm -rf $s

# (iii) an fpath entry spelled differently but resolving to the same directory.
# A raw string filter let `<cache>/` through and the auditor was pinned from it.
for _alias in '/' '/.' ''; do
    s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 0777 $s/zd/completions
    print -r -- 'print COMPINIT-ATTACKER-RAN' > $s/zd/completions/compinit
    chmod 0666 $s/zd/completions/compinit
    out=$( zsh -f -c "
ZDOTDIR=$s/zd
fpath=($s/zd/completions$_alias \$fpath)
source $SRC 2>&1
p=\${\${:-$s/zd/completions}:A}
n=0; for d in \$fpath; do [[ \${d:A} == \$p ]] && (( n++ )); done
print PHYS_COUNT=\$n" </dev/null 2>&1 )
    check "fpath alias '<cache>$_alias' is purged by physical identity" \
          "$([[ $out == *PHYS_COUNT=0* ]] && print 0 || print nonzero)" "0"
    check "and no attacker compinit runs via alias '<cache>$_alias'" \
          "$([[ $out == *COMPINIT-ATTACKER-RAN* ]] && print RAN || print blocked)" "blocked"
    rm -rf $s
done
unset _alias

# (iv) a symlinked alias of the cache directory
s=$(mktemp -d); mkdir -p $s/zd/completions; chmod 0777 $s/zd/completions
print -r -- 'print COMPINIT-ATTACKER-RAN' > $s/zd/completions/compinit
chmod 0666 $s/zd/completions/compinit
ln -s $s/zd/completions $s/alias-link
out=$( zsh -f -c "
ZDOTDIR=$s/zd
fpath=($s/alias-link \$fpath)
source $SRC 2>&1
p=\${\${:-$s/zd/completions}:A}
n=0; for d in \$fpath; do [[ \${d:A} == \$p ]] && (( n++ )); done
print PHYS_COUNT=\$n" </dev/null 2>&1 )
check "a SYMLINKED alias of the cache is purged by physical identity" \
      "$([[ $out == *PHYS_COUNT=0* ]] && print 0 || print nonzero)" "0"
check "and no attacker compinit runs via the symlinked alias" \
      "$([[ $out == *COMPINIT-ATTACKER-RAN* ]] && print RAN || print blocked)" "blocked"
rm -rf $s

# --- 17. DIFFERENTIAL: the old glob idiom must not come back -----------------
old_always_true=$(zsh -f -c '
    d=$(mktemp -d); rm -f $d/.zcompdump
    if [[ -n $d/.zcompdump(#qN.mh-24) ]]; then print yes; else print no; fi' 2>/dev/null)
check "the old (#q...) test without EXTENDED_GLOB is true even with NO dump" \
      "$old_always_true" "yes"
check "no executable line in the shipped file uses that glob qualifier" \
      "$(grep -v '^[[:space:]]*#' $SRC | grep -c '(#q')" "0"

print
(( FAILED )) && { print "SOME TESTS FAILED"; exit 1 }
print "ALL PASS"
