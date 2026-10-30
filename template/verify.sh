#!/usr/bin/env bash
# Verify every layer of the stack. Exit code 0 only if all hard checks pass.
#
# Env: BRIDGE_PORT, API_PORT, ROUTER_PORT, EXIT_COUNT, API_KEY, ROUTER_KEY
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$HOME/opencode2api"
BRIDGE_PORT="${BRIDGE_PORT:-8787}"
API_PORT="${API_PORT:-18080}"
ROUTER_PORT="${ROUTER_PORT:-20128}"
EXIT_COUNT="${EXIT_COUNT:-6}"
API_KEY="${API_KEY:-}"
if [ -z "$API_KEY" ] && [ -f "$STACK/config.json" ]; then
  API_KEY="$(python3 -c "import json;print((json.load(open('$STACK/config.json')).get('server_keys') or [''])[0])" 2>/dev/null)"
fi
API_KEY="${API_KEY:-change-me-local-key}"

ROUTER_KEY="${ROUTER_KEY:-}"
if [ -z "$ROUTER_KEY" ] && [ -f "$HOME/.9router/db/data.sqlite" ]; then
  ROUTER_KEY="$(node - "$HOME/.9router/db/data.sqlite" 2>/dev/null <<'JS'
const { DatabaseSync } = require('node:sqlite');
try {
  const db = new DatabaseSync(process.argv[2], { readOnly: true });
  const row = db.prepare('select key from apiKeys where isActive=1 limit 1').get();
  if (row) process.stdout.write(row.key);
} catch (e) { /* ignore */ }
JS
)"
fi

ROUTER_UNIT="${ROUTER_UNIT:-9router}"
fail=0
pass() { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

echo "== services =="
for u in "$ROUTER_UNIT" opencode2api-bridge warp-watchdog.timer; do
  st="$(systemctl --user is-active "$u" 2>/dev/null)"
  [ "$st" = "active" ] && pass "$u active" || bad "$u is $st"
done
if [ -f "$HOME/.zen-proxy/zen-proxy.json" ]; then
  st="$(systemctl --user is-active zen-proxy 2>/dev/null)"
  [ "$st" = "active" ] && pass "zen-proxy active" || bad "zen-proxy is $st"
fi
for i in $(seq 1 "$EXIT_COUNT"); do
  st="$(systemctl --user is-active "wireproxy-exit@$i" 2>/dev/null)"
  [ "$st" = "active" ] && pass "wireproxy-exit@$i active" || bad "wireproxy-exit@$i is $st"
done

echo "== container =="
cst="$(docker inspect -f '{{.State.Health.Status}}' opencode2api-laptop 2>/dev/null)"
[ "$cst" = "healthy" ] && pass "opencode2api-laptop healthy" || bad "opencode2api-laptop health: ${cst:-missing}"

echo "== http layers =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:$API_PORT/v1/models")"
[ "$code" = "200" ] && pass "opencode2api :$API_PORT -> 200" || bad "opencode2api :$API_PORT -> $code"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer x" "http://127.0.0.1:$BRIDGE_PORT/v1/models")"
[ "$code" = "200" ] && pass "bridge :$BRIDGE_PORT -> 200" || bad "bridge :$BRIDGE_PORT -> $code"
if [ -n "$ROUTER_KEY" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $ROUTER_KEY" "http://127.0.0.1:$ROUTER_PORT/v1/models")"
  [ "$code" = "200" ] && pass "9router :$ROUTER_PORT -> 200" || bad "9router :$ROUTER_PORT -> $code"
else
  bad "no 9Router API key found (set ROUTER_KEY)"
fi

echo "== warp tunnels =="
alive=0
if [ -f "$STACK/exits/ports.json" ]; then
  for i in $(seq 1 "$EXIT_COUNT"); do
    port="$(python3 -c "import json;print(json.load(open('$STACK/exits/ports.json'))['$i']['http'])" 2>/dev/null)"
    [ -n "$port" ] || continue
    if curl -s --max-time 10 -x "http://127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on$'; then
      alive=$((alive + 1))
    fi
  done
fi
[ "$alive" -eq "$EXIT_COUNT" ] && pass "$alive/$EXIT_COUNT exits warp=on" || bad "$alive/$EXIT_COUNT exits warp=on"

echo "== end to end =="
if [ -n "$ROUTER_KEY" ]; then
  body="$(curl -s --max-time 90 -X POST "http://127.0.0.1:$ROUTER_PORT/v1/chat/completions" \
    -H "Authorization: Bearer $ROUTER_KEY" -H 'Content-Type: application/json' \
    -d '{"model":"oc/deepseek-v4.1-flash-free","stream":false,"max_tokens":16,"messages":[{"role":"user","content":"Balas hanya: OK"}]}')"
  text="$(printf '%s' "$body" | python3 -c "import json,sys;d=json.load(sys.stdin);print(((d.get('choices') or [{}])[0].get('message') or {}).get('content') or '')" 2>/dev/null)"
  [ -n "$text" ] && pass "chat oc/deepseek-v4.1-flash-free -> ${text:0:20}" || bad "chat failed: ${body:0:120}"
fi

echo "== tool alias round trip =="
body="$(curl -s --max-time 90 -X POST "http://127.0.0.1:$BRIDGE_PORT/v1/chat/completions" \
  -H "Authorization: Bearer x" -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash-free","stream":false,"max_tokens":64,"messages":[{"role":"user","content":"run echo hi"}],"tools":[{"type":"function","function":{"name":"terminal","description":"run","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}],"tool_choice":{"type":"function","function":{"name":"terminal"}}}')"
if printf '%s' "$body" | grep -q '"name":"terminal"' && ! printf '%s' "$body" | grep -q 'oc2api_t0'; then
  pass "terminal restored, no alias leak"
else
  bad "tool alias round trip: ${body:0:160}"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$fail CHECK(S) FAILED"
fi
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
