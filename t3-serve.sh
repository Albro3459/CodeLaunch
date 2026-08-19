#!/bin/sh
set -u

T3_DIR="$HOME/.t3"
LOG="$T3_DIR/t3-serve.log"
PIDFILE="$T3_DIR/t3-serve.pid"

mkdir -p "$T3_DIR"

# Make sure npx is actually available in this shell's PATH.
NPX="$(command -v npx)" || {
    echo "npx not found in PATH" >&2
    exit 127
}

# Don't start another copy if our recorded PID is still alive.
if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "t3 serve already running as PID $PID"
        exit 0
    fi

    rm -f "$PIDFILE"
fi

# Fully detach T3 from this shell/SSH session.
nohup "$NPX" --yes t3@latest serve \
    </dev/null \
    >>"$LOG" 2>&1 &

PID=$!
echo "$PID" > "$PIDFILE"

# Give npx a moment to fail immediately if something is wrong.
sleep 1

if kill -0 "$PID" 2>/dev/null; then
    echo "t3 serve started as PID $PID"
    echo "log: $LOG"
else
    echo "t3 serve failed to start; check $LOG" >&2
    rm -f "$PIDFILE"
    exit 1
fi
