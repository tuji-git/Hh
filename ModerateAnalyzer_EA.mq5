//+------------------------------------------------------------------+
//|                                       ModerateAnalyzer_EA.mq5      |
//|  بوت معتدل - فريم M5 - تحليل حقيقي متعدد المؤشرات                 |
//|  هدف: 50-80 صفقة يومياً بجودة عالية - بدون مارتينجال              |
//+------------------------------------------------------------------+
#property copyright "Built with the user - fully transparent, no hidden logic"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//---------------------------- إعدادات عامة ----------------------------
input group "=== إعدادات عامة ==="
input int      MagicNumber        = 202609;
input string   TradeComment       = "ModerateAnalyzer";

//---------------------------- التحليل (3 تأكيدات حقيقية) ----------------------------
input group "=== الإشارة: EMA + RSI + MACD ==="
input int      EMA_Fast           = 8;
input int      EMA_Slow           = 21;
input int      RSI_Period         = 10;
input double   RSI_MidLevel       = 50.0;
input int      MACD_Fast          = 12;
input int      MACD_Slow          = 26;
input int      MACD_Signal        = 9;
input int      MinConfirmations   = 2;    // أقل عدد تأكيدات مطلوبة (من أصل 3) للدخول

//---------------------------- إدارة المخاطر ----------------------------
input group "=== إدارة المخاطر (بدون مارتينجال) ==="
input double   LotStart           = 0.01;
input double   LotMax             = 0.04;
input int      ATR_Period         = 14;
input double   ATR_Multiplier_SL  = 1.5;
input double   ATR_Multiplier_TP  = 2.2;

//---------------------------- فلتر السبريد ----------------------------
input group "=== فلتر السبريد ==="
input bool     UseSpreadFilter      = true;
input double   MaxSpreadPoints_Gold = 350;
input double   MaxSpreadPoints_BTC  = 5000;
input double   MaxSpreadPoints_Other= 20;
input string   BTC_SymbolHint       = "BTC";

//---------------------------- تحكم بالتكرار ----------------------------
input group "=== تحكم بالتكرار (يستهدف 50-80 صفقة/يوم) ==="
input int      MinBarsBetweenTrades = 1;    // أقل عدد شموع ننتظرها بين صفقة وأخرى
input int      MaxTradesPerDay       = 80;  // الحد الأعلى (حماية من الإفراط)

//---------------------------- حماية يومية (موصى بها بقوة) ----------------------------
input group "=== حد الخسارة اليومي (حماية أساسية) ==="
input bool     UseDailyLossLimit   = true;
input double   MaxDailyLossPercent = 5.0;   // يوقف الصفقات الجديدة لو خسر الحساب هالنسبة باليوم

//---------------------------- Trailing Stop ----------------------------
input group "=== Trailing Stop ==="
input bool     UseTrailingStop    = true;
input double   TrailingStart_ATR  = 1.2;
input double   TrailingStep_ATR   = 0.5;

//---------------------------- متغيرات داخلية ----------------------------
int hEMAfast, hEMAslow, hRSI, hMACD, hATR;
int barsSinceLastTrade = 999;
int tradesToday = 0;
datetime currentDayStart = 0;
double dayStartBalance = 0;
bool dailyLossHit = false;

//+------------------------------------------------------------------+
int OnInit()
{
   hEMAfast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hMACD    = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hEMAfast==INVALID_HANDLE || hEMAslow==INVALID_HANDLE || hRSI==INVALID_HANDLE ||
      hMACD==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("خطأ: فشل تحميل أحد المؤشرات");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   ResetDailyStateIfNeeded();
   Print("ModerateAnalyzer_EA بدأ الشغل على ", _Symbol, " فريم: ", EnumToString(PERIOD_CURRENT));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEMAfast);
   IndicatorRelease(hEMAslow);
   IndicatorRelease(hRSI);
   IndicatorRelease(hMACD);
   IndicatorRelease(hATR);
}

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
double GetMaxSpreadForSymbol()
{
   if(StringFind(_Symbol, BTC_SymbolHint) >= 0) return MaxSpreadPoints_BTC;
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0) return MaxSpreadPoints_Gold;
   return MaxSpreadPoints_Other;
}

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
         if(bid - openPrice >= startDistance)
           {
            double newSL = NormalizeDouble(bid - stepDistance, digits);
            if(newSL > currentSL) trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask >= startDistance)
           {
            double newSL = NormalizeDouble(ask + stepDistance, digits);
            if(newSL < currentSL || currentSL == 0) trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
}

//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);
   if(todayStart != currentDayStart)
     {
      currentDayStart  = todayStart;
      tradesToday      = 0;
      dayStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyLossHit     = false;
     }
}

//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
   if(!UseDailyLossLimit) return false;
   if(dayStartBalance <= 0) return false;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dayStartBalance - currentEquity) / dayStartBalance * 100.0;
   if(lossPercent >= MaxDailyLossPercent)
     {
      if(!dailyLossHit)
        {
         Print("⚠️ تم الوصول لحد الخسارة اليومي (", DoubleToString(lossPercent,2), "%) - إيقاف صفقات جديدة لباقي اليوم");
         dailyLossHit = true;
        }
      return true;
     }
   return false;
}

//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   if(isNewBar)
     {
      lastBarTime = currentBarTime;
      if(barsSinceLastTrade < 999) barsSinceLastTrade++;
     }

   ManageTrailingStop();

   if(!isNewBar) return;
   ResetDailyStateIfNeeded();

   if(HasOpenPosition()) return;
   if(tradesToday >= MaxTradesPerDay) return;
   if(barsSinceLastTrade < MinBarsBetweenTrades) return;
   if(CheckDailyLossLimit()) return;

   if(UseSpreadFilter)
     {
      double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(currentSpread > GetMaxSpreadForSymbol()) return;
     }

   // ================= قراءة المؤشرات (3 مصادر تحليل مستقلة) =================
   double emaFast[], emaSlow[], rsi[], macdMain[], macdSignal[], atr[];
   ArraySetAsSeries(emaFast,true); ArraySetAsSeries(emaSlow,true); ArraySetAsSeries(rsi,true);
   ArraySetAsSeries(macdMain,true); ArraySetAsSeries(macdSignal,true); ArraySetAsSeries(atr,true);

   if(CopyBuffer(hEMAfast, 0, 1, 3, emaFast) <= 0) return;
   if(CopyBuffer(hEMAslow, 0, 1, 3, emaSlow) <= 0) return;
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) <= 0) return;
   if(CopyBuffer(hMACD, 0, 1, 3, macdMain) <= 0) return;   // خط MACD
   if(CopyBuffer(hMACD, 1, 1, 3, macdSignal) <= 0) return; // خط الإشارة
   if(CopyBuffer(hATR, 0, 1, 3, atr) <= 0) return;

   double atrValue = atr[0];

   // ================= 3 تأكيدات مستقلة لكل اتجاه =================
   int bullConfirms = 0, bearConfirms = 0;

   // تأكيد 1: تقاطع أو ترتيب EMA
   if(emaFast[0] > emaSlow[0]) bullConfirms++;
   else if(emaFast[0] < emaSlow[0]) bearConfirms++;

   // تأكيد 2: زخم RSI
   if(rsi[0] > RSI_MidLevel) bullConfirms++;
   else if(rsi[0] < RSI_MidLevel) bearConfirms++;

   // تأكيد 3: هيستوجرام MACD (خط الماكد فوق/تحت خط الإشارة)
   if(macdMain[0] > macdSignal[0]) bullConfirms++;
   else if(macdMain[0] < macdSignal[0]) bearConfirms++;

   // ================= شرط الدخول الفعلي: لازم يكون فيه تغيّر (تقاطع جديد) مو بس حالة ثابتة =================
   bool freshBullCross = (emaFast[1] <= emaSlow[1] && emaFast[0] > emaSlow[0]) ||
                          (macdMain[1] <= macdSignal[1] && macdMain[0] > macdSignal[0]);
   bool freshBearCross = (emaFast[1] >= emaSlow[1] && emaFast[0] < emaSlow[0]) ||
                          (macdMain[1] >= macdSignal[1] && macdMain[0] < macdSignal[0]);

   int signal = 0;
   int confluence = 0;

   if(freshBullCross && bullConfirms >= MinConfirmations)
     {
      signal = 1;
      confluence = bullConfirms;
     }
   else if(freshBearCross && bearConfirms >= MinConfirmations)
     {
      signal = -1;
      confluence = bearConfirms;
     }

   if(signal == 0) return; // ما فيه إشارة جديدة نظيفة هالشمعة

   // ================= حجم اللوت حسب قوة التأكيد (بدون مارتينجال) =================
   double lot = LotStart;
   if(confluence == 2) lot = LotStart + (LotMax - LotStart) * 0.5;
   if(confluence >= 3) lot = LotMax;
   lot = NormalizeDouble(lot, 2);

   // ================= SL/TP معتدلين =================
   double slDistance = atrValue * ATR_Multiplier_SL;
   double tpDistance = atrValue * ATR_Multiplier_TP;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl, tp;
   bool opened = false;

   if(signal == 1)
     {
      sl = NormalizeDouble(ask - slDistance, digits);
      tp = NormalizeDouble(ask + tpDistance, digits);
      opened = trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment);
      if(opened) Print("شراء | تأكيدات: ", confluence, "/3 | لوت: ", lot, " | صفقة رقم ", tradesToday+1, " اليوم");
     }
   else if(signal == -1)
     {
      sl = NormalizeDouble(bid + slDistance, digits);
      tp = NormalizeDouble(bid - tpDistance, digits);
      opened = trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment);
      if(opened) Print("بيع | تأكيدات: ", confluence, "/3 | لوت: ", lot, " | صفقة رقم ", tradesToday+1, " اليوم");
     }

   if(opened)
     {
      barsSinceLastTrade = 0;
      tradesToday++;
     }
}
//+------------------------------------------------------------------+
