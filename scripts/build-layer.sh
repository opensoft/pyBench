#!/bin/bash
# Build Layer 2 and ensure Layer 3 (python-bench)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

USERNAME=${1:-$(whoami)}
if [ "$USERNAME" = "--user" ]; then
    USERNAME="${2:-$(whoami)}"
fi

"${SCRIPT_DIR}/build-layer2.sh" --user "$USERNAME"
exec "${REPO_DIR}/scripts/ensure-layer3.sh" --base "python-bench:latest" --user "$USERNAME"
