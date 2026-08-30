# scripts

Standalone tools that live in the dotfiles and are symlinked onto `PATH`.
This is the detailed reference — the repo root README deliberately stays short.

---

## `theme` — wallpaper + terminal palette CLI

`theme.sh` is symlinked to `~/.local/bin/theme`, so `theme` works everywhere.

One command owns two things that should always agree:

- the **desktop wallpaper** (via the `wallpaper` brew formula on macOS), and
- the **terminal palette**, either derived from that wallpaper with
  [pywal](https://github.com/dylanaraps/pywal) or pinned to a static kitty theme.

It can also *fetch* new wallpapers — from Unsplash or from any image URL or
Pinterest pin — save them into the wallpaper library with a readable filename,
and apply them in one step.

### Quick reference

```sh
theme                    # usage
theme help               # same
theme wal                # random local wallpaper -> desktop + pywal colors
theme wal <image>        # specific local image  -> desktop + pywal colors
theme random             # explicit name for `theme wal` with no argument
theme set <image>        # explicit name for `theme wal <image>`
theme static             # static kitty theme (default: catppuccin-mocha)
theme static <name>      # any file in ~/.config/kitty/themes/<name>.conf
theme unsplash           # random high-res Unsplash photo -> save + apply
theme unsplash <query>   # ...matching a search term
theme unsplash <photo-url>   # ...exactly that unsplash.com/photos/… page
theme unsplash status    # API window: requests left this hour, tier, key
theme url <link>         # direct image URL or Pinterest pin -> save + apply
theme … --rotate left|right   # any image command: turn 90° before applying
theme … --extend[=RRGGBB]     # pad flat-background art to screen shape (default 000000)
theme list [-v]          # wallpaper table, latest added first: title + source
                         #   (-v adds format, size, date added)
theme status             # current theme: mode, color-scheme swatches, variables
theme rename <w> <n…>    # rename a saved wallpaper (slugified, extension kept)
theme rm <w…>            # delete saved wallpapers by name (library only)
```

`wal`, `random` and `set` are the same code path; `random`/`set` exist because
they say out loud what the argument means.

### Examples

```sh
# Palette + desktop from a specific wallpaper. Any of these three work:
theme set nebulosa-red                       # bare name, extension inferred
theme set nebulosa-red.png                   # name with extension
theme set ~/Pictures/screenshot-4k.png       # any path outside the library

# Shuffle
theme random

# Pin the terminal to a fixed scheme, leaving the desktop alone
theme static catppuccin-mocha

# Pull something new from Unsplash (needs a free key, see below)
theme unsplash
theme unsplash "misty forest"
theme unsplash "brutalist architecture"

# Or exactly the photo you are looking at — paste its page link
theme unsplash https://unsplash.com/photos/winged-person-with-halo-in-sky-coy_MhYMLHs

# Any direct image URL
theme url https://upload.wikimedia.org/wikipedia/commons/1/12/Andromeda.jpg

# A Pinterest pin page — the original image behind the pin is resolved for you
theme url https://www.pinterest.com/pin/776730267011073968/
```

What a fetch looks like:

```
$ theme url https://www.pinterest.com/pin/776730267011073968/
theme: saved 8k-and-4k-black-white-abstract-wallpaper-4kwallpaper-for-pc-5k-w.jpg (3840x2160)
theme: now: 8k-and-4k-black-white-abstract-wallpaper-4kwallpaper-for-pc-5k-w.jpg (3840x2160)
```

### Download rules

Every download — Unsplash, direct URL, Pinterest — goes through the same
checks before anything is applied:

1. **Validated as an image by content, not by extension.** The bytes are typed
   with `file --mime-type`; anything that is not `image/*` is refused with the
   MIME type it actually was. A URL that returns HTML gets exactly one chance
   to resolve to a real image via its `og:image` meta tag (this is how
   Pinterest pins work) — after that it is an error.
2. **Named descriptively.** The filename is slugified from the best hint
   available: your search prompt plus the photo's own description (Unsplash),
   the page's `og:title`, or the URL basename — long names cut at a word
   boundary. Bare CDN-hash basenames become `pinterest-<timestamp>`. The
   photographer is credited in the terminal note, never baked into the name.
3. **Never overwrites.** If the target name already exists and the bytes are
   identical, the existing file is reused and nothing is downloaded again. If
   the bytes differ, the new file takes the next free `-2`, `-3`, … suffix. An
   existing file is never modified.
4. **Warns when small.** Anything narrower than 2560px is saved and applied,
   but says so.
5. **Highest rendition wins.** Unsplash downloads use the `raw` URL — the
   untouched original upload — never the `full` q=85 re-compressed jpg;
   Pinterest `/NNNx/` downscales are upgraded to `/originals/` when it exists.

Pinterest specifically: pin pages expose only a `736x`-wide preview in their
`og:image`. `theme` rewrites any `i.pinimg.com/<width>x/...` downscale —
whether it came from a pin page or was pasted directly — to
`i.pinimg.com/originals/...` to get the uploaded original, and falls back to
the given URL if the originals path is not there. Pins whose source upload
was small stay small — that is Pinterest's copy, not a bug here, and the width
warning will tell you.

Portrait pins: add `--rotate left|right` (any position, any image command) to
turn the image 90° before it is saved and applied. Rotating a local-library
image saves the turned copy as its own wallpaper — the original file is never
modified. The desktop is always set in fill mode: crop to cover the screen,
never letterbox bars.

### Unsplash setup (free)

`source.unsplash.com`, the old keyless random-photo endpoint, is dead. The
supported zero-cost path is the official API in **demo mode**: free forever,
no card, rate-limited to **50 requests per hour** — far more than a wallpaper
habit needs.

Getting a key, once:

1. Sign in (or sign up) at <https://unsplash.com>.
2. Go to <https://unsplash.com/oauth/applications> and click
   **New Application**.
3. Accept the API Use and Guidelines checkboxes, then give the app a name and
   a one-line description (e.g. `personal wallpaper CLI`).
4. On the application page, copy the **Access Key** (*not* the Secret Key —
   this tool only makes public read requests).

Storing it — **never in this repository**, which is public. Two supported
places, checked in this order:

```sh
# 1. environment (per-shell, good for a quick try)
export UNSPLASH_ACCESS_KEY='...'

# 2. macOS Keychain (recommended — survives reboots, out of every dotfile)
security add-generic-password -s unsplash-access-key -a "$USER" -w
#   ^ prompts for the key without echoing it; -w with no value reads it interactively
```

With no key anywhere, `theme unsplash` fails with a one-line instruction and
does nothing else. It never silently falls back to another photo service.

Implementation notes worth knowing:

- The key is handed to `curl` through a **stdin config file**, not on the
  command line, so it never appears in `ps` output for other users.
- The command asks for 5 random landscape candidates in a single request and
  keeps the widest one that is at least 3840px; if none reach that, it takes
  the widest available and tells you the size it settled for.
- After a successful download it pings the photo's `download_location`
  endpoint. That is an Unsplash API guideline requirement (it credits the
  photographer's download count) and costs nothing.
- The photographer's name is printed on success (the filename carries your
  prompt and the photo's description instead). If you republish one of these
  images anywhere, attribute them.

### How the kitty include chain works

```
~/.config/kitty/kitty.conf
      └── include current-theme.conf          (gitignored; rewritten by `theme`)
                 └── include ~/.cache/wal/colors-kitty.conf     ← pywal mode
                     or     ~/.config/kitty/themes/<name>.conf  ← static mode
```

`theme` only ever rewrites the one-line `current-theme.conf`, then pushes the
new colors to every running kitty instance over its remote-control socket.
The socket's authority is capability-scoped, not open: `kitty.conf` sets
`allow_remote_control password`, `listen_on unix:/tmp/kitty-samuel`, and
`remote_control_password "" set-colors`, so a passwordless socket client may
call `set-colors` and nothing else — no window reads, no send-text, no
launch. `kitten @ set-colors --all --configured`
recolors existing windows *and* updates the instance's stored config, so
windows opened later inherit the new palette too — no restart, no new window.
A running instance ignores `SIGUSR1` on macOS, so the signal survives only as
a fallback for instances started before the socket config existed; after
pulling this config, quit and reopen kitty once so the instance carries the
socket.

`kitten themes` (built into kitty) writes the same `current-theme.conf`, so the
two coexist; `theme status` will report whatever is currently included.

### Adding static themes

Drop any kitty color `.conf` into `~/.config/kitty/themes/`:

```sh
curl -fsSL https://raw.githubusercontent.com/catppuccin/kitty/main/themes/latte.conf \
  -o ~/.config/kitty/themes/catppuccin-latte.conf
theme static catppuccin-latte
```

It shows up in `theme list` and `theme help` immediately.

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONFIG_DIR` | `~/.config` | Root for everything below |
| `KITTY_CONFIG_DIRECTORY` | `$CONFIG_DIR/kitty` | Where `current-theme.conf` and `themes/` live |
| `WALLPAPER_DIR` | `$CONFIG_DIR/wallpapers/pc` | Wallpaper library; downloads land here |
| `WAL_CACHE` | `~/.cache/wal` | Where pywal writes `colors-kitty.conf` |
| `UNSPLASH_ACCESS_KEY` | *(unset)* | Unsplash key; Keychain is checked if unset |
| `THEME_NO_APPLY` | *(unset)* | Any value = dry run (see below) |

`WAL_CACHE` only tells `theme` where to *point the include*. pywal itself
writes to `$XDG_CACHE_HOME/wal` (i.e. `~/.cache/wal`), so if you move one you
must move both. `theme` refuses to write a dangling include and says so.

### Dry-run / testing

```sh
THEME_NO_APPLY=1 theme random
THEME_NO_APPLY=1 WALLPAPER_DIR=/tmp/wp theme url https://example.org/pic.jpg
```

With `THEME_NO_APPLY` set, every step still runs — resolution, download,
validation, dedupe, naming — but the three steps that touch live state are
skipped and announced instead: setting the desktop image, running pywal, and
rewriting `current-theme.conf`. Combine it with a throwaway `WALLPAPER_DIR` to
test the network paths without adding files to the real library.

### Dependencies

Required:

| Tool | Install | Used for |
| --- | --- | --- |
| `wallpaper` | `brew install wallpaper` | Setting the macOS desktop image |
| `wal` (pywal) | `pipx install pywal` | Deriving the palette from an image |
| `colorz`, `modern_colorthief` | `pipx inject pywal colorz modern_colorthief` | pywal backends — colorz first; modern_colorthief handles near-monochrome art colorz refuses |
| `curl` | preinstalled | All downloads |
| `python3` | preinstalled (or `brew install python`) | Parsing Unsplash JSON and `og:` meta tags |
| `file`, `sed`, `awk`, `find`, `shasum` | preinstalled | Typing, slugifying, dedupe |

Optional: `sips` (macOS, preinstalled) gives exact image dimensions; without it
`file` is used, which is slightly less reliable on exotic formats. `kitty` need
not be running — the reload is best-effort.

### Fresh machine

**macOS**

```sh
brew install wallpaper pipx
pipx install pywal
mkdir -p ~/.local/bin
ln -sf ~/.config/scripts/theme.sh ~/.local/bin/theme
# ensure ~/.local/bin is on PATH (it is, via the shell rc in this repo)
theme list
```

If `theme` is missing after moving the dotfiles, the symlink is what broke —
recreate it with the `ln -sf` line above.

**Ubuntu / the pi (`pie5`)**

The palette half works unchanged; the desktop half depends on the session:

```sh
sudo apt install pipx curl file
pipx install pywal          # or: pip install --user pywal
ln -sf ~/.config/scripts/theme.sh ~/.local/bin/theme
```

`theme` sets the desktop through GNOME (`gsettings`, when
`XDG_CURRENT_DESKTOP` is set) or `feh --bg-fill`, whichever is present. On a
headless box neither is, and `theme` says
`desktop wallpaper not supported here` and continues — the terminal palette
still changes. That fallback is deliberate: there is no Linux desktop test
matrix here, and macOS is the supported target.

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `no Unsplash key: ...` | No `UNSPLASH_ACCESS_KEY` and nothing in the Keychain. See the setup section. |
| `Unsplash request failed (bad key, rate limit, or no network)` | Wrong Access Key (Secret Key won't work), the 50/hour demo limit, or offline. |
| `that URL is text/html, not an image` | The link is a page. If it is a Pinterest pin it should resolve automatically; otherwise open it and copy the direct image URL. |
| `no og:image on that page` | The page exposes no preview image. Pass a direct image URL. |
| `download failed: <url>` | DNS, TLS, 403 or 404. Try the URL in a browser; some hosts block non-browser clients regardless of user agent. |
| `warning: only NNNpx wide` | The source really is that small. It was still saved and applied. |
| `pywal not installed` | `pipx install pywal`, then reopen the shell so `~/.local/bin/wal` is on `PATH`. |
| `pywal wrote no kitty colors in ...` | `WAL_CACHE` and pywal's actual cache disagree. Unset `WAL_CACHE` or point it at `~/.cache/wal`. |
| Colors don't change | The kitty instance predates the socket config — quit and reopen kitty once — or `kitty.conf` no longer has `include current-theme.conf`. `theme status` shows what is included. |
| Desktop doesn't change but colors do | `wallpaper` is not installed (`brew install wallpaper`) or the platform is unsupported. |
| Two files with `-2` suffixes | Two different images wanted the same slug. Both were kept on purpose; delete whichever you don't want. |
