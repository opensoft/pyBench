#!/bin/bash
# Ensure pyBench Docker images exist before the devcontainer starts.
#
# Dev Containers run initializeCommand before Compose can start the service.
# If py-bench:latest has been pruned, rebuild the missing base stack first,
# then refresh the per-user Layer 3 image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_DIR/scripts/lib/image-names.sh"

USERNAME="$(whoami)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            USERNAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--user USERNAME]"
            echo ""
            echo "Ensures workbench-base, dev-bench-base, py-bench:latest,"
            echo "and py-bench:USERNAME are available for the pyBench devcontainer."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

LAYER0_IMAGE="workbench-base:latest"
LAYER2_IMAGE="py-bench:latest"

if ! docker image inspect "$LAYER2_IMAGE" >/dev/null 2>&1; then
    echo "WARNING: Image '$LAYER2_IMAGE' not found. Rebuilding missing pyBench image stack..."
    echo ""

    if ! docker image inspect "$LAYER0_IMAGE" >/dev/null 2>&1; then
        echo "WARNING: Image '$LAYER0_IMAGE' not found. Building Layer 0..."
        "$REPO_DIR/base-image/build.sh" --user "$USERNAME"
        echo ""
    fi

    if ! resolve_family_base_image dev "$USERNAME" >/dev/null 2>&1; then
        echo "WARNING: Image '$(family_base_image dev)' not found. Building Layer 1a..."
        "$REPO_DIR/devBenches/base-image/build.sh" --user "$USERNAME"
        echo ""
    fi

    "$SCRIPT_DIR/build-layer2.sh" --user "$USERNAME"
    echo ""
else
    echo "OK: Layer 2 image '$LAYER2_IMAGE' found"
    echo ""
fi

exec "$REPO_DIR/scripts/ensure-layer3.sh" --base "$LAYER2_IMAGE" --user "$USERNAME"
