# ChartShot → Telegram (Kingatasolutions)

Kirim screenshot chart MT5 (dengan OptimusPanel) ke channel Telegram tiap 15 menit, plus proteksi konten & auto-cleanup saat market off.

## Alur

```
MT5 (ChartShotSender.mq5) --WebRequest JSON(base64)--> hosting (tg_shot/send.php) --> Telegram sendPhoto (protected)
                                            ^-- Sabtu/Minggu: auto-cleanup semua pesan foto
```

## Komponen

| File | Fungsi |
|---|---|
| `ChartShotSender.mq5` | EA di MT5: screenshot tiap 15 menit, kirim ke endpoint |
| `ChartShotSender.ex5` | Hasil compile 0 error (mumpuni langsung di MQL5/Experts) |
| `tg_shot/send.php` | Endpoint di hosting: terima base64 → kirim ke channel, simpan message_id, hapus saat weekend |
| `tg_shot/sent.log` | Log message_id (dibuat otomatis) |

## Setup Hosting (sekali)

```bash
cd ~/public_html   # docroot
wget -qO /tmp/tg_shot_send.php https://raw.githubusercontent.com/genggong/chart-tg/main/tg_shot/send.php
mkdir -p tg_shot && mv /tmp/tg_shot_send.php tg_shot/send.php
chmod 644 tg_shot/send.php
# verifikasi
curl -s -o /dev/null -w "%{http_code}\n" https://vapekongstore.com/tg_shot/send.php   # harus 405 (bukan 404)
```

## Setup MT5

1. Copy `ChartShotSender.mq5` (atau `.ex5` kalau mau langsung pakai) ke `MQL5/Experts/`
2. Buka **Tools → Options → Expert Advisors → Allow WebRequest** → tambahkan `https://vapekongstore.com`
3. Taruh EA di chart **M15** (screenshot menampilkan OptimusPanel yang jalan di chart M15)
4. Input default sudah benar: `everyMinutes=15`, `webUrl=https://vapekongstore.com/tg_shot/send.php`, `webKey=<key>`
5. Kompilasi (kalau pakai `.mq5`) → 0 error

## Fitur

- **Tiap 15 menit**: screenshot chart (1280×720) + caption simbol/TF/waktu → kirim ke channel
- **Proteksi konten**: `protect_content=true` → anggota tidak bisa screenshot/copy/forward
- **Auto-cleanup Sabtu–Minggu**: EA kirim ping saat market off → send.php menghapus semua pesan foto lama dari channel (deleteMessage), log dikosongkan
- **Key rahasia** di body JSON mencegah endpoint disalah-pakai orang lain

## Keamanan

- `SECRET_KEY` harus sama antara `ChartShotSender.mq5` (input `webKey`) dan `tg_shot/send.php`
- Bot hanya perlu izin: kirim pesan + hapus pesan di channel
- Endpoint menolak non-POST & key salah (403)

## Custom

- Ganti interval: input `everyMinutes` di EA
- Ganti tujuan: parameter `webChat` di EA (berisi chat_id) atau edit `TG_CHAT_ID` di send.php
- Ganti bot: edit `TG_BOT_TOKEN` di send.php