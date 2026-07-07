//+------------------------------------------------------------------+
//|                                          AdaptiveScanner_EA.mq5    |
//|  EA متكيف وشفاف - يفحص السوق ويختار بين استراتيجية اتجاه أو ارتداد |
//|  بدون مارتينجال - بدون جريد - صفقة وحدة بالمرة - SL/TP ثابتين     |
//+------------------------------------------------------------------+
#property copyright "Built with the user - fully transparent, no hidden logic"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//---------------------------- إعدادات عامة ----------------------------
input group "=== إعدادات عامة ==="
input int      MagicNumber        = 202607;   // رقم تعريف EA (غيّره لو تشغل أكثر من نسخة)
input string   TradeComment       = "AdaptiveScanner";

//---------------------------- فحص حالة السوق ----------------------------
input group "=== فحص حالة السوق (ADX) ==="
input int      ADX_Period         = 14;       // فترة ADX
input double   ADX_TrendLevel     = 25.0;     // فوق هذا الرقم = سوق فيه اتجاه واضح
input double   ADX_RangeLevel     = 20.0;     // تحت هذا الرقم = سوق عرضي (Range)

//---------------------------- استراتيجية الاتجاه (EMA) ----------------------------
input group "=== استراتيجية 1: اتباع الاتجاه ==="
input int      EMA_Fast           = 9;
input int      EMA_Slow           = 21;
input int      EMA_TrendFilter    = 200;      // فلتر الاتجاه العام

//---------------------------- استراتيجية الارتداد (RSI+BB) ----------------------------
input group "=== استراتيجية 2: الارتداد من الأطراف ==="
input int      RSI_Period         = 14;
input double   RSI_Oversold       = 30.0;
input double   RSI_Overbought     = 70.0;
input int      BB_Period          = 20;
input double   BB_Deviation       = 2.0;

//---------------------------- إدارة المخاطر ----------------------------
input group "=== إدارة المخاطر (بدون مارتينجال) ==="
input double   LotStart           = 0.01;     // أصغر لوت (تأكيد ضعيف)
input double   LotMax             = 0.04;     // أكبر لوت (تأكيد قوي)
input double   ATR_Multiplier_SL  = 2.0;      // مضاعف ATR لوقف الخسارة
input double   ATR_Multiplier_TP  = 3.0;      // مضاعف ATR لجني الأرباح (نسبة مخاطرة:ربح صحية)
input int      ATR_Period         = 14;

//---------------------------- فلتر السبريد ----------------------------
input group "=== فلتر السبريد ==="
input bool     UseSpreadFilter    = true;     // تفعيل فلتر السبريد
input double   MaxSpreadPoints    = 30;       // أقصى سبريد مسموح (بالنقاط)، عدّله حسب الرمز (الذهب/البيتكوين يحتاجون رقم أعلى)

//---------------------------- فلتر ساعات التداول ----------------------------
input group "=== فلتر ساعات التداول (توقيت السيرفر) ==="
input bool     UseTradingHours    = true;     // تفعيل فلتر الساعات
input int      TradingHourStart   = 8;        // بداية التداول (توقيت السيرفر)
input int      TradingHourEnd     = 20;       // نهاية التداول (توقيت السيرفر) - يغطي لندن + أوفرلاب نيويورك

//---------------------------- Trailing Stop ----------------------------
input group "=== Trailing Stop ==="
input bool     UseTrailingStop    = true;     // تفعيل التتبع
input double   TrailingStart_ATR  = 1.0;      // يبدأ التتبع بعد ما الربح يوصل X × ATR
input double   TrailingStep_ATR   = 0.5;      // كل ما الربح يزيد بهالمقدار، SL يتحرك معاه

//---------------------------- متغيرات داخلية (Handles) ----------------------------
int hADX, hEMAfast, hEMAslow, hEMAfilter, hRSI, hBB, hATR;

//+------------------------------------------------------------------+
int OnInit()
{
   hADX      = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   hEMAfast  = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow  = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hEMAfilter= iMA(_Symbol, PERIOD_CURRENT, EMA_TrendFilter, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hBB       = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   hATR      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hADX==INVALID_HANDLE || hEMAfast==INVALID_HANDLE || hEMAslow==INVALID_HANDLE ||
      hEMAfilter==INVALID_HANDLE || hRSI==INVALID_HANDLE || hBB==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("خطأ: فشل تحميل أحد المؤشرات");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   Print("AdaptiveScanner_EA بدأ الشغل على ", _Symbol, " فريم: ", EnumToString(PERIOD_CURRENT));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hADX);
   IndicatorRelease(hEMAfast);
   IndicatorRelease(hEMAslow);
   IndicatorRelease(hEMAfilter);
   IndicatorRelease(hRSI);
   IndicatorRelease(hBB);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| هل عندنا صفقة مفتوحة حالياً بهالـ Magic؟ (صفقة وحدة بالمرة فقط)   |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol)
            return true;
        }
     }
   return false;
}

//+------------------------------------------------------------------+
//| Trailing Stop: يحرك SL مع الربح تدريجياً، مبني على ATR             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!UseTrailingStop) return;

   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(hATR, 0, 0, 1, atrBuf) <= 0) continue;
      double atrNow = atrBuf[0];

      long posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      double startDistance = atrNow * TrailingStart_ATR;
      double stepDistance   = atrNow * TrailingStep_ATR;

      if(posType == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDistance = bid - openPrice;
         if(profitDistance >= startDistance)
           {
            double newSL = NormalizeDouble(bid - stepDistance, digits);
            if(newSL > currentSL) // بس نحرك SL لفوق، ما نرجعه أبداً
               trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDistance = openPrice - ask;
         if(profitDistance >= startDistance)
           {
            double newSL = NormalizeDouble(ask + stepDistance, digits);
            if(newSL < currentSL || currentSL == 0) // بس نحرك SL لتحت، ما نرجعه أبداً
               trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
}

//+------------------------------------------------------------------+
//| قراءة المؤشرات لآخر شمعة مغلقة (index = 1)                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // شمعة جديدة فقط (نتجنب الفحص كل تك، نفحص عند إغلاق كل شمعة)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // ================= إدارة Trailing Stop للصفقة المفتوحة (لو موجودة) =================
   ManageTrailingStop();

   if(HasOpenPosition()) return; // صفقة وحدة بالمرة، ننتظر تسكر قبل ندخل ثانية

   // ================= فلتر ساعات التداول =================
   if(UseTradingHours)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < TradingHourStart || dt.hour >= TradingHourEnd)
        {
         Comment("AdaptiveScanner: خارج ساعات التداول المسموحة (", TradingHourStart, ":00 - ", TradingHourEnd, ":00)");
         return;
        }
     }

   // ================= فلتر السبريد =================
   if(UseSpreadFilter)
     {
      double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(currentSpread > MaxSpreadPoints)
        {
         Comment("AdaptiveScanner: السبريد اتسع (", DoubleToString(currentSpread,1), " نقطة) - ننتظر يرجع طبيعي");
         return;
        }
     }

   double adx[], emaFast[], emaSlow[], emaFilter[], rsi[], bbUpper[], bbLower[], bbMid[], atr[];
   ArraySetAsSeries(adx,true); ArraySetAsSeries(emaFast,true); ArraySetAsSeries(emaSlow,true);
   ArraySetAsSeries(emaFilter,true); ArraySetAsSeries(rsi,true);
   ArraySetAsSeries(bbUpper,true); ArraySetAsSeries(bbLower,true); ArraySetAsSeries(bbMid,true);
   ArraySetAsSeries(atr,true);

   if(CopyBuffer(hADX, 0, 1, 3, adx) <= 0) return;
   if(CopyBuffer(hEMAfast, 0, 1, 3, emaFast) <= 0) return;
   if(CopyBuffer(hEMAslow, 0, 1, 3, emaSlow) <= 0) return;
   if(CopyBuffer(hEMAfilter, 0, 1, 3, emaFilter) <= 0) return;
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) <= 0) return;
   if(CopyBuffer(hBB, 1, 1, 3, bbUpper) <= 0) return;  // upper band buffer
   if(CopyBuffer(hBB, 2, 1, 3, bbLower) <= 0) return;  // lower band buffer
   if(CopyBuffer(hATR, 0, 1, 3, atr) <= 0) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double atrValue = atr[0];

   // ================= خطوة 1: فحص حالة السوق =================
   string marketState = "";
   if(adx[0] >= ADX_TrendLevel)
      marketState = "TREND";
   else if(adx[0] <= ADX_RangeLevel)
      marketState = "RANGE";
   else
      marketState = "UNCLEAR"; // منطقة رمادية، ننتظر

   if(marketState == "UNCLEAR")
     {
      Comment("AdaptiveScanner: السوق غير واضح (ADX=", DoubleToString(adx[0],1), ") - ننتظر");
      return;
     }

   int signal = 0;      // 1 = شراء، -1 = بيع، 0 = لا شي
   int confluence = 0;  // عدد التأكيدات (يحدد حجم اللوت)
   string usedStrategy = "";

   // ================= خطوة 2أ: استراتيجية الاتجاه =================
   if(marketState == "TREND")
     {
      usedStrategy = "اتباع الاتجاه (EMA Crossover)";
      bool crossUp   = (emaFast[1] <= emaSlow[1] && emaFast[0] > emaSlow[0]);
      bool crossDown = (emaFast[1] >= emaSlow[1] && emaFast[0] < emaSlow[0]);

      if(crossUp && close1 > emaFilter[0])
        {
         signal = 1;
         confluence = 1;
         if(adx[0] > ADX_TrendLevel + 10) confluence++;      // اتجاه قوي جداً
         if(rsi[0] > 50 && rsi[0] < 70) confluence++;        // RSI يدعم الشراء بدون تشبع
        }
      else if(crossDown && close1 < emaFilter[0])
        {
         signal = -1;
         confluence = 1;
         if(adx[0] > ADX_TrendLevel + 10) confluence++;
         if(rsi[0] < 50 && rsi[0] > 30) confluence++;
        }
     }

   // ================= خطوة 2ب: استراتيجية الارتداد =================
   if(marketState == "RANGE")
     {
      usedStrategy = "الارتداد من الأطراف (RSI + Bollinger)";
      bool touchLower = (close1 <= bbLower[0]);
      bool touchUpper = (close1 >= bbUpper[0]);

      if(touchLower && rsi[0] <= RSI_Oversold)
        {
         signal = 1;
         confluence = 1;
         if(rsi[0] < RSI_Oversold - 5) confluence++;         // تشبع بيعي قوي
         if(close1 < emaFilter[0]) confluence++;              // ملاحظة: ارتداد مضاد للاتجاه العام، تأكيد إضافي حذر
        }
      else if(touchUpper && rsi[0] >= RSI_Overbought)
        {
         signal = -1;
         confluence = 1;
         if(rsi[0] > RSI_Overbought + 5) confluence++;
         if(close1 > emaFilter[0]) confluence++;
        }
     }

   if(signal == 0)
     {
      Comment("AdaptiveScanner: حالة السوق = ", marketState, " | لا توجد إشارة دخول حالياً");
      return;
     }

   // ================= خطوة 3: حساب حجم اللوت حسب قوة التأكيد =================
   double lot = LotStart;
   if(confluence == 2) lot = LotStart + (LotMax - LotStart) * 0.5;  // نص المسافة
   if(confluence >= 3) lot = LotMax;                                 // أقصى تأكيد = أقصى لوت
   lot = NormalizeDouble(lot, 2);

   // ================= خطوة 4: حساب SL/TP بناءً على ATR =================
   double slDistance = atrValue * ATR_Multiplier_SL;
   double tpDistance = atrValue * ATR_Multiplier_TP;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl, tp, entryPrice;

   if(signal == 1)
     {
      entryPrice = ask;
      sl = NormalizeDouble(entryPrice - slDistance, digits);
      tp = NormalizeDouble(entryPrice + tpDistance, digits);
      trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment + " | " + usedStrategy);
      Print("شراء | ", usedStrategy, " | لوت: ", lot, " | تأكيدات: ", confluence, " | SL: ", sl, " | TP: ", tp);
     }
   else if(signal == -1)
     {
      entryPrice = bid;
      sl = NormalizeDouble(entryPrice + slDistance, digits);
      tp = NormalizeDouble(entryPrice - tpDistance, digits);
      trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment + " | " + usedStrategy);
      Print("بيع | ", usedStrategy, " | لوت: ", lot, " | تأكيدات: ", confluence, " | SL: ", sl, " | TP: ", tp);
     }

   Comment("AdaptiveScanner: تم فتح صفقة | ", usedStrategy, " | حالة السوق: ", marketState);
}
//+------------------------------------------------------------------+
