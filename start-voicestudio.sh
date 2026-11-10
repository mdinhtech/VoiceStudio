#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Configurable port (argument or environment variable, default 3900)
PORT="${1:-${OMNIVOICE_PORT:-3900}}"
export OMNIVOICE_PORT="$PORT"

# 2. Pin data directory to current workspace
DATA_DIR="${OMNIVOICE_DATA_DIR:-${SCRIPT_DIR}/omnivoice_data}"
export OMNIVOICE_DATA_DIR="$DATA_DIR"
export HF_HOME="${DATA_DIR}/huggingface"
mkdir -p "$DATA_DIR"

# 3. Persistent or custom API Key
KEY_FILE="${DATA_DIR}/.api_key"
if [ -z "$OMNIVOICE_API_KEY" ]; then
    if [ -f "$KEY_FILE" ]; then
        OMNIVOICE_API_KEY="$(cat "$KEY_FILE")"
    else
        OMNIVOICE_API_KEY="$(openssl rand -hex 32)"
        echo "$OMNIVOICE_API_KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
else
    echo "$OMNIVOICE_API_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
fi
export OMNIVOICE_API_KEY

# 4. Networking and server mode
export OMNIVOICE_BIND_HOST="${OMNIVOICE_BIND_HOST:-0.0.0.0}"
export OMNIVOICE_SERVER_MODE="${OMNIVOICE_SERVER_MODE:-1}"
export PYTHONPATH="${SCRIPT_DIR}/backend:${PYTHONPATH:-}"

# 5. Code-server proxy URL integration
DETECTED_HOST=""
if [ -n "$VSCODE_PROXY_URI" ]; then
    DETECTED_HOST="$(echo "$VSCODE_PROXY_URI" | sed -E 's|(https?://[^/]+).*|\1|')"
fi
PROXY_BASE="${CODE_SERVER_PROXY_HOST:-${DETECTED_HOST:-https://code.zuelligpharma.com}}"
export CODE_SERVER_PROXY_HOST="$PROXY_BASE"
export OMNIVOICE_PUBLIC_API_BASE="${OMNIVOICE_PUBLIC_API_BASE:-${PROXY_BASE}/proxy/${PORT}}"
export OMNIVOICE_ALLOWED_ORIGINS="${OMNIVOICE_ALLOWED_ORIGINS:-${PROXY_BASE},https://code.zuelligpharma.com,https://code-server-mdinh.zuelligpharma.com,http://localhost:${PORT},http://127.0.0.1:${PORT}}"
export OMNIVOICE_ALLOWED_HOSTS="${OMNIVOICE_ALLOWED_HOSTS:-*}"
export OMNIVOICE_FRONTEND_DIST="${SCRIPT_DIR}/frontend/dist"

LOG_FILE="${DATA_DIR}/omnivoice.log"
PID_FILE="${DATA_DIR}/omnivoice.pid"
WATCHDOG_PID_FILE="${DATA_DIR}/watchdog.pid"
STOP_SENTINEL="${DATA_DIR}/.stopped"

rm -f "$STOP_SENTINEL"

ensure_watchdog() {
    if [ "${2:-}" = "--no-watchdog" ] || [ "${2:-}" = "--foreground" ]; then
        return 0
    fi
    if [ -f "$WATCHDOG_PID_FILE" ] && kill -0 "$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    setsid "${SCRIPT_DIR}/watchdog-voicestudio.sh" "$PORT" </dev/null >/dev/null 2>&1 &
}

# Check if already running on this port
if [ -f "$PID_FILE" ]; then
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        ensure_watchdog "$@"
        echo "VoiceStudio is already running (PID: $(cat "$PID_FILE"))."
        if [ -f "$WATCHDOG_PID_FILE" ]; then
            echo "Always-on watchdog is active (PID: $(cat "$WATCHDOG_PID_FILE"))."
        fi
        echo "Web Proxy Access URL: ${PROXY_BASE}/proxy/${PORT}/"
        echo "Direct Local Access:   http://127.0.0.1:${PORT}/"
        echo "API Documentation:    ${PROXY_BASE}/proxy/${PORT}/docs"
        echo "API Key:              $OMNIVOICE_API_KEY"
        echo "To restart, run: ./stop-voicestudio.sh && ./start-voicestudio.sh $PORT"
        exit 0
    else
        rm -f "$PID_FILE"
    fi
fi

# Fallback: if uvicorn is already running on this port without a PID file, adopt it
EXISTING_UVICORN_PID="$(pgrep -f "uvicorn.*backend.main:app.*--port ${PORT}" | head -n 1 || true)"
if [ -n "$EXISTING_UVICORN_PID" ]; then
    echo "$EXISTING_UVICORN_PID" > "$PID_FILE"
    ensure_watchdog "$@"
    echo "VoiceStudio is already running (adopted PID: $EXISTING_UVICORN_PID)."
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        echo "Always-on watchdog is active (PID: $(cat "$WATCHDOG_PID_FILE"))."
    fi
    echo "Web Proxy Access URL: ${PROXY_BASE}/proxy/${PORT}/"
    echo "Direct Local Access:   http://127.0.0.1:${PORT}/"
    echo "API Documentation:    ${PROXY_BASE}/proxy/${PORT}/docs"
    echo "API Key:              $OMNIVOICE_API_KEY"
    echo "To restart, run: ./stop-voicestudio.sh && ./start-voicestudio.sh $PORT"
    exit 0
fi

# Check Python virtual environment
VENV_PYTHON="${SCRIPT_DIR}/.venv/bin/python"
if [ ! -x "$VENV_PYTHON" ]; then
    echo "Virtual environment not found at $VENV_PYTHON. Setting up dependencies..."
    node scripts/setup-api.mjs
fi

# Check frontend web build
if [ ! -f "${SCRIPT_DIR}/frontend/dist/index.html" ]; then
    echo "Building web frontend..."
    export PATH="$HOME/.bun/bin:$PATH"
    bun run --cwd electron build:web
fi

echo "=========================================================="
echo " Starting VoiceStudio (OmniVoice)"
echo " Port:       $PORT"
echo " Data dir:   $DATA_DIR"
echo " Log file:   $LOG_FILE"
echo " API Key:    $OMNIVOICE_API_KEY"
echo " Web Proxy:  ${PROXY_BASE}/proxy/${PORT}/"
echo "=========================================================="

if [ "${2:-}" = "--foreground" ]; then
    exec "$VENV_PYTHON" backend/docker_entrypoint.py --host "$OMNIVOICE_BIND_HOST" --port "$PORT"
else
    setsid "$VENV_PYTHON" backend/docker_entrypoint.py --host "$OMNIVOICE_BIND_HOST" --port "$PORT" </dev/null >> "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"
    echo "Started with PID $PID"
    ensure_watchdog "$@"

    # Wait up to 30 seconds for health check
    echo "Waiting for VoiceStudio to be ready..."
    for i in {1..30}; do
        if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            echo ""
            echo " VoiceStudio is ready and running!"
            echo " Web Proxy Access URL: ${PROXY_BASE}/proxy/${PORT}/"
            echo " Direct Local Access:   http://127.0.0.1:${PORT}/"
            echo " API Documentation:    ${PROXY_BASE}/proxy/${PORT}/docs"
            echo " API Key:              $OMNIVOICE_API_KEY"
            echo ""
            echo "To stop: ./stop-voicestudio.sh"
            echo "To view logs: tail -f $LOG_FILE"
            exit 0
        fi
        sleep 1
        printf "."
    done

    echo ""
    echo "Warning: Healthcheck timed out after 30 seconds."
    echo "Check logs at: $LOG_FILE"
fi
