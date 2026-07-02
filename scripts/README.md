# scripts

## theme — kitty color switcher

`theme.sh` is symlinked to `~/.local/bin/theme`, so it's available everywhere.
It controls which colors kitty uses by rewriting `kitty/current-theme.conf`
(gitignored, included by `kitty/kitty.conf`) and reloading kitty live.

### Usage

```sh
theme                 # show usage, available themes, and the current mode
theme wal             # random wallpaper from wallpapers/pc + pywal colors
theme wal <image>     # specific image: sets desktop wallpaper + pywal colors
theme static          # fixed theme, defaults to catppuccin-mocha
theme static <name>   # any theme file from kitty/themes/<name>.conf
```

### How it works

- **pywal mode** picks/uses an image, sets the desktop wallpaper (via the
  `wallpaper` brew formula), runs `wal` (installed with pipx, Python 3.14),
  and points `current-theme.conf` at `~/.cache/wal/colors-kitty.conf`.
- **static mode** points `current-theme.conf` at a file in `kitty/themes/`.
- Both send SIGUSR1 to kitty, which reloads its config in place — no restart
  needed.

### Adding static themes

Drop any kitty color `.conf` into `kitty/themes/`, e.g.:

```sh
curl -fsSL https://raw.githubusercontent.com/catppuccin/kitty/main/themes/latte.conf \
  -o ~/.config/kitty/themes/catppuccin-latte.conf
theme static catppuccin-latte
```

You can also browse themes interactively with `kitten themes` (built into
kitty), which writes its own `current-theme.conf` in the same location.
