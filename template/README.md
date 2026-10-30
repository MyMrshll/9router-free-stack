# Template stack — 9Router + OpenCode free models

Template untuk memasang stack berikut di laptop lain, tanpa sudo:

```
klien → 9Router :20128 → bridge :8787 → opencode2api :18080 → WARP :40051-56 → opencode.ai
```

Semua artefak di folder ini sudah dipakai dan diverifikasi di satu laptop
(Ubuntu 24.04, Node 26, Docker). Path, versi Node, dan arsitektur dideteksi
otomatis oleh pemasang.

## Mulai cepat

```bash
cd template
chmod +x install.sh verify.sh
./install.sh
./verify.sh
```

Prasyarat: Node ≥ 22, 9Router terpasang (`npm i -g 9router`), Docker bisa
diakses user (grup `docker`), systemd user + `linger=yes`, Python 3, openssl,
curl. Detail lengkap ada di [PANDUAN.md](PANDUAN.md).

## Isi

| File | Fungsi |
|---|---|
| [PROMPT.md](PROMPT.md) | Prompt siap tempel untuk agent AI di laptop tujuan |
| [PANDUAN.md](PANDUAN.md) | Penjelasan arsitektur + langkah manual + troubleshooting + rollback |
| `install.sh` | Pemasang otomatis (backup, WARP, Docker, bridge, patch 9Router) |
| `verify.sh` | Verifikasi semua lapisan, exit code ≠ 0 bila ada yang gagal |
| `files/bridge.js` | Bridge 8787 → 18080 (alias tool, retry, rotasi) |
| `files/setup_exits.py` | Registrasi N profil WARP |
| `files/rotate_wireproxy.py` | Rotasi endpoint + verifikasi tunnel |
| `files/warp-watchdog.sh` | Pemulih tunnel otomatis |
| `files/9router-oc-patch.sh` | Re-apply patch `baseUrl` setelah update 9Router |
| `files/*.service*`, `files/*.timer` | Unit systemd user |

## Konfigurasi

Default cocok dengan stack referensi: bridge `8787`, API `18080`, WebUI `18081`,
9Router `20128`, 6 exit WARP `40051–40056`/`40061–40066`, key lokal
`sk-opencode2api-<hostname>`.

Ubah lewat environment, misalnya:

```bash
BRIDGE_PORT=8787 API_PORT=18080 EXIT_COUNT=6 \
API_KEY=sk-opencode2api-$(hostname -s) ./install.sh
```

Daftar variabel lengkap ada di [PANDUAN.md §3](PANDUAN.md).

## Setelah selesai

- Base URL 9Router: `http://127.0.0.1:20128/v1`
- Model: `oc/deepseek-v4.1-flash-free`, `oc/big-pickle`, `oc/beam-free`, dst.
- `oc/*` memakai passthrough: 8 model free bisa dipanggil walau `/v1/models`
  hanya menampilkan 4 model statis.
- Patch 9Router **hilang setiap `npm update 9router`** → jalankan
  `~/bin/9router-oc-patch.sh` lalu restart 9Router.

## Batas

Kuota gratis tetap per `/64` dan per model; rotasi WARP hanya mitigasi.
Registrasi WARP terlalu sering bisa dibalas 429 oleh Cloudflare. Stack
bergantung pada Docker dan linger. Lihat bagian rollback di PANDUAN.
