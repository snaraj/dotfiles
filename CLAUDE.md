# Claude instructions for ~/.config

This repo's only working copy is the live config directory every shell, terminal and editor here reads.

- Change tracked configuration only on a branch in a separate worktree (`git worktree add`), delivered as a pull request.
- Never switch, reset, rebase or otherwise move the live working copy's branch or index, and never touch the stash.
- Never delete or modify untracked or gitignored files: they hold machine-local credentials and tool state.
- Never run `git add`, `git commit` or `git push` in the live working copy unless I explicitly ask in that conversation; that is always my call.
