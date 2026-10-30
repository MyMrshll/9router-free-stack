#!/usr/bin/env python3
"""Create N WireGuard/WARP profiles for wireproxy exits.

Registers a fresh WARP identity per exit, writes exits/wireproxy-<n>.conf and
exits/ports.json. Port layout (overridable via environment):
  HTTP  : HTTP_BASE..HTTP_BASE+N-1   (default 40051..)
  SOCKS : SOCKS_BASE..SOCKS_BASE+N-1 (default 40061..)

Environment:
  STACK_DIR, EXIT_COUNT, HTTP_BASE, SOCKS_BASE
"""
import base64
import json
import os
import random
import string
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
BASE = os.environ.get("STACK_DIR", os.path.join(HOME, "opencode2api"))
EXITS = os.path.join(BASE, "exits")
N = int(os.environ.get("EXIT_COUNT", "6"))
HTTP_BASE = int(os.environ.get("HTTP_BASE", "40051"))
SOCKS_BASE = int(os.environ.get("SOCKS_BASE", "40061"))

ENDPOINTS = [
    "188.114.98.1:2408", "188.114.97.1:2408", "188.114.99.1:2408",
    "188.114.96.1:2408", "162.159.195.1:2408", "162.159.192.1:2408",
    "188.114.98.2:2408", "188.114.97.2:2408", "188.114.99.2:2408",
    "188.114.96.2:2408", "162.159.195.2:2408", "162.159.192.2:2408",
]


def keypair():
    pem = subprocess.run(["openssl", "genpkey", "-algorithm", "x25519"],
                         stdout=subprocess.PIPE, check=True).stdout
    txt = subprocess.run(["openssl", "pkey", "-noout", "-text"], input=pem,
                         stdout=subprocess.PIPE, check=True).stdout.decode()
    priv_hex, recording = "", False
    for line in txt.split("\n"):
        if "priv:" in line:
            recording = True
            continue
        if "pub:" in line:
            break
        if recording:
            priv_hex += line.strip().replace(":", "")
    priv_b64 = base64.b64encode(bytes.fromhex(priv_hex)).decode()
    pub_der = subprocess.run(["openssl", "pkey", "-pubout", "-outform", "DER"],
                             input=pem, stdout=subprocess.PIPE, check=True).stdout
    pub_b64 = base64.b64encode(pub_der[-32:]).decode()
    return priv_b64, pub_b64


def register(pub_b64):
    install_id = "".join(random.choices(string.ascii_letters + string.digits, k=22))
    data = {
        "key": pub_b64,
        "install_id": install_id,
        "fcm_token": "",
        "tos": "2020-09-01T00:00:00.000+02:00",
        "model": "PC",
        "serial_number": install_id,
        "locale": "en_US",
    }
    req = urllib.request.Request(
        "https://api.cloudflareclient.com/v0a2158/reg",
        data=json.dumps(data).encode(),
        headers={"User-Agent": "okhttp/3.12.1",
                 "Content-Type": "application/json; charset=UTF-8"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        r = json.loads(resp.read().decode())
    cfg = r["config"]
    return {
        "v4": cfg["interface"]["addresses"]["v4"],
        "v6": cfg["interface"]["addresses"]["v6"],
        "peer_pub": cfg["peers"][0]["public_key"],
    }


def conf(priv_b64, prof, http_port, socks_port, endpoint):
    return f"""[Interface]
PrivateKey = {priv_b64}
Address = {prof['v4']}/32, {prof['v6']}/128
DNS = 1.1.1.1

[Peer]
PublicKey = {prof['peer_pub']}
Endpoint = {endpoint}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 10

[Socks5]
BindAddress = 127.0.0.1:{socks_port}

[Http]
BindAddress = 127.0.0.1:{http_port}
"""


def main():
    os.makedirs(EXITS, exist_ok=True)
    endpoints = ENDPOINTS[:]
    random.shuffle(endpoints)
    ports = {}
    for i in range(N):
        last = None
        for attempt in range(4):
            try:
                priv, pub = keypair()
                last = (priv, register(pub))
                break
            except Exception as e:  # noqa: BLE001
                last = None
                print(f"exit {i+1}: register attempt {attempt+1} failed: {e}",
                      file=sys.stderr)
                time.sleep(2 + attempt * 2)
        if not last:
            raise SystemExit(f"exit {i+1}: could not register a WARP profile")
        priv, prof = last
        http_port = HTTP_BASE + i
        socks_port = SOCKS_BASE + i
        endpoint = endpoints[i % len(endpoints)]
        path = os.path.join(EXITS, f"wireproxy-{i+1}.conf")
        with open(path, "w") as f:
            f.write(conf(priv, prof, http_port, socks_port, endpoint))
        os.chmod(path, 0o600)
        ports[str(i + 1)] = {"http": http_port, "socks": socks_port,
                             "endpoint": endpoint, "v6": prof["v6"]}
        print(f"exit {i+1}: http={http_port} endpoint={endpoint}")
        time.sleep(0.5)
    with open(os.path.join(EXITS, "ports.json"), "w") as f:
        json.dump(ports, f, indent=2)
    print(json.dumps({"exits": N, "ports": ports}, indent=2))


if __name__ == "__main__":
    main()
