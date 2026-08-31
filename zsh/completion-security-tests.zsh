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
s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP; : >| $s/zd/.zcompdump
run_shipped $s
check "a fresh clean-audit stamp takes the -C fast path" "$(branch_of $s/record)" "fast"
rm -rf $s

# --- 3. STALE: a stamp over 24h old re-runs the full audit --------------------
s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP
touch -t 202501010000 $s/zd/$STAMP
run_shipped $s
check "a stale stamp re-runs the full compaudit" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 4. ABORTED audit must not leave a usable fast path ----------------------
s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP
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
s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP
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
s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 600 $s/zd/$STAMP
touch -t 203501010000 $s/zd/$STAMP; : >| $s/zd/.zcompdump
run_shipped $s
check "a FUTURE-dated stamp is not accepted as fresh" "$(branch_of $s/record)" "full"
rm -rf $s

# --- 7. A stamp that is not ours/not a regular file is not trusted -----------
s=$(new_sandbox); : >| $s/zd/real-stamp; ln -s $s/zd/real-stamp $s/zd/$STAMP
: >| $s/zd/.zcompdump
run_shipped $s
check "a SYMLINKED stamp is not trusted" "$(branch_of $s/record)" "full"
rm -rf $s

s=$(new_sandbox); : >| $s/zd/$STAMP; chmod 666 $s/zd/$STAMP; : >| $s/zd/.zcompdump
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

# --- 12. DIFFERENTIAL: the old glob idiom must not come back -----------------
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
