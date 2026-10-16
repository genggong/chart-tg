//+------------------------------------------------------------------+
//| OptimusPanel.mq5 - Aurora/COPTAH-style multi-timeframe table       |
//|                                                                  |
//| Recreates the reference panel:                                   |
//|  - Candle Flow rows for EVERY period from 15-M up to YEARLY:     |
//|    OHLC now/before, JIKA, OP-PV, TREND, PIVOTING, TUGAS, MOVE,   |
//|    AREA, INDEX%, RANGE%, BREAK H/L, BUSUR, TARGET, TRG UP/DN,    |
//|    ATS, SAR ATAS/BAWAH, POLA, HSH                                |
//|  - RPS matrix for EVERY period (S5..S1 PIV R1..R5)               |
//|  - Moment flags: equivalent RPS levels between neighbouring      |
//|    periods (H4-ASIA, D1-ASIA, W1-H4, MN-W1)                     |
//|                                                                  |
//| Engine logic lives in OptimusCore.mqh.                           |
//+------------------------------------------------------------------+
#property copyright   "Optimus"
#property version     "1.12"
#property indicator_separate_window   // panel di sub-window bawah chart (tidak nutupin chart)
#property indicator_plots 1
#property indicator_buffers 3
#property indicator_color1 clrNONE    // dummy plot transparan (hanya utk memaksa sub-window)

//=== INLINE dari OptimusCore.mqh (standalone, tanpa include) ===
//+------------------------------------------------------------------+
//| OptimusCore.mqh - Shared engine for the Optimus indicator suite  |
//| Built from the NexTrum/Aurora manual (Tabel Multi Timeframe) and |
//| COPTAH four-law fundamentals.                                    |
//|                                                                  |
//| Blocks:                                                          |
//|   1. Pivot RPS levels (5 resistances, pivot, 5 supports)         |
//|   2. Candle Flow (direction, open-pivot, trend, move, area,      |
//|      index%, range%)                                             |
//|   3. Aggregated calendar periods (ASIA, EURO, MKT, WK, MN, QRTR, |
//|      SMTR, YEAR) built from raw D1 bars                          |
//|   4. Multi-timeframe shared state containers                     |
//+------------------------------------------------------------------+

//--- Aggregated period identifiers ----------------------------------
enum OptPeriod
  {
   OPT_15M  = 0,   // M15
   OPT_30M  = 1,   // M30
   OPT_H1   = 2,   // H1
   OPT_H4   = 3,   // H4
   OPT_H8   = 4,   // 8-HOUR (blok 8 jam; dulu ASIA/EURO/MARKET digabung)
   OPT_D1   = 5,   // Daily
   OPT_W1   = 6,   // Weekly
   OPT_MN1  = 7,   // Monthly
   OPT_QRTR = 8,   // Quarter (aggregated)
   OPT_SMTR = 9,   // Semester (aggregated)
   OPT_YEAR = 10,  // Yearly (aggregated)
   OPT_COUNT = 11
  };

//--- RPS level set ---------------------------------------------------
struct RPSLevels
  {
   double res1, res2, res3, res4, res5;
   double pivot;
   double sup1, sup2, sup3, sup4, sup5;
   bool   valid;
   //--- classic 5/1/5 pivot formulas from the Aurora manual
   void   ComputeFrom(double hB, double lB, double cB)
     {
      valid = false;
      pivot = (hB + lB + cB) / 3.0;
      res1  = 2.0 * pivot - lB;
      sup1  = 2.0 * pivot - hB;
      res2  = pivot + (hB - lB);
      sup2  = pivot - (hB - lB);
      res3  = hB + 2.0 * (pivot - lB);
      sup3  = lB - 2.0 * (hB - pivot);
      res4  = hB + 3.0 * (pivot - lB);
      sup4  = lB - 3.0 * (hB - pivot);
      res5  = hB + 4.0 * (pivot - lB);
      sup5  = lB - 4.0 * (hB - pivot);
      if(hB > 0.0 && lB > 0.0 && (hB - lB) > 0.0)
         valid = true;
     }
   //--- nearest level above/at price (used by BUSUR/TARGET columns)
   double NearestAbove(double price)
     {
      double lvl[11];
      lvl[0] = res1; lvl[1] = res2; lvl[2] = res3; lvl[3] = res4; lvl[4] = res5;
      lvl[5] = pivot;
      lvl[6] = sup1; lvl[7] = sup2; lvl[8] = sup3; lvl[9] = sup4; lvl[10] = sup5;
      double best = EMPTY_VALUE;
      for(int i = 0; i < 11; i++)
         if(lvl[i] > price && (best == EMPTY_VALUE || lvl[i] < best))
            best = lvl[i];
      return best;
     }
   double NearestBelow(double price)
     {
      double lvl[11];
      lvl[0] = res1; lvl[1] = res2; lvl[2] = res3; lvl[3] = res4; lvl[4] = res5;
      lvl[5] = pivot;
      lvl[6] = sup1; lvl[7] = sup2; lvl[8] = sup3; lvl[9] = sup4; lvl[10] = sup5;
      double best = EMPTY_VALUE;
      for(int i = 0; i < 11; i++)
         if(lvl[i] < price && (best == EMPTY_VALUE || lvl[i] > best))
            best = lvl[i];
      return best;
     }
  };

//--- OHLC state -------------------------------------------------------
struct CandleBar
  {
   double open, high, low, close;
   datetime time;
   bool valid;
  };

//--- Global shared state (one slot per period) --------------------------
RPSLevels g_rps[OPT_COUNT];
CandleBar g_barNow[OPT_COUNT];
CandleBar g_barPrev[OPT_COUNT];
double    g_index[OPT_COUNT];
double    g_rangePct[OPT_COUNT];
int       g_trend[OPT_COUNT];
bool      g_valid[OPT_COUNT];

//--- Reset state --------------------------------------------------------
void OptimusCoreInit()
  {
   for(int i = 0; i < OPT_COUNT; i++)
     {
      g_valid[i]    = false;
      g_index[i]    = 50.0;
      g_rangePct[i] = 100.0;
      g_trend[i]    = 0;
     }
  }

//--- Read ONE raw bar (shift counted from history) ----------------------
bool ReadRawBar(string sym, ENUM_TIMEFRAMES tf, int shift, CandleBar &b)
  {
   b.valid = false;
   b.time  = iTime(sym, tf, shift);
   b.open  = iOpen(sym, tf, shift);
   b.high  = iHigh(sym, tf, shift);
   b.low   = iLow(sym, tf, shift);
   b.close = iClose(sym, tf, shift);
   if(b.time > 0 && b.high > 0.0 && b.low > 0.0)
      b.valid = true;
   return b.valid;
  }

//--- RPS from any bar -----------------------------------------------------
void ComputeRpsFromBar(const CandleBar &b, RPSLevels &r)
  {
   r.ComputeFrom(b.high, b.low, b.close);
  }

//--- Index% : 0..100 momentum from close position in running bar ----------
double ComputeIndex(const CandleBar &now)
  {
   if(!now.valid || now.high <= now.low) return 50.0;
   double pos = (now.close - now.low) / (now.high - now.low);
   return 100.0 * MathMax(0.0, MathMin(1.0, pos));
  }

//--- Range% : current range vs average of past N bars ---------------------
double ComputeRangePct(string sym, ENUM_TIMEFRAMES tf, int lookback)
  {
   double sum = 0.0;
   int n = 0;
   for(int s = 1; s <= lookback; s++)
     {
      double h = iHigh(sym, tf, s);
      double l = iLow(sym, tf, s);
      if(h > 0.0 && l > 0.0 && h >= l) { sum += (h - l); n++; }
     }
   double avg = (n > 0) ? sum / n : 0.0;
   double h0 = iHigh(sym, tf, 0);
   double l0 = iLow(sym, tf, 0);
   if(avg <= 0.0 || h0 <= 0.0 || l0 <= 0.0) return 100.0;
   return 100.0 * (h0 - l0) / avg;
  }

//--- Trend pattern ---------------------------------------------------------
//   +-2 engulf, +-1 normal, 0 inside/flat, +-3 anomaly
int TrendOfBars(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid || !prev.valid) return 0;
   bool nowUp  = (now.close > now.open);
   bool prevUp = (prev.close > prev.open);

   // Engulfing (running candle body engulfs prev body beyond its high/low)
   if((nowUp && !prevUp && now.close > prev.high) ||
      (!nowUp && prevUp && now.close < prev.low))
      return (nowUp ? 1 : -1) * 2;
   if(nowUp && now.high > prev.high && now.low >= prev.low)
      return 1;
   if(!nowUp && now.low < prev.low && now.high <= prev.high)
      return -1;
   if(now.high <= prev.high && now.low >= prev.low)
      return 0;
   if(nowUp && now.high > prev.high && now.low < prev.low)
      return 3;
   if(!nowUp && now.high > prev.high && now.low < prev.low)
      return -3;
   return 0;
  }
//=== AKHIR INLINE ===

//--- Panel layout -----------------------------------------------------
input group  "=== Panel Layout ==="
input bool   showCandleFlow   = true;   // Show Candle Flow block
input bool   showRpsMatrix    = true;   // Show RPS matrix block (default ON: tabel level RPS)
input bool   showMomentRow    = false;  // Baris MOMENT (ekuivalensi RPS antar TF)
input bool   showMarketInfo   = true;   // Blok info pasar: sesi 8 jam, pair, P/L harian
input bool   showVanteraSignal= true;   // Blok analisa entry: ARAH BUY/SELL + harga pending order
input bool   momentAlert       = true;  // Notifikasi/alert saat MOMENT berubah (per TF)
input double vanteraBufferPips= 2.0;    // Buffer SL di luar level RPS/OHLC (pips)
input int    sessOffsetHours  = 0;     // Koreksi offset sesi (0 = auto ikut jam server broker)
input int    panelCorner      = 0;      // 0=LeftUpper 1=RightUpper 2=LeftLower 3=RightLower
input int    panelX           = 5;      // X offset
input int    panelY           = 4;      // Y offset
input int    fontSize         = 9;      // Font size (lebih besar agar terbaca)
input int    rowH             = 13;     // Row height (rapat: 11 baris muat di sub-window)
input int    colW             = 88;     // Lebar kolom (jarak horizontal lega, anti-tabrakan)
input color  clrHeader        = clrWhite;      // header: putih terang
input color  clrUp            = clrLime;       // up: hijau terang (nyaman di bg hitam)
input color  clrDown          = clrTomato;     // down: merah-oranye terang (nyaman)
input color  clrNeutral       = clrLightGray;  // netral: abu terang
input color  clrMoment        = clrYellow;     // moment: kuning (info)

//--- Palet khas per jenis kolom (>7 warna: bedakan tiap kolom/angka di bg hitam)
#define C_AQUA   clrAqua      // BUSUR / level bawah
#define C_ORG    clrOrange    // TARGET / level atas
#define C_CYAN   clrCyan      // TRG UP
#define C_MAG    clrMagenta   // TRG DN
#define C_GOLD   clrGold      // TUGAS
#define C_PINK   clrPink      // RVSLMT
#define C_RED    clrRed       // RPS R1-R5
#define C_GRN    clrGreen     // RPS S1-S5

//--- Column toggles ----------------------------------------------------
input group  "=== Candle Flow Columns ==="
input bool   colOHLC      = true;   // OPEN/HIGH/LOW now & before
input bool   colJika      = true;   // JIKA (open now vs open before)
input bool   colOpPv      = true;   // OP-PV (open vs candle pivot)
input bool   colTrend     = true;   // TREND pattern
input bool   colPivoting  = false;  // PIVOTING (open vs RPS pivot)
input bool   colTugas     = true;   // TUGAS (busur/target role)
input bool   colMove       = true;   // MOVE
   input bool   colPerahu     = true;   // PERAHU (hukum perahu: struktur HI/LO berjenjang)
   input bool   colArea       = false;  // AREA
input bool   colIndex     = false;  // INDEX%
input bool   colRange     = false;  // RANGE%
input bool   colBreak     = false;  // BREAK H / BREAK L
input bool   colBusur     = true;   // BUSUR level
input bool   colTarget    = true;   // TARGET level
input bool   colRvs       = true;   // RVSLMT (reversal moment)
input bool   colTrg       = true;   // TRG UP / TRG DN
input bool   colAts       = false;  // ATS (ATR stop)
input bool   colMoment    = true;   // MOMENT (keterangan detail)
input bool   colSar       = false;  // SAR ATAS / SAR BAWAH
input bool   colPola      = false;  // POLA (candle pattern)
input bool   colHsh       = false;  // HSH (home sweet home)

//--- Calculation parameters --------------------------------------------
input group  "=== Calculation ==="
input int    atrPeriod        = 14;    // ATR period (ATS & TRG)
input double atrMult          = 1.0;   // ATR multiplier for ATS
input double pivotTolerancePct= 0.05;  // % of range for "equivalent" (open vs pivot)
input bool   useParabolic     = true;  // SAR columns from iSAR
input double psarStep         = 0.02;
input double psarMax          = 0.20;
input int    rangeLookback    = 14;    // periods for RANGE% average
input double hshZonePips      = 20.0;  // HSH zone width (pips) around open ref
input double momentEqPips     = 2.0;   // RPS equivalence tolerance (pips)
input double trgReachFactor   = 1.5;   // Jangkauan tembus TRG UP/DN (x range TF)
input bool   enableEaSig      = true;  // Ekspor sinyal konsensus ke EA (via GlobalVariable)

//--- Globals ------------------------------------------------------------
#define UP_ARROW ShortToString(0x2191)   // ↑
#define DN_ARROW ShortToString(0x2193)   // ↓
#define RT_ARROW ShortToString(0x2192)   // → (alur TF kecil → besar)
string g_pfx  = "OP_";
int    g_colN = 0;
string g_colT[40];
int    g_colW[40];
int    g_sarHandle[11];   // native-TF SAR handles (aggregated = INVALID_HANDLE)
int    g_atrHandle[11];   // native-TF ATR handles
double g_dummy[];         // buffer dummy utk memaksa sub-window (selalu EMPTY)
double g_panelSig[];      // [1] sinyal konsensus panel: +1 bullish / -1 bearish / 0 netral (utk EA)
double g_momentSig[];     // [2] sinyal MOMENT panel: +1 (↑) / -1 (↓) / 0 (utk EA)
int    g_win    = 0;      // index sub-window indicator (bukan chart utama)

//--- Period table (order: M15..YEARLY, sesi digabung jadi 8-HOUR) ----
OptPeriod g_periods[11];

void PeriodOrder()
  {
   g_periods[ 0] = OPT_15M;  g_periods[ 1] = OPT_30M;  g_periods[ 2] = OPT_H1;
   g_periods[ 3] = OPT_H4;   g_periods[ 4] = OPT_H8;   g_periods[ 5] = OPT_D1;
   g_periods[ 6] = OPT_W1;   g_periods[ 7] = OPT_MN1;  g_periods[ 8] = OPT_QRTR;
   g_periods[ 9] = OPT_SMTR; g_periods[10] = OPT_YEAR;
  }

int PeriodIndex(OptPeriod p)
  {
   for(int i = 0; i < 11; i++)
      if(g_periods[i] == p) return i;
   return -1;
  }

string PeriodName(OptPeriod p)
  {
   switch(p)
     {
      case OPT_15M:  return "15-M";
            case OPT_30M:  return "30-M";
            case OPT_H1:   return "1-HOUR";
            case OPT_H4:   return "4-HOUR";
            case OPT_H8:   return "8-HOUR";
            case OPT_D1:   return "DAILY";
            case OPT_W1:   return "WEEKLY";
            case OPT_MN1:  return "MONTH";
            case OPT_QRTR: return "QRTR";
            case OPT_SMTR: return "SMTR";
            case OPT_YEAR: return "YEARLY";
          }
        return "?";
        }

//--- Native TF mapping for a period --------------------------------------
ENUM_TIMEFRAMES BarTf(OptPeriod p)
  {
   switch(p)
     {
      case OPT_15M:  return PERIOD_M15;
      case OPT_30M:  return PERIOD_M30;
      case OPT_H1:   return PERIOD_H1;
      case OPT_H4:   return PERIOD_H4;
      case OPT_H8:   return PERIOD_H8;
      case OPT_D1:   return PERIOD_D1;
      case OPT_W1:   return PERIOD_W1;
      case OPT_MN1:  return PERIOD_MN1;
      default:       return PERIOD_D1;
     }
  }

//--- Calendar helpers ----------------------------------------------------
datetime DayStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   d.hour = 0; d.min = 0; d.sec = 0;
   return StructToTime(d);
  }
datetime WeekStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(DayStart(t), d);
   int dow = d.day_of_week; if(dow == 0) dow = 7;
   d.day -= (dow - 1);
   return StructToTime(d);
  }
datetime MonthStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   d.day = 1; d.hour = 0; d.min = 0; d.sec = 0;
   return StructToTime(d);
  }
datetime QuarterStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(MonthStart(t), d);
   int q = (d.mon - 1) / 3;
   d.mon = q * 3 + 1; d.day = 1;
   return StructToTime(d);
  }
datetime SemesterStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(MonthStart(t), d);
   d.mon = (d.mon <= 6) ? 1 : 7; d.day = 1;
   return StructToTime(d);
  }
datetime YearStart(datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   d.mon = 1; d.day = 1; d.hour = 0; d.min = 0; d.sec = 0;
   return StructToTime(d);
  }

//--- Aggregate a calendar window from D1 bars -----------------------------
//   closed-only (shift>=1) for the PREVIOUS period; includes running D1
//   when live=true for the CURRENT period.
bool AggregateWindow(string sym, datetime start, datetime end, bool live, CandleBar &out)
  {
   out.valid = false;
   int total = Bars(sym, PERIOD_D1);
   if(total < 2) return false;

   bool first = true;
   for(int s = 1; s < total; s++)
     {
      datetime t = iTime(sym, PERIOD_D1, s);
      if(t < start) break;
      if(t >= start && t < end)
        {
         if(first)
           {
            out.high  = iHigh (sym, PERIOD_D1, s);
            out.low   = iLow  (sym, PERIOD_D1, s);
            out.close = iClose(sym, PERIOD_D1, s);
            first = false;
           }
         else
           {
            out.high  = MathMax(out.high, iHigh (sym, PERIOD_D1, s));
            out.low   = MathMin(out.low,  iLow  (sym, PERIOD_D1, s));
            out.close = iClose(sym, PERIOD_D1, s);
           }
         // OPEN PERIODE = open bar PERTAMA (paling TUA) dalam window.
         // Loop berjalan dari bar terbaru ke terlama -> overwrite terus,
         // sehingga di akhir iterasi out.open = open bar terlama (benar).
         out.open  = iOpen(sym, PERIOD_D1, s);
         out.time = t;
        }
     }
   if(live)
     {
      datetime t0 = iTime(sym, PERIOD_D1, 0);
      if(t0 >= start && t0 < end)
        {
         if(first)
           {
            out.open  = iOpen (sym, PERIOD_D1, 0);
            out.high  = iHigh (sym, PERIOD_D1, 0);
            out.low   = iLow  (sym, PERIOD_D1, 0);
            out.close = iClose(sym, PERIOD_D1, 0);
           }
         else
           {
            // JANGAN timpa open periode dengan bar hari ini (running/unclosed)
            out.high  = MathMax(out.high, iHigh(sym, PERIOD_D1, 0));
            out.low   = MathMin(out.low,  iLow (sym, PERIOD_D1, 0));
            out.close = iClose(sym, PERIOD_D1, 0);
           }
         out.time  = t0;
         first     = false;
        }
     }
   out.valid = !first;
   return out.valid;
  }

//--- Resolve now/prev bars for any period ---------------------------------
bool PeriodBars(OptPeriod p, CandleBar &now, CandleBar &prev)
  {
   string sym = _Symbol;
   datetime cur = TimeCurrent();
   datetime startN = 0, endN = 0, startP = 0, endP = 0;
   bool useD1 = true;

   switch(p)
     {
      case OPT_15M:
      case OPT_30M:
      case OPT_H1:
      case OPT_H4:
      case OPT_H8:
      case OPT_D1:
         useD1 = false;
         break;
      case OPT_W1:
         startP = WeekStart(cur - 86400 * 7); endP = WeekStart(cur);
         startN = WeekStart(cur);              endN = cur + 1;
         break;
      case OPT_MN1:
         startP = MonthStart(cur - 86400 * 32); endP = MonthStart(cur);
         startN = MonthStart(cur);               endN = cur + 1;
         break;
      case OPT_QRTR:
         startP = QuarterStart(cur - 86400 * 95); endP = QuarterStart(cur);
         startN = QuarterStart(cur);               endN = cur + 1;
         break;
      case OPT_SMTR:
         startP = SemesterStart(cur - 86400 * 190); endP = SemesterStart(cur);
         startN = SemesterStart(cur);               endN = cur + 1;
         break;
      case OPT_YEAR:
         startP = YearStart(cur - 86400 * 370); endP = YearStart(cur);
         startN = YearStart(cur);               endN = cur + 1;
         break;
     }

   bool okN, okP;
   if(useD1)
     {
      okN = AggregateWindow(sym, startN, endN, true,  now);
      okP = AggregateWindow(sym, startP, endP, false, prev);
      return okN && okP;
     }

   ENUM_TIMEFRAMES tf = BarTf(p);
   okN = ReadRawBar(sym, tf, 0, now);
   okP = ReadRawBar(sym, tf, 1, prev);
   return okN && okP;
  }

//--- iSAR value (native TF only; aggregated periods return EMPTY) ----------
double SarValue(OptPeriod p, int shift)
  {
   int h = g_sarHandle[(int)p];
   if(h == INVALID_HANDLE) return EMPTY_VALUE;
   double buf[1];
   if(CopyBuffer(h, 0, shift, 1, buf) != 1) return EMPTY_VALUE;
   return buf[0];
  }

//--- ATR (native TF; aggregated periods measure from D1) --------------------
double AtrValue(OptPeriod p)
  {
   int h = g_atrHandle[(int)p];
   if(h == INVALID_HANDLE) return EMPTY_VALUE;
   double buf[1];
   if(CopyBuffer(h, 0, 1, 1, buf) != 1) return EMPTY_VALUE;
   return buf[0];
  }

//--- Formatting helpers ----------------------------------------------------
string FmtPrice(double v)
  {
   if(v <= 0.0 || v == EMPTY_VALUE) return "--";
   return DoubleToString(v, MathMin(_Digits, 2));   // ringkas: maks 2 desimal (anti melebar)
  }
string FmtPct(double v)
  {
   if(v == EMPTY_VALUE) return "--";
   return DoubleToString(v, 1) + "%";
  }
string FmtIdx(double v)
  {
   if(v == EMPTY_VALUE) return "--";
   return DoubleToString(v, 1);
  }

//--- Compute all period states ---------------------------------------------
void ComputeAll()
  {
   OptimusCoreInit();
   for(int i = 0; i < OPT_COUNT; i++)
     {
      OptPeriod p = g_periods[i];
      g_valid[i] = PeriodBars(p, g_barNow[i], g_barPrev[i]);
      if(!g_valid[i]) continue;

      ComputeRpsFromBar(g_barPrev[i], g_rps[i]);
      g_trend[i]    = TrendOfBars(g_barNow[i], g_barPrev[i]);
      g_index[i]    = ComputeIndex(g_barNow[i]);
      g_rangePct[i] = ComputeRangePct(_Symbol, BarTf(p), rangeLookback);
     }
  }

//--- Label helpers -----------------------------------------------------------
string g_lastMoment[OPT_COUNT];        // notifikasi MOMENT: perubahan per TF

void CheckMomentAlert()
  {
   if(!momentAlert) return;
   for(int r = 0; r < OPT_COUNT; r++)
     {
      OptPeriod p = g_periods[r];
      string cur = MomentCell(p);
      if(cur == g_lastMoment[r]) continue;
      if(g_lastMoment[r] != "" && StringFind(cur, "--") < 0)
        {
         string msg = StringFormat("%s %s: MOMENT = %s", _Symbol, PeriodName(p), cur);
         Alert(msg);
         Print("[MOMENT] ", msg);
        }
      g_lastMoment[r] = cur;
     }
  }
void SetLabel(string name, string text, int x, int y, color clr, int fs, string font = "Consolas Bold")
  {
   string full = g_pfx + name;
   if(ObjectFind(0, full) < 0)
     {
      // subwindow ditentukan di sini: g_win = window indicator (bukan OBJPROP_SUBWINDOW)
      ObjectCreate(0, full, OBJ_LABEL, g_win, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_CORNER, panelCorner);
      ObjectSetInteger(0, full, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, full, OBJPROP_FONTSIZE, fs);
      ObjectSetString (0, full, OBJPROP_FONT, font);   // font tebal (visibilitas di bg hitam)
     }
   else if(ObjectGetString(0, full, OBJPROP_FONT) != font)
      ObjectSetString(0, full, OBJPROP_FONT, font);    // update font saat ganti (mis. panah)
   ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
   ObjectSetString (0, full, OBJPROP_TEXT, text);
  }
void DelLabel(string prefix)
  {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      string n = ObjectName(0, i);
      if(StringFind(n, prefix) == 0)
         ObjectDelete(0, n);
     }
  }

color UseUpDownCol(double nowV, double prevV)
  {
   if(nowV > prevV) return clrUp;
   if(nowV < prevV) return clrDown;
   return clrNeutral;
  }

//--- Trend label -----------------------------------------------------------------
string TrendLabel(int t)
  {
   switch(t)
     {
      case  2: return "ENG UP";
      case -2: return "ENG DN";
      case  1: return "NRM UP";
      case -1: return "NRM DN";
      case  3: return "ANM UP";
      case -3: return "ANM DN";
      default: return "SIDEWAY";    // inside bar: bar di dalam range bar sebelumnya
     }
  }
color TrendColor(int t)
  {
   if(t > 0) return clrUp;
   if(t < 0) return clrDown;
   return clrNeutral;
  }

//--- OP-PV ------------------------------------------------------------------------
string OpPvLabel(int st)
  {
   if(st == 1)  return "DI ATAS";   // open di atas pivot
   if(st == -1) return "DI BAWAH";  // open di bawah pivot
   return "SAMA";                    // open dekat/tepat di pivot
  }
int OpPvState(const CandleBar &b, double pivot)
  {
   if(!b.valid || b.high <= b.low) return 0;
   double tol = (pivotTolerancePct / 100.0) * (b.high - b.low);
   if(b.open > pivot + tol) return 1;
   if(b.open < pivot - tol) return -1;
   return 0;
  }

//--- JIKA --------------------------------------------------------------------------
string JikaLabel(int d)
  {
   if(d > 0) return "UP";
   if(d < 0) return "DOWN";
   return "FLAT";
  }
int JikaState(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid || !prev.valid) return 0;
   double tol = _Point * 5;
   if(now.open > prev.open + tol) return 1;
   if(now.open < prev.open - tol) return -1;
   return 0;
  }

//--- Warna header kolom: pelangi dari kiri ke kanan (TF -> MOMENT) ------------
//   7 warna berurutan, diulang bila kolom > 7 (mudah dibedakan tiap kolom)
color HeaderRainbow(int c, int total)
  {
   if(total <= 0) return clrHeader;
   color pal[7] = {clrLightSkyBlue, clrCyan, clrLime, clrYellow, clrOrange, clrMagenta, clrPink};
   return pal[c % 7];
  }

//--- RPS touched: level SUDAH disentuh harga (bar sekarang) --------------------
//   R1..R4 & PIV: tersentuh bila high bar >= level
//   S1..S5      : tersentuh bila low  bar <= level
bool RpsTouched(OptPeriod p, int lvlIdx, double level)
  {
   if(level <= 0.0 || level == EMPTY_VALUE) return false;
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return false;
   double h = g_barNow[ia].high;
   double l = g_barNow[ia].low;
   if(h <= 0.0 || l <= 0.0) return false;
   if(lvlIdx >= 5) return (h >= level);   // R4..PIV (idx 9..5)
   return (l <= level);                    // S1..S5  (idx 4..0)
  }

//--- Warna level RPS yang SUDAH TERSENTUH harga --------------------------------
//   R1-R5 (oranye) tersentuh -> MERAH ; S1-S5 (biru) tersentuh -> PUTIH ;
//   PIV (putih) tersentuh -> UNGU.
color TouchColor(int lvlIdx)
  {
   if(lvlIdx == 5) return clrMagenta;   // PIV  tersentuh -> ungu
   if(lvlIdx < 5)  return clrWhite;     // S1..S5 tersentuh -> putih
   return clrRed;                        // R1..R5 tersentuh -> merah
  }

//--- Warna identitas per TF (label TF + header RPS, tidak berubah) ------------
color TfColor(OptPeriod p)
  {
   switch(p)
     {
      case OPT_15M:  return clrSkyBlue;
      case OPT_30M:  return clrCyan;
      case OPT_H1:   return clrTurquoise;
      case OPT_H4:   return clrLime;
      case OPT_H8:   return clrYellow;
      case OPT_D1:   return clrOrange;
      case OPT_W1:   return clrMagenta;
      case OPT_MN1:  return clrViolet;
      case OPT_QRTR: return clrDeepPink;
      case OPT_SMTR: return clrGold;
      case OPT_YEAR: return clrSilver;
      default:       return clrWhite;
     }
  }

//--- MOVE ----------------------------------------------------------------------------
string MoveLabel(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid) return "--";
   double body = MathAbs(now.close - now.open);
   double rng  = now.high - now.low;
   if(rng <= 0.0 || body < 0.15 * rng)
     {
      // SIDEWAY: arah dari pola pergerakan (bandingkan dgn bar sebelumnya)
      if(prev.valid)
         return (now.close >= prev.close) ? "SDW UP" : "SDW DN";
      return "SDW";
     }
   return (now.close > now.open) ? "UP" : "DN";
  }

//--- Panah arah TF (di samping RPS tiap TF): prediksi ke mana harga akan bergerak ---
//   Konsensus dari kolom tabel di atas:
//     JIKA (open now vs open before) + TREND + MOVE + MOMENT + TUGAS.
//   ↑ naik, ↓ turun, → sideways/netral.
string TfArrow(OptPeriod p)
  {
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return RT_ARROW;
   CandleBar nowC = g_barNow[ia], prvC = g_barPrev[ia];
   if(!nowC.valid || !prvC.valid) return RT_ARROW;

   int j  = JikaState(nowC, prvC);
   int t  = g_trend[ia];
   string mv = MoveLabel(nowC, prvC);
   string m  = MomentCell(p);

   int up = 0, dn = 0;
   if(j > 0) up++; else if(j < 0) dn++;
   if(t > 0) up++; else if(t < 0) dn++;
   if(mv == "UP") up++; else if(mv == "DN") dn++;
   if(StringFind(m, "TARGET UP") >= 0) up++;
   else if(StringFind(m, "TARGET DN") >= 0) dn++;

   if(up > dn) return UP_ARROW;
   if(dn > up) return DN_ARROW;
   return RT_ARROW;
  }

//--- AREA -----------------------------------------------------------------------------
string AreaLabel(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid || !prev.valid) return "--";
   if(now.close > prev.high) return "ATAS";   // close di atas range bar sebelumnya
   if(now.close < prev.low)  return "BAWAH";  // close di bawah range bar sebelumnya
   return "TENGAH";                            // close di dalam range bar sebelumnya
  }

//--- BREAK H/L -------------------------------------------------------------------------
string BreakLabel(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid || !prev.valid) return "--";
   if(now.high > prev.high && now.low < prev.low) return "BRK";
   if(now.high > prev.high) return "BRK H";
   if(now.low  < prev.low)  return "BRK L";
   return "HOLD";
  }

//--- BUSUR / TARGET (COPTAH) -----------------------------------------------------------
// JIKA up : support above LowBefore (nearest) ; JIKA down : resistance below HighBefore
double BusurLevel(const CandleBar &prev, int jika, RPSLevels &rps)
  {
   if(jika >= 0)
      return rps.NearestAbove(prev.low);
   return rps.NearestBelow(prev.high);
  }
double TargetLevel(const CandleBar &prev, int jika, RPSLevels &rps)
  {
   if(jika >= 0)
      return rps.NearestAbove(prev.high);
   return rps.NearestBelow(prev.low);
  }

//--- TUGAS: peran tiap TF dalam membentuk HI/LO sebuah harga ------------------
//   Setiap TF punya tugas masing2 utk MERANGKAI pergerakan:
//     - TF kecil (15M-30M)  = PERTANDA  (mulai arah, cari arah mana yg jalan)
//     - TF menengah (H1-H8) = PENGERJA  (mengerjakan busur/target, lanjutkan)
//     - TF besar (D1+)      = PENENTU   (batas HI/LO, konfirmasi arah global)
//   Arah terbaca dari JIKA + posisi vs pivot; target/batas = level RPS.
string TugasLabel(OptPeriod p, int jika, double price, double pivot)
  {
   if(jika > 0)
     {
      // UP: PERTANDA cari support; PENGERJA/PENENTU kejar HI
      if(p == OPT_15M || p == OPT_30M)
         return (price < pivot) ? "PT BUSUR" : "PT TARGET";
      if(p == OPT_H1 || p == OPT_H4 || p == OPT_H8)
         return (price < pivot) ? "PJ BUSUR" : "PJ TARGET";
      return (price < pivot) ? "PN BUSUR" : "PN TARGET";
     }
   if(jika < 0)
     {
      if(p == OPT_15M || p == OPT_30M)
         return (price < pivot) ? "PT TARGET" : "PT BUSUR";
      if(p == OPT_H1 || p == OPT_H4 || p == OPT_H8)
         return (price < pivot) ? "PJ TARGET" : "PJ BUSUR";
      return (price < pivot) ? "PN TARGET" : "PN BUSUR";
     }
   return "--";
  }

//--- TRG UP / TRG DN --------------------------------------------------------------------
//   TRG UP = level RPS terdekat DI ATAS High-Before (target harga jika lanjut naik)
//   TRG DN = level RPS terdekat DI BAWAH Low-Before  (target harga jika lanjut turun)
//   Konsisten untuk semua arah JIKA (tidak berubah-ubah).
double TrgUp(const CandleBar &prev, int jika, RPSLevels &rps)
  {
   if(!prev.valid) return EMPTY_VALUE;
   return rps.NearestAbove(prev.high);
  }
double TrgDn(const CandleBar &prev, int jika, RPSLevels &rps)
  {
   if(!prev.valid) return EMPTY_VALUE;
   return rps.NearestBelow(prev.low);
  }

//--- Kemampuan TF menembus level target (analisa range pergerakan) -----------
//   Mampu = jarak harga sekarang ke level target masih dalam jangkauan
//           range TF (max(high-low now, high-low before) x trgReachFactor).
//   TF ber-range besar (daily/week/month) mampu tembus jauh; TF kecil tidak.
bool TrgAbleUp(OptPeriod p, double lvl)
  {
   if(lvl <= 0.0 || lvl == EMPTY_VALUE) return false;
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return false;
   double close = g_barNow[ia].close;
   double rng   = MathMax(g_barNow[ia].high - g_barNow[ia].low,
                          g_barPrev[ia].high - g_barPrev[ia].low);
   if(close <= 0.0 || rng <= 0.0) return false;
   return (lvl - close) <= rng * trgReachFactor;
  }
bool TrgAbleDn(OptPeriod p, double lvl)
  {
   if(lvl <= 0.0 || lvl == EMPTY_VALUE) return false;
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return false;
   double close = g_barNow[ia].close;
   double rng   = MathMax(g_barNow[ia].high - g_barNow[ia].low,
                          g_barPrev[ia].high - g_barPrev[ia].low);
   if(close <= 0.0 || rng <= 0.0) return false;
   return (close - lvl) <= rng * trgReachFactor;
  }

//--- ATS -----------------------------------------------------------------------------------
double AtsValue(const CandleBar &now, double atr)
  {
   if(atr == EMPTY_VALUE || atr <= 0.0 || !now.valid) return EMPTY_VALUE;
   double stop = atr * atrMult;
   return (now.close > now.open) ? now.high - stop : now.low + stop;
  }

//--- POLA (candle pattern of last completed bar) -------------------------------------------
string PolaLabel(const CandleBar &prev)
  {
   if(!prev.valid) return "--";
   bool up  = (prev.close > prev.open);
   double body = MathAbs(prev.close - prev.open);
   double rng  = prev.high - prev.low;
   if(rng <= 0.0 || body < 0.15 * rng) return "DOJI";
   double upperWick = prev.high - MathMax(prev.open, prev.close);
   double lowerWick = MathMin(prev.open, prev.close) - prev.low;
   if(upperWick > 0.6 * rng) return "SHOOT";
   if(lowerWick > 0.6 * rng) return "HAMMER";
   return up ? "BULL" : "BEAR";
  }

//--- HSH (HUKUM RUMAH IDAMAN): setelah menciptakan HI/LO, harga pulang ke open --
string HshLabel(const CandleBar &now, double refOpen, double zonePips)
  {
   if(!now.valid) return "--";
   double zone = zonePips * 10.0 * _Point;
   if(MathAbs(now.close - refOpen) <= zone) return "HSH";      // sudah pulang ke rumah
   // Masih dalam perjalanan pulang? (close di antara open ref dan ekstrem harga)
   double extHi = MathMax(now.high, refOpen);
   double extLo = MathMin(now.low,  refOpen);
   if(now.close > extLo + (extHi - extLo) * 0.25 && now.close < extHi - (extHi - extLo) * 0.25)
      return "PULANG";
   return "JAUH";
  }

//--- PERAHU (HUKUM PERAHU): struktur HI/LO berjenjang ---------------------------
//   Haluan = High; buritan = Low. Kalau haluan bergeser, buritan ikut.
//   NAIK     = HH + HL (struktur naik: high & low naik)
//   TURUN    = LH + LL (struktur turun)
//   MELEBAR  = HH + LL (range meluas, volatilitas naik)
//   MERAPAT  = LH + HL (range menyempit, konsolidasi/sideway)
string PerahuLabel(const CandleBar &now, const CandleBar &prev)
  {
   if(!now.valid || !prev.valid) return "--";
   bool hh = (now.high > prev.high);
   bool hl = (now.low  > prev.low);
   bool lh = (now.high < prev.high);
   bool ll = (now.low  < prev.low);
   if(hh && hl) return "NAIK";
   if(lh && ll) return "TURUN";
   if(hh && ll) return "MELEBAR";
   if(lh && hl) return "MERAPAT";
   return "--";
  }

//--- Moment: equivalent RPS levels between two periods --------------------------------------
int MomentEq(OptPeriod a, OptPeriod b, double &refLevel)
  {
   int ia = PeriodIndex(a), ib = PeriodIndex(b);
   if(ia < 0 || ib < 0 || !g_valid[ia] || !g_valid[ib]) return 0;
   double lvlA[11], lvlB[11];
   lvlA[0]=g_rps[ia].res1; lvlA[1]=g_rps[ia].res2; lvlA[2]=g_rps[ia].res3;
   lvlA[3]=g_rps[ia].res4; lvlA[4]=g_rps[ia].res5; lvlA[5]=g_rps[ia].pivot;
   lvlA[6]=g_rps[ia].sup1; lvlA[7]=g_rps[ia].sup2; lvlA[8]=g_rps[ia].sup3;
   lvlA[9]=g_rps[ia].sup4; lvlA[10]=g_rps[ia].sup5;
   lvlB[0]=g_rps[ib].res1; lvlB[1]=g_rps[ib].res2; lvlB[2]=g_rps[ib].res3;
   lvlB[3]=g_rps[ib].res4; lvlB[4]=g_rps[ib].res5; lvlB[5]=g_rps[ib].pivot;
   lvlB[6]=g_rps[ib].sup1; lvlB[7]=g_rps[ib].sup2; lvlB[8]=g_rps[ib].sup3;
   lvlB[9]=g_rps[ib].sup4; lvlB[10]=g_rps[ib].sup5;
   double tol = momentEqPips * 10.0 * _Point;
   int    cnt = 0;
   refLevel   = EMPTY_VALUE;
   for(int i = 0; i < 11; i++)
     {
      if(lvlA[i] <= 0.0) continue;
      for(int j = 0; j < 11; j++)
        {
         if(lvlB[j] <= 0.0) continue;
         if(MathAbs(lvlA[i] - lvlB[j]) <= tol)
           {
            cnt++;
            refLevel = lvlA[i];
            break;
           }
        }
     }
   return cnt;
  }

//--- Nama level RPS (index 0..10 ala MomentEq) ---------------------------
string MomentLevelName(int i)
  {
   switch(i)
     {
      case 0:  return "R1";
      case 1:  return "R2";
      case 2:  return "R3";
      case 3:  return "R4";
      case 4:  return "R5";
      case 5:  return "PIV";
      case 6:  return "S1";
      case 7:  return "S2";
      case 8:  return "S3";
      case 9:  return "S4";
      case 10: return "S5";
      default: return "";
     }
  }

//--- Detail ekuivalensi: TF mana dg TF mana + level RPS berapa -------------
//   output: "EQV 15-M/30-M R2" atau "EQV H4/H8 R2+S1" (maks 3 level + sisanya)
void MomentEqDetail(OptPeriod a, OptPeriod b, string &out)
  {
   out = "";
   int ia = PeriodIndex(a), ib = PeriodIndex(b);
   if(ia < 0 || ib < 0 || !g_valid[ia] || !g_valid[ib]) return;
   double lvlA[11], lvlB[11];
   lvlA[0]=g_rps[ia].res1; lvlA[1]=g_rps[ia].res2; lvlA[2]=g_rps[ia].res3;
   lvlA[3]=g_rps[ia].res4; lvlA[4]=g_rps[ia].res5; lvlA[5]=g_rps[ia].pivot;
   lvlA[6]=g_rps[ia].sup1; lvlA[7]=g_rps[ia].sup2; lvlA[8]=g_rps[ia].sup3;
   lvlA[9]=g_rps[ia].sup4; lvlA[10]=g_rps[ia].sup5;
   lvlB[0]=g_rps[ib].res1; lvlB[1]=g_rps[ib].res2; lvlB[2]=g_rps[ib].res3;
   lvlB[3]=g_rps[ib].res4; lvlB[4]=g_rps[ib].res5; lvlB[5]=g_rps[ib].pivot;
   lvlB[6]=g_rps[ib].sup1; lvlB[7]=g_rps[ib].sup2; lvlB[8]=g_rps[ib].sup3;
   lvlB[9]=g_rps[ib].sup4; lvlB[10]=g_rps[ib].sup5;
   double tol = momentEqPips * 10.0 * _Point;
   string lst = "";
   int    cnt = 0;
   for(int i = 0; i < 11; i++)
     {
      if(lvlA[i] <= 0.0) continue;
      for(int j = 0; j < 11; j++)
        {
         if(lvlB[j] <= 0.0) continue;
         if(MathAbs(lvlA[i] - lvlB[j]) <= tol)
           {
            if(cnt < 3) { if(lst != "") lst += "+"; lst += MomentLevelName(i); }
            cnt++;
            break;
           }
        }
     }
   if(cnt == 0) return;
   if(cnt > 3) lst += "+" + IntegerToString(cnt - 3);
   out = StringFormat("%s/%s %s", ShortTfName(a), ShortTfName(b), lst);
  }

//--- Nama TF singkat (15M, 30M, H1, H4, 8H, D1, W1, MN, Q, SM, YR) ------------
string ShortTfName(OptPeriod p)
  {
   switch(p)
     {
      case OPT_15M:  return "15M";
      case OPT_30M:  return "30M";
      case OPT_H1:   return "H1";
      case OPT_H4:   return "H4";
      case OPT_H8:   return "8H";
      case OPT_D1:   return "D1";
      case OPT_W1:   return "W1";
      case OPT_MN1:  return "MN";
      case OPT_QRTR: return "Q";
      case OPT_SMTR: return "SM";
      case OPT_YEAR: return "YR";
      default:       return "?";
     }
  }

//--- Moment: pasangan TF berurutan (semua TF punya pasangan, TF kecil aktif)
OptPeriod MomentMate(OptPeriod p)
  {
   switch(p)
     {
      case OPT_15M:  return OPT_30M;
      case OPT_30M:  return OPT_H1;
      case OPT_H1:   return OPT_H4;
      case OPT_H4:   return OPT_H8;
      case OPT_H8:   return OPT_D1;
      case OPT_D1:   return OPT_W1;
      case OPT_W1:   return OPT_MN1;
      case OPT_MN1:  return OPT_QRTR;
      case OPT_QRTR: return OPT_SMTR;
      case OPT_SMTR: return OPT_YEAR;
      case OPT_YEAR: return OPT_MN1;
      default:       return OPT_COUNT;
     }
  }

//--- Moment cell: SELALU ADA ISI di setiap timeframe -----------------------
//  Prioritas: GEJALA ANOMALI → TARGET UP/DN, EQUIVALEN → EQUIVALEN → EQn
//  → fallback momentum arah bar itu sendiri (MOM UP / MOM DN / FLAT)
string MomentCell(OptPeriod p)
  {
   OptPeriod mate = MomentMate(p);
   if(mate == OPT_COUNT) return "--";
   int ia = PeriodIndex(p), ib = PeriodIndex(mate);
   if(ia < 0 || ib < 0 || !g_valid[ia] || !g_valid[ib]) return "--";
   double close = g_barNow[ia].close;
   if(close <= 0.0) return "--";

   // GEJALA ANOMALI: level RPS ekstrem/sangat jauh dari harga
   if(g_rps[ia].res5 > 0.0 && g_rps[ia].res5 > close * 1.5)
      return "GEJALA ANOMALI";

   double ref = EMPTY_VALUE;
   int n = MomentEq(p, mate, ref);
   if(n > 0 && ref != EMPTY_VALUE)
     {
      // Pola: satu TF JIKA up (Target Up) vs pasangannya JIKA down (Busur Down)
      int jA = JikaState(g_barNow[ia], g_barPrev[ia]);
      int jB = JikaState(g_barNow[ib], g_barPrev[ib]);
      bool polaUp  = (jA > 0 && jB < 0);   // Target UP
      bool polaDn  = (jA < 0 && jB > 0);   // Target DN

      string det = "";
      MomentEqDetail(p, mate, det);        // "EQV 15-M/30-M R2"

      string ket = "";
      if(polaUp)      ket += "TARGET UP " + det;
      else if(polaDn) ket += "TARGET DN " + det;
      else            ket  = det;         // cukup "EQV tf/tf LVL"
      return ket;
     }

   // Fallback: momentum arah bar TF itu sendiri (selalu ada isi)
   CandleBar b = g_barNow[ia];
   double body = MathAbs(b.close - b.open);
   double rng  = b.high - b.low;
   if(rng <= 0.0 || body < 0.15 * rng) return "FLAT";
   return (b.close > b.open) ? "MOM UP" : "MOM DN";
  }

//--- RVSLMT (Reversal Limit): batas pembalikan arah utk acuan locking / SL ----
//   A = level R di ATAS HB (buystop / SL di atas harga sekarang)
//   B = level S di BAWAH LB (sellstop / SL di bawah harga sekarang)
//   Prioritas penempatan: level R di atas HB / level S di bawah LB.
//   Semua TF dapat isi -> "A 4159.37" / "B 4137.07" atau "A 4159.37/B 4137.07"
string RvsLabel(OptPeriod p)
  {
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return "--";
   if(!g_barNow[ia].valid || !g_barPrev[ia].valid) return "--";

   CandleBar prv = g_barPrev[ia];
   RPSLevels rps = g_rps[ia];

   double hb = prv.high, lb = prv.low;   // HIGH BEFORE / LOW BEFORE
   double rA = rps.NearestAbove(hb);     // level R di atas HB
   double sB = rps.NearestBelow(lb);     // level S di bawah LB

   string out = "";
   if(rA != EMPTY_VALUE) out += "A " + FmtPrice(rA);
   if(sB != EMPTY_VALUE)
     {
      if(out != "") out += ", ";
      out += "B " + FmtPrice(sB);
     }
   if(out == "") return "--";
   return out;
  }

//--- RVSLMT + fallback: SELALU ADA sinyal di tiap TF -------------------------
//   Prioritas: A/B level RPS di sekitar HB/LB. Kalau level RPS tidak ada di
//   sisi itu, cari lebih jauh (2× rentang HB-LB). Kalau tetap tidak ada,
//   pakai High-Before / Low-Before itu sendiri (batas riil harga terakhir).
string RvsLabelAlways(OptPeriod p)
  {
   int ia = PeriodIndex(p);
   if(ia < 0 || !g_valid[ia]) return "--";
   if(!g_barPrev[ia].valid) return "--";
   CandleBar prv = g_barPrev[ia];
   RPSLevels rps = g_rps[ia];
   double hb = prv.high, lb = prv.low;
   double span = (hb - lb > 0.0) ? (hb - lb) : 0.0;

   double rA = rps.NearestAbove(hb);
   if(rA == EMPTY_VALUE && span > 0.0)
      rA = rps.NearestAbove(hb + span);          // cari lebih jauh
   double sB = rps.NearestBelow(lb);
   if(sB == EMPTY_VALUE && span > 0.0)
      sB = rps.NearestBelow(lb - span);          // cari lebih jauh

   string out = "";
   // Hanya tampilkan SATU sisi: A atau B — yang PALING DEKAT ke harga sekarang
   // (batasan yang "kejemput" harganya terlebih dulu). Kolom tidak melebar.
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(rA != EMPTY_VALUE && sB != EMPTY_VALUE)
     {
      if(MathAbs(rA - px) <= MathAbs(px - sB))
         return "A " + FmtPrice(rA);
      return "B " + FmtPrice(sB);
     }
   if(rA != EMPTY_VALUE) return "A " + FmtPrice(rA);
   if(sB != EMPTY_VALUE) return "B " + FmtPrice(sB);
   // fallback terakhir: HB/LB (batas riil harga terakhir)
   if(hb > 0.0) return "A " + FmtPrice(hb);
   if(lb > 0.0) return "B " + FmtPrice(lb);
   return out;
  }

//--- RPS row cell ---------------------------------------------------------------------------
double RpsAt(OptPeriod p, int idx)   // 0=S5 ... 5=PIVOT ... 10=R5
  {
   int ia = PeriodIndex(p);
   if(ia < 0) return EMPTY_VALUE;
   switch(idx)
     {
      case 0:  return g_rps[ia].sup5;
      case 1:  return g_rps[ia].sup4;
      case 2:  return g_rps[ia].sup3;
      case 3:  return g_rps[ia].sup2;
      case 4:  return g_rps[ia].sup1;
      case 5:  return g_rps[ia].pivot;
      case 6:  return g_rps[ia].res1;
      case 7:  return g_rps[ia].res2;
      case 8:  return g_rps[ia].res3;
      case 9:  return g_rps[ia].res4;
      case 10: return g_rps[ia].res5;
     }
   return EMPTY_VALUE;
  }

//--- Column plan helpers ---------------------------------------------------------------------
void AddCol(string t, int w)
  {
   if(g_colN < 40) { g_colT[g_colN] = t; g_colW[g_colN] = w; g_colN++; }
  }
void ResetCols() { g_colN = 0; }

//--- VANTERA DIRECTION: skor arah bersama (dipakai panel & EA) ----------------
// +1 = BUY, -1 = SELL, 0 = WAIT — basis TF chart aktif + spion 2 tingkat
int VanteraDirection()
  {
   OptPeriod base  = ChartOptPeriod();     // TF chart aktif (perwakilan terdekat)
   OptPeriod htf   = ChartSpion();         // spion: 2 tingkat di atas (M5 -> M30)
   OptPeriod htf2  = ChartHtf(htf);        // konfirmasi kedua (M30 -> H4)

   int score = 0;
   string m0 = MomentCell(base);
   string m1 = MomentCell(htf);
   string m2 = MomentCell(htf2);
   if(StringFind(m0, "TARGET UP") >= 0) score++;
   if(StringFind(m0, "TARGET DN") >= 0) score--;
   if(StringFind(m1, "TARGET UP") >= 0) score++;
   if(StringFind(m1, "TARGET DN") >= 0) score--;
   if(StringFind(m2, "TARGET UP") >= 0) score++;
   if(StringFind(m2, "TARGET DN") >= 0) score--;
   string r0 = RvsLabelAlways(base);
   string r1 = RvsLabelAlways(htf);
   // RVSLMT A = level R di atas HB (batas atas, bullish); B = level S di bawah LB (batas bawah, bearish)
   if(StringFind(r0, "A") >= 0) score++;
   if(StringFind(r0, "B") >= 0) score--;
   if(StringFind(r1, "A") >= 0) score++;
   if(StringFind(r1, "B") >= 0) score--;
   int ia0 = PeriodIndex(base);
   if(ia0 >= 0 && g_valid[ia0] && g_barNow[ia0].valid && g_barPrev[ia0].valid)
     {
      int j0 = JikaState(g_barNow[ia0], g_barPrev[ia0]);
      if(j0 > 0) score++;
      if(j0 < 0) score--;
     }
   return (score > 0) ? 1 : (score < 0 ? -1 : 0);
  }

//--- ALASAN arah VANTERA (analisa entry/exit utk ditampilkan & di-log) ---------
//   Detail faktor pendukung: MOMENT (TARGET UP/DN + ekuivalensi), RVSLMT (A/B),
//   JIKA TF chart — biar trader paham KENAPA BUY/SELL.
string VanteraReason()
  {
   OptPeriod base  = ChartOptPeriod();
   OptPeriod htf   = ChartSpion();
   OptPeriod htf2  = ChartHtf(htf);
   string   out    = "";
   string   m0 = MomentCell(base), m1 = MomentCell(htf), m2 = MomentCell(htf2);
   if(StringFind(m0, "TARGET UP") >= 0) out += "MOMENT " + PeriodName(base) + " UP; ";
   if(StringFind(m0, "TARGET DN") >= 0) out += "MOMENT " + PeriodName(base) + " DN; ";
   if(StringFind(m1, "TARGET UP") >= 0) out += "SPION "  + PeriodName(htf)  + " UP; ";
   if(StringFind(m1, "TARGET DN") >= 0) out += "SPION "  + PeriodName(htf)  + " DN; ";
   string r0 = RvsLabelAlways(base), r1 = RvsLabelAlways(htf);
   int ia0 = PeriodIndex(base);
   int j0 = (ia0 >= 0 && g_valid[ia0]) ? JikaState(g_barNow[ia0], g_barPrev[ia0]) : 0;
   if(StringFind(r0, "A") >= 0) out += "RVSLMT " + PeriodName(base) + " A(" + r0 + "); ";
   if(StringFind(r0, "B") >= 0) out += "RVSLMT " + PeriodName(base) + " B; ";
   if(StringFind(r1, "B") >= 0) out += "RVSLMT " + PeriodName(htf)  + " B; ";
   if(j0 > 0) out += "JIKA " + PeriodName(base) + " UP; ";
   if(j0 < 0) out += "JIKA " + PeriodName(base) + " DN; ";
   if(out == "") out = "Tidak ada konfirmasi kuat (WAIT)";
   return out;
  }

//--- VANTERA SIGNAL: analisa entry (BUY/SELL) + level pending order ------------
// Basis analisa = TIMEFRAME CHART AKTIF (Period()); ganti chart TF = sinyal ikut berubah
OptPeriod ChartOptPeriod()
  {
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   switch(tf)
     {
      case PERIOD_M1:
      case PERIOD_M5:
      case PERIOD_M15: return OPT_15M;
      case PERIOD_M30: return OPT_30M;
      case PERIOD_H1:  return OPT_H1;
      case PERIOD_H4:  return OPT_H4;
      case PERIOD_H8:  return OPT_H8;
      case PERIOD_D1:  return OPT_D1;
      case PERIOD_W1:  return OPT_W1;
      case PERIOD_MN1: return OPT_MN1;
      default:         return OPT_H1;
     }
  }
// TF "spion" (2 tingkat di atas chart AKTIF): M5 -> M30, M30 -> H4, H1 -> H8, dsb
OptPeriod ChartSpion()
  {
   switch((ENUM_TIMEFRAMES)Period())
     {
      case PERIOD_M1:  return OPT_15M;   // M1  -> M15
      case PERIOD_M5:  return OPT_30M;   // M5  -> M30  (sesuai permintaan)
      case PERIOD_M15: return OPT_H1;    // M15 -> H1
      case PERIOD_M30: return OPT_H4;    // M30 -> H4
      case PERIOD_H1:  return OPT_H8;    // H1  -> 8H
      case PERIOD_H4:  return OPT_D1;    // H4  -> D1
      case PERIOD_H8:  return OPT_W1;    // 8H  -> W1
      case PERIOD_D1:  return OPT_MN1;   // D1  -> MN1
      case PERIOD_W1:  return OPT_MN1;   // W1  -> MN1
      default:         return OPT_H4;
     }
  }
// TF "induk" (2 tingkat di atas spion) utk konfirmasi kedua
OptPeriod ChartHtf(OptPeriod base)
  {
   switch(base)
     {
      case OPT_15M:  return OPT_H1;    // 15M -> H1
      case OPT_30M:  return OPT_H4;    // 30M -> H4
      case OPT_H1:   return OPT_H8;    // H1  -> 8H
      case OPT_H4:   return OPT_D1;    // H4  -> D1
      case OPT_H8:   return OPT_W1;    // 8H  -> W1
      case OPT_D1:   return OPT_MN1;   // D1  -> MN1
      case OPT_W1:   return OPT_MN1;   // W1  -> MN1
      default:       return OPT_H4;
     }
  }

void DrawVanteraSignal(int &y, int x0)
  {
   // --- Basis analisa: TF chart aktif + SPION 2 tingkat di atas
   OptPeriod base  = ChartOptPeriod();     // mis. M5 -> OPT_15M (perwakilan terdekat)
   OptPeriod htf   = ChartSpion();         // SPION: mis. chart M5 -> M30 (2 tingkat di atas)

   // Arah bias: skor dari MOMENT & RVSLMT di TF chart + induknya + JIKA TF chart
   int dirVantera = VanteraDirection();
   int score = 0;
   if(dirVantera > 0) score = 1;           // arah dari fungsi bersama
   else if(dirVantera < 0) score = -1;
   else score = 0;

   string arah  = (score > 0) ? "BUY"  : (score < 0 ? "SELL" : "WAIT");
   color  arahC = (score > 0) ? clrUp  : (score < 0 ? clrDown : clrNeutral);
   string alasan = VanteraReason();     // analisa entry/exit: kenapa BUY/SELL

   // --- Level eksekusi dari RPS TF CHART AKTIF + TP/SL dari RPS & OHLC
   double px    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double trgUp = EMPTY_VALUE, trgDn = EMPTY_VALUE;
   double tpBuy = EMPTY_VALUE, slBuy = EMPTY_VALUE;
   double tpSell = EMPTY_VALUE, slSell = EMPTY_VALUE;
   int iaB = PeriodIndex(base);
   if(iaB >= 0 && g_valid[iaB])
     {
      RPSLevels rpsB = g_rps[iaB];
      trgUp = rpsB.NearestAbove(px);      // resistance terdekat
      trgDn = rpsB.NearestBelow(px);      // support terdekat

      double buf  = vanteraBufferPips * 10.0 * _Point;
      double lo1  = iLow(_Symbol, BarTf(base), 1);    // OHLC bar selesai terakhir
      double hi1  = iHigh(_Symbol, BarTf(base), 1);

      // BUY : SL di bawah support (dgn buffer OHLC low), TP di resistance berikutnya
      slBuy = (trgDn != EMPTY_VALUE) ? trgDn : (lo1 > 0.0 ? lo1 : px);
      if(lo1 > 0.0 && slBuy > lo1) slBuy = lo1;       // pastikan SL di bawah low terakhir
      slBuy -= buf;
      if(trgUp != EMPTY_VALUE) tpBuy = rpsB.NearestAbove(trgUp + _Point);
      if(tpBuy == EMPTY_VALUE) tpBuy = trgUp;

      // SELL: SL di atas resistance (dgn buffer OHLC high), TP di support berikutnya
      slSell = (trgUp != EMPTY_VALUE) ? trgUp : (hi1 > 0.0 ? hi1 : px);
      if(hi1 > 0.0 && slSell < hi1) slSell = hi1;     // pastikan SL di atas high terakhir
      slSell += buf;
      if(trgDn != EMPTY_VALUE) tpSell = rpsB.NearestBelow(trgDn - _Point);
      if(tpSell == EMPTY_VALUE) tpSell = trgDn;
     }

   int x = x0;
   SetLabel("vs_hdr", "VANTERA SIGNAL", x, y, clrHeader, fontSize);
   y += rowH;

   x = x0;
   SetLabel("vs_tf_l", "TF CHART:", x, y, clrHeader, fontSize); x += 86;
   SetLabel("vs_tf", PeriodName(base), x, y, clrMoment, fontSize);
   y += rowH;

   x = x0;
   SetLabel("vs_arah_l", "ARAH:", x, y, clrHeader, fontSize); x += 56;
   SetLabel("vs_arah", arah, x, y, arahC, fontSize); x += 96;
   SetLabel("vs_hit_l", "ENTRY:", x, y, clrHeader, fontSize); x += 66;
   SetLabel("vs_hit", FmtPrice(px), x, y, clrMoment, fontSize);
   y += rowH;

   // ALASAN analisa entry/exit (kenapa BUY/SELL) — dari MOMENT + RVSLMT + JIKA
   x = x0;
   SetLabel("vs_why_l", "ALASAN:", x, y, clrHeader, fontSize); x += 66;
   SetLabel("vs_why", alasan, x, y, clrMoment, fontSize);
   y += rowH;

   // BUY line: stop di target (breakout) + limit di busur (retest)
   x = x0;
   SetLabel("vs_bs_l", "B.STOP", x, y, clrHeader, fontSize); x += 62;
   SetLabel("vs_bs", FmtPrice(trgUp), x, y, C_CYAN, fontSize); x += 104;
   SetLabel("vs_bl_l", "B.LIMIT", x, y, clrHeader, fontSize); x += 72;
   SetLabel("vs_bl", FmtPrice(trgDn), x, y, C_AQUA, fontSize);
   y += rowH;

   // SELL line: stop di busur (breakdown) + limit di target (retest)
   x = x0;
   SetLabel("vs_ss_l", "S.STOP", x, y, clrHeader, fontSize); x += 62;
   SetLabel("vs_ss", FmtPrice(trgDn), x, y, C_MAG, fontSize); x += 104;
   SetLabel("vs_sl_l", "S.LIMIT", x, y, clrHeader, fontSize); x += 72;
   SetLabel("vs_sl", FmtPrice(trgUp), x, y, C_ORG, fontSize);
   y += rowH;

   // TP / SL (dari RPS + OHLC TF chart aktif)
   x = x0;
   SetLabel("vs_tp_l", "TP BUY/SELL:", x, y, clrHeader, fontSize); x += 122;
   SetLabel("vs_tp", FmtPrice(tpBuy) + " / " + FmtPrice(tpSell), x, y, clrUp, fontSize);
   y += rowH;
   x = x0;
   SetLabel("vs_sl2_l", "SL BUY/SELL:", x, y, clrHeader, fontSize); x += 122;
   SetLabel("vs_sl2", FmtPrice(slBuy) + " / " + FmtPrice(slSell), x, y, clrDown, fontSize);
   y += rowH + 4;
  }

//--- Market info block di SEBELAH KANAN matriks RPS (sejajar baris RPS) --------
void DrawMarketInfoRight(int yStart)
  {
   // x = kanan R5 (TF 70 + 11 kolom colW), y = sejajar baris RPS matrix
   int x  = panelX + 70 + 11 * colW + 24;
   int y  = yStart;

   SetLabel("mi_hdr", "MARKET INFO", x, y, clrHeader, fontSize);
   y += rowH;

   MqlDateTime st; TimeToStruct(TimeCurrent(), st);
   int hr = (st.hour + sessOffsetHours + 24) % 24;   // jam efektif utk sesi
   string on = "ON ", off = "OFF";
   bool aOpen = (hr >= 0 && hr < 8);
   bool eOpen = (hr >= 8 && hr < 16);
   bool uOpen = (hr >= 16);

   // Zona pasar RIIL sekarang
   string zona = uOpen ? "AMERIKA" : (eOpen ? "EROPA" : "ASIA");
   color  zonaClr = uOpen ? clrDown : (eOpen ? clrUp : clrMoment);
   SetLabel("mi_zona_l", "ZONA:", x, y, clrHeader, fontSize); x += 52;
   SetLabel("mi_zona", zona, x, y, zonaClr, fontSize);
   y += rowH;

   // Sesi 8 jam
   x = panelX + 70 + 11 * colW + 24;
   SetLabel("mi_asia",  "ASIA    00-08", x, y, aOpen ? clrUp : clrNeutral, fontSize);  x += 132;
   SetLabel("mi_asia_s",  aOpen ? on : off, x, y, aOpen ? clrUp : clrNeutral, fontSize); x += 46;
   SetLabel("mi_eur",   "EROPA   08-16", x, y, eOpen ? clrUp : clrNeutral, fontSize);  x += 132;
   SetLabel("mi_eur_s",   eOpen ? on : off, x, y, eOpen ? clrUp : clrNeutral, fontSize); x += 46;
   SetLabel("mi_usa",   "AMERIKA 16-24", x, y, uOpen ? clrUp : clrNeutral, fontSize);  x += 152;
   SetLabel("mi_usa_s",   uOpen ? on : off, x, y, uOpen ? clrUp : clrNeutral, fontSize);
   y += rowH;

   // Pair + jam server
   x = panelX + 70 + 11 * colW + 24;
   SetLabel("mi_pair_l", "PAIR:", x, y, clrHeader, fontSize); x += 52;
   SetLabel("mi_pair", _Symbol, x, y, clrMoment, fontSize);   x += 168;
   SetLabel("mi_srv", "SERVER " + StringFormat("%02d:%02d", st.hour, st.min), x, y, clrNeutral, fontSize);
   y += rowH;

   // Spread broker
   x = panelX + 70 + 11 * colW + 24;
   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips = spreadPts / 10.0;
   SetLabel("mi_spr_l", "SPREAD:", x, y, clrHeader, fontSize); x += 76;
   SetLabel("mi_spr", StringFormat("%.1f pips (%.0f pts)", spreadPips, (double)spreadPts), x, y,
            (spreadPts <= 30) ? clrUp : ((spreadPts <= 50) ? clrMoment : clrDown), fontSize);
   y += rowH;

   // P/L hari ini
   MqlDateTime st0; TimeToStruct(TimeCurrent(), st0);
   st0.hour = 0; st0.min = 0; st0.sec = 0;
   datetime dayStart = StructToTime(st0);
   double daily = 0.0;
   if(HistorySelect(dayStart, TimeCurrent() + 60))
     {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         daily += HistoryDealGetDouble(tk, DEAL_PROFIT)
                + HistoryDealGetDouble(tk, DEAL_SWAP)
                + HistoryDealGetDouble(tk, DEAL_COMMISSION);
        }
     }
   daily += AccountInfoDouble(ACCOUNT_PROFIT);
   x = panelX + 70 + 11 * colW + 24;
   SetLabel("mi_pl_l", "P/L HARI INI:", x, y, clrHeader, fontSize); x += 122;
   SetLabel("mi_pl", StringFormat("%+.2f", daily), x, y, (daily >= 0.0) ? clrUp : clrDown, fontSize);
   y += rowH + 2;

   // Nama pemilik (footer)
   x = panelX + 70 + 11 * colW + 24;
   SetLabel("mi_owner", "Vantera Trading Konsultan", x, y, clrMoment, fontSize);
   y += rowH;

   // VANTERA SIGNAL: analisa entry & pending order (di bawah owner, DIBERI JARAK)
   y += rowH;   // jarak ekstra: tidak mepet nama owner
   if(showVanteraSignal)
      DrawVanteraSignal(y, panelX + 70 + 11 * colW + 24);
  }

//--- Draw -------------------------------------------------------------------------------------
void DrawPanel()
  {
   int y = panelY;
   int rpsHeaderY = 0;   // posisi header RPS (scope DrawPanel, dipakai MARKET INFO)
   ResetCols();

   if(showCandleFlow)
     {
      AddCol("TF", 70);
      if(colOHLC)    { AddCol("OP N",colW); AddCol("OP B",colW); AddCol("HI N",colW); AddCol("HI B",colW); AddCol("LO N",colW); AddCol("LO B",colW); }
      if(colJika)     AddCol("JIKA",64);
      if(colTrend)    AddCol("TREND",74);
      if(colOpPv)     AddCol("OP-PV",64);
      if(colPivoting) AddCol("PIVOTING",80);
      if(colTugas)    AddCol("TUGAS",64);
      if(colMove)     AddCol("MOVE",64);
      if(colPerahu)   AddCol("PERAHU",56);
      if(colArea)     AddCol("AREA",64);
      if(colIndex)    AddCol("INDEX%",60);
      if(colRange)    AddCol("RANGE%",60);
      if(colBreak)   { AddCol("BRK H",60); AddCol("BRK L",60); }
      if(colBusur)    AddCol("BUSUR",colW);
      if(colTarget)   AddCol("TARGET",colW);
      if(colRvs)      AddCol("RVSLMT",colW);      // hanya A/B terdekat -> cukup colW
      if(colTrg)     { AddCol("TRG UP",colW); AddCol("TRG DN",colW); }
      if(colAts)      AddCol("ATS",colW);
      if(colMoment)   AddCol("MOMENT",(int)(colW*1.5));
      if(colSar)     { AddCol("SAR ATAS",70); AddCol("SAR BWH",70); }
      if(colPola)     AddCol("POLA",70);
      if(colHsh)      AddCol("HSH",60);
     }

   //--- Header row (warna pelangi dari kiri ke kanan: TF -> MOMENT) ---
   int x = panelX;
   for(int c = 0; c < g_colN; c++)
     {
      color hc = HeaderRainbow(c, g_colN);
      SetLabel("h_"+IntegerToString(c), g_colT[c], x, y, hc, fontSize);
      x += g_colW[c];
     }
   y += rowH + 4;

   //--- Candle Flow rows (11 periods: 15-M .. YEARLY) ---
   for(int r = 0; r < OPT_COUNT; r++)
     {
      OptPeriod p  = g_periods[r];
      int       ia = g_valid[r] ? r : -1;
      int       x2 = panelX;
      int       c  = 0;

      SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), PeriodName(p), x2, y,
               (ia < 0) ? clrNeutral : TfColor(p), fontSize);
      x2 += g_colW[0];

      if(colOHLC)
        {
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barNow[ia].open),  x2, y, (ia<0)?clrNeutral:UseUpDownCol(g_barNow[ia].open, g_barPrev[ia].open), fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barPrev[ia].open),  x2, y, clrNeutral, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barNow[ia].high),  x2, y, (ia<0)?clrNeutral:clrUp, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barPrev[ia].high),  x2, y, clrNeutral, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barNow[ia].low),   x2, y, (ia<0)?clrNeutral:clrDown, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), (ia<0)?"--":FmtPrice(g_barPrev[ia].low),   x2, y, clrNeutral, fontSize); x2 += g_colW[c-1];
        }

      if(colJika)
        {
         int j = (ia<0)?0:JikaState(g_barNow[ia], g_barPrev[ia]);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), JikaLabel(j), x2, y,
                  (j>0)?clrUp:((j<0)?clrDown:clrNeutral), fontSize); x2 += g_colW[c-1];
        }
      if(colTrend)
        {
         int t = (ia<0)?0:g_trend[ia];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), TrendLabel(t), x2, y,
                  (ia<0)?clrNeutral:TrendColor(t), fontSize); x2 += g_colW[c-1];
        }
      if(colOpPv)
        {
         double pv = (ia<0)?0.0:(g_barNow[ia].high+g_barNow[ia].low+g_barNow[ia].close)/3.0;
         int st = (ia<0)?0:OpPvState(g_barNow[ia], pv);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), OpPvLabel(st), x2, y,
                  (st>0)?clrUp:((st<0)?clrDown:clrNeutral), fontSize); x2 += g_colW[c-1];
        }
      if(colPivoting)
        {
         int st = (ia<0)?0:OpPvState(g_barNow[ia], g_rps[ia].pivot);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), OpPvLabel(st), x2, y,
                  (st>0)?clrUp:((st<0)?clrDown:clrNeutral), fontSize); x2 += g_colW[c-1];
        }
      if(colTugas)
        {
         int j  = (ia<0)?0:JikaState(g_barNow[ia], g_barPrev[ia]);
         string tg = (ia<0)?"--":TugasLabel(p, j, g_barNow[ia].close, g_rps[ia].pivot);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), tg, x2, y, (tg=="--")?clrNeutral:C_GOLD, fontSize); x2 += g_colW[c-1];
        }
      if(colMove)
        {
         string mv = (ia<0)?"--":MoveLabel(g_barNow[ia], g_barPrev[ia]);
         color mc = (mv=="UP")?clrUp:((mv=="DN")?clrDown:clrNeutral);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), mv, x2, y, mc, fontSize); x2 += g_colW[c-1];
        }
      if(colPerahu)
        {
         string ph = (ia<0)?"--":PerahuLabel(g_barNow[ia], g_barPrev[ia]);
         color pc = (ph=="NAIK")?clrUp:((ph=="TURUN")?clrDown:((ph=="MELEBAR")?clrMoment:clrNeutral));
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), ph, x2, y, pc, fontSize); x2 += g_colW[c-1];
        }
      if(colArea)
        {
         string ar = (ia<0)?"--":AreaLabel(g_barNow[ia], g_barPrev[ia]);
         color ac = (ar=="ATAS")?clrUp:((ar=="BAWAH")?clrDown:clrNeutral);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), ar, x2, y, ac, fontSize); x2 += g_colW[c-1];
        }
      if(colIndex)
        {
         double iv = (ia<0)?50.0:g_index[ia];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtIdx(iv), x2, y,
                  (iv>=60)?clrUp:((iv<=40)?clrDown:clrNeutral), fontSize); x2 += g_colW[c-1];
        }
      if(colRange)
        {
         double rv = (ia<0)?100.0:g_rangePct[ia];
         color rc = (rv>=140)?clrUp:((rv<=80)?clrDown:clrNeutral);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPct(rv), x2, y, rc, fontSize); x2 += g_colW[c-1];
        }
      if(colBreak)
        {
         string bl = (ia<0)?"--":BreakLabel(g_barNow[ia], g_barPrev[ia]);
         string bh = (bl=="BRK"||bl=="BRK H") ? "BRK" : ((bl=="BRK L")?"HOLD":bl);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), bh, x2, y, (bh=="HOLD")?clrNeutral:clrUp, fontSize); x2 += g_colW[c-1];
         string bl2 = (bl=="BRK"||bl=="BRK L") ? "BRK" : ((bl=="BRK H")?"HOLD":bl);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), bl2, x2, y, (bl2=="HOLD")?clrNeutral:clrDown, fontSize); x2 += g_colW[c-1];
        }
      if(colBusur)
        {
         int j = (ia<0)?0:JikaState(g_barNow[ia], g_barPrev[ia]);
         double bv = (ia<0)?EMPTY_VALUE:BusurLevel(g_barPrev[ia], j, g_rps[ia]);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPrice(bv), x2, y, (ia<0)?clrNeutral:C_AQUA, fontSize); x2 += g_colW[c-1];
        }
      if(colTarget)
        {
         int j = (ia<0)?0:JikaState(g_barNow[ia], g_barPrev[ia]);
         double tv = (ia<0)?EMPTY_VALUE:TargetLevel(g_barPrev[ia], j, g_rps[ia]);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPrice(tv), x2, y, (ia<0)?clrNeutral:C_ORG, fontSize); x2 += g_colW[c-1];
        }
      if(colRvs)
        {
         string rvs = (ia<0)?"--":RvsLabelAlways(p);
         // A = batas atas (R di atas HB) -> hijau/cyan ; B = batas bawah (S di bawah LB) -> merah/magenta
         color rc = clrNeutral;
         if(rvs != "--")
           {
            if(StringFind(rvs, "A") >= 0 && StringFind(rvs, "B") >= 0) rc = C_PINK;
            else if(StringFind(rvs, "A") >= 0)                          rc = C_CYAN;
            else if(StringFind(rvs, "B") >= 0)                          rc = C_MAG;
           }
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), rvs, x2, y, rc, fontSize); x2 += g_colW[c-1];
        }
      if(colTrg)
        {
         int j = (ia<0)?0:JikaState(g_barNow[ia], g_barPrev[ia]);
         double tu = (ia<0)?EMPTY_VALUE:TrgUp(g_barPrev[ia], j, g_rps[ia]);
         double td = (ia<0)?EMPTY_VALUE:TrgDn(g_barPrev[ia], j, g_rps[ia]);
         // Analisa range pergerakan: TF yang MAMPU menembus target tampil warna
         // terang (cyan/magenta); yang tidak mampu redup (abu)
         bool ableUp = (ia>=0 && tu!=EMPTY_VALUE) ? TrgAbleUp(p, tu) : false;
         bool ableDn = (ia>=0 && td!=EMPTY_VALUE) ? TrgAbleDn(p, td) : false;
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPrice(tu), x2, y,
                  ableUp?C_CYAN:clrNeutral, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPrice(td), x2, y,
                  ableDn?C_MAG:clrNeutral, fontSize); x2 += g_colW[c-1];
        }
      if(colAts)
        {
         double atr = (ia<0)?EMPTY_VALUE:AtrValue(p);
         double av  = (ia<0)?EMPTY_VALUE:AtsValue(g_barNow[ia], atr);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), FmtPrice(av), x2, y, clrNeutral, fontSize); x2 += g_colW[c-1];
        }
      if(colMoment)
        {
         string mc = (ia<0)?"--":MomentCell(p);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), mc, x2, y, (mc=="--")?clrNeutral:clrMoment, fontSize); x2 += g_colW[c-1];
        }
      if(colSar)
        {
         double sv = (ia<0)?EMPTY_VALUE:SarValue(p, 1);
         double closeNow = (ia<0)?0.0:g_barNow[ia].close;
         string sa = (sv==EMPTY_VALUE || closeNow<=0.0) ? "--" : ((sv>closeNow)?FmtPrice(sv):"--");
         string sb = (sv==EMPTY_VALUE || closeNow<=0.0) ? "--" : ((sv<closeNow)?FmtPrice(sv):"--");
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), sa, x2, y, (sa=="--")?clrNeutral:clrUp, fontSize); x2 += g_colW[c-1];
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), sb, x2, y, (sb=="--")?clrNeutral:clrDown, fontSize); x2 += g_colW[c-1];
        }
      if(colPola)
        {
         string pl = (ia<0)?"--":PolaLabel(g_barPrev[ia]);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), pl, x2, y, clrNeutral, fontSize); x2 += g_colW[c-1];
        }
      if(colHsh)
        {
         double refO = (ia<0)?0.0:iOpen(_Symbol, BarTf(p), 1);
         string hs = (ia<0)?"--":HshLabel(g_barNow[ia], refO, hshZonePips);
         color hc = (hs=="HSH")?clrMoment:((hs=="PULANG")?clrOrange:clrNeutral);
         SetLabel("r"+IntegerToString(r)+"c"+IntegerToString(c++), hs, x2, y, hc, fontSize); x2 += g_colW[c-1];
        }
      y += rowH;
     }

   //--- Moment row (equivalence flags) — opsional, default off (hemat tinggi)
   if(showMomentRow)
     {
      int x3 = panelX;
      SetLabel("mom_tf", "MOMENT", x3, y, clrHeader, fontSize); x3 += g_colW[0];
      for(int r = 0; r < OPT_COUNT; r++)
        {
         string cell = MomentCell(g_periods[r]);
         int widx = MathMin(r + 1, g_colN - 1);
         SetLabel("mom_c"+IntegerToString(r), cell, x3, y, (cell=="--")?clrNeutral:clrMoment, fontSize);
         x3 += g_colW[widx];
        }
      y += rowH + 8;
     }

   //--- RPS matrix (TRANSPOSE ala referensi: level RPS di kiri kebawah, TF ke kanan)
   if(showRpsMatrix)
     {
      int rpsFont = fontSize;
      y += 12;                       // JARAK dari tabel atas (Candle Flow) — tidak mepet
      int rpsRow  = rowH + 4;        // tinggi baris RPS diperlebar (vertikal lega, presisi)
      // Level dari atas ke bawah: R5,R4,R3,R2,R1,PIV,S1,S2,S3,S4,S5 (simetris)
      string lvlName[11] = {"R5","R4","R3","R2","R1","PIV","S1","S2","S3","S4","S5"};
      int    lvlIdx[11]  = {10,9,8,7,6,5,4,3,2,1,0};   // index ke RpsAt()
      int x4 = panelX;
      rpsHeaderY = y;   // simpan posisi header RPS utk MARKET INFO sejajar
      SetLabel("rps_h_corner", "RPS", x4, y, clrHeader, rpsFont);
      x4 += 70;
      for(int t = 0; t < OPT_COUNT; t++)
        {
         // Panah arah TF pakai font Segoe UI Symbol (glyph ↑↓→ PASTI ada di Win7),
         // biar tidak tampil sebagai kotak/□.
         string tfLabel = PeriodName(g_periods[t]) + " " + TfArrow(g_periods[t]);
         SetLabel("rps_h_tf"+IntegerToString(t), tfLabel, x4, y, TfColor(g_periods[t]), rpsFont, "Segoe UI Symbol");
         x4 += colW;
        }
      y += rpsRow + 3;

      for(int r = 0; r < 11; r++)
        {
         int x5 = panelX;
         color lvlClr = clrNeutral;
         // Warna level (belum tersentuh): R1-R5 ORANYE, PIV PUTIH, S1-S5 BIRU
         switch(r)
           {
            case  0: lvlClr = clrOrange;     break;  // R5
            case  1: lvlClr = clrOrange;     break;  // R4
            case  2: lvlClr = clrOrange;     break;  // R3
            case  3: lvlClr = clrOrange;     break;  // R2
            case  4: lvlClr = clrOrange;     break;  // R1
            case  5: lvlClr = clrWhite;      break;  // PIV
            case  6: lvlClr = clrDodgerBlue; break;  // S1
            case  7: lvlClr = clrDodgerBlue; break;  // S2
            case  8: lvlClr = clrDodgerBlue; break;  // S3
            case  9: lvlClr = clrDodgerBlue; break;  // S4
            case 10: lvlClr = clrDodgerBlue; break;  // S5
           }
         SetLabel("rps_l_"+IntegerToString(r), lvlName[r], x5, y, lvlClr, rpsFont);
         x5 += 70;
         for(int t = 0; t < OPT_COUNT; t++)
           {
            OptPeriod p  = g_periods[t];
            int       ia = PeriodIndex(p);
            double    v  = (ia<0)?EMPTY_VALUE:RpsAt(p, lvlIdx[r]);
            string cell = FmtPrice(v);
            color  clr  = clrNeutral;
            if(v != EMPTY_VALUE && v > 0.0)
              {
               switch(r)
                 {
                  case  0: clr = clrOrange;     break;  // R5
                  case  1: clr = clrOrange;     break;  // R4
                  case  2: clr = clrOrange;     break;  // R3
                  case  3: clr = clrOrange;     break;  // R2
                  case  4: clr = clrOrange;     break;  // R1
                  case  5: clr = clrWhite;      break;  // PIV
                  case  6: clr = clrDodgerBlue; break;  // S1
                  case  7: clr = clrDodgerBlue; break;  // S2
                  case  8: clr = clrDodgerBlue; break;  // S3
                  case  9: clr = clrDodgerBlue; break;  // S4
                  case 10: clr = clrDodgerBlue; break;  // S5
                 }
               // SUDAH TERSENTUH harga -> warna khas TF (beda per timeframe,
               // biar kebaca level mana yg sudah terpakai dari TF mana)
               if(RpsTouched(p, lvlIdx[r], v))
                  clr = TouchColor(lvlIdx[r]);
              }
            SetLabel("rps_l"+IntegerToString(r)+"_c"+IntegerToString(t), cell, x5, y, clr, rpsFont);
            x5 += colW;
           }
         y += rpsRow;
        }
     }

   //--- Market info (sesi, pair, P/L harian) di SEBELAH KANAN matriks RPS (sejajar baris M15)
   if(showMarketInfo)
      DrawMarketInfoRight(rpsHeaderY + rowH + 3);   // baris pertama RPS = 15-M

   ChartRedraw();
  }

//--- Konsensus sinyal panel utk EA (dibaca via GlobalVariable) ----------------
string VarSig() { return "OP_SIG_" + _Symbol; }
string VarMom() { return "OP_MOM_" + _Symbol; }
string VarDir() { return "OP_DIR_" + _Symbol; }   // arah VANTERA (ARAH panel)
string VarTm()  { return "OP_TM_"  + _Symbol; }

void ComputePanelSignal()
  {
   int bull = 0, bear = 0;
   for(int r = 0; r < OPT_COUNT; r++)
     {
      int ia = PeriodIndex(g_periods[r]);
      if(ia < 0 || !g_valid[ia] || !g_barNow[ia].valid) continue;
      int j = JikaState(g_barNow[ia], g_barPrev[ia]);
      if(j > 0) bull++; else if(j < 0) bear++;
      int t = g_trend[ia];
      if(t > 0) bull++; else if(t < 0) bear++;
      double px = g_barNow[ia].close;
      if(px > g_rps[ia].pivot) bull++; else if(px < g_rps[ia].pivot) bear++;
     }
   g_panelSig[0] = (bull > bear) ? 1.0 : ((bear > bull) ? -1.0 : 0.0);

   int up = 0, dn = 0;
   for(int r = 0; r < OPT_COUNT; r++)
     {
      string m = MomentCell(g_periods[r]);
      if(StringFind(m, "TARGET UP") >= 0)   up++;
      else if(StringFind(m, "TARGET DN") >= 0) dn++;
     }
   g_momentSig[0] = (up > dn) ? 1.0 : ((dn > up) ? -1.0 : 0.0);

   // Bridge ke EA: sinyal ditulis tiap bar baru; EA wajib baca ini saat entry
   if(enableEaSig)
     {
      GlobalVariableSet(VarSig(), g_panelSig[0]);
      GlobalVariableSet(VarMom(), g_momentSig[0]);
      GlobalVariableSet(VarDir(), (double)VanteraDirection());   // ARAH panel (BUY/SELL/WAIT)
      GlobalVariableSet(VarTm(),  (double)TimeCurrent());
     }
  }

//--- OnCalculate / Init / Deinit ---------------------------------------------
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   for(int i = prev_calculated; i < rates_total; i++)
     {
      g_dummy[i] = EMPTY_VALUE;              // dummy kosong: sub-window bersih
      g_panelSig[i] = EMPTY_VALUE;           // hanya nilai di index aktif bar terakhir
      g_momentSig[i] = EMPTY_VALUE;
     }
   if(prev_calculated < rates_total - 1)
      for(int i = 0; i < 3; i++) { g_panelSig[rates_total-1-i] = 0.0; g_momentSig[rates_total-1-i] = 0.0; }
   ComputeAll();
   CheckMomentAlert();          // notifikasi MOMENT saat berubah (per TF)
   if(rates_total > 0)
     {
      // Nilai sinyal ditaruh di 3 bar terakhir supaya CopyBuffer(shift 0/1/2) selalu dapet data
      ComputePanelSignal();
      for(int i = 0; i < 3 && (rates_total-1-i) >= 0; i++)
        {
         g_panelSig[rates_total-1-i]  = g_panelSig[0];
         g_momentSig[rates_total-1-i] = g_momentSig[0];
        }
     }
   DrawPanel();
   return rates_total;
  }

int OnInit()
  {
   PeriodOrder();
   DelLabel(g_pfx);
   // PENTING: dapatkan sub-window sendiri indicator via shortname (bukan ChartWindowOnDropped
   // yang bisa 0 saat load dari Navigator). Label dibuat di sub-window ini -> terpisah dari chart.
   IndicatorSetString(INDICATOR_SHORTNAME, "OptimusPanel v1.12");
   g_win = ChartWindowFind(0, "OptimusPanel v1.12");
   if(g_win < 0) g_win = 1;   // fallback: sub-window pertama indicator
   // SetIndexBuffer dummy -> sub-window terbentuk; g_win dipakai utk label
   SetIndexBuffer(0, g_dummy, INDICATOR_DATA);
   SetIndexBuffer(1, g_panelSig, INDICATOR_CALCULATIONS);   // sinyal utk EA (tidak di-plot)
   SetIndexBuffer(2, g_momentSig, INDICATOR_CALCULATIONS);  // sinyal MOMENT utk EA
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   //--- create SAR/ATR handles for native TFs (aggregated have no handle)
   for(int i = 0; i < OPT_COUNT; i++)
     {
      OptPeriod p = g_periods[i];
      g_sarHandle[i] = INVALID_HANDLE;
      g_atrHandle[i] = INVALID_HANDLE;
      if(p == OPT_H8 || p == OPT_QRTR || p == OPT_SMTR || p == OPT_YEAR)
         continue;
      ENUM_TIMEFRAMES tf = BarTf(p);
      g_sarHandle[i] = iSAR(_Symbol, tf, psarStep, psarMax);
      g_atrHandle[i] = iATR(_Symbol, tf, atrPeriod);
     }
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int reason)
  {
   for(int i = 0; i < OPT_COUNT; i++)
     {
      if(g_sarHandle[i] != INVALID_HANDLE) IndicatorRelease(g_sarHandle[i]);
      if(g_atrHandle[i] != INVALID_HANDLE) IndicatorRelease(g_atrHandle[i]);
     }
   DelLabel(g_pfx);
  }
//+------------------------------------------------------------------+