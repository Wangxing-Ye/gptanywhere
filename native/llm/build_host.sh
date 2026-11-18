#!/bin/sh
# Host CPU build used only as a Mac smoke test. It is not a device measurement.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/llama.cpp"
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
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TOOLS=ON \
  -DBUILD_SHARED_LIBS=OFF

"$CMAKE" --build "$SRC/build-host" --config Release -j "$JOBS" --target llama-cli
echo "built $SRC/build-host/bin/llama-cli"
