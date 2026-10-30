#!/bin/bash
# Watchdog for the wireproxy WARP exits.
# Probes the tunnel itself (trace prints warp=on). Restarts the unit when the
# tunnel is dead; rotates endpoints only when a restart is not enough.
EXIT_COUNT="${EXIT_COUNT:-6}"
STACK_DIR="${STACK_DIR:-$HOME/opencode2api}"
LOG="$HOME/scripts/warp-watchdog.log"
PORTS_JSON="$STACK_DIR/exits/ports.json"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

probe() {
  curl -s --max-time 8 -x "http://127.0.0.1:$1" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep -q '^warp=on$'
}

[ -f "$PORTS_JSON" ] || { log "ports.json missing"; exit 1; }

bad=0
for n in $(seq 1 "$EXIT_COUNT"); do
  port=$(python3 -c "import json;print(json.load(open('$PORTS_JSON'))['$n']['http'])" 2>/dev/null)
  [ -n "$port" ] || { log "exit $n: no port mapping"; bad=1; continue; }
  if probe "$port"; then continue; fi
  log "exit $n (port $port) down, restarting unit"
  systemctl --user restart "wireproxy-exit@$n"
  sleep 2
  if probe "$port"; then
    log "exit $n recovered"
  else
    log "exit $n still down, rotating"
    bad=1
  fi
done

if [ "$bad" -ne 0 ]; then
  out=$(STACK_DIR="$STACK_DIR" python3 "$STACK_DIR/rotate_wireproxy.py" 2>&1)
  rc=$?
  log "rotate rc=$rc $out"
fi
exit 0
