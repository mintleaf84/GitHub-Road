#!/bin/bash
# github-road-daemon.sh -- resident self-heal loop for machines with NO cron
# daemon (containers, proot, systemd-less boxes): the crontab entry installed
# by install.sh is inert there, so run this instead.
#
# Single instance via flock. Interval: GITHUB_ROAD_INTERVAL seconds (default
# 1800). Start:  nohup bash github-road-daemon.sh >> ~/.hermes/github-road.log 2>&1 &
# Stop:   kill <pid>   (the lock fd is released on exit)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT="$HERE/select-github-ip.sh"
INTERVAL="${GITHUB_ROAD_INTERVAL:-1800}"
LOG="${GITHUB_ROAD_LOG:-$HOME/.hermes/github-road.log}"
LOCK="$HOME/.hermes/.github-road-daemon.lock"

command -v flock >/dev/null 2>&1 || { echo "[daemon] ERROR: flock not found" >&2; exit 1; }
[ -f "$SELECT" ] || { echo "[daemon] ERROR: $SELECT not found" >&2; exit 1; }
mkdir -p "$(dirname "$LOCK")"

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[daemon] another instance is already running - exit"
    exit 0
fi
echo $$ >&9  # record the pid for troubleshooting (flock ignores the content)

logline() { printf '%s [daemon] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }
child=""
stop() { logline "stopped (pid $$)"; [ -n "$child" ] && kill "$child" 2>/dev/null; exit 0; }
trap stop TERM INT

logline "started (pid $$, interval ${INTERVAL}s, select=$SELECT)"
while :; do
    # Run select and the nap as background children so the TERM trap fires
    # immediately (a trap is deferred while a FOREGROUND child runs).
    # 9>&- : children must NOT inherit the lock fd, or the lock would stay
    # held after this daemon exits (e.g. a lingering select grandchild).
    GITHUB_ROAD_QUIET=1 GITHUB_ROAD_LOG="$LOG" bash "$SELECT" >>"$LOG" 2>&1 9>&- &
    child=$!
    wait "$child" 2>/dev/null
    child=""
    sleep "$INTERVAL" 9>&- &
    child=$!
    wait "$child" 2>/dev/null
    child=""
done
