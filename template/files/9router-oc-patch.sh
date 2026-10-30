#!/usr/bin/env bash
# Re-apply the 9Router "OpenCode Free" baseUrl patch after an npm update.
#
# 9Router ships the built-in provider `opencode` (alias `oc`) pointing at
# https://opencode.ai. This stack needs it to point at the local bridge.
# The bundle is minified and filenames change between versions, so we scan the
# whole app tree for the transport fragment and replace it in place.
#
# Usage: 9router-oc-patch.sh [APP_DIR]
# Env:   BRIDGE_PORT (default 8787)
set -euo pipefail

ROOT="${1:-$(npm root -g)/9router/app}"
BRIDGE_PORT="${BRIDGE_PORT:-8787}"
URL="http://127.0.0.1:${BRIDGE_PORT}"

if [ ! -d "$ROOT" ]; then
  echo "app dir not found: $ROOT" >&2
  exit 1
fi

python3 - "$ROOT" "$URL" <<'PY'
import os, re, sys

root, url = sys.argv[1], sys.argv[2]
pat = re.compile(r'baseUrl:"[^"]*",headers:\{"x-opencode-client":"desktop"\}')
repl = f'baseUrl:"{url}",headers:{{"x-opencode-client":"desktop"}}'
changed = []
for dp, _, files in os.walk(root):
    for name in files:
        if not name.endswith('.js'):
            continue
        p = os.path.join(dp, name)
        try:
            s = open(p, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        new, n = pat.subn(repl, s)
        if n:
            open(p, 'w', encoding='utf-8').write(new)
            changed.append((os.path.relpath(p, root), n))
for p, n in changed:
    print(f'patched {n}x {p}')
if not changed:
    print('nothing to patch (already patched, or upstream bundle changed)')
PY

echo "restart 9router to apply: systemctl --user restart 9router"
