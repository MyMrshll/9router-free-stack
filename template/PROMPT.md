# Prompt siap tempel — replikasi stack di laptop lain

Salin blok di bawah ini ke agent AI (OpenCode, Claude Code, dll.) yang berjalan
di laptop tujuan. Ganti hanya bagian `KONTEKS LOKAL` bila perlu.

---

## PROMPT

Anda adalah engineer yang memasang stack **9Router → bridge → opencode2api →
WARP** di laptop ini, mereplikasi stack yang sudah terbukti di laptop lain.
Tujuannya: model gratis OpenCode (`*-free`) bisa dipanggil lewat 9Router dengan
nama `oc/<model>` dan tool calling tetap utuh.

### Aturan keras

1. **Tanpa sudo.** Semua komponen berjalan sebagai user biasa (systemd *user*
   service + Docker milik grup `docker`). Jika ada langkah yang benar-benar
   butuh root, berhenti dan minta user menjalankannya.
2. **Jangan menyentuh stack lain** (container/service yang tidak terkait).
3. **Jangan menebak path.** Deteksi sendiri: `command -v node`, `npm root -g`,
   `id -u`, `$HOME`, versi Node.
4. **Backup dulu** sebelum mengubah: DB 9Router, bundle 9Router yang dipatch,
   config zen-proxy, config klien.
5. **Verifikasi tiap fase** sebelum lanjut. Jangan klaim selesai tanpa bukti
   HTTP 200 nyata.
6. **Idempoten**: aman dijalankan ulang; jangan menduplikasi baris DB/unit.
7. Jangan pernah menulis secret ke repo atau log. Key di sini hanya key lokal.

### Prasyarat yang harus dicek

```bash
node -v                 # butuh >= 22 (node:sqlite)
npm root -g             # lokasi 9router
docker info             # user harus bisa akses docker tanpa sudo
systemctl --user show-environment
loginctl show-user "$USER" -p Linger --value   # harus yes
python3 --version; openssl version; curl --version | head -1
ss -lntp | grep -E ':(8787|20128|18080|18081)\b' || true
```

9Router harus sudah terpasang (`npm i -g 9router`) dan unit user-nya aktif.
Jika belum, pasang dulu dan pastikan dashboard `http://127.0.0.1:20128` hidup.
`linger=yes` wajib agar service hidup setelah reboot tanpa login:
`loginctl enable-linger "$USER"` (bisa tanpa sudo jika polkit mengizinkan).

### KONTEKS LOKAL (sesuaikan)

- Path stack: `$HOME/opencode2api`
- Port: bridge `8787`, API `18080`, WebUI `18081`, 9Router `20128`
- Jumlah exit WARP: `6` (HTTP `40051–40056`, SOCKS `40061–40066`)
- Key API lokal: `sk-opencode2api-<hostname>` (ganti `<hostname>`)
- Nama container: `opencode2api-laptop`, volume: `opencode2api-laptop-state`
- Unit 9Router: `9router.service` (jika beda, sesuaikan)

### Fase kerja

**Fase 0 — Audit & backup.**
Deteksi semua path/versi. Cek port bentrok. Backup ke
`$HOME/backup/<timestamp>/`: `~/.9router/db/data.sqlite`, file bundle 9Router
yang mengandung `headers:{"x-opencode-client":"desktop"}`, dan
`~/.zen-proxy/zen-proxy.json` bila ada. Catat hasil audit.

**Fase 1 — Selesaikan konflik port.**
Jika `zen-proxy` (atau proses lain) memakai `8787`, pindahkan zen-proxy ke
`8788` dan restart. Alternatif: matikan, tetapi pindah lebih aman untuk
rollback. Jangan mematikan gateway 9Router.

**Fase 2 — Wireproxy WARP 6 exit.**
Pasang `wireproxy` v1.1.3 ke `~/.local/bin` (unduh rilis GitHub, verifikasi
SHA256 terhadap `checksums.txt`; dukung amd64/arm64). Registrasikan 6 profil
WARP (endpoint `api.cloudflareclient.com/v0a2158/reg`) dan tulis
`~/opencode2api/exits/wireproxy-N.conf` + `ports.json`. Jalankan sebagai
`wireproxy-exit@N.service`. Buktikan **6/6** `warp=on` dengan `/64` berbeda:

```bash
for p in 40051 40052 40053 40054 40055 40056; do
  curl -s --max-time 10 -x "http://127.0.0.1:$p" https://www.cloudflare.com/cdn-cgi/trace \
    | awk -F= '/^warp=/{w=$2}/^ip=/{ip=$2}END{print w,ip}'
done
```

Sertakan `rotate_wireproxy.py` (ganti endpoint, restart unit, verifikasi) dan
`warp-watchdog.sh` + timer 2 menit (restart unit mati, rotasi bila perlu).

**Fase 3 — opencode2api di Docker.**
Jalankan `ghcr.io/jasonxu114514/opencode2api:latest` dengan `--network host`,
`--restart unless-stopped`, volume `opencode2api-laptop-state`, healthcheck ke
`http://127.0.0.1:18080/healthz` (bawaan image memakai `:8080` — wajib diubah).
Config efektif ada **di dalam volume**, bukan di host. Alur aman:

```bash
docker cp opencode2api-laptop:/var/lib/opencode2api/config.json /tmp/c.json
# edit: listen 127.0.0.1:18080, server_keys, anonymous true,
#       proxies = 6 HTTP exit, warp.enabled=false, webui 127.0.0.1:18081,
#       performance timeouts (attempt 45s, first_event 15s)
docker cp /tmp/c.json opencode2api-laptop:/var/lib/opencode2api/config.json
docker restart opencode2api-laptop
```

Jangan memakai `docker exec ... cat > file` tanpa `-i` (file akan kosong).

**Fase 4 — bridge `8787 → 18080`.**
Tulis `~/opencode2api/bridge.js` dengan perilaku:
- rewrite `/inference/*` → `/*`
- inject `Authorization: Bearer <key lokal>`
- buang header `session`/`affinity`
- alias tool yang namanya cocok `/terminal/i` → `oc2api_t0`, lalu
  **kembalikan nama aslinya** di respons (streaming dan non-streaming)
- hapus `content-length` saat rename (panjang body berubah; jika tidak,
  respons terpotong/hang)
- rotasi WARP saat 429 lalu retry maksimal 3×; retry 10×3 dtk saat API lokal
  `ECONNREFUSED`
- renamer harus sliding-window, **bukan hanya saat flush**, supaya alias di
  tengah body tidak lolos
Jalankan sebagai `opencode2api-bridge.service`. Uji `/v1/models` → 200 dan
tool `terminal` kembali utuh.

**Fase 5 — 9Router.**
Provider bawaan `opencode` (alias `oc`) menunjuk `https://opencode.ai`. Patch
semua bundle JS di `$(npm root -g)/9router/app` yang mengandung fragmen
`baseUrl:"...",headers:{"x-opencode-client":"desktop"}` menjadi
`baseUrl:"http://127.0.0.1:8787"`. Buat script re-apply
`~/bin/9router-oc-patch.sh` (patch hilang setiap `npm update 9router`).
Lalu buat/aktifkan koneksi provider di `~/.9router/db/data.sqlite`:

```sql
-- tabel providerConnections
-- provider='opencode', authType='apikey', name='OpenCode Free',
-- isActive=1, data='{"apiKey":"public","testStatus":"unknown","defaultModel":null}'
```

Hentikan 9router sebelum menulis DB, lalu start lagi. Restart wajib.

**Fase 6 — Verifikasi berlapis.**
1. `:18080/v1/models` 200
2. `:8787/v1/models` 200
3. `:20128/v1/models` 200
4. Chat `oc/deepseek-v4.1-flash-free` 200 (streaming + non-streaming)
5. Tool `terminal` (dipaksa `tool_choice`) kembali bernama `terminal`, tidak
   ada `oc2api_t0` di body
6. 8 model free → 200
7. Ketahanan: stop `wireproxy-exit@6` → watchdog memulihkan; stop container
   saat request → bridge retry lalu 200 tanpa rotasi sia-sia
8. Rotasi manual `rotate_wireproxy.py` → semua exit hidup dengan `/64` baru

Jika model 429: itu kuota upstream per `/64`/model. Rotasi adalah mitigasi,
bukan kuota tak terbatas. Jangan mengklaim gagal total hanya karena 429 satu
kali; verifikasi ulang setelah rotasi.

**Fase 7 — Dokumentasi.**
Tulis laporan + runbook di repo ini: status unit, path, port, hasil uji,
troubleshooting, rollback. Sertakan catatan bahwa patch 9Router hilang setelah
update dan cara re-apply.

### Jebakan yang sudah terbukti (jangan diulang)

- Healthcheck image opencode2api default ke `:8080` → container tampak
  `unhealthy` walau berfungsi.
- `content-length` basi setelah rename tool → body terpotong.
- Renamer hanya di `flush` → alias lolos.
- 9Router `/v1/models` hanya menampilkan 4 model statis `oc/*`; 8 model free
  tetap bisa dipanggil karena `passthroughModels`. Jangan simpulkan model
  hilang dari daftar.
- Klien OpenCode mengirim ID model **tanpa** prefix provider; daftarkan model
  sebagai `oc/<model>` agar yang dikirim `oc/<model>`.
- API 9Router `/api/*` butuh cookie dashboard; `/v1/*` cukup API key.
- Model dengan reasoning bisa mengembalikan `content` kosong bila `max_tokens`
  sangat kecil; itu normal.

### Kriteria selesai

- Semua unit `active`/`enabled`, container `healthy`, 6/6 tunnel `warp=on`.
- Chat lewat 9Router 200 dan tool call berfungsi.
- `verify.sh` lulus tanpa FAIL.
- Rollback terdokumentasi dan diuji minimal di atas kertas.

### Output akhir yang diminta

Ringkas: arsitektur, daftar unit/port, hasil uji (kode HTTP + waktu), bug yang
ditemukan, dan perintah verifikasi ulang. Jangan hanya menulis "selesai".
