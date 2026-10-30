# Runbook — 9Router + OpenCode Free (laptop `shall`)

Semua perintah di bawah dijalankan sebagai user `shall` (tanpa sudo), kecuali
yang ditandai.

## 1. Cek status cepat

```bash
# service
for s in 9router zen-proxy opencode2api-bridge warp-watchdog.timer; do
  printf "%-22s %s\n" "$s" "$(systemctl --user is-active $s)"
done
for i in 1 2 3 4 5 6; do printf "exit@%s=%s " $i "$(systemctl --user is-active wireproxy-exit@$i)"; done; echo

# container
docker ps --filter name=opencode2api-laptop --format '{{.Names}} {{.Status}}'

# port
ss -lntp | grep -E ':(20128|8787|8788|18080|4005[1-6])\b'
```

Health:

```bash
curl -s http://127.0.0.1:8787/v1/models -H 'Authorization: Bearer x' -o /dev/null -w 'bridge %{http_code}\n'
curl -s http://127.0.0.1:18080/v1/models -H 'Authorization: Bearer sk-opencode2api-<hostname>' -o /dev/null -w 'api %{http_code}\n'
curl -s http://127.0.0.1:20128/v1/models -H 'Authorization: Bearer sk-ROUTER-KEY-PLACEHOLDER' -o /dev/null -w '9router %{http_code}\n'
curl -s http://127.0.0.1:8788/health; echo
```

Cek tunnel WARP:

```bash
for p in 40051 40052 40053 40054 40055 40056; do
  printf '%s ' $p
  curl -s --max-time 10 -x http://127.0.0.1:$p https://www.cloudflare.com/cdn-cgi/trace \
    | awk -F= '/^warp=/{w=$2} /^ip=/{ip=$2} END{print (w?w:"DOWN"), ip}'
done
```

## 2. Cara memakai dari klien

| Setting | Nilai |
|---|---|
| Base URL | `http://127.0.0.1:20128/v1` |
| API key | `sk-ROUTER-KEY-PLACEHOLDER` |
| Model | `oc/<salah satu model di bawah>` |

Model free yang tersedia (passthrough):

```
oc/deepseek-v4.1-flash-free
oc/mimo-v2.6-flash-free
oc/big-pickle
oc/beam-free
oc/flint-40b-free
oc/glm-5.3-flash-free
oc/nemotron-3.5-lightning-free
oc/nemotron-3.5-super-vl-free
```

> `/v1/models` 9Router hanya menampilkan 4 model statis `oc/*`. Model lain tetap
> bisa dipanggil karena provider `oc` memakai passthrough.

Jika ingin memakai bridge langsung (tanpa 9Router): base URL
`http://127.0.0.1:8787/v1`, key apa pun (di-override bridge).

Jika ingin memakai zen-proxy: base URL `http://127.0.0.1:8788/v1`, key `public`.

### Klien yang sudah disambungkan

**OpenCode** (`~/.config/opencode/opencode.json`)

Provider `9router` (OpenAI-compatible) ditambahkan:

```json
"9router": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "9Router (local)",
  "options": {
    "baseURL": "http://127.0.0.1:20128/v1",
    "apiKey": "sk-ROUTER-KEY-PLACEHOLDER"
  },
  "models": {
    "oc/deepseek-v4.1-flash-free": { "name": "deepseek-v4.1-flash-free" }
  }
}
```

Pemakaian:

```bash
opencode models | grep 9router
opencode run -m 9router/oc/deepseek-v4.1-flash-free "halo"
```

Default `model` sengaja tidak diubah (masih `explabs/gpt-6-astra`). Untuk
menjadikannya default, ubah `"model": "9router/oc/deepseek-v4.1-flash-free"`.
Jika daftar model belum berubah, restart server OpenCode:
`opencode service restart` (akan memutus sesi yang sedang berjalan).

**Hermes** (`~/.hermes/config.yaml`)

```yaml
model:
  default: "oc/deepseek-v4.1-flash-free"
  provider: "local-localhost-20128"
  base_url: "http://127.0.0.1:20128/v1"
  api_mode: chat_completions
  key_env: HERMES_CUSTOM_LOCAL_LOCALHOST_20128_API_KEY
```

Provider `custom:opencode2api` (langsung ke `:18080`) juga diperbaiki:
`api_key: sk-opencode2api-<hostname>` dan env `HERMES_CUSTOM_OPENCODE2API_API_KEY`
ditambahkan. Uji:

```bash
hermes -z "Balas hanya: OK"
hermes --yolo -z "Jalankan perintah shell: echo halo-hermes"
```


## 3. Urutan restart yang benar

```bash
# WARP dulu
systemctl --user restart wireproxy-exit@1 wireproxy-exit@2 wireproxy-exit@3 \
  wireproxy-exit@4 wireproxy-exit@5 wireproxy-exit@6

# lalu API container
docker restart opencode2api-laptop
sleep 8

# lalu bridge dan 9Router
systemctl --user restart opencode2api-bridge
systemctl --user restart 9router
```

## 4. Log yang berguna

```bash
tail -f /tmp/bridge-requests.log          # request bridge, ALIAS, ROTATE, API_DOWN
ls -lt /tmp/bridge-fail | head            # dump respons non-200
journalctl --user -u opencode2api-bridge -n 50 --no-pager
journalctl --user -u wireproxy-exit@1 -n 50 --no-pager
journalctl --user -u 9router -n 50 --no-pager
docker logs --tail 50 opencode2api-laptop
tail -n 20 ~/scripts/warp-watchdog.log
```

## 4b. Membuat ulang container `opencode2api` (jika perlu)

Config efektif tersimpan di volume `opencode2api-laptop-state`, jadi container
boleh dihapus/dibuat ulang. Healthcheck harus diarahkan ke port `18080` (bawaan
image memakai `8080`).

```bash
docker rm -f opencode2api-laptop
docker run -d --name opencode2api-laptop --network host --restart unless-stopped \
  --health-cmd 'wget -q -O /dev/null http://127.0.0.1:18080/healthz || exit 1' \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 15s \
  -v opencode2api-laptop-state:/var/lib/opencode2api \
  ghcr.io/jasonxu114514/opencode2api:latest
```

## 5. Rotasi manual

```bash
python3 ~/opencode2api/rotate_wireproxy.py
```

Rotasi hanya mengganti endpoint (cepat, tanpa registrasi baru). Jika semua exit
mati, jalankan ulang registrasi:

```bash
python3 ~/opencode2api/setup_exits.py
systemctl --user restart wireproxy-exit@1 wireproxy-exit@2 wireproxy-exit@3 \
  wireproxy-exit@4 wireproxy-exit@5 wireproxy-exit@6
```

## 6. Setelah update 9Router (`npm i -g 9router`)

Patch `baseUrl` hilang setiap update. Jalankan:

```bash
~/bin/9router-oc-patch.sh
systemctl --user restart 9router
```

Lalu pastikan provider `oc` masih ada di dashboard. Jika koneksi provider hilang,
buat ulang lewat dashboard: Providers → OpenCode Free → API key apa pun (mis.
`public`) → aktifkan.

## 7. Troubleshooting

| Gejala | Cek | Tindakan |
|---|---|---|
| `429 FreeUsageLimitError` | `python3 ~/opencode2api/rotate_wireproxy.py`, cek `/64` tiap exit | rotasi; kalau semua `/64` sama, registrasi ulang `setup_exits.py` |
| `502` dari 9Router | `curl :8787/v1/models` | bridge mati → `systemctl --user restart opencode2api-bridge` |
| `503 all proxies are unavailable` | cek 6 port `trace` | restart exit yang mati / jalankan watchdog |
| Chat tidak dibalas | `docker ps`, `:18080/v1/models` | container mati → `docker start opencode2api-laptop`; bridge akan retry 10×3 s |
| Tool call kembali `oc2api_t0` | versi bridge | pastikan bridge versi terbaru (renamer + hapus content-length) |
| Semua model 429 | `curl :8788/api/status` | kuota/gate upstream; tunggu window reset |

## 8. Rollback

Lihat bagian **Rollback** di `LAPORAN-SETUP-LAPTOP.md`.

## 9. Batas yang diketahui

- Kuota tetap per `/64` dan per model. Rotasi adalah mitigasi, bukan kuota tak terbatas.
- Registrasi WARP terlalu sering bisa dibalas 429 oleh `api.cloudflareclient.com`.
- Stack bergantung pada Docker (enabled) dan linger (aktif).
- Pindah Wi-Fi bisa memutus tunnel WARP; watchdog 2 menit akan memulihkan.
