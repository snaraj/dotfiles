#!/usr/bin/env python3
"""Exhaustive scenario campaign for the kitty directional-split kitten.

Re-run:  python3 campaign.py --all            (full campaign, ~45-70 min)
         python3 campaign.py --smoke          (fast sanity pass)
         python3 campaign.py --systematic --max-depth 3
         python3 campaign.py --random --walks 150 --seed0 0
         python3 campaign.py --owner
         python3 campaign.py --replay split-right,split-down,close-focused

Add --restart after editing the kitten; a running lab holds the old copy.

It launches its own minimized kitty on a private socket and kills it again,
so it never touches the terminal you are sitting in. Everything is driven
over kitty's remote-control socket, speaking the wire protocol directly (no
`kitten @` process spawn) for speed.

Under test by default is the SHIPPED ../split_dir.py. controls/ holds two
deliberately broken kittens, so a green run cannot be mistaken for a suite
with no teeth:

    SPLIT_KITTEN=controls/split_dir_naive.py python3 campaign.py --owner
        the pre-rebuild behaviour -> 18 of 47 fail, drift over 1600px
    SPLIT_KITTEN=controls/split_dir_v4orig.py python3 campaign.py --owner
        the same plus the Pair.parent shadowing bug -> 20 of 47 fail

If a control ever comes back green, the harness is broken, not fixed.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import random
import socket
import subprocess
import sys
import time

LAB = os.path.dirname(os.path.abspath(__file__))
KITTY = '/Applications/kitty.app/Contents/MacOS/kitty'
SOCK_BASE = '/tmp/kitty-split-lab'
STATE_FILE = '/tmp/split-lab-state.json'
DRIFT_TOL = 48          # I1/I2/I4 per-edge drift tolerance (px)
OVERLAP_TOL = 4         # I3 border-width overlap tolerance (px)
MIN_SIZE = 5            # I3 minimum window extent (px)
MAX_WINDOWS = 10
SETTLE = 0.14           # seconds after an action before probing
# Manual resizes must be BIGGER than DRIFT_TOL, otherwise a kitten that quietly
# re-equalizes would hide inside the tolerance. 6 cells ~= 100px here.
RESIZE_INCREMENT = 6
# Which kitten is under test. Paths are resolved by kitty against
# KITTY_CONFIG_DIRECTORY, which the lab points at this directory, so the
# default reaches one level up to the SHIPPED kitten rather than a copy that
# could silently drift out of date. SPLIT_KITTEN=controls/split_dir_naive.py
# runs a negative control instead (see controls/README lines in each file).
KITTEN = os.environ.get('SPLIT_KITTEN', os.path.join('..', 'split_dir.py'))

SPLITS = ['split-right', 'split-down', 'split-left', 'split-up']
CORE_ALPHABET = SPLITS + ['close-focused', 'next-layout']
RANDOM_ALPHABET = CORE_ALPHABET + [
    'resize-taller', 'resize-shorter', 'resize-wider', 'resize-narrower',
    'resize-taller', 'resize-shorter', 'resize-wider', 'resize-narrower',
    'focus-next', 'close-random',
]


# ---------------------------------------------------------------- RC transport
class RCError(Exception):
    pass


class Lab:
    def __init__(self, verbose: bool = False) -> None:
        self.sock_path: str | None = None
        self.verbose = verbose
        self.restarts = 0
        self.ensure_kitty()

    # -- process lifecycle ------------------------------------------------
    def find_socket(self) -> str | None:
        socks = sorted(glob.glob(SOCK_BASE + '-*'))
        return socks[-1] if socks else None

    def kill_kitty(self) -> None:
        subprocess.run(['pkill', '-f', 'kitty --config ' + LAB + '/lab.conf'],
                       capture_output=True)
        for s in glob.glob(SOCK_BASE + '-*'):
            try:
                os.unlink(s)
            except OSError:
                pass
        time.sleep(1.0)

    def ensure_kitty(self, force_restart: bool = False) -> None:
        if force_restart:
            self.kill_kitty()
            self.restarts += 1
        self.sock_path = self.find_socket()
        if self.sock_path is None:
            env = dict(os.environ, KITTY_CONFIG_DIRECTORY=LAB)
            subprocess.Popen(
                [KITTY, '--config', os.path.join(LAB, 'lab.conf'),
                 '--start-as=minimized', '--detach'],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                time.sleep(0.2)
                self.sock_path = self.find_socket()
                if self.sock_path:
                    break
            else:
                raise RCError('lab kitty did not come up')
            time.sleep(1.5)
        self.ensure_os_window()

    # -- wire protocol ----------------------------------------------------
    def rc(self, cmd: str, payload: dict, retry: bool = True):
        msg = {'cmd': cmd, 'version': [0, 26, 0], 'payload': payload}
        data = b'\x1bP@kitty-cmd' + json.dumps(msg).encode() + b'\x1b\\'
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(15.0)
            s.connect(self.sock_path)
            s.sendall(data)
            buf = b''
            while b'\x1b\\' not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
            s.close()
        except (OSError, socket.timeout) as e:
            if retry:
                self.ensure_kitty(force_restart=True)
                return self.rc(cmd, payload, retry=False)
            raise RCError('socket failure: %r' % (e,))
        if not buf:
            return None
        i = buf.find(b'@kitty-cmd')
        j = buf.find(b'\x1b\\', i)
        try:
            resp = json.loads(buf[i + len('@kitty-cmd'):j].decode())
        except Exception:
            return None
        if isinstance(resp, dict) and resp.get('ok') is False:
            raise RCError('%s failed: %s' % (cmd, str(resp.get('error'))[:400]))
        return resp.get('data') if isinstance(resp, dict) else None

    def action(self, spec: str):
        return self.rc('action', {'action': spec})

    def ls(self):
        return self.rc('ls', {'output_format': 'json'})

    def ensure_os_window(self) -> None:
        try:
            data = self.ls()
        except RCError:
            data = None
        need = True
        if data:
            try:
                oswins = json.loads(data) if isinstance(data, str) else data
                need = not oswins
            except Exception:
                need = False        # ls parse issue is not "no os-window"
        if need:
            self.rc('launch', {'type': 'os-window', 'location': 'default',
                               'stdin_source': 'none', 'logo_alpha': -1,
                               'os_window_state': 'minimized'})
            time.sleep(1.2)

    # -- state ------------------------------------------------------------
    def state(self) -> dict:
        try:
            os.unlink(STATE_FILE)
        except OSError:
            pass
        self.action('kitten probe_state.py ' + STATE_FILE)
        for _ in range(60):
            if os.path.exists(STATE_FILE):
                try:
                    with open(STATE_FILE) as f:
                        return json.load(f)
                except (ValueError, OSError):
                    pass
            time.sleep(0.05)
        raise RCError('probe_state produced no output (kitty wedged?)')

    # -- scenario primitives ----------------------------------------------
    def reset(self) -> dict:
        """Back to exactly one window, splits layout, even sizes."""
        for attempt in range(3):
            try:
                self.ensure_os_window()
                st = self.state()
                if st.get('error') or not st.get('windows'):
                    self.rc('launch', {'type': 'os-window', 'location': 'default',
                                       'stdin_source': 'none', 'logo_alpha': -1,
                                       'os_window_state': 'minimized'})
                    time.sleep(1.2)
                    st = self.state()
                ids = sorted(int(i) for i in st['windows'])
                keep = st.get('focused') or ids[0]
                doomed = [i for i in ids if i != keep]
                if doomed:
                    self.rc('close-window',
                            {'match': ' or '.join('id:%d' % i for i in doomed)})
                    time.sleep(0.1 + 0.05 * len(doomed))
                st = self.state()
                if len(st.get('windows', {})) != 1:
                    for i in [int(x) for x in st.get('windows', {})][1:]:
                        self.rc('close-window', {'match': 'id:%d' % i})
                        time.sleep(0.1)
                    st = self.state()
                if st.get('layout') != 'splits':
                    self.rc('goto-layout', {'layout': 'splits'})
                    time.sleep(0.15)
                self.action('resize_window reset')
                time.sleep(0.1)
                st = self.state()
                if len(st.get('windows', {})) == 1 and st.get('layout') == 'splits':
                    return st
            except RCError:
                self.ensure_kitty(force_restart=True)
        raise RCError('could not reset lab to a single window')

    def do(self, act: str, st: dict) -> None:
        if act.startswith('split-'):
            self.action('kitten %s %s' % (KITTEN, act.split('-', 1)[1]))
        elif act == 'next-layout':
            # exactly what the owner's cmd+shift+l does
            self.action('combine : next_layout : resize_window reset')
        elif act == 'close-focused':
            self.rc('close-window', {'match': 'id:%d' % st['focused']})
        elif act == 'close-random':
            ids = sorted(int(i) for i in st['windows'])
            self.rc('close-window', {'match': 'id:%d' % random.choice(ids)})
        elif act == 'focus-next':
            self.action('next_window')
        elif act.startswith('resize-'):
            self.action('resize_window %s %d' % (act.split('-', 1)[1],
                                                 RESIZE_INCREMENT))
        else:
            raise ValueError(act)
        time.sleep(SETTLE)


# ------------------------------------------------------------- invariants
def rects(st):
    return {int(k): v for k, v in st['windows'].items()}


def drift(a, b):
    return max(abs(a[i] - b[i]) for i in range(4))


def overlap(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return w, h


def leaf_groups(node, out):
    if node is None:
        return
    if isinstance(node, int):
        out.append(node)
        return
    leaf_groups(node.get('one'), out)
    leaf_groups(node.get('two'), out)


def sibling_windows(st, closed_win):
    """Window ids in the sibling subtree of the closed window's leaf (I4)."""
    gid = None
    for g, info in st.get('groups', {}).items():
        if closed_win in info.get('windows', []):
            gid = int(g)
    if gid is None:
        return None
    root = st.get('pairs_root')
    found = []

    def walk(node):
        if not isinstance(node, dict):
            return
        for a, b in (('one', 'two'), ('two', 'one')):
            if node.get(a) == gid:
                leaves = []
                leaf_groups(node.get(b), leaves)
                found.append(leaves)
        walk(node.get('one'))
        walk(node.get('two'))

    walk(root)
    if not found:
        return None
    wins = set()
    for g in found[0]:
        for w in st['groups'].get(str(g), {}).get('windows', []):
            wins.add(w)
    return wins


def check(prev, cur, act, tag):
    """Returns list of violation strings."""
    bad = []
    pr, cr = rects(prev), rects(cur)
    prev_layout, cur_layout = prev.get('layout'), cur.get('layout')

    # responsiveness / internal consistency (part of I3)
    if cur.get('exc'):
        bad.append('I3 probe exception: ' + cur['exc'].splitlines()[-1])
    if cur.get('neighbors_ok') is False:
        bad.append('I3 neighbors_for_window raised: %s' % cur.get('neighbors_err'))

    # I5 bookkeeping
    if act.startswith('split-'):
        if len(cr) != len(pr) + 1:
            bad.append('I5 split changed count %d -> %d' % (len(pr), len(cr)))
    elif act.startswith('close-'):
        if len(cr) != len(pr) - 1:
            bad.append('I5 close changed count %d -> %d' % (len(pr), len(cr)))
    else:
        if len(cr) != len(pr):
            bad.append('I5 %s changed count %d -> %d' % (act, len(pr), len(cr)))

    # I3 tiling sanity
    if cur_layout != 'stack':
        for i, r in cr.items():
            if r[2] - r[0] < MIN_SIZE or r[3] - r[1] < MIN_SIZE:
                bad.append('I3 window %d degenerate %s' % (i, r))
        ids = sorted(cr)
        for a in range(len(ids)):
            for b in range(a + 1, len(ids)):
                w, h = overlap(cr[ids[a]], cr[ids[b]])
                if w > OVERLAP_TOL and h > OVERLAP_TOL:
                    bad.append('I3 windows %d/%d overlap %dx%d' %
                               (ids[a], ids[b], w, h))

    # I1 / I2 split geometry preservation
    if act.startswith('split-') and len(cr) == len(pr) + 1:
        foc = prev.get('focused')
        new = [i for i in cr if i not in pr]
        if len(new) != 1:
            bad.append('I1 expected 1 new window, got %s' % new)
        elif prev_layout == 'stack':
            pass                                   # documented equalize fallback
        elif foc in pr and foc in cr:
            for i, r in pr.items():
                if i == foc:
                    continue
                if i in cr and drift(r, cr[i]) > DRIFT_TOL:
                    key = 'I1' if prev_layout == 'splits' else 'I2'
                    bad.append('%s window %d drifted %dpx (%s -> %s) from %s' %
                               (key, i, drift(r, cr[i]), r, cr[i], prev_layout))
            a, b = cr[foc], cr[new[0]]
            union = [min(a[0], b[0]), min(a[1], b[1]),
                     max(a[2], b[2]), max(a[3], b[3])]
            if drift(union, pr[foc]) > DRIFT_TOL:
                bad.append('I1 split pair %s does not tile old rect %s' %
                           (union, pr[foc]))
            w, h = overlap(a, b)
            if w > OVERLAP_TOL and h > OVERLAP_TOL:
                bad.append('I1 split pair overlaps %dx%d' % (w, h))

    # I4 close locality (splits only)
    if act.startswith('close-') and prev_layout == 'splits' and \
            cur_layout == 'splits' and len(cr) == len(pr) - 1 and len(cr) >= 1:
        closed = [i for i in pr if i not in cr]
        if closed:
            sibs = sibling_windows(prev, closed[0])
            if sibs is not None:
                for i, r in cr.items():
                    if i in sibs:
                        continue
                    if i in pr and drift(pr[i], r) > DRIFT_TOL:
                        bad.append('I4 window %d outside sibling subtree drifted '
                                   '%dpx (%s -> %s)' % (i, drift(pr[i], r),
                                                        pr[i], r))
    return ['%s [%s]' % (b, tag) for b in bad]


# ------------------------------------------------------------- enumeration
def enumerate_sequences(max_depth):
    """All action sequences of length 1..max_depth that stay within 1..10 windows."""
    out = []
    frontier = [([], 1)]
    for _ in range(max_depth):
        nxt = []
        for seq, n in frontier:
            for a in CORE_ALPHABET:
                if a.startswith('split-'):
                    if n + 1 > MAX_WINDOWS:
                        continue
                    m = n + 1
                elif a == 'close-focused':
                    if n <= 1:
                        continue
                    m = n - 1
                else:
                    m = n
                nxt.append((seq + [a], m))
        out.extend(s for s, _ in nxt)
        frontier = nxt
    return out


# ------------------------------------------------------------------- runner
class Runner:
    def __init__(self, lab, logf, stop_after=None):
        self.lab = lab
        self.logf = logf
        self.passed = 0
        self.failed = 0
        self.failures = []
        self.actions = 0
        self.stop_after = stop_after

    def log(self, line):
        self.logf.write(line + '\n')
        self.logf.flush()

    def run_scenario(self, sid, seq, note=''):
        try:
            st = self.lab.reset()
        except RCError as e:
            self.log('%s FAIL reset: %s' % (sid, e))
            self.failed += 1
            self.failures.append((sid, seq, 'reset: %s' % e))
            return False
        bad = []
        for k, act in enumerate(seq):
            try:
                self.lab.do(act, st)
                nxt = self.lab.state()
            except RCError as e:
                bad.append('RC failure after %s: %s' % (act, e))
                self.lab.ensure_kitty(force_restart=True)
                break
            self.actions += 1
            bad += check(st, nxt, act, 'step%d=%s' % (k + 1, act))
            st = nxt
            if bad:
                break
        if bad:
            self.failed += 1
            self.failures.append((sid, seq, bad))
            self.log('%s FAIL seq=%s %s | %s' % (sid, ','.join(seq), note,
                                                 ' ;; '.join(bad[:4])))
            return False
        self.passed += 1
        self.log('%s PASS seq=%s %s' % (sid, ','.join(seq), note))
        return True


def phase_systematic(runner, max_depth, sample_depth4=None, seed=99):
    seqs = enumerate_sequences(max_depth)
    by_len = {}
    for s in seqs:
        by_len.setdefault(len(s), []).append(s)
    chosen = []
    for L in sorted(by_len):
        pool = by_len[L]
        if sample_depth4 and L == max_depth and len(pool) > sample_depth4:
            random.Random(seed).shuffle(pool)
            pool = pool[:sample_depth4]
        chosen.extend(pool)
    runner.log('# SYSTEMATIC: %d scenarios (%s)' %
               (len(chosen), {L: sum(1 for c in chosen if len(c) == L)
                              for L in sorted(by_len)}))
    for n, seq in enumerate(chosen):
        runner.run_scenario('SYS%04d' % n, seq)
    return len(chosen)


def phase_random(runner, walks, seed0):
    runner.log('# RANDOMIZED: %d walks' % walks)
    for w in range(walks):
        seed = seed0 + w
        rnd = random.Random(seed)
        random.seed(seed)         # close-random uses the global rng
        length = rnd.randint(8, 20)
        seq, n = [], 1
        for _ in range(length):
            opts = []
            for a in RANDOM_ALPHABET:
                if a.startswith('split-'):
                    if n + 1 <= MAX_WINDOWS:
                        opts.append(a)
                elif a.startswith('close-'):
                    if n > 1:
                        opts.append(a)
                else:
                    opts.append(a)
            a = rnd.choice(opts)
            seq.append(a)
            n += 1 if a.startswith('split-') else (-1 if a.startswith('close-') else 0)
        random.seed(seed)
        runner.run_scenario('RND%04d' % w, seq, note='seed=%d' % seed)
    return walks


def phase_owner(runner):
    """The owner's reported bug classes, scripted."""
    cases = []
    # A. split, resize, close one of the pair, split again
    for d1 in SPLITS:
        for d2 in SPLITS:
            cases.append((['split-' + d1.split('-')[1], 'resize-wider', 'resize-taller',
                           'close-focused', 'split-' + d2.split('-')[1]], 'A resize+close+split'))
    # B. cycle layouts between splits/closes
    for k in range(1, 8):
        cases.append((['split-right', 'split-down'] + ['next-layout'] * k +
                      ['split-right'], 'B cycle%d then split' % k))
        cases.append((['split-right', 'split-down', 'resize-wider', 'resize-taller'] +
                      ['next-layout'] * k + ['split-down'], 'B resize+cycle%d+split' % k))
    # C. build N even windows via cycle->split, delete to 3 parallel, split again
    for n in range(3, 8):
        seq = ['split-right'] * (n - 1) + ['next-layout', 'next-layout']
        seq += ['split-down']
        seq += ['close-focused'] * max(0, (n + 1) - 3)
        seq += ['split-right']
        cases.append((seq, 'C screenshot case n=%d' % n))
    # D. manual resize then layout ring round-trip (7 layouts) then split
    cases.append((['split-right', 'split-down', 'split-left', 'resize-wider',
                   'resize-narrower', 'resize-taller'] + ['next-layout'] * 7 +
                  ['split-up'], 'D full ring round trip'))
    # E. deep tree, close interior, split again
    for d in SPLITS:
        cases.append((['split-right', 'split-down', 'split-right', 'split-down',
                       'close-focused', 'close-focused', 'split-' + d.split('-')[1]],
                      'E deep close+split'))
    # F. every layout as a conversion source, with prior manual resize
    for k in range(7):
        cases.append((['split-right', 'split-down', 'resize-wider'] +
                      ['next-layout'] * k + ['split-right', 'split-down'],
                      'F convert from ring position %d' % k))
    runner.log('# OWNER-REPRO: %d scenarios' % len(cases))
    for n, (seq, note) in enumerate(cases):
        runner.run_scenario('OWN%03d' % n, seq, note=note)
    return len(cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--smoke', action='store_true')
    ap.add_argument('--systematic', action='store_true')
    ap.add_argument('--random', action='store_true')
    ap.add_argument('--owner', action='store_true')
    ap.add_argument('--replay')
    ap.add_argument('--max-depth', type=int, default=4)
    ap.add_argument('--sample-depth4', type=int, default=None)
    ap.add_argument('--walks', type=int, default=150)
    ap.add_argument('--seed0', type=int, default=0)
    ap.add_argument('--log', default=os.path.join(LAB, 'campaign.log'))
    ap.add_argument('--restart', action='store_true',
                    help='kill any running lab kitty first (needed after editing the kitten)')
    ap.add_argument('--leave-running', action='store_true')
    args = ap.parse_args()

    t0 = time.time()
    lab = Lab()
    if args.restart:
        lab.ensure_kitty(force_restart=True)
    logf = open(args.log, 'a')
    logf.write('\n===== run %s args=%s =====\n' % (time.strftime('%F %T'), sys.argv[1:]))
    runner = Runner(lab, logf)
    counts = {}

    if args.replay:
        seq = args.replay.split(',')
        runner.run_scenario('REPLAY', seq)
    if args.smoke:
        counts['smoke'] = phase_systematic(runner, 2)
    if args.systematic or args.all:
        counts['systematic'] = phase_systematic(runner, args.max_depth,
                                                args.sample_depth4)
    if args.owner or args.all:
        counts['owner'] = phase_owner(runner)
    if args.random or args.all:
        counts['random'] = phase_random(runner, args.walks, args.seed0)

    dt = time.time() - t0
    summary = ('SUMMARY %s pass=%d fail=%d actions=%d restarts=%d wall=%.1fs'
               % (counts, runner.passed, runner.failed, runner.actions,
                  lab.restarts, dt))
    runner.log(summary)
    print(summary)
    for sid, seq, bad in runner.failures[:80]:
        print('  FAIL %s %s -> %s' % (sid, ','.join(seq), bad if isinstance(bad, str) else ' ;; '.join(bad[:3])))
    if not args.leave_running:
        lab.kill_kitty()
    logf.close()
    return 1 if runner.failed else 0


if __name__ == '__main__':
    sys.exit(main())
