#!/usr/bin/env zsh
# Regressions for the history location in zsh/variables.zsh, the history
# options in zsh/.zshrc, and the zsh/local.zsh hook.
#
# Pinned here:
#   1. history lives in ${XDG_STATE_HOME:-~/.local/state}/zsh/history, in a
#      0700 directory outside this repository's working copy;
#   2. the old zsh/.zsh_history moves there once: never over an existing file,
#      never merged, never deleted;
#   3. when the new place is unusable, the shell keeps the old file for that
#      session and says so in one stderr line;
#   4. a command typed with a leading space never reaches the history file;
#   5. the machine-only Firefox profile comes from the gitignored local.zsh.
#
# Each case runs a clean `zsh -f` (env -i) whose HOME, ZDOTDIR and
# XDG_STATE_HOME sit in a throwaway directory, sourcing a COPY of the shipped
# file. Your real history is never read or written.
#
# Run: zsh zsh/variables-tests.zsh
set -u
emulate -L zsh
zmodload -F zsh/stat b:zstat

SRC=${0:A:h}/variables.zsh
ZSHRC=${0:A:h}/.zshrc
[[ -r $SRC && -r $ZSHRC ]] || { print -u2 "cannot read $SRC or $ZSHRC"; exit 2 }

typeset -g FAILED=0
pass() { print "PASS  $1" }
fail() { print "FAIL  $1"; FAILED=1 }
check() { [[ $2 == $3 ]] && pass "$1" || { fail "$1"; print "        expected: $3"; print "        actual:   $2" } }
exists() { [[ -e $1 ]] && print yes || print no }
# File reads go through slurp: `zsh -n` still expands a top-level $(<file).
slurp() { [[ -f $1 ]] && print -r -- "$(<$1)" }
lines_in() { local -a l; [[ -s $1 ]] && l=("${(@f)$(<$1)}"); print ${#l} }
mode_of() { local m; m=$(zstat +mode $1 2>/dev/null) || { print none; return }; print $(( [##8] m & 8#777 )) }

ROOT=$(mktemp -d) || exit 2
trap 'chmod -R u+w $ROOT 2>/dev/null; rm -rf $ROOT' EXIT

# new_home NAME: a sandbox HOME holding a copy of the shipped file.
new_home() {
    local h=$ROOT/$1
    mkdir -p $h/.config/zsh
    cp $SRC $h/.config/zsh/variables.zsh
    print -r -- $h
}

# in_home HOME XDG_STATE_HOME CMD: run CMD in a clean zsh inside the sandbox;
# its stderr lands in HOME/stderr.
in_home() {
    local h=$1 xdg=$2
    env -i PATH=$PATH HOME=$h ZDOTDIR=$h/.config/zsh ${xdg:+XDG_STATE_HOME=$xdg} \
        zsh -f -c "source \$ZDOTDIR/variables.zsh; $3" 2>$h/stderr
}
histfile_in() { in_home $1 "${2:-}" 'print -r -- $HISTFILE' }

OLD=.config/zsh/.zsh_history
NEW=.local/state/zsh/history

# --- 1. fresh machine ---------------------------------------------------------
h=$(new_home fresh)
check "fresh: HISTFILE is the XDG state path" "$(histfile_in $h)" "$h/$NEW"
check "fresh: the history directory is created 0700" "$(mode_of $h/.local/state/zsh)" "700"
check "fresh: nothing on stderr" "$(slurp $h/stderr)" ""
check "fresh: no file appears at the old path" "$(exists $h/$OLD)" "no"

# --- 2. old file only: moved once, and again is a no-op -----------------------
h=$(new_home old-only)
print -r -- ': 1:0;old-line' > $h/$OLD
check "old-only: HISTFILE is the new path" "$(histfile_in $h)" "$h/$NEW"
check "old-only: the old content is now in the new file" "$(slurp $h/$NEW)" ": 1:0;old-line"
check "old-only: the old file is gone (moved, not copied)" "$(exists $h/$OLD)" "no"
check "old-only: nothing on stderr" "$(slurp $h/stderr)" ""
check "old-only, next shell: same path" "$(histfile_in $h)" "$h/$NEW"
check "old-only, next shell: content unchanged and quiet" "$(slurp $h/$NEW)|$(slurp $h/stderr)" ": 1:0;old-line|"

# --- 3. both present: never overwritten, merged or deleted --------------------
h=$(new_home both)
mkdir -p -m 700 $h/.local/state/zsh
print -r -- old-line > $h/$OLD
print -r -- new-line > $h/$NEW
check "both: HISTFILE is the new path" "$(histfile_in $h)" "$h/$NEW"
check "both: the new file is not overwritten or merged" "$(slurp $h/$NEW)" "new-line"
check "both: the old file is left untouched" "$(slurp $h/$OLD)" "old-line"
check "both: nothing on stderr" "$(slurp $h/stderr)" ""

# --- 4./5. unusable target: fall back for the session, one stderr line --------
if (( EUID == 0 )); then
    print "SKIP  unwritable-target cases (root ignores directory permissions)"
else
    h=$(new_home unwritable)
    mkdir -p $h/.local/state/zsh && chmod 500 $h/.local/state/zsh
    print -r -- old-line > $h/$OLD
    check "unwritable: HISTFILE falls back to the old path" "$(histfile_in $h)" "$h/$OLD"
    check "unwritable: the old file is intact" "$(slurp $h/$OLD)" "old-line"
    check "unwritable: no new file" "$(exists $h/$NEW)" "no"
    check "unwritable: exactly one stderr line, naming the fallback" \
          "$(lines_in $h/stderr)|$([[ $(slurp $h/stderr) == *"history stays in $h/$OLD"* ]] && print named)" "1|named"

    h=$(new_home unwritable-fresh)
    mkdir -p $h/.local/state/zsh && chmod 500 $h/.local/state/zsh
    check "unwritable dir, no old file: falls back to the old path" "$(histfile_in $h)" "$h/$OLD"
    check "unwritable dir, no old file: exactly one stderr line" "$(lines_in $h/stderr)" "1"

    h=$(new_home uncreatable)
    mkdir -p $h/ro && chmod 500 $h/ro
    check "uncreatable dir, no old file: falls back to the old path" "$(histfile_in $h $h/ro/state)" "$h/$OLD"
    check "uncreatable dir: exactly one stderr line" "$(lines_in $h/stderr)" "1"
fi

# --- 6. XDG_STATE_HOME is honoured --------------------------------------------
h=$(new_home xdg)
check "XDG_STATE_HOME set: history goes under it" "$(histfile_in $h $h/state)" "$h/state/zsh/history"

# --- 7. an interactive shell with the shipped .zshrc history options ---------
h=$(new_home interactive)
setopt_line=$(grep -m1 '^setopt .*HIST_IGNORE_SPACE' $ZSHRC)
check "the shipped .zshrc sets HIST_IGNORE_SPACE" "$([[ -n $setopt_line ]] && print yes)" "yes"
print -rl -- 'source $ZDOTDIR/variables.zsh' "$setopt_line" \
    'print visible-one' ' print hidden-secret' 'print   visible-two' |
    env -i PATH=$PATH HOME=$h ZDOTDIR=$h/.config/zsh zsh -f -i >/dev/null 2>&1
hist=$(slurp $h/$NEW)
check "interactive: a plain command is recorded in the new file" \
      "$([[ $hist == *'print visible-one'* ]] && print recorded)" "recorded"
check "interactive: a leading-space command is not recorded" \
      "$([[ $hist == *hidden-secret* ]] && print recorded || print absent)" "absent"
check "interactive: extra blanks are squeezed" \
      "$([[ $hist == *'print visible-two'* ]] && print squeezed)" "squeezed"

# --- 8. machine-only values come from local.zsh -------------------------------
h=$(new_home local)
print -r -- 'FIREFOX_PROFILE=abcd1234.default-release' > $h/.config/zsh/local.zsh
check "local.zsh: FIREFOX_USER_CHROME is built from FIREFOX_PROFILE" \
      "$(in_home $h '' 'print -r -- ${FIREFOX_USER_CHROME-unset}')" \
      "$h/Library/Application Support/Firefox/Profiles/abcd1234.default-release/chrome"
h=$(new_home no-local)
check "no local.zsh: FIREFOX_USER_CHROME stays unset" \
      "$(in_home $h '' 'print -r -- ${FIREFOX_USER_CHROME-unset}')" "unset"
check "the shipped file names no home directory" "$(grep -cE '/(Users|home)/' $SRC)" "0"

print
(( FAILED )) && { print "SOME TESTS FAILED"; exit 1 }
print "ALL PASS"
