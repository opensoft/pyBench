#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/prepare-openbenches-mounts.sh"
COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yml"
DEVCONTAINER_FILE="$REPO_ROOT/.devcontainer/devcontainer.json"
SETUP_SCRIPT="$REPO_ROOT/setup.sh"
START_SCRIPT="$REPO_ROOT/start-monster.sh"
TMP_ROOT="$(mktemp -d)"
REAL_MV="$(command -v mv)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for required_command in docker jq flock; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command is unavailable: $required_command"
done

docker compose version >/dev/null 2>&1 \
    || fail "required command is unavailable: docker compose"

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
    printf 'services:\n  py-bench: {}\n' \
        > "$CASE_REPO/.devcontainer/docker-compose.amd-rocm.generated.yml"
}

run_resolver() {
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" "$@" \
        bash "$CASE_REPO/scripts/prepare-openbenches-mounts.sh"
}

render_config() {
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester "$@" \
        docker compose \
        -f "$CASE_REPO/.devcontainer/docker-compose.yml" \
        -f "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
        -f "$CASE_REPO/.devcontainer/docker-compose.amd-rocm.generated.yml" \
        config --format json --no-env-resolution > "$CASE_DIR/config.json"
}

compose_hash() {
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester \
        docker compose \
        -f "$CASE_REPO/.devcontainer/docker-compose.yml" \
        -f "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
        -f "$CASE_REPO/.devcontainer/docker-compose.amd-rocm.generated.yml" \
        config --hash py-bench
}

assert_bind() {
    local target="$1"
    local source="$2"
    local read_only="$3"
    local consistency="$4"
    jq -e \
        --arg target "$target" \
        --arg source "$source" \
        --argjson read_only "$read_only" \
        --arg consistency "$consistency" \
        '[.services["py-bench"].volumes[] | select(.target == $target)] as $mounts
        | ($mounts | length) == 1
        and $mounts[0].type == "bind"
        and $mounts[0].source == $source
        and (($mounts[0].read_only // false) == $read_only)
        and (($mounts[0].consistency // "") == $consistency)' \
        "$CASE_DIR/config.json" >/dev/null \
        || fail "unexpected mount for $target"
}

assert_history() {
    local volume_name="${1:-dev-benches_pybenchhistory}"
    jq -e --arg volume_name "$volume_name" '
        [.services["py-bench"].volumes[]
            | select(.target == "/home/tester/.workbenches-history")] as $mounts
        | ($mounts | length) == 1
        and $mounts[0].type == "volume"
        and $mounts[0].source == "pybench-zshhistory"
        and .volumes["pybench-zshhistory"].name == $volume_name
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
    local generated="$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml"

    [[ -f "$generated" && ! -L "$generated" ]] \
        || fail "$name did not publish a regular Compose override"
    [[ -d "$config_root" && -d "$lib_root" && -d "$state_root" ]] \
        || fail "$name selected a missing root"
    [[ ! -L "$CASE_REPO/.devcontainer/.openbenches-mounts/config" \
        && ! -L "$CASE_REPO/.devcontainer/.openbenches-mounts/lib" \
        && ! -L "$CASE_REPO/.devcontainer/.openbenches-mounts/state" ]] \
        || fail "$name published mutable mount links"
    render_config
    assert_bind /home/tester/.config/workbenches "$config_root" true ""
    assert_bind /home/tester/.local/lib/workbenches "$lib_root" true ""
    assert_bind /home/tester/.local/state/workbenches "$state_root" false cached
    assert_history
    echo "PASS: $name"
}

write_log_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${0##*/}" >> "${STUB_LOG:?}"
if [[ $# -gt 0 ]]; then
    printf ' %s' "$@" >> "$STUB_LOG"
fi
printf '\n' >> "$STUB_LOG"
EOF
    chmod +x "$path"
}

prepare_entrypoint_case() {
    local name="$1"
    prepare_case "$name"
    cp "$SETUP_SCRIPT" "$START_SCRIPT" "$CASE_REPO/"
    write_log_stub "$CASE_REPO/scripts/configure-amd-rocm-wsl.sh"
    mkdir -p "$CASE_DIR/mockbin"
    cat > "$CASE_DIR/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
    exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 1
EOF
    cat > "$CASE_DIR/mockbin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_COMPOSE_LOG:?}"
EOF
    chmod +x "$CASE_DIR/mockbin/docker" "$CASE_DIR/mockbin/docker-compose"
    : > "$CASE_DIR/docker-compose.log"
    : > "$CASE_DIR/stubs.log"
}

run_setup_entrypoint() {
    (
        cd "$CASE_REPO"
        "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester \
            PATH="$CASE_DIR/mockbin:$PATH" \
            STUB_LOG="$CASE_DIR/stubs.log" \
            DOCKER_COMPOSE_LOG="$CASE_DIR/docker-compose.log" \
            bash ./setup.sh > "$CASE_DIR/setup.out" 2>&1
    )
}

run_start_entrypoint() {
    (
        cd "$CASE_REPO"
        "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester \
            PATH="$CASE_DIR/mockbin:$PATH" \
            STUB_LOG="$CASE_DIR/stubs.log" \
            DOCKER_COMPOSE_LOG="$CASE_DIR/docker-compose.log" \
            "$@" bash ./start-monster.sh > "$CASE_DIR/start.out" 2>&1
    )
}

assert_compose_invocations() {
    local log="$1"
    local count="$2"
    local suffix="$3"
    local expected="-f .devcontainer/docker-compose.yml -f .devcontainer/.openbenches-mounts/docker-compose.yml -f .devcontainer/docker-compose.amd-rocm.generated.yml up -d$suffix"
    local line
    mapfile -t lines < "$log"
    [[ "${#lines[@]}" == "$count" ]] \
        || fail "expected $count Compose invocations, got ${#lines[@]}"
    for line in "${lines[@]}"; do
        [[ "$line" == "$expected" ]] \
            || fail "unexpected Compose invocation: $line"
        [[ "$line" != *--force-recreate* ]] \
            || fail "entrypoint always forces container recreation"
    done
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
touch \
    "$CASE_HOME/.config/workbenches/legacy-data" \
    "$CASE_HOME/.local/lib/workbenches/legacy-data" \
    "$CASE_HOME/.local/state/workbenches/legacy-data"
run_resolver
check_case both-present-new-first \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"
for empty_root in \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches"; do
    [[ -z "$(find "$empty_root" -mindepth 1 -print -quit)" ]] \
        || fail "legacy data was merged or migrated into $empty_root"
done
[[ -f "$CASE_HOME/.config/workbenches/legacy-data" \
    && -f "$CASE_HOME/.local/lib/workbenches/legacy-data" \
    && -f "$CASE_HOME/.local/state/workbenches/legacy-data" ]] \
    || fail "legacy data was changed during new-first selection"
echo "PASS: populated-legacy-does-not-trigger-fallback-or-migration"

prepare_case fresh-default
run_resolver
check_case fresh-default-creates-legacy-roots \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches"
render_config WORKBENCH_HISTORY_VOLUME=custom-history
assert_history custom-history
echo "PASS: history-volume-override"

prepare_case mixed-selection
mkdir -p \
    "$CASE_DIR/explicit config" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches" \
    "$CASE_HOME/.local/state/openbenches"
run_resolver "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/explicit config"
check_case independent-per-destination-selection \
    "$CASE_DIR/explicit config" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/openbenches"

prepare_case explicit-legacy
mkdir -p \
    "$CASE_HOME/.config/openbenches" \
    "$CASE_HOME/.local/lib/openbenches" \
    "$CASE_HOME/.local/state/openbenches" \
    "$CASE_DIR/legacy config" \
    "$CASE_DIR/legacy lib" \
    "$CASE_DIR/legacy state"
run_resolver \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/legacy config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/legacy lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/legacy state"
check_case explicit-legacy-override \
    "$CASE_DIR/legacy config" \
    "$CASE_DIR/legacy lib" \
    "$CASE_DIR/legacy state"

prepare_case explicit-new
mkdir -p \
    "$CASE_HOME/.config/workbenches" \
    "$CASE_HOME/.local/lib/workbenches" \
    "$CASE_HOME/.local/state/workbenches" \
    "$CASE_DIR/new config" \
    "$CASE_DIR/new lib" \
    "$CASE_DIR/new state's"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/new lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/new state's"
check_case explicit-new-override-with-yaml-quoting \
    "$CASE_DIR/new config" \
    "$CASE_DIR/new lib" \
    "$CASE_DIR/new state's"

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
[[ ! -e "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" ]] \
    || fail "conflicting roots published a Compose override"
[[ ! -e "$CASE_HOME/.config" && ! -e "$CASE_HOME/.local" ]] \
    || fail "conflicting roots created default mount sources"
run_resolver
cp "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    "$CASE_DIR/before-conflict.yml"
if run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "conflicting explicit roots replaced an existing selection"
fi
cmp -s "$CASE_DIR/before-conflict.yml" \
    "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    || fail "conflicting roots changed the published selection"
echo "PASS: conflicting-explicit-overrides-are-atomic"

prepare_case missing-explicit
if run_resolver "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/missing new" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "a missing explicit openBenches root was accepted"
fi
[[ "$(<"$CASE_DIR/stderr")" == *"OPENBENCHES_CONFIG_ROOT must reference an existing directory"* ]] \
    || fail "missing explicit openBenches root did not produce an actionable error"
[[ ! -e "$CASE_DIR/missing new" \
    && ! -e "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" ]] \
    || fail "missing explicit openBenches root was created or published"
run_resolver
cp "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    "$CASE_DIR/before-missing.yml"
if run_resolver "WORKBENCHES_STATE_ROOT=$CASE_DIR/missing legacy" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "a missing explicit workBenches root was accepted"
fi
[[ "$(<"$CASE_DIR/stderr")" == *"WORKBENCHES_STATE_ROOT must reference an existing directory"* ]] \
    || fail "missing explicit workBenches root did not produce an actionable error"
cmp -s "$CASE_DIR/before-missing.yml" \
    "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    || fail "missing explicit root changed the published selection"
touch "$CASE_DIR/not-a-directory"
if run_resolver "OPENBENCHES_LIB_ROOT=$CASE_DIR/not-a-directory" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "a regular file was accepted as an explicit root"
fi
cmp -s "$CASE_DIR/before-missing.yml" \
    "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    || fail "invalid explicit root changed the published selection"
echo "PASS: missing-and-invalid-explicit-roots"

prepare_case changed-root-recreation
mkdir -p \
    "$CASE_DIR/old-config" "$CASE_DIR/old-lib" "$CASE_DIR/old-state" \
    "$CASE_DIR/new-config" "$CASE_DIR/new-lib" "$CASE_DIR/new-state"
run_resolver \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/old-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/old-state"
hash_old="$(compose_hash)"
inode_old="$(stat -c %i "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml")"
run_resolver \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/old-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/old-state"
[[ "$(compose_hash)" == "$hash_old" ]] \
    || fail "unchanged roots changed the Compose service hash"
[[ "$(stat -c %i "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml")" == "$inode_old" ]] \
    || fail "unchanged roots republished the Compose override"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/new-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/new-state"
[[ "$(compose_hash)" != "$hash_old" ]] \
    || fail "changed roots did not change the Compose service hash"
check_case changed-root-recreation \
    "$CASE_DIR/new-config" \
    "$CASE_DIR/new-lib" \
    "$CASE_DIR/new-state"

prepare_case interrupted-publication
mkdir -p \
    "$CASE_DIR/old-config" "$CASE_DIR/old-lib" "$CASE_DIR/old-state" \
    "$CASE_DIR/new-config" "$CASE_DIR/new-lib" "$CASE_DIR/new-state"
run_resolver \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/old-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/old-state"
cp "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    "$CASE_DIR/before-interrupt.yml"
mkdir -p "$CASE_DIR/mockbin"
cat > "$CASE_DIR/mockbin/mv" <<'EOF'
#!/usr/bin/env bash
exit 74
EOF
chmod +x "$CASE_DIR/mockbin/mv"
if run_resolver \
    PATH="$CASE_DIR/mockbin:$PATH" \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/new-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/new-state" \
    > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    fail "interrupted publication unexpectedly succeeded"
fi
cmp -s "$CASE_DIR/before-interrupt.yml" \
    "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" \
    || fail "interrupted publication exposed a partial selection"
if compgen -G "$CASE_REPO/.devcontainer/.openbenches-mounts/.docker-compose.yml.*" >/dev/null; then
    fail "interrupted publication left temporary files"
fi
render_config
assert_bind /home/tester/.config/workbenches "$CASE_DIR/old-config" true ""
assert_bind /home/tester/.local/lib/workbenches "$CASE_DIR/old-lib" true ""
assert_bind /home/tester/.local/state/workbenches "$CASE_DIR/old-state" false cached
echo "PASS: interrupted-publication-keeps-complete-old-set"

prepare_case concurrent-publication
mkdir -p \
    "$CASE_DIR/a-config" "$CASE_DIR/a-lib" "$CASE_DIR/a-state" \
    "$CASE_DIR/b-config" "$CASE_DIR/b-lib" "$CASE_DIR/b-state"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/a-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/a-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/a-state"
cp "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" "$CASE_DIR/a.yml"
run_resolver \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/b-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/b-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/b-state"
cp "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" "$CASE_DIR/b.yml"
mkdir -p "$CASE_DIR/mockbin"
cat > "$CASE_DIR/mockbin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.02
exec "${REAL_MV:?}" "$@"
EOF
chmod +x "$CASE_DIR/mockbin/mv"
for _ in 1 2 3 4 5; do
    run_resolver \
        PATH="$CASE_DIR/mockbin:$PATH" REAL_MV="$REAL_MV" \
        "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/a-config" \
        "OPENBENCHES_LIB_ROOT=$CASE_DIR/a-lib" \
        "OPENBENCHES_STATE_ROOT=$CASE_DIR/a-state" \
        > "$CASE_DIR/a.out" 2> "$CASE_DIR/a.err" &
    pid_a=$!
    run_resolver \
        PATH="$CASE_DIR/mockbin:$PATH" REAL_MV="$REAL_MV" \
        "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/b-config" \
        "OPENBENCHES_LIB_ROOT=$CASE_DIR/b-lib" \
        "OPENBENCHES_STATE_ROOT=$CASE_DIR/b-state" \
        > "$CASE_DIR/b.out" 2> "$CASE_DIR/b.err" &
    pid_b=$!
    status=0
    wait "$pid_a" || status=1
    wait "$pid_b" || status=1
    [[ "$status" == 0 ]] || fail "concurrent resolver invocation failed"
    if ! cmp -s "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" "$CASE_DIR/a.yml" \
        && ! cmp -s "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" "$CASE_DIR/b.yml"; then
        fail "concurrent publication exposed a mixed config/lib/state set"
    fi
done
render_config
assert_history
echo "PASS: concurrent-publication-is-serialized-and-coherent"

sed '/^[[:space:]]*\/\//d' "$DEVCONTAINER_FILE" > "$TMP_ROOT/devcontainer.json"
jq -e '
    (.dockerComposeFile == [
        "docker-compose.yml",
        ".openbenches-mounts/docker-compose.yml",
        "docker-compose.amd-rocm.generated.yml"
    ])
    and (.initializeCommand | contains("scripts/prepare-openbenches-mounts.sh"))
    and ([.mounts[] | select(contains("/.openbenches-mounts/"))] | length == 0)
' "$TMP_ROOT/devcontainer.json" >/dev/null \
    || fail "devcontainer.json does not use the generated mount selection"
echo "PASS: devcontainer-json"

prepare_case "devcontainer workspace with spaces"
write_log_stub "$CASE_REPO/scripts/configure-amd-rocm-wsl.sh"
write_log_stub "$CASE_REPO/scripts/ensure-images.sh"
write_log_stub "$CASE_DIR/scripts/ensure-sonarqube-mcp.sh"
write_log_stub "$TMP_ROOT/scripts/reconcile-devcontainer-container.sh"
: > "$CASE_DIR/initialize.log"
initialize_command="$(jq -r '.initializeCommand' "$TMP_ROOT/devcontainer.json")"
initialize_command="${initialize_command//\$\{localWorkspaceFolder\}/$CASE_REPO}"
initialize_command="${initialize_command//\$\{localEnv:USER\}/tester}"
(
    cd "$CASE_REPO"
    "${CLEAN_ENV[@]}" HOME="$CASE_HOME" USER=tester \
        STUB_LOG="$CASE_DIR/initialize.log" \
        bash -c "$initialize_command"
)
mapfile -t initialize_log < "$CASE_DIR/initialize.log"
[[ "${#initialize_log[@]}" == 4 ]] \
    || fail "devcontainer initialization did not run every staged command"
[[ "${initialize_log[0]}" == "configure-amd-rocm-wsl.sh" \
    && "${initialize_log[1]}" == "ensure-sonarqube-mcp.sh" \
    && "${initialize_log[2]}" == "ensure-images.sh --user tester" \
    && "${initialize_log[3]}" == "reconcile-devcontainer-container.sh --container py-bench --image py-bench:tester" ]] \
    || fail "devcontainer initialization order or arguments changed"
[[ -f "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" ]] \
    || fail "devcontainer initialization did not publish its mount selection"
echo "PASS: devcontainer-initialize-command-with-workspace-spaces"

prepare_entrypoint_case setup-entrypoint
touch "$CASE_HOME/.gitconfig"
write_log_stub "$TMP_ROOT/scripts/ensure-layer3.sh"
run_setup_entrypoint
assert_compose_invocations "$CASE_DIR/docker-compose.log" 1 ""
[[ -f "$CASE_REPO/.devcontainer/.openbenches-mounts/docker-compose.yml" ]] \
    || fail "setup did not prepare the selected mounts"
echo "PASS: setup-entrypoint-uses-selection-without-forced-recreation"

prepare_entrypoint_case start-monster-entrypoint
mkdir -p \
    "$CASE_DIR/old-config" "$CASE_DIR/old-lib" "$CASE_DIR/old-state" \
    "$CASE_DIR/new-config" "$CASE_DIR/new-lib" "$CASE_DIR/new-state"
run_start_entrypoint \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/old-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/old-state"
start_hash_old="$(compose_hash)"
run_start_entrypoint \
    "WORKBENCHES_CONFIG_ROOT=$CASE_DIR/old-config" \
    "WORKBENCHES_LIB_ROOT=$CASE_DIR/old-lib" \
    "WORKBENCHES_STATE_ROOT=$CASE_DIR/old-state"
[[ "$(compose_hash)" == "$start_hash_old" ]] \
    || fail "unchanged start-monster roots changed the service hash"
run_start_entrypoint \
    "OPENBENCHES_CONFIG_ROOT=$CASE_DIR/new-config" \
    "OPENBENCHES_LIB_ROOT=$CASE_DIR/new-lib" \
    "OPENBENCHES_STATE_ROOT=$CASE_DIR/new-state"
[[ "$(compose_hash)" != "$start_hash_old" ]] \
    || fail "start-monster did not publish changed roots for Compose recreation"
assert_compose_invocations "$CASE_DIR/docker-compose.log" 3 " --build"
echo "PASS: start-monster-recreates-only-on-selection-change"

echo "pyBench openBenches mount compatibility tests passed"
