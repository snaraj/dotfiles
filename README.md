# dotfiles

Clone as `~/.config` (XDG root). Everything else in here is machine-local and
gitignored.

## What's here

**`zsh/`**
- `.zshrc` — plugins, cached completions (kubectl/helm), starship, history search
- `aliases.zsh` — kubectl (`k`, `kgp`, `kdp`, `kn`), eza `ls`, nvim, kitten ssh
- `variables.zsh` — env vars (paths for starship, wallpapers, kitty, scripts);
  history lives in `~/.local/state/zsh/history` (moved there once from
  `zsh/.zsh_history`)
- `local.zsh` — yours, gitignored: machine-only values such as
  `FIREFOX_PROFILE=<profile dir name>`
- `zshenv` — copy to `~/.zshenv` (sets ZDOTDIR + brew env; the entry point)

**`kitty/`**
- `kitty.conf` + font/cursor/layout fragments; paste-guard enabled
- colors come from `current-theme.conf`, managed by the `theme` CLI
- `kitty-font.conf` currently selects MonoLisaCode Trial at 16 pt. Install your
  own copy of that font before launching Kitty, or select an installed font in
  that file and adjust its `modify_font` values. Font files are not in this repo.
- `split_dir.py` — directional-split kitten that rebuilds the splits tree
  instead of equalizing it

**`starship/`** — prompt config (`STARSHIP_CONFIG` points here)

**`nvim/`** — `init.lua` + `lsp/`

**`git/`**
- `config` — identity (public noreply), nvim editor, gh credential helper
- signing stays per-command by design; no keys here

**`wallpapers/`**
- the wallpaper library (content, untracked — only the folder convention
  lives in git). Managed by the `theme` CLI, which ships as a release
  binary from [snaraj/theme](https://github.com/snaraj/theme).

## Tests

Each suite lives beside what it tests and runs straight from a checkout.

| Suite | Run | Covers |
| --- | --- | --- |
| [`zsh/completion-security-tests.zsh`](zsh/completion-security-tests.zsh) | `zsh zsh/completion-security-tests.zsh` | the `compinit` permission audit and its dump handling |
| [`zsh/variables-tests.zsh`](zsh/variables-tests.zsh) | `zsh zsh/variables-tests.zsh` | the history file's location, one-time move and fallback, leading-space commands kept out of history, and `local.zsh` — all in a throwaway `HOME` |
| [`kitty/split-layout-tests/`](kitty/split-layout-tests/) | `python3 kitty/split-layout-tests/campaign.py --smoke` | window geometry across split / close / layout-cycle sequences, driven through a private kitty |
| [`kitty/text-integrity-tests.sh`](kitty/text-integrity-tests.sh) | `zsh kitty/text-integrity-tests.sh` | typing, wrapping, unicode and the paste guard, asserted against the real screen buffer |

The two kitty suites launch their own minimized kitty on a private socket and
close it again; they never touch the terminal you are sitting in.

## Install — fresh macOS

```sh
git clone https://github.com/snaraj/dotfiles.git ~/.config
cp ~/.config/zsh/zshenv ~/.zshenv
brew install kitty starship neovim eza kubernetes-cli helm wallpaper
mkdir -p ~/.config/zsh/plugins && cd ~/.config/zsh/plugins
# every shell sources these: pinned to exact commits (upstream HEAD on
# 2026-11-10), so an upstream change arrives only when you bump the SHA
git clone https://github.com/zsh-users/zsh-autosuggestions && git -C zsh-autosuggestions checkout 85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5
git clone https://github.com/zsh-users/zsh-syntax-highlighting && git -C zsh-syntax-highlighting checkout e6683f20e5c38d3e5447f45845d04ddda75d0f23
git clone https://github.com/zsh-users/zsh-history-substring-search && git -C zsh-history-substring-search checkout a0bdb0d47dbaba31dba2db7af8c48a5d9c74049a
# theme CLI: prebuilt binary — https://github.com/snaraj/theme#install
exec zsh
```

Single item instead: take just its folder plus the matching lines of
`zsh/variables.zsh`.

## Install — Ubuntu

Same clone + zshenv + plugins as above, then:

```sh
sudo apt install zsh kitty neovim eza curl
sudo apt install starship    # Ubuntu 25.04+ packages it
chsh -s "$(which zsh)"
```

Older Ubuntu has no starship package. Install the release binary instead,
checked against the SHA-256 that starship publishes beside each archive
(`<archive>.sha256`, v1.27.0) before anything from it runs:

```sh
case $(uname -m) in
  aarch64) sum=341f5cbf24699fa0b27ec88965ad25f862ea09e15d35a543fd6ffdff1d2aa00d ;;
  x86_64)  sum=10c8eb4cb3b761d9bf59ea828444c2dab36c900b7d69a69e08814b286969df89 ;;
esac
f=starship-$(uname -m)-unknown-linux-musl.tar.gz
cd "$(mktemp -d)" && curl -fsSLO "https://github.com/starship/starship/releases/download/v1.27.0/$f" &&
  echo "$sum  $f" | sha256sum -c - && tar -xzf "$f" starship && install -Dm755 starship ~/.local/bin/starship
```

The `theme` CLI installs the same way as on macOS (Linux binaries on the
[releases page](https://github.com/snaraj/theme/releases)).

Skip `brew`'s env lines in `~/.zshenv` (guard: they no-op if `/opt/homebrew`
is absent — or delete them). `wallpaper` is macOS-only; `theme` falls back
gracefully.
