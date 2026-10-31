#!/bin/sh
#
# Aria2 Automatic File Cleaner Script
# Supported Events: on-download-stop, on-download-error, on-download-complete, on-bt-download-complete
#
# Usage:
#   1. Automatic Installation (when placed in the same directory as aria2.conf):
#      ./clean.sh --install
#
#   2. Event Hook Call (invoked automatically by aria2c):
#      $1: GID
#      $2: Number of files
#      $3: Path to the first file
#

set -e

# Resolve script path and directory
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONF_FILE="${SCRIPT_DIR}/aria2.conf"

# ================= Configuration & Auto-Detection =================
# If placed in the same directory as aria2.conf, automatically parse configuration
if [ -f "$CONF_FILE" ]; then
    if [ -z "$ARIA2_RPC_SECRET" ]; then
        CONF_SECRET=$(grep -E '^[[:space:]]*rpc-secret[[:space:]]*=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') || true
        if [ -n "$CONF_SECRET" ]; then
            ARIA2_RPC_SECRET="$CONF_SECRET"
        fi
    fi

    if [ -z "$ARIA2_RPC_URL" ]; then
        CONF_PORT=$(grep -E '^[[:space:]]*rpc-listen-port[[:space:]]*=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') || true
        CONF_PORT="${CONF_PORT:-6800}"
        ARIA2_RPC_URL="http://127.0.0.1:${CONF_PORT}/jsonrpc"
    fi
fi

# Fallback default values
ARIA2_RPC_URL="${ARIA2_RPC_URL:-http://127.0.0.1:6800/jsonrpc}"
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"

# Logging configuration (set ENABLE_LOG=true to debug)
ENABLE_LOG="${ENABLE_LOG:-false}"
LOG_FILE="${LOG_FILE:-/tmp/aria2_clean.log}"

# Behavior switches
DELETE_ON_ERROR="${DELETE_ON_ERROR:-true}"
DELETE_ON_REMOVE="${DELETE_ON_REMOVE:-true}"
DELETE_CONTROL_FILE="${DELETE_CONTROL_FILE:-true}"
DELETE_TORRENT_FILE="${DELETE_TORRENT_FILE:-true}"
# ==================================================================

# ----------------- CLI Management Commands -----------------
install_hooks() {
    echo "=========================================="
    echo "  Aria2 Cleaner Automatic Installation    "
    echo "=========================================="

    if [ ! -f "$CONF_FILE" ]; then
        echo "Error: aria2.conf not found in the script directory (${SCRIPT_DIR})."
        echo "Please make sure clean.sh and aria2.conf are placed in the same folder."
        exit 1
    fi

    # Make self executable
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true

    # Backup original configuration
    cp "$CONF_FILE" "${CONF_FILE}.bak"
    echo "Created backup: ${CONF_FILE}.bak"

    # Remove previous hook configurations to prevent duplicates
    TMP_CONF="${CONF_FILE}.tmp"
    grep -v -E '^[[:space:]]*on-download-(stop|error|complete)[[:space:]]*=' "$CONF_FILE" > "$TMP_CONF" 2>/dev/null || cat "$CONF_FILE" > "$TMP_CONF"

    # Append new cleaner hooks
    cat <<EOF >> "$TMP_CONF"

# === Aria2 Cleaner Hooks ===
on-download-stop=${SCRIPT_PATH}
on-download-error=${SCRIPT_PATH}
on-download-complete=${SCRIPT_PATH}
EOF

    mv "$TMP_CONF" "$CONF_FILE"
    echo "Updated ${CONF_FILE} with cleaner hooks."

    # Print auto-detected settings
    echo "Auto-detected settings:"
    echo "  RPC URL: ${ARIA2_RPC_URL}"
    if [ -n "$ARIA2_RPC_SECRET" ]; then
        echo "  RPC Secret: [Configured]"
    else
        echo "  RPC Secret: [None]"
    fi

    echo "=========================================="
    echo "Installation completed successfully!"
    echo "Please restart aria2c to apply changes."
    echo "=========================================="
    exit 0
}

uninstall_hooks() {
    echo "=========================================="
    echo "  Aria2 Cleaner Uninstallation            "
    echo "=========================================="

    if [ ! -f "$CONF_FILE" ]; then
        echo "Error: aria2.conf not found in ${SCRIPT_DIR}."
        exit 1
    fi

    TMP_CONF="${CONF_FILE}.tmp"
    grep -v -E '^[[:space:]]*on-download-(stop|error|complete)[[:space:]]*=' "$CONF_FILE" | grep -v '# === Aria2 Cleaner Hooks ===' > "$TMP_CONF" 2>/dev/null || cat "$CONF_FILE" > "$TMP_CONF"

    mv "$TMP_CONF" "$CONF_FILE"
    echo "Removed cleaner hooks from ${CONF_FILE}."
    echo "Please restart aria2c to apply changes."
    echo "=========================================="
    exit 0
}

case "$1" in
    "--install"|"install"|"-i")
        install_hooks
        ;;
    "--uninstall"|"uninstall"|"-u")
        uninstall_hooks
        ;;
    "--help"|"-h")
        echo "Usage: $0 [OPTION] | [GID] [FILE_COUNT] [FIRST_FILE_PATH]"
        echo "Options:"
        echo "  --install, -i    Auto-configure aria2.conf in the same directory"
        echo "  --uninstall, -u  Remove cleaner hooks from aria2.conf"
        echo "  --help, -h       Display this help message"
        exit 0
        ;;
esac
# -----------------------------------------------------------

GID="$1"
FILE_NUM="$2"
FIRST_FILE_PATH="$3"

log() {
    if [ "$ENABLE_LOG" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [GID: ${GID:-N/A}] $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

if [ -z "$GID" ]; then
    log "Error: GID argument is missing. Exiting."
    exit 0
fi

log "Triggered: GID=$GID, FileCount=$FILE_NUM, FirstFile='$FIRST_FILE_PATH'"

# Query task status from Aria2 RPC
query_rpc_status() {
    local payload
    if [ -n "$ARIA2_RPC_SECRET" ]; then
        payload="{\"jsonrpc\":\"2.0\",\"id\":\"cleaner\",\"method\":\"aria2.tellStatus\",\"params\":[\"token:${ARIA2_RPC_SECRET}\",\"${GID}\",[\"status\",\"dir\",\"files\",\"bittorrent\",\"errorMessage\"]]}"
    else
        payload="{\"jsonrpc\":\"2.0\",\"id\":\"cleaner\",\"method\":\"aria2.tellStatus\",\"params\":[\"${GID}\",[\"status\",\"dir\",\"files\",\"bittorrent\",\"errorMessage\"]]}"
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -s -m 5 -X POST -H "Content-Type: application/json" -d "$payload" "$ARIA2_RPC_URL" 2>/dev/null || echo ""
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O - --post-data="$payload" --header="Content-Type: application/json" "$ARIA2_RPC_URL" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Parse JSON fields using available system tools (jq -> python3 -> python -> grep/sed)
parse_json() {
    local json_data="$1"
    local query_type="$2"

    if [ -z "$json_data" ]; then
        return
    fi

    # Strategy 1: jq
    if command -v jq >/dev/null 2>&1; then
        case "$query_type" in
            "status")
                echo "$json_data" | jq -r '.result.status // empty' 2>/dev/null || true
                ;;
            "dir")
                echo "$json_data" | jq -r '.result.dir // empty' 2>/dev/null || true
                ;;
            "bt_name")
                echo "$json_data" | jq -r '.result.bittorrent.info.name // empty' 2>/dev/null || true
                ;;
            "bt_mode")
                echo "$json_data" | jq -r '.result.bittorrent.mode // empty' 2>/dev/null || true
                ;;
            "files")
                echo "$json_data" | jq -r '.result.files[].path // empty' 2>/dev/null || true
                ;;
        esac
        return
    fi

    # Strategy 2: Python (Python 3 or Python 2)
    local py_bin=""
    if command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        py_bin="python"
    fi

    if [ -n "$py_bin" ]; then
        "$py_bin" -c "
import sys, json
try:
    data = json.loads('''$json_data''')
    res = data.get('result', {})
    q = '$query_type'
    if q == 'status':
        print(res.get('status', ''))
    elif q == 'dir':
        print(res.get('dir', ''))
    elif q == 'bt_name':
        bt = res.get('bittorrent', {})
        info = bt.get('info', {}) if bt else {}
        print(info.get('name', ''))
    elif q == 'bt_mode':
        bt = res.get('bittorrent', {})
        print(bt.get('mode', '') if bt else '')
    elif q == 'files':
        for f in res.get('files', []):
            p = f.get('path', '')
            if p:
                print(p)
except Exception:
    pass
" 2>/dev/null || true
        return
    fi

    # Strategy 3: POSIX grep / sed fallback
    case "$query_type" in
        "status")
            echo "$json_data" | grep -o '"status":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true
            ;;
        "dir")
            echo "$json_data" | grep -o '"dir":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true
            ;;
        "bt_name")
            echo "$json_data" | grep -o '"name":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true
            ;;
        "files")
            echo "$json_data" | grep -o '"path":"[^"]*"' | cut -d'"' -f4 || true
            ;;
    esac
}

# Safe removal helper (verifies target path is not root or dangerous)
safe_remove_file() {
    local target="$1"
    if [ -z "$target" ] || [ "$target" = "/" ]; then
        return
    fi
    if [ -f "$target" ] || [ -L "$target" ]; then
        rm -f "$target" 2>/dev/null || true
        log "Deleted file: $target"
    fi
}

safe_remove_dir() {
    local target="$1"
    if [ -z "$target" ] || [ "$target" = "/" ] || [ "$target" = "/root" ] || [ "$target" = "/home" ]; then
        return
    fi
    if [ -d "$target" ]; then
        rm -rf "$target" 2>/dev/null || true
        log "Deleted directory: $target"
    fi
}

# Fetch status via RPC
RPC_RESP=$(query_rpc_status)

TASK_STATUS=""
TASK_DIR=""
BT_NAME=""
BT_MODE=""
FILE_LIST=""

if [ -n "$RPC_RESP" ]; then
    TASK_STATUS=$(parse_json "$RPC_RESP" "status")
    TASK_DIR=$(parse_json "$RPC_RESP" "dir")
    BT_NAME=$(parse_json "$RPC_RESP" "bt_name")
    BT_MODE=$(parse_json "$RPC_RESP" "bt_mode")
    FILE_LIST=$(parse_json "$RPC_RESP" "files")
fi

log "Parsed info: status='$TASK_STATUS', dir='$TASK_DIR', bt_name='$BT_NAME', bt_mode='$BT_MODE'"

# Decision Branch 1: Task was paused -> STRICT PRESERVATION
if [ "$TASK_STATUS" = "paused" ]; then
    log "Task status is 'paused'. Keeping all files intact. Exiting."
    exit 0
fi

# Decision Branch 2: Task status is 'active' (e.g. BT Seeding in progress)
if [ "$TASK_STATUS" = "active" ]; then
    log "Task is currently active/seeding. Skipping file deletion to avoid interrupting task. Exiting."
    exit 0
fi

# Decision Branch 3: Download Error or Task Removed (Unfinished files cleanup)
if [ "$TASK_STATUS" = "error" ] || [ "$TASK_STATUS" = "removed" ] || [ -z "$TASK_STATUS" ]; then
    log "Task status is '$TASK_STATUS'. Processing unfinished file deletion..."

    # 1. Clean individual files and .aria2 control files
    if [ -n "$FILE_LIST" ]; then
        echo "$FILE_LIST" | while IFS= read -r file_path; do
            if [ -n "$file_path" ]; then
                safe_remove_file "$file_path"
                if [ "$DELETE_CONTROL_FILE" = "true" ]; then
                    safe_remove_file "${file_path}.aria2"
                fi
            fi
        done
    else
        # Fallback to FIRST_FILE_PATH if file list not obtained
        if [ -n "$FIRST_FILE_PATH" ]; then
            safe_remove_file "$FIRST_FILE_PATH"
            if [ "$DELETE_CONTROL_FILE" = "true" ]; then
                safe_remove_file "${FIRST_FILE_PATH}.aria2"
            fi
        fi
    fi

    # 2. If multi-file BT task, clean dedicated subfolder
    if [ -n "$TASK_DIR" ] && [ -n "$BT_NAME" ] && [ "$BT_MODE" = "multi" ]; then
        DEDICATED_DIR="${TASK_DIR}/${BT_NAME}"
        if [ -d "$DEDICATED_DIR" ] && [ "$DEDICATED_DIR" != "$TASK_DIR" ]; then
            safe_remove_dir "$DEDICATED_DIR"
        fi
    fi

    # 3. Clean .torrent metadata if present
    if [ "$DELETE_TORRENT_FILE" = "true" ] && [ -n "$TASK_DIR" ] && [ -n "$BT_NAME" ]; then
        safe_remove_file "${TASK_DIR}/${BT_NAME}.torrent"
    fi

    exit 0
fi

# Decision Branch 4: Task Completed (Clean .aria2 control file & .torrent file)
if [ "$TASK_STATUS" = "complete" ]; then
    log "Task is completed. Cleaning up residual control and torrent files..."

    # Clean residual .aria2 control files
    if [ "$DELETE_CONTROL_FILE" = "true" ]; then
        if [ -n "$FILE_LIST" ]; then
            echo "$FILE_LIST" | while IFS= read -r file_path; do
                if [ -n "$file_path" ]; then
                    safe_remove_file "${file_path}.aria2"
                fi
            done
        elif [ -n "$FIRST_FILE_PATH" ]; then
            safe_remove_file "${FIRST_FILE_PATH}.aria2"
        fi
    fi

    # Clean .torrent seed files
    if [ "$DELETE_TORRENT_FILE" = "true" ]; then
        if [ -n "$TASK_DIR" ] && [ -n "$BT_NAME" ]; then
            safe_remove_file "${TASK_DIR}/${BT_NAME}.torrent"
        fi
        # If the downloaded item itself was a .torrent file or saved with .torrent extension
        if [ -n "$FIRST_FILE_PATH" ]; then
            case "$FIRST_FILE_PATH" in
                *.torrent)
                    # Handled when specifically targeted
                    ;;
            esac
        fi
    fi

    exit 0
fi

log "Completed execution for GID: $GID"
