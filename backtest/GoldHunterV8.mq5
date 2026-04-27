//+------------------------------------------------------------------+
//|                                           Gold Hunter V8.mq5     |
//|                    Adaptive v3.0                                  |
//|                                                                   |
//|  Fully auto-adapts to any broker, symbol or spread condition.    |
//|  No hardcoded pip values — everything calculated from live        |
//|  spread and ATR so it works on Exness, Fusion, or any broker.    |
//+------------------------------------------------------------------+
#property copyright "Gold Hunter V8 — Adaptive v3.0"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//════════════════════════════════════════════════════════════════════
//  INPUTS
//════════════════════════════════════════════════════════════════════

input group "=== TRADE SETTINGS ==="
input long   Inp_MagicNumber        = 5555;   // Magic Number
input bool   Inp_UseTrailingStop    = true;   // Use trailing stop
input double Inp_DailyProfitTarget  = 0.0;   // Daily profit target $ (0=off)

input group "=== RISK MANAGEMENT ==="
input bool   Inp_UseDynamicLots     = false;  // true=% risk | false=fixed lot
input double Inp_RiskPct            = 1.0;    // Risk % per trade (dynamic mode)
input double Inp_FixedLot           = 0.01;   // Fixed lot size (fixed mode)
input double Inp_MinLot             = 0.01;   // Minimum lot
input double Inp_MaxLot             = 1.00;   // Maximum lot
input double Inp_MaxDailyLossPct    = 2.0;    // Halt if day loss > X% (0=off)

input group "=== AUTO-ADAPTIVE MULTIPLIERS ==="
// These work on ANY broker — values are relative to live spread & ATR
input double Inp_SL_SpreadMult      = 2.5;   // SL = max(spread×this, ATR×SL_AtrMult)
input double Inp_SL_AtrMult         = 0.5;   // SL = max(spread×SL_SpreadMult, ATR×this)
input double Inp_Gap_SpreadMult     = 1.5;   // Gap from mid = spread × this
input double Inp_Trail_AtrMult      = 0.35;  // Trail step = ATR × this
input double Inp_Trail_TrigMult     = 1.0;   // Trail trigger = spread × this
input double Inp_MaxSpreadMult      = 3.0;   // Skip if spread > avg_spread × this

input group "=== SESSION FILTER ==="
input bool   Inp_SessionFilter      = true;  // Enable session hours filter
input int    Inp_SessionStartUTC    = 7;     // Session open  (UTC hour)
input int    Inp_SessionEndUTC      = 21;    // Session close (UTC hour)

input group "=== LOSS PROTECTION ==="
input int    Inp_ConsecLossLimit    = 5;     // Pause after N consecutive losses
input int    Inp_ConsecLossPauseMin = 60;    // Pause duration (minutes)

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════
CTrade   trade;
int      atrHandle      = INVALID_HANDLE;

// Spread EMA — auto-learns the broker's normal spread over time
double   spreadEma      = 0;
bool     spreadEmaReady = false;

datetime lastPlaceTime  = 0;
datetime lastTrailTime  = 0;
double   dayStartBal    = 0;
datetime currentDayBar  = 0;
bool     dailyTargetHit = false;
bool     dailyLossHit   = false;

int      consecLosses   = 0;
datetime pauseUntil     = 0;
ulong    lastPosTkt     = 0;

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
   {
      Print("ERROR: Cannot create ATR indicator");
      return INIT_FAILED;
   }

   dayStartBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDayBar = iTime(_Symbol, PERIOD_D1, 0);

   // Seed spread EMA with current spread
   spreadEma     = GetSpreadPoints();
   spreadEmaReady = true;

   PrintFormat("Gold Hunter V8 Adaptive v3.0 | Balance=%.2f | Magic=%I64d",
               dayStartBal, Inp_MagicNumber);
   PrintFormat("Symbol: %s | Digits: %d | Point: %.5f",
               _Symbol,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("Gold Hunter V8 Adaptive v3.0 stopped");
}

//════════════════════════════════════════════════════════════════════
//  MAIN TICK
//════════════════════════════════════════════════════════════════════
void OnTick()
{
   // Update spread EMA every tick (slow EMA — adapts over ~20 min)
   UpdateSpreadEma();

   //── Daily bar reset ──────────────────────────────────────────────
   datetime todayBar = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBar != currentDayBar)
   {
      dayStartBal    = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDayBar  = todayBar;
      dailyTargetHit = false;
      dailyLossHit   = false;
      consecLosses   = 0;
      pauseUntil     = 0;
      PrintFormat("New day | Balance reset to %.2f", dayStartBal);
   }

   //── Daily profit target ──────────────────────────────────────────
   if(!dailyTargetHit && Inp_DailyProfitTarget > 0)
   {
      if(AccountInfoDouble(ACCOUNT_EQUITY) - dayStartBal >= Inp_DailyProfitTarget)
      {
         Print("Daily profit target hit — closing all");
         CloseAllPositions();
         CancelAllPending();
         dailyTargetHit = true;
         return;
      }
   }

   //── Daily loss limit ─────────────────────────────────────────────
   if(!dailyLossHit && Inp_MaxDailyLossPct > 0)
   {
      double loss    = dayStartBal - AccountInfoDouble(ACCOUNT_BALANCE);
      double maxLoss = dayStartBal * Inp_MaxDailyLossPct / 100.0;
      if(loss >= maxLoss)
      {
         PrintFormat("Daily loss limit hit: -%.2f — halting today", loss);
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

   //── Detect closed position ───────────────────────────────────────
   CheckForClosedPosition();

   //── New order cycle (every 60 sec) ───────────────────────────────
   if(TimeCurrent() - lastPlaceTime >= 60)
   {
      OrderCycle();
      lastPlaceTime = TimeCurrent();
   }
}

//════════════════════════════════════════════════════════════════════
//  ORDER CYCLE
//════════════════════════════════════════════════════════════════════
void OrderCycle()
{
   //1. Consecutive loss pause
   if(pauseUntil > 0 && TimeCurrent() < pauseUntil)
   {
      PrintFormat("Loss pause — %d min remaining",
                  (int)((pauseUntil - TimeCurrent()) / 60));
      return;
   }

   //2. Skip if position open
   if(HasOpenPosition()) return;

   //3. Session filter
   if(Inp_SessionFilter && !IsSessionActive())
   {
      CancelAllPending();
      return;
   }

   //4. Auto spread filter — skip if spread is abnormally wide
   double spreadPts = GetSpreadPoints();
   double maxAllowed = spreadEma * Inp_MaxSpreadMult;
   if(spreadPts > maxAllowed)
   {
      PrintFormat("Spread spike: %.0f pts (avg=%.0f, max=%.0f) — skipping",
                  spreadPts, spreadEma, maxAllowed);
      CancelAllPending();
      return;
   }

   //5. Volatility check — need some movement to trade
   double atrPts = GetAtrPoints();
   if(atrPts < 1)   // fallback guard only
   {
      Print("ATR near zero — skipping");
      return;
   }

   //6. Place bracket
   PlaceBracket(spreadPts, atrPts);
}

//════════════════════════════════════════════════════════════════════
//  PLACE BRACKET — all distances auto-calculated
//════════════════════════════════════════════════════════════════════
void PlaceBracket(double spreadPts, double atrPts)
{
   CancelAllPending();

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid    = (bid + ask) / 2.0;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // SL: larger of (spread × mult) or (ATR × mult) — always safe
   double slPts  = MathMax(spreadPts * Inp_SL_SpreadMult,
                           atrPts    * Inp_SL_AtrMult);

   // Gap: proportional to spread so entry is reachable but above noise
   double gapPts = spreadPts * Inp_Gap_SpreadMult;

   double slDist  = slPts  * point;
   double gapDist = gapPts * point;

   double buyEntry  = NormalizeDouble(mid + gapDist, digits);
   double buySL     = NormalizeDouble(buyEntry - slDist, digits);
   double sellEntry = NormalizeDouble(mid - gapDist, digits);
   double sellSL    = NormalizeDouble(sellEntry + slDist, digits);

   double lots = CalculateLots(slPts);

   PrintFormat("Bracket | spread=%.0f avg=%.0f | gap=%.0f sl=%.0f atr=%.0f | lots=%.2f",
               spreadPts, spreadEma, gapPts, slPts, atrPts, lots);

   if(!trade.BuyStop(lots, buyEntry, _Symbol, buySL, 0,
                     ORDER_TIME_GTC, 0, "GH-BUY"))
      PrintFormat("BuyStop failed | %.5f sl=%.5f err=%d", buyEntry, buySL, GetLastError());

   if(!trade.SellStop(lots, sellEntry, _Symbol, sellSL, 0,
                      ORDER_TIME_GTC, 0, "GH-SELL"))
      PrintFormat("SellStop failed | %.5f sl=%.5f err=%d", sellEntry, sellSL, GetLastError());
}

//════════════════════════════════════════════════════════════════════
//  TRAILING STOP — ATR-based, adapts to volatility
//════════════════════════════════════════════════════════════════════
void ManageTrailing()
{
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atrPts   = GetAtrPoints();
   double spreadPts = GetSpreadPoints();

   // Trail step adapts to current volatility
   double trailStep    = atrPts    * Inp_Trail_AtrMult  * point;
   // Trail starts when profit >= spread (trade has cleared the spread cost)
   double trailTrigger = spreadPts * Inp_Trail_TrigMult * point;

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
         if(bid - openPrice < trailTrigger) continue;
         double idealSL = NormalizeDouble(bid - trailStep, digits);
         if(idealSL > currentSL + point)
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail BUY  #%I64u | sl %.5f → %.5f", ticket, currentSL, idealSL);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(openPrice - ask < trailTrigger) continue;
         double idealSL = NormalizeDouble(ask + trailStep, digits);
         if(idealSL < currentSL - point)
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail SELL #%I64u | sl %.5f → %.5f", ticket, currentSL, idealSL);
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  CLOSED POSITION DETECTION
//════════════════════════════════════════════════════════════════════
void CheckForClosedPosition()
{
   bool posOpen = HasOpenPosition();

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
         PrintFormat("Trade closed | #%I64u  P&L=%.2f", lastPosTkt, pnl);
         break;
      }
      lastPosTkt = 0;
   }

   if(posOpen && lastPosTkt == 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;
         lastPosTkt = ticket;
         CancelAllPending();
         PrintFormat("Fill | #%I64u  %s  %.2f lots @ %.5f  SL=%.5f",
                     ticket,
                     PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?"BUY":"SELL",
                     PositionGetDouble(POSITION_VOLUME),
                     PositionGetDouble(POSITION_PRICE_OPEN),
                     PositionGetDouble(POSITION_SL));
         break;
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  HELPERS
//════════════════════════════════════════════════════════════════════

// Slow EMA of spread — learns broker's normal spread automatically
void UpdateSpreadEma()
{
   double s = GetSpreadPoints();
   if(!spreadEmaReady) { spreadEma = s; spreadEmaReady = true; return; }
   spreadEma = spreadEma * 0.98 + s * 0.02;  // ~50-tick EMA
}

// Current spread in points
double GetSpreadPoints()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 1;
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;
}

// ATR in points (M1, period 14)
double GetAtrPoints()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) < 1) return GetSpreadPoints() * 2;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 1;
   return buf[0] / point;
}

// Risk-based or fixed lot sizing
double CalculateLots(double slPoints)
{
   if(!Inp_UseDynamicLots) return Inp_FixedLot;

   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash     = balance * Inp_RiskPct / 100.0;
   double point        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0) return Inp_MinLot;

   double slValuePerLot = (slPoints * point / tickSize) * tickValue;
   if(slValuePerLot <= 0) return Inp_MinLot;

   double lots    = riskCash / slValuePerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

   return NormalizeDouble(MathMax(Inp_MinLot, MathMin(Inp_MaxLot, lots)), 2);
}

// Session filter
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= Inp_SessionStartUTC && dt.hour < Inp_SessionEndUTC);
}

// Cancel all pending orders
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

// Close all positions
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

// Has open position
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
