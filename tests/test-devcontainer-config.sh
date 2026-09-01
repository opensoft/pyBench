#!/usr/bin/env bash
# Validate the durable pyBench Compose contract without starting services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yml"
RENDERED_CONFIG="$(mktemp)"
trap 'rm -f "$RENDERED_CONFIG"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

docker compose \
    -f "$COMPOSE_FILE" \
    config \
    --format json \
    --no-env-resolution \
    > "$RENDERED_CONFIG"

jq -e '
    .services["py-bench"].environment.CODEX_SONARQUBE_MCP_URL
        == "http://sonarqube-mcp-proxy:64130/mcp"
' "$RENDERED_CONFIG" >/dev/null \
    || fail "py-bench does not supply the private SonarQube MCP URL"

jq -e '
    (.services["py-bench"].networks | keys | sort)
        == ["default", "devbench-shared"]
' "$RENDERED_CONFIG" >/dev/null \
    || fail "py-bench must retain default and join devbench-shared"

jq -e '
    .networks["devbench-shared"].external == true
    and .networks["devbench-shared"].name == "devbench-shared"
' "$RENDERED_CONFIG" >/dev/null \
    || fail "devbench-shared must remain an existing external network"

jq -e '
    (.services["py-bench"] | has("ports") | not)
    or (.services["py-bench"].ports | length == 0)
' "$RENDERED_CONFIG" >/dev/null \
    || fail "py-bench configuration must not publish the MCP proxy"

! grep -Eq 'SONAR(QUBE)?_TOKEN' "$COMPOSE_FILE" \
    || fail "py-bench Compose source must not contain a SonarQube token"

echo "pyBench devcontainer configuration tests passed"
