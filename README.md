# 9Router Free Stack — template & dokumentasi

Stack lokal agar model gratis OpenCode bisa dipakai lewat 9Router dengan tool
calling yang utuh:

```
klien → 9Router :20128 → bridge :8787 → opencode2api :18080 → WARP ×6 → opencode.ai
```

Repo ini berisi template pemasangan untuk laptop lain, plus laporan dan runbook
dari instalasi yang sudah diverifikasi end-to-end (8/8 model free HTTP 200,
streaming, tool call, watchdog, dan retry saat API lokal mati).

## Mulai

```bash
cd template
chmod +x install.sh verify.sh
./install.sh
./verify.sh
```

Atau tempel isi [`template/PROMPT.md`](template/PROMPT.md) ke agent AI yang
bekerja di laptop tujuan.

## Isi repo

| Path | Isi |
|---|---|
| [`template/README.md`](template/README.md) | Indeks template & mulai cepat |
| [`template/PROMPT.md`](template/PROMPT.md) | Prompt siap tempel untuk agent di laptop lain |
| [`template/PANDUAN.md`](template/PANDUAN.md) | Arsitektur, prasyarat, langkah manual, troubleshooting, rollback |
| [`template/install.sh`](template/install.sh) | Pemasang otomatis (tanpa sudo) |
| [`template/verify.sh`](template/verify.sh) | Verifikasi semua lapisan |
| [`template/files/`](template/files/) | Bridge, generator exit WARP, rotasi, watchdog, unit systemd |
| [`LAPORAN-SETUP-LAPTOP.md`](LAPORAN-SETUP-LAPTOP.md) | Laporan hasil instalasi & verifikasi |
| [`RUNBOOK-9ROUTER.md`](RUNBOOK-9ROUTER.md) | Operasional harian, restart, rotasi, rollback |

## Prasyarat

Node ≥ 22, 9Router terpasang (`npm i -g 9router`), Docker yang bisa diakses user
(grup `docker`), systemd user + `linger=yes`, Python 3, openssl, curl.

## Catatan

- Template memakai placeholder untuk API key. Isi key nyata hanya di mesin
  lokal, jangan commit.
- Patch `baseUrl` 9Router hilang setiap `npm update 9router`; jalankan
  `~/bin/9router-oc-patch.sh` lalu restart.
- Kuota gratis tetap terbatas per `/64`; rotasi WARP adalah mitigasi, bukan
  kuota tak terbatas.
- `9router.md` (transkrip sumber) sengaja tidak disertakan karena memuat
  kredensial.
