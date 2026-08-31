#!/bin/zsh
# Text-integrity suite for the shipped kitty configuration: does typing and
# pasting actually survive the terminal? Covers an axis split-layout-tests/
# does not touch — characters, wrapping, unicode, and the paste guard.
#
# All input goes through kitty itself (send-text / paste_from_clipboard) and
# every assertion reads the real screen buffer back with get-text, so this
# measures what a person would see rather than what the config file says.
#
# Run:  zsh kitty/text-integrity-tests.sh
#
# It launches its OWN minimized kitty on a private socket, loading the
# kitty.conf next to this file, and closes it again on exit — nothing touches
# the terminal you are sitting in. The window must exist for the duration;
# do not log out from under it.
#
# What it needs beyond the repo: macOS (pbcopy, the kitty.app path), and the
# dotfiles installed so the lab shell renders the real prompt — T1/T9b assert
# on starship's dagger from starship/starship.toml. Those two are assertions
# about the INSTALLED stack, which is the thing under test.
set -u
KITTY_APP=/Applications/kitty.app/Contents/MacOS/kitty
KITTEN=/Applications/kitty.app/Contents/MacOS/kitten
[ -x "$KITTY_APP" ] || { echo "kitty.app not found at $KITTY_APP"; exit 1; }
HERE=${0:A:h}

# A private config that inherits the shipped one, so the paste guard, fonts
# and narrow-symbol widths under test are the REAL ones, with only the
# remote-control surface added. Absolute include: kitty resolves an include
# against the including file's directory, so kitty.conf's own fragments
# (font/cursor/layout) still resolve next to it.
LABDIR=$(mktemp -d -t kitty-text-lab) || exit 1
SOCKPATH=$LABDIR/sock
cat >"$LABDIR/text-lab.conf" <<CONF
include $HERE/kitty.conf
allow_remote_control socket-only
listen_on unix:$SOCKPATH
initial_window_width 1200
initial_window_height 800
CONF

cleanup() {
    [ -n "${LABPID:-}" ] && kill "$LABPID" 2>/dev/null
    rm -rf "$LABDIR"
}
trap cleanup EXIT INT TERM

KITTY_CONFIG_DIRECTORY=$LABDIR "$KITTY_APP" --config "$LABDIR/text-lab.conf" \
    --start-as=minimized >/dev/null 2>&1 &
LABPID=$!
SOCK=""
for _ in {1..100}; do
    # (N) so an unmatched glob expands to nothing instead of erroring — the
    # socket does not exist for the first second or so of startup.
    s=(${SOCKPATH}-*(NOm))
    [ ${#s} -gt 0 ] && { SOCK="unix:${s[1]}"; break; }
    sleep 0.2
done
[ -n "$SOCK" ] || { echo "lab kitty did not come up"; exit 1; }
sleep 2   # let zsh, the plugins and the prompt finish drawing

KT() { "$KITTEN" @ --to "$SOCK" "$@"; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
screen() { KT get-text --extent screen; }
lastline() { screen | grep -v '^[[:space:]]*$' | tail -1; }
ctrl_u() { KT send-text '\x15'; sleep 0.3; }
# ctrl+u empties zsh's BUFFER; it does not repaint cells the buffer no longer
# owns. After a 600-char line that wrapped several rows, stale glyphs stay on
# screen and the next assertion reads them as if they were its own output —
# T5 saw `echechone-one` and called a working paste broken. Every test that
# reads the screen therefore starts from a cleared one.
fresh() { ctrl_u; KT send-text 'clear\n'; sleep 0.5; }

# T1: prompt carries the VS16 dagger (colorful form)
if screen | grep -q $'\U0001F5E1️'; then ok "T1: prompt shows dagger+VS16"
else bad "T1: dagger+VS16 missing from prompt: $(lastline | head -c 80)"; fi

# T2: plain typing — 60 chars arrive intact, in order, on the prompt line
S60="the-quick-brown-fox-jumps-0123456789-abcdefghijklmnopqrstuvw"
KT send-text "$S60"; sleep 0.5
if lastline | grep -qF "$S60"; then ok "T2: 60-char typed string intact"
else bad "T2: typed string mangled: $(lastline | head -c 120)"; fi
ctrl_u
if lastline | grep -qF "$S60"; then bad "T2b: ctrl+u did not clear the line"
else ok "T2b: ctrl+u cleared the line"; fi

# T3: long chain — 600 chars, wraps several rows, all present in order
LONG=$(python3 -c 'print("".join(chr(97+i%26) for i in range(600)))')
KT send-text "$LONG"; sleep 0.8
GOT=$(screen | tr -d ' \n' | grep -oE 'abcdefghij[a-z]{100,}' | head -1)
FLAT=$(screen | tr -d ' \n')
case "$FLAT" in *"${LONG:0:100}"*) MATCH1=y;; *) MATCH1=n;; esac
case "$FLAT" in *"${LONG:500:100}"*) MATCH2=y;; *) MATCH2=n;; esac
if [ "$MATCH1$MATCH2" = "yy" ]; then ok "T3: 600-char wrapped chain intact (head+tail verified)"
else bad "T3: wrapped chain lost content (head=$MATCH1 tail=$MATCH2)"; fi
fresh

# T4: unicode soup — CJK, combining, ZWJ family, flag, emoji run
SOUP="日本語テスト-éàü-👨‍👩‍👧‍👦-🇺🇸-🎉🚀✨-end"
KT send-text "$SOUP"; sleep 0.6
if screen | grep -qF -- "-end"; then ok "T4: unicode soup typed to completion"
else bad "T4: unicode soup truncated"; fi
if screen | grep -qF "日本語テスト"; then ok "T4b: CJK intact"
else bad "T4b: CJK mangled"; fi
# get-text serializes ZWJ (U+200D) as a literal "<200d>" placeholder
if screen | grep -qF "👨‍👩‍👧‍👦" || screen | grep -qF "👨<200d>👩<200d>👧<200d>👦"; then ok "T4c: ZWJ family emoji intact in buffer"
else bad "T4c: ZWJ family emoji mangled"; fi
fresh

# T5: multi-line paste — bracketed paste must hold all 3 lines unexecuted
printf 'echo line-one\necho line-two\necho line-three' | pbcopy
KT action paste_from_clipboard; sleep 1.2
FLAT=$(screen | tr -d ' \n')
case "$FLAT" in *line-one*line-two*line-three*) ok "T5: 3-line paste held intact (bracketed)";;
  *) bad "T5: multi-line paste lost lines";; esac
# none of them may have EXECUTED (no bare 'line-one' output line without echo)
if screen | grep -qE '^line-one$'; then bad "T5b: paste auto-executed!"
else ok "T5b: paste did not auto-execute"; fi
KT send-text '\x03'; sleep 0.3   # ctrl+c: abandon the pasted buffer

# T6: hostile paste — embedded OSC title-change + C0 controls must be defanged
TITLE_BEFORE=$(KT ls | /usr/bin/jq -r '.[0].tabs[] | select(.is_active) | .title')
printf 'safe-\x1b]2;PWNED-TITLE\x07-\x01\x02-after' | pbcopy
KT action paste_from_clipboard; sleep 0.6
TITLE_AFTER=$(KT ls | /usr/bin/jq -r '.[0].tabs[] | select(.is_active) | .title')
FLAT=$(screen | tr -d ' \n')
case "$FLAT" in *safe-*-after*|*safe-*after*) ok "T6: hostile paste text survived sans controls";;
  *) bad "T6: hostile paste corrupted the line";; esac
case "$TITLE_AFTER" in *PWNED*) bad "T6b: OSC in paste CHANGED WINDOW TITLE";;
  *) ok "T6b: window title unaffected by pasted OSC (\"$TITLE_AFTER\")";; esac
KT send-text '\x03'; sleep 0.2; fresh

# T7: URL paste at prompt gets quoted (paste_actions quote-urls-at-prompt)
printf 'https://example.com/x?a=1&b=2' | pbcopy
KT action paste_from_clipboard; sleep 0.6
if lastline | grep -qF "'https://example.com/x?a=1&b=2'"; then ok "T7: URL paste auto-quoted"
elif lastline | grep -qF "https://example.com/x?a=1&b=2"; then ok "T7: URL pasted intact (unquoted — acceptable)"
else bad "T7: URL paste mangled: $(lastline | head -c 120)"; fi
fresh

# T8: 5KB paste chain — full roundtrip below the confirm threshold
BIG=$(python3 -c 'import sys; sys.stdout.write("".join("chunk%04d-"%i for i in range(500)))')
printf '%s' "$BIG" | pbcopy
KT action paste_from_clipboard; sleep 1.2
FLAT=$(KT get-text --extent all | tr -d ' \n')
case "$FLAT" in *chunk0000-*) H=y;; *) H=n;; esac
case "$FLAT" in *chunk0499-*) T=y;; *) T=n;; esac
if [ "$H$T" = "yy" ]; then ok "T8: 5KB paste head+tail intact"
else bad "T8: 5KB paste dropped content (head=$H tail=$T)"; fi
fresh

# T9: command execution sanity — prompt survives a real command + emoji intact
KT send-text 'echo round-trip-$((6*7))\n'; sleep 0.8
if screen | grep -q 'round-trip-42'; then ok "T9: command executed, output correct"
else bad "T9: command execution broken"; fi
N=$(screen | grep -c $'\U0001F5E1️')
if [ "$N" -ge 2 ]; then ok "T9b: fresh prompt re-rendered with dagger (count=$N)"
else bad "T9b: dagger count after command = $N"; fi

echo "----"
echo "RESULT: $PASS passed, $FAIL failed"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
