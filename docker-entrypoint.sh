#!/bin/sh
set -e

CONFIG_SRC="/app/config.container.toml"
CONFIG_DST="/zeroclaw-data/.zeroclaw/config.toml"
MEMORY_DIR="/zeroclaw-data/workspace/memory"
S3_STATE="/s3-state"
BRAIN_DB="brain.db"

mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace "$MEMORY_DIR"

# Substitute env vars into config
sed "s|\${TELEGRAM_BOT_TOKEN}|${TELEGRAM_BOT_TOKEN}|g" "$CONFIG_SRC" > "$CONFIG_DST"

# ── Restore brain.db from S3 state on startup ──────────────
if [ -f "$S3_STATE/$BRAIN_DB" ]; then
    echo "[entrypoint] Restoring $BRAIN_DB from S3 state..."
    cp "$S3_STATE/$BRAIN_DB" "$MEMORY_DIR/$BRAIN_DB"
    echo "[entrypoint] Restored $(wc -c < "$MEMORY_DIR/$BRAIN_DB") bytes"
else
    echo "[entrypoint] No $BRAIN_DB found in S3 state, starting fresh"
fi

# ── Save brain.db to S3 state on shutdown ──────────────────
save_state() {
    if [ -f "$MEMORY_DIR/$BRAIN_DB" ]; then
        echo "[entrypoint] Saving $BRAIN_DB to S3 state..."
        cp "$MEMORY_DIR/$BRAIN_DB" "$S3_STATE/$BRAIN_DB" || echo "[entrypoint] WARNING: failed to save $BRAIN_DB to S3"
        echo "[entrypoint] Saved $(wc -c < "$MEMORY_DIR/$BRAIN_DB") bytes"
    else
        echo "[entrypoint] No $BRAIN_DB to save"
    fi
}

# Trap SIGTERM (Kubernetes sends this before SIGKILL) and SIGINT
cleanup() {
    echo "[entrypoint] Signal received, shutting down..."
    # Forward signal to zeroclaw so it can clean up
    kill -TERM "$ZEROCLAW_PID" 2>/dev/null || true
    wait "$ZEROCLAW_PID" 2>/dev/null || true
    save_state
    exit 0
}
trap cleanup TERM INT

# Run zeroclaw in the background so the trap can fire
zeroclaw daemon --config-dir /zeroclaw-data/.zeroclaw "$@" &
ZEROCLAW_PID=$!

# Wait for zeroclaw to exit (or for a signal)
wait $ZEROCLAW_PID
EXIT_CODE=$?

# Save state on normal exit too
save_state

exit $EXIT_CODE
