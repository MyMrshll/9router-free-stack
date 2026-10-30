#!/usr/bin/env bash
# Install the 9Router -> bridge -> opencode2api -> WARP free-model stack.
#
# Tested on Ubuntu 24.04, Node 22+, Docker (user in docker group), systemd
# user services with linger enabled. No sudo is used by this script.
#
# Overridable environment:
#   BRIDGE_PORT=8787 API_PORT=18080 WEBUI_PORT=18081
#   EXIT_COUNT=6 HTTP_BASE=40051 SOCKS_BASE=40061
#   API_KEY=sk-opencode2api-<host> WIREPROXY_VERSION=1.1.3
#   ROUTER_UNIT=9router ZEN_NEW_PORT=8788
#   FORCE_REGISTER=0 MOVE_ZEN_PROXY=1 SKIP_ROUTER=0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
STACK="$HOME/opencode2api"
SCRIPT_DIR="$HOME/scripts"
BIN_DIR="$HOME/bin"
LOCAL_BIN="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

BRIDGE_PORT="${BRIDGE_PORT:-8787}"
API_PORT="${API_PORT:-18080}"
WEBUI_PORT="${WEBUI_PORT:-18081}"
EXIT_COUNT="${EXIT_COUNT:-6}"
HTTP_BASE="${HTTP_BASE:-40051}"
SOCKS_BASE="${SOCKS_BASE:-40061}"
WIREPROXY_VERSION="${WIREPROXY_VERSION:-1.1.3}"
ROUTER_UNIT="${ROUTER_UNIT:-9router}"
ZEN_NEW_PORT="${ZEN_NEW_PORT:-8788}"
FORCE_REGISTER="${FORCE_REGISTER:-0}"
MOVE_ZEN_PROXY="${MOVE_ZEN_PROXY:-1}"
SKIP_ROUTER="${SKIP_ROUTER:-0}"
API_KEY="${API_KEY:-sk-opencode2api-$(hostname -s 2>/dev/null || echo local)}"
IMAGE="ghcr.io/jasonxu114514/opencode2api:latest"
CONTAINER="opencode2api-laptop"
VOLUME="opencode2api-laptop-state"

say() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Preflight"
for c in node npm python3 openssl curl docker systemctl ss; do
  command -v "$c" >/dev/null || die "missing command: $c"
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 22 ] || die "Node >= 22 required (node:sqlite); found $(node -v)"
docker info >/dev/null 2>&1 || die "cannot talk to Docker; add the user to the docker group and re-login"
systemctl --user show-environment >/dev/null 2>&1 || die "systemd user session unavailable"
[ -d "$FILES" ] || die "files/ directory missing next to install.sh"

NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
NPM_ROOT="$(npm root -g)"
APP_DIR="$NPM_ROOT/9router/app"
if [ "$SKIP_ROUTER" != "1" ] && [ ! -d "$APP_DIR" ]; then
  die "9Router not found at $APP_DIR (install it first: npm i -g 9router), or set SKIP_ROUTER=1"
fi
echo "node: $NODE_BIN ($(node -v))"
echo "9router app: $APP_DIR"
linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
[ "$linger" = "yes" ] || echo "WARN: linger=$linger; services will not start at boot until 'loginctl enable-linger $USER'"

say "Backup"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$HOME/backup/$TS"
mkdir -p "$BK" "$STACK/exits" "$SCRIPT_DIR" "$BIN_DIR" "$LOCAL_BIN" "$UNIT_DIR"
[ -f "$HOME/.9router/db/data.sqlite" ] && cp "$HOME/.9router/db/data.sqlite" "$BK/data.sqlite" || true
[ -f "$HOME/.zen-proxy/zen-proxy.json" ] && cp "$HOME/.zen-proxy/zen-proxy.json" "$BK/zen-proxy.json" || true
if [ -d "$APP_DIR" ]; then
  mkdir -p "$BK/app"
  while IFS= read -r f; do
    [ -n "$f" ] && cp --parents "$f" "$BK/app" 2>/dev/null || true
  done < <(grep -rl --include='*.js' 'headers:{"x-opencode-client":"desktop"}' "$APP_DIR" 2>/dev/null || true)
fi
echo "backup: $BK"

say "wireproxy $WIREPROXY_VERSION"
have_wp=0
if [ -x "$LOCAL_BIN/wireproxy" ] && "$LOCAL_BIN/wireproxy" --version 2>&1 | grep -q "$WIREPROXY_VERSION"; then
  have_wp=1
fi
if [ "$have_wp" -eq 0 ]; then
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  asset="wireproxy_linux_${arch}.tar.gz"
  base="https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}"
  curl -fsSL --max-time 120 -o "$TMP/$asset" "$base/$asset"
  curl -fsSL --max-time 60 -o "$TMP/checksums.txt" "$base/checksums.txt"
  expected="$(awk -v a="$asset" '$2==a {print $1}' "$TMP/checksums.txt")"
  [ -n "$expected" ] || die "checksum for $asset not found"
  actual="$(sha256sum "$TMP/$asset" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "wireproxy checksum mismatch"
  tar xzf "$TMP/$asset" -C "$TMP" wireproxy
  install -m 0755 "$TMP/wireproxy" "$LOCAL_BIN/wireproxy"
fi
"$LOCAL_BIN/wireproxy" --version 2>&1 | head -1

say "Install scripts"
install -m 0755 "$FILES/setup_exits.py" "$STACK/setup_exits.py"
install -m 0755 "$FILES/rotate_wireproxy.py" "$STACK/rotate_wireproxy.py"
install -m 0644 "$FILES/bridge.js" "$STACK/bridge.js"
install -m 0755 "$FILES/warp-watchdog.sh" "$SCRIPT_DIR/warp-watchdog.sh"
install -m 0755 "$FILES/9router-oc-patch.sh" "$BIN_DIR/9router-oc-patch.sh"
node --check "$STACK/bridge.js"
echo "scripts installed"

say "systemd units"
install -m 0644 "$FILES/wireproxy-exit@.service" "$UNIT_DIR/wireproxy-exit@.service"
install -m 0644 "$FILES/warp-watchdog.timer" "$UNIT_DIR/warp-watchdog.timer"
sed -e "s|__NODE_BIN__|$NODE_BIN|g" \
    -e "s|__NODE_DIR__|$NODE_DIR|g" \
    -e "s|__STACK_DIR__|$STACK|g" \
    -e "s|__UID__|$(id -u)|g" \
    -e "s|__BRIDGE_PORT__|$BRIDGE_PORT|g" \
    -e "s|__API_PORT__|$API_PORT|g" \
    -e "s|__API_KEY__|$API_KEY|g" \
    "$FILES/opencode2api-bridge.service.in" > "$UNIT_DIR/opencode2api-bridge.service"
sed -e "s|__UID__|$(id -u)|g" -e "s|__EXIT_COUNT__|$EXIT_COUNT|g" \
    "$FILES/warp-watchdog.service.in" > "$UNIT_DIR/warp-watchdog.service"
systemctl --user daemon-reload

say "zen-proxy (optional port move)"
if [ "$MOVE_ZEN_PROXY" = "1" ] && [ -f "$HOME/.zen-proxy/zen-proxy.json" ]; then
  zport="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.zen-proxy/zen-proxy.json'))).get('port'))")"
  if [ "$zport" = "$BRIDGE_PORT" ]; then
    echo "zen-proxy owns $BRIDGE_PORT; moving it to $ZEN_NEW_PORT"
    python3 - "$HOME/.zen-proxy/zen-proxy.json" "$ZEN_NEW_PORT" <<'PY'
import json, sys
p, port = sys.argv[1], int(sys.argv[2])
c = json.load(open(p))
c['port'] = port
json.dump(c, open(p, 'w'), indent=2)
PY
    systemctl --user restart zen-proxy 2>/dev/null || true
  fi
fi

say "WARP exits"
if [ "$FORCE_REGISTER" = "1" ] || [ ! -f "$STACK/exits/ports.json" ] \
   || [ "$(python3 -c "import json;print(len(json.load(open('$STACK/exits/ports.json'))))" 2>/dev/null || echo 0)" != "$EXIT_COUNT" ]; then
  EXIT_COUNT="$EXIT_COUNT" HTTP_BASE="$HTTP_BASE" SOCKS_BASE="$SOCKS_BASE" python3 "$STACK/setup_exits.py"
else
  echo "reusing existing exits/ports.json (FORCE_REGISTER=1 to re-register)"
fi
for i in $(seq 1 "$EXIT_COUNT"); do
  systemctl --user enable --now "wireproxy-exit@$i"
done
systemctl --user restart $(for i in $(seq 1 "$EXIT_COUNT"); do printf 'wireproxy-exit@%s ' "$i"; done)
sleep 5
alive=0
for i in $(seq 1 "$EXIT_COUNT"); do
  port="$(python3 -c "import json;print(json.load(open('$STACK/exits/ports.json'))['$i']['http'])")"
  if curl -s --max-time 10 -x "http://127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on$'; then
    alive=$((alive + 1))
  fi
done
echo "tunnels alive: $alive/$EXIT_COUNT"
[ "$alive" -gt 0 ] || die "no WARP exit is up; check journalctl --user -u wireproxy-exit@1"

say "opencode2api container"
docker pull "$IMAGE" >/dev/null
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --network host --restart unless-stopped \
  --health-cmd "wget -q -O /dev/null http://127.0.0.1:$API_PORT/healthz || exit 1" \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 15s \
  -v "$VOLUME:/var/lib/opencode2api" "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" test -f /var/lib/opencode2api/config.json 2>/dev/null; then break; fi
  sleep 1
done
docker cp "$CONTAINER:/var/lib/opencode2api/config.json" "$TMP/config.json"
python3 - "$TMP/config.json" "$API_PORT" "$WEBUI_PORT" "$STACK/exits/ports.json" "$API_KEY" <<'PY'
import json, sys
path, api, webui, ports_json, key = sys.argv[1:6]
c = json.load(open(path))
c['listen'] = f'127.0.0.1:{api}'
c['server_keys'] = [key]
c['anonymous'] = True
ports = json.load(open(ports_json))
c['proxies'] = [f"http://127.0.0.1:{v['http']}" for _, v in sorted(ports.items(), key=lambda kv: int(kv[0]))]
c.setdefault('warp', {})['enabled'] = False
perf = c.setdefault('performance', {})
perf.update({
    'attempt_timeout_seconds': 45,
    'first_event_timeout_seconds': 15,
    'free_tier_block_seconds': 60,
    'connect_timeout_seconds': 5,
    'failure_cooldown_seconds': 15,
    'max_anonymous_exits': 8,
})
c.setdefault('webui', {})['listen'] = f'127.0.0.1:{webui}'
json.dump(c, open(path, 'w'), indent=2)
PY
docker cp "$TMP/config.json" "$CONTAINER:/var/lib/opencode2api/config.json"
install -m 0600 "$TMP/config.json" "$STACK/config.json"
docker restart "$CONTAINER" >/dev/null
ok=0
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$API_PORT/v1/models" -H "Authorization: Bearer $API_KEY"; then ok=1; break; fi
  sleep 1
done
[ "$ok" = "1" ] || die "opencode2api did not answer on 127.0.0.1:$API_PORT"
echo "opencode2api: http://127.0.0.1:$API_PORT"

say "bridge"
systemctl --user enable opencode2api-bridge
systemctl --user restart opencode2api-bridge
sleep 2
curl -s -o /dev/null --max-time 5 -H "Authorization: Bearer x" "http://127.0.0.1:$BRIDGE_PORT/v1/models" \
  || die "bridge did not answer on 127.0.0.1:$BRIDGE_PORT"
echo "bridge: http://127.0.0.1:$BRIDGE_PORT"

say "watchdog"
systemctl --user enable --now warp-watchdog.timer
systemctl --user start warp-watchdog.service 2>/dev/null || true

if [ "$SKIP_ROUTER" != "1" ]; then
  say "9Router patch"
  BRIDGE_PORT="$BRIDGE_PORT" "$BIN_DIR/9router-oc-patch.sh" "$APP_DIR"
  systemctl --user stop "$ROUTER_UNIT" 2>/dev/null || true
  if [ -f "$HOME/.9router/db/data.sqlite" ]; then
    node - "$HOME/.9router/db/data.sqlite" <<'JS'
const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');
const db = new DatabaseSync(process.argv[2]);
const now = new Date().toISOString();
const data = JSON.stringify({ apiKey: 'public', testStatus: 'unknown', defaultModel: null });
const row = db.prepare("select id from providerConnections where provider='opencode'").get();
if (row) {
  db.prepare('update providerConnections set isActive=1, data=?, updatedAt=? where id=?')
    .run(data, now, row.id);
  console.log('provider connection updated', row.id);
} else {
  const id = randomUUID();
  db.prepare(`insert into providerConnections
    (id,provider,authType,name,email,priority,isActive,data,createdAt,updatedAt)
    values(?,?,?,?,?,?,?,?,?,?)`)
    .run(id, 'opencode', 'apikey', 'OpenCode Free', null, 1, 1, data, now, now);
  console.log('provider connection created', id);
}
JS
  else
    echo "9Router DB missing; create the OpenCode Free provider in the dashboard" >&2
  fi
  systemctl --user restart "$ROUTER_UNIT"
  sleep 5
  systemctl --user is-active "$ROUTER_UNIT" || die "9router failed to start"
fi

say "Done"
cat <<EOF
Stack is installed.

  bridge          http://127.0.0.1:$BRIDGE_PORT/v1   key: $API_KEY
  opencode2api    http://127.0.0.1:$API_PORT/v1   key: $API_KEY
  9router         http://127.0.0.1:20128/v1
  WARP exits      $EXIT_COUNT HTTP proxies on ${HTTP_BASE}-$((HTTP_BASE + EXIT_COUNT - 1))
  logs            /tmp/bridge-requests.log, journalctl --user -u opencode2api-bridge
  backup          $BK

Verify with: $HERE/verify.sh
EOF
