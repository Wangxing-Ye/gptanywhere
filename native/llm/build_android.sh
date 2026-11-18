#!/bin/sh
# Cross-compile llama-cli for the connected arm64 Android probe.
# Flags follow llama.cpp docs/android.md. Output stays in third_party and is not committed.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/llama.cpp"
NDK="${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
CMAKE="${ANDROID_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
JOBS="${JOBS:-6}"

if [ ! -d "$SRC" ]; then
  echo "missing $SRC; clone ggml-org/llama.cpp there first" >&2
  exit 1
fi

"$CMAKE" \
  -S "$SRC" \
  -B "$SRC/build-android" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_LLAMAFILE=OFF \
  -DGGML_METAL=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TOOLS=ON \
  -DBUILD_SHARED_LIBS=OFF

# This llama.cpp snapshot only adds the llama-cli target when the server tools are enabled.
"$CMAKE" --build "$SRC/build-android" --config Release -j "$JOBS" --target llama-cli
echo "built $SRC/build-android/bin/llama-cli"
