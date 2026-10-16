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
#property version   "1.01"
#property description "Screenshot chart -> Telegram tiap N menit via endpoint PHP."

input int    everyMinutes = 15;     // Interval screenshot (menit)
input string shotFilename = "chart_shot.png"; // Nama file di MQL5\Files\
input int    shotWidth    = 1280;   // Lebar gambar px
input int    shotHeight   = 720;    // Tinggi gambar px
input bool   shotOnInit   = true;   // Screenshot langsung saat dipasang
input bool   showInfo     = true;   // Label info simbol & waktu di gambar
input bool   webSend      = true;   // Kirim via WebRequest
input string webUrl       = "https://vapekongstore.com/tg_shot/send.php";
input string webKey       = "KGSd2825161d5eacbae1ef6beb8"; // Secret send.php
input string webChat      = "";     // Kosong = channel bawaan di send.php
input int    webTimeout   = 10000;  // ms

const string c_label = "_ChartShotSender_info";
int g_lastShot = 0;
int g_lastCleanup = 0;

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
   ObjectSetString(0, c_label, OBJPROP_TEXT,
      StringFormat("%s %s | %s", _Symbol, TfName(),
                   TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)));
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
   string json = StringFormat("{\"key\":\"%s\",\"chat\":\"%s\",\"caption\":\"%s\",\"img\":\"%s\"}",
                              JsonEscape(webKey), JsonEscape(webChat),
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
      PrintFormat("[ChartShotSender] WebRequest GAGAL (%d). Cek Allow WebRequest & domain. %s",
                  e, (e == 4014 ? "(tidak aktif di Strategy Tester)" : ""));
      return false;
   }
   PrintFormat("[ChartShotSender] Terkirim: %d/%d bytes, server: %s",
               ArraySize(img), (int)sz, CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
   return true;
}

void TakeShot()
{
   if(showInfo)
      UpdateInfoLabel();

   string fn = (StringLen(shotFilename) > 0 ? shotFilename : "chart_shot.png");
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
      string caption = StringFormat("%s %s | %s", _Symbol, TfName(),
                                    TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
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
   if(IsWeekend())
   {
      // Market tutup: kirim ping trigger biar endpoint bersihkan foto lama (sekali per interval)
      if((int)now - g_lastCleanup >= everyMinutes * 60)
      {
         SendCleanupPing();
         g_lastCleanup = (int)now;
      }
      g_lastShot = (int)now; // jangan screenshot selama libur
      return;
   }
   if((int)now - g_lastShot >= everyMinutes * 60)
   {
      TakeShot();
      g_lastShot = (int)now;
   }
}

void OnTick() {}

//--- true saat Sabtu/Minggu (waktu server broker) — market forex tutup
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