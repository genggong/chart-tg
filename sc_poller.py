#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sc_poller.py — Kirim screenshot MT5 ke Telegram TANPA hosting (jalur LOKAL).

Cara kerja:
  MT5 (ChartShotSender: webSend=false) menulis PNG ke <MT5 Data Folder>\\MQL5\\Files\\
  -> script ini mengawasi folder itu, dan setiap file gambar BARU dikirim sendiri
     ke Telegram lewat api.telegram.org/sendPhoto.

Keunggulan jalur lokal:
  + tidak butuh hosting/PHP
  + tidak butuh whitelist WebRequest di MT5
  - butuh proses ini selalu hidup di mesin yang sama dengan MT5

Contoh pakai (Windows):
  python sc_poller.py --token 123456:ABC... --chat -1001583828319 ^
      --dir "C:\\Users\\Eazy\\AppData\\Roaming\\MetaQuotes\\Terminal\\HASH\\MQL5\\Files"

  python sc_poller.py --find-mt5          (cari otomatis folder MQL5\\Files)
  python sc_poller.py --once              (sekali scan saja, lalu keluar)
  python sc_poller.py --dry-run           (uji tanpa mengirim ke Telegram)
  python sc_poller.py --send-test <chat_id> [--image file.png]   (tes kirim 1 gambar)

Catatan: token/chat bisa juga dari env TG_TOKEN / TG_CHAT, atau file sc_poller.json
         ({"token": "...", "chat": "-100...", "dir": "..."}), permission 600.
"""

import argparse
import json
import os
import sys
import time
import uuid
import urllib.request
import urllib.error
from pathlib import Path

IMG_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
DEFAULT_STATE = "sc_poller_state.json"
DEFAULT_LOG = "sc_poller.log"
DEFAULT_CAPTION = "{sym} {tf}"


# ----------------------------------------------------------------- utilitas
LOGFILE = None      # diisi dari --log; None = tanpa file log


def log(msg, logfile=None):
    line = "[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    lf = logfile or LOGFILE
    if lf:
        try:
            with open(lf, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return "%.0f %s" % (n, u)
        n /= 1024.0
    return "%.1f TB" % n


def multipart(fields, files):
    """files: {field_name: (filename, bytes, mime)} — tanpa dependensi eksternal."""
    b = uuid.uuid4().hex
    out = bytearray()
    for k, v in fields.items():
        out += ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                % (b, k, v)).encode("utf-8")
    for k, (fn, data, mime) in files.items():
        out += ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\n'
                'Content-Type: %s\r\n\r\n' % (b, k, fn, mime)).encode("utf-8")
        out += data + b"\r\n"
    out += ("--%s--\r\n" % b).encode("utf-8")
    return bytes(out), "multipart/form-data; boundary=%s" % b


def tg(token, method, fields=None, files=None, timeout=180):
    url = "https://api.telegram.org/bot%s/%s" % (token, method)
    if files:
        body, ctype = multipart(fields or {}, files)
    else:
        body = json.dumps(fields or {}).encode("utf-8")
        ctype = "application/json"
    req = urllib.request.Request(url, data=body, headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def mime_of(path):
    e = path.suffix.lower()
    return {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".webp": "image/webp", ".gif": "image/gif"}.get(e, "application/octet-stream")


def caption_for(path, template):
    """chart_XAUUSD_M15.png -> {sym:XAUUSD, tf:M15}; SC_20261017_XAUUSD_M30.png -> XAUUSD M30."""
    SKIP = {"CHART", "CHARTSHOT", "SC", "SHOT", "SNAPSHOT", "IMG", "IMAGE", "SCREEN",
            "SHOOT", "SENDER", "PANEL", "OPTIMUS", "NEW", "COPY", "FINAL", "EXPORT", "PNG"}
    TFS = {"M1", "M5", "M15", "M30", "H1", "H2", "H3", "H4", "H6", "H8", "H12",
           "D1", "W1", "MN", "MN1", "DAILY", "WEEKLY", "MONTHLY", "PERIOD"}
    p = path.stem.split("_")
    sym = tf = ""
    for tok in p:
        t = tok.upper()
        if t in SKIP:
            continue
        if not sym:
            if t.isalpha() and len(t) >= 3:
                sym = t
            continue
        if not tf and (t.isdigit() or t in TFS):
            tf = t
    if not sym:
        sym = path.stem
    try:
        return template.format(sym=sym, tf=tf, name=path.name).strip()
    except (KeyError, IndexError):
        return ("%s %s" % (sym, tf)).strip()


def find_mt5_files():
    """Cari semua folder MQL5\\Files milik terminal MetaTrader di Windows."""
    base = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
    hits = []
    if base.is_dir():
        for d in sorted(base.iterdir()):
            f = d / "MQL5" / "Files"
            if f.is_dir():
                pngs = list(f.glob("*.png"))
                hits.append((f, len(pngs)))
    return hits


def load_state(p):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(p, s):
    try:
        Path(p).write_text(json.dumps(s, ensure_ascii=False), encoding="utf-8")
    except OSError as e:
        log("GAGAL simpan state: %s" % e)


def file_ready(path, tries=8, delay=0.6):
    """Tunggu file selesai ditulis (ukuran stabil 2x) — MT5 menulis bertahap."""
    last = -1
    for _ in range(tries):
        try:
            sz = path.stat().st_size
        except OSError:
            return False
        if sz > 0 and sz == last:
            return True
        last = sz
        time.sleep(delay)
    return last > 0


def key_of(path):
    st = path.stat()
    return "%d|%d" % (int(st.st_mtime), st.st_size)


# ----------------------------------------------------------------- perintah
def cmd_find_mt5():
    hits = find_mt5_files()
    if not hits:
        print("Tidak ketemu folder MQL5\\Files. Jalankan di Windows, atau isi --dir manual.")
        print(r"Lokasi umum: C:\Users\<nama>\AppData\Roaming\MetaQuotes\Terminal\<HASH>\MQL5\Files")
        return 1
    print("Kandidat folder MQL5\\Files (jumlah PNG yang ada sekarang):")
    for f, n in hits:
        print("  [%d png]  %s" % (n, f))
        print('           --dir "%s"' % f)
    return 0


def cmd_send_test(args):
    token = args.token
    img = Path(args.image) if args.image else None
    if not img or not img.is_file():
        # buat gambar PNG kecil sendiri (1x1 px biru) supaya tes tidak butuh file luar
        img = Path("sc_test.png")
        img.write_bytes(bytes.fromhex(
            "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
            "0000000d4944415478da63f8cfc0000003010100b5e5e5f60000000049454e44ae426082"))
        log("gambar tes dibuat: %s" % img.resolve())
    data = img.read_bytes()
    res = tg(token, "sendPhoto",
             {"chat_id": str(args.chat), "caption": "Tes SC poller lokal — %s" % img.name},
             {"photo": (img.name, data, mime_of(img))})
    ok = res.get("ok")
    log("SEND-TEST %s -> ok=%s %s" % (img.name, ok, res.get("description", "")))
    return 0 if ok else 2


def cmd_run(args):
    token, chat, folder = args.token, str(args.chat), Path(args.dir)
    if not folder.is_dir():
        log("FOLDER TIDAK ADA: %s" % folder)
        return 2
    log("poller lokal mulai | folder=%s | chat=%s | interval=%ss | dry_run=%s"
        % (folder, chat, args.interval, args.dry_run))

    state = load_state(args.state)
    # hindari kirim ulang backlog lama saat pertama jalan
    if args.skip_existing and not state:
        for f in folder.iterdir():
            if f.suffix.lower() in IMG_EXT:
                try:
                    state[str(f)] = key_of(f)
                except OSError:
                    pass
        save_state(args.state, state)
        log("backlog diabaikan: %d file lama ditandai sudah-terkirim" % len(state))

    sent = failed = 0
    while True:
        try:
            cands = sorted((f for f in folder.iterdir()
                            if f.suffix.lower() in IMG_EXT and f.is_file()),
                           key=lambda p: p.stat().st_mtime)
        except OSError as e:
            log("gagal baca folder: %s" % e)
            cands = []

        for f in cands:
            k = str(f)
            try:
                cur = key_of(f)
            except OSError:
                continue
            if state.get(k) == cur:
                continue                                   # sudah pernah dikirim
            if args.min_age and (time.time() - f.stat().st_mtime) < args.min_age:
                continue                                   # terlalu baru, tunggu matang
            if not file_ready(f):
                continue                                   # belum selesai ditulis
            cur = key_of(f)                                # ukuran bisa berubah saat menunggu
            if state.get(k) == cur:
                continue
            cap = caption_for(f, args.caption)
            if args.dry_run:
                log("DRY-RUN kirim: %s (%s) caption=%r" % (f.name, human(f.stat().st_size), cap))
                state[k] = cur
                sent += 1
                continue
            try:
                res = tg(token, "sendPhoto",
                         {"chat_id": chat, "caption": cap},
                         {"photo": (f.name, f.read_bytes(), mime_of(f))})
                if res.get("ok"):
                    state[k] = cur
                    sent += 1
                    log("TERKIRIM %s (%s) caption=%r | total=%d"
                        % (f.name, human(f.stat().st_size), cap, sent))
                else:
                    failed += 1
                    log("GAGAL %s -> %s" % (f.name, res.get("description")))
            except urllib.error.HTTPError as e:
                failed += 1
                body = e.read().decode("utf-8", "ignore")[:200]
                log("GAGAL %s -> HTTP %s %s" % (f.name, e.code, body))
                if e.code in (401, 403):
                    log("  -> token/chat salah atau bot belum di-approve di grup. Berhenti.")
                    return 3
            except (urllib.error.URLError, OSError) as e:
                failed += 1
                log("GAGAL %s -> %s (akan dicoba lagi nanti)" % (f.name, e))
            save_state(args.state, state)

        save_state(args.state, state)     # selalu simpan (termasuk mode dry-run)

        if args.once:
            break
        time.sleep(max(2, args.interval))

    log("selesai | terkirim=%d gagal=%d" % (sent, failed))
    return 0


# ----------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Kirim SC MT5 ke Telegram tanpa hosting (lokal)")
    ap.add_argument("--token", default=os.environ.get("TG_TOKEN", ""), help="bot token Telegram")
    ap.add_argument("--chat", default=os.environ.get("TG_CHAT", ""), help="chat/group id target")
    ap.add_argument("--dir", default=os.environ.get("TG_DIR", ""), help="folder MQL5\\Files MT5")
    ap.add_argument("--interval", type=int, default=10, help="detik antar scan (default 10)")
    ap.add_argument("--min-age", type=int, default=0, help="abaikan file lebih baru dari N detik")
    ap.add_argument("--caption", default=DEFAULT_CAPTION, help="template caption: {sym} {tf} {name}")
    ap.add_argument("--state", default=DEFAULT_STATE, help="file state (anti kirim dobel)")
    ap.add_argument("--log", default=DEFAULT_LOG, help="file log (kosongkan utk matikan)")
    ap.add_argument("--once", action="store_true", help="sekali scan lalu keluar")
    ap.add_argument("--dry-run", action="store_true", help="uji tanpa mengirim")
    ap.add_argument("--skip-existing", action="store_true", default=True,
                    help="(default) tandai file lama sbg sudah terkirim")
    ap.add_argument("--no-skip-existing", dest="skip_existing", action="store_false")
    ap.add_argument("--find-mt5", action="store_true", help="cari folder MQL5\\Files lalu keluar")
    ap.add_argument("--send-test", dest="send_test", action="store_true",
                    help="kirim 1 gambar tes ke --chat lalu keluar")
    ap.add_argument("--image", default="", help="gambar utk --send-test (default: PNG kecil bawaan)")
    args = ap.parse_args()

    if args.find_mt5:
        return cmd_find_mt5()

    # config file opsional (menimpa default kosong saja)
    cfg = load_state("sc_poller.json")
    for k in ("token", "chat", "dir"):
        if not getattr(args, k) and cfg.get(k):
            setattr(args, k, cfg[k])

    if not args.token:
        print("ERROR: token kosong. Isi --token, env TG_TOKEN, atau sc_poller.json")
        return 2
    if args.send_test:
        return cmd_send_test(args)
    if not args.chat:
        print("ERROR: --chat kosong (id grup/channel tujuan)")
        return 2
    if not args.dir:
        print("ERROR: --dir kosong. Cari dulu dengan: python sc_poller.py --find-mt5")
        return 2
    if args.log:
        globals()["LOGFILE"] = args.log
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())