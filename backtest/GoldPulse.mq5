//+------------------------------------------------------------------+
//|                                                   GoldPulse.mq5  |
//|                        Python-to-MQL5 port for Strategy Tester   |
//|  Mirrors GoldPulse Python bot logic exactly so backtest results  |
//|  reflect live bot behaviour.                                      |
//+------------------------------------------------------------------+
#property copyright "GoldPulse Bot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//── Inputs (mirror config.py) ────────────────────────────────────────
input int    BASE_STOP_POINTS       = 50;     // Min SL distance (pts)
input double SPREAD_MULTIPLIER      = 1.5;    // Dynamic SL = max(BASE, spread*this)
input double ENTRY_BUFFER_FACTOR    = 0.55;   // Entry = mid ± (sl_dist * factor)

input int    TRAIL_ATR_PERIOD       = 14;     // ATR period for trailing
input double TRAIL_ATR_MULT         = 0.4;    // Trail step = ATR * this
input int    TRAIL_MIN_POINTS       = 30;     // Min trail step (pts)
input int    TRAIL_CHECK_SEC        = 15;     // Trailing update interval (sec)

input double RISK_PCT_PER_TRADE     = 0.005;  // 0.5% account risk per trade
input double MIN_LOT                = 0.01;
input double MAX_LOT                = 1.00;

input double MAX_DAILY_LOSS_PCT     = 0.02;   // Halt if day loss > 2%

input int    SESSION_START_UTC      = 7;      // Session open (UTC hour)
input int    SESSION_END_UTC        = 21;     // Session close (UTC hour)

input int    MAX_SPREAD_POINTS      = 80;     // Max allowed spread (pts)
input int    ATR_MIN_POINTS         = 20;     // Min ATR filter (pts)
input int    ATR_MAX_POINTS         = 500;    // Max ATR filter (pts)

input int    ORDER_INTERVAL_SEC     = 60;     // Re-place orders every N sec
input int    CONSEC_LOSS_LIMIT      = 5;      // Losses before pause
input int    CONSEC_LOSS_PAUSE_MIN  = 60;     // Pause duration (min)

input long   BOT_MAGIC              = 20250001;

//── Global state ─────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

datetime  lastOrderTime   = 0;
datetime  lastTrailTime   = 0;
datetime  pauseUntil      = 0;
int       consecLosses    = 0;
ulong     lastPositionTicket = 0;
double    startOfDayBalance  = 0;
datetime  currentDay         = 0;

int       atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialisation                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(BOT_MAGIC);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   atrHandle = iATR(_Symbol, PERIOD_M1, TRAIL_ATR_PERIOD);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }

   startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDay        = iTime(_Symbol, PERIOD_D1, 0);

   Print("GoldPulse EA initialised | Balance: ", startOfDayBalance,
         " | Magic: ", BOT_MAGIC);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialisation                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Print("GoldPulse EA stopped");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();

   //── Midnight reset ───────────────────────────────────────────────
   datetime todayBar = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBar != currentDay)
   {
      startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDay        = todayBar;
      Print("New day — balance reset to ", startOfDayBalance);
   }

   //── Trailing stop (every TRAIL_CHECK_SEC) ────────────────────────
   if(now - lastTrailTime >= TRAIL_CHECK_SEC)
   {
      ManageTrailing();
      lastTrailTime = now;
   }

   //── Order cycle (every ORDER_INTERVAL_SEC) ───────────────────────
   if(now - lastOrderTime >= ORDER_INTERVAL_SEC)
   {
      OrderCycle();
      lastOrderTime = now;
   }
}

//+------------------------------------------------------------------+
//| Order cycle — all filters then place bracket                      |
//+------------------------------------------------------------------+
void OrderCycle()
{
   //1. Daily loss limit
   if(IsDailyLossLimitHit())
   {
      Print("Daily loss limit hit — halting for today");
      CancelAllPending();
      return;
   }

   //2. Consecutive loss pause
   if(pauseUntil > 0 && TimeCurrent() < pauseUntil)
   {
      int remaining = (int)((pauseUntil - TimeCurrent()) / 60);
      Print("Consecutive loss pause — ", remaining, " min remaining");
      return;
   }

   //3. Skip if position open
   if(GetOpenPosition() >= 0)
   {
      Print("Position open — skipping new order cycle");
      return;
   }

   //4. Session filter
   if(!IsSessionActive())
   {
      Print("Outside session window");
      CancelAllPending();
      return;
   }

   //5. Spread filter
   double spreadPts = GetSpreadPoints();
   if(spreadPts > MAX_SPREAD_POINTS)
   {
      Print("Spread too wide: ", spreadPts, " pts — skipping");
      CancelAllPending();
      return;
   }

   //6. Volatility filter (ATR)
   double atrPts = GetAtrPoints();
   if(atrPts < ATR_MIN_POINTS || atrPts > ATR_MAX_POINTS)
   {
      Print("ATR out of range: ", atrPts, " pts — skipping");
      CancelAllPending();
      return;
   }

   //7. Place bracket
   PlaceBracket(spreadPts, atrPts);
}

//+------------------------------------------------------------------+
//| Place buy stop + sell stop around current mid price               |
//+------------------------------------------------------------------+
void PlaceBracket(double spreadPts, double atrPts)
{
   CancelAllPending();

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid   = (bid + ask) / 2.0;

   //SL distance
   double slDist = MathMax(
      BASE_STOP_POINTS * point,
      spreadPts * point * SPREAD_MULTIPLIER
   );

   //Entry buffer
   double buf       = slDist * ENTRY_BUFFER_FACTOR;

   double buyEntry  = NormalisePrice(mid + buf);
   double buySL     = NormalisePrice(buyEntry - slDist);

   double sellEntry = NormalisePrice(mid - buf);
   double sellSL    = NormalisePrice(sellEntry + slDist);

   double slPoints  = slDist / point;
   double lots      = CalculateLotSize(slPoints);

   PrintFormat("Bracket | mid=%.2f  buf=%.0f pts  SL=%.0f pts  ATR=%.0f pts  spread=%.0f pts  lots=%.2f",
               mid, buf/point, slDist/point, atrPts, spreadPts, lots);

   //Place BUY STOP
   trade.BuyStop(lots, buyEntry, _Symbol, buySL, 0,
                 ORDER_TIME_GTC, 0, "GP-BUY");

   //Place SELL STOP
   trade.SellStop(lots, sellEntry, _Symbol, sellSL, 0,
                  ORDER_TIME_GTC, 0, "GP-SELL");
}

//+------------------------------------------------------------------+
//| Manage trailing stop on open position                             |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   int posIdx = GetOpenPosition();

   if(posIdx < 0)
   {
      // Position just closed
      if(lastPositionTicket != 0)
      {
         OnPositionClosed(lastPositionTicket);
         lastPositionTicket = 0;
      }
      return;
   }

   ulong ticket = PositionGetTicket(posIdx);

   // New fill detected
   if(ticket != lastPositionTicket)
   {
      PrintFormat("Position filled | #%I64u  %s  %.2f lots @ %.2f  SL=%.2f",
                  ticket,
                  PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "BUY" : "SELL",
                  PositionGetDouble(POSITION_VOLUME),
                  PositionGetDouble(POSITION_PRICE_OPEN),
                  PositionGetDouble(POSITION_SL));
      CancelAllPending();   // Cancel opposing pending order
      lastPositionTicket = ticket;
      return;
   }

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentSL = PositionGetDouble(POSITION_SL);
   double atrPts    = GetAtrPoints();

   double trailStep = MathMax(
      TRAIL_MIN_POINTS * point,
      atrPts * point * TRAIL_ATR_MULT
   );

   ENUM_POSITION_TYPE posType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(posType == POSITION_TYPE_BUY)
   {
      double idealSL = NormalisePrice(bid - trailStep);
      if(idealSL > currentSL + point)
      {
         trade.PositionModify(ticket, idealSL, 0);
         PrintFormat("Trail SL UP | #%I64u  new_sl=%.2f", ticket, idealSL);
      }
   }
   else
   {
      double idealSL = NormalisePrice(ask + trailStep);
      if(idealSL < currentSL - point)
      {
         trade.PositionModify(ticket, idealSL, 0);
         PrintFormat("Trail SL DOWN | #%I64u  new_sl=%.2f", ticket, idealSL);
      }
   }
}

//+------------------------------------------------------------------+
//| Called when a position closes — update consecutive loss counter   |
//+------------------------------------------------------------------+
void OnPositionClosed(ulong ticket)
{
   // Find closing deal in history
   datetime from = TimeCurrent() - 300;   // last 5 minutes
   HistorySelect(from, TimeCurrent());

   double pnl = 0;
   bool   found = false;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dTicket = HistoryDealGetTicket(i);
      if(dTicket == 0) continue;
      if(HistoryDealGetInteger(dTicket, DEAL_POSITION_ID) != (long)ticket) continue;
      if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      pnl   = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
            + HistoryDealGetDouble(dTicket, DEAL_SWAP)
            + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
      found = true;
      break;
   }

   if(!found) return;

   if(pnl < 0)
   {
      consecLosses++;
      PrintFormat("Loss #%d in a row | P&L=%.2f", consecLosses, pnl);
      if(consecLosses >= CONSEC_LOSS_LIMIT)
      {
         pauseUntil = TimeCurrent() + CONSEC_LOSS_PAUSE_MIN * 60;
         PrintFormat("PAUSE: %d consecutive losses — pausing %d min",
                     CONSEC_LOSS_LIMIT, CONSEC_LOSS_PAUSE_MIN);
      }
   }
   else
   {
      if(consecLosses > 0)
         PrintFormat("Win after %d losses — resetting counter", consecLosses);
      consecLosses = 0;
   }

   PrintFormat("Trade closed | ticket=%I64u  P&L=%.2f  consec_loss=%d",
               ticket, pnl, consecLosses);
}

//+------------------------------------------------------------------+
//| Cancel all GoldPulse pending orders for this symbol               |
//+------------------------------------------------------------------+
void CancelAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != BOT_MAGIC) continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP) continue;

      trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Return position index for this symbol/magic, or -1 if none        |
//+------------------------------------------------------------------+
int GetOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != BOT_MAGIC) continue;
      return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Risk-based lot sizing                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash  = balance * RISK_PCT_PER_TRADE;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return MIN_LOT;

   double slValuePerLot = (slPoints * point / tickSize) * tickValue;
   if(slValuePerLot <= 0) return MIN_LOT;

   double lots = riskCash / slValuePerLot;

   // Round to lot step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(MIN_LOT, MathMin(MAX_LOT, lots));
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Daily loss limit check                                            |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayLoss  = startOfDayBalance - balance;
   double maxLoss  = startOfDayBalance * MAX_DAILY_LOSS_PCT;
   return dayLoss >= maxLoss;
}

//+------------------------------------------------------------------+
//| Session filter: 07:00 – 21:00 UTC                                 |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= SESSION_START_UTC && dt.hour < SESSION_END_UTC);
}

//+------------------------------------------------------------------+
//| Spread in points                                                  |
//+------------------------------------------------------------------+
double GetSpreadPoints()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0;
   return (ask - bid) / point;
}

//+------------------------------------------------------------------+
//| ATR in points (M1, period=TRAIL_ATR_PERIOD)                       |
//+------------------------------------------------------------------+
double GetAtrPoints()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) < 1)
      return ATR_MIN_POINTS;   // safe default

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return ATR_MIN_POINTS;
   return atrBuf[0] / point;
}

//+------------------------------------------------------------------+
//| Round price to symbol digits                                      |
//+------------------------------------------------------------------+
double NormalisePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}
//+------------------------------------------------------------------+
