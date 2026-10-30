#!/usr/bin/env python3
"""Rotate wireproxy exits by switching WARP endpoints (no re-registration).

Each exit gets a different endpoint, its systemd unit is restarted, and the
tunnel is verified through the exit's HTTP proxy. Prints a JSON summary.
"""
import json
import os
import random
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
BASE = os.environ.get("STACK_DIR", os.path.join(HOME, "opencode2api"))
EXITS = os.path.join(BASE, "exits")
PORTS = os.path.join(EXITS, "ports.json")

ENDPOINTS = [
    "188.114.98.1:2408", "188.114.97.1:2408", "188.114.99.1:2408",
    "188.114.96.1:2408", "162.159.195.1:2408", "162.159.192.1:2408",
    "188.114.98.2:2408", "188.114.97.2:2408", "188.114.99.2:2408",
    "188.114.96.2:2408", "162.159.195.2:2408", "162.159.192.2:2408",
]

TRACE = "https://www.cloudflare.com/cdn-cgi/trace"


def probe(port, timeout=8):
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", str(timeout), "-x", f"http://127.0.0.1:{port}", TRACE],
            capture_output=True, text=True, timeout=timeout + 3,
        ).stdout
        data = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        if data.get("warp") == "on":
            return data.get("ip", "")
    except Exception:
        pass
    return ""


def current_endpoint(conf_path):
    try:
        with open(conf_path) as f:
            m = re.search(r"^Endpoint\s*=\s*(\S+)", f.read(), re.M)
            return m.group(1) if m else ""
    except OSError:
        return ""


def set_endpoint(conf_path, endpoint):
    with open(conf_path) as f:
        text = f.read()
    text = re.sub(r"^Endpoint\s*=\s*\S+", f"Endpoint = {endpoint}", text, flags=re.M)
    with open(conf_path, "w") as f:
        f.write(text)


def main():
    with open(PORTS) as f:
        ports = json.load(f)
    alive = 0
    blocks = {}
    pool = ENDPOINTS[:]
    random.shuffle(pool)
    idx = 0
    for key in sorted(ports, key=int):
        n = int(key)
        port = ports[key]["http"]
        conf = os.path.join(EXITS, f"wireproxy-{n}.conf")
        current = current_endpoint(conf)
        candidates = [e for e in pool[idx:] + pool[:idx] if e != current] or pool
        chosen = None
        ip = ""
        for ep in candidates[:5]:
            set_endpoint(conf, ep)
            subprocess.run(["systemctl", "--user", "restart", f"wireproxy-exit@{n}"],
                           check=False, capture_output=True)
            time.sleep(1.2)
            ip = probe(port)
            if ip:
                chosen = ep
                break
        idx += 1
        if chosen:
            alive += 1
            blocks[str(port)] = ":".join(ip.split(":")[:4])
    print(json.dumps({"exits": len(ports), "alive": alive, "blocks": blocks}))
    return 0 if alive else 1


if __name__ == "__main__":
    sys.exit(main())
