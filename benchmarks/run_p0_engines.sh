#!/bin/sh
# P0 engine probe. Host logs are Mac smoke tests. Device logs are the OnePlus 6T.
set -u
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/results"
WEIGHTS="$ROOT/models/weights"
SAMPLES="$ROOT/benchmarks/samples"
LLAMA_HOST="$ROOT/third_party/llama.cpp/build-host/bin/llama-cli"
LLAMA_AND="$ROOT/third_party/llama.cpp/build-android/bin/llama-cli"
WHISPER_HOST="$ROOT/third_party/whisper.cpp/build-host/bin/whisper-cli"
WHISPER_AND="$ROOT/third_party/whisper.cpp/build-android/bin/whisper-cli"
SHERPA_HOST="$ROOT/third_party/sherpa-onnx-osx/bin"
SHERPA_AND="$ROOT/third_party/sherpa-onnx/build-android-api24/bin"
DEV="${ANDROID_SERIAL:-89ed17e8}"
REMOTE=/data/local/tmp/ta
mkdir -p "$OUT"

run_llm() {
  bin="$1"
  model="$2"
  label="$3"
  system="$4"
  prompt="$5"
  predict="$6"
  extra="$7"
  echo "LLM $label"
  /usr/bin/time -l "$bin" \
    -m "$model" \
    -c 2048 \
    -n "$predict" \
    --temp 0.2 \
    --reasoning off \
    -t 6 \
    --verbose-prompt \
    --system-prompt "$system" \
    --prompt "$prompt" \
    $extra \
    < /dev/null > "$OUT/$label.log" 2>&1 || echo "exit $? for $label" | tee -a "$OUT/$label.log"
}

echo "===== host whisper ====="
"$WHISPER_HOST" -m "$WEIGHTS/ggml-small.bin" -l zh -f "$SAMPLES/zh.wav" -nt > "$OUT/host-whisper-zh.log" 2>&1 || true
"$WHISPER_HOST" -m "$WEIGHTS/ggml-small.bin" -l en -f "$SAMPLES/en.wav" -nt > "$OUT/host-whisper-en.log" 2>&1 || true
"$WHISPER_HOST" -m "$WEIGHTS/ggml-small.bin" -l zh -f "$SAMPLES/silence.wav" -nt > "$OUT/host-whisper-silence.log" 2>&1 || true

echo "===== host sense-voice ====="
"$SHERPA_HOST/sherpa-onnx-offline" \
  --tokens="$WEIGHTS/sense-voice/tokens.txt" \
  --sense-voice-model="$WEIGHTS/sense-voice/model.onnx" \
  --sense-voice-language=zh \
  --num-threads=4 \
  "$SAMPLES/zh.wav" > "$OUT/host-sense-zh.log" 2>&1 || true
"$SHERPA_HOST/sherpa-onnx-offline" \
  --tokens="$WEIGHTS/sense-voice/tokens.txt" \
  --sense-voice-model="$WEIGHTS/sense-voice/model.onnx" \
  --sense-voice-language=en \
  --num-threads=4 \
  "$SAMPLES/en.wav" > "$OUT/host-sense-en.log" 2>&1 || true
"$SHERPA_HOST/sherpa-onnx-offline" \
  --tokens="$WEIGHTS/sense-voice/tokens.txt" \
  --sense-voice-model="$WEIGHTS/sense-voice/model.onnx" \
  --sense-voice-language=zh \
  --num-threads=4 \
  "$SAMPLES/silence.wav" > "$OUT/host-sense-silence.log" 2>&1 || true

echo "===== host tts ====="
"$SHERPA_HOST/sherpa-onnx-offline-tts" \
  --vits-model="$WEIGHTS/tts-en/en_US-lessac-medium.onnx" \
  --vits-tokens="$WEIGHTS/tts-en/tokens.txt" \
  --num-threads=2 \
  --output-filename="$OUT/host-tts-en.wav" \
  "The train does not leave at 15:00." > "$OUT/host-tts-en.log" 2>&1 || true
"$SHERPA_HOST/sherpa-onnx-offline-tts" \
  --vits-model="$WEIGHTS/tts-zh/model.onnx" \
  --vits-lexicon="$WEIGHTS/tts-zh/lexicon.txt" \
  --vits-tokens="$WEIGHTS/tts-zh/tokens.txt" \
  --tts-rule-fsts="$WEIGHTS/tts-zh/phone.fst,$WEIGHTS/tts-zh/date.fst,$WEIGHTS/tts-zh/number.fst" \
  --num-threads=2 \
  --output-filename="$OUT/host-tts-zh.wav" \
  "今天下午三点不见，不是五点。" > "$OUT/host-tts-zh.log" 2>&1 || true

SYS_EN="Translate the user text into English. Output only the translation."
SYS_ZH="Translate the user text into Simplified Chinese. Output only the translation."
ZH_TEXT="今天下午三点不见，不是五点。"
EN_TEXT="The train does not leave at 15:00."

echo "===== host llm ====="
run_llm "$LLAMA_HOST" "$WEIGHTS/Qwen3-0.6B-Q4_0.gguf" host-qwen06-zh-en "$SYS_EN" "$ZH_TEXT" 64 ""
run_llm "$LLAMA_HOST" "$WEIGHTS/Qwen3-0.6B-Q4_0.gguf" host-qwen06-en-zh "$SYS_ZH" "$EN_TEXT" 64 ""
run_llm "$LLAMA_HOST" "$WEIGHTS/Qwen3-1.7B-Q4_K_M.gguf" host-qwen17-zh-en "$SYS_EN" "$ZH_TEXT" 64 ""
run_llm "$LLAMA_HOST" "$WEIGHTS/Qwen3-1.7B-Q4_K_M.gguf" host-qwen17-en-zh "$SYS_ZH" "$EN_TEXT" 64 ""

echo "===== device ====="
if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
  echo "DEVICE_ABSENT" | tee "$OUT/device-status.txt"
  echo DONE
  exit 0
fi
adb -s "$DEV" shell "mkdir -p $REMOTE/tts-en $REMOTE/tts-zh $REMOTE/sense $REMOTE/samples"
adb -s "$DEV" push "$LLAMA_AND" "$REMOTE/llama-cli"
adb -s "$DEV" push "$WHISPER_AND" "$REMOTE/whisper-cli"
adb -s "$DEV" push "$SHERPA_AND/sherpa-onnx-offline" "$REMOTE/sherpa-onnx-offline"
adb -s "$DEV" push "$SHERPA_AND/sherpa-onnx-offline-tts" "$REMOTE/sherpa-onnx-offline-tts"
adb -s "$DEV" push "$WEIGHTS/Qwen3-0.6B-Q4_0.gguf" "$REMOTE/Qwen3-0.6B-Q4_0.gguf"
adb -s "$DEV" push "$WEIGHTS/Qwen3-1.7B-Q4_K_M.gguf" "$REMOTE/Qwen3-1.7B-Q4_K_M.gguf"
adb -s "$DEV" push "$WEIGHTS/ggml-small.bin" "$REMOTE/ggml-small.bin"
adb -s "$DEV" push "$WEIGHTS/sense-voice/model.onnx" "$REMOTE/sense/model.onnx"
adb -s "$DEV" push "$WEIGHTS/sense-voice/tokens.txt" "$REMOTE/sense/tokens.txt"
adb -s "$DEV" push "$WEIGHTS/tts-en/en_US-lessac-medium.onnx" "$REMOTE/tts-en/model.onnx"
adb -s "$DEV" push "$WEIGHTS/tts-en/tokens.txt" "$REMOTE/tts-en/tokens.txt"
adb -s "$DEV" push "$WEIGHTS/tts-zh/model.onnx" "$REMOTE/tts-zh/model.onnx"
adb -s "$DEV" push "$WEIGHTS/tts-zh/lexicon.txt" "$REMOTE/tts-zh/lexicon.txt"
adb -s "$DEV" push "$WEIGHTS/tts-zh/tokens.txt" "$REMOTE/tts-zh/tokens.txt"
adb -s "$DEV" push "$WEIGHTS/tts-zh/phone.fst" "$REMOTE/tts-zh/phone.fst"
adb -s "$DEV" push "$WEIGHTS/tts-zh/date.fst" "$REMOTE/tts-zh/date.fst"
adb -s "$DEV" push "$WEIGHTS/tts-zh/number.fst" "$REMOTE/tts-zh/number.fst"
adb -s "$DEV" push "$SAMPLES/zh.wav" "$REMOTE/samples/zh.wav"
adb -s "$DEV" push "$SAMPLES/en.wav" "$REMOTE/samples/en.wav"
adb -s "$DEV" push "$SAMPLES/silence.wav" "$REMOTE/samples/silence.wav"
adb -s "$DEV" shell "chmod 755 $REMOTE/llama-cli $REMOTE/whisper-cli $REMOTE/sherpa-onnx-offline $REMOTE/sherpa-onnx-offline-tts"

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

dev_llm() {
  label="$1"
  model="$2"
  system="$3"
  prompt="$4"
  predict="$5"
  echo "DEVICE LLM $label"
  adb -s "$DEV" shell "$REMOTE/run_peak.sh $REMOTE/$label.log $REMOTE/llama-cli -m $REMOTE/$model -c 2048 -n $predict --temp 0.2 --reasoning off -t 4 --system-prompt '$system' --prompt '$prompt'"
  adb -s "$DEV" pull "$REMOTE/$label.log" "$OUT/$label.log"
}

echo "===== device asr tts ====="
adb -s "$DEV" shell "$REMOTE/run_peak.sh $REMOTE/device-whisper-zh.log $REMOTE/whisper-cli -m $REMOTE/ggml-small.bin -l zh -f $REMOTE/samples/zh.wav -nt"
adb -s "$DEV" pull "$REMOTE/device-whisper-zh.log" "$OUT/device-whisper-zh.log"
adb -s "$DEV" shell "$REMOTE/whisper-cli -m $REMOTE/ggml-small.bin -l en -f $REMOTE/samples/en.wav -nt > $REMOTE/device-whisper-en.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-whisper-en.log" "$OUT/device-whisper-en.log"
adb -s "$DEV" shell "$REMOTE/whisper-cli -m $REMOTE/ggml-small.bin -l zh -f $REMOTE/samples/silence.wav -nt > $REMOTE/device-whisper-silence.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-whisper-silence.log" "$OUT/device-whisper-silence.log"

adb -s "$DEV" shell "$REMOTE/run_peak.sh $REMOTE/device-sense-zh.log $REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=zh --num-threads=4 $REMOTE/samples/zh.wav"
adb -s "$DEV" pull "$REMOTE/device-sense-zh.log" "$OUT/device-sense-zh.log"
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=en --num-threads=4 $REMOTE/samples/en.wav > $REMOTE/device-sense-en.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-sense-en.log" "$OUT/device-sense-en.log"
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline --tokens=$REMOTE/sense/tokens.txt --sense-voice-model=$REMOTE/sense/model.onnx --sense-voice-language=zh --num-threads=4 $REMOTE/samples/silence.wav > $REMOTE/device-sense-silence.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-sense-silence.log" "$OUT/device-sense-silence.log"

adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline-tts --vits-model=$REMOTE/tts-en/model.onnx --vits-tokens=$REMOTE/tts-en/tokens.txt --num-threads=2 --output-filename=$REMOTE/tts-en.wav 'The train does not leave at 15:00.' > $REMOTE/device-tts-en.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-tts-en.log" "$OUT/device-tts-en.log"
adb -s "$DEV" shell "$REMOTE/sherpa-onnx-offline-tts --vits-model=$REMOTE/tts-zh/model.onnx --vits-lexicon=$REMOTE/tts-zh/lexicon.txt --vits-tokens=$REMOTE/tts-zh/tokens.txt --tts-rule-fsts=$REMOTE/tts-zh/phone.fst,$REMOTE/tts-zh/date.fst,$REMOTE/tts-zh/number.fst --num-threads=2 --output-filename=$REMOTE/tts-zh.wav '今天下午三点不见，不是五点。' > $REMOTE/device-tts-zh.log 2>&1"
adb -s "$DEV" pull "$REMOTE/device-tts-zh.log" "$OUT/device-tts-zh.log"
adb -s "$DEV" pull "$REMOTE/tts-en.wav" "$OUT/device-tts-en.wav" || true
adb -s "$DEV" pull "$REMOTE/tts-zh.wav" "$OUT/device-tts-zh.wav" || true

dev_llm device-qwen06-zh-en Qwen3-0.6B-Q4_0.gguf "$SYS_EN" "$ZH_TEXT" 64
dev_llm device-qwen06-en-zh Qwen3-0.6B-Q4_0.gguf "$SYS_ZH" "$EN_TEXT" 64
dev_llm device-qwen17-zh-en-cold Qwen3-1.7B-Q4_K_M.gguf "$SYS_EN" "$ZH_TEXT" 100
dev_llm device-qwen17-zh-en-warm Qwen3-1.7B-Q4_K_M.gguf "$SYS_EN" "$ZH_TEXT" 100
dev_llm device-qwen17-en-zh Qwen3-1.7B-Q4_K_M.gguf "$SYS_ZH" "$EN_TEXT" 64

echo DONE
