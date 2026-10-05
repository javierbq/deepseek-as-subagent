#!/usr/bin/env bash
# install.sh — One-click installer for deepseek-mcp to Claude Code.
# Cross-platform: macOS / Linux (zsh|bash) + Windows Git Bash / MINGW64.
# Idempotent: safe to run repeatedly.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="$PROJECT_ROOT/requirements.lock"
PATH_GUARD="$PROJECT_ROOT/scripts/installer_path_guard.py"
CLAUDE_HELPERS="$PROJECT_ROOT/scripts/claude_helpers.sh"
CONFIG_DIR="$HOME/.deepseek-mcp"
CONFIG_FILE="$CONFIG_DIR/config.json"
VENV_ROOT="$CONFIG_DIR/claude-venvs"
LEGACY_VENV="$PROJECT_ROOT/.venv"
INSTALL_LOCK="$CONFIG_DIR/claude-install.lock"
CLAUDE_SKILLS="$HOME/.claude/skills"
CLAUDE_COMMANDS="$HOME/.claude/commands"
CLAUDE_BIN="${DEEPSEEK_CLAUDE_BIN:-claude}"

echo "▶ deepseek-mcp installer"
echo "  project: $PROJECT_ROOT"
echo ""

# ===== Platform Detection =====
case "$(uname -s 2>/dev/null)" in
    Linux*)               PLATFORM=linux ;;
    Darwin*)              PLATFORM=macos ;;
    MINGW*|CYGWIN*|MSYS*) PLATFORM=windows ;;
    *)                    PLATFORM=unknown ;;
esac
echo "  platform: $PLATFORM"
echo ""

# ===== Step 0: Find supported installed Python =====
PYTHON_CMD=""
supported_python() {
    "$@" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] < (3, 13) else 1)' \
        >/dev/null 2>&1
}

find_python() {
    local candidate version
    for candidate in python3.12 python3.11 python3.10 python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 && supported_python "$candidate"; then
            PYTHON_CMD="$candidate"
            return 0
        fi
    done
    if command -v py >/dev/null 2>&1; then
        for version in -3.12 -3.11 -3.10; do
            if supported_python py "$version"; then
                PYTHON_CMD="py $version"
                return 0
            fi
        done
    fi
    return 1
}

if ! find_python; then
    echo "✗ PATH does not contain a supported Python 3.10–3.12."
    echo "  Please install Python 3.12 from https://www.python.org/downloads/ and retry."
    echo "  This installer does not download or execute remote bootstrap scripts."
    exit 1
else
    echo "  Python: $($PYTHON_CMD --version) (using '$PYTHON_CMD')"
fi
if [ ! -r "$LOCK_FILE" ]; then
    echo "✗ Missing dependency lock: $LOCK_FILE"
    exit 1
fi
if [ ! -r "$CLAUDE_HELPERS" ]; then
    echo "✗ Missing Claude helper deployment script: $CLAUDE_HELPERS" >&2
    exit 1
fi
. "$CLAUDE_HELPERS"
echo ""

normalize_command() {
    local converted=""
    if [ "$PLATFORM" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
        converted="$(cygpath -u "$1" 2>/dev/null || true)"
    fi
    if [ -n "$converted" ]; then
        printf '%s' "$converted"
    else
        printf '%s' "$1"
    fi
}

same_command_path() {
    [ "$(normalize_command "$1")" = "$(normalize_command "$2")" ]
}

is_managed_registration() {
    local candidate relative generation suffix token first
    candidate="$(normalize_command "$1")"
    case "$candidate" in
        "$LEGACY_VENV/bin/deepseek-mcp"|"$LEGACY_VENV/bin/deepseek-mcp.exe"|\
        "$LEGACY_VENV/Scripts/deepseek-mcp"|"$LEGACY_VENV/Scripts/deepseek-mcp.exe")
            return 0
            ;;
        "$VENV_ROOT"/*) relative="${candidate#"$VENV_ROOT"/}" ;;
        *) return 1 ;;
    esac
    generation="${relative%%/*}"
    suffix="${relative#*/}"
    [ "$generation/$suffix" = "$relative" ] || return 1
    case "$suffix" in
        bin/deepseek-mcp|bin/deepseek-mcp.exe|\
        Scripts/deepseek-mcp|Scripts/deepseek-mcp.exe) ;;
        *) return 1 ;;
    esac
    case "$generation" in generation.*) token="${generation#generation.}" ;; *) return 1 ;; esac
    [ -n "$token" ] && [ "${#token}" -le 128 ] || return 1
    case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    first="${token%"${token#?}"}"
    case "$first" in [A-Za-z0-9]) return 0 ;; *) return 1 ;; esac
}

registration_snapshot() {
    local details="" command="" custom="" listing=""
    if details="$("$CLAUDE_BIN" mcp get deepseek 2>/dev/null)"; then
        command="$(printf '%s\n' "$details" | sed -n 's/^  Command: //p' | tr -d '\r')"
        custom="$(printf '%s\n' "$details" | sed -n -e 's/^  Args: //p' \
            -e '/^  Environment:$/,/^$/ { /^    /p; }')"
        [ -n "$command" ] && [ -z "$custom" ] \
            && printf '%s\n' "$details" | grep -q '^  Scope: User' \
            && printf '%s\n' "$details" | grep -q '^  Type: stdio$' \
            && is_managed_registration "$command" || return 1
        printf 'present:%s' "$command"
        return 0
    fi
    listing="$("$CLAUDE_BIN" mcp list 2>/dev/null)" || return 1
    printf '%s\n' "$listing" | grep -q '^deepseek:' && return 1
    printf 'absent'
}

registration_matches_expected() {
    local expected="$1" snapshot="" current=""
    snapshot="$(registration_snapshot)" || return 1
    if [ -z "$expected" ]; then
        [ "$snapshot" = "absent" ] || return 1
        return 0
    fi
    case "$snapshot" in present:*) current="${snapshot#present:}" ;; *) return 1 ;; esac
    same_command_path "$current" "$expected"
}

$PYTHON_CMD "$PATH_GUARD" prepare-dirs "$CONFIG_DIR" "$VENV_ROOT"
$PYTHON_CMD "$PATH_GUARD" secure-files "$CONFIG_FILE"

GENERATION_DIR="" INSTALL_SUCCEEDED=0 REGISTRATION_TRANSACTION=0 PRESERVE_GENERATION=0 LOCK_HELD=0 CLAUDE_AVAILABLE=0 REGISTERED_COMMAND=""

cleanup_generation() {
    [ -n "$GENERATION_DIR" ] || return 0
    if ! $PYTHON_CMD "$PATH_GUARD" delete-generation \
        "$VENV_ROOT" "$GENERATION_DIR"; then
        echo "warning: unable to safely clean incomplete runtime: $GENERATION_DIR" >&2
    fi
}

release_install_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        if ! rmdir "$INSTALL_LOCK"; then
            echo "warning: unable to release install lock: $INSTALL_LOCK" >&2
        fi
        LOCK_HELD=0
    fi
}

on_exit() {
    local exit_code=$?
    if [ "$HELPER_TRANSACTION" -eq 1 ]; then
        trap '' INT TERM HUP
        rollback_helper_transaction \
            || echo "warning: helper recovery incomplete after interrupted install; see paths above." >&2
    fi
    if [ "$REGISTRATION_TRANSACTION" -eq 1 ]; then
        REGISTRATION_TRANSACTION=0
        trap '' INT TERM HUP
        echo "  Restoring Claude MCP registration..." >&2
        if ! restore_registration "$REGISTERED_COMMAND"; then
            PRESERVE_GENERATION=1
            echo "✗ Registration recovery failed; retaining candidate runtime: $GENERATION_DIR" >&2
        fi
    fi
    if [ "$INSTALL_SUCCEEDED" -ne 1 ] && [ "$PRESERVE_GENERATION" -ne 1 ]; then
        cleanup_generation
    fi
    release_install_lock
    return "$exit_code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# mkdir is an atomic, cross-process mutex on every supported platform.  A
# process killed with SIGKILL intentionally leaves the directory behind so the
# next installer fails closed instead of guessing whether pruning is safe.
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
    echo "✗ Another install/uninstall transaction is running, or a previous run left an unreleased lock:" >&2
    echo "  $INSTALL_LOCK" >&2
    echo "  Verify that no install.sh/uninstall.sh is running before manually removing this empty directory." >&2
    exit 1
fi
LOCK_HELD=1

# Snapshot the existing registration only after taking the lease.  An
# unparseable or foreign registration is never overwritten.
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    CLAUDE_AVAILABLE=1
    REGISTERED_SNAPSHOT="$(registration_snapshot)" || {
        echo "✗ deepseek MCP registration exists but is not owned by this installer, or cannot be safely parsed." >&2
        echo "  To avoid overwriting user configuration, installation has been aborted." >&2
        exit 1
    }
    case "$REGISTERED_SNAPSHOT" in
        present:*) REGISTERED_COMMAND="${REGISTERED_SNAPSHOT#present:}" ;;
        absent) REGISTERED_COMMAND="" ;;
        *) echo "✗ Unable to read deepseek MCP registration." >&2; exit 1 ;;
    esac
fi

GENERATION_DIR="$(mktemp -d "$VENV_ROOT/generation.XXXXXX")"
case "$PLATFORM" in
    windows) ;;
    *) chmod 700 "$GENERATION_DIR" ;;
esac

# ===== Step 1: Create isolated generation =====
echo "[1/7] Creating isolated Python runtime..."
$PYTHON_CMD -m venv "$GENERATION_DIR"

# venv bin directory is bin/ on Unix, Scripts/ on Windows
if [ -d "$GENERATION_DIR/Scripts" ]; then
    VENV_BIN="$GENERATION_DIR/Scripts"
elif [ -d "$GENERATION_DIR/bin" ]; then
    VENV_BIN="$GENERATION_DIR/bin"
else
    echo "✗ venv created but neither bin/ nor Scripts/ found inside $GENERATION_DIR"
    exit 1
fi
CLI="$VENV_BIN/deepseek-mcp"
[ ! -x "$CLI" ] && [ -x "$CLI.exe" ] && CLI="$CLI.exe"

# ===== Step 2: Install packages =====
echo "[2/7] Installing deepseek-mcp..."
PYBIN="$VENV_BIN/python"
[ ! -x "$PYBIN" ] && [ -x "$PYBIN.exe" ] && PYBIN="$PYBIN.exe"
$PYTHON_CMD "$PATH_GUARD" validate-venv "$GENERATION_DIR" "$PYBIN"

if ! supported_python "$PYBIN"; then
    echo "✗ New runtime used an unsupported Python: $($PYBIN --version 2>&1 || true)"
    exit 1
fi

"$PYBIN" -m pip install --quiet --only-binary=:all: --require-hashes -r "$LOCK_FILE"
"$PYBIN" -m pip install --quiet --no-deps --no-build-isolation "$PROJECT_ROOT"
"$PYBIN" -m pip check

[ ! -x "$CLI" ] && [ -x "$CLI.exe" ] && CLI="$CLI.exe"
if [ ! -e "$CLI" ]; then
    echo "✗ deepseek-mcp entrypoint was not created at $CLI"
    exit 1
fi

# ===== Step 3: Configuration file + prompt for API key =====
$PYTHON_CMD "$PATH_GUARD" prepare-dirs "$CONFIG_DIR"
$PYTHON_CMD "$PATH_GUARD" secure-files "$CONFIG_FILE"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[3/7] Configuring DeepSeek..."
    echo ""

    # Disable xtrace before any secret-bearing assignment or expansion.  Restore
    # it only after both the raw and escaped values have been cleared.
    XTRACE_WAS_ON=0
    case "$-" in
        *x*) XTRACE_WAS_ON=1; set +x ;;
    esac

    # Default values
    API_KEY=""
    DEFAULT_KEY_HINT="(press Enter to skip, you can fill in $CONFIG_FILE later)"

    # POSIX interacts only when local terminal is readable; Windows only allows env var key.
    INTERACTIVE=0
    if [ "$PLATFORM" = "windows" ]; then
        INTERACTIVE=0
    elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
        INTERACTIVE=1
    elif [ -t 0 ]; then
        INTERACTIVE=1
    fi

    if [ "$INTERACTIVE" = "1" ]; then
        echo "  Using the official DeepSeek service requires an API key; local OpenAI-compatible services can skip this."
        echo "  DeepSeek key: https://platform.deepseek.com"
        echo "  (Workspace sandbox automatically follows Claude launch directory; no configuration needed)"
        echo ""
        # -s silent: API key is not echoed to screen / scrollback
        # || true prevents set -e from exiting the script if user presses Ctrl+C
        if [ -e /dev/tty ] && [ -r /dev/tty ]; then
            read -rs -p "  Paste DeepSeek API key $DEFAULT_KEY_HINT: " API_KEY < /dev/tty || true
        else
            read -rs -p "  Paste DeepSeek API key $DEFAULT_KEY_HINT: " API_KEY || true
        fi
        echo ""
        echo ""
        # Strip leading/trailing whitespace (pastes often carry trailing spaces / newlines)
        API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"
    fi

    if [ -z "$API_KEY" ]; then
        API_KEY="PASTE_YOUR_DEEPSEEK_KEY_HERE"
        NEED_KEY=1
    else
        NEED_KEY=0
    fi

    # Escape the sole interpolated JSON string. Expansion output is not
    # evaluated again by the shell, so command syntax remains ordinary data.
    escaped_value="${API_KEY//\\/\\\\}"
    escaped_value="${escaped_value//\"/\\\"}"

    # workspace is omitted so MCP server uses os.getcwd() to follow Claude Code launch directory
    # Advanced users who want to lock the workspace can manually add "workspace": "/abs/path"
    #
    # umask 077 takes effect in subshell, ensuring config file is created mode 0600
    $PYTHON_CMD "$PATH_GUARD" write-exclusive "$CONFIG_FILE" <<EOF
{
  "api_key": "$escaped_value",
  "flash": "deepseek-v4-flash",
  "flash_reasoning_effort": "high",
  "pro": "deepseek-v4-pro",
  "pro_reasoning_effort": "high",
  "_reasoning_effort_options": ["provider-default", "none", "low", "high", "max"],
  "max_turns": 50,
  "max_run_seconds": 18000,
  "allowed_tools": ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "NotebookEdit"]
}
EOF
    API_KEY=""
    escaped_value=""
    if [ "$XTRACE_WAS_ON" -eq 1 ]; then
        set -x
    fi
    if [ "$NEED_KEY" = "0" ]; then
        echo "  ✓ config written (with your entered key)"
    elif [ "$PLATFORM" = "windows" ]; then
        echo "  ✓ config template written (placeholder retained; real key read from environment variable only)"
    else
        echo "  ✓ config template written (key placeholder, fill manually later)"
    fi
else
    echo "[3/7] config.json already exists, skipping"
    $PYTHON_CMD "$PATH_GUARD" secure-files "$CONFIG_FILE"
    if grep -q "PASTE_YOUR_DEEPSEEK_KEY_HERE" "$CONFIG_FILE"; then
        NEED_KEY=1
    else
        NEED_KEY=0
    fi
fi

CONFIG_ERROR=""
if ! CONFIG_ERROR="$("$PYBIN" -c '
import sys
from deepseek_mcp.config import Config
try:
    Config.validate_runtime_settings()
except RuntimeError as error:
    print(error)
    sys.exit(1)
' 2>&1)"; then
    echo "✗ Existing DeepSeek configuration is incompatible with current version: $CONFIG_FILE" >&2
    echo "  $CONFIG_ERROR" >&2
    echo "  Please check field formats; remove obsolete bash_backend/bash_runtime/bash_image fields and retry." >&2
    exit 1
fi

# ===== Step 4: Verify new generation before switching registration =====
echo "[4/7] Verifying MCP initialize/list_tools/ping..."
"$PYBIN" "$PROJECT_ROOT/adapters/codex/mcp_smoke.py" "$CLI"

# ===== Steps 5-6: optional helpers deploy only after core registration =====

restore_registration() {
    local previous="$1" snapshot="" current=""
    snapshot="$(registration_snapshot)" || return 1
    case "$snapshot" in present:*) current="${snapshot#present:}" ;; absent) ;; *) return 1 ;; esac
    if [ -n "$previous" ] && [ -n "$current" ] \
        && same_command_path "$current" "$previous"; then
        return 0
    fi
    if [ -z "$previous" ] && [ -z "$current" ]; then
        return 0
    fi
    if [ -n "$current" ]; then
        same_command_path "$current" "$CLI" || return 1
        registration_matches_expected "$current" || return 1
        "$CLAUDE_BIN" mcp remove deepseek -s user >/dev/null 2>&1 || return 1
        registration_matches_expected "" || return 1
    else
        registration_matches_expected "" || return 1
    fi
    if [ -n "$previous" ]; then
        "$CLAUDE_BIN" mcp add deepseek -s user -- "$previous" >/dev/null 2>&1 \
            || return 1
    fi
    registration_matches_expected "$previous"
}

switch_registration() {
    local previous="$1"
    REGISTRATION_TRANSACTION=1
    registration_matches_expected "$previous" || return 1
    if [ -n "$previous" ]; then
        "$CLAUDE_BIN" mcp remove deepseek -s user >/dev/null 2>&1 || return 1
        registration_matches_expected "" || return 1
    fi
    "$CLAUDE_BIN" mcp add deepseek -s user -- "$CLI" >/dev/null 2>&1 || return 1
    registration_matches_expected "$CLI" || return 1
    INSTALL_SUCCEEDED=1 REGISTRATION_TRANSACTION=0
    return 0
}

# Registration is the last state switch. Until here, the old runtime and user
# registration remain untouched, so config/package/smoke failures are harmless.
echo "[7/7] Registering MCP server to Claude Code (user scope)..."
if [ "$CLAUDE_AVAILABLE" -eq 0 ]; then
    echo "       ⚠ claude CLI not in PATH, skipping registration"
    echo "       (Re-run install.sh after installing Claude Code)"
elif ! switch_registration "$REGISTERED_COMMAND"; then
    echo "✗ Claude MCP registration switch failed; restoring previous registration on exit." >&2
    if [ -n "$REGISTERED_COMMAND" ]; then
        echo "  Previous runtime retained at: $REGISTERED_COMMAND" >&2
    fi
    exit 1
else
    echo "       ✓ Registration switched to $CLI"
    INSTALL_SUCCEEDED=1
fi

# Helper assets are optional and are deployed only after the core registration
# has committed.  A foreign/raced path is preserved and reported without
# turning a usable MCP registration into a failed installation.
deploy_claude_helpers

# Success was marked atomically with transaction completion so EXIT cleanup can
# never remove a generation that Claude may actively reference.
[ "$CLAUDE_AVAILABLE" -eq 1 ] || INSTALL_SUCCEEDED=1
if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    if ! $PYTHON_CMD "$PATH_GUARD" prune-generations \
        "$VENV_ROOT" "$GENERATION_DIR"; then
        echo "warning: failed to prune old runtime generations; current installation remains usable." >&2
    fi
else
    echo "       ⚠ Unable to verify active registration; retaining all previous generations"
fi

echo ""
echo "✅ Installation complete"
echo "  MCP environment: $GENERATION_DIR"
[ "$HELPER_WARNINGS" -eq 0 ] \
    || echo "  ⚠ Core MCP is installed, but some optional helpers were not deployed; see warnings above."
echo ""

if [ "${NEED_KEY:-0}" = "1" ]; then
    echo "No DeepSeek key provided. Official DeepSeek endpoint requires a key; local loopback endpoints do not."
    echo "Next steps:"
    if [ "$PLATFORM" = "windows" ]; then
        echo "  1. Set DEEPSEEK_API_KEY environment variable; do not store real keys in config.json."
    else
        echo "  1. Edit $CONFIG_FILE to set api_key to your DeepSeek key"
    fi
    echo "     For local models, configure base_url, flash, and pro; set OPENAI_API_KEY if auth is required."
    echo "     For local models, also set flash_reasoning_effort / pro_reasoning_effort to provider-default."
    echo "  2. Run claude, and enter: Please call the ping tool"
    echo ""
    # On Windows, don't open config file to avoid accidental persistence of secrets.
    if [ "$PLATFORM" != "windows" ]; then
        if command -v code >/dev/null 2>&1; then
            code "$CONFIG_FILE"
        elif command -v open >/dev/null 2>&1; then
            open -t "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi
else
    echo "Try it now:"
    echo "  cd <your-project-directory> && claude     # Running claude sessions must be restarted to load new MCP"
    echo "  > /ds inspect current project and summarize code structure   # Force delegate to DeepSeek"
    echo "  > Please call the ping tool                                  # Verify MCP connection and workspace root"
    echo ""
    echo "Automatic delegation: In conversation, tasks like \"batch extract i18n to JSON\" will be delegated automatically by Claude."
    echo "Disable delegation: Run DEEPSEEK_MODE=off claude (for current Claude session only)"
fi
echo ""
echo "Uninstall: ./uninstall.sh"
