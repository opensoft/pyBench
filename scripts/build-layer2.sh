#!/bin/bash
# Build script for Layer 2: pyBench image
# Creates: py-bench:latest

set -euo pipefail

echo "=========================================="
echo "Building Layer 2: pyBench"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_DIR/scripts/lib/image-names.sh"
cd "$SCRIPT_DIR/.."

USERNAME=${1:-$(whoami)}
if [ "$USERNAME" = "--user" ]; then
    USERNAME="${2:-$(whoami)}"
fi

BASE_IMAGE="$(resolve_family_base_image dev "$USERNAME" || true)"

echo "Configuration:"
echo "  Tag: py-bench:latest (user-agnostic)"
echo "  Base image: ${BASE_IMAGE:-$(family_base_image dev)}"
echo ""

if [ -z "$BASE_IMAGE" ]; then
    echo "❌ Error: Layer 1 ($(family_base_image dev)) not found!"
    echo ""
    echo "Please build Layer 1 first:"
    echo "  cd ../../base-image"
    echo "  ./build.sh --user $USERNAME"
    exit 1
fi

echo "Building py-bench:latest..."
docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg USERNAME="$USERNAME" \
    -f Dockerfile.layer2 \
    -t "py-bench:latest" \
    .

echo ""
echo "✓ Layer 2 (Python) built successfully!"
echo "  Image: py-bench:latest"
echo ""
echo "Layer 3 (user personalization) is handled by"
echo "build-layer.sh or scripts/ensure-layer3.sh."
