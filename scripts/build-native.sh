#!/usr/bin/env bash
#
# Build a standalone `goshell` binary with GraalVM native-image.
#
# Requirements:
#   - GraalVM CE/Community for JDK 21 with native-image (GRAALVM_HOME)
#   - libs/dpt/ (dpt.jar + shell-files) and the native/ tree from this repository
#
# Cross-compilation is not supported by native-image; run this on each target OS.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GRAALVM_HOME="${GRAALVM_HOME:-${JAVA_HOME:-}}"
if [[ -z "$GRAALVM_HOME" || ! -x "$GRAALVM_HOME/bin/native-image" ]]; then
  for candidate in "$ROOT"/.toolchain/graalvm*/ "$HOME/.sdkman/candidates/java/21.0.2-graalce" "$HOME/.sdkman/candidates/java/current"; do
    candidate="${candidate%/}"
    if [[ -x "$candidate/bin/native-image" ]]; then
      GRAALVM_HOME="$candidate"
      break
    fi
  done
fi
if [[ -z "$GRAALVM_HOME" || ! -x "$GRAALVM_HOME/bin/native-image" ]]; then
  echo "error: native-image not found. Set GRAALVM_HOME to a GraalVM JDK 21 installation." >&2
  exit 1
fi

JAR="$ROOT/libs/dpt/dpt.jar"
[[ -f "$JAR" ]] || { echo "error: $JAR is missing (see libs/dpt/README.md)" >&2; exit 1; }
[[ -d "$ROOT/libs/dpt/shell-files" ]] || { echo "error: libs/dpt/shell-files/ is missing" >&2; exit 1; }

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) SEP=';' ;;
  *) SEP=':' ;;
esac

BUILD="$ROOT/build/native"
CLASSES="$BUILD/classes"
RES="$BUILD/resources"
rm -rf "$CLASSES" "$RES"
mkdir -p "$CLASSES" "$RES"

# shell-files are read from the filesystem at runtime, so embed them and materialize
# them into a per-user cache on first use.
cp -R "$ROOT/libs/dpt/shell-files" "$RES/shell-files"
(
  cd "$RES"
  find shell-files -type f | LC_ALL=C sort > goshell-files.list
)

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}
# Tie the runtime cache to the exact shell-files payload, so rebuilding the same
# dpt version cannot silently reuse an older extracted copy.
BUILD_ID="$(cd "$RES" && tar cf - shell-files | hash_stdin | cut -c1-12)"
printf '%s\n' "$BUILD_ID" > "$RES/goshell-build-id.txt"

JAVA_BIN="$GRAALVM_HOME/bin/java"
JAR_BIN="$GRAALVM_HOME/bin/jar"
JMOD_BIN="$GRAALVM_HOME/bin/jmod"

# Java tools must receive native-style paths on Windows; the script itself runs with
# POSIX paths under Git Bash, so use relative paths for everything passed to them.
VERSION="$("$JAVA_BIN" -jar libs/dpt/dpt.jar -v 2>/dev/null | tail -1 | tr -d '\r')"
if [[ ! "$VERSION" =~ ^[0-9] ]]; then
  VERSION="2.21.0"
fi
printf '%s\n' "$VERSION" > "$RES/goshell-version.txt"

# The @TargetClass/@Substitute annotations live in different places depending on the
# GraalVM distribution: a jmod in Oracle GraalVM 21.0.12+, svm.jar in GraalVM CE 21.0.2.
ANNOTATIONS="$BUILD/toolchain/annotations"
rm -rf "$ANNOTATIONS"
mkdir -p "$ANNOTATIONS"
ANNOTATIONS_CP=""

archive_has_annotations() {
  local archive="$1"
  if [[ "$archive" == *.jmod && -x "$JMOD_BIN" ]]; then
    "$JMOD_BIN" list "$archive" 2>/dev/null | grep -q 'classes/com/oracle/svm/core/annotate/TargetClass.class'
  elif [[ -x "$JAR_BIN" ]]; then
    "$JAR_BIN" tf "$archive" 2>/dev/null | grep -q 'annotate/TargetClass.class'
  else
    unzip -l "$archive" 2>/dev/null | grep -q 'annotate/TargetClass.class'
  fi
}

# Prefer any jmod (the module layout used by newer distributions) that contains the
# annotations, then fall back to the classic svm.jar layout.
for jmode in "$GRAALVM_HOME"/jmods/*.jmod; do
  [[ -f "$jmode" ]] || continue
  if archive_has_annotations "$jmode"; then
    if [[ -x "$JMOD_BIN" ]]; then
      "$JMOD_BIN" extract --dir "$ANNOTATIONS" "$jmode" >/dev/null 2>&1 || true
    else
      # jmod files carry a 4-byte header and make unzip print a warning; extraction still works.
      unzip -q "$jmode" 'classes/com/oracle/svm/core/annotate/*' -d "$ANNOTATIONS" >/dev/null 2>&1 || true
    fi
    if [[ -f "$ANNOTATIONS/classes/com/oracle/svm/core/annotate/TargetClass.class" ]]; then
      ANNOTATIONS_CP="build/native/toolchain/annotations/classes"
      break
    fi
  fi
done

if [[ -z "$ANNOTATIONS_CP" ]]; then
  while IFS= read -r candidate; do
    if archive_has_annotations "$candidate"; then
      ANNOTATIONS_CP="$candidate"
      if command -v cygpath >/dev/null 2>&1; then
        ANNOTATIONS_CP="$(cygpath -m "$ANNOTATIONS_CP")"
      fi
      break
    fi
  done < <(find "$GRAALVM_HOME" -name 'svm.jar' 2>/dev/null)
fi

if [[ -z "$ANNOTATIONS_CP" ]]; then
  echo "error: cannot find com.oracle.svm.core.annotate.TargetClass under $GRAALVM_HOME" >&2
  exit 1
fi

echo "Compiling native-image substitutions (annotations: $ANNOTATIONS_CP)"
find native/src -name '*.java' > "$BUILD/sources.txt"
"$GRAALVM_HOME/bin/javac" --release 11 -encoding UTF-8 \
  -cp "libs/dpt/dpt.jar$SEP$ANNOTATIONS_CP" \
  -d "build/native/classes" \
  @"build/native/sources.txt"

CONFIG_DIR="$ROOT/native/config"
if [[ ! -d "$CONFIG_DIR" ]] || ! compgen -G "$CONFIG_DIR/*.json" > /dev/null; then
  echo "native/config is empty; generating native-image metadata with the tracing agent..."
  "$ROOT/scripts/trace-config.sh" testapp/fixture.apk
fi

CONFIG_DIRS="native/config"
if [[ -d "native/config-extra" ]]; then
  CONFIG_DIRS="$CONFIG_DIRS,native/config-extra"
fi
CONFIG_ARGS=("-H:ConfigurationFileDirectories=$CONFIG_DIRS")

echo "Building native image..."
"$GRAALVM_HOME/bin/native-image" \
  --no-fallback \
  -Ob \
  --gc=serial \
  -J-Xmx4g \
  -cp "libs/dpt/dpt.jar${SEP}build/native/classes${SEP}build/native/resources" \
  -o "build/native/goshell" \
  -H:+ReportExceptionStackTraces \
  -H:+AddAllCharsets \
  -H:IncludeResources='assets/.*|shell-files/.*|goshell-files\.list|goshell-version\.txt|goshell-build-id\.txt|META-INF/MANIFEST\.MF' \
  --enable-url-protocols=jar,file \
  --initialize-at-run-time=com.luoye.dpt,com.wind.meditor \
  "${CONFIG_ARGS[@]}" \
  com.luoye.dpt.Dpt

echo
if [[ -f "$BUILD/goshell" ]]; then
  echo "Built: $BUILD/goshell"
  ls -lh "$BUILD/goshell"
else
  echo "Built: $BUILD/goshell.exe"
  ls -lh "$BUILD/goshell.exe"
fi
