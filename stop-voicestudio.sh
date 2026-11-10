#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATA_DIR="${OMNIVOICE_DATA_DIR:-${SCRIPT_DIR}/omnivoice_data}"
PID_FILE="${DATA_DIR}/omnivoice.pid"
WATCHDOG_PID_FILE="${DATA_DIR}/watchdog.pid"
STOP_SENTINEL="${DATA_DIR}/.stopped"

mkdir -p "$DATA_DIR"
touch "$STOP_SENTINEL"

STOPPED=0

# Stop the always-on watchdog first so it doesn't respawn VoiceStudio
if [ -f "$WATCHDOG_PID_FILE" ]; then
    WD_PID="$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)"
    if [ -n "$WD_PID" ] && kill -0 "$WD_PID" 2>/dev/null; then
        echo "Stopping VoiceStudio watchdog (PID $WD_PID)..."
        kill "$WD_PID" 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_PID_FILE"
fi
pkill -f "watchdog-voicestudio.sh" 2>/dev/null || true

if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping VoiceStudio (PID $PID)..."
        kill "$PID" 2>/dev/null || true
        for i in {1..10}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null || true
        fi
        echo "VoiceStudio stopped."
        STOPPED=1
    fi
    rm -f "$PID_FILE"
fi

# Fallback: check any remaining uvicorn backend.main:app processes
REMAINING_PIDS=$(pgrep -f "uvicorn.*backend.main:app" || true)
if [ -n "$REMAINING_PIDS" ]; then
    echo "Cleaning up lingering VoiceStudio processes: $REMAINING_PIDS"
    kill $REMAINING_PIDS 2>/dev/null || true
    sleep 1
    kill -9 $REMAINING_PIDS 2>/dev/null || true
    STOPPED=1
fi

if [ $STOPPED -eq 0 ]; then
    echo "No running VoiceStudio instance found."
fi
