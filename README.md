# dotfiles

Clone as `~/.config` (XDG root). Everything else in here is machine-local and
gitignored.

## What's here

**`zsh/`**
- `.zshrc` — plugins, cached completions (kubectl/helm), starship, history search
- `aliases.zsh` — kubectl (`k`, `kgp`, `kdp`, `kn`), eza `ls`, nvim, kitten ssh
- `variables.zsh` — env vars (paths for starship, wallpapers, kitty, scripts)
- `zshenv` — copy to `~/.zshenv` (sets ZDOTDIR + brew env; the entry point)

**`kitty/`**
- `kitty.conf` + font/cursor/layout fragments; paste-guard enabled
- colors come from `current-theme.conf`, managed by the `theme` CLI
- `split_dir.py` — directional-split kitten that rebuilds the splits tree
  instead of equalizing it

**`starship/`** — prompt config (`STARSHIP_CONFIG` points here)

**`nvim/`** — `init.lua` + `lsp/`

**`git/`**
- `config` — identity (public noreply), nvim editor, gh credential helper
- signing stays per-command by design; no keys here

**`wallpapers/` + `theme/`**
- wallpaper library and the `theme` CLI (wallpaper + matching terminal
  colors, Unsplash/Pinterest fetch) — full docs in
  [`theme/README.md`](theme/README.md). `theme/` is self-contained,
  ready to split into its own repository.

## Tests

Each suite lives beside what it tests and runs straight from a checkout.

| Suite | Run | Covers |
| --- | --- | --- |
| [`theme/theme-boundary-tests.sh`](theme/theme-boundary-tests.sh) | `bash theme/theme-boundary-tests.sh` | the `theme` CLI's destructive-command, network, credential and save-path boundaries |
| [`zsh/completion-security-tests.zsh`](zsh/completion-security-tests.zsh) | `zsh zsh/completion-security-tests.zsh` | the `compinit` permission audit and its dump handling |
| [`kitty/split-layout-tests/`](kitty/split-layout-tests/) | `python3 kitty/split-layout-tests/campaign.py --smoke` | window geometry across split / close / layout-cycle sequences, driven through a private kitty |
| [`kitty/text-integrity-tests.sh`](kitty/text-integrity-tests.sh) | `zsh kitty/text-integrity-tests.sh` | typing, wrapping, unicode and the paste guard, asserted against the real screen buffer |

The two kitty suites launch their own minimized kitty on a private socket and
close it again; they never touch the terminal you are sitting in.

## Install — fresh macOS

```sh
git clone https://github.com/snaraj/dotfiles.git ~/.config
cp ~/.config/zsh/zshenv ~/.zshenv
brew install kitty starship neovim eza kubernetes-cli helm wallpaper pipx imagemagick
pipx install pywal
mkdir -p ~/.config/zsh/plugins && cd ~/.config/zsh/plugins
git clone https://github.com/zsh-users/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-history-substring-search
mkdir -p ~/.local/bin && ln -s ~/.config/theme/theme.sh ~/.local/bin/theme
exec zsh
```

Single item instead: take just its folder plus the matching lines of
`zsh/variables.zsh`.

## Install — Ubuntu (e.g. matching the setup on the pie)

Same clone + zshenv + plugins as above, then:

```sh
sudo apt install zsh kitty neovim eza curl python3-pip pipx imagemagick
curl -sS https://starship.rs/install.sh | sh
pipx install pywal
chsh -s "$(which zsh)"
```

Skip `brew`'s env lines in `~/.zshenv` (guard: they no-op if `/opt/homebrew`
is absent — or delete them). `wallpaper` is macOS-only; `theme` falls back
gracefully.
