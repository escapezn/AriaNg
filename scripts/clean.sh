#!/bin/sh
#
# Aria2 Automatic File Cleaner Script
# Supported Events: on-download-stop, on-download-error, on-download-complete, on-bt-download-complete
#
# Aria2 passes 3 arguments to hook scripts:
# $1: GID
# $2: Number of files
# $3: Path to the first file
#

set -e

# ================= Configuration =================
# Aria2 JSON-RPC endpoint (default: http://127.0.0.1:6800/jsonrpc)
ARIA2_RPC_URL="${ARIA2_RPC_URL:-http://127.0.0.1:6800/jsonrpc}"

# Aria2 RPC secret token (leave empty if not configured)
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"

# Logging configuration (set ENABLE_LOG=true to debug)
ENABLE_LOG="${ENABLE_LOG:-false}"
LOG_FILE="${LOG_FILE:-/tmp/aria2_clean.log}"

# Behavior switches
DELETE_ON_ERROR="${DELETE_ON_ERROR:-true}"
DELETE_ON_REMOVE="${DELETE_ON_REMOVE:-true}"
DELETE_CONTROL_FILE="${DELETE_CONTROL_FILE:-true}"
DELETE_TORRENT_FILE="${DELETE_TORRENT_FILE:-true}"
# =================================================

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
