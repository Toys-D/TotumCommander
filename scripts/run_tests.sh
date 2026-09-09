#!/bin/bash
set -e

echo "=== Running Totum Commander Tests ==="

cd "$(dirname "$0")/.."

# Build first
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Debug -DFCXL_BUILD_TESTS=ON
cmake --build . -j$(sysctl -n hw.ncpu)

# Run tests
ctest --output-on-failure

echo "=== All tests passed ==="
