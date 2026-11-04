#!/bin/bash
set -e

echo "=== Building Totum Commander Core ==="

cd "$(dirname "$0")/.."

mkdir -p core/build
cd core/build

cmake .. -DCMAKE_BUILD_TYPE=Debug
cmake --build . -j$(sysctl -n hw.ncpu)

echo "=== Build complete ==="
