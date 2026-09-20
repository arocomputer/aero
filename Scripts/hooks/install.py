#!/usr/bin/env python3
"""Enable repository hooks for this worktree while retaining an existing pre-commit hook."""
import os
import subprocess
from pathlib import Path


def git(*args):
    """Read or set Git configuration without invoking a shell."""
    return subprocess.check_output(['git', *args], text=True).strip()


def same(first, second):
    """Whether two paths name one place. Spelling differs on a case-insensitive disk and through links."""
    try:
        return first.samefile(second)
    except OSError:
        return first == second


def install():
    """Do not replace other active hooks; each linked worktree opts into its own checkout."""
    root = Path(git('rev-parse', '--show-toplevel'))
    hooks = root / 'Scripts/hooks'
    configured = subprocess.run(['git', 'config', '--path', '--get', 'core.hooksPath'], capture_output=True, text=True)
    previous = Path(configured.stdout.strip()) if configured.returncode == 0 else Path(git('rev-parse', '--git-path', 'hooks'))
    previous = previous.resolve()
    ours = same(previous, hooks)
    if not ours:
        others = [p.name for p in previous.glob('*') if p.is_file() and os.access(p, os.X_OK)
                  and p.name != 'pre-commit' and not p.name.endswith('.sample')]
        if others:
            raise SystemExit('Existing hooks need manual integration before setup: ' + ', '.join(sorted(others)))
    # Git otherwise shares local configuration across linked worktrees.
    git('config', '--local', 'extensions.worktreeConfig', 'true')
    if not ours:
        hook = previous / 'pre-commit'
        if hook.is_file() and os.access(hook, os.X_OK):
            git('config', '--worktree', 'aero.previousPreCommit', str(hook))
    # A hook that names itself as the one to run first would run itself without end.
    kept = subprocess.run(['git', 'config', '--worktree', '--get', 'aero.previousPreCommit'], capture_output=True, text=True)
    if kept.returncode == 0 and same(Path(kept.stdout.strip()), hooks / 'pre-commit'):
        git('config', '--worktree', '--unset', 'aero.previousPreCommit')
    git('config', '--worktree', 'core.hooksPath', str(hooks))
    print('Repository hooks enabled for this worktree.')


if __name__ == '__main__':
    install()
