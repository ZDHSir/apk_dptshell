#!/usr/bin/env bash
#
# Regenerate native-image reflection/resource/JCA metadata by running libs/dpt/dpt.jar
# under the native-image tracing agent. Run this whenever libs/dpt/ changes.
#
# Usage: scripts/trace-config.sh <app.apk>
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APK="${1:-}"
if [[ -z "$APK" || ! -f "$APK" ]]; then
  echo "usage: $0 <app.apk>" >&2
  exit 1
fi

GRAALVM_HOME="${GRAALVM_HOME:-${JAVA_HOME:-}}"
if [[ -z "$GRAALVM_HOME" || ! -x "$GRAALVM_HOME/bin/java" ]]; then
  for candidate in "$ROOT"/.toolchain/graalvm*/ "$HOME/.sdkman/candidates/java/21.0.2-graalce" "$HOME/.sdkman/candidates/java/current"; do
    candidate="${candidate%/}"
    if [[ -x "$candidate/bin/java" ]]; then
      GRAALVM_HOME="$candidate"
      break
    fi
  done
fi
[[ -x "$GRAALVM_HOME/bin/java" ]] || { echo "error: GraalVM java not found" >&2; exit 1; }

CONFIG="$ROOT/native/config"
TMP="$ROOT/build/trace"
CONFIG_REL="native/config"
TMP_REL="build/trace"
rm -rf "$CONFIG" "$TMP"
mkdir -p "$CONFIG" "$TMP"

KEYSTORE_REL="$TMP_REL/trace.jks"
"$GRAALVM_HOME/bin/keytool" -genkeypair -keystore "$KEYSTORE_REL" -storepass tracepass \
  -keypass tracepass -alias trace -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=goshell trace" >/dev/null 2>&1

# JSON passed to Java must not contain a Git-Bash /c/... path on Windows.
KEYSTORE_FOR_JAVA="$ROOT/$KEYSTORE_REL"
if command -v cygpath >/dev/null 2>&1; then
  KEYSTORE_FOR_JAVA="$(cygpath -m "$KEYSTORE_FOR_JAVA")"
fi

cat > "$TMP/trace-config.json" <<JSON
{
  "shellPkgName": "<random>",
  "signature": {
    "keystore": "$KEYSTORE_FOR_JAVA",
    "alias": "trace",
    "storepass": "tracepass",
    "keypass": "tracepass"
  }
}
JSON

run_trace() {
  local output="$1"
  shift
  mkdir -p "$output"
  "$GRAALVM_HOME/bin/java" \
    -agentlib:native-image-agent=config-merge-dir="$CONFIG_REL" \
    -jar libs/dpt/dpt.jar "$@" >/dev/null 2>&1
  rm -rf "$output"
}

echo "Tracing default keystore path..."
run_trace "$TMP_REL/out-default" -f "$APK" -o "$TMP_REL/out-default"

echo "Tracing custom keystore + verify-sign path..."
run_trace "$TMP_REL/out-custom" -f "$APK" -o "$TMP_REL/out-custom" -c "$TMP_REL/trace-config.json" -vs

echo "Wrote native-image metadata to $CONFIG"
ls -1 "$CONFIG"
