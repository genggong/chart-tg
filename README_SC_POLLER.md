# SC Poller Lokal — kirim screenshot MT5 ke Telegram **tanpa hosting**

Jalur alternatif dari `ChartShotSender` (webSend=true → endpoint PHP). Di jalur ini
**EA hanya menulis PNG** ke `MQL5\Files\`, lalu script Python ini yang mengirimkannya
ke Telegram.

| | Jalur hosting (sekarang) | Jalur lokal (script ini) |
|---|---|---|
| Butuh hosting/PHP | ya | **tidak** |
| Butuh whitelist WebRequest di MT5 | ya | **tidak** |
| Butuh proses hidup terus | tidak | **ya** (di mesin MT5) |
| Kalau hosting down | SC gagal | tetap jalan |

---

## 1. Siapkan
```bat
python --version
```
Python 3.8+ (cek di cmd). **Tanpa `pip install` apa pun** — script pakai stdlib saja.
Kalau `python` tidak dikenali, coba `py --version` (Windows launcher).

## 2. Atur EA supaya menulis file (bukan kirim via WebRequest)
Di `ChartShotSender` → Properties:
- `webSend = false`  ← matikan jalur hosting
- `everyMinutes = 15`
- `webChat`, `webUrl`, `webKey` dibiarkan (tidak dipakai saat webSend=false)

EA akan menulis `MQL5\Files\chart_<SIMBOL>_<TF>.png` setiap boundary :00/:15/:30/:45.

## 3. Cari folder MQL5\Files kamu
```bat
python sc_poller.py --find-mt5
```
Contoh output:
```
[3 png]  C:\Users\Eazy\AppData\Roaming\MetaQuotes\Terminal\A1B2C3...\MQL5\Files
         --dir "C:\Users\Eazy\AppData\Roaming\MetaQuotes\Terminal\A1B2C3...\MQL5\Files"
```
Kalau ada beberapa terminal, pilih yang **jumlah PNG-nya bertambah** sesudah EA jalan.

## 4. Tes kirim 1 gambar (paling penting, lakukan dulu)
```bat
python sc_poller.py --send-test --token 123456:ABC... --chat -1001583828319
```
Harus muncul `SEND-TEST ... -> ok=True` dan gambar muncul di grup.
Kalau `ok=False` → baca pesannya: `chat not found` (id salah) / `bot was blocked` /
`not enough rights to send photos` (bot belum admin / dikeluarkan dari grup).

## 5. Jalankan poller
```bat
python sc_poller.py --token 123456:ABC... --chat -1001583828319 --dir "C:\...\MQL5\Files"
```
Uji dulu tanpa kirim beneran:
```bat
python sc_poller.py --token X --chat -1 --dir "C:\...\MQL5\Files" --dry-run --once
```
Default:
- scan **tiap 10 detik**, kirim hanya file **baru** (mtime/ukuran berubah)
- file lama saat start **tidak** dikirim ulang (anti-banjir riwayat)
- file yang sedang ditulis MT5 **ditunda** sampai ukurannya stabil
- caption otomatis: `chart_XAUUSD_M15.png` → `XAUUSD M15`

Opsi berguna:

| Opsi | Arti |
|---|---|
| `--interval 10` | detik antar scan |
| `--min-age 30` | kirim hanya file yang sudah berumur ≥30 detik |
| `--caption "{sym} {tf}"` | template caption (`{sym} {tf} {name}`) |
| `--no-skip-existing` | ikut kirim file lama saat start |
| `--once` | sekali scan lalu keluar |
| `--dry-run` | tidak mengirim, hanya catat |
| `--log sc_poller.log` | simpan log ke file |

## 6. Jangan taruh token di command line yang panjang — pakai config file
Buat `sc_poller.json` di folder script:
```json
{ "token": "123456:ABC...", "chat": "-1001583828319", "dir": "C:\\Users\\Eazy\\AppData\\Roaming\\MetaQuotes\\Terminal\\A1B2C3\\MQL5\\Files" }
```
Lalu cukup:
```bat
python sc_poller.py
```
Batasi akses file (opsional): klik-kanan → Properties → Security → hanya user kamu.

## 7. Jalankan otomatis saat Windows nyala
Buat `sc_poller.bat` di folder script:
```bat
@echo off
cd /d %~dp0
py sc_poller.py --log sc_poller.log
pause
```
Lalu: tekan `Win+R` → `shell:startup` → tempel **shortcut** ke `sc_poller.bat` di folder itu.
(Atau Task Scheduler → Create Task → Trigger "At log on" → Action: `py sc_poller.py`
dengan "Start in" = folder script.)

## 8. Kalau bermasalah
| Gejala | Sebab / solusi |
|---|---|
| `FOLDER TIDAK ADA` | `--dir` salah; jalankan `--find-mt5` |
| `ok=False chat not found` | id grup salah (harus mulai `-100`), atau bot belum jadi anggota grup |
| `HTTP 401` | token salah → script berhenti sendiri |
| Tidak ada SC masuk | EA belum jalan, `webSend=false` belum diset, atau chart sedang tidak menghasilkan bar baru |
| SC dobel | ada 2 poller jalan (cek Task Manager) atau 2 terminal MT5 menulis folder sama |
| File PNG tidak muncul | sementara: MT5 menulis piksel satu per satu; `--min-age 20` membantu |

## Catatan
- **State anti-dobel** disimpan di `sc_poller_state.json` (nama file → mtime+ukuran).
  Hapus file ini kalau ingin mengirim ulang semuanya.
- Jalur hosting **tidak dihapus** — tinggal `webSend=true` untuk kembali.
- Token di `sc_poller.json` = kunci bot kamu. Jangan di-push ke GitHub.