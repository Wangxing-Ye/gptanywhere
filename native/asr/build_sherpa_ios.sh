#!/bin/sh
# Build sherpa-onnx's C API for iPhone arm64.
# ONNX Runtime is the iOS static xcframework, not the Android zip.
# TTS stays off. SenseVoice and Qwen3-ASR do not need it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/sherpa-onnx"
BUILD="$SRC/build-ios-device"
OUT="$ROOT/native/prebuilt/ios"
CMAKE="${IOS_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
ORT_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.28.2}"
JOBS="${JOBS:-8}"

if [ ! -d "$SRC/.git" ]; then
  echo "missing $SRC" >&2
  exit 1
fi

ort_root="$BUILD/ios-onnxruntime/${ORT_VERSION}"
ort_slice="$ort_root/onnxruntime.xcframework/ios-arm64"
ort_lib="$ort_slice/onnxruntime.framework/onnxruntime"
ort_inc="$ort_slice/onnxruntime.framework/Headers"
if [ ! -f "$ort_lib" ]; then
  mkdir -p "$ort_root"
  tmp="$ort_root/ort.zip"
  curl -L --fail --retry 3 -o "$tmp" \
    "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/onnxruntime-ios-static-xcframework-${ORT_VERSION}.xcframework.zip"
  unzip -q -o "$tmp" -d "$ort_root"
  rm -f "$tmp"
fi
if [ ! -f "$ort_lib" ]; then
  echo "missing ONNX Runtime static library: $ort_lib" >&2
  exit 1
fi

export SHERPA_ONNXRUNTIME_LIB_DIR="$ort_slice"
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ort_inc"

"$CMAKE" \
  -S "$SRC" \
  -B "$BUILD/os64" \
  -DCMAKE_TOOLCHAIN_FILE="$SRC/toolchains/ios.toolchain.cmake" \
  -DPLATFORM=OS64 \
  -DDEPLOYMENT_TARGET=15.5 \
  -DENABLE_BITCODE=0 \
  -DENABLE_ARC=1 \
  -DENABLE_VISIBILITY=0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_ENABLE_GPU=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF

"$CMAKE" --build "$BUILD/os64" --config Release -j "$JOBS"

libs=""
for name in \
  libkaldi-native-fbank-core.a \
  libkissfft-float.a \
  libsherpa-onnx-c-api.a \
  libsherpa-onnx-core.a \
  libsherpa-onnx-fst.a \
  libsherpa-onnx-fstfar.a \
  libsherpa-onnx-kaldifst-core.a \
  libkaldi-decoder-core.a \
  libssentencepiece_core.a \
  libutf8proc.a
do
  found=$(find "$BUILD/os64" -name "$name" -print | head -n 1)
  if [ -z "$found" ]; then
    echo "missing $name" >&2
    exit 1
  fi
  libs="$libs $found"
done

mkdir -p "$OUT"
libtool -static -o "$OUT/libsherpa_ios.a" $libs
cp "$ort_lib" "$OUT/libonnxruntime_ios.a"
echo "built $OUT/libsherpa_ios.a"
echo "built $OUT/libonnxruntime_ios.a"
