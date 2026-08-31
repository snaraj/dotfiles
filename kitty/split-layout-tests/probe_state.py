# Lab-only state probe: dumps everything the campaign needs in one RC round-trip.
import json
import traceback

from kittens.tui.handler import result_handler


def main(args):
    pass


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    out = args[1]
    info = {}
    try:
        tab = boss.active_tab or next(iter(boss.all_tabs), None)
        if tab is None:
            info['error'] = 'no-tab'
        else:
            layout = tab.current_layout
            info['layout'] = layout.name

            def enc(p):
                if p is None:
                    return None
                if isinstance(p, int):
                    return p
                return {'h': bool(getattr(p, 'horizontal', False)),
                        'bias': getattr(p, 'bias', None),
                        'one': enc(getattr(p, 'one', None)),
                        'two': enc(getattr(p, 'two', None))}

            info['pairs_root'] = enc(getattr(layout, 'pairs_root', None))
            wins = {}
            for w in tab.windows:
                g = w.geometry
                wins[str(w.id)] = [g.left, g.top, g.right, g.bottom]
            info['windows'] = wins
            groups = {}
            for g in tab.windows.iter_all_layoutable_groups():
                geo = g.geometry
                groups[str(g.id)] = {
                    'windows': [getattr(w, 'id', w) for w in getattr(g, 'windows', ())],
                    'rect': [geo.left, geo.top, geo.right, geo.bottom] if geo else None,
                }
            info['groups'] = groups
            aw = tab.active_window
            info['focused'] = aw.id if aw is not None else None
            info['n'] = len(wins)
            info['os_windows'] = len(list(boss.os_window_map))
            # exercise the code paths that a shadowed Pair.parent would break
            try:
                if aw is not None:
                    layout.neighbors_for_window(aw, tab.windows)
                info['neighbors_ok'] = True
            except Exception as e:
                info['neighbors_ok'] = False
                info['neighbors_err'] = repr(e)
    except Exception:
        info['exc'] = traceback.format_exc()
    with open(out, 'w') as f:
        json.dump(info, f)
