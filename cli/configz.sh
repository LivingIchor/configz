#!/usr/bin/env bash
# configz — cli to interact with configzd, a server wrapper that automatically
# manages dotfiles using a bare git repo.
#
# Usage:
#     configz                         — Show status of tracked dotfile changes
#     configz log                     — Show recent commit history
#     configz sync                    — Commit and push all tracked changes
#     configz pull                    — Pull latest changes from remote
#     configz fetch                   — Fetch latest changes from remote without merging
#     configz init <remote>           — Initialize bare repo and set remote
#     configz git -- <args>           — Pass commands directly to git
#     configz diff <file|all>         — Show unstaged changes for a file or all tracked files
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

function header  { echo -e "\n${BLU}${BLD}==> $*${RST}"; }
function info    { echo -e "  ${CYN}->${RST} $*"; }
function warn    { echo -e "  ${YLW}!${RST}  $*"; }
function die     { echo -e "\n${RED}configz: $*${RST}\n" >&2; exit 1; }
function debug { if [[ "${CONFIGZ_DEBUG:-0}" == "1" ]]; then echo "  [DEBUG] $*"; fi; }

function require {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
    done
}


# ── Commands ──────────────────────────────────────────────────────────────────

# Sends a status request to configzd and prints the current state of tracked files
function cmd_status {
    local payload response ok
    payload=$(jq -n '{"cmd": "status"}')

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

# Sends a log request to configzd and prints recent dotfile commit history
function cmd_log {
    local payload response ok
    payload=$(jq -n '{"cmd": "log"}')

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
        payload=$(jq -n \
            --arg subject "$subject" \
            --arg body "$body" \
            '{"cmd": "sync", "args": {"subject": $subject, "body": $body}}')
    else
        payload=$(jq -n \
            --arg subject "$subject" \
            '{"cmd": "sync", "args": {"subject": $subject}}')
    fi

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "${GRN}Sync successful${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Pulls the latest changes from remote and merges them into the working tree
function cmd_pull {
    local payload response ok
    payload=$(jq -n '{"cmd": "pull"}')

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "${GRN}Successfully updated from remote${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Fetches latest changes from remote without merging into the working tree
function cmd_fetch {
    local payload response ok
    payload=$(jq -n '{"cmd": "fetch"}')

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

# Initializes a new bare repo at the default location and sets the given remote
function cmd_init {
    [[ $# -gt 0 ]] || die "usage: configz init <remote>"

    local payload response ok
    payload=$(jq -n \
        --arg remote "$1" \
        '{"cmd": "init", "args": {"remote": $remote}}')

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "${GRN}Successfully initialized${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "$(echo "$response" | jq -r '.output')"
    else
        die "Malformed response from configzd"
    fi
}

# Passes arguments directly to git, allowing full access to git's command set
function cmd_git {
    local payload response ok
    payload=$(jq -n \
        --args '{"cmd": "git", "args": $ARGS.positional}' \
        -- "$@")

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

# Shows unstaged changes for a specific file or all tracked files if 'all' is given
function cmd_diff {
    local payload response ok
    payload=$(jq -n \
        --args '{"cmd": "diff", "args": $ARGS.positional}' \
        -- "$@")

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

# Begins tracking one or more files by adding them to the bare repo
function cmd_add {
    [[ $# -gt 0 ]] || die "usage: configz add <file> [file...]"

    local payload response ok
    payload=$(jq -n \
        --args '{"cmd": "add", "files": $ARGS.positional}' \
        -- "$@")

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "${GRN}Successfully added files${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "some files failed to add:"$'\n'"$(echo "$response" | jq -r '.output[] | "\(.file): \(.reason)"')"
    else
        die "Malformed response from configzd"
    fi
}

# Stops tracking one or more files by removing them from the bare repo
function cmd_drop {
    [[ $# -gt 0 ]] || die "usage: configz drop <file> [file...]"

    local payload response ok
    payload=$(jq -n \
        --args '{"cmd": "drop", "files": $ARGS.positional}' \
        -- "$@")

    response=$(echo "$payload" | socat - UNIX-CONNECT:"$SOCK")
    ok=$(echo "$response" | jq -r '.ok')

    if [[ "$ok" == "true" ]]; then
        echo "${GRN}Successfully dropped files${RST}"
    elif [[ "$ok" == "false" ]]; then
        die "some files failed to be dropped:"$'\n'"$(echo "$response" | jq -r '.output[] | "\(.file): \(.reason)"')"
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
    echo "    configz log                    — Show recent commit history"
    echo "    configz sync                   — Commit and push all tracked changes"
    echo "        -m <message>                   — Attach a commit message"
    echo "    configz pull                   — Pull latest changes from remote"
    echo "    configz fetch                  — Fetch latest changes from remote"
    echo "    configz init <remote>          — Initialize bare repo and set remote"
    echo "    configz git -- <args>          — Pass commands directly to git"
    echo "    configz diff <file|all>        — Show unstaged changes for a file or all"
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
    log)
        shift; cmd_log "$@"
        ;;
    sync)
        shift; cmd_sync "$@"
        ;;
    pull)
        shift; cmd_pull "$@"
        ;;
    fetch)
        shift; cmd_fetch "$@"
        ;;
    add)
        shift; cmd_add "$@"
        ;;
    drop)
        shift; cmd_drop "$@"
        ;;
    init)
        shift; cmd_init "$@"
        ;;
    git)
        shift
        [[ $# -gt 0 && "$1" == "--" ]] || die "expected '--' before git arguments"$'\n'"Usage: configz git -- <args>"
        shift
        cmd_git "$@"
        ;;
    diff)
        shift; cmd_diff "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        die "unknown command '$1'"$'\n'"Try 'configz help' for a list of commands."
        ;;
esac
