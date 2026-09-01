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

for required_command in docker jq; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command is unavailable: $required_command"
done

env -u CODEX_SONARQUBE_MCP_URL docker compose \
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

for environment_file in \
    "$COMPOSE_FILE" \
    "$REPO_ROOT/.env" \
    "$REPO_ROOT/.devcontainer/.env"; do
    [[ -f "$environment_file" ]] || continue
    ! grep -Eq 'SONAR(QUBE)?_TOKEN' "$environment_file" \
        || fail "$environment_file must not contain a SonarQube token"
done

echo "pyBench devcontainer configuration tests passed"
