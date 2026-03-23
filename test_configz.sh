#!/usr/bin/env bash
# Integration test suite for configz/configzd
# Usage: ./test_configz.sh [path/to/configzd] [path/to/configz.sh]

set -uo pipefail

CONFIGZD="${1:-./zig-out/bin/configzd}"
CONFIGZ="${2:-./cli/configz.sh}"

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GRN='\033[0;32m'
BLU='\033[0;34m'
BLD='\033[1m'
RST='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
CONFIGZD_PID=""
TEST_HOME=""

# ── Assertions ────────────────────────────────────────────────────────────────

function pass { echo -e "  ${GRN}✓${RST} $*"; ((PASS++)) || true; }
function fail { echo -e "  ${RED}✗${RST} $*"; ((FAIL++)) || true; }
function header { echo -e "\n${BLU}${BLD}==> $*${RST}"; }
function die { echo -e "${RED}FATAL: $*${RST}" >&2; cleanup; exit 1; }

function assert_eq {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected' got='$actual')"
    fi
}

function assert_contains {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc"
        echo "    expected to contain: $needle"
        echo "    got: $haystack"
    fi
}

function assert_not_contains {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc (should not contain '$needle')"
    fi
}

function assert_file_exists {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then pass "$desc"
    else fail "$desc (not found: $path)"; fi
}

# ── Daemon management ─────────────────────────────────────────────────────────

function start_daemon {
    rm -f "$SOCK"

    HOME="$TEST_HOME" \
    XDG_RUNTIME_DIR="$TEST_RUNTIME" \
    XDG_DATA_HOME="$TEST_DATA" \
    GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" \
        "$CONFIGZD" 2>>"$TEST_HOME/daemon.log" &
    CONFIGZD_PID=$!

    # Wait for socket file to appear
    local attempts=0
    while [[ ! -S "$SOCK" ]]; do
        sleep 0.1
        ((attempts++)) || true
        if [[ $attempts -gt 50 ]]; then
            echo "daemon log:" >&2
            cat "$TEST_HOME/daemon.log" >&2
            die "configzd socket never appeared at $SOCK"
        fi
    done
}

function stop_daemon {
    if [[ -n "$CONFIGZD_PID" ]]; then
        kill "$CONFIGZD_PID" 2>/dev/null || true
        wait "$CONFIGZD_PID" 2>/dev/null || true
        CONFIGZD_PID=""
    fi
    rm -f "$SOCK"
}

function cleanup {
    stop_daemon
    [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
    [[ -n "${REMOTE_REPO:-}" && -d "${REMOTE_REPO:-}" ]] && rm -rf "$REMOTE_REPO"
}

trap cleanup EXIT

function cz {
    HOME="$TEST_HOME" \
    XDG_RUNTIME_DIR="$TEST_RUNTIME" \
    GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" \
        "$CONFIGZ" "$@"
}

# ── Setup ─────────────────────────────────────────────────────────────────────

[[ -x "$CONFIGZD" ]] || die "configzd not found or not executable: $CONFIGZD"
[[ -x "$CONFIGZ" ]]  || die "configz not found or not executable: $CONFIGZ"
command -v socat &>/dev/null || die "socat not found"
command -v jq &>/dev/null    || die "jq not found"
command -v git &>/dev/null   || die "git not found"

TEST_HOME="$(mktemp -d)"
TEST_RUNTIME="$TEST_HOME/.runtime"
TEST_DATA="$TEST_HOME/.local/share"
SOCK="$TEST_RUNTIME/configz.sock"
mkdir -p "$TEST_RUNTIME" "$TEST_DATA"

# Git identity required for sync
cat > "$TEST_HOME/.gitconfig" <<EOF
[user]
    name = Test User
    email = test@example.com
EOF

# Bare remote repo to push to
REMOTE_REPO="$(mktemp -d)"
git init --bare "$REMOTE_REPO" -q

# Test files
mkdir -p "$TEST_HOME/.config/test"
echo "hello"   > "$TEST_HOME/.config/test/file1.txt"
echo "world"   > "$TEST_HOME/.config/test/file2.txt"
echo "dotfile" > "$TEST_HOME/.testrc"
mkdir -p "$TEST_HOME/scripts"
echo "#!/bin/sh" > "$TEST_HOME/scripts/myscript.sh"
chmod +x "$TEST_HOME/scripts/myscript.sh"

# ── Tests ─────────────────────────────────────────────────────────────────────

header "Pre-init: commands fail without a repo"
start_daemon

output=$(cz status 2>&1 || true)
assert_contains "status fails before init" "repo not initialized" "$output"

output=$(cz add "$TEST_HOME/.testrc" 2>&1 || true)
assert_contains "add fails before init" "repo not initialized" "$output"

# ── Init ──────────────────────────────────────────────────────────────────────

header "Init"

output=$(cz init "$REMOTE_REPO" 2>&1)
assert_contains "init succeeds" "Successfully initialized" "$output"

assert_file_exists "repo directory created" "$TEST_DATA/configz"

output=$(cz init "$REMOTE_REPO" 2>&1 || true)
assert_contains "double init fails" "repo already initialized" "$output"

sleep 0.3

# ── Status ────────────────────────────────────────────────────────────────────

header "Status (fresh repo)"

output=$(cz status 2>&1)
assert_contains "status works after init" "nothing to commit" "$output"

# ── Add ───────────────────────────────────────────────────────────────────────

header "Add files"

output=$(cz add "$TEST_HOME/.testrc" 2>&1)
assert_contains "add single file succeeds" "Successfully added" "$output"

output=$(cz git -- status 2>&1)
assert_contains "added file is staged" ".testrc" "$output"

output=$(cz add "$TEST_HOME/.config/test/file1.txt" "$TEST_HOME/.config/test/file2.txt" 2>&1)
assert_contains "add multiple files succeeds" "Successfully added" "$output"

output=$(cz git -- status 2>&1)
assert_contains "first file staged" "file1.txt" "$output"
assert_contains "second file staged" "file2.txt" "$output"

output=$(cz add "$TEST_HOME/scripts" 2>&1)
assert_contains "add directory succeeds" "Successfully added" "$output"

output=$(cz git -- status 2>&1)
assert_contains "directory contents staged" "myscript.sh" "$output"

# ── Status with staged files ──────────────────────────────────────────────────

header "Status with staged files"

output=$(cz status 2>&1)
assert_contains "status shows staged files" "testrc" "$output"

# ── Sync ──────────────────────────────────────────────────────────────────────

header "Sync"

output=$(cz sync 2>&1)
assert_contains "sync succeeds" "Sync successful" "$output"

commit_count=$(git -C "$REMOTE_REPO" log --oneline 2>/dev/null | wc -l | tr -d ' ')
assert_eq "commit pushed to remote" "1" "$commit_count"

output=$(cz sync -m "test body" 2>&1)
assert_contains "sync with message succeeds" "Sync successful" "$output"

commit_count=$(git -C "$REMOTE_REPO" log --oneline 2>/dev/null | wc -l | tr -d ' ')
assert_eq "second commit pushed to remote" "2" "$commit_count"

# ── Auto-tracking ─────────────────────────────────────────────────────────────

header "Auto-tracking file changes"

echo "updated content" > "$TEST_HOME/.config/test/file1.txt"
sleep 0.5

output=$(cz git -- status 2>&1)
assert_contains "modified file detected" "modified" "$output"
assert_contains "correct file detected as modified" "file1.txt" "$output"

# ── Drop ──────────────────────────────────────────────────────────────────────

header "Drop files"

output=$(cz drop "$TEST_HOME/.testrc" 2>&1)
assert_contains "drop single file succeeds" "Successfully dropped" "$output"

sleep 0.3

output=$(cz git -- diff --cached --name-only 2>&1)
assert_contains "dropped file staged for deletion" ".testrc" "$output"

output=$(cz git -- status 2>&1)
assert_contains "dropped file shows as deleted" "deleted" "$output"

# ── Post-drop sync ────────────────────────────────────────────────────────────

header "Post-drop sync"

output=$(cz sync 2>&1)
assert_contains "sync after drop succeeds" "Sync successful" "$output"

output=$(cz git -- diff --cached --name-only 2>&1)
assert_not_contains "dropped file gone after sync" ".testrc" "$output"

# ── Git passthrough ───────────────────────────────────────────────────────────

header "Git passthrough"

output=$(cz git -- log --oneline 2>&1)
assert_contains "git log shows commits" "sync" "$output"

output=$(cz git -- branch 2>&1)
assert_contains "git branch shows master" "master" "$output"

# ── Watch state persists across restart ───────────────────────────────────────

header "Watch state persists across restart"

stop_daemon
start_daemon
sleep 0.3

assert_file_exists "watched_dirs file exists after restart" "$TEST_DATA/configz/watched_dirs"

echo "after restart" > "$TEST_HOME/scripts/myscript.sh"
sleep 0.5

output=$(cz git -- status 2>&1)
assert_contains "file change detected after restart" "myscript.sh" "$output"

# ── Error handling ────────────────────────────────────────────────────────────

header "Error handling"

output=$(cz add 2>&1 || true)
assert_contains "add requires arguments" "Usage: configz add" "$output"

output=$(cz drop 2>&1 || true)
assert_contains "drop requires arguments" "Usage: configz drop" "$output"

output=$(cz add "/etc/passwd" 2>&1 || true)
assert_contains "add outside home fails" "home directory" "$output"

output=$(cz git -- 2>&1 || true)
assert_contains "git requires -- separator" "Usage: configz git" "$output"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BLD}Results: ${GRN}${PASS} passed${RST}${BLD}, ${RED}${FAIL} failed${RST}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "Daemon log:"
    cat "$TEST_HOME/daemon.log" 2>/dev/null || true
fi

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
