//+------------------------------------------------------------------+
//|                                             ChartShotSender.mq5  |
//|  Screenshot chart tiap N menit, simpan ke MQL5\Files\, lalu      |
//|  kirim ke Telegram via endpoint PHP di hosting (WebRequest).     |
//|                                                                  |
//|  Prasyarat:                                                      |
//|   - MT5: Tools > Options > Expert Advisors > Allow WebRequest    |
//|     tambahkan domain panel: https://palasanga.site               |
//|   - Upload tg_shot/send.php ke hosting, set $SECRET & token bot  |
//+------------------------------------------------------------------+
#property copyright "Ndes"
#property version   "1.28"
#property description "Data panel Optimus -> website (hosting). SC grup TIDAK dikirim oleh EA ini."

input int    everyMinutes = 15;     // Interval screenshot (menit)
input string shotFilename = "";     // Kosong = auto "chart_<SYMBOL>_<TF>.png" (unik per pair)
input bool   shotIkutJendela = false; // false = pakai shotWidth x shotHeight (1280x720, sama seperti berkas Anda)
input int    shotSkala     = 1;      // pengali (1 = pas; jangan >1 kalau layar kecil)
input int    shotWidth    = 1280;   // Lebar gambar px (SAMA seperti berkas Anda)
input int    shotHeight   = 720;    // Tinggi gambar px (SAMA seperti berkas Anda)
input bool   shotOnInit   = false;   // Screenshot langsung saat dipasang
input bool   showInfo     = true;   // Label info simbol & waktu di gambar
input bool   ignoreMarketClose = false; // true = tetap kirim SC walau broker bilang pasar tutup (crypto yg tak punya info sesi)
input bool   webSend      = false;   // Kirim via WebRequest
input string webUrl       = "https://palasanga.site/tg_shot/send.php";
input string webKey       = "PAL2f01487bf0cdec19040bde"; // Secret send.php
input string webChat      = "-1001583828319"; // Group default: kirim lgsg ke group tanpa isi parameter
input int    webTimeout   = 10000;  // ms
//=== MODE KIRIM LANGSUNG KE TELEGRAM (tanpa hosting/PHP) — kebal proteksi anti-bot hosting ===
input bool   kirimLangsung = false;      // true = SC dikirim LANGSUNG ke Telegram (api.telegram.org), tidak lewat hosting
// JANGAN bagikan berkas .mq5 ini ke luar grup (ada token bot di dalamnya)
input string tgToken       = "TEMPEL-TOKEN-BOT-DISINI"; // token bot (dari BotFather). Ganti bila bocor.
input string tgChat        = "-1001583828319"; // chat/grup tujuan (grup Vantera Trading Konsultan)
//=== mode lama lewat hosting (dipakai bila kirimLangsung=false) ===
input bool   panelPush    = true;   // Kirim data panel (indikator OptimusPanel) ke website
input string panelUrl     = "https://palasanga.site/vantera/panel_data.php"; // endpoint data panel (website Vantera) — ganti bila domain pindah
input int    panelPushSec = 5;     // jeda minimal antar-kirim payload panel (detik)
input int    panelCropPersen = 0;  // SC: sisakan bagian BAWAH gambar (area panel) sebanyak % ini (0 = matikan)
input double panelZoom       = 1.0; // SC: perbesar area panel setelah dipotong (1.0 = tanpa perbesar)
input bool   kirimDuaGambar  = false; // false = SATU foto saja (bersih). true = 2 foto (chart + panel diperbesar) - hati2 jadi ramai
input int    belahPersen     = 0;    // (dipakai kalau kirimDuaGambar=true) % tinggi dari bawah = area panel
input double belahZoom       = 2.0;  // perbesaran foto panel (1.0 - 3.5)
input int    kropAtasPersen  = 0;    // 0 = kirim gambar penuh (disarankan). >0 = potong jadi hanya area atas (chart)
input int    panelPushUlangMenit = 10; // kirim ulang payload panel walau isinya tidak berubah (menit). 0 = matikan
                                       // berguna bila data di hosting terhapus: web terisi sendiri lagi

const string c_label = "_ChartShotSender_info";
int g_lastShot = 0;
string g_panelNama[8];   // penanda payload panel yang sudah terkirim (anti kirim ulang)
string g_panelIsi[8];
datetime g_panelKirimTerakhir = 0;   // untuk pengiriman ulang berkala
int g_lastCleanup = 0;
int g_lastBoundary = 0;   // boundary 15-menit terakhir yang sudah di-shoot (sejajar jam)
bool g_noSessionInfo = false; // true = broker SAMA SEKALI tak punya info sesi (crypto 24/7)

//+------------------------------------------------------------------+
//| Helper                                                            |
//+------------------------------------------------------------------+
string TfName()
{
   switch(_Period)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return EnumToString(_Period);
   }
}

//--- Jam dunia GMT nyata (dari jam lokal PC + offset GMT, bukan jam server broker)
string WorldTimeStr()
{
   datetime gmt = TimeLocal() - TimeGMTOffset();
   return TimeToString(gmt, TIME_DATE | TIME_SECONDS);
}

void UpdateInfoLabel()
{
   if(ObjectFind(0, c_label) < 0)
   {
      if(!ObjectCreate(0, c_label, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, c_label, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, c_label, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, c_label, OBJPROP_YDISTANCE, 10);
      ObjectSetInteger(0, c_label, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, c_label, OBJPROP_BACK, false);
      ObjectSetString(0, c_label, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, c_label, OBJPROP_FONTSIZE, 11);
   }
   MqlDateTime st; TimeToStruct(TimeTradeServer(), st);
   ObjectSetString(0, c_label, OBJPROP_TEXT,
      StringFormat("%s %s | %s GMT | SVR %02d:%02d", _Symbol, TfName(),
                   WorldTimeStr(), st.hour, st.min));
}

string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", "");
   StringReplace(s, "\n", "\\n");
   return s;
}

//--- Encode uchar[] ke base64 (stdlib MT5 tidak punya)
string Base64Encode(uchar &data[])
{
   static const string tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
   int n = ArraySize(data);
   int outLen = ((n + 2) / 3) * 4;
   ushort out[];
   ArrayResize(out, outLen);
   int oi = 0;

   for(int i = 0; i < n; i += 3)
   {
      uint a = data[i];
      uint b = (i + 1 < n) ? data[i + 1] : 0;
      uint c = (i + 2 < n) ? data[i + 2] : 0;
      uint x = (a << 16) | (b << 8) | c;
      out[oi++] = StringGetCharacter(tbl, (x >> 18) & 0x3F);
      out[oi++] = StringGetCharacter(tbl, (x >> 12) & 0x3F);
      out[oi++] = (i + 1 < n) ? StringGetCharacter(tbl, (x >> 6) & 0x3F) : '=';
      out[oi++] = (i + 2 < n) ? StringGetCharacter(tbl, x & 0x3F) : '=';
   }
   return ShortArrayToString(out, 0, outLen);
}

//--- Baca PNG + POST base64 JSON ke endpoint
bool SendPng(string file, string caption)
{
   int h = FileOpen(file, FILE_READ | FILE_BIN, 0);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("[ChartShotSender] File tidak terbaca: %s (%d)", file, GetLastError());
      return false;
   }
   ulong sz = FileSize(h);
   if(sz <= 0 || sz > 8 * 1024 * 1024)
   {
      PrintFormat("[ChartShotSender] Ukuran file aneh: %llu", sz);
      FileClose(h);
      return false;
   }
   uchar img[];
   ArrayResize(img, (int)sz);
   FileReadArray(h, img, 0, (int)sz);
   FileClose(h);

   string b64 = Base64Encode(img);
   string json = StringFormat("{\"key\":\"%s\",\"chat\":\"%s\",\"sym\":\"%s\",\"caption\":\"%s\",\"crop\":%d,\"zoom\":%.2f,\"belah\":%d,\"belahPersen\":%d,\"belahZoom\":%.2f,\"kropAtas\":%d,\"img\":\"%s\"}",
                              JsonEscape(webKey), JsonEscape(webChat), JsonEscape(_Symbol),
                              JsonEscape(caption), panelCropPersen, panelZoom,
                              (kirimDuaGambar ? 1 : 0), belahPersen, belahZoom, kropAtasPersen, b64);

   char body[];   // WebRequest wajib char[] (uchar[] -> error 4006)
   int len = StringToCharArray(json, body, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(body, len - 1); // buang null terminator

   string hdrs = "Content-Type: application/json";
   char result[];
   string resultHdrs;
   ResetLastError();
   int rc = WebRequest("POST", webUrl, hdrs, webTimeout, body, result, resultHdrs);
   if(rc == -1)
   {
      int e = GetLastError();
      string tips = "";
      if(e == 4060 || e == 4014)
         tips = StringFormat(" -> DOMAIN BELUM DIIZINKAN. MT5: Tools > Options > Expert Advisors > "
                             "centang 'Allow WebRequest for listed URL' lalu tambahkan: %s", webUrl);
      else if(e == 5203)
         tips = " -> request ditolak server (cek URL endpoint)";
      PrintFormat("[ChartShotSender] WebRequest GAGAL (err %d)%s", e, tips);
      return false;
   }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(rc != 200)
   {
      PrintFormat("[ChartShotSender] SC GAGAL — server balas HTTP %d. Body: %s", rc, resp);
      PrintFormat("[ChartShotSender]   cek: endpoint %s hidup? key webKey sama dgn SECRET_KEY di send.php?", webUrl);
      return false;
   }
   if(StringFind(resp, "\"ok\":true") < 0)
   {
      PrintFormat("[ChartShotSender] SC GAGAL — endpoint balas 200 tapi ok!=true: %s", resp);
      return false;
   }
   PrintFormat("[ChartShotSender] Terkirim ke %s (%d bytes): %s", webChat, (int)sz, resp);
   return true;
}

//--- Nama file otomatis unik per pair+TF (anti-tabrakan saat multi pair)
string ShotAutoName()
{
   string sym = _Symbol;
   StringReplace(sym, ".", "_");   // simbol dgn titik (mis. XAUUSD.a) -> aman utk nama file
   return StringFormat("chart_%s_%s.png", sym, TfName());
}

//--- Kirim PNG LANGSUNG ke Telegram (multipart/form-data) — tanpa hosting.
bool KirimTelegramLangsung(string file, string caption)
{
   if(StringFind(tgToken, "TEMPEL") >= 0)
   { Print("[Direct] tgToken MASIH PLACEHOLDER. Isi dengan token bot asli: klik kanan chart > Expert Advisors > Properties > tab Inputs > baris tgToken (token ada di berkas send.php di hosting Anda, atau dari BotFather)."); return false; }
   if(StringLen(tgToken) < 20 || StringLen(tgChat) < 3)
   { PrintFormat("[Direct] tgToken/tgChat belum diisi (token %d char, chat '%s')", StringLen(tgToken), tgChat); return false; }

   int h = FileOpen(file, FILE_READ | FILE_BIN, 0);
   if(h == INVALID_HANDLE)
   { PrintFormat("[Direct] File tidak terbaca: %s (%d)", file, GetLastError()); return false; }
   ulong sz = FileSize(h);
   if(sz <= 0 || sz > 8 * 1024 * 1024)
   { PrintFormat("[Direct] Ukuran file aneh: %llu", sz); FileClose(h); return false; }
   uchar img[];
   ArrayResize(img, (int)sz);
   FileReadArray(h, img, 0, (int)sz);
   FileClose(h);

   string batas = "----MT5BoundaryVantera7f3a";
   string cap = caption;
   if(StringLen(cap) > 900) cap = StringSubstr(cap, 0, 900);   // batas caption Telegram

   string pre = "--" + batas + "\r\n"
                "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n" + tgChat + "\r\n"
                "--" + batas + "\r\n"
                "Content-Disposition: form-data; name=\"caption\"\r\n\r\n" + cap + "\r\n"
                "--" + batas + "\r\n"
                "Content-Disposition: form-data; name=\"disable_notification\"\r\n\r\nfalse\r\n"
                "--" + batas + "\r\n"
                "Content-Disposition: form-data; name=\"photo\"; filename=\"chart.png\"\r\n"
                "Content-Type: image/png\r\n\r\n";
   string post = "\r\n--" + batas + "--\r\n";

   uchar body[];
   int nPre = StringToCharArray(pre, body, 0, WHOLE_ARRAY, CP_UTF8);
   if(nPre > 0) ArrayResize(body, nPre - 1);
   int nBody = ArraySize(body);
   uchar tail[];
   int nTail = StringToCharArray(post, tail, 0, WHOLE_ARRAY, CP_UTF8);
   if(nTail > 0) ArrayResize(tail, nTail - 1);
   int nTailSz = ArraySize(tail);
   ArrayResize(body, nBody + (int)sz + nTailSz);
   ArrayCopy(body, img, nBody, 0, (int)sz);
   ArrayCopy(body, tail, nBody + (int)sz, 0, nTailSz);
   ArrayResize(body, nBody + (int)sz + nTailSz);

   string url  = "https://api.telegram.org/bot" + tgToken + "/sendPhoto";
   string hdrs = "Content-Type: multipart/form-data; boundary=" + batas;

   char hasil[];
   string hasilHdr;
   ResetLastError();
   char kirim[];                      // WebRequest hanya menerima char[]; uchar[] -> error 4006
   int nKirim = ArraySize(body);
   ArrayResize(kirim, nKirim);
   for(int i = 0; i < nKirim; i++) kirim[i] = (char)body[i];
   int rc = WebRequest("POST", url, hdrs, webTimeout, kirim, hasil, hasilHdr);
   if(rc == -1)
   {
      int e = GetLastError();
      string tips = "";
      if(e == 4060 || e == 4014)
         tips = " -> TAMBAHKAN 'https://api.telegram.org' di MT5: Tools > Options > Expert Advisors > Allow WebRequest";
      PrintFormat("[Direct] WebRequest GAGAL (err %d)%s", e, tips);
      return false;
   }
   string resp = CharArrayToString(hasil, 0, WHOLE_ARRAY, CP_UTF8);
   if(rc == 200 && StringFind(resp, "\"ok\":true") >= 0)
   {
      PrintFormat("[Direct] TERKIRIM langsung ke Telegram %s (%d byte foto)", tgChat, (int)sz);
      return true;
   }
   string petunjuk = "";
   if(rc == 404) petunjuk = " -> TOKEN SALAH. Format benar: <angka>:<huruf> (mis. 1234567890:AAH...), TANPA spasi, TANPA kata 'bot' di depan.";
   PrintFormat("[Direct] GAGAL rc=%d | token: %d karakter, awal '%s', chat '%s'%s | balasan: %s",
               rc, StringLen(tgToken), StringSubstr(tgToken, 0, 4), tgChat, petunjuk, StringSubstr(resp, 0, 200));
   return false;
}

void TakeShot(datetime bTime = 0)
{
   if(showInfo)
      UpdateInfoLabel();

   // bTime = waktu BOUNDARY (:00/:15/:30/:45) supaya label waktu di gambar sama
   // persis dengan jadwalnya, bukan waktu proses yg bisa geser beberapa detik.
   if(bTime <= 0)
      bTime = TimeTradeServer();

   string fn = (StringLen(shotFilename) > 0 ? shotFilename : ShotAutoName());
   // refresh chart dulu biar gambar terbaru
   ChartRedraw(0);
   // --- ukuran gambar: ikut jendela chart (anti pecah/upscale) ---
   int wShot = shotWidth, hShot = shotHeight;
   if(shotIkutJendela)
   {
      int wJ = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int hJ = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      if(wJ > 200 && hJ > 200)
      {
         int sk = (shotSkala < 1 ? 1 : shotSkala);
         wShot = wJ * sk; hShot = hJ * sk;
      }
      else
         PrintFormat("[ChartShotSender] ukuran jendela tak terbaca (%dx%d) -> pakai %dx%d", wJ, hJ, shotWidth, shotHeight);
   }
   bool ok = ChartScreenShot(0, fn, wShot, hShot, ALIGN_RIGHT);
   if(!ok)
   {
      PrintFormat("[ChartShotSender] Gagal screenshot (%d). Lokasi: MQL5\\Files\\%s",
                  GetLastError(), fn);
      return;
   }
   PrintFormat("[ChartShotSender] Screenshot OK -> MQL5\\Files\\%s", fn);
   MqlDateTime cst; TimeToStruct(bTime, cst);
   if(kirimLangsung)
   {
      string capL = StringFormat("%s %s | %s GMT | SVR %02d:%02d", _Symbol, TfName(),
                                 WorldTimeStr(), cst.hour, cst.min);
      KirimTelegramLangsung(fn, capL);
   }
   else if(webSend)
   {
      string caption = StringFormat("%s %s | %s GMT | SVR %02d:%02d", _Symbol, TfName(),
                                    WorldTimeStr(), cst.hour, cst.min);
      SendPng(fn, caption);
   }
}

//+------------------------------------------------------------------+
//| Event handler                                                     |
//+------------------------------------------------------------------+
//--- Kirim payload panel (ditulis indikator OptimusPanel) ke website.
//    Indikator TIDAK BISA memanggil WebRequest (aturan MQL5), jadi tugas kirim ada di EA ini.
void PushPanel()
{
   if(!panelPush) return;
   string nama = "";
   long cari = FileFindFirst("panel_web_*.json", nama);
   if(cari == INVALID_HANDLE)
   {
      static datetime s_logKosong = 0;
      if(TimeCurrent() - s_logKosong > 300)
      {
         Print("[PanelPush] TIDAK ADA berkas panel_web_*.json di MQL5\\Files — indikator OptimusPanel belum menulis.");
         Print("[PanelPush]   cek: (1) OptimusPanel terpasang di chart? (2) input webAktif = true? (3) tunggu 1-2 menit setelah indikator dipasang.");
         s_logKosong = TimeCurrent();
      }
      return;
   }
   do
   {
      int fh = FileOpen(nama, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(fh == INVALID_HANDLE) continue;
      string isi = "";
      while(!FileIsEnding(fh)) isi += FileReadString(fh);
      FileClose(fh);
      if(StringLen(isi) < 10) continue;

      // Token di berkas payload ditulis oleh INDIKATOR (input webToken-nya).
      // Di sini token itu DIPAKSA = webKey milik EA, supaya tidak pernah lagi
      // berbeda (penyebab jurnal: {"ok":false,"pesan":"token salah"}).
      int pt = StringFind(isi, "\"token\":\"");
      if(pt >= 0)
      {
         int q1 = pt + 9;                                 // tepat setelah  "token":"
         int q2 = StringFind(isi, "\"", q1);
         if(q2 > q1) isi = StringSubstr(isi, 0, q1) + webKey + StringSubstr(isi, q2);
      }

      static string s_terakhir = "";
      if(s_terakhir != nama)
      {
         PrintFormat("[PanelPush] berkas payload ditemukan: %s (%d byte)", nama, StringLen(isi));
         s_terakhir = nama;
      }
      int idx = -1;
      for(int i = 0; i < ArraySize(g_panelNama); i++)
         if(g_panelNama[i] == nama) { idx = i; break; }
      bool ulangWaktu = (panelPushUlangMenit > 0 && g_panelKirimTerakhir > 0
                         && (TimeCurrent() - g_panelKirimTerakhir) >= (long)panelPushUlangMenit * 60);
      if(idx >= 0 && g_panelIsi[idx] == isi && !ulangWaktu) continue;   // isi sama & belum waktunya -> jangan kirim ulang

      char body[];   // WebRequest wajib char[] (uchar[] -> error 4006)
      int len = StringToCharArray(isi, body, 0, WHOLE_ARRAY, CP_UTF8);
      if(len > 0) ArrayResize(body, len - 1);
      string hdrs = "Content-Type: application/json";
      char hasil[];
      string hasilHdr;
      ResetLastError();
      int rc = WebRequest("POST", panelUrl, hdrs, webTimeout, body, hasil, hasilHdr);
      string resp = CharArrayToString(hasil, 0, WHOLE_ARRAY, CP_UTF8);
      if(rc == 200 && StringFind(resp, "\"ok\":true") >= 0)
      {
         if(idx < 0)
            for(int i = 0; i < ArraySize(g_panelNama); i++)
               if(g_panelNama[i] == "") { idx = i; break; }
         if(idx < 0) idx = 0;
         g_panelNama[idx] = nama;
         g_panelIsi[idx]  = isi;
         g_panelKirimTerakhir = TimeCurrent();
         PrintFormat("[PanelPush] OK %s (%d byte)%s -> %s", nama, StringLen(isi),
                     (ulangWaktu ? " [kirim ulang berkala]" : ""), panelUrl);
      }
      else
      {
         int e = GetLastError();
         string tips = "";
         if(e == 4014 || e == 4060)
            tips = StringFormat(" -> TAMBAHKAN URL INI di Tools > Options > Expert Advisors > Allow WebRequest: %s", panelUrl);
         PrintFormat("[PanelPush] GAGAL %s rc=%d err=%d%s | balasan: %s", nama, rc, e, tips, StringSubstr(resp, 0, 160));
      }
   }
   while(FileFindNext(cari, nama));
   FileFindClose(cari);
}

int OnInit()
{
   // Timer 500 ms: cek boundary dg presisi sub-detik (dulu 60 dtk -> SC bisa telat 1 menit)
   EventSetMillisecondTimer(500);
   g_lastShot = 0;
   g_lastCleanup = 0;
   g_lastBoundary = (int)(TimeTradeServer() / (everyMinutes * 60)) * (everyMinutes * 60);
   g_noSessionInfo = DetectNoSessionInfo();

   //--- ringkasan setelan ke jurnal Expert (sekali saat dipasang) -> gampang dicek
   PrintFormat("[ChartShotSender] START %s %s | tiap %d menit (sejajar :00/:15/:30/:45) | kirim=%s | chat=%s",
               _Symbol, TfName(), everyMinutes, (webSend ? "WebRequest" : "OFF"), webChat);
   PrintFormat("[ChartShotSender] endpoint: %s | pasar: %s", webUrl,
               (g_noSessionInfo ? "24/7 (broker tak punya info sesi = crypto)"
                                : (IsMarketClosed() ? "TUTUP sekarang (SC di-skip, cleanup ping tetap jalan)"
                                                    : "BUKA")));
   if(webSend)
      PrintFormat("[ChartShotSender] WAJIB sekali saja: Tools > Options > Expert Advisors > Allow WebRequest + tambah %s",
                  webUrl);
   PrintFormat("[Direct] mode kirim langsung=%s | token: %d karakter (awal '%s') | chat: %s",
               (kirimLangsung ? "YA" : "tidak"), StringLen(tgToken), StringSubstr(tgToken, 0, 4), tgChat);
   PrintFormat("[PanelPush] aktif=%s | URL=%s | token webKey: %d karakter | jeda %d dtk | kirim ulang tiap %d menit",
               (panelPush ? "YA" : "TIDAK"), panelUrl, StringLen(webKey), panelPushSec, panelPushUlangMenit);
   PrintFormat("[ChartShotSender] SC: 2 gambar=%s | crop=%d%% zoom=x%.2f | panel %d%% zoom=x%.2f",
               (kirimDuaGambar ? "YA (chart + panel diperbesar)" : "tidak"), panelCropPersen, panelZoom, belahPersen, belahZoom);
   if(false) PrintFormat("[ChartShotSender] SC: crop bawah %d%% + zoom x%.2f (atur di input panelCropPersen/panelZoom; 0 = mati)",
               panelCropPersen, panelZoom);
   PrintFormat("[ChartShotSender] ukuran jendela chart: %d x %d px -> gambar SC %s",
               (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS), (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS),
               (shotIkutJendela ? "otomatis ikut jendela (tajam)" : StringFormat("%dx%d (manual)", shotWidth, shotHeight)));
   if(panelPush)
      PrintFormat("[ChartShotSender] Data panel -> %s (URL ini JUGA wajib didaftarkan di Allow WebRequest) | jeda %d dtk",
                  panelUrl, panelPushSec);

   if(shotOnInit)
   {
      // hindari SC DOBEL: kalau boundary berikutnya < 60 detik lagi, tunggu boundary saja
      int step0 = everyMinutes * 60;
      int now0  = (int)TimeTradeServer();
      int sisa  = step0 - (now0 % step0);
      if(sisa > 60)
         TakeShot();
      else
         PrintFormat("[ChartShotSender] shotOnInit dilewati — %d dtk lagi ke boundary (biar tidak dobel)", sisa);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(ObjectFind(0, c_label) >= 0)
      ObjectDelete(0, c_label);
}

void OnTimer()
{
   // TimeTradeServer() = jam server terminal, UPDATE TIAP DETIK tanpa perlu tick
   // (TimeCurrent() = waktu tick terakhir -> bisa macet di simbol sepi & bikin telat)
   datetime now = TimeTradeServer();

   // label jam di chart ikut hidup (dulu hanya berubah tiap SC -> kelihatan beku)
   static datetime s_lastLbl = 0;
   if(showInfo && now != s_lastLbl) { s_lastLbl = now; UpdateInfoLabel(); }

   //--- data panel -> website (independen dari gate pasar; payload hanya berubah saat bar baru)
   static datetime s_lastPanel = 0;
   if(panelPush && (int)now - (int)s_lastPanel >= MathMax(5, panelPushSec))
   {
      s_lastPanel = now;
      PushPanel();
   }

   if(!ignoreMarketClose && IsMarketClosed())
   {
      // Pasar tutup MENURUT BROKER (XAUUSD/forex weekend; BTC biasanya buka):
      // kirim ping trigger biar endpoint bersihkan foto lama (sekali per interval)
      if((int)now - g_lastCleanup >= everyMinutes * 60)
      {
         MqlDateTime td; TimeToStruct(now, td);
         PrintFormat("[ChartShotSender] %s: pasar tutup menurut broker (hari %d, 0=Minggu..6=Sabtu) — SC dilewati, kirim cleanup ping",
                     _Symbol, td.day_of_week);
         SendCleanupPing();
         g_lastCleanup = (int)now;
      }
      g_lastShot = (int)now; // jangan screenshot selama libur
      return;
   }
   // Kirim SELARAS JAM: boundary = kelipatan 15 menit jam server (:00, :15, :30, :45).
   // Timer 500 ms -> SC berangkat maksimal ~0,5 dtk setelah boundary (dulu timer 60 dtk
   // -> bisa telat sampai 1 menit, gambar jadi tidak cocok dgn jam yg dibaca anggota).
   int step      = everyMinutes * 60;
   int boundary  = (int)(now / step) * step;
   if(boundary != g_lastBoundary && now >= boundary)
   {
      double late = (double)(now - boundary);
      if(late <= (double)step)      // masih di boundary ini -> kirim
      {
         PrintFormat("[ChartShotSender] Boundary %s -> shot telat %.1f dtk",
                     TimeToString((datetime)boundary, TIME_MINUTES), late);
         TakeShot((datetime)boundary);
         g_lastShot = (int)now;
      }
      else
         PrintFormat("[ChartShotSender] Boundary %s terlewat %.0f dtk (PC tidur/offline) — dilewati, tidak kirim data basi",
                     TimeToString((datetime)boundary, TIME_MINUTES), late);
      g_lastBoundary = boundary;
   }
}

void OnTick() {}

//--- true saat pasar tutup MENURUT BROKER (sadar crypto 24/7):
//    cek SESI TRADE hari ini; kalau broker tak punya info sesi -> fallback Sabtu/Minggu.
//    (Dulu: Sabtu/Minggu selalu dianggap libur -> BTC/ETH yang jalan hari Sabtu
//     jadi tidak pernah dikirim SC-nya.)
bool IsMarketClosed()
{
   // Broker TIDAK punya info sesi utk simbol ini sama sekali (khas CRYPTO: BTCUSD/ETHUSD)
   // -> anggap 24/7, JANGAN skip SC. (Dulu: Bitcoin kena fallback Sabtu/Minggu = libur,
   //    padahal pasar crypto jalan -> SC hari Sabtu tidak pernah terkirim.)
   if(g_noSessionInfo) return false;

   MqlDateTime t;
   TimeToStruct(TimeTradeServer(), t);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)t.day_of_week;
   datetime from, to;
   if(SymbolInfoSessionTrade(_Symbol, dow, 0, from, to)) return false;   // ada sesi hari ini -> BUKA
   if(SymbolInfoSessionTrade(_Symbol, dow, 1, from, to)) return false;   // sesi ke-2
   return (t.day_of_week == 6 || t.day_of_week == 0);                    // fallback: Sabtu/Minggu
}

//--- true bila broker SAMA SEKALI tidak punya tabel sesi utk simbol ini (crypto 24/7)
bool DetectNoSessionInfo()
{
   datetime f, t;
   for(int d = 0; d < 7; d++)
      for(int s = 0; s < 2; s++)
         if(SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, s, f, t))
            return false;      // ada minimal 1 sesi sepekan -> broker punya info sesi
   return true;                // tak ada info sesi -> simbol 24/7 (crypto)
}

//--- true saat Sabtu/Minggu (waktu server broker) — hanya dipakai sbg fallback
bool IsWeekend()
{
   MqlDateTime t;
   TimeToStruct(TimeTradeServer(), t);
   return (t.day_of_week == 6 || t.day_of_week == 0);
}

//--- POST JSON kecil ke endpoint (dipakai sbg trigger cleanup saat libur)
void SendCleanupPing()
{
   if(!webSend) return;
   string json = StringFormat("{\"key\":\"%s\",\"chat\":\"\",\"caption\":\"cleanup\",\"img\":\"\"}",
                              JsonEscape(webKey));
   char body[];   // WebRequest wajib char[] (uchar[] -> error 4006)
   int len = StringToCharArray(json, body, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(body, len - 1);
   string hdrs = "Content-Type: application/json";
   char result[];
   string resultHdrs;
   ResetLastError();
   int rc = WebRequest("POST", webUrl, hdrs, webTimeout, body, result, resultHdrs);
   PrintFormat("[ChartShotSender] Cleanup ping: rc=%d %s",
               rc, CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
}
//+------------------------------------------------------------------+