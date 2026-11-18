#!/bin/sh
# Build whisper.cpp for iPhone arm64. Chinese still uses a multilingual weight.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/whisper.cpp"
BUILD="$SRC/build-ios"
OUT="$ROOT/native/prebuilt/ios"
CMAKE="${IOS_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
JOBS="${JOBS:-8}"

if [ ! -d "$SRC" ]; then
  echo "missing $SRC" >&2
  exit 1
fi

"$CMAKE" \
  -S "$SRC" \
  -B "$BUILD" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_LLAMAFILE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_NDEBUG=ON \
  -DCMAKE_C_VISIBILITY_PRESET=hidden \
  -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
  -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_SDL2=OFF

"$CMAKE" --build "$BUILD" --config Release --target whisper -j "$JOBS"

archives=""
for lib in $(find "$BUILD" -path '*Release-iphoneos*' -name '*.a' -print); do
  archives="$archives $lib"
done
if [ -z "$archives" ]; then
  echo "no iPhone static libraries under $BUILD" >&2
  exit 1
fi
echo "merging$archives"
mkdir -p "$OUT"
libtool -static -o "$OUT/libwhisper_ios.a" $archives
echo "built $OUT/libwhisper_ios.a"
