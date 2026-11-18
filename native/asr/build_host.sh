#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/whisper.cpp"
CMAKE="${CMAKE:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
JOBS="${JOBS:-6}"

"$CMAKE" \
  -S "$SRC" \
  -B "$SRC/build-host" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_OPENMP=OFF \
  -DGGML_LLAMAFILE=OFF \
  -DGGML_METAL=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_SDL2=OFF \
  -DBUILD_SHARED_LIBS=OFF

"$CMAKE" --build "$SRC/build-host" --config Release -j "$JOBS" --target whisper-cli
echo "built $SRC/build-host/bin/whisper-cli"
