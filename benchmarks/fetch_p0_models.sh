#!/bin/sh
# Download P0 weights and sherpa-onnx prebuilt CLIs into gitignored directories.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WEIGHTS="$ROOT/models/weights"
mkdir -p "$WEIGHTS" "$ROOT/third_party"

fetch() {
  url="$1"
  dest="$2"
  if [ -f "$dest" ]; then
    echo "present $dest"
    return 0
  fi
  echo "get $url"
  curl -L --fail --retry 5 --retry-delay 2 -C - --silent --show-error -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

fetch "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf" \
  "$WEIGHTS/Qwen3-1.7B-Q4_K_M.gguf" &
fetch "https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_0.gguf" \
  "$WEIGHTS/Qwen3-0.6B-Q4_0.gguf" &
fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" \
  "$WEIGHTS/ggml-small.bin" &
fetch "https://huggingface.co/Qwen/Qwen3-1.7B/resolve/main/LICENSE" \
  "$WEIGHTS/Qwen3-LICENSE.txt" &
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-x64-static.tar.bz2" \
  "$WEIGHTS/sherpa-onnx-v2.0.1-osx-x64-static.tar.bz2" &
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-android-aarch64-termux-static.tar.bz2" \
  "$WEIGHTS/sherpa-onnx-v2.0.1-android-aarch64-termux-static.tar.bz2" &
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" \
  "$WEIGHTS/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" &
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2" \
  "$WEIGHTS/vits-piper-en_US-lessac-medium.tar.bz2" &
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-vits-zh-ll.tar.bz2" \
  "$WEIGHTS/sherpa-onnx-vits-zh-ll.tar.bz2" &
wait

if [ ! -d "$ROOT/third_party/sherpa-onnx-osx/bin" ]; then
  mkdir -p "$ROOT/third_party/sherpa-onnx-osx"
  tar -xjf "$WEIGHTS/sherpa-onnx-v2.0.1-osx-x64-static.tar.bz2" -C "$ROOT/third_party/sherpa-onnx-osx" --strip-components=1
fi
if [ ! -d "$ROOT/third_party/sherpa-onnx-android/bin" ]; then
  mkdir -p "$ROOT/third_party/sherpa-onnx-android"
  tar -xjf "$WEIGHTS/sherpa-onnx-v2.0.1-android-aarch64-termux-static.tar.bz2" -C "$ROOT/third_party/sherpa-onnx-android" --strip-components=1
fi
if [ ! -d "$WEIGHTS/sense-voice" ]; then
  mkdir -p "$WEIGHTS/sense-voice"
  tar -xjf "$WEIGHTS/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" -C "$WEIGHTS/sense-voice" --strip-components=1
fi
if [ ! -d "$WEIGHTS/tts-en" ]; then
  mkdir -p "$WEIGHTS/tts-en"
  tar -xjf "$WEIGHTS/vits-piper-en_US-lessac-medium.tar.bz2" -C "$WEIGHTS/tts-en" --strip-components=1
fi
if [ ! -d "$WEIGHTS/tts-zh" ]; then
  mkdir -p "$WEIGHTS/tts-zh"
  tar -xjf "$WEIGHTS/sherpa-onnx-vits-zh-ll.tar.bz2" -C "$WEIGHTS/tts-zh" --strip-components=1
fi

cd "$WEIGHTS"
shasum -a 256 \
  Qwen3-1.7B-Q4_K_M.gguf \
  Qwen3-0.6B-Q4_0.gguf \
  ggml-small.bin \
  sherpa-onnx-v2.0.1-osx-x64-static.tar.bz2 \
  sherpa-onnx-v2.0.1-android-aarch64-termux-static.tar.bz2 \
  sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2 \
  vits-piper-en_US-lessac-medium.tar.bz2 \
  sherpa-onnx-vits-zh-ll.tar.bz2 \
  > SHA256SUMS
echo "wrote $WEIGHTS/SHA256SUMS"
