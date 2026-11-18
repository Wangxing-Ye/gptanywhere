#!/bin/sh
# Build llama-cli's static libraries for iPhone arm64.
# Same llama.cpp revision as Android. Output is not committed.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/llama.cpp"
BUILD="$SRC/build-ios"
OUT="$ROOT/native/prebuilt/ios"
CMAKE="${IOS_CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
JOBS="${JOBS:-8}"

if [ ! -d "$SRC" ]; then
  echo "missing $SRC" >&2
  exit 1
fi
if [ ! -x "$CMAKE" ]; then
  echo "missing cmake: $CMAKE" >&2
  exit 1
fi

# This revision installs the iOS llama-server bundle without a bundle destination.
server_cmake="$SRC/tools/server/CMakeLists.txt"
if ! grep -q 'NOT CMAKE_SYSTEM_NAME STREQUAL "iOS"' "$server_cmake"; then
  python3 - "$server_cmake" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "install(TARGETS ${TARGET} RUNTIME)\n"
new = "if(NOT CMAKE_SYSTEM_NAME STREQUAL \"iOS\")\ninstall(TARGETS ${TARGET} RUNTIME)\nendif()\n"
if old not in text:
    raise SystemExit("llama-server install() line was not found")
path.write_text(text.replace(old, new, 1))
PY
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
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_COMMON=ON \
  -DLLAMA_TOOLS_INSTALL=OFF \
  -DLLAMA_OPENSSL=OFF

"$CMAKE" --build "$BUILD" --config Release --target llama-cli -j "$JOBS"

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
libtool -static -o "$OUT/libllama_ios.a" $archives
echo "built $OUT/libllama_ios.a"
