#!/bin/bash

set -euo pipefail

USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAYER2_IMAGE="python-bench:latest"
USER_IMAGE="python-bench:$USER"

echo "🚀 Starting the Python DevBench Container"
echo "   User: $USER"

if ! docker image inspect "$LAYER2_IMAGE" >/dev/null 2>&1; then
    echo ""
    echo "🔧 Docker image not found. Building python-bench:latest..."
    "$SCRIPT_DIR/scripts/build-layer.sh"
else
    echo "✓ Base image '$LAYER2_IMAGE' found"
    echo "🔧 Ensuring user image '$USER_IMAGE'..."
    "$REPO_DIR/scripts/ensure-layer3.sh" --base "$LAYER2_IMAGE" --user "$USER"
fi

echo "🔧 Starting container with user mapping..."
docker-compose -f .devcontainer/docker-compose.yml up -d

if [ $? -eq 0 ]; then
    echo "✅ Container started successfully!"
else
    echo "❌ Container failed to start. Check Docker logs:"
    echo "   docker-compose -f .devcontainer/docker-compose.yml logs"
fi
