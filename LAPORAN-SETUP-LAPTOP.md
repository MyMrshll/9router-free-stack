# Laporan Setup 9Router dan OpenCode di Laptop

**Tanggal:** 30 Oktober 2026 (16:50 WIB)
**Host:** `shall` — Ubuntu 24.04.5, kernel 7.0.0-38, Node v26.12.1, Bun
**Zona waktu:** Asia/Jakarta (WIB), NTP aktif

## Status umum

Stack lengkap ala `9router.md` sudah diterapkan di laptop ini dan terverifikasi
end-to-end. Semua komponen berjalan sebagai **systemd user service** (kecuali
`opencode2api` yang berjalan di Docker). **Tidak ada langkah yang memakai sudo.**

Perbedaan yang disengaja dari `9router.md`: `zen-proxy` tidak dimatikan, tetapi
dipindah ke port `8788` sebagai jalur pembanding/rollback. Bridge menempati
`8787` persis seperti di transkrip.

## Arsitektur

```
klien
  → 9Router            127.0.0.1:20128   (oc/<model>)
  → bridge.js          127.0.0.1:8787    (alias tool, retry, rotasi)
  → opencode2api       127.0.0.1:18080   (Docker, host network)
  → wireproxy 1..6     127.0.0.1:40051–40056 (WARP)
  → opencode.ai

zen-proxy              127.0.0.1:8788    (fallback / pembanding)
```

## Komponen aktif

| Komponen | Unit / wadah | Port | Status |
|---|---|---|---|
| 9Router | `9router.service` | `20128` | active, enabled |
| Bridge | `opencode2api-bridge.service` | `8787` | active, enabled, `NRestarts=0` |
| opencode2api | container `opencode2api-laptop` | `18080` (API), `18081` (WebUI) | healthy, `restart=unless-stopped`, host network |
| Wireproxy WARP ×6 | `wireproxy-exit@1..6.service` | `40051–40056` (HTTP), `40061–40066` (SOCKS) | 6/6 active, enabled |
| Watchdog | `warp-watchdog.timer` | — | active, tiap 2 menit |
| Zen Proxy | `zen-proxy.service` | `8788` | active, enabled (fallback) |
| Docker | `docker.service` | — | active, **enabled** |

`loginctl Linger=yes` sudah aktif, jadi semua user service hidup setelah boot
tanpa perlu login.

## Berkas utama

| Path | Isi |
|---|---|
| `~/opencode2api/bridge.js` | bridge 8787 → 18080 |
| `~/opencode2api/config.json` | salinan config efektif opencode2api (seed/referensi) |
| `~/opencode2api/setup_exits.py` | registrasi 6 profil WARP |
| `~/opencode2api/rotate_wireproxy.py` | rotasi endpoint 6 exit (~5–20 s) |
| `~/opencode2api/exits/` | `wireproxy-1..6.conf`, `ports.json` |
| `~/scripts/warp-watchdog.sh` | watchdog exit WARP |
| `~/bin/9router-oc-patch.sh` | re-apply patch `baseUrl` 9Router setelah update |
| `~/.local/bin/wireproxy` | wireproxy v1.1.3 (linux amd64, checksum terverifikasi) |
| `~/.config/systemd/user/` | unit bridge, wireproxy template, watchdog |
| `/tmp/bridge-requests.log` | log request bridge |
| `/tmp/bridge-fail/` | dump respons non-200 (best-effort) |
| `~/backup/<timestamp>/` | backup DB 9Router, chunk, config zen-proxy |

## Perubahan pada 9Router

1. Provider bawaan **OpenCode Free** (`id:"opencode"`, alias `oc`) diarahkan ke
   bridge: `baseUrl:"https://opencode.ai"` → `baseUrl:"http://127.0.0.1:8787"`.
   Dipatch di empat bundle: `server/chunks/2359.js`, `server/chunks/2598.js`,
   `server/chunks/7987.js`, dan `static/chunks/1321-*.js`.
2. Koneksi provider `opencode` dibuat di database (`providerConnections`,
   `authType=apikey`, `apiKey=public`, `isActive=1`). Bridge tetap meng-inject
   key aslinya, jadi nilai ini hanya formalitas.
3. **Penting:** patch bundle hilang saat `npm update 9router`. Jalankan
   `~/bin/9router-oc-patch.sh` lalu `systemctl --user restart 9router`.

## Verifikasi

### Fungsional

| Uji | Hasil |
|---|---|
| 6 exit WARP `trace` | 6/6 `warp=on`, **6 `/64` berbeda** |
| `:18080/v1/models` | 200 |
| `:8787/v1/models` | 200 |
| `:20128/v1/models` | 200 |
| Chat non-stream via 9Router | 200 (~2,4–3,9 s) |
| Chat streaming via 9Router | 200, SSE + `[DONE]` |
| Tool call via 9Router (`shell`/`read`) | nama tool kembali utuh |
| Tool bernama `terminal` (forced, non-stream & stream) | kembali `terminal`, tidak ada kebocoran `oc2api_t0` |
| 8 model free via `oc/<model>` | **8/8 HTTP 200** |

### Klien

| Klien | Konfigurasi | Uji | Hasil |
|---|---|---|---|
| OpenCode v2.2.0 | provider `9router` → `:20128/v1`, model `oc/*` | `opencode run -m 9router/oc/deepseek-v4.1-flash-free` | teks `OK`; tool `shell` berjalan (`echo halo-opencode`) |
| Hermes v0.22.5 | `model.provider: local-localhost-20128` → `:20128/v1` | `hermes -z` dan `hermes --yolo -z` (pakai shell) | `OK`; `echo halo-hermes` berjalan |

Default OpenCode tidak diubah (tetap `explabs/gpt-6-astra`). Default Hermes
diubah ke `oc/deepseek-v4.1-flash-free` lewat 9Router.

Catatan: model yang `reasoning` bisa mengembalikan `content` kosong bila
`max_tokens` sangat kecil (8); itu normal, bukan kegagalan routing.

### Ketahanan

| Skenario | Hasil |
|---|---|
| `wireproxy-exit@6` dimatikan, watchdog dijalankan | unit hidup lagi, tunnel `warp=on`, `/64` baru |
| Container `opencode2api` dimatikan saat request berjalan | bridge retry `API_DOWN` 3× lalu request **200** setelah container hidup (24 s), tanpa rotasi WARP sia-sia |
| `NRestarts` bridge / 9Router | 0 |

### Bug yang ditemukan dan diperbaiki saat setup

1. **Renamer hanya mengganti di `flush`** — alias di tengah body tidak
   dikembalikan. Diperbaiki dengan sliding window yang tidak memotong alias.
2. **`content-length` basi** — setelah nama tool diganti, panjang body berubah;
   header lama bisa memotong respons. Sekarang `content-length` dihapus saat
   renamer aktif (pakai chunked).

## Catatan model di 9Router

`/v1/models` 9Router hanya menampilkan 4 model statis untuk `oc/*`:

```
oc/muse-spark-1.2-contributor-free
oc/muse-spark-1.3-contributor-free
oc/union-alpha
oc/jev-1.13-free
```

Provider `oc` memakai `passthroughModels`, jadi **semua 8 model free tetap bisa
dipanggil** walau tidak tampil di daftar:

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

## Rollback

```bash
systemctl --user disable --now opencode2api-bridge warp-watchdog.timer
systemctl --user disable --now wireproxy-exit@1 wireproxy-exit@2 wireproxy-exit@3 \
  wireproxy-exit@4 wireproxy-exit@5 wireproxy-exit@6
docker rm -f opencode2api-laptop
# kembalikan zen-proxy ke 8787
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/.zen-proxy/zen-proxy.json')
c=json.load(open(p)); c['port']=8787; json.dump(c,open(p,'w'),indent=2)
PY
systemctl --user restart zen-proxy
# pulihkan 9Router
cp ~/backup/<timestamp>/2359.js ~/backup/<timestamp>/2598.js \
   ~/.nvm/versions/node/v26.12.1/lib/node_modules/9router/app/.next-cli-build/server/chunks/
cp ~/backup/<timestamp>/data.sqlite ~/.9router/db/data.sqlite
systemctl --user restart 9router
```

## Yang belum diuji

- Reboot penuh laptop (unit sudah enabled + linger, docker enabled).
- Perpindahan Wi-Fi saat tunnel WARP aktif (watchdog sudah menangani kasus
  tunnel mati, tetapi belum diuji dengan pindah jaringan sungguhan).
- Rate limit registrasi Cloudflare bila rotasi/registrasi dilakukan terlalu
  sering.

## Masalah terpisah

Container `tulisin-fastapi-engine` masih restart-loop dengan
`Could not import module "app.main"`. Tidak terkait stack ini dan tidak diubah.

## Kesimpulan

**Setup lokal: diterapkan dan terverifikasi end-to-end.**
**8 model free dapat dipanggil lewat 9Router (`oc/<model>`) dan menghasilkan 200.**
