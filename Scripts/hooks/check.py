#!/usr/bin/env python3
"""Check whitespace, conflict markers, and Swift formatting without modifying files."""
import subprocess
import sys
import tempfile


def git(*args):
    """Read Git objects, retaining filenames and blob bytes exactly."""
    return subprocess.check_output(['git', *args])


def check(base=None):
    """Inspect the index locally, or the committed CI diff against its base."""
    diff = [base, 'HEAD'] if base else ['--cached']
    subprocess.run(['git', 'diff', '--check', *diff], check=True)
    paths = git('diff', '--name-only', '-z', '--diff-filter=ACMR', *diff).split(b'\0')
    prefix = 'HEAD:' if base else ':'
    swift = [raw.decode('utf-8', errors='surrogateescape') for raw in paths if raw.endswith(b'.swift')]
    if not swift:
        return 0
    failed = False
    # Lint the staged or committed bytes with the configuration from the same place, not the worktree's.
    with tempfile.NamedTemporaryFile(suffix='.swift-format') as configuration:
        configuration.write(git('show', prefix + '.swift-format'))
        configuration.flush()
        for path in swift:
            print(f'Checking staged Swift: {path}' if not base else f'Checking Swift: {path}', flush=True)
            result = subprocess.run(['swift', 'format', 'lint', '--strict', '--configuration', configuration.name,
                                     '--assume-filename', path, '-'], input=git('show', prefix + path))
            failed = failed or result.returncode != 0
    if failed:
        print('Run ./x fmt, review the changes, and stage them again.', file=sys.stderr)
    return int(failed)


if __name__ == '__main__':
    if len(sys.argv) > 2:
        sys.exit('usage: check.py [base-commit]')
    try:
        sys.exit(check(sys.argv[1] if len(sys.argv) == 2 else None))
    except (subprocess.CalledProcessError, RuntimeError, FileNotFoundError) as error:
        sys.exit(str(error))
