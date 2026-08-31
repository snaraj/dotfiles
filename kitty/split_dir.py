# Directional split (cmd+shift+arrows) that never disturbs other windows.
#
# `launch --location=vsplit/hsplit` is honored only by the splits layout.
# When the cmd+shift+l cycle is on another layout, plain keybindings can only
# `goto_layout splits` first — and that conversion rebuilds the tree with
# default biases (three even-looking columns become 50/25/25), deforming
# every window except the one being split. A mapping cannot branch on
# "am I converting?", so this kitten does:
#   * coming from another layout: convert, then EQUALIZE the converted tree
#     so the screen keeps the even distribution it was already showing;
#   * already in splits: split the focused window and touch nothing else —
#     manual sizes are never re-equalized.
# Arrow = where the NEW window lands (left/up = same split, then swap).

from kittens.tui.handler import result_handler


def main(args: list[str]) -> None:
    pass


@result_handler(no_ui=True)
def handle_result(args: list[str], answer: str, target_window_id: int, boss) -> None:
    direction = args[1] if len(args) > 1 else 'right'
    if direction not in ('left', 'right', 'up', 'down'):
        return
    tab = boss.active_tab
    if tab is None:
        return
    if tab.current_layout.name != 'splits':
        tab.goto_layout('splits')
        tab.layout_action('equalize', ())
    from kitty.launch import launch, parse_launch_args
    loc = 'vsplit' if direction in ('left', 'right') else 'hsplit'
    spec = parse_launch_args(['--location=' + loc, '--bias=50', '--cwd=current'])
    launch(boss, spec.opts, spec.args)
    if direction in ('left', 'up'):
        tab.move_window(direction)
