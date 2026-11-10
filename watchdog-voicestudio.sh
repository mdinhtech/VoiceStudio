#!/usr/bin/env bash
# Always-on background watchdog for VoiceStudio (OmniVoice).
# Monitors the VoiceStudio server process and restarts it automatically if it crashes or stops,
# unless explicitly stopped via stop-voicestudio.sh (which removes the watchdog or sets .stopped).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${1:-${OMNIVOICE_PORT:-3900}}"
DATA_DIR="${OMNIVOICE_DATA_DIR:-${SCRIPT_DIR}/omnivoice_data}"
mkdir -p "$DATA_DIR"

WATCHDOG_PID_FILE="${DATA_DIR}/watchdog.pid"
WATCHDOG_LOG_FILE="${DATA_DIR}/watchdog.log"
STOP_SENTINEL="${DATA_DIR}/.stopped"
PID_FILE="${DATA_DIR}/omnivoice.pid"

# Ensure single watchdog instance
if [ -f "$WATCHDOG_PID_FILE" ]; then
    EXISTING_WD_PID="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
    if [ -n "$EXISTING_WD_PID" ] && [ "$EXISTING_WD_PID" != "$$" ] && kill -0 "$EXISTING_WD_PID" 2>/dev/null; then
        exit 0
    fi
fi

echo "$$" > "$WATCHDOG_PID_FILE"
rm -f "$STOP_SENTINEL"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*" >> "$WATCHDOG_LOG_FILE"
}

cleanup() {
    log "Watchdog (PID $$) shutting down."
    rm -f "$WATCHDOG_PID_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "VoiceStudio always-on watchdog started (PID $$, monitoring port $PORT)."

while true; do
    if [ -f "$STOP_SENTINEL" ]; then
        log "Stop sentinel detected ($STOP_SENTINEL). Exiting watchdog."
        rm -f "$WATCHDOG_PID_FILE"
        exit 0
    fi

    RUNNING=0
    if [ -f "$PID_FILE" ]; then
        SERVER_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
            RUNNING=1
        fi
    fi

    # Fallback check if uvicorn is running even without matching PID file
    if [ "$RUNNING" -eq 0 ]; then
        FOUND_PID="$(pgrep -f "uvicorn.*backend.main:app.*--port ${PORT}" | head -n 1 || true)"
        if [ -n "$FOUND_PID" ]; then
            echo "$FOUND_PID" > "$PID_FILE"
            RUNNING=1
        fi
    fi

    if [ "$RUNNING" -eq 0 ]; then
        log "VoiceStudio is not running on port $PORT. Starting via start-voicestudio.sh..."
        ./start-voicestudio.sh "$PORT" --no-watchdog >> "$WATCHDOG_LOG_FILE" 2>&1 || true
        sleep 5
    fi

    sleep 10
done
