#!/bin/sh
# Cross-compile whisper-cli. Use a multilingual ggml weight, never a *.en model, for Chinese.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/whisper.cpp"
NDK="${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
CMAKE="${ANDROID_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
JOBS="${JOBS:-6}"

if [ ! -d "$SRC" ]; then
  echo "missing $SRC; clone ggml-org/whisper.cpp there first" >&2
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
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_SDL2=OFF \
  -DBUILD_SHARED_LIBS=OFF

"$CMAKE" --build "$SRC/build-android" --config Release -j "$JOBS" --target whisper-cli
echo "built $SRC/build-android/bin/whisper-cli"
