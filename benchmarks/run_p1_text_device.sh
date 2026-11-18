#!/bin/sh
# Copy the verified Qwen file onto the phone and run the text-page device test.
# Prints DEVICE_ABSENT when adb has no device. Does not claim airplane mode.
set -u
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/results"
DEV="${ANDROID_SERIAL:-89ed17e8}"
WEIGHT="$ROOT/models/weights/Qwen3-1.7B-Q4_K_M.gguf"
REMOTE_SRC=/data/local/tmp/ta/Qwen3-1.7B-Q4_K_M.gguf
STAGED=/sdcard/Android/data/dev.local.gptanywhere/files/qwen3-1.7b-q4-k-m.gguf
EXPECT=1282439264
mkdir -p "$OUT"

if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
  echo "DEVICE_ABSENT $DEV" | tee "$OUT/p1-text-status.txt"
  exit 1
fi

remote_size=$(adb -s "$DEV" shell "wc -c < $REMOTE_SRC" 2>/dev/null | tr -d '[:space:]' || true)
if [ "$remote_size" != "$EXPECT" ]; then
  if [ ! -f "$WEIGHT" ]; then
    echo "MISSING_WEIGHT" | tee "$OUT/p1-text-status.txt"
    exit 1
  fi
  adb -s "$DEV" shell "mkdir -p /data/local/tmp/ta"
  adb -s "$DEV" push "$WEIGHT" "$REMOTE_SRC"
fi

adb -s "$DEV" shell "mkdir -p /sdcard/Android/data/dev.local.gptanywhere/files"
adb -s "$DEV" shell "cp $REMOTE_SRC $STAGED"
staged_size=$(adb -s "$DEV" shell "wc -c < $STAGED" | tr -d '[:space:]')
if [ "$staged_size" != "$EXPECT" ]; then
  echo "STAGE_FAILED $staged_size" | tee "$OUT/p1-text-status.txt"
  exit 1
fi

echo "STAGED $staged_size" | tee "$OUT/p1-text-status.txt"
export PATH="/Users/user/git/flutter/bin:${JAVA_HOME:-/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home}/bin:${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools:$PATH"
cd "$ROOT"
flutter test integration_test/p1_text_device_test.dart -d "$DEV" --plain-name "both ways" --reporter expanded \
  > "$OUT/p1-text-device.txt" 2>&1
code=$?
echo "TEST_EXIT $code" | tee -a "$OUT/p1-text-status.txt"
exit "$code"
