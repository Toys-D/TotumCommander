#!/bin/bash
set -e

echo "=== Packaging Totum Commander ==="

cd "$(dirname "$0")/.."

# Build release
mkdir -p build-release
cd build-release

cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(sysctl -n hw.ncpu)

echo "=== Package complete ==="
echo "Next: build Xcode project in app/ for .app bundle"
