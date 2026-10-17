//+------------------------------------------------------------------+
//|                                             ChartShotSender.mq5  |
//|  Screenshot chart tiap N menit, simpan ke MQL5\Files\, lalu      |
//|  kirim ke Telegram via endpoint PHP di hosting (WebRequest).     |
//|                                                                  |
//|  Prasyarat:                                                      |
//|   - MT5: Tools > Options > Expert Advisors > Allow WebRequest    |
//|     tambahkan domain hosting kamu (mis. https://vapekongstore.com)|
//|   - Upload tg_shot/send.php ke hosting, set $SECRET & token bot  |
//+------------------------------------------------------------------+
#property copyright "Ndes"
#property version   "1.03"
#property description "Screenshot chart -> Telegram tiap N menit via endpoint PHP."

input int    everyMinutes = 15;     // Interval screenshot (menit)
input string shotFilename = "";     // Kosong = auto "chart_<SYMBOL>_<TF>.png" (unik per pair)
input int    shotWidth    = 1280;   // Lebar gambar px
input int    shotHeight   = 720;    // Tinggi gambar px
input bool   shotOnInit   = true;   // Screenshot langsung saat dipasang
input bool   showInfo     = true;   // Label info simbol & waktu di gambar
input bool   ignoreMarketClose = false; // true = tetap kirim SC walau broker bilang pasar tutup (crypto yg tak punya info sesi)
input bool   webSend      = true;   // Kirim via WebRequest
input string webUrl       = "https://vapekongstore.com/tg_shot/send.php";
input string webKey       = "KGSd2825161d5eacbae1ef6beb8"; // Secret send.php
input string webChat      = "-1001583828319"; // Group default: kirim lgsg ke group tanpa isi parameter
input int    webTimeout   = 10000;  // ms

const string c_label = "_ChartShotSender_info";
int g_lastShot = 0;
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
   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
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
   string json = StringFormat("{\"key\":\"%s\",\"chat\":\"%s\",\"sym\":\"%s\",\"caption\":\"%s\",\"img\":\"%s\"}",
                              JsonEscape(webKey), JsonEscape(webChat), JsonEscape(_Symbol),
                              JsonEscape(caption), b64);

   uchar body[];
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

void TakeShot()
{
   if(showInfo)
      UpdateInfoLabel();

   string fn = (StringLen(shotFilename) > 0 ? shotFilename : ShotAutoName());
   // refresh chart dulu biar gambar terbaru
   ChartRedraw(0);
   bool ok = ChartScreenShot(0, fn, shotWidth, shotHeight, ALIGN_RIGHT);
   if(!ok)
   {
      PrintFormat("[ChartShotSender] Gagal screenshot (%d). Lokasi: MQL5\\Files\\%s",
                  GetLastError(), fn);
      return;
   }
   PrintFormat("[ChartShotSender] Screenshot OK -> MQL5\\Files\\%s", fn);
   if(webSend)
   {
      MqlDateTime cst; TimeToStruct(TimeCurrent(), cst);
      string caption = StringFormat("%s %s | %s GMT | SVR %02d:%02d", _Symbol, TfName(),
                                    WorldTimeStr(), cst.hour, cst.min);
      SendPng(fn, caption);
   }
}

//+------------------------------------------------------------------+
//| Event handler                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(60);
   g_lastShot = 0;
   g_lastCleanup = 0;
   g_lastBoundary = (int)(TimeCurrent() / (everyMinutes * 60)) * (everyMinutes * 60);
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

   if(shotOnInit)
      TakeShot();
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
   datetime now = TimeCurrent();
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
   // Kirim SELARAS JAM: boundary = kelipatan 15 menit dari jam server (:00, :15, :30, :45).
   // pindah boundary terakhir, baru shoot — mencegah dobel di tick yang sama.
   int step = everyMinutes * 60;
   int boundary = (int)(now / step) * step;
   if(boundary != g_lastBoundary && now >= boundary)
   {
      TakeShot();
      g_lastBoundary = boundary;
      g_lastShot = (int)now;
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
   TimeToStruct(TimeCurrent(), t);
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
   TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 6 || t.day_of_week == 0);
}

//--- POST JSON kecil ke endpoint (dipakai sbg trigger cleanup saat libur)
void SendCleanupPing()
{
   if(!webSend) return;
   string json = StringFormat("{\"key\":\"%s\",\"chat\":\"\",\"caption\":\"cleanup\",\"img\":\"\"}",
                              JsonEscape(webKey));
   uchar body[];
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