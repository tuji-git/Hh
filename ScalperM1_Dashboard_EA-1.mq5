//+------------------------------------------------------------------+
//|                                  ScalperM1_Dashboard_EA.mq5        |
//|  بوت سكالب سريع + شاشة عرض سوداء بالشارت                          |
//|  فريم M1 - مصمم للذهب والبيتكوين - بدون مارتينجال                 |
//+------------------------------------------------------------------+
#property copyright "Built with the user - fully transparent, no hidden logic"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//---------------------------- إعدادات عامة ----------------------------
input group "=== إعدادات عامة ==="
input int      MagicNumber        = 202608;
input string   TradeComment       = "ScalperM1";

//---------------------------- الاستراتيجية ----------------------------
input group "=== إشارة الدخول ==="
input int      EMA_Fast           = 5;
input int      EMA_Slow           = 13;
input int      RSI_Period         = 7;
input double   RSI_MidLevel       = 50.0;

//---------------------------- إدارة المخاطر ----------------------------
input group "=== إدارة المخاطر (بدون مارتينجال) ==="
input double   LotStart           = 0.01;
input double   LotMax             = 0.04;
input int      ATR_Period         = 14;
input double   ATR_Multiplier_SL  = 1.0;
input double   ATR_Multiplier_TP  = 1.5;

//---------------------------- فلتر السبريد ----------------------------
input group "=== فلتر السبريد ==="
input bool     UseSpreadFilter      = true;
input double   MaxSpreadPoints_Gold = 350;
input double   MaxSpreadPoints_BTC  = 5000;
input string   BTC_SymbolHint       = "BTC";

//---------------------------- تحكم بالتكرار ----------------------------
input group "=== تحكم بالتكرار ==="
input int      MinBarsBetweenTrades = 3;
input int      MaxTradesPerDay       = 15;

//---------------------------- ساعات التداول ----------------------------
input group "=== فلتر ساعات التداول ==="
input bool     UseTradingHours    = false;
input int      TradingHourStart   = 8;
input int      TradingHourEnd     = 22;

//---------------------------- Trailing Stop ----------------------------
input group "=== Trailing Stop ==="
input bool     UseTrailingStop    = true;
input double   TrailingStart_ATR  = 0.7;
input double   TrailingStep_ATR   = 0.3;

//---------------------------- شاشة العرض ----------------------------
input group "=== شاشة العرض (Dashboard) ==="
input bool     ShowDashboard      = true;
input int      Dashboard_X        = 15;    // موضع أفقي
input int      Dashboard_Y        = 25;    // موضع رأسي
input int      Dashboard_Width    = 300;
input color    Dashboard_BGColor  = clrBlack;
input color    Dashboard_ProfitColor = clrLimeGreen;
input color    Dashboard_LossColor   = clrOrangeRed;
input color    Dashboard_TextColor   = clrWhiteSmoke;
input bool     ShowNewsAlert      = true;   // عرض أقرب خبر اقتصادي مهم

//---------------------------- متغيرات داخلية ----------------------------
int hEMAfast, hEMAslow, hRSI, hATR;
int barsSinceLastTrade = 999;
int tradesToday = 0;
datetime currentDayStart = 0;
string PREFIX = "SCALP_DASH_";

//+------------------------------------------------------------------+
int OnInit()
{
   hEMAfast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(hEMAfast==INVALID_HANDLE || hEMAslow==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("خطأ: فشل تحميل أحد المؤشرات");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   ResetDailyCounterIfNeeded();
   EventSetTimer(1); // تحديث الشاشة كل ثانية
   Print("ScalperM1_Dashboard_EA بدأ الشغل على ", _Symbol, " فريم: ", EnumToString(PERIOD_CURRENT));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEMAfast);
   IndicatorRelease(hEMAslow);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
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
   if(StringFind(_Symbol, BTC_SymbolHint) >= 0)
      return MaxSpreadPoints_BTC;
   return MaxSpreadPoints_Gold;
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
         double profitDistance = bid - openPrice;
         if(profitDistance >= startDistance)
           {
            double newSL = NormalizeDouble(bid - stepDistance, digits);
            if(newSL > currentSL) trade.PositionModify(ticket, newSL, currentTP);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDistance = openPrice - ask;
         if(profitDistance >= startDistance)
           {
            double newSL = NormalizeDouble(ask + stepDistance, digits);
            if(newSL < currentSL || currentSL == 0) trade.PositionModify(ticket, newSL, currentTP);
           }
        }
     }
}

//+------------------------------------------------------------------+
void ResetDailyCounterIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);
   if(todayStart != currentDayStart)
     {
      currentDayStart = todayStart;
      tradesToday = 0;
     }
}

//+------------------------------------------------------------------+
//| ربح/خسارة اليوم المُقفلة (Realized) - من سجل الصفقات               |
//+------------------------------------------------------------------+
double CalculateTodayRealizedPL()
{
   double profit = 0;
   if(!HistorySelect(currentDayStart, TimeCurrent())) return 0;
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
        {
         profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        }
     }
   return profit;
}

//+------------------------------------------------------------------+
//| ربح/خسارة الصفقة المفتوحة حالياً (Floating)                       |
//+------------------------------------------------------------------+
double CalculateFloatingPL()
{
   double profit = 0;
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol)
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
     }
   return profit;
}

//+------------------------------------------------------------------+
//| أقرب خبر اقتصادي مهم من تقويم MT5 (لعملة الرمز الأساسية/المقابلة) |
//+------------------------------------------------------------------+
string GetNextHighImpactNews()
{
   string baseCur  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quoteCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   MqlCalendarValue values[];
   datetime from = TimeCurrent();
   datetime to   = from + 3*24*3600; // ثلاث أيام قدام
   int total = CalendarValueHistory(values, from, to, "", "");
   if(total <= 0) return "لا يوجد اتصال بتقويم الأخبار";

   datetime nearestTime = 0;
   string nearestName = "";
   string nearestCur  = "";

   for(int i=0; i<total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id, country)) continue;
      if(country.currency != baseCur && country.currency != quoteCur) continue;

      if(nearestTime == 0 || values[i].time < nearestTime)
        {
         nearestTime = values[i].time;
         nearestName = ev.name;
         nearestCur  = country.currency;
        }
     }

   if(nearestTime == 0) return "لا أخبار مهمة قريبة (" + baseCur + "/" + quoteCur + ")";

   long secondsLeft = (long)(nearestTime - TimeCurrent());
   if(secondsLeft < 0) secondsLeft = 0;
   long hoursLeft = secondsLeft / 3600;
   long minsLeft  = (secondsLeft % 3600) / 60;

   return nearestCur + ": " + nearestName + " خلال " + (string)hoursLeft + "س " + (string)minsLeft + "د";
}

//+------------------------------------------------------------------+
//| رسم/تحديث عنصر نصي بالشاشة                                        |
//+------------------------------------------------------------------+
void DrawLabel(string name, string text, int x, int y, color clr, int fontSize=9)
{
   string fullName = PREFIX + name;
   if(ObjectFind(0, fullName) < 0)
     {
      ObjectCreate(0, fullName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, fullName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, fullName, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, fullName, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, fullName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, fullName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, fullName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, fullName, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, fullName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, fullName, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| رسم/تحديث الخلفية السوداء                                          |
//+------------------------------------------------------------------+
void DrawBackground(int height)
{
   string bgName = PREFIX + "BG";
   if(ObjectFind(0, bgName) < 0)
     {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, Dashboard_X - 10);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, Dashboard_Y - 10);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, Dashboard_Width);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bgName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, bgName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, Dashboard_BGColor);
}

//+------------------------------------------------------------------+
//| بناء الشاشة كاملة                                                  |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   if(!ShowDashboard) return;

   double realizedPL = CalculateTodayRealizedPL();
   double floatingPL = CalculateFloatingPL();
   double totalTodayPL = realizedPL + floatingPL;

   int lineHeight = 18;
   int y = Dashboard_Y;
   int lineCount = ShowNewsAlert ? 8 : 7;
   DrawBackground(lineCount * lineHeight + 20);

   DrawLabel("Title", "🔥 SCALPER M1 DASHBOARD", Dashboard_X, y, clrGold, 10); y += lineHeight + 4;
   DrawLabel("Symbol", "الرمز: " + _Symbol + "   |   الحالة: " + (HasOpenPosition() ? "في صفقة" : "بانتظار إشارة"),
             Dashboard_X, y, Dashboard_TextColor); y += lineHeight;

   color realizedColor = (realizedPL >= 0) ? Dashboard_ProfitColor : Dashboard_LossColor;
   DrawLabel("Realized", "ربح/خسارة اليوم (مقفولة): " + DoubleToString(realizedPL, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY),
             Dashboard_X, y, realizedColor); y += lineHeight;

   color floatColor = (floatingPL >= 0) ? Dashboard_ProfitColor : Dashboard_LossColor;
   DrawLabel("Floating", "ربح/خسارة عائمة الآن: " + DoubleToString(floatingPL, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY),
             Dashboard_X, y, floatColor); y += lineHeight;

   color totalColor = (totalTodayPL >= 0) ? Dashboard_ProfitColor : Dashboard_LossColor;
   DrawLabel("Total", "إجمالي اليوم: " + DoubleToString(totalTodayPL, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY),
             Dashboard_X, y, totalColor, 10); y += lineHeight + 2;

   DrawLabel("Trades", "صفقات اليوم: " + (string)tradesToday + " / " + (string)MaxTradesPerDay,
             Dashboard_X, y, Dashboard_TextColor); y += lineHeight;

   DrawLabel("Balance", "الرصيد: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
             "   الإيكويتي: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             Dashboard_X, y, Dashboard_TextColor); y += lineHeight;

   if(ShowNewsAlert)
     {
      static string cachedNews = "";
      static datetime lastNewsCheck = 0;
      if(TimeCurrent() - lastNewsCheck > 60 || cachedNews == "") // نحدّث الأخبار كل دقيقة بس (ما نبطئ الشاشة)
        {
         cachedNews = GetNextHighImpactNews();
         lastNewsCheck = TimeCurrent();
        }
      DrawLabel("News", "📰 " + cachedNews, Dashboard_X, y, clrOrange, 9);
     }
}

//+------------------------------------------------------------------+
void OnTimer()
{
   DrawDashboard();
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
   ResetDailyCounterIfNeeded();

   if(HasOpenPosition()) return;

   if(tradesToday >= MaxTradesPerDay) return;
   if(barsSinceLastTrade < MinBarsBetweenTrades) return;

   if(UseTradingHours)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < TradingHourStart || dt.hour >= TradingHourEnd) return;
     }

   if(UseSpreadFilter)
     {
      double currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(currentSpread > GetMaxSpreadForSymbol()) return;
     }

   double emaFast[], emaSlow[], rsi[], atr[];
   ArraySetAsSeries(emaFast,true); ArraySetAsSeries(emaSlow,true);
   ArraySetAsSeries(rsi,true); ArraySetAsSeries(atr,true);

   if(CopyBuffer(hEMAfast, 0, 1, 3, emaFast) <= 0) return;
   if(CopyBuffer(hEMAslow, 0, 1, 3, emaSlow) <= 0) return;
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) <= 0) return;
   if(CopyBuffer(hATR, 0, 1, 3, atr) <= 0) return;

   double atrValue = atr[0];

   bool crossUp   = (emaFast[1] <= emaSlow[1] && emaFast[0] > emaSlow[0]);
   bool crossDown = (emaFast[1] >= emaSlow[1] && emaFast[0] < emaSlow[0]);

   int signal = 0;
   int confluence = 0;

   if(crossUp && rsi[0] > RSI_MidLevel)
     {
      signal = 1; confluence = 1;
      if(rsi[0] > RSI_MidLevel + 10) confluence++;
      if(emaFast[0] - emaSlow[0] > atrValue*0.3) confluence++;
     }
   else if(crossDown && rsi[0] < RSI_MidLevel)
     {
      signal = -1; confluence = 1;
      if(rsi[0] < RSI_MidLevel - 10) confluence++;
      if(emaSlow[0] - emaFast[0] > atrValue*0.3) confluence++;
     }

   if(signal == 0) return;

   double lot = LotStart;
   if(confluence == 2) lot = LotStart + (LotMax - LotStart) * 0.5;
   if(confluence >= 3) lot = LotMax;
   lot = NormalizeDouble(lot, 2);

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
     }
   else if(signal == -1)
     {
      sl = NormalizeDouble(bid + slDistance, digits);
      tp = NormalizeDouble(bid - tpDistance, digits);
      opened = trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment);
     }

   if(opened)
     {
      barsSinceLastTrade = 0;
      tradesToday++;
     }
}
//+------------------------------------------------------------------+
