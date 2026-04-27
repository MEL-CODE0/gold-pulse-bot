//+------------------------------------------------------------------+
//|                                           Gold Hunter V8.mq5     |
//|                    Adaptive v5.0  — Tick-Reactive                |
//|                                                                   |
//|  Reacts on EVERY TICK — not just every 60 seconds.               |
//|  • Trailing stop: moved the instant price improves               |
//|  • Spread spike: pending orders cancelled within milliseconds     |
//|  • Order refresh: bracket replaced the moment ATR/spread shifts  |
//|  • Everything auto-scales — no manual inputs needed              |
//+------------------------------------------------------------------+
#property copyright "Gold Hunter V8 — Adaptive v5.0"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//════════════════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════════════════
input group "=== CORE SETTINGS ==="
input long   Inp_MagicNumber        = 5555;
input double Inp_DailyProfitTarget  = 0.0;    // Daily profit $ target (0 = off)

input group "=== RISK — auto-scales to any account ==="
input bool   Inp_UseDynamicLots     = true;   // ON = risk % sizing (recommended)
input double Inp_RiskPct            = 0.5;    // % of balance risked per trade
input double Inp_FixedLot           = 0.01;   // Only used if dynamic OFF
input double Inp_MinLot             = 0.01;
input double Inp_MaxLot             = 1.00;
input double Inp_MaxDailyLossPct    = 2.0;    // Halt if day loss > X% (0 = off)

input group "=== AUTO-ADAPTIVE DISTANCES (multipliers only) ==="
input double Inp_Gap_AtrMult        = 0.25;   // Entry gap = ATR × this
input double Inp_SL_SpreadMult      = 1.5;    // SL >= spread × this
input double Inp_SL_AtrMult         = 0.5;    // SL >= ATR × this
input double Inp_Trail_AtrMult      = 0.28;   // Trail step = ATR × this (tighter)
input double Inp_Trail_TrigMult     = 0.4;    // Trail starts at profit >= spread × this
input double Inp_BE_SLMult          = 0.7;    // Break-even at profit >= SL × this

input group "=== TICK-REACTIVE THRESHOLDS ==="
input double Inp_RefreshChangePct   = 15.0;   // Refresh orders if spread/ATR shifts > this %
input double Inp_SpreadSpikeX       = 2.0;    // Cancel pending if spread > avg × this

input group "=== SESSION FILTER ==="
input bool   Inp_SessionFilter      = true;
input int    Inp_SessionStartUTC    = 7;
input int    Inp_SessionEndUTC      = 21;

input group "=== LOSS PROTECTION ==="
input int    Inp_ConsecLossLimit    = 5;
input int    Inp_ConsecLossPauseMin = 60;

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════
CTrade   trade;
int      atrHandle      = INVALID_HANDLE;

// Spread EMA — learns normal broker spread automatically
double   spreadEma      = 0;

// Values recorded when orders were last placed (used for refresh check)
double   placedSpread   = 0;
double   placedAtr      = 0;

datetime lastPlaceTime  = 0;
double   dayStartBal    = 0;
datetime currentDayBar  = 0;
bool     dailyTargetHit = false;
bool     dailyLossHit   = false;

int      consecLosses   = 0;
datetime pauseUntil     = 0;
ulong    lastPosTkt     = 0;

// Minimum seconds between full order placements (avoid hammering broker)
#define  MIN_REORDER_SEC  10

//════════════════════════════════════════════════════════════════════
//  INIT / DEINIT
//════════════════════════════════════════════════════════════════════
int OnInit()
{
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   atrHandle = iATR(_Symbol, PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE)
   { Print("ERROR: Cannot create ATR"); return INIT_FAILED; }

   dayStartBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDayBar = iTime(_Symbol, PERIOD_D1, 0);
   spreadEma     = GetSpreadPoints();

   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   PrintFormat("=== Gold Hunter V8  v5.0  STARTED ===");
   PrintFormat("Symbol=%s  Digits=%d  Point=%.6f",
               _Symbol,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               point);
   PrintFormat("TickSize=%.6f  TickValue=%.6f  Contract=%.2f",
               tickSz, tickVal, contractSz);
   PrintFormat("Spread=%.0f pts  Balance=%.2f %s  Magic=%I64d",
               spreadEma, dayStartBal,
               AccountInfoString(ACCOUNT_CURRENCY),
               Inp_MagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("Gold Hunter V8 v5.0 stopped");
}

//════════════════════════════════════════════════════════════════════
//  MAIN TICK  — every price change calls this
//════════════════════════════════════════════════════════════════════
void OnTick()
{
   double spreadPts = GetSpreadPoints();
   double atrPts    = GetAtrPoints();
   if(atrPts <= 0) atrPts = spreadPts * 2.0;

   // Update spread EMA continuously (α=0.01 → very smooth, ~100-tick average)
   spreadEma = spreadEma * 0.99 + spreadPts * 0.01;

   //── 1. Daily reset ───────────────────────────────────────────────
   datetime todayBar = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBar != currentDayBar)
   {
      dayStartBal    = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDayBar  = todayBar;
      dailyTargetHit = false;
      dailyLossHit   = false;
      consecLosses   = 0;
      pauseUntil     = 0;
      PrintFormat("New day | Balance=%.2f", dayStartBal);
   }

   //── 2. Daily profit target ───────────────────────────────────────
   if(!dailyTargetHit && Inp_DailyProfitTarget > 0)
   {
      if(AccountInfoDouble(ACCOUNT_EQUITY) - dayStartBal >= Inp_DailyProfitTarget)
      {
         Print("Daily profit target reached — stopping");
         CloseAllPositions(); CancelAllPending();
         dailyTargetHit = true; return;
      }
   }

   //── 3. Daily loss limit ──────────────────────────────────────────
   if(!dailyLossHit && Inp_MaxDailyLossPct > 0)
   {
      double loss    = dayStartBal - AccountInfoDouble(ACCOUNT_BALANCE);
      double maxLoss = dayStartBal * Inp_MaxDailyLossPct / 100.0;
      if(loss >= maxLoss)
      {
         PrintFormat("Daily loss limit hit (-%.2f) — halting today", loss);
         CancelAllPending();
         dailyLossHit = true;
      }
   }
   if(dailyTargetHit || dailyLossHit) return;

   //── 4. TICK-LEVEL: spread spike → cancel pending IMMEDIATELY ─────
   //   If spread suddenly doubles above normal, cancel pending at once.
   //   Don't wait for the 60-second cycle — act within milliseconds.
   if(spreadPts > spreadEma * Inp_SpreadSpikeX && HasPendingOrders())
   {
      PrintFormat("SPIKE cancel | spread=%.0f avg=%.0f", spreadPts, spreadEma);
      CancelAllPending();
      lastPlaceTime = 0;   // force re-place when spread normalises
   }

   //── 5. TICK-LEVEL: trailing stop ─────────────────────────────────
   //   Checked on every tick — SL moves the instant price improves.
   ManageTrailing(spreadPts, atrPts);

   //── 6. Detect position state changes ────────────────────────────
   CheckPositionState();

   //── 7. TICK-LEVEL: refresh orders if market conditions shifted ───
   //   If spread or ATR changed > Inp_RefreshChangePct since last place,
   //   cancel stale orders and place fresh ones with new distances.
   if(ShouldRefreshOrders(spreadPts, atrPts))
   {
      PrintFormat("REFRESH | spread %.0f→%.0f  ATR %.0f→%.0f",
                  placedSpread, spreadPts, placedAtr, atrPts);
      DoPlaceBracket(spreadPts, atrPts);
      return;
   }

   //── 8. Regular order cycle (minimum every 60 sec) ────────────────
   if(TimeCurrent() - lastPlaceTime >= 60)
      OrderCycle(spreadPts, atrPts);
}

//════════════════════════════════════════════════════════════════════
//  SHOULD REFRESH ORDERS?
//  Returns true when spread or ATR drifts enough to warrant new orders
//════════════════════════════════════════════════════════════════════
bool ShouldRefreshOrders(double spreadPts, double atrPts)
{
   // Only refresh if:
   //  a) we have pending orders currently placed
   //  b) no position open (don't interfere with open trade)
   //  c) minimum reorder cooldown passed (avoid hammering broker)
   if(!HasPendingOrders())   return false;
   if(HasOpenPosition())     return false;
   if(TimeCurrent() - lastPlaceTime < MIN_REORDER_SEC) return false;

   if(placedSpread <= 0 || placedAtr <= 0) return false;

   double spreadChange = MathAbs(spreadPts - placedSpread) / placedSpread * 100.0;
   double atrChange    = MathAbs(atrPts    - placedAtr)    / placedAtr    * 100.0;

   return (spreadChange > Inp_RefreshChangePct ||
           atrChange    > Inp_RefreshChangePct);
}

//════════════════════════════════════════════════════════════════════
//  ORDER CYCLE — full guard checks
//════════════════════════════════════════════════════════════════════
void OrderCycle(double spreadPts, double atrPts)
{
   if(pauseUntil > 0 && TimeCurrent() < pauseUntil)
   {
      int rem = (int)((pauseUntil - TimeCurrent()) / 60);
      if(rem % 5 == 0) PrintFormat("Loss pause — %d min remaining", rem);
      return;
   }

   if(HasOpenPosition()) return;

   if(Inp_SessionFilter && !IsSessionActive())
   { CancelAllPending(); return; }

   DoPlaceBracket(spreadPts, atrPts);
}

//════════════════════════════════════════════════════════════════════
//  PLACE BRACKET  — all distances auto-calculated every time
//════════════════════════════════════════════════════════════════════
void DoPlaceBracket(double spreadPts, double atrPts)
{
   // Don't place during a spike — wait for normal spread
   if(spreadPts > spreadEma * Inp_SpreadSpikeX)
   {
      CancelAllPending();
      return;
   }

   CancelAllPending();

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid    = (bid + ask) / 2.0;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // GAP: ATR-fraction so entries fill on normal momentum
   double gapPts = atrPts * Inp_Gap_AtrMult;
   gapPts = MathMax(gapPts, spreadPts * 0.5);   // floor: >= half spread

   // SL: must be wider than spread to survive spread noise
   double slPts  = MathMax(spreadPts * Inp_SL_SpreadMult,
                            atrPts    * Inp_SL_AtrMult);
   slPts = MathMax(slPts, spreadPts * 1.2);      // hard floor: 1.2× spread

   double gapDist = gapPts * point;
   double slDist  = slPts  * point;

   double buyEntry  = NormalizeDouble(mid + gapDist, digits);
   double buySL     = NormalizeDouble(buyEntry  - slDist, digits);
   double sellEntry = NormalizeDouble(mid - gapDist, digits);
   double sellSL    = NormalizeDouble(sellEntry + slDist, digits);

   double lots = CalculateLots(slPts);

   PrintFormat("BRACKET | spread=%.0f avg=%.0f | gap=%.0f SL=%.0f ATR=%.0f | lots=%.2f",
               spreadPts, spreadEma, gapPts, slPts, atrPts, lots);
   PrintFormat("  BUY@%.3f sl=%.3f  SELL@%.3f sl=%.3f",
               buyEntry, buySL, sellEntry, sellSL);

   bool b = trade.BuyStop (lots, buyEntry,  _Symbol, buySL,   0, ORDER_TIME_GTC, 0, "GH-BUY");
   bool s = trade.SellStop(lots, sellEntry, _Symbol, sellSL,  0, ORDER_TIME_GTC, 0, "GH-SELL");

   if(!b) PrintFormat("BuyStop  FAILED err=%d", GetLastError());
   if(!s) PrintFormat("SellStop FAILED err=%d", GetLastError());

   // Record conditions at placement time for refresh comparison
   placedSpread  = spreadPts;
   placedAtr     = atrPts;
   lastPlaceTime = TimeCurrent();
}

//════════════════════════════════════════════════════════════════════
//  TRAILING STOP  — runs on EVERY TICK
//  Moves SL the instant price ticks in our favour.
//════════════════════════════════════════════════════════════════════
void ManageTrailing(double spreadPts, double atrPts)
{
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Trail step adapts to current volatility
   double trailStep = atrPts * Inp_Trail_AtrMult * point;
   // Minimum trail step: 10% of spread so we never trail tighter than spread noise
   trailStep = MathMax(trailStep, spreadPts * 0.1 * point);

   // Trail activates when profit >= fraction of spread
   double trailTrig = spreadPts * Inp_Trail_TrigMult * point;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;

      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE posType =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = bid - open;
         if(profit < trailTrig) continue;   // trade hasn't cleared spread cost yet

         double newSL = sl;

         // Break-even: lock entry + small buffer when profit hits BE threshold
         double slDist = open - sl;
         if(slDist > 0 && profit >= slDist * Inp_BE_SLMult)
         {
            double beSL = NormalizeDouble(open + spreadPts * 0.2 * point, digits);
            if(beSL > newSL + point) newSL = beSL;
         }

         // Standard trail: pull SL up behind bid
         double idealSL = NormalizeDouble(bid - trailStep, digits);
         if(idealSL > newSL + point) newSL = idealSL;

         if(newSL > sl + point)
         {
            trade.PositionModify(ticket, newSL, 0);
            PrintFormat("Trail BUY  #%I64u  %.3f→%.3f (+%.0f pts)",
                        ticket, sl, newSL, (newSL-sl)/point);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = open - ask;
         if(profit < trailTrig) continue;

         double newSL = sl;

         double slDist = sl - open;
         if(slDist > 0 && profit >= slDist * Inp_BE_SLMult)
         {
            double beSL = NormalizeDouble(open - spreadPts * 0.2 * point, digits);
            if(beSL < newSL - point) newSL = beSL;
         }

         double idealSL = NormalizeDouble(ask + trailStep, digits);
         if(idealSL < newSL - point) newSL = idealSL;

         if(newSL < sl - point)
         {
            trade.PositionModify(ticket, newSL, 0);
            PrintFormat("Trail SELL #%I64u  %.3f→%.3f (+%.0f pts)",
                        ticket, sl, newSL, (sl-newSL)/point);
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  POSITION STATE — detect fills and closes on every tick
//════════════════════════════════════════════════════════════════════
void CheckPositionState()
{
   bool posOpen = HasOpenPosition();

   // Position just closed
   if(!posOpen && lastPosTkt != 0)
   {
      HistorySelect(TimeCurrent() - 600, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong dTkt = HistoryDealGetTicket(i);
         if(dTkt == 0) continue;
         if(HistoryDealGetInteger(dTkt, DEAL_POSITION_ID) != (long)lastPosTkt) continue;
         if(HistoryDealGetInteger(dTkt, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

         double pnl = HistoryDealGetDouble(dTkt, DEAL_PROFIT)
                    + HistoryDealGetDouble(dTkt, DEAL_SWAP)
                    + HistoryDealGetDouble(dTkt, DEAL_COMMISSION);

         if(pnl < 0)
         {
            consecLosses++;
            PrintFormat("Loss #%d | P&L=%.2f", consecLosses, pnl);
            if(consecLosses >= Inp_ConsecLossLimit)
            {
               pauseUntil = TimeCurrent() + Inp_ConsecLossPauseMin * 60;
               PrintFormat("PAUSE: %d losses — pausing %d min",
                           consecLosses, Inp_ConsecLossPauseMin);
            }
         }
         else
         {
            if(consecLosses > 0)
               PrintFormat("Win after %d losses — counter reset", consecLosses);
            consecLosses = 0;
         }
         PrintFormat("Closed #%I64u  P&L=%.2f  consec=%d", lastPosTkt, pnl, consecLosses);
         break;
      }
      lastPosTkt    = 0;
      placedSpread  = 0;   // reset so next cycle places fresh
      placedAtr     = 0;
      lastPlaceTime = 0;
   }

   // New fill detected
   if(posOpen && lastPosTkt == 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;

         lastPosTkt = ticket;
         CancelAllPending();   // cancel the opposing pending order immediately
         PrintFormat("FILLED #%I64u  %s  %.2f lots @ %.3f  SL=%.3f",
                     ticket,
                     PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "BUY" : "SELL",
                     PositionGetDouble(POSITION_VOLUME),
                     PositionGetDouble(POSITION_PRICE_OPEN),
                     PositionGetDouble(POSITION_SL));
         break;
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  LOT SIZING — auto-scales to any balance/currency/broker
//════════════════════════════════════════════════════════════════════
double CalculateLots(double slPoints)
{
   if(!Inp_UseDynamicLots) return Inp_FixedLot;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash  = balance * Inp_RiskPct / 100.0;
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0) return Inp_MinLot;

   double slValuePerLot = (slPoints * point / tickSize) * tickValue;
   if(slValuePerLot <= 0) return Inp_MinLot;

   double lots    = riskCash / slValuePerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(Inp_MinLot, MathMin(Inp_MaxLot, lots));
   PrintFormat("  LotCalc: balance=%.2f risk=%.2f slPts=%.0f slVal/lot=%.5f → %.2f lots",
               balance, riskCash, slPoints, slValuePerLot, lots);
   return NormalizeDouble(lots, 2);
}

//════════════════════════════════════════════════════════════════════
//  UTILITY
//════════════════════════════════════════════════════════════════════

double GetSpreadPoints()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 10;
   double s = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
               SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;
   return MathMax(s, 1.0);
}

double GetAtrPoints()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 3, buf) < 3) return 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0;
   // Use 3-bar average of ATR to smooth out single-bar spikes
   return ((buf[0] + buf[1] + buf[2]) / 3.0) / point;
}

bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= Inp_SessionStartUTC && dt.hour < Inp_SessionEndUTC);
}

bool HasPendingOrders()
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)  != Inp_MagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_SELL_STOP) return true;
   }
   return false;
}

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
