#!/usr/bin/env bash
# configz — cli to interact with configzd, a server wrapper that automatically
# manages dotfiles using a bare git repo.
#
# Usage:
#     configz                         — Show status of tracked dotfile changes
#     configz sync                    — Commit and push all tracked changes
#     configz purge                   — Permanently delete the local repo and all data"
#     configz init <remote>           — Initialize bare repo and set remote
#     configz git -- <args>           — Pass commands directly to git
#     configz add <file> [file...]    — Begin tracking a file
#     configz drop <file> [file...]   — Stop tracking a file

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

# Ansi color formaters
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

function header  { echo -e "${BLU}${BLD}==> $*${RST}"; }
function info    { echo -e "  ${CYN}->${RST} $*"; }
function warn    { echo -e "  ${YLW}!${RST}  $*"; }
function die     { echo -e "${RED}configz: $*${RST}" >&2; exit 1; }
function debug { if [[ "${CONFIGZ_DEBUG:-0}" == "1" ]]; then echo "  [DEBUG] $*"; fi; }

function require {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
    done
}

# Resolves a path to be relative to $HOME, errors if outside home
function resolve_path {
    local path="$1"
    # Make absolute if relative
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    # Normalize the path
    path="$(realpath -m "$path")"
    # Check if it's inside HOME
    if [[ "$path" != "$HOME"/* ]]; then
        die "file must be inside home directory: $path"
    fi
    # Make relative to HOME
    echo "${path#"$HOME"/}"
}


# ── Commands ──────────────────────────────────────────────────────────────────

# Sends a status request to configzd and prints the current state of tracked files
function cmd_status {
    local payload response ok
    payload=$(jq -cn '{"cmd": "status", "args": []}')

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "$response" | jq -r '.output'
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Commits all tracked changes and pushes to remote with an auto-generated timestamp
# subject. Accepts an optional -m flag to attach a body to the commit message
function cmd_sync {
    local subject body
    subject="$(date '+%Y-%m-%d %H:%M:%S') — sync"
    body=""
    while getopts ":m:" opt; do
        case "$opt" in
            m) body="$OPTARG" ;;
            :) die "option -$OPTARG requires an argument" ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local payload response ok
    if [[ -n "$body" ]]; then
        payload=$(jq -cn \
            --arg subject "$subject" \
            --arg body "$body" \
            '{"cmd": "sync", "args": [$subject, $body]}')
    else
        payload=$(jq -cn \
            --arg subject "$subject" \
            '{"cmd": "sync", "args": [$subject]}')
    fi

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo -e "${GRN}Sync successful${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Permanently deletes the local bare repo and all configz data
function cmd_purge {
    printf "Are you sure? ${RED}(Any changes not pushed will be lost forever)${RST}\n[YES]: "
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Purge cancelled."
        return 0
    fi

    pkill -TERM configzd || true
    rm -f "$XDG_RUNTIME_DIR/configz.sock"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/configz"
    echo -e "${GRN}Local repo purged successfully${RST}"
}

# Initializes a new bare repo at the default location and sets the given remote
function cmd_init {
    [[ $# -gt 0 ]] || die "usage: configz init <remote>"

    local payload response ok
    payload=$(jq -cn \
        --arg remote "$1" \
        '{"cmd": "init", "args": [$remote]}')

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo -e "${GRN}Successfully initialized${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Passes arguments directly to git, allowing full access to git's command set
function cmd_git {
    local payload response ok
    payload=$(jq -cn \
        --args '{"cmd": "git", "args": $ARGS.positional}' \
        -- "$@")

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        printf '%s' "$(echo "$response" | jq -r '.output.out')"
        printf '%s' "$(echo "$response" | jq -r '.output.err')" 1>&2
    else
        die "Malformed response from configzd"
    fi
}

# Begins tracking one or more files by adding them to the bare repo
function cmd_add {
    [[ $# -gt 0 ]] || die "usage: configz add <file> [file...]"

    local resolved=()
    for f in "$@"; do
        resolved+=("$(resolve_path "$f")")
    done

    local payload response ok
    payload=$(jq -cn \
        --args '{"cmd": "add", "args": $ARGS.positional}' \
        -- "${resolved[@]}")

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo -e "${GRN}Successfully added files${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Stops tracking one or more files by removing them from the bare repo
function cmd_drop {
    [[ $# -gt 0 ]] || die "usage: configz drop <file> [file...]"

    local resolved=()
    for f in "$@"; do
        resolved+=("$(resolve_path "$f")")
    done

    local payload response ok
    payload=$(jq -cn \
        --args '{"cmd": "drop", "args": $ARGS.positional}' \
        -- "${resolved[@]}")

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo -e "${GRN}Successfully dropped files${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}


# ── Print Usage ───────────────────────────────────────────────────────────────

function show_help {
    echo "Usage: configz [log|sync|pull|add|drop|init|git|diff]"
    echo
    echo "Commands:"
    echo "    configz                        — Show status of tracked dotfile changes"
    echo "    configz sync                   — Commit and push all tracked changes"
    echo "        -m <message>                   — Attach a commit message"
    echo "    configz purge                  — Permanently delete the local repo and all data"
    echo "    configz init <remote>          — Initialize bare repo and set remote"
    echo "    configz git -- <args>          — Pass commands directly to git"
    echo "    configz add <file> [file...]   — Begin tracking a file"
    echo "    configz drop <file> [file...]  — Stop tracking a file"
}


# ── Entrypoint ────────────────────────────────────────────────────────────────

require socat jq

[[ -n "$XDG_RUNTIME_DIR" ]] || die "XDG_RUNTIME_DIR is not set"
SOCK="$XDG_RUNTIME_DIR/configz.sock"

case "${1:-}" in
    ""|status)
        cmd_status
        ;;
    sync)
        shift; cmd_sync "$@"
        ;;
    purge)
        shift; cmd_purge "$@"
        ;;
    init)
        shift; cmd_init "$@"
        ;;
    git)
        shift
        if [[ $# -eq 0 || "$1" != "--" ]]; then
            die "expected '--' before git arguments"$'\n'"Usage: configz git -- <args>"
        fi
        shift
        cmd_git "$@"
        ;;
    add)
        shift; cmd_add "$@"
        ;;
    drop)
        shift; cmd_drop "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        die "unknown command '$1'"$'\n'"Try 'configz help' for a list of commands."
        ;;
esac
