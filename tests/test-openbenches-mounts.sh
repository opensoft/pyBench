#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/prepare-openbenches-mounts.sh"
COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yml"
DEVCONTAINER_FILE="$REPO_ROOT/.devcontainer/devcontainer.json"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for required_command in docker jq; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command is unavailable: $required_command"
done

CLEAN_ENV=(
    env
    -u OPENBENCHES_CONFIG_ROOT
    -u OPENBENCHES_LIB_ROOT
    -u OPENBENCHES_STATE_ROOT
    -u WORKBENCHES_CONFIG_ROOT
    -u WORKBENCHES_LIB_ROOT
    -u WORKBENCHES_STATE_ROOT
    -u WORKBENCH_HISTORY_VOLUME
    -u CODEX_SONARQUBE_MCP_URL
)

prepare_case() {
    local name="$1"
    CASE_DIR="$TMP_ROOT/$name"
    CASE_HOME="$CASE_DIR/home"
    CASE_REPO="$CASE_DIR/repo"
    mkdir -p "$CASE_REPO/scripts" "$CASE_REPO/.devcontainer" "$CASE_HOME"
    cp "$RESOLVER" "$CASE_REPO/scripts/"
    cp "$COMPOSE_FILE" "$CASE_REPO/.devcontainer/"
    touch "$CASE_REPO/.env"
}

run_resolver() {
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" "$@" \
        bash "$CASE_REPO/scripts/prepare-openbenches-mounts.sh"
}

render_config() {
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester \
        docker compose -f "$CASE_REPO/.devcontainer/docker-compose.yml" \
        config --format json --no-env-resolution > "$CASE_DIR/config.json"
}

assert_link() {
    local name="$1"
    local expected="$2"
    local actual
    actual="$(readlink "$CASE_REPO/.devcontainer/.openbenches-mounts/$name")" \
        || fail "$name mount link is missing"
    [[ "$actual" == "$expected" ]] \
        || fail "$name resolved to $actual instead of $expected"
}

assert_bind() {
    local target="$1"
    local source="$2"
    local read_only="$3"
    jq -e \
        --arg target "$target" \
        --arg source "$source" \
        --argjson read_only "$read_only" \
        '[.services["py-bench"].volumes[] | select(.target == $target)] as $mounts
        | ($mounts | length) == 1
        and $mounts[0].type == "bind"
        and $mounts[0].source == $source
        and (($mounts[0].read_only // false) == $read_only)' \
        "$CASE_DIR/config.json" >/dev/null \
        || fail "unexpected mount for $target"
}

assert_history() {
    jq -e '
        [.services["py-bench"].volumes[]
            | select(.target == "/home/tester/.workbenches-history")] as $mounts
        | ($mounts | length) == 1
        and $mounts[0].type == "volume"
        and $mounts[0].source == "pybench-zshhistory"
        and .volumes["pybench-zshhistory"].name == "dev-benches_pybenchhistory"
        and .services["py-bench"].environment.HISTFILE
            == "/home/tester/.workbenches-history/.zsh_history"
    ' "$CASE_DIR/config.json" >/dev/null \
        || fail "persistent history contract changed"
}

check_case() {
    local name="$1"
    local config_root="$2"
    local lib_root="$3"
    local state_root="$4"
    local mount_dir="$CASE_REPO/.devcontainer/.openbenches-mounts"

    assert_link config "$config_root"
    assert_link lib "$lib_root"
    assert_link state "$state_root"
    render_config
    assert_bind /home/tester/.config/workbenches "$mount_dir/config" true
    assert_bind /home/tester/.local/lib/workbenches "$mount_dir/lib" true
    assert_bind /home/tester/.local/state/workbenches "$mount_dir/state" false
    assert_history
    echo "PASS: $name"
}

prepare_case old-only
mkdir -p \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches"
run_resolver
check_case old-only \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches"

prepare_case new-only
mkdir -p \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"
run_resolver
check_case new-only \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"

prepare_case both-present
mkdir -p \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches" \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"
run_resolver
check_case both-present-new-first \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"

prepare_case legacy-default
run_resolver
check_case legacy-default \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches"

prepare_case explicit-legacy
mkdir -p \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches" \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches" \
    "$CASE_DIR/legacy-config" \
    "$CASE_DIR/legacy-lib" \
    "$CASE_DIR/legacy-state"
run_resolver \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/legacy-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/legacy-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/legacy-state"
check_case explicit-legacy-override \
    "$CASE_DIR/legacy-config" \
    "$CASE_DIR/legacy-lib" \
    "$CASE_DIR/legacy-state"

prepare_case explicit-new
mkdir -p \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches" \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches" \
    "$CASE_DIR/new-config" \
    "$CASE_DIR/new-lib" \
    "$CASE_DIR/new-state"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/new-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/new-state"
check_case explicit-new-override \
    "$CASE_DIR/new-config" \
    "$CASE_DIR/new-lib" \
    "$CASE_DIR/new-state"

prepare_case equal-overrides
mkdir -p "$CASE_DIR/shared-config" "$CASE_DIR/shared-lib" "$CASE_DIR/shared-state"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/shared-config" \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/shared-config/" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/shared-lib" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/shared-lib/" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/shared-state" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/shared-state/"
check_case equal-explicit-overrides \
    "$CASE_DIR/shared-config" \
    "$CASE_DIR/shared-lib" \
    "$CASE_DIR/shared-state"

prepare_case conflicting-overrides
mkdir -p "$CASE_DIR/old-config" "$CASE_DIR/new-config"
if run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "conflicting explicit roots were accepted"
fi
[[ "$(<"$CASE_DIR/stderr")" == *"OPENBENCHES_CONFIG_ROOT and WORKBENCHES_CONFIG_ROOT conflict"* ]] \
    || fail "conflicting explicit roots did not produce an actionable error"
[[ ! -e "$CASE_REPO/.devcontainer/.openbenches-mounts/config" \
    && ! -L "$CASE_REPO/.devcontainer/.openbenches-mounts/config" ]] \
    || fail "conflicting roots produced a partial mount selection"
echo "PASS: conflicting-explicit-overrides"

sed '/^[[:space:]]*\/\//d' "$DEVCONTAINER_FILE" > "$TMP_ROOT/devcontainer.json"
jq -e \
    --arg config 'source=${localWorkspaceFolder}/.devcontainer/.openbenches-mounts/config,target=/home/${localEnv:USER}/.config/workbenches,type=bind,readonly' \
    --arg lib 'source=${localWorkspaceFolder}/.devcontainer/.openbenches-mounts/lib,target=/home/${localEnv:USER}/.local/lib/workbenches,type=bind,readonly' \
    --arg state 'source=${localWorkspaceFolder}/.devcontainer/.openbenches-mounts/state,target=/home/${localEnv:USER}/.local/state/workbenches,type=bind,consistency=cached' \
    '(.initializeCommand | contains("bash ${localWorkspaceFolder}/scripts/prepare-openbenches-mounts.sh"))
    and (.mounts | index($config) != null)
    and (.mounts | index($lib) != null)
    and (.mounts | index($state) != null)
    and ([.mounts[] | select(contains("/.openbenches-mounts/"))] | length == 3)' \
    "$TMP_ROOT/devcontainer.json" >/dev/null \
    || fail "devcontainer.json does not use the selected mount roots"
echo "PASS: devcontainer-json"

echo "pyBench openBenches mount compatibility tests passed"
