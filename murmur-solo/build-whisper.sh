#!/usr/bin/env bash
# Build the whisper.cpp static library that Murmur Solo links against, and stage
# it (+ headers) into this package. Reproducible with only Xcode Command Line
# Tools (no full Xcode needed) — uses the default cmake generator, Metal with an
# embedded shader library, and no CoreML (we run the GGML model on Metal).
#
# Requirements: cmake (brew install cmake), the whisper.cpp checkout below.
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_SRC="${WHISPER_SRC:-../ext/whisper.cpp}"
if [[ ! -d "$WHISPER_SRC" ]]; then
    echo "Cloning whisper.cpp into $WHISPER_SRC"
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_SRC"
fi

command -v cmake >/dev/null || { echo "cmake required: brew install cmake" >&2; exit 1; }

pushd "$WHISPER_SRC" >/dev/null
rm -rf build-cli
cmake -B build-cli \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DWHISPER_COREML=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -S .
cmake --build build-cli -j --config Release

# Combine the per-component archives into one.
libtool -static -o /tmp/libwhisper_all.a $(find build-cli -name "*.a")
WHISPER_ABS="$(pwd)"
popd >/dev/null

DEST="Frameworks/whisper"
mkdir -p "$DEST/lib" "Sources/CWhisper/include"
cp /tmp/libwhisper_all.a "$DEST/lib/"
cp "$WHISPER_ABS"/include/whisper.h \
   "$WHISPER_ABS"/ggml/include/{ggml.h,ggml-alloc.h,ggml-backend.h,ggml-metal.h,ggml-cpu.h,ggml-blas.h,gguf.h} \
   Sources/CWhisper/include/

echo "==> staged $DEST/lib/libwhisper_all.a ($(du -h "$DEST/lib/libwhisper_all.a" | awk '{print $1}'))"
echo "    headers -> Sources/CWhisper/include/"
