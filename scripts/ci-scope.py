#!/usr/bin/env python3
"""Conservative, fail-closed CI scope. This is a fast-path allowlist, not a risk score."""
import os
from pathlib import Path
import re
import subprocess

MAX_FILES = 5
MAX_LINES = 80
# Literal Swift strings only: interpolation and arbitrary expressions require full CI.
STRING = r'"(?:[^"\\]|\\["\\nrt])*"'
LABEL = re.compile(r'(\b(?:Text\(|Button\(|Image\(systemName:\s*)|'
                   r'\.(?:help|accessibilityLabel|accessibilityHint)\()(' + STRING + ')')
NUMBER = r'-?\d+(?:\.\d+)?'
SPACING = r'(?:' + NUMBER + r'|StudioSpacing\.\w+)'
# No closures, method calls, state, disabled gates or lifecycle modifiers.
STYLE = re.compile(
    r'^\.(?:padding\((?:(?:\.(?:horizontal|vertical|top|bottom|leading|trailing|all)),\s*)?' + SPACING + r'?\)'
    r'|font\(\.(?:caption|caption2|callout|body|headline|subheadline|title|title2|title3|footnote)\)'
    r'|foregroundStyle\(\.(?:primary|secondary|tertiary|red|orange|blue)\)'
    r'|lineLimit\(\d+\)|cornerRadius\(' + NUMBER + r'\)'
    r'|frame\((?:width|height|minWidth|minHeight|maxWidth|maxHeight):\s*' + NUMBER + r'\))$')


def labels_only(line):
    # Replace only the displayed literal, preserving every callback/argument after it.
    return LABEL.sub(lambda m: m[1] + '"<label>"', line)


def lines_safe(added, removed):
    def executable(lines):
        return [line.strip() for line in lines if line.strip() and not STYLE.fullmatch(line.strip())]
    before, after = executable(removed), executable(added)
    if len(before) != len(after):
        return False
    # Unknown executable lines cannot be added, removed or moved. Each remaining
    # pair must change ONLY a displayed literal in the same zero-context hunk.
    return all(old != new and labels_only(old) != old and labels_only(old) == labels_only(new)
               for old, new in zip(before, after))


def classify(changes):
    """changes: (status, path, added lines, removed lines). Unknown means full."""
    if not changes or len(changes) > MAX_FILES:
        return 'full', 'Empty or broad change set'
    if sum(len(a) + len(r) for _, _, a, r in changes) > MAX_LINES:
        return 'full', 'Change exceeds the small-change line budget'
    for status, path, added, removed in changes:
        if status != 'M':
            return 'full', 'Added, deleted, renamed or type-changed files'
        if path.endswith('.md') and (path.startswith('docs/') or path == 'README.md'):
            continue
        if not (path.startswith('RecScribe/RecScribe/UI/') and path.endswith('.swift')):
            return 'full', 'Non-presentation path: ' + path
        if not lines_safe(added, removed):
            return 'full', 'State, behavior or unrecognized UI edit: ' + path
    return 'focused', 'Small allowlisted presentation/documentation diff'


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.PIPE)


def detect(env):
    try:
        if env.get('CI_EVENT') == 'pull_request':
            base = git('merge-base', env['CI_PR_BASE'], env['CI_PR_HEAD']).decode().strip()
        elif env.get('CI_EVENT') == 'push':
            base = env['CI_PUSH_BASE']
        else:
            return 'full', 'Unknown event'
        if not re.fullmatch(r'[0-9a-f]{40}', base) or base == '0' * 40:
            return 'full', 'Missing baseline'
        git('merge-base', '--is-ancestor', base, 'HEAD')
        raw = git('diff', '--no-renames', '--name-status', '-z', base, 'HEAD')
        fields = raw.decode('utf-8').split('\0')
        changes = []
        for i in range(0, len(fields) - 1, 2):
            status, path = fields[i:i+2]
            if status != 'M':
                return 'full', 'File creation/deletion/type change'
            # A mode-only change has no line diff but is not a presentation edit.
            if git('diff', '--summary', base, 'HEAD', '--', path).strip():
                return 'full', 'File mode change'
            patch = git('diff', '--no-ext-diff', '--no-textconv', '--unified=0', base, 'HEAD', '--', path)
            if len(patch) > 1_048_576 or b'Binary files ' in patch:
                return 'full', 'Large or binary patch'
            added, removed = [], []
            hunks = []
            chunk_added, chunk_removed = [], []
            in_hunk = False
            for line in patch.decode('utf-8').splitlines():
                if line.startswith('@@'):
                    if in_hunk:
                        hunks.append((chunk_added, chunk_removed))
                    chunk_added, chunk_removed = [], []
                    in_hunk = True
                elif in_hunk and line.startswith('+'):
                    added.append(line[1:]); chunk_added.append(line[1:])
                elif in_hunk and line.startswith('-'):
                    removed.append(line[1:]); chunk_removed.append(line[1:])
            if in_hunk:
                hunks.append((chunk_added, chunk_removed))
            if path.startswith('RecScribe/RecScribe/UI/') and any(not lines_safe(a, r) for a, r in hunks):
                return 'full', 'Unrecognized or moved UI behavior'
            changes.append((status, path, added, removed))
        return classify(changes)
    except (KeyError, OSError, UnicodeError, ValueError, subprocess.CalledProcessError):
        return 'full', 'Cannot establish a complete diff'


if __name__ == '__main__':
    mode, reason = detect(os.environ)
    print(f'CI scope: {mode} — {reason}')
    if output := os.environ.get('GITHUB_OUTPUT'):
        with Path(output).open('a') as f:
            f.write(f'mode={mode}\n')
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(summary).open('a') as f:
            f.write(f'CI scope: **{mode}**. {reason}\n')
