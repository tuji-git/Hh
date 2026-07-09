//+------------------------------------------------------------------+
//|                                    TelegramNotifier_EA.mq5         |
//|  بوت إشعارات فقط - ما يفتح ولا يقفل أي صفقة                        |
//|  يراقب حسابك ويرسل إشعارات تليجرام مع أزرار تحكم                  |
//+------------------------------------------------------------------+
#property copyright "Built with the user - fully transparent, no hidden logic"
#property version   "1.00"
#property strict

//---------------------------- إعدادات تليجرام ----------------------------
input group "=== إعدادات تليجرام ==="
input string   BotToken           = "8797767210:AAGPWz7AH_H6V9XqLyjisHn9q_DggUnFY-4";
input string   ChatID             = "6603754497";
input int      PollingSeconds     = 5;     // كل كم ثانية نتحقق من ضغطات الأزرار

//---------------------------- تفعيل/تعطيل افتراضي (يتغيّر لاحقاً بالأزرار) ----------------------------
input group "=== افتراضي عند أول تشغيل ==="
input bool     Default_TradeOpen    = true;   // 1. إشعار فتح صفقة
input bool     Default_TradeClose   = true;   // 2. إشعار إغلاق صفقة
input bool     Default_ShowBalance  = true;   // 3. عرض الرصيد مع كل إشعار
input bool     Default_DailyReport  = true;   // 4. تقرير يومي
input bool     Default_WeeklyReport = true;   // 5. تقرير أسبوعي
input bool     Default_Connection   = true;   // 11. تنبيه انقطاع الاتصال
input bool     Default_News         = true;   // 12. تنبيه الأخبار المهمة

//---------------------------- عتبات الإيموجي (ميزة 13) ----------------------------
input group "=== عتبات الإيموجي حسب حجم الربح/الخسارة ==="
input double   BigProfitThreshold = 10.0;   // فوق هالرقم = ربح كبير 🎉
input double   BigLossThreshold   = -10.0;  // تحت هالرقم = خسارة كبيرة 🚨

//---------------------------- متغيرات داخلية ----------------------------
bool   Notify_TradeOpen, Notify_TradeClose, Notify_ShowBalance;
bool   Notify_DailyReport, Notify_WeeklyReport, Notify_Connection, Notify_News;
long   lastUpdateId = 0;
bool   lastConnectionState = true;
datetime currentDayStart = 0, currentWeekStart = 0;
double dayStartBalanceForReport = 0;
ulong  lastAlertedNewsEventId = 0;
string GV_PREFIX = "TGNOTIFY_";

//+------------------------------------------------------------------+
int OnInit()
{
   LoadPreferences();
   lastConnectionState = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   currentDayStart = StructToTime(dt);
   dayStartBalanceForReport = AccountInfoDouble(ACCOUNT_BALANCE);

   MqlDateTime wdt = dt;
   currentWeekStart = currentDayStart - (wdt.day_of_week * 86400); // بداية الأسبوع = الأحد

   EventSetTimer(PollingSeconds);
   TelegramSendMessage("🤖 بوت المراقبة بدأ الشغل\nالحساب: " + (string)AccountInfoInteger(ACCOUNT_LOGIN) +
                        "\nالرصيد الحالي: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY),
                        BuildControlPanel());
   Print("TelegramNotifier_EA بدأ الشغل");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| حفظ/تحميل التفضيلات (تبقى محفوظة حتى لو أعدت تشغيل MT5)            |
//+------------------------------------------------------------------+
void LoadPreferences()
{
   Notify_TradeOpen    = GlobalVariableCheck(GV_PREFIX+"OPEN")    ? GlobalVariableGet(GV_PREFIX+"OPEN")>0    : Default_TradeOpen;
   Notify_TradeClose   = GlobalVariableCheck(GV_PREFIX+"CLOSE")   ? GlobalVariableGet(GV_PREFIX+"CLOSE")>0   : Default_TradeClose;
   Notify_ShowBalance  = GlobalVariableCheck(GV_PREFIX+"BAL")     ? GlobalVariableGet(GV_PREFIX+"BAL")>0     : Default_ShowBalance;
   Notify_DailyReport  = GlobalVariableCheck(GV_PREFIX+"DAILY")   ? GlobalVariableGet(GV_PREFIX+"DAILY")>0   : Default_DailyReport;
   Notify_WeeklyReport = GlobalVariableCheck(GV_PREFIX+"WEEKLY")  ? GlobalVariableGet(GV_PREFIX+"WEEKLY")>0  : Default_WeeklyReport;
   Notify_Connection   = GlobalVariableCheck(GV_PREFIX+"CONN")    ? GlobalVariableGet(GV_PREFIX+"CONN")>0    : Default_Connection;
   Notify_News         = GlobalVariableCheck(GV_PREFIX+"NEWS")    ? GlobalVariableGet(GV_PREFIX+"NEWS")>0    : Default_News;
}

void SavePreferences()
{
   GlobalVariableSet(GV_PREFIX+"OPEN",    Notify_TradeOpen?1:0);
   GlobalVariableSet(GV_PREFIX+"CLOSE",   Notify_TradeClose?1:0);
   GlobalVariableSet(GV_PREFIX+"BAL",     Notify_ShowBalance?1:0);
   GlobalVariableSet(GV_PREFIX+"DAILY",   Notify_DailyReport?1:0);
   GlobalVariableSet(GV_PREFIX+"WEEKLY",  Notify_WeeklyReport?1:0);
   GlobalVariableSet(GV_PREFIX+"CONN",    Notify_Connection?1:0);
   GlobalVariableSet(GV_PREFIX+"NEWS",    Notify_News?1:0);
}

//+------------------------------------------------------------------+
//| إرسال رسالة تليجرام (مع لوحة أزرار اختيارية)                       |
//+------------------------------------------------------------------+
bool TelegramSendMessage(string text, string replyMarkupJson="")
{
   string url = "https://api.telegram.org/bot" + BotToken + "/sendMessage";
   string json = "{\"chat_id\":\"" + ChatID + "\",\"text\":\"" + EscapeJson(text) + "\"";
   if(replyMarkupJson != "") json += ",\"reply_markup\":" + replyMarkupJson;
   json += "}";

   char post[];
   int len = StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(post, len);

   char result[];
   string result_headers;
   ResetLastError();
   int res = WebRequest("POST", url, "Content-Type: application/json\r\n", 5000, post, result, result_headers);
   if(res == -1)
     {
      int err = GetLastError();
      Print("⚠️ خطأ إرسال تليجرام: ", err, " - تأكد من إضافة https://api.telegram.org بقائمة Allow WebRequest (Tools > Options > Expert Advisors)");
      return false;
     }
   return true;
}

//+------------------------------------------------------------------+
void TelegramAnswerCallback(string callbackId)
{
   string url = "https://api.telegram.org/bot" + BotToken + "/answerCallbackQuery";
   string json = "{\"callback_query_id\":\"" + callbackId + "\",\"text\":\"تم ✅\"}";
   char post[];
   int len = StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   ArrayResize(post, len);
   char result[]; string result_headers;
   WebRequest("POST", url, "Content-Type: application/json\r\n", 5000, post, result, result_headers);
}

//+------------------------------------------------------------------+
string EscapeJson(string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   return r;
}

//+------------------------------------------------------------------+
string JsonExtractString(string json, string key)
{
   string search = "\"" + key + "\":\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";
   pos += StringLen(search);
   int endPos = StringFind(json, "\"", pos);
   if(endPos < 0) return "";
   return StringSubstr(json, pos, endPos - pos);
}

//+------------------------------------------------------------------+
long JsonExtractInt(string json, string key)
{
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0) return -1;
   pos += StringLen(search);
   int endPos = pos;
   int lenj = StringLen(json);
   while(endPos < lenj)
     {
      ushort ch = StringGetCharacter(json, endPos);
      if((ch>='0' && ch<='9')) endPos++;
      else break;
     }
   if(endPos == pos) return -1;
   return (long)StringToInteger(StringSubstr(json, pos, endPos-pos));
}

//+------------------------------------------------------------------+
//| لوحة تحكم الأزرار                                                  |
//+------------------------------------------------------------------+
string ToggleLabel(string prefix, bool state)
{
   return (state ? "🟢 " : "🔴 ") + prefix + (state ? ": مفعّل" : ": متوقف");
}

string BuildControlPanel()
{
   string kb = "{\"inline_keyboard\":[";
   kb += "[{\"text\":\"" + ToggleLabel("1. فتح صفقة", Notify_TradeOpen) + "\",\"callback_data\":\"T_OPEN\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("2. إغلاق صفقة", Notify_TradeClose) + "\",\"callback_data\":\"T_CLOSE\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("3. عرض الرصيد بكل إشعار", Notify_ShowBalance) + "\",\"callback_data\":\"T_BAL\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("4. تقرير يومي", Notify_DailyReport) + "\",\"callback_data\":\"T_DAILY\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("5. تقرير أسبوعي", Notify_WeeklyReport) + "\",\"callback_data\":\"T_WEEKLY\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("11. تنبيه الاتصال", Notify_Connection) + "\",\"callback_data\":\"T_CONN\"}],";
   kb += "[{\"text\":\"" + ToggleLabel("12. تنبيه الأخبار", Notify_News) + "\",\"callback_data\":\"T_NEWS\"}],";
   kb += "[{\"text\":\"📊 اعرض الرصيد الحالي الآن\",\"callback_data\":\"SHOW_BAL\"}],";
   kb += "[{\"text\":\"🔕 إيقاف كل الإشعارات\",\"callback_data\":\"MUTE_ALL\"},{\"text\":\"🔔 تفعيل الكل\",\"callback_data\":\"UNMUTE_ALL\"}]";
   kb += "]}";
   return kb;
}

//+------------------------------------------------------------------+
string BuildBalanceReport()
{
   string txt = "📊 حالة الحساب الآن\n";
   txt += "الرصيد: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   txt += "الإيكويتي: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   txt += "الهامش الحر: " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
   txt += "عدد الصفقات المفتوحة: " + (string)PositionsTotal();
   return txt;
}

//+------------------------------------------------------------------+
//| معالجة ضغطة زر                                                     |
//+------------------------------------------------------------------+
void HandleCallback(string data, string cbId)
{
   string msg = "";
   bool sendPanel = true;

   if(data == "T_OPEN")        { Notify_TradeOpen    = !Notify_TradeOpen;    msg = ToggleLabel("إشعار فتح الصفقات", Notify_TradeOpen); }
   else if(data == "T_CLOSE")  { Notify_TradeClose   = !Notify_TradeClose;   msg = ToggleLabel("إشعار إغلاق الصفقات", Notify_TradeClose); }
   else if(data == "T_BAL")    { Notify_ShowBalance  = !Notify_ShowBalance;  msg = ToggleLabel("عرض الرصيد بكل إشعار", Notify_ShowBalance); }
   else if(data == "T_DAILY")  { Notify_DailyReport  = !Notify_DailyReport;  msg = ToggleLabel("التقرير اليومي", Notify_DailyReport); }
   else if(data == "T_WEEKLY") { Notify_WeeklyReport = !Notify_WeeklyReport; msg = ToggleLabel("التقرير الأسبوعي", Notify_WeeklyReport); }
   else if(data == "T_CONN")   { Notify_Connection   = !Notify_Connection;   msg = ToggleLabel("تنبيه الاتصال", Notify_Connection); }
   else if(data == "T_NEWS")   { Notify_News         = !Notify_News;         msg = ToggleLabel("تنبيه الأخبار", Notify_News); }
   else if(data == "SHOW_BAL") { msg = BuildBalanceReport(); }
   else if(data == "MUTE_ALL")
     {
      Notify_TradeOpen=Notify_TradeClose=Notify_ShowBalance=Notify_DailyReport=Notify_WeeklyReport=Notify_Connection=Notify_News=false;
      msg = "🔕 تم إيقاف كل الإشعارات";
     }
   else if(data == "UNMUTE_ALL")
     {
      Notify_TradeOpen=Notify_TradeClose=Notify_ShowBalance=Notify_DailyReport=Notify_WeeklyReport=Notify_Connection=Notify_News=true;
      msg = "🔔 تم تفعيل كل الإشعارات";
     }
   else { sendPanel = false; }

   SavePreferences();
   TelegramAnswerCallback(cbId);
   if(sendPanel) TelegramSendMessage(msg, BuildControlPanel());
}

//+------------------------------------------------------------------+
//| فحص تحديثات تليجرام (ضغطات الأزرار + أوامر نصية)                   |
//+------------------------------------------------------------------+
void TelegramCheckUpdates()
{
   string url = "https://api.telegram.org/bot" + BotToken + "/getUpdates?offset=" + (string)(lastUpdateId+1) + "&timeout=0";
   char post[]; char result[]; string result_headers;
   ResetLastError();
   int res = WebRequest("GET", url, "", 5000, post, result, result_headers);
   if(res == -1) return; // ما نطبع خطأ هنا كل مرة، فقط بأول رسالة عند الإرسال

   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(response) < 10) return;

   int pos = 0;
   while(true)
     {
      pos = StringFind(response, "\"update_id\":", pos);
      if(pos < 0) break;
      int nextPos = StringFind(response, "\"update_id\":", pos+1);
      string chunk = (nextPos<0) ? StringSubstr(response, pos) : StringSubstr(response, pos, nextPos-pos);

      long updId = JsonExtractInt(chunk, "update_id");
      if(updId > lastUpdateId) lastUpdateId = updId;

      if(StringFind(chunk, "callback_query") >= 0)
        {
         string data = JsonExtractString(chunk, "data");
         string cbId = JsonExtractString(chunk, "id");
         if(data != "" && cbId != "") HandleCallback(data, cbId);
        }
      else
        {
         string txt = JsonExtractString(chunk, "text");
         if(StringFind(txt, "/start") >= 0 || StringFind(txt, "/panel") >= 0)
            TelegramSendMessage("⚙️ لوحة التحكم:", BuildControlPanel());
        }

      if(nextPos < 0) break;
      pos = nextPos;
     }
}

//+------------------------------------------------------------------+
//| أقرب خبر اقتصادي مهم (نفس منطق النسخة السابقة)                     |
//+------------------------------------------------------------------+
void CheckNewsAlert()
{
   if(!Notify_News) return;

   MqlCalendarValue values[];
   datetime from = TimeCurrent();
   datetime to   = from + 3*3600; // خلال 3 ساعات جاية
   int total = CalendarValueHistory(values, from, to, "", "");
   if(total <= 0) return;

   for(int i=0; i<total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      if(values[i].event_id == lastAlertedNewsEventId) continue; // ما نكرر نفس الحدث

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id, country)) continue;

      long minutesLeft = (long)((values[i].time - TimeCurrent()) / 60);
      if(minutesLeft <= 60 && minutesLeft >= 0)
        {
         string msg = "📰 خبر اقتصادي مهم قريب\n" + country.currency + ": " + ev.name + "\nخلال " + (string)minutesLeft + " دقيقة";
         TelegramSendMessage(msg);
         lastAlertedNewsEventId = values[i].event_id;
        }
     }
}

//+------------------------------------------------------------------+
//| تقرير يومي/أسبوعي عند تغيّر اليوم                                   |
//+------------------------------------------------------------------+
void CheckPeriodicReports()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime dayOnly = dt;
   dayOnly.hour=0; dayOnly.min=0; dayOnly.sec=0;
   datetime todayStart = StructToTime(dayOnly);

   if(todayStart != currentDayStart)
     {
      // يوم جديد بدأ - نرسل تقرير عن اليوم اللي راح
      if(Notify_DailyReport)
        {
         double realized = CalculatePeriodRealizedPL(currentDayStart, todayStart);
         int    tradeCount = CalculatePeriodTradeCount(currentDayStart, todayStart);
         string emoji = realized >= BigProfitThreshold ? "🎉" : (realized > 0 ? "👍" : (realized <= BigLossThreshold ? "🚨" : "😐"));
         string msg = "📅 التقرير اليومي\n" + emoji + " صافي الربح/الخسارة: " + DoubleToString(realized,2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
         msg += "\nعدد الصفقات: " + (string)tradeCount;
         if(Notify_ShowBalance) msg += "\nالرصيد الحالي: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
         TelegramSendMessage(msg);
        }

      // تقرير أسبوعي لو اليوم الجديد هو الأحد (بداية أسبوع جديد)
      if(Notify_WeeklyReport && dayOnly.day_of_week == 0 && todayStart != currentWeekStart)
        {
         double realizedWeek = CalculatePeriodRealizedPL(currentWeekStart, todayStart);
         int    tradeCountWeek = CalculatePeriodTradeCount(currentWeekStart, todayStart);
         string msg = "🗓️ التقرير الأسبوعي\nصافي الربح/الخسارة: " + DoubleToString(realizedWeek,2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
         msg += "\nعدد الصفقات: " + (string)tradeCountWeek;
         TelegramSendMessage(msg);
         currentWeekStart = todayStart;
        }

      currentDayStart = todayStart;
      dayStartBalanceForReport = AccountInfoDouble(ACCOUNT_BALANCE);
     }
}

double CalculatePeriodRealizedPL(datetime from, datetime to)
{
   double profit = 0;
   if(!HistorySelect(from, to)) return 0;
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
              + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
              + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
     }
   return profit;
}

int CalculatePeriodTradeCount(datetime from, datetime to)
{
   if(!HistorySelect(from, to)) return 0;
   int total = HistoryDealsTotal();
   int count = 0;
   for(int i=0; i<total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT) count++;
     }
   return count;
}

//+------------------------------------------------------------------+
//| فحص حالة الاتصال (ميزة 11)                                         |
//+------------------------------------------------------------------+
void CheckConnectionStatus()
{
   if(!Notify_Connection) return;
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(connected != lastConnectionState)
     {
      if(!connected) TelegramSendMessage("🚨 انقطع الاتصال بين MT5 والسيرفر!");
      else           TelegramSendMessage("✅ عاد الاتصال بالسيرفر بشكل طبيعي");
      lastConnectionState = connected;
     }
}

//+------------------------------------------------------------------+
//| رصد الصفقات (فتح/إغلاق) - يراقب كل الحساب، بدون تنفيذ أي شي        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   string symbol  = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double volume  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   long dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   double price   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

   if(entryType == DEAL_ENTRY_IN)
     {
      if(!Notify_TradeOpen) return;
      string typeStr = (dealType == DEAL_TYPE_BUY) ? "شراء" : "بيع";
      string msg = "🔵 صفقة جديدة\n" + symbol + " | " + typeStr + " " + DoubleToString(volume,2) + "\nسعر الدخول: " + DoubleToString(price, (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
      if(Notify_ShowBalance) msg += "\nالرصيد الحالي: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
      TelegramSendMessage(msg);
     }
   else if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
     {
      if(!Notify_TradeClose) return;
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      string emoji = profit >= BigProfitThreshold ? "🎉" : (profit > 0 ? "👍" : (profit <= BigLossThreshold ? "🚨" : "😐"));
      string msg = emoji + " صفقة أُغلقت\n" + symbol + "\nالربح/الخسارة: " + DoubleToString(profit,2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
      if(Notify_ShowBalance) msg += "\nالرصيد الحالي: " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
      TelegramSendMessage(msg);
     }
}

//+------------------------------------------------------------------+
void OnTimer()
{
   TelegramCheckUpdates();
   CheckConnectionStatus();
   CheckPeriodicReports();
   CheckNewsAlert();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // ما فيه أي منطق تداول هنا - هذا EA مراقبة وإشعارات فقط
}
//+------------------------------------------------------------------+
