#!/usr/bin/env bash
#
# Package goshell for all supported platforms.
#
# native-image cannot cross-compile, so the only real "all platforms" path is the
# GitHub Actions matrix. This script pushes the current branch, triggers the
# workflow, waits for it, and downloads the packaged artifacts into dist/.
#
# Usage:
#   scripts/package-all.sh            # build all platforms via GitHub Actions
#   scripts/package-all.sh --local    # build/package only the current platform
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--local" ]]; then
  exec "$ROOT/scripts/package-local.sh"
fi

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || {
  echo "error: GitHub CLI (gh) is required for all-platform builds." >&2
  echo "       install: https://cli.github.com/  then run: gh auth login" >&2
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: not inside a git repository" >&2
  exit 1
}

REMOTE="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$REMOTE" ]]; then
  echo "error: no 'origin' remote configured." >&2
  echo "       git remote add origin git@github.com:<you>/<repo>.git" >&2
  echo "       git push -u origin main" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree has uncommitted changes." >&2
  echo "       CI builds the pushed commit, so commit and push first." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || {
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
}

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
  echo "error: detached HEAD; check out a branch first." >&2
  exit 1
fi

echo "Pushing $BRANCH to origin..."
git push origin "$BRANCH"

echo "Triggering workflow build-native on $BRANCH..."
gh workflow run release.yml --ref "$BRANCH"

RUN_ID=""
for _ in $(seq 1 15); do
  RUN_ID="$(gh run list --workflow=release.yml --branch "$BRANCH" --limit 1 \
    --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]] && break
  RUN_ID=""
  sleep 3
done
if [[ -z "$RUN_ID" ]]; then
  echo "error: could not find the triggered workflow run." >&2
  echo "       open the Actions tab and start 'build-native' manually." >&2
  exit 1
fi

echo "Watching run $RUN_ID (this builds four platforms)..."
gh run watch "$RUN_ID" --exit-status

echo "Downloading artifacts..."
rm -rf dist/_ci
mkdir -p dist/_ci dist
gh run download "$RUN_ID" -D dist/_ci

while IFS= read -r file; do
  mv -f "$file" dist/
done < <(find dist/_ci -type f \( -name '*.tar.gz' -o -name '*.sha256' \))
rm -rf dist/_ci

echo
echo "Packaged:"
ls -lh dist/goshell-*.tar.gz dist/goshell-*.sha256 2>/dev/null || true
