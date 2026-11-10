#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-${OMNIVOICE_PORT:-3900}}"

echo "=== VoiceStudio Status ==="
if curl -sf "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
    echo ""
    echo "Service is healthy and responding on port $PORT"
    DETECTED_HOST=""
    if [ -n "$VSCODE_PROXY_URI" ]; then
        DETECTED_HOST="$(echo "$VSCODE_PROXY_URI" | sed -E 's|(https?://[^/]+).*|\1|')"
    fi
    PROXY_HOST="${CODE_SERVER_PROXY_HOST:-${DETECTED_HOST:-https://code.zuelligpharma.com}}"
    echo "Web Proxy URL: ${PROXY_HOST}/proxy/${PORT}/"
    echo "Local URL:     http://127.0.0.1:${PORT}/"
    if [ -f "${SCRIPT_DIR}/omnivoice_data/omnivoice.pid" ]; then
        echo "Server PID:    $(cat "${SCRIPT_DIR}/omnivoice_data/omnivoice.pid")"
    fi
    if [ -f "${SCRIPT_DIR}/omnivoice_data/watchdog.pid" ] && kill -0 "$(cat "${SCRIPT_DIR}/omnivoice_data/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
        echo "Watchdog:      ACTIVE (PID $(cat "${SCRIPT_DIR}/omnivoice_data/watchdog.pid")) - Auto-restart enabled"
    else
        echo "Watchdog:      INACTIVE"
    fi
    if [ -f "${SCRIPT_DIR}/omnivoice_data/.api_key" ]; then
        echo "API Key:       $(cat "${SCRIPT_DIR}/omnivoice_data/.api_key")"
    fi
else
    echo "Service is NOT running or not responding on port $PORT"
fi
