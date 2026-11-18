#!/bin/sh
# Cross-compile sherpa-onnx CLIs for stock Android.
# Do not use the Termux prebuilt: it imports std::__ndk1::__hash_memory and
# does not start on the Android 9 linker. ONNX Runtime stays a prebuilt static
# library; this script does not compile ONNX Runtime from source.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/sherpa-onnx"
NDK="${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
CMAKE="${ANDROID_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
BUILD="$SRC/build-android-api24"
ORT_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.28.2}"
JOBS="${JOBS:-8}"
READELF="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"

if [ ! -d "$NDK" ]; then
  echo "missing NDK: $NDK" >&2
  exit 1
fi

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$ROOT/third_party"
  git clone --depth 1 --branch v2.0.1 https://github.com/k2-fsa/sherpa-onnx.git "$SRC"
fi

mkdir -p "$BUILD"
if [ ! -f "$BUILD/${ORT_VERSION}-static/lib/libonnxruntime.a" ]; then
  tmp="$BUILD/ort.zip"
  curl -L --fail --retry 3 -C - \
    -o "$tmp" \
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/onnxruntime-android-arm64-v8a-static_lib-${ORT_VERSION}.zip"
  unzip -q -o "$tmp" -d "$BUILD"
  rm -f "$tmp"
  mv "$BUILD/onnxruntime-android-arm64-v8a-static_lib-${ORT_VERSION}" "$BUILD/${ORT_VERSION}-static"
fi

export SHERPA_ONNXRUNTIME_LIB_DIR="$BUILD/${ORT_VERSION}-static/lib"
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$BUILD/${ORT_VERSION}-static/include"

"$CMAKE" \
  -S "$SRC" \
  -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=ON \
  -DSHERPA_ONNX_ENABLE_BINARY=ON \
  -DSHERPA_ONNX_ENABLE_GPU=OFF \
  -DSHERPA_ONNX_LINK_LIBSTDCPP_STATICALLY=OFF \
  -DCMAKE_INSTALL_PREFIX="$BUILD/install"

"$CMAKE" --build "$BUILD" --config Release -j "$JOBS" --target sherpa-onnx-offline --target sherpa-onnx-offline-tts

for bin in sherpa-onnx-offline sherpa-onnx-offline-tts; do
  path="$BUILD/bin/$bin"
  if [ ! -f "$path" ]; then
    echo "missing $path" >&2
    exit 1
  fi
  echo "NEEDED $bin"
  "$READELF" -d "$path" | awk '/NEEDED/ {print}'
  if "$READELF" -s "$path" | awk '/__hash_memory/ && $7 == "UND" {found=1} END {exit !found}'; then
    echo "$bin still imports __hash_memory" >&2
    exit 1
  fi
done

echo "built $BUILD/bin/sherpa-onnx-offline"
echo "built $BUILD/bin/sherpa-onnx-offline-tts"
