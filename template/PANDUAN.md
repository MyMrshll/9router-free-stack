# Panduan — replikasi stack 9Router → bridge → opencode2api → WARP

Dokumen ini menjelaskan **kenapa** stack ini berbentuk demikian, lalu
**langkah-langkah** memasangnya di laptop lain. Untuk versi otomatis, jalankan
`install.sh`; untuk versi manual, ikuti bagian 5.

---

## 1. Penjelasan arsitektur

```
klien (OpenCode / Hermes / curl)
  → 9Router          127.0.0.1:20128   gateway + API key + routing `oc/<model>`
  → bridge.js        127.0.0.1:8787    penerjemah protokol + alias tool
  → opencode2api     127.0.0.1:18080   auth/kuota OpenCode + rotasi proxy
  → wireproxy 1..6   127.0.0.1:40051–56 tunnel WARP (IP keluar berbeda)
  → opencode.ai
```

| Komponen | Peran | Kenapa perlu |
|---|---|---|
| **9Router** | Gateway OpenAI-compatible, menyimpan API key klien, mengekspos `oc/<model>` | Titik masuk tunggal; klien tidak perlu tahu detail internal |
| **bridge.js** | Menulis ulang path `/inference/*`, inject key lokal, membuang header sesi, mengalias tool terlarang lalu mengembalikan namanya | 9Router mengirim format/header yang tidak diterima opencode2api; tool bernama `terminal` ditolak upstream |
| **opencode2api** | Proxy ke endpoint inference OpenCode, mengelola key/anonim dan pool proxy | Menyembunyikan detail auth/kuota dan menyediakan rotasi proxy |
| **wireproxy + WARP** | 6 identitas WARP dengan `/64` berbeda | Kuota gratis dihitung per `/64`; rotasi memperpanjang pemakaian |
| **watchdog** | Cek tunnel tiap 2 menit, restart unit mati, rotasi bila perlu | WARP bisa putus saat pindah Wi-Fi/sleep |
| **zen-proxy** (opsional) | Implementasi alternatif gate bypass | Dibesarkan ke `8788` sebagai pembanding/rollback, bukan jalur utama |

Alasan bridge memisahkan diri dari 9Router: upstream OpenCode menolak
`Authorization`/header sesi dari gateway dan menolak nama tool tertentu. Bridge
adalah satu-satunya tempat aturan itu diubah, sehingga gateway tetap bersih.

---

## 2. Prasyarat

| Kebutuhan | Cara cek | Catatan |
|---|---|---|
| Node ≥ 22 | `node -v` | `node:sqlite` dipakai untuk menulis DB 9Router |
| npm global | `npm root -g` | Menemukan folder 9Router |
| 9Router terpasang | `systemctl --user is-active 9router` | `npm i -g 9router` |
| Docker + grup `docker` | `docker info` | Tanpa sudo; jika gagal: `sudo usermod -aG docker $USER` lalu login ulang |
| systemd user + linger | `loginctl show-user $USER -p Linger --value` | Harus `yes`; `loginctl enable-linger $USER` |
| Python 3, openssl, curl | `python3 -V; openssl version` | Untuk registrasi WARP dan verifikasi |
| Internet keluar | `curl -sI https://api.cloudflareclient.com` | Registrasi WARP butuh akses ini |

Port default: `8787` (bridge), `18080`/`18081` (API/WebUI), `20128` (9Router),
`40051–40056` (HTTP exit), `40061–40066` (SOCKS exit).

---

## 3. Mulai cepat (otomatis)

Dari folder `template/`:

```bash
chmod +x install.sh verify.sh
./install.sh
./verify.sh
```

`install.sh` melakukan semuanya: backup, pasang wireproxy, registrasi WARP,
container opencode2api, config, bridge, unit systemd, patch 9Router, dan
koneksi provider. Tidak memakai sudo.

Variabel yang bisa diubah sebelum menjalankan:

```bash
BRIDGE_PORT=8787 API_PORT=18080 EXIT_COUNT=6 \
API_KEY=sk-opencode2api-$(hostname -s) \
ROUTER_UNIT=9router MOVE_ZEN_PROXY=1 \
./install.sh
```

| Variabel | Default | Fungsi |
|---|---|---|
| `BRIDGE_PORT` | `8787` | Port bridge (dipakai patch 9Router) |
| `API_PORT` | `18080` | Port API opencode2api |
| `WEBUI_PORT` | `18081` | Port WebUI opencode2api |
| `EXIT_COUNT` | `6` | Jumlah tunnel WARP |
| `HTTP_BASE` / `SOCKS_BASE` | `40051` / `40061` | Port awal exit |
| `API_KEY` | `sk-opencode2api-<host>` | Key lokal bridge/API |
| `ROUTER_UNIT` | `9router` | Nama unit systemd 9Router |
| `MOVE_ZEN_PROXY` | `1` | Pindahkan zen-proxy jika bentrok `8787` |
| `ZEN_NEW_PORT` | `8788` | Port baru zen-proxy |
| `FORCE_REGISTER` | `0` | `1` = registrasi ulang 6 profil WARP |
| `SKIP_ROUTER` | `0` | `1` = lewati patch 9Router (uji sebagian) |

Jika `verify.sh` melaporkan 429 pada chat, itu kuota upstream; jalankan rotasi
lalu ulangi. Kegagalan keras hanya bila ada baris `FAIL` selain chat.

---

## 4. Struktur file template

```
template/
├── PROMPT.md                       prompt siap tempel untuk agent
├── PANDUAN.md                      dokumen ini
├── README.md                       indeks singkat
├── install.sh                      pemasang otomatis
├── verify.sh                       verifikasi semua lapisan
└── files/
    ├── bridge.js                   8787 → 18080 (env-configurable)
    ├── setup_exits.py              registrasi N profil WARP
    ├── rotate_wireproxy.py         rotasi endpoint + verifikasi
    ├── warp-watchdog.sh            pemulih tunnel
    ├── 9router-oc-patch.sh         re-apply patch setelah update
    ├── opencode2api-bridge.service.in
    ├── wireproxy-exit@.service
    ├── warp-watchdog.service.in
    └── warp-watchdog.timer
```

---

## 5. Langkah manual (setara `install.sh`)

### 5.1 Backup dan direktori

```bash
TS=$(date +%Y%m%d-%H%M%S); BK=$HOME/backup/$TS
mkdir -p "$BK" "$HOME/opencode2api/exits" "$HOME/scripts" "$HOME/bin" "$HOME/.local/bin"
cp "$HOME/.9router/db/data.sqlite" "$BK/" 2>/dev/null || true
cp "$HOME/.zen-proxy/zen-proxy.json" "$BK/" 2>/dev/null || true
```

### 5.2 Wireproxy

```bash
V=1.1.3; ARCH=amd64   # atau arm64
BASE=https://github.com/pufferffish/wireproxy/releases/download/v$V
curl -fsSL -o /tmp/wp.tgz "$BASE/wireproxy_linux_$ARCH.tar.gz"
curl -fsSL -o /tmp/wp.sum "$BASE/checksums.txt"
grep " wireproxy_linux_$ARCH.tar.gz$" /tmp/wp.sum
sha256sum /tmp/wp.tgz          # harus sama
tar xzf /tmp/wp.tgz -C /tmp wireproxy
install -m755 /tmp/wireproxy "$HOME/.local/bin/wireproxy"
"$HOME/.local/bin/wireproxy" --version
```

### 5.3 Enam exit WARP

```bash
install -m755 files/setup_exits.py ~/opencode2api/setup_exits.py
cd ~/opencode2api && ./setup_exits.py
```

Hasil: `exits/wireproxy-1..6.conf` dan `exits/ports.json`. Kalau registrasi
Cloudflare membalas 429, tunggu beberapa menit lalu ulangi; jangan spam.

Pasang unit lalu aktifkan:

```bash
install -m644 files/wireproxy-exit@.service ~/.config/systemd/user/
systemctl --user daemon-reload
for i in 1 2 3 4 5 6; do systemctl --user enable --now wireproxy-exit@$i; done
sleep 5
for p in 40051 40052 40053 40054 40055 40056; do
  curl -s --max-time 10 -x http://127.0.0.1:$p https://www.cloudflare.com/cdn-cgi/trace \
    | awk -F= '/^warp=/{w=$2}/^ip=/{ip=$2}END{print w,ip}'
done
```

Harus `on` dengan 6 `/64` berbeda.

### 5.4 opencode2api

```bash
docker pull ghcr.io/jasonxu114514/opencode2api:latest
docker rm -f opencode2api-laptop 2>/dev/null || true
docker run -d --name opencode2api-laptop --network host --restart unless-stopped \
  --health-cmd 'wget -q -O /dev/null http://127.0.0.1:18080/healthz || exit 1' \
  --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 15s \
  -v opencode2api-laptop-state:/var/lib/opencode2api \
  ghcr.io/jasonxu114514/opencode2api:latest
```

Tunggu container menulis config, lalu sunting **di dalam volume**:

```bash
docker cp opencode2api-laptop:/var/lib/opencode2api/config.json /tmp/c.json
python3 - <<'PY'
import json
c=json.load(open('/tmp/c.json'))
c['listen']='127.0.0.1:18080'
c['server_keys']=['sk-opencode2api-GANTI']
c['anonymous']=True
c['proxies']=[f'http://127.0.0.1:{p}' for p in range(40051,40057)]
c.setdefault('warp',{})['enabled']=False
c.setdefault('performance',{}).update({
 'attempt_timeout_seconds':45,'first_event_timeout_seconds':15,
 'free_tier_block_seconds':60,'connect_timeout_seconds':5,
 'failure_cooldown_seconds':15,'max_anonymous_exits':8})
c.setdefault('webui',{})['listen']='127.0.0.1:18081'
json.dump(c,open('/tmp/c.json','w'),indent=2)
PY
docker cp /tmp/c.json opencode2api-laptop:/var/lib/opencode2api/config.json
docker restart opencode2api-laptop
```

Jangan `docker exec ... cat > file` tanpa `-i` — file akan kosong.

### 5.5 Bridge

```bash
install -m755 files/rotate_wireproxy.py ~/opencode2api/
install -m644 files/bridge.js ~/opencode2api/
node --check ~/opencode2api/bridge.js
install -m755 files/9router-oc-patch.sh ~/bin/
install -m755 files/warp-watchdog.sh ~/scripts/
```

Buat unit dari `files/opencode2api-bridge.service.in`; ganti
`__NODE_BIN__`, `__NODE_DIR__`, `__STACK_DIR__`, `__UID__`,
`__BRIDGE_PORT__`, `__API_PORT__`, `__API_KEY__` dengan nilai nyata. Lalu:

```bash
systemctl --user daemon-reload
systemctl --user enable --now opencode2api-bridge
```

Uji: `curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer x' http://127.0.0.1:8787/v1/models` → `200`.

### 5.6 Watchdog

```bash
install -m644 files/warp-watchdog.service.in /tmp/w.service
sed -e "s|__UID__|$(id -u)|g" -e "s|__EXIT_COUNT__|6|g" /tmp/w.service \
  > ~/.config/systemd/user/warp-watchdog.service
install -m644 files/warp-watchdog.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now warp-watchdog.timer
```

### 5.7 Patch 9Router

```bash
~/bin/9router-oc-patch.sh "$(npm root -g)/9router/app"
```

Script memindai semua `.js` dan mengganti fragmen
`baseUrl:"https://opencode.ai",headers:{"x-opencode-client":"desktop"}`
menjadi `baseUrl:"http://127.0.0.1:8787"`. Jika output
`nothing to patch`, cek apakah fragmen upstream berubah — patch manual di
bundle yang mengandung `id:"opencode"`.

Koneksi provider (DB, lakukan saat 9router berhenti):

```bash
systemctl --user stop 9router
node - "$HOME/.9router/db/data.sqlite" <<'JS'
const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');
const db = new DatabaseSync(process.argv[2]);
const now = new Date().toISOString();
const data = JSON.stringify({ apiKey: 'public', testStatus: 'unknown', defaultModel: null });
const row = db.prepare("select id from providerConnections where provider='opencode'").get();
if (row) db.prepare('update providerConnections set isActive=1,data=?,updatedAt=? where id=?').run(data, now, row.id);
else db.prepare('insert into providerConnections(id,provider,authType,name,email,priority,isActive,data,createdAt,updatedAt) values(?,?,?,?,?,?,?,?,?,?)')
  .run(randomUUID(), 'opencode', 'apikey', 'OpenCode Free', null, 1, 1, data, now, now);
JS
systemctl --user restart 9router
```

### 5.8 Verifikasi

```bash
./verify.sh
```

Atau manual:

```bash
KEY=$(node -e "const{DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.env.HOME+'/.9router/db/data.sqlite',{readOnly:true});process.stdout.write(d.prepare('select key from apiKeys where isActive=1 limit 1').get().key)")
curl -s -o /dev/null -w '9router %{http_code}\n' -H "Authorization: Bearer $KEY" http://127.0.0.1:20128/v1/models
curl -s -w '\n%{http_code}\n' -X POST http://127.0.0.1:20128/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"oc/deepseek-v4.1-flash-free","stream":false,"max_tokens":16,"messages":[{"role":"user","content":"Balas hanya: OK"}]}'
```

---

## 6. Menyambungkan klien

### OpenCode

Tambahkan provider OpenAI-compatible di `~/.config/opencode/opencode.json`:

```json
"9router": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "9Router (local)",
  "options": {
    "baseURL": "http://127.0.0.1:20128/v1",
    "apiKey": "<API_KEY_9ROUTER>"
  },
  "models": {
    "oc/deepseek-v4.1-flash-free": { "name": "deepseek-v4.1-flash-free" }
  }
}
```

Model **harus** didaftarkan sebagai `oc/<model>` (OpenCode mengirim ID tanpa
prefix provider). Pakai: `opencode run -m 9router/oc/deepseek-v4.1-flash-free "halo"`.

### Hermes

Arahkan provider lokal yang sudah ada ke 9Router:

```yaml
model:
  default: "oc/deepseek-v4.1-flash-free"
  provider: "local-localhost-20128"
  base_url: "http://127.0.0.1:20128/v1"
  api_mode: chat_completions
  key_env: HERMES_CUSTOM_LOCAL_LOCALHOST_20128_API_KEY
```

Pastikan env tersebut berisi API key 9Router. Jika Hermes memakai provider
langsung ke opencode2api, isi `api_key` dengan key lokal (`sk-opencode2api-...`),
bukan `public`.

---

## 7. Troubleshooting

| Gejala | Penyebab umum | Tindakan |
|---|---|---|
| `No active credentials for provider: openrouter` | Nama model terkirim tanpa prefix, 9Router fallback | Daftarkan model sebagai `oc/<model>` di klien |
| `429 FreeUsageLimitError` | Kuota `/64` habis | `python3 ~/opencode2api/rotate_wireproxy.py`, ulangi |
| Semua exit `warp=off` | WARP mati / jaringan berubah | `systemctl --user restart wireproxy-exit@N`; watchdog 2 menit |
| `503 all proxies are unavailable` | Tidak ada exit hidup | Cek 6 port; jalankan `setup_exits.py` bila profil rusak |
| Container `unhealthy` tapi chat jalan | Healthcheck masih `:8080` | Recreate dengan `--health-cmd` ke `:18080/healthz` |
| Body tool call terpotong | `content-length` basi setelah rename | Hapus header saat renamer aktif |
| Tool kembali `oc2api_t0` | Renamer hanya di `flush` | Pakai renamer sliding-window |
| 9Router 404/403 setelah update npm | Patch bundle hilang | `~/bin/9router-oc-patch.sh` lalu restart |
| `docker: permission denied` | User belum di grup `docker` | `sudo usermod -aG docker $USER`, login ulang |
| `node:sqlite` tidak ditemukan | Node < 22 | Pasang Node 22+ |

Log: `/tmp/bridge-requests.log`, `/tmp/bridge-fail/`, `journalctl --user -u
opencode2api-bridge`, `journalctl --user -u wireproxy-exit@1`, `docker logs
opencode2api-laptop`, `~/scripts/warp-watchdog.log`.

---

## 8. Rollback

```bash
systemctl --user disable --now opencode2api-bridge warp-watchdog.timer
for i in 1 2 3 4 5 6; do systemctl --user disable --now wireproxy-exit@$i; done
docker rm -f opencode2api-laptop
# zen-proxy kembali ke 8787 bila dipindah
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/.zen-proxy/zen-proxy.json')
c=json.load(open(p)); c['port']=8787; json.dump(c,open(p,'w'),indent=2)
PY
systemctl --user restart zen-proxy 2>/dev/null || true
# pulihkan 9Router dari backup
cp ~/backup/<timestamp>/data.sqlite ~/.9router/db/data.sqlite
# pulihkan bundle yang dipatch dari ~/backup/<timestamp>/app/...
systemctl --user restart 9router
```

Volume `opencode2api-laptop-state` bisa dihapus dengan
`docker volume rm opencode2api-laptop-state`.

---

## 9. Catatan portabilitas

- **Path** tidak di-hardcode selain `$HOME/opencode2api` (dan `%h/opencode2api`
  di unit). Node ditemukan lewat `command -v node`; npm global lewat
  `npm root -g`.
- **Arsitektur**: `install.sh` mendukung `amd64` dan `arm64`; checksum diambil
  dari rilis resmi.
- **Port** dapat diubah lewat env, tetapi `wireproxy-exit@.service` mengikuti
  `exits/wireproxy-N.conf`, jadi cukup ubah `HTTP_BASE`/`SOCKS_BASE` saat
  registrasi.
- **Nama unit 9Router** bisa berbeda; set `ROUTER_UNIT`.
- **Tanpa sudo** selama user ada di grup `docker` dan linger aktif. Langkah
  yang butuh root hanya pemasangan paket sistem (jika ada) dan
  `usermod`/`enable-linger`.
- **Kuota tetap terbatas**: rotasi WARP bukan kuota tak terbatas. Registrasi
  WARP terlalu sering bisa dibalas 429 oleh Cloudflare.
- **Patch 9Router rapuh terhadap update upstream**: selalu jalankan ulang
  `9router-oc-patch.sh` setelah `npm i -g 9router`. Jika fragmen berubah,
  perbarui regex di script.
