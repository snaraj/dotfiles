# NEGATIVE CONTROL: the pre-v4 naive behaviour (goto_layout then launch).
from kittens.tui.handler import result_handler
def main(args): pass
@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    direction = args[1] if len(args) > 1 else 'right'
    tab = boss.active_tab
    if tab is None: return
    if tab.current_layout.name != 'splits':
        tab.goto_layout('splits')
    from kitty.launch import launch, parse_launch_args
    loc = 'vsplit' if direction in ('left','right') else 'hsplit'
    spec = parse_launch_args(['--location='+loc, '--bias=50', '--cwd=current'])
    launch(boss, spec.opts, spec.args)
    if direction in ('left','up'):
        tab.move_window(direction)
