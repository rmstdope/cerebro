#!/usr/bin/env bash
# Point the consumer repository's hooks at this directory.
#
# Run once per clone, from anywhere inside the consumer repo:
#   .claude/cerebro/githooks/install.sh
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Not inside a git repository" >&2
  exit 1
fi

# core.hooksPath is repository-wide: it replaces .git/hooks entirely rather than
# adding to it. Say so rather than silently disabling hooks somebody relies on.
EXISTING="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"
HOOKS_PATH="${HOOK_DIR#"$REPO_ROOT"/}"

if [[ -n "$EXISTING" && "$EXISTING" != "$HOOKS_PATH" ]]; then
  echo "core.hooksPath is already set to '$EXISTING'." >&2
  echo "Setting it to '$HOOKS_PATH' would disable those hooks. Merge them by hand instead." >&2
  exit 1
fi

if [[ -d "$REPO_ROOT/.git/hooks" ]] \
  && compgen -G "$REPO_ROOT/.git/hooks/*" >/dev/null 2>&1 \
  && ! compgen -G "$REPO_ROOT/.git/hooks/*.sample" >/dev/null 2>&1; then
  echo "Note: .git/hooks contains hooks that will stop running once core.hooksPath is set."
fi

git -C "$REPO_ROOT" config core.hooksPath "$HOOKS_PATH"
echo "core.hooksPath = $HOOKS_PATH"
echo "post-merge and post-checkout will now sync symlinks when .claude/cerebro moves."
