#!/usr/bin/env bash
#
# Package goshell for all supported platforms.
#
# native-image cannot cross-compile, so the only real "all platforms" path is the
# GitHub Actions matrix. This script pushes the current branch, triggers the
# workflow, waits for it, and downloads the packaged artifacts into dist/.
#
# Usage:
#   scripts/package-all.sh                # build all platforms (Actions artifacts)
#   scripts/package-all.sh --release v2.21.0
#                                         # build and publish a GitHub Release
#   scripts/package-all.sh --local        # build/package only the current platform
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=build
TAG=""
case "${1:-}" in
  "")
    ;;
  --local)
    exec "$ROOT/scripts/package-local.sh"
    ;;
  --release)
    MODE=release
    TAG="${2:-}"
    if [[ -z "$TAG" ]]; then
      echo "usage: $0 --release <tag>   e.g. $0 --release v2.21.0" >&2
      exit 1
    fi
    ;;
  *)
    echo "unknown option: $1" >&2
    echo "usage: $0 [--release <tag> | --local]" >&2
    exit 1
    ;;
esac

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

find_run() {
  local ref="$1" attempts="$2" run_id="" i
  for ((i = 0; i < attempts; i++)); do
    run_id="$(gh run list --workflow=release.yml --branch "$ref" --limit 1 \
      --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
      # Tag pushes are not always matched by --branch on older gh versions.
      run_id="$(gh run list --workflow=release.yml --limit 10 \
        --json databaseId,headBranch \
        --jq ".[] | select(.headBranch==\"$ref\") | .databaseId" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$run_id" && "$run_id" != "null" ]]; then
      echo "$run_id"
      return 0
    fi
    sleep 3
  done
  return 1
}

if [[ "$MODE" == "release" ]]; then
  if ! [[ "$TAG" =~ ^v[0-9] ]]; then
    echo "error: release tag should look like v2.21.0 (got: $TAG)" >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists locally." >&2
    exit 1
  fi

  echo "Pushing $BRANCH and creating tag $TAG..."
  git push origin "$BRANCH"
  git tag -a "$TAG" -m "goshell $TAG"
  git push origin "$TAG"

  echo "Waiting for the tag build to register..."
  RUN_ID="$(find_run "$TAG" 20 || true)"
else
  echo "Pushing $BRANCH to origin..."
  git push origin "$BRANCH"

  echo "Triggering workflow build-native on $BRANCH..."
  gh workflow run release.yml --ref "$BRANCH"

  echo "Waiting for the workflow run to register..."
  RUN_ID="$(find_run "$BRANCH" 15 || true)"
fi

if [[ -z "$RUN_ID" ]]; then
  echo "error: could not find the triggered workflow run." >&2
  echo "       open the Actions tab and start 'build-native' manually." >&2
  exit 1
fi

echo "Watching run $RUN_ID (this builds Linux x64 and Windows x64)..."
gh run watch "$RUN_ID" --exit-status

echo "Downloading artifacts..."
rm -rf dist/_ci
mkdir -p dist/_ci dist
gh run download "$RUN_ID" -D dist/_ci

while IFS= read -r file; do
  mv -f "$file" dist/
done < <(find dist/_ci -type f \( -name '*.tar.gz' -o -name '*.sha256' \))
rm -rf dist/_ci

if [[ "$MODE" == "release" ]]; then
  echo
  echo "GitHub Release: $(gh release view "$TAG" --json url --jq .url)"
fi

echo
echo "Packaged:"
ls -lh dist/goshell-*.tar.gz dist/goshell-*.sha256 2>/dev/null || true
