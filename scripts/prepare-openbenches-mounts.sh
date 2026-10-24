#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOUNT_DIR="${1:-$BENCH_DIR/.devcontainer/.openbenches-mounts}"

[[ -n "${HOME:-}" ]] || {
    echo "HOME must be set to resolve openBenches mounts" >&2
    exit 1
}

normalize_root() {
    local value="$1"
    while [[ "$value" != "/" && "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "$value"
}

resolve_root() {
    local label="$1"
    local legacy_root="$2"
    local open_root="$3"
    local new_name="OPENBENCHES_${label}_ROOT"
    local old_name="WORKBENCHES_${label}_ROOT"
    local new_value="${!new_name:-}"
    local old_value="${!old_name:-}"
    local selected

    if [[ -n "$new_value" && "$new_value" != /* ]]; then
        echo "$new_name must be an absolute path" >&2
        return 1
    fi
    if [[ -n "$old_value" && "$old_value" != /* ]]; then
        echo "$old_name must be an absolute path" >&2
        return 1
    fi
    if [[ -n "$new_value" ]]; then
        new_value="$(normalize_root "$new_value")"
    fi
    if [[ -n "$old_value" ]]; then
        old_value="$(normalize_root "$old_value")"
    fi

    if [[ -n "$new_value" && -n "$old_value" ]]; then
        if [[ "$new_value" != "$old_value" ]]; then
            echo "$new_name and $old_name conflict; set only one or use the same path" >&2
            return 1
        fi
        selected="$new_value"
    elif [[ -n "$new_value" ]]; then
        selected="$new_value"
    elif [[ -n "$old_value" ]]; then
        selected="$old_value"
    elif [[ -d "$open_root" ]]; then
        selected="$open_root"
    elif [[ -d "$legacy_root" ]]; then
        selected="$legacy_root"
    else
        selected="$legacy_root"
    fi

    printf '%s\n' "$selected"
}

config_root="$(resolve_root CONFIG "$HOME/.config/workbenches" "$HOME/.config/openbenches")"
lib_root="$(resolve_root LIB "$HOME/.local/lib/workbenches" "$HOME/.local/lib/openbenches")"
state_root="$(resolve_root STATE "$HOME/.local/state/workbenches" "$HOME/.local/state/openbenches")"

mkdir -p "$MOUNT_DIR"

for name in config lib state; do
    if [[ -e "$MOUNT_DIR/$name" && ! -L "$MOUNT_DIR/$name" ]]; then
        echo "refusing to replace non-symlink mount path: $MOUNT_DIR/$name" >&2
        exit 1
    fi
done

link_root() {
    local name="$1"
    local selected="$2"
    ln -sfn "$selected" "$MOUNT_DIR/$name"
}

link_root config "$config_root"
link_root lib "$lib_root"
link_root state "$state_root"
