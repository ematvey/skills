#!/bin/sh
# big-job-cleanup.sh — Remove finished jobs older than N days.
#
# Usage: big-job-cleanup.sh [DAYS]
#
# DAYS defaults to 7. Removes jobs whose created_at is older than DAYS.
# Running jobs are never removed.
#
# Exit codes: 0=ok

DAYS="${1:-7}"
JOBS_DIR="${BIG_JOB_DIR:-$HOME/.local/share/big-job}"
CUTOFF=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || \
CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%S 2>/dev/null) || \
{ echo "Cannot compute cutoff date" >&2; exit 1; }

if [ ! -d "$JOBS_DIR" ]; then
    echo "No jobs directory found."
    exit 0
fi

removed=0
for d in "$JOBS_DIR"/*/; do
    [ -d "$d" ] || continue

    # Skip jobs that are still running
    if [ ! -f "$d/exit_code" ]; then
        # Check systemd unit
        ID=$(basename "$d")
        UNIT_NAME="big-job-$ID"
        if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
            STATE=$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)
            case "$STATE" in active|activating) continue ;; esac
        fi
        # Check PID
        PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$d/meta.json" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            continue
        fi
    fi

    # Check if job was created before the cutoff
    CREATED=$(sed -n 's/.*"created_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null | head -1)
    [ -n "$CREATED" ] || continue
    # Normalize to comparable format (first 19 chars: YYYY-MM-DDTHH:MM:SS)
    CREATED=$(printf '%.19s' "$CREATED")
    if [ "$CREATED" \< "$CUTOFF" ] || [ "$CREATED" = "$CUTOFF" ]; then
        ID=$(basename "$d")
        rm -rf "$d"
        echo "Removed $ID"
        removed=$((removed + 1))
    fi
done

echo "Cleanup complete: $removed job(s) removed (older than $DAYS days)."
