//+------------------------------------------------------------------+
//|                                           Gold Hunter V8.mq5     |
//|                    Improved Reconstruction — v2.0                 |
//|                                                                    |
//|  Improvements over original:                                       |
//|   - Dynamic lot sizing (% risk per trade)                         |
//|   - Wider SL + Gap — gives trades room to breathe                 |
//|   - ATR-based adaptive trailing stop                               |
//|   - Session filter  (07:00–21:00 UTC)                             |
//|   - Spread filter   (skip if spread too wide)                     |
//|   - Volatility filter (ATR min/max guard)                         |
//|   - Daily loss limit (halt if down X%)                            |
//|   - Consecutive loss protection (pause after N losses)            |
//+------------------------------------------------------------------+
#property copyright "Gold Hunter V8 — Improved v2.0"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//════════════════════════════════════════════════════════════════════
//  INPUT GROUPS
//════════════════════════════════════════════════════════════════════

//── Original settings ────────────────────────────────────────────────
input group "=== ORIGINAL SETTINGS ==="
input long   Inp_MagicNumber        = 5555;    // Magic Number
input int    Inp_GapPips            = 100;     // Gap: entry distance from mid (pts)
input int    Inp_StopLossPips       = 150;     // Stop Loss distance (pts)
input int    Inp_TrailAfterPips     = 80;      // Start trailing after X pts profit
input int    Inp_TrailStepPips      = 50;      // Trail step distance (pts)
input bool   Inp_UseTrailingStop    = true;    // Use trailing stop
input double Inp_DailyProfitTarget  = 0.0;    // Daily Profit Target $ (0 = disabled)

//── Risk management ──────────────────────────────────────────────────
input group "=== RISK MANAGEMENT ==="
input bool   Inp_UseDynamicLots     = true;    // Dynamic lot sizing (% risk)
input double Inp_RiskPct            = 1.0;     // Risk % per trade (if dynamic)
input double Inp_FixedLotSize       = 0.02;    // Fixed lot (if dynamic OFF)
input double Inp_MinLot             = 0.01;    // Minimum lot size
input double Inp_MaxLot             = 1.00;    // Maximum lot size
input double Inp_MaxDailyLossPct    = 2.0;     // Daily loss limit % (0 = disabled)

//── Session filter ───────────────────────────────────────────────────
input group "=== SESSION FILTER ==="
input bool   Inp_SessionFilter      = true;    // Enable session filter
input int    Inp_SessionStartUTC    = 7;       // Session start (UTC hour)
input int    Inp_SessionEndUTC      = 21;      // Session end   (UTC hour)

//── Spread filter ────────────────────────────────────────────────────
input group "=== SPREAD FILTER ==="
input bool   Inp_SpreadFilter       = true;    // Enable spread filter
input int    Inp_MaxSpreadPips      = 25;      // Max allowed spread (pts)

//── Volatility filter (ATR) ──────────────────────────────────────────
input group "=== VOLATILITY FILTER ==="
input bool   Inp_VolatilityFilter   = true;    // Enable ATR volatility filter
input int    Inp_AtrPeriod          = 14;      // ATR period (M1 bars)
input int    Inp_AtrMinPips         = 15;      // Min ATR — skip dead market (pts)
input int    Inp_AtrMaxPips         = 500;     // Max ATR — skip news spike (pts)

//── Consecutive loss protection ──────────────────────────────────────
input group "=== LOSS PROTECTION ==="
input int    Inp_ConsecLossLimit    = 5;       // Pause after N consecutive losses
input int    Inp_ConsecLossPauseMin = 60;      // Pause duration (minutes)

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════
CTrade   trade;
int      atrHandle        = INVALID_HANDLE;

datetime lastPlaceTime    = 0;
datetime lastTrailTime    = 0;
double   dayStartBalance  = 0;
datetime currentDayBar    = 0;
bool     dailyTargetHit   = false;
bool     dailyLossHit     = false;

int      consecLosses     = 0;
datetime pauseUntil       = 0;
ulong    lastPosTicket    = 0;

//════════════════════════════════════════════════════════════════════
//  INIT / DEINIT
//════════════════════════════════════════════════════════════════════
int OnInit()
{
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   atrHandle = iATR(_Symbol, PERIOD_M1, Inp_AtrPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot create ATR indicator");
      return INIT_FAILED;
   }

   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDayBar   = iTime(_Symbol, PERIOD_D1, 0);

   PrintFormat("Gold Hunter V8 v2.0 | Balance=%.2f | Magic=%I64d | Risk=%.1f%%",
               dayStartBalance, Inp_MagicNumber, Inp_RiskPct);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   Print("Gold Hunter V8 v2.0 stopped");
}

//════════════════════════════════════════════════════════════════════
//  MAIN TICK
//════════════════════════════════════════════════════════════════════
void OnTick()
{
   //── Daily bar reset ──────────────────────────────────────────────
   datetime todayBar = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBar != currentDayBar)
   {
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDayBar   = todayBar;
      dailyTargetHit  = false;
      dailyLossHit    = false;
      consecLosses    = 0;
      pauseUntil      = 0;
      PrintFormat("New day | Balance reset to %.2f", dayStartBalance);
   }

   //── Daily profit target ──────────────────────────────────────────
   if(!dailyTargetHit && Inp_DailyProfitTarget > 0)
   {
      double floatingPnL = AccountInfoDouble(ACCOUNT_EQUITY) - dayStartBalance;
      if(floatingPnL >= Inp_DailyProfitTarget)
      {
         PrintFormat("Daily profit target hit: +%.2f — closing all", floatingPnL);
         CloseAllPositions();
         CancelAllPending();
         dailyTargetHit = true;
      }
   }

   //── Daily loss limit ─────────────────────────────────────────────
   if(!dailyLossHit && Inp_MaxDailyLossPct > 0)
   {
      double dayLoss   = dayStartBalance - AccountInfoDouble(ACCOUNT_BALANCE);
      double maxLoss   = dayStartBalance * Inp_MaxDailyLossPct / 100.0;
      if(dayLoss >= maxLoss)
      {
         PrintFormat("Daily loss limit hit: -%.2f (%.1f%%) — halting today",
                     dayLoss, Inp_MaxDailyLossPct);
         CancelAllPending();
         dailyLossHit = true;
      }
   }

   if(dailyTargetHit || dailyLossHit) return;

   //── Trailing stop (every 5 sec) ──────────────────────────────────
   if(Inp_UseTrailingStop && TimeCurrent() - lastTrailTime >= 5)
   {
      ManageTrailing();
      lastTrailTime = TimeCurrent();
   }

   //── Detect closed positions ──────────────────────────────────────
   CheckForClosedPosition();

   //── New order cycle (every 60 sec) ───────────────────────────────
   if(TimeCurrent() - lastPlaceTime >= 60)
   {
      OrderCycle();
      lastPlaceTime = TimeCurrent();
   }
}

//════════════════════════════════════════════════════════════════════
//  ORDER CYCLE — all filters then place bracket
//════════════════════════════════════════════════════════════════════
void OrderCycle()
{
   //1. Consecutive loss pause
   if(pauseUntil > 0 && TimeCurrent() < pauseUntil)
   {
      int mins = (int)((pauseUntil - TimeCurrent()) / 60);
      PrintFormat("Consecutive loss pause — %d min remaining", mins);
      return;
   }

   //2. Skip if position already open
   if(HasOpenPosition()) return;

   //3. Session filter
   if(Inp_SessionFilter && !IsSessionActive())
   {
      CancelAllPending();
      return;
   }

   //4. Spread filter
   double spreadPts = GetSpreadPoints();
   if(Inp_SpreadFilter && spreadPts > Inp_MaxSpreadPips)
   {
      PrintFormat("Spread too wide: %.0f pts — skipping", spreadPts);
      CancelAllPending();
      return;
   }

   //5. Volatility filter (ATR)
   double atrPts = GetAtrPoints();
   if(Inp_VolatilityFilter)
   {
      if(atrPts < Inp_AtrMinPips)
      {
         PrintFormat("ATR too low: %.0f pts — market dead, skipping", atrPts);
         CancelAllPending();
         return;
      }
      if(atrPts > Inp_AtrMaxPips)
      {
         PrintFormat("ATR too high: %.0f pts — news spike, skipping", atrPts);
         CancelAllPending();
         return;
      }
   }

   //6. Place bracket
   PlaceBracket(spreadPts, atrPts);
}

//════════════════════════════════════════════════════════════════════
//  PLACE BRACKET
//════════════════════════════════════════════════════════════════════
void PlaceBracket(double spreadPts, double atrPts)
{
   CancelAllPending();

   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid      = (bid + ask) / 2.0;
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double gapDist  = Inp_GapPips      * point;
   double slDist   = Inp_StopLossPips * point;

   double buyEntry  = NormalizeDouble(mid + gapDist, digits);
   double buySL     = NormalizeDouble(buyEntry - slDist, digits);
   double sellEntry = NormalizeDouble(mid - gapDist, digits);
   double sellSL    = NormalizeDouble(sellEntry + slDist, digits);

   double lots = CalculateLots(Inp_StopLossPips);

   PrintFormat("Bracket | mid=%.2f  gap=%d pts  SL=%d pts  ATR=%.0f pts  spread=%.0f pts  lots=%.2f",
               mid, Inp_GapPips, Inp_StopLossPips, atrPts, spreadPts, lots);

   if(!trade.BuyStop(lots, buyEntry, _Symbol, buySL, 0, ORDER_TIME_GTC, 0, "GH-BUY"))
      PrintFormat("BuyStop failed | %.2f sl=%.2f err=%d", buyEntry, buySL, GetLastError());

   if(!trade.SellStop(lots, sellEntry, _Symbol, sellSL, 0, ORDER_TIME_GTC, 0, "GH-SELL"))
      PrintFormat("SellStop failed | %.2f sl=%.2f err=%d", sellEntry, sellSL, GetLastError());
}

//════════════════════════════════════════════════════════════════════
//  TRAILING STOP
//════════════════════════════════════════════════════════════════════
void ManageTrailing()
{
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atrPts     = GetAtrPoints();

   // Trail step: larger of fixed step or ATR-based step
   double trailStep  = MathMax(Inp_TrailStepPips * point,
                               atrPts * point * 0.4);
   double triggerDist = Inp_TrailAfterPips * point;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE posType =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = bid - openPrice;
         if(profit < triggerDist) continue;        // wait for enough profit first

         double idealSL = NormalizeDouble(bid - trailStep, digits);
         if(idealSL > currentSL + point)           // only ratchet UP
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail BUY  #%I64u | sl: %.2f → %.2f", ticket, currentSL, idealSL);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         if(profit < triggerDist) continue;

         double idealSL = NormalizeDouble(ask + trailStep, digits);
         if(idealSL < currentSL - point)           // only ratchet DOWN
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail SELL #%I64u | sl: %.2f → %.2f", ticket, currentSL, idealSL);
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  DETECT CLOSED POSITION → update consecutive loss counter
//════════════════════════════════════════════════════════════════════
void CheckForClosedPosition()
{
   bool posOpen = HasOpenPosition();

   if(!posOpen && lastPosTicket != 0)
   {
      // Position just closed — look up result in history
      HistorySelect(TimeCurrent() - 600, TimeCurrent());

      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket == 0) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_POSITION_ID) != (long)lastPosTicket) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

         double pnl = HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);

         if(pnl < 0)
         {
            consecLosses++;
            PrintFormat("Loss #%d | P&L=%.2f", consecLosses, pnl);
            if(consecLosses >= Inp_ConsecLossLimit)
            {
               pauseUntil = TimeCurrent() + Inp_ConsecLossPauseMin * 60;
               PrintFormat("PAUSE: %d losses in a row — pausing %d min",
                           consecLosses, Inp_ConsecLossPauseMin);
            }
         }
         else
         {
            if(consecLosses > 0)
               PrintFormat("Win after %d losses — counter reset", consecLosses);
            consecLosses = 0;
         }

         PrintFormat("Trade closed | #%I64u  P&L=%.2f  streak=%d",
                     lastPosTicket, pnl, consecLosses);
         break;
      }

      lastPosTicket = 0;
   }

   // Track currently open position ticket
   if(posOpen && lastPosTicket == 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;
         lastPosTicket = ticket;
         CancelAllPending();   // cancel opposite pending on fill
         PrintFormat("Position filled | #%I64u  %s  %.2f lots @ %.2f",
                     ticket,
                     PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "BUY":"SELL",
                     PositionGetDouble(POSITION_VOLUME),
                     PositionGetDouble(POSITION_PRICE_OPEN));
         break;
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  HELPERS
//════════════════════════════════════════════════════════════════════

//── Lot sizing ───────────────────────────────────────────────────────
double CalculateLots(int slPoints)
{
   if(!Inp_UseDynamicLots) return Inp_FixedLotSize;

   double balance       = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash      = balance * Inp_RiskPct / 100.0;
   double point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return Inp_MinLot;

   double slValuePerLot = (slPoints * point / tickSize) * tickValue;
   if(slValuePerLot <= 0) return Inp_MinLot;

   double lots = riskCash / slValuePerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

   return NormalizeDouble(MathMax(Inp_MinLot, MathMin(Inp_MaxLot, lots)), 2);
}

//── Session filter ───────────────────────────────────────────────────
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= Inp_SessionStartUTC && dt.hour < Inp_SessionEndUTC);
}

//── Spread in points ─────────────────────────────────────────────────
double GetSpreadPoints()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0;
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;
}

//── ATR in points ────────────────────────────────────────────────────
double GetAtrPoints()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) < 1) return Inp_AtrMinPips;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return Inp_AtrMinPips;
   return buf[0] / point;
}

//── Cancel all pending orders ────────────────────────────────────────
void CancelAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)  != Inp_MagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP) continue;
      trade.OrderDelete(ticket);
   }
}

//── Close all positions ──────────────────────────────────────────────
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;
      trade.PositionClose(ticket);
   }
}

//── Has open position ────────────────────────────────────────────────
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+
