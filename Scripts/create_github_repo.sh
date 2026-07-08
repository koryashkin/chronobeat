#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="watch-accuracy-meter-ios"
VISIBILITY="--private"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required. Install from https://cli.github.com/"
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init
fi

git add .
git commit -m "Initial iOS watch accuracy meter MVP" || true

gh repo create "koryashkin/${REPO_NAME}" ${VISIBILITY} --source . --remote origin --push

echo "Created and pushed: https://github.com/koryashkin/${REPO_NAME}"
