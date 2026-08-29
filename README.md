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

**`starship/`** — prompt config (`STARSHIP_CONFIG` points here)

**`nvim/`** — `init.lua` + `lsp/`

**`git/`**
- `config` — identity (public noreply), nvim editor, gh credential helper
- signing stays per-command by design; no keys here

**`wallpapers/` + `wal/` + `scripts/`**
- wallpaper library, pywal templates, and the `theme` CLI (wallpaper +
  matching terminal colors, Unsplash/Pinterest fetch) — full docs in
  [`scripts/README.md`](scripts/README.md)

## Install — fresh macOS

```sh
git clone https://github.com/snaraj/dotfiles.git ~/.config
cp ~/.config/zsh/zshenv ~/.zshenv
brew install kitty starship neovim eza kubernetes-cli helm wallpaper pipx
pipx install pywal
mkdir -p ~/.config/zsh/plugins && cd ~/.config/zsh/plugins
git clone https://github.com/zsh-users/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-history-substring-search
mkdir -p ~/.local/bin && ln -s ~/.config/scripts/theme.sh ~/.local/bin/theme
exec zsh
```

Single item instead: take just its folder plus the matching lines of
`zsh/variables.zsh`.

## Install — Ubuntu (e.g. matching the setup on the pie)

Same clone + zshenv + plugins as above, then:

```sh
sudo apt install zsh kitty neovim eza curl python3-pip pipx
curl -sS https://starship.rs/install.sh | sh
pipx install pywal
chsh -s "$(which zsh)"
```

Skip `brew`'s env lines in `~/.zshenv` (guard: they no-op if `/opt/homebrew`
is absent — or delete them). `wallpaper` is macOS-only; `theme` falls back
gracefully.
