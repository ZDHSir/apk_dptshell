#!/usr/bin/env bash
#
# Build and package goshell for the current OS/architecture.
# Output: dist/goshell-<os>-<arch>.tar.gz (+ .sha256)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

case "$(uname -s)" in
  Linux*) OS=linux ;;
  Darwin*) OS=macos ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *)
    echo "error: unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) ARCH=x64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

NAME="goshell-${OS}-${ARCH}"
STAGE="build/pkg/$NAME"

scripts/build-native.sh

rm -rf "$STAGE"
mkdir -p "$STAGE" dist

if [[ -f build/native/goshell ]]; then
  cp build/native/goshell "$STAGE/goshell"
else
  cp build/native/goshell.exe "$STAGE/goshell.exe"
fi
cp libs/dpt/dpt-exclude-classes-template.rules \
   libs/dpt/dpt-protect-config-template.json \
   README.md "$STAGE/"

tar -czf "dist/$NAME.tar.gz" -C build/pkg "$NAME"

if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum "$NAME.tar.gz" > "$NAME.sha256")
else
  (cd dist && shasum -a 256 "$NAME.tar.gz" > "$NAME.sha256")
fi

echo
echo "Packaged: dist/$NAME.tar.gz"
ls -lh "dist/$NAME.tar.gz" "dist/$NAME.sha256"
