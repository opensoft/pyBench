#!/bin/bash

set -euo pipefail

USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAYER2_IMAGE="py-bench:latest"
USER_IMAGE="py-bench:$USER"
GITCONFIG_PATH="${HOME}/.gitconfig"

ensure_host_gitconfig() {
    if [ -d "$GITCONFIG_PATH" ]; then
        if [ -n "$(find "$GITCONFIG_PATH" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            echo "❌ '$GITCONFIG_PATH' is a non-empty directory; refusing to remove it."
            echo "   Move or inspect its contents, then replace it with a regular file."
            return 1
        fi

        echo "⚠️  '$GITCONFIG_PATH' is an empty directory; replacing it with a regular file..."
        rmdir "$GITCONFIG_PATH"
    fi

    if [ ! -e "$GITCONFIG_PATH" ]; then
        echo "🔧 Creating host Git configuration file: $GITCONFIG_PATH"
        (umask 077 && : > "$GITCONFIG_PATH")
    fi

    if [ ! -f "$GITCONFIG_PATH" ]; then
        echo "❌ '$GITCONFIG_PATH' exists but is not a regular file."
        return 1
    fi

    if [ ! -r "$GITCONFIG_PATH" ] || [ ! -w "$GITCONFIG_PATH" ]; then
        echo "❌ '$GITCONFIG_PATH' must be readable and writable by '$USER'."
        echo "   Fix it with: sudo chown $USER:$(id -gn) '$GITCONFIG_PATH' && chmod 600 '$GITCONFIG_PATH'"
        return 1
    fi
}

echo "🚀 Starting the pyBench container"
echo "   User: $USER"

if ! docker image inspect "$LAYER2_IMAGE" >/dev/null 2>&1; then
    echo ""
    echo "🔧 Docker image not found. Building py-bench:latest..."
    "$SCRIPT_DIR/scripts/build-layer.sh"
else
    echo "✓ Base image '$LAYER2_IMAGE' found"
    echo "🔧 Ensuring user image '$USER_IMAGE'..."
    "$REPO_DIR/scripts/ensure-layer3.sh" --base "$LAYER2_IMAGE" --user "$USER"
fi

ensure_host_gitconfig

echo "🔧 Starting container with user mapping..."
"$SCRIPT_DIR/scripts/configure-amd-rocm-wsl.sh"
docker-compose \
    -f .devcontainer/docker-compose.yml \
    -f .devcontainer/docker-compose.amd-rocm.generated.yml \
    up -d

if [ $? -eq 0 ]; then
    echo "✅ Container started successfully!"
else
    echo "❌ Container failed to start. Check Docker logs:"
    echo "   docker-compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.amd-rocm.generated.yml logs"
fi
