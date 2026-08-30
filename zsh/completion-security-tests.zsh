#!/usr/bin/env zsh
# Regressions for the compinit security audit in zsh/completion-init.zsh.
#
# Two distinct fail-open bugs are pinned here, both of which shipped:
#   1. the `(#qN.mh-24)` age test is inert without EXTENDED_GLOB, so it was
#      always true and `compinit -C` (which skips compaudit) always ran;
#   2. an unconditional `touch` of the dump refreshed the mtime even when
#      compinit ABORTED on insecure completion directories, caching a rejected
#      audit as a trusted fast path.
#
# Run: zsh zsh/completion-security-tests.zsh
set -u
emulate -L zsh

SRC=${0:A:h}/completion-init.zsh
[[ -r $SRC ]] || { print -u2 "cannot read $SRC"; exit 2 }

typeset -g FAILED=0
pass() { print "PASS  $1" }
fail() { print "FAIL  $1"; FAILED=1 }
check() { [[ $2 == $3 ]] && pass "$1" || { fail "$1"; print "        expected: $3"; print "        actual:   $2" } }

# A sandbox ZDOTDIR with a recording `compinit` stub earlier in fpath than the
# real one, so the BRANCH the shipped code selects is observable. The stub is
# what `autoload -Uz compinit` resolves to.
new_sandbox() {
    local d=$(mktemp -d)
    mkdir -p $d/zd/completions $d/stub
    cat > $d/stub/compinit <<'STUB'
print -r -- "$*" >> $STUB_RECORD
return ${STUB_RC:-0}
STUB
    print -r -- $d
}

# Source the shipped file in a clean subshell with the stub in front.
run_shipped() {
    local sandbox=$1 rc=${2:-0}
    (
        export ZDOTDIR=$sandbox/zd
        export STUB_RECORD=$sandbox/record
        export STUB_RC=$rc
        fpath=($sandbox/stub)
        source $SRC >/dev/null 2>&1
    )
}

branch_of() {  # "-C ..." => fast, otherwise full
    local rec=$1
    [[ ! -s $rec ]] && { print "none"; return }
    [[ "$(<$rec)" == *-C* ]] && print "fast" || print "full"
}

# --- 1. ABSENT: no dump at all must run the FULL audit -----------------------
s=$(new_sandbox); rm -f $s/zd/.zcompdump
run_shipped $s
check "absent dump runs the full compaudit, not the -C fast path" \
      "$(branch_of $s/record)" "full"
check "absent dump is armed after a successful audit" \
      "$([[ -f $s/zd/.zcompdump ]] && print yes || print no)" "yes"
rm -rf $s

# --- 2. FRESH: a dump under 24h old takes the fast path -----------------------
s=$(new_sandbox); : > $s/zd/.zcompdump
run_shipped $s
check "a fresh dump takes the -C fast path" "$(branch_of $s/record)" "fast"
rm -rf $s

# --- 3. STALE: a dump over 24h old re-runs the full audit and re-arms ---------
s=$(new_sandbox); : > $s/zd/.zcompdump; touch -t 202501010000 $s/zd/.zcompdump
run_shipped $s
check "a stale dump re-runs the full compaudit" "$(branch_of $s/record)" "full"
mt=$(stat -f %m $s/zd/.zcompdump)
check "a successful audit re-arms the 24h fast path" \
      "$(( EPOCHSECONDS - mt < 86400 ? 1 : 0 ))" "1"
rm -rf $s

# --- 4. REJECTED: an aborted audit must NOT be cached as trusted --------------
# compinit returning non-zero is exactly what an insecure-fpath abort does.
s=$(new_sandbox); : > $s/zd/.zcompdump; touch -t 202501010000 $s/zd/.zcompdump
before=$(stat -f %m $s/zd/.zcompdump)
run_shipped $s 1
after=$(stat -f %m $s/zd/.zcompdump)
check "a REJECTED audit leaves the dump mtime untouched" "$after" "$before"
# and the next shell must therefore still take the full path, not -C
rm -f $s/record
run_shipped $s 1
check "the shell after a rejected audit still runs the full audit" \
      "$(branch_of $s/record)" "full"
rm -rf $s

# --- 5. REJECTED against the REAL compinit (no stub) --------------------------
# A world-writable completion dir makes the genuine compaudit refuse.
s=$(mktemp -d); mkdir -p $s/zd/completions
: > $s/zd/completions/_faketool
chmod 0777 $s/zd/completions $s/zd/completions/_faketool
: > $s/zd/.zcompdump; touch -t 202501010000 $s/zd/.zcompdump
before=$(stat -f %m $s/zd/.zcompdump)
( export ZDOTDIR=$s/zd; source $SRC </dev/null >/dev/null 2>&1 )
after=$(stat -f %m $s/zd/.zcompdump)
check "real compaudit refusal does not re-arm the fast path" "$after" "$before"
rm -rf $s

# --- 6. DIFFERENTIAL: the old glob test was always true -----------------------
# Pins the root cause so the old idiom cannot quietly come back.
old_always_true=$(zsh -f -c '
    d=$(mktemp -d); rm -f $d/.zcompdump
    if [[ -n $d/.zcompdump(#qN.mh-24) ]]; then print yes; else print no; fi' 2>/dev/null)
check "the old (#q...) test without EXTENDED_GLOB is true even with NO dump" \
      "$old_always_true" "yes"
# comments may still *describe* the old idiom; no executable line may use it
check "no executable line in the shipped file uses that glob qualifier" \
      "$(grep -v '^[[:space:]]*#' $SRC | grep -c '(#q')" "0"

print
(( FAILED )) && { print "SOME TESTS FAILED"; exit 1 }
print "ALL PASS"
