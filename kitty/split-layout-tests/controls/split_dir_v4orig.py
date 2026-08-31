# Directional split (cmd+shift+arrows) that never disturbs other windows.
#
# `launch --location=vsplit/hsplit` is honored only by the splits layout.
# When the cmd+shift+l cycle is on another layout, plain keybindings can only
# `goto_layout splits` first — and that conversion rebuilds the pair tree in
# insertion order with default biases, deforming every window except the one
# being split. A mapping cannot branch on "am I converting?", so this kitten
# does:
#   * coming from another layout: capture every window's on-screen rectangle,
#     convert, then REBUILD the splits tree to reproduce those exact
#     rectangles (guillotine recovery: find a full-height or full-width cut
#     line, recurse on each side). What you saw is what you keep — grids stay
#     grids, thirds stay thirds, manual shapes survive the ring.
#   * a layout whose windows overlap (stack) has no tiling to reproduce:
#     convert and equalize, the one honest fallback.
#   * already in splits: split the focused window and touch nothing else —
#     manual sizes are never re-equalized.
# Arrow = where the NEW window lands (left/up = same split, then swap).

from kittens.tui.handler import result_handler


def main(args: list[str]) -> None:
    pass


def _guillotine(ids, rects):
    # Recover a binary split tree reproducing the captured rectangles.
    # Returns a nested (axis, fraction, one, two) tuple with group-id leaves,
    # or None when the rectangles do not tile (overlap / non-guillotine).
    if len(ids) == 1:
        return ids[0]
    left = min(rects[i][0] for i in ids)
    top = min(rects[i][1] for i in ids)
    right = max(rects[i][2] for i in ids)
    bottom = max(rects[i][3] for i in ids)
    for x in sorted({rects[i][2] for i in ids}):
        if x >= right:
            continue
        one = [i for i in ids if rects[i][2] <= x]
        two = [i for i in ids if rects[i][0] > x]
        if one and two and len(one) + len(two) == len(ids):
            a, b = _guillotine(one, rects), _guillotine(two, rects)
            if a is not None and b is not None:
                return ('h', (x - left) / (right - left), a, b)
    for y in sorted({rects[i][3] for i in ids}):
        if y >= bottom:
            continue
        one = [i for i in ids if rects[i][3] <= y]
        two = [i for i in ids if rects[i][1] > y]
        if one and two and len(one) + len(two) == len(ids):
            a, b = _guillotine(one, rects), _guillotine(two, rects)
            if a is not None and b is not None:
                return ('v', (y - top) / (bottom - top), a, b)
    return None


def _rebuild(tab, tree):
    # Impose the recovered tree on the freshly converted splits layout.
    from kitty.layout.splits import Pair

    def build(node, parent):
        if not isinstance(node, tuple):
            return node
        axis, frac, one, two = node
        p = Pair(horizontal=(axis == 'h'))
        # bias is clamped the same way kitty clamps interactive resizes, so a
        # sliver window cannot collapse a branch to zero.
        p.bias = min(0.9, max(0.1, frac))
        p.one = build(one, p)
        p.two = build(two, p)
        try:
            p.parent = parent
        except AttributeError:
            pass
        return p

    root = build(tree, None)
    if not isinstance(root, Pair):
        return False
    layout = tab.current_layout
    expect = {g.id for g in tab.windows.iter_all_layoutable_groups()}
    if set(root.all_window_ids()) != expect:
        return False
    layout.pairs_root = root
    return True


@result_handler(no_ui=True)
def handle_result(args: list[str], answer: str, target_window_id: int, boss) -> None:
    direction = args[1] if len(args) > 1 else 'right'
    if direction not in ('left', 'right', 'up', 'down'):
        return
    tab = boss.active_tab
    if tab is None:
        return
    if tab.current_layout.name != 'splits':
        groups = list(tab.windows.iter_all_layoutable_groups())
        rects = {}
        for g in groups:
            geo = g.geometry
            rects[g.id] = (geo.left, geo.top, geo.right, geo.bottom)
        tree = _guillotine(list(rects), rects) if len(rects) > 1 else None
        tab.goto_layout('splits')
        rebuilt = tree is not None and _rebuild(tab, tree)
        if not rebuilt and len(rects) > 1:
            tab.layout_action('equalize', ())
        tab.relayout()
    from kitty.launch import launch, parse_launch_args
    loc = 'vsplit' if direction in ('left', 'right') else 'hsplit'
    spec = parse_launch_args(['--location=' + loc, '--bias=50', '--cwd=current'])
    launch(boss, spec.opts, spec.args)
    if direction in ('left', 'up'):
        tab.move_window(direction)
