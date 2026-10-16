# PASANG SEKALIAN — OptimusPanel v34 + ChartShotSender

Paket ini berisi:
- `OptimusPanel.mq5` + `OptimusPanel.ex5` — indikator panel multi-TF versi terbaru
- `ChartShotSender.mq5` + `ChartShotSender.ex5` — EA screenshot tiap 15 menit → channel Telegram
- 2 preset panel (Kompak / Lengkap)

## 🔧 1. Pasang file

Copy file **`.mq5`** (dan `.ex5` kalau build MT5 kamu cocok) ke:

| File | Tujuan folder |
|---|---|
| `OptimusPanel.mq5` (wajib) | `MQL5\Indicators\` |
| `OptimusPanel.ex5` (opsional) | `MQL5\Indicators\` |
| `ChartShotSender.mq5` (wajib) | `MQL5\Experts\` |
| `ChartShotSender.ex5` (opsional) | `MQL5\Experts\` |

⚠️ **Karena MT5 kamu Windows 7 build 6230**, kalau `.ex5` tidak mau load, **kompilasi sendiri**:
1. Buka MetaEditor → buka `OptimusPanel.mq5` → F7 → harus 0 error
2. Buka `ChartShotSender.mq5` → F7 → harus 0 error

## 🔧 2. Izinkan WebRequest (sekali)

**Tools → Options → Expert Advisors** → centang **Allow WebRequest** → di kolom URL tambahkan:
```
https://vapekongstore.com
```
(dan OK)

## 📈 3. Pasang di chart M15 (ini PENTING)

1. Buka chart **symbol utama** (mis. XAUUSD) di **timeframe M15**
2. Seret **OptimusPanel** ke chart → panel muncul di sub-window bawah
   - Pakai preset `OptimusPanel_Lengkap.set` kalau mau tampilan penuh
3. Seret **ChartShotSender** ke chart yang sama
   - Input sudah default benar: `everyMinutes=15`, `webUrl=https://vapekongstore.com/tg_shot/send.php`, key terisi
4. Pastikan EA aktif (ikon autotrading / smiley tersenyum di toolbar, atau `Expert` muncul di jendela DataToolbox)

## 📤 Hasil

Tiap **15 menit**: MT5 screenshot chart M15 + panel Optimus → kirim ke channel **Kingatasolutions**:
- ✅ Anggota tidak bisa screenshot/copy/forward (protected content)
- ✅ Sabtu–Minggu market off: foto lama otomatis dibersihkan

## Verifikasi cepat

Setelah 15 menit, cek channel — harus ada gambar chart M15 dengan panel di bawahnya. Kalau belum, buka **Tools → Expert Advisors → Journal** tab di MT5 dan cari baris `[ChartShotSender]` — kirim teks error-nya ke Ndes.