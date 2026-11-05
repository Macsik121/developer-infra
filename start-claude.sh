#!/usr/bin/env bash
# ==============================================================================
# Synopsis: Launches Claude Code with model selection via OmniRoute proxy.
# Usage:
#   ./start_claude.sh
#   ./start_claude.sh -c "claude" -m 1
#   ./start_claude.sh --add-model
#   ./start_claude.sh --remove-model
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/claude_models.json"
OMNIROUTE_PORT=20128
OMNIROUTE_URL="http://localhost:${OMNIROUTE_PORT}"
OMNIROUTE_LOG="/tmp/omniroute_${OMNIROUTE_PORT}.log"

# ANSI Colors
C_RESET='\033[0m'
C_CYAN='\033[0;36m'
C_YELLOW='\033[1;33m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_GRAY='\033[0;90m'
C_WHITE='\033[0;37m'

print_color() {
    local color="$1"
    local message="$2"
    printf "${color}%s${C_RESET}\n" "$message"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --command <str>   Claude command to run (e.g., "claude" or "claude make team work")
  -m, --model <int>     Model ID number (1-N)
  --add-model           Add a new model to claude_models.json
  --remove-model        Remove an existing model from claude_models.json
  -h, --help            Show this help message
EOF
}

# ============================================
# Dependency Verification
# ============================================
check_dependencies() {
    local missing=()
    for cmd in node omniroute claude curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_color "$C_RED" "ERROR: Missing required dependencies: ${missing[*]}"
        print_color "$C_YELLOW" "Ensure Node.js, OmniRoute (npm i -g omniroute), Claude CLI, and curl are installed."
        exit 1
    fi
}

# ============================================
# JSON Model Management (via Node.js)
# ============================================
ensure_models_file() {
    MODELS_FILE_ENV="$MODELS_FILE" node -e '
const fs = require("fs");
const file = process.env.MODELS_FILE_ENV;
const defaults = {
  "1": "kr/claude-sonnet-4.5",
  "2": "kr/glm-5[1m]",
  "3": "agentrouter/claude-opus-5",
  "4": "agentrouter/claude-opus-4.8",
  "5": "agentrouter/deepseek-v4-flash",
  "6": "antigravity/claude-sonnet-4-6",
  "7": "antigravity/claude-opus-4-6-thinking",
  "8": "antigravity/gemini-3.1-flash-lite",
  "9": "nvidia/nvidia/nemotron-3-super-120b-a12b",
  "10": "nvidia/nvidia/nemotron-3-ultra-550b-a55b"
};

let data = defaults;
if (fs.existsSync(file)) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    const keys = Object.keys(parsed).sort((a, b) => Number(a) - Number(b));
    if (keys.length > 0) {
      data = {};
      keys.forEach((k, idx) => { data[String(idx + 1)] = String(parsed[k]); });
    }
  } catch (e) {
    console.error("Warning: Could not parse claude_models.json. Resetting to defaults.");
  }
}
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n", "utf8");
'
}

list_models() {
    ensure_models_file
    MODELS_FILE_ENV="$MODELS_FILE" node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.env.MODELS_FILE_ENV, "utf8"));
Object.keys(data).sort((a, b) => Number(a) - Number(b)).forEach(k => {
  console.log(` ${k.padStart(2, " ")}. ${data[k]}`);
});
'
    echo ""
}

get_model_count() {
    ensure_models_file
    MODELS_FILE_ENV="$MODELS_FILE" node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.env.MODELS_FILE_ENV, "utf8"));
console.log(Object.keys(data).length);
'
}

get_model_by_id() {
    local target_id="$1"
    MODELS_FILE_ENV="$MODELS_FILE" TARGET_ID="$target_id" node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.env.MODELS_FILE_ENV, "utf8"));
const val = data[process.env.TARGET_ID];
if (val) console.log(val);
'
}

add_model() {
    print_color "$C_CYAN" $'\n=== Add New Model ==='
    read -r -p "Enter model string (e.g., 'provider/model-name'): " new_model
    new_model="$(echo "$new_model" | xargs)"

    if [[ -z "$new_model" ]]; then
        print_color "$C_RED" "ERROR: Model string cannot be empty."
        exit 1
    fi

    ensure_models_file
    local next_id
    next_id=$(MODELS_FILE_ENV="$MODELS_FILE" NEW_MODEL="$new_model" node -e '
const fs = require("fs");
const file = process.env.MODELS_FILE_ENV;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const keys = Object.keys(data).sort((a, b) => Number(a) - Number(b));
const renumbered = {};
keys.forEach((k, idx) => { renumbered[String(idx + 1)] = data[k]; });
const nextId = keys.length + 1;
renumbered[String(nextId)] = process.env.NEW_MODEL;
fs.writeFileSync(file, JSON.stringify(renumbered, null, 2) + "\n", "utf8");
console.log(nextId);
')

    print_color "$C_GREEN" "Models saved to: ${MODELS_FILE}"
    print_color "$C_GREEN" $'\nModel added successfully!'
    print_color "$C_WHITE" "  ID: ${next_id}"
    print_color "$C_WHITE" "  Model: ${new_model}"
}

remove_model() {
    print_color "$C_CYAN" $'\n=== Remove Model ==='
    local count
    count="$(get_model_count)"

    if [[ "$count" -eq 0 ]]; then
        print_color "$C_YELLOW" "No models found."
        return 0
    fi

    print_color "$C_YELLOW" $'\nCurrent models:'
    list_models

    read -r -p "Enter model ID to remove (or 'cancel'): " model_id_input
    model_id_input="$(echo "$model_id_input" | xargs)"

    if [[ "${model_id_input,,}" == "cancel" ]]; then
        print_color "$C_YELLOW" "Operation cancelled."
        return 0
    fi

    if [[ ! "$model_id_input" =~ ^[0-9]+$ ]]; then
        print_color "$C_RED" "ERROR: Invalid ID. Please enter a number."
        exit 1
    fi

    local target_model
    target_model="$(get_model_by_id "$model_id_input")"

    if [[ -z "$target_model" ]]; then
        print_color "$C_RED" "ERROR: Model ID ${model_id_input} not found."
        exit 1
    fi

    read -r -p "Remove model '${target_model}'? (y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        print_color "$C_YELLOW" "Operation cancelled."
        return 0
    fi

    MODELS_FILE_ENV="$MODELS_FILE" REMOVE_ID="$model_id_input" node -e '
const fs = require("fs");
const file = process.env.MODELS_FILE_ENV;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
delete data[process.env.REMOVE_ID];
const keys = Object.keys(data).sort((a, b) => Number(a) - Number(b));
const renumbered = {};
keys.forEach((k, idx) => { renumbered[String(idx + 1)] = data[k]; });
fs.writeFileSync(file, JSON.stringify(renumbered, null, 2) + "\n", "utf8");
'

    print_color "$C_GREEN" "Models saved to: ${MODELS_FILE}"
    print_color "$C_GREEN" $'\nModel removed successfully!'
    print_color "$C_WHITE" "  Removed: ${target_model}"
    print_color "$C_WHITE" "  Models renumbered to maintain order: 1, 2, 3, ..."
}

test_omniroute_health() {
    curl -s -f --max-time 3 "$OMNIROUTE_URL" >/dev/null 2>&1
}

# ============================================
# Argument Parsing
# ============================================
COMMAND=""
MODEL=0
ACTION="run"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--command)
            COMMAND="${2:-}"
            shift 2
            ;;
        -m|--model)
            if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
                print_color "$C_RED" "ERROR: --model requires a numeric argument."
                exit 1
            fi
            MODEL="$2"
            shift 2
            ;;
        --add-model)
            ACTION="add"
            shift
            ;;
        --remove-model)
            ACTION="remove"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_color "$C_RED" "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Pre-flight check for node (required for JSON operations)
if ! command -v node >/dev/null 2>&1; then
    print_color "$C_RED" "ERROR: Node.js is required but not installed."
    exit 1
fi

if [[ "$ACTION" == "add" ]]; then
    add_model
    exit 0
elif [[ "$ACTION" == "remove" ]]; then
    remove_model
    exit 0
fi

# Show interactive mode selector only when no CLI parameters were supplied
if [[ -z "$COMMAND" && "$MODEL" -eq 0 ]]; then
    print_color "$C_CYAN" $'Claude Code via OmniRoute Launcher\n'
    print_color "$C_YELLOW" $'Select mode:\n  1. Run Claude (select model and launch)\n  2. Add new model to list\n  3. Remove model from list\n'
    read -r -p "Enter your choice (1, 2, or 3) [default: 1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
        1) ;;
        2) add_model; exit 0 ;;
        3) remove_model; exit 0 ;;
        *)
            print_color "$C_RED" "ERROR: Invalid choice. Please enter 1, 2, or 3."
            exit 1
            ;;
    esac
fi

check_dependencies

# ============================================
# Phase 1: Get Claude Command
# ============================================
if [[ -z "$COMMAND" ]]; then
    read -r -p "Enter Claude command [default: 'claude']: " input_cmd
    COMMAND="${input_cmd:-claude}"
fi

# ============================================
# Phase 2: Get Auth Token
# ============================================
print_color "$C_CYAN" $'\nChecking authentication token...'
AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"

if [[ -z "$AUTH_TOKEN" ]]; then
    print_color "$C_YELLOW" "ANTHROPIC_AUTH_TOKEN environment variable not set."
    print_color "$C_GRAY"   "Tip: Export it via: export ANTHROPIC_AUTH_TOKEN='your-key'"
    print_color "$C_YELLOW" "Please enter your OmniRoute API Key (input will be hidden):"
    read -r -s auth_input
    echo ""
    AUTH_TOKEN="$auth_input"

    if [[ -z "$AUTH_TOKEN" ]]; then
        print_color "$C_RED" "ERROR: Authentication token cannot be empty."
        exit 1
    fi
fi

# ============================================
# Phase 3: Select Model
# ============================================
MAX_ID="$(get_model_count)"
SELECTED_MODEL=""

if [[ "$MODEL" -ge 1 && "$MODEL" -le "$MAX_ID" ]]; then
    SELECTED_MODEL="$(get_model_by_id "$MODEL")"
fi

if [[ -z "$SELECTED_MODEL" ]]; then
    print_color "$C_CYAN" $'\nSelect Claude model:'
    list_models
    read -r -p "Enter model number (1-${MAX_ID}): " model_input

    if [[ ! "$model_input" =~ ^[0-9]+$ ]] || [[ "$model_input" -lt 1 ]] || [[ "$model_input" -gt "$MAX_ID" ]]; then
        print_color "$C_RED" "ERROR: Invalid model choice. Please enter a number from 1 to ${MAX_ID}."
        exit 1
    fi
    MODEL="$model_input"
    SELECTED_MODEL="$(get_model_by_id "$MODEL")"
fi

print_color "$C_GREEN" "Selected model: ${SELECTED_MODEL}"

# ============================================
# Phase 4: Check and Start OmniRoute
# ============================================
print_color "$C_CYAN" $'\nChecking OmniRoute status...'

if test_omniroute_health; then
    print_color "$C_GREEN" "OmniRoute is already running and healthy."
else
    print_color "$C_YELLOW" "OmniRoute is not running. Starting it in background..."

    nohup omniroute --port="$OMNIROUTE_PORT" >"$OMNIROUTE_LOG" 2>&1 &
    OMNIROUTE_PID=$!

    print_color "$C_GREEN" "OmniRoute started in background (PID: ${OMNIROUTE_PID}, Log: ${OMNIROUTE_LOG})"
    print_color "$C_CYAN"  "Waiting for OmniRoute to become healthy..."

    MAX_ATTEMPTS=30
    IS_HEALTHY=false

    for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
        sleep 1
        if test_omniroute_health; then
            print_color "$C_GREEN" "OmniRoute is now healthy (attempt ${attempt}/${MAX_ATTEMPTS})"
            IS_HEALTHY=true
            break
        fi
        echo "Waiting... (attempt ${attempt}/${MAX_ATTEMPTS})"
    done

    if [[ "$IS_HEALTHY" != "true" ]]; then
        print_color "$C_RED"    "ERROR: OmniRoute failed to start after ${MAX_ATTEMPTS} seconds."
        print_color "$C_YELLOW" "Check log file for details: ${OMNIROUTE_LOG}"
        exit 1
    fi
fi

# ============================================
# Phase 5: Set Environment Variables
# ============================================
print_color "$C_CYAN" $'\nSetting up environment...'

export ANTHROPIC_AUTH_TOKEN="$AUTH_TOKEN"
export ANTHROPIC_BASE_URL="${OMNIROUTE_URL}/v1"
export ANTHROPIC_MODEL="$SELECTED_MODEL"
export ANTHROPIC_deepseek_MODEL="deepseek-v4-flash"
export ENABLE_CC_COMPATIBLE_PROVIDER="true"
export CLAUDE_CODE_SKIP_UPDATE_CHECK="1"
export CLAUDE_CODE_DISABLE_ARTIFACT="1"

export ANTHROPIC_DEFAULT_SONNET_MODEL="$SELECTED_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SELECTED_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$SELECTED_MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL=glm-5.2
export CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1

print_color "$C_GREEN" "Environment configured:"
echo "  ANTHROPIC_MODEL    = ${ANTHROPIC_MODEL}"
echo "  ANTHROPIC_BASE_URL = ${ANTHROPIC_BASE_URL}"

# ============================================
# Phase 6: Launch Claude
# ============================================
print_color "$C_CYAN"  $'\nStarting Claude Code via OmniRoute...'
print_color "$C_WHITE" "Command: ${COMMAND}"
print_color "$C_GRAY"  $'\n========================================\n'

set +e
eval "$COMMAND"
CMD_EXIT_CODE=$?
set -e

# ============================================
# Phase 7: Cleanup Instructions
# ============================================
print_color "$C_GRAY" $'\n========================================'

if [[ $CMD_EXIT_CODE -ne 0 ]]; then
    print_color "$C_RED" "ERROR: Failed to execute command (exit code ${CMD_EXIT_CODE})."
    exit "$CMD_EXIT_CODE"
fi

print_color "$C_CYAN"   "Session ended."
print_color "$C_YELLOW" "OmniRoute is still running in the background (Port ${OMNIROUTE_PORT})."
print_color "$C_YELLOW" "To stop it manually, run: pkill -f 'omniroute --port=${OMNIROUTE_PORT}'"
exit 0