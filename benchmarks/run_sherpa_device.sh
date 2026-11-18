#!/bin/sh
# Rerun SenseVoice and Chinese TTS on the connected phone.
# Uses the stock-Android build from native/asr/build_sherpa_android.sh.
# Does not push libc++_shared.so and does not run the espeak English voice.
set -u
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/results"
WEIGHTS="$ROOT/models/weights"
SAMPLES="$ROOT/benchmarks/samples"
BIN="$ROOT/third_party/sherpa-onnx/build-android-api24/bin"
DEV="${ANDROID_SERIAL:-89ed17e8}"
REMOTE=/data/local/tmp/ta
mkdir -p "$OUT"

if [ ! -x "$BIN/sherpa-onnx-offline" ] || [ ! -x "$BIN/sherpa-onnx-offline-tts" ]; then
  echo "missing Android sherpa binaries in $BIN" >&2
  exit 1
fi

if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
  echo "DEVICE_ABSENT" | tee "$OUT/device-sherpa-status.txt"
  exit 1
fi

adb -s "$DEV" shell "mkdir -p $REMOTE/sense $REMOTE/tts-zh $REMOTE/samples"
adb -s "$DEV" push "$BIN/sherpa-onnx-offline" "$REMOTE/sherpa-onnx-offline"
adb -s "$DEV" push "$BIN/sherpa-onnx-offline-tts" "$REMOTE/sherpa-onnx-offline-tts"
adb -s "$DEV" shell "chmod 755 $REMOTE/sherpa-onnx-offline $REMOTE/sherpa-onnx-offline-tts"

echo "===== load check ====="
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline" > "$OUT/device-sherpa-load.log" 2>&1 || true
if grep -q "CANNOT LINK EXECUTABLE" "$OUT/device-sherpa-load.log"; then
  echo "LOAD_FAILED" | tee "$OUT/device-sherpa-status.txt"
  exit 1
fi

need_push() {
  remote="$1"
  local_size="$2"
  remote_size=$(adb -s "$DEV" shell "wc -c < $remote" 2>/dev/null | tr -d '[:space:]' || true)
  [ "$remote_size" != "$local_size" ]
}

push_if_needed() {
  local_path="$1"
  remote_path="$2"
  size=$(wc -c < "$local_path" | tr -d ' ')
  if need_push "$remote_path" "$size"; then
    echo "push $remote_path"
    adb -s "$DEV" push "$local_path" "$remote_path"
  else
    echo "keep $remote_path"
  fi
}

push_if_needed "$WEIGHTS/sense-voice/model.onnx" "$REMOTE/sense/model.onnx"
push_if_needed "$WEIGHTS/sense-voice/tokens.txt" "$REMOTE/sense/tokens.txt"
push_if_needed "$WEIGHTS/tts-zh/model.onnx" "$REMOTE/tts-zh/model.onnx"
push_if_needed "$WEIGHTS/tts-zh/lexicon.txt" "$REMOTE/tts-zh/lexicon.txt"
push_if_needed "$WEIGHTS/tts-zh/tokens.txt" "$REMOTE/tts-zh/tokens.txt"
push_if_needed "$WEIGHTS/tts-zh/phone.fst" "$REMOTE/tts-zh/phone.fst"
push_if_needed "$WEIGHTS/tts-zh/date.fst" "$REMOTE/tts-zh/date.fst"
push_if_needed "$WEIGHTS/tts-zh/number.fst" "$REMOTE/tts-zh/number.fst"
push_if_needed "$SAMPLES/zh.wav" "$REMOTE/samples/zh.wav"
push_if_needed "$SAMPLES/en.wav" "$REMOTE/samples/en.wav"
push_if_needed "$SAMPLES/silence.wav" "$REMOTE/samples/silence.wav"

cat > "$OUT/run_peak.sh" <<'EOF'
#!/system/bin/sh
out="$1"
shift
"$@" >"$out" 2>&1 &
pid=$!
hwm=0
while kill -0 "$pid" 2>/dev/null; do
  cur=$(grep VmHWM "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
  if [ -n "$cur" ]; then
    if [ "$cur" -gt "$hwm" ]; then
      hwm=$cur
    fi
  fi
  sleep 1
done
wait "$pid"
echo "PEAK_VmHWM_KB $hwm" >>"$out"
EOF
adb -s "$DEV" push "$OUT/run_peak.sh" "$REMOTE/run_peak.sh"
adb -s "$DEV" shell "chmod 755 $REMOTE/run_peak.sh"

echo "===== device sense-voice ====="
adb -s "$DEV" shell "$REMOTE/run_peak.sh $REMOTE/device-sense-zh.log $REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=zh --num-threads=4 $REMOTE/samples/zh.wav"
adb -s "$DEV" pull "$REMOTE/device-sense-zh.log" "$OUT/device-sense-zh.log"
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=en --num-threads=4 $REMOTE/samples/en.wav > $REMOTE/device-sense-en.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-sense-en.log" "$OUT/device-sense-en.log"
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=zh --num-threads=4 $REMOTE/samples/silence.wav > $REMOTE/device-sense-silence.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-sense-silence.log" "$OUT/device-sense-silence.log"

echo "===== device tts zh ====="
adb -s "$DEV" shell "$REMOTE/run_peak.sh $REMOTE/device-tts-zh.log $REMOTE/sherpa-onnx-offline-tts --vits-model=$REMOTE/tts-zh/model.onnx --vits-lexicon=$REMOTE/tts-zh/lexicon.txt --vits-tokens=$REMOTE/tts-zh/tokens.txt --tts-rule-fsts=$REMOTE/tts-zh/phone.fst,$REMOTE/tts-zh/date.fst,$REMOTE/tts-zh/number.fst --num-threads=2 --output-filename=$REMOTE/tts-zh.wav '今天下午三点不见，不是五点。'"
adb -s "$DEV" pull "$REMOTE/device-tts-zh.log" "$OUT/device-tts-zh.log"
adb -s "$DEV" pull "$REMOTE/tts-zh.wav" "$OUT/device-tts-zh.wav"

echo DONE
