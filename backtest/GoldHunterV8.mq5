//+------------------------------------------------------------------+
//|                                           Gold Hunter V8.mq5     |
//|                    Adaptive v4.0  — Fully Auto                   |
//|                                                                   |
//|  ZERO hardcoded pip values. Everything — SL, gap, trail, lots — |
//|  auto-calculates from live spread + ATR every single cycle.      |
//|  Works on any broker, any digits, any spread condition.          |
//+------------------------------------------------------------------+
#property copyright "Gold Hunter V8 — Adaptive v4.0"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//════════════════════════════════════════════════════════════════════
//  INPUTS  — multipliers only, no pip values
//════════════════════════════════════════════════════════════════════

input group "=== TRADE SETTINGS ==="
input long   Inp_MagicNumber        = 5555;
input bool   Inp_UseTrailingStop    = true;
input double Inp_DailyProfitTarget  = 0.0;    // Daily profit target in account currency (0=off)

input group "=== RISK MANAGEMENT (auto-scales to ANY account) ==="
input bool   Inp_UseDynamicLots     = true;   // AUTO lot sizing from risk %
input double Inp_RiskPct            = 1.0;    // Risk % per trade  (e.g. 1.0 = 1%)
input double Inp_FixedLot           = 0.01;   // Used ONLY if dynamic lots OFF
input double Inp_MinLot             = 0.01;
input double Inp_MaxLot             = 1.00;
input double Inp_MaxDailyLossPct    = 2.0;    // Halt if day loss > X%  (0=off)

input group "=== AUTO-ADAPTIVE MULTIPLIERS (broker/spread agnostic) ==="
//  All distances derived from live ATR and spread — no manual pip entry needed.
input double Inp_Gap_AtrMult        = 0.25;   // Gap from mid = ATR × this
                                               //   ATR~150pts → gap~37pts  (fills fast)
input double Inp_SL_SpreadMult      = 1.5;    // SL >= spread × this  (clears spread noise)
input double Inp_SL_AtrMult         = 0.5;    // SL >= ATR   × this   (clears volatility)
input double Inp_Trail_AtrMult      = 0.30;   // Trail step  = ATR × this
input double Inp_Trail_TrigMult     = 0.5;    // Trail starts when profit >= spread × this
input double Inp_BE_SLMult          = 0.8;    // Move SL to break-even at profit >= SL × this

input group "=== SESSION FILTER ==="
input bool   Inp_SessionFilter      = true;
input int    Inp_SessionStartUTC    = 7;      // 07:00 UTC
input int    Inp_SessionEndUTC      = 21;     // 21:00 UTC

input group "=== LOSS PROTECTION ==="
input int    Inp_ConsecLossLimit    = 5;
input int    Inp_ConsecLossPauseMin = 60;

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════
CTrade   trade;
int      atrHandle      = INVALID_HANDLE;

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
   trade.SetTypeFilling(ORDER_FILLING_FOK);   // Required by Exness

   atrHandle = iATR(_Symbol, PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot create ATR indicator");
      return INIT_FAILED;
   }

   dayStartBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDayBar = iTime(_Symbol, PERIOD_D1, 0);

   //── Print diagnostics so the user can see broker parameters ──────
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSz= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double spread    = GetSpreadPoints();

   PrintFormat("=== Gold Hunter V8 Adaptive v4.0 STARTED ===");
   PrintFormat("Symbol      : %s",    _Symbol);
   PrintFormat("Digits      : %d",    digits);
   PrintFormat("Point       : %.6f",  point);
   PrintFormat("TickSize    : %.6f",  tickSz);
   PrintFormat("TickValue   : %.6f",  tickVal);
   PrintFormat("ContractSize: %.2f",  contractSz);
   PrintFormat("Spread now  : %.0f pts",  spread);
   PrintFormat("Balance     : %.2f %s",   dayStartBal,
               AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("Magic       : %I64d", Inp_MagicNumber);
   PrintFormat("DynLots     : %s  RiskPct=%.2f%%",
               Inp_UseDynamicLots ? "ON" : "OFF", Inp_RiskPct);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("Gold Hunter V8 Adaptive v4.0 stopped");
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
      dayStartBal    = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDayBar  = todayBar;
      dailyTargetHit = false;
      dailyLossHit   = false;
      consecLosses   = 0;
      pauseUntil     = 0;
      PrintFormat("New day | Balance=%.2f", dayStartBal);
   }

   //── Daily profit target ──────────────────────────────────────────
   if(!dailyTargetHit && Inp_DailyProfitTarget > 0)
   {
      if(AccountInfoDouble(ACCOUNT_EQUITY) - dayStartBal >= Inp_DailyProfitTarget)
      {
         Print("Daily profit target reached — closing all & halting");
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
         PrintFormat("Daily loss limit: -%.2f (max=%.2f) — halting", loss, maxLoss);
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

   //── Detect newly closed/opened positions ─────────────────────────
   CheckPositionState();

   //── New order cycle (every 60 sec) ───────────────────────────────
   if(TimeCurrent() - lastPlaceTime >= 60)
   {
      OrderCycle();
      lastPlaceTime = TimeCurrent();
   }
}

//════════════════════════════════════════════════════════════════════
//  ORDER CYCLE  — only two guards: session + consecutive loss pause
//  Spread and ATR are NOT filters — they drive the math instead.
//════════════════════════════════════════════════════════════════════
void OrderCycle()
{
   //1. Consecutive loss pause
   if(pauseUntil > 0 && TimeCurrent() < pauseUntil)
   {
      int remaining = (int)((pauseUntil - TimeCurrent()) / 60);
      if(remaining % 5 == 0)   // print every 5 min so log isn't flooded
         PrintFormat("Loss pause — %d min remaining", remaining);
      return;
   }

   //2. Skip if position already open
   if(HasOpenPosition()) return;

   //3. Session filter — cancel stale orders outside hours
   if(Inp_SessionFilter && !IsSessionActive())
   {
      CancelAllPending();
      return;
   }

   //4. Read live spread and ATR
   double spreadPts = GetSpreadPoints();
   double atrPts    = GetAtrPoints();

   //   If ATR hasn't loaded yet (first few bars) use spread × 2 as fallback
   if(atrPts <= 0) atrPts = spreadPts * 2.0;

   //5. Place bracket
   PlaceBracket(spreadPts, atrPts);
}

//════════════════════════════════════════════════════════════════════
//  PLACE BRACKET
//  Gap   = ATR  × Inp_Gap_AtrMult        (small — fills on normal momentum)
//  SL    = max(spread × SL_SpreadMult,
//              ATR    × SL_AtrMult)       (always wider than spread noise)
//  Lots  = auto risk% OR fixed            (scales to any balance)
//════════════════════════════════════════════════════════════════════
void PlaceBracket(double spreadPts, double atrPts)
{
   CancelAllPending();

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid    = (bid + ask) / 2.0;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //── Gap: fraction of ATR so entries fill on most candles ─────────
   double gapPts  = atrPts * Inp_Gap_AtrMult;
   // Safety floor: gap must be > half the spread (avoid immediate fill on current price)
   gapPts = MathMax(gapPts, spreadPts * 0.5);

   //── SL: must be wider than the spread so we aren't stopped instantly
   double slPts   = MathMax(spreadPts * Inp_SL_SpreadMult,
                             atrPts    * Inp_SL_AtrMult);
   // Hard floor: SL must be at least 1.2× spread no matter what
   slPts = MathMax(slPts, spreadPts * 1.2);

   double gapDist = gapPts * point;
   double slDist  = slPts  * point;

   double buyEntry  = NormalizeDouble(mid + gapDist, digits);
   double buySL     = NormalizeDouble(buyEntry - slDist, digits);
   double sellEntry = NormalizeDouble(mid - gapDist, digits);
   double sellSL    = NormalizeDouble(sellEntry + slDist, digits);

   double lots = CalculateLots(slPts);

   PrintFormat("──── ORDER CYCLE ────────────────────────────────");
   PrintFormat("spread=%.0f pts | ATR=%.0f pts | gap=%.0f pts | SL=%.0f pts",
               spreadPts, atrPts, gapPts, slPts);
   PrintFormat("mid=%.3f | BUY@%.3f sl=%.3f | SELL@%.3f sl=%.3f | lots=%.2f",
               mid, buyEntry, buySL, sellEntry, sellSL, lots);

   bool buyOk = trade.BuyStop(lots, buyEntry, _Symbol, buySL, 0,
                               ORDER_TIME_GTC, 0, "GH-BUY");
   if(!buyOk)
      PrintFormat("BuyStop FAILED  entry=%.3f sl=%.3f err=%d",
                  buyEntry, buySL, GetLastError());

   bool sellOk = trade.SellStop(lots, sellEntry, _Symbol, sellSL, 0,
                                 ORDER_TIME_GTC, 0, "GH-SELL");
   if(!sellOk)
      PrintFormat("SellStop FAILED entry=%.3f sl=%.3f err=%d",
                  sellEntry, sellSL, GetLastError());
}

//════════════════════════════════════════════════════════════════════
//  TRAILING STOP  — ATR-based with early break-even move
//════════════════════════════════════════════════════════════════════
void ManageTrailing()
{
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atrPts    = GetAtrPoints();
   double spreadPts = GetSpreadPoints();

   if(atrPts <= 0) atrPts = spreadPts * 2.0;

   // Trail step adapts to live volatility
   double trailStep = atrPts * Inp_Trail_AtrMult * point;
   // Trail activates when trade is >= half the spread in profit
   double trailTrig = spreadPts * Inp_Trail_TrigMult * point;

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
         if(profit < trailTrig) continue;   // not enough profit yet

         //── Break-even: move SL to entry+spread once we're up SL×BE_mult
         double slDist = openPrice - currentSL;
         if(slDist > 0 && profit >= slDist * Inp_BE_SLMult)
         {
            double beSL = NormalizeDouble(openPrice + spreadPts * 0.3 * point, digits);
            if(beSL > currentSL + point)
            {
               trade.PositionModify(ticket, beSL, 0);
               PrintFormat("BE BUY #%I64u | sl %.3f → %.3f (profit=%.0f pts)",
                           ticket, currentSL, beSL, profit/point);
               currentSL = beSL;
            }
         }

         //── Standard trail: ratchet SL up behind price
         double idealSL = NormalizeDouble(bid - trailStep, digits);
         if(idealSL > currentSL + point)
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail BUY  #%I64u | sl %.3f → %.3f (step=%.0f pts)",
                        ticket, currentSL, idealSL, trailStep/point);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         if(profit < trailTrig) continue;

         //── Break-even
         double slDist = currentSL - openPrice;
         if(slDist > 0 && profit >= slDist * Inp_BE_SLMult)
         {
            double beSL = NormalizeDouble(openPrice - spreadPts * 0.3 * point, digits);
            if(beSL < currentSL - point)
            {
               trade.PositionModify(ticket, beSL, 0);
               PrintFormat("BE SELL #%I64u | sl %.3f → %.3f (profit=%.0f pts)",
                           ticket, currentSL, beSL, profit/point);
               currentSL = beSL;
            }
         }

         //── Standard trail
         double idealSL = NormalizeDouble(ask + trailStep, digits);
         if(idealSL < currentSL - point)
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail SELL #%I64u | sl %.3f → %.3f (step=%.0f pts)",
                        ticket, currentSL, idealSL, trailStep/point);
         }
      }
   }
}

//════════════════════════════════════════════════════════════════════
//  POSITION STATE — detect fills and closes
//════════════════════════════════════════════════════════════════════
void CheckPositionState()
{
   bool posOpen = HasOpenPosition();

   //── Position just closed ─────────────────────────────────────────
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
               PrintFormat("PAUSE: %d consecutive losses — pausing %d min",
                           consecLosses, Inp_ConsecLossPauseMin);
            }
         }
         else
         {
            if(consecLosses > 0)
               PrintFormat("Win after %d losses — counter reset", consecLosses);
            consecLosses = 0;
         }
         PrintFormat("Trade closed | #%I64u  P&L=%.2f  consec=%d",
                     lastPosTkt, pnl, consecLosses);
         break;
      }
      lastPosTkt = 0;
   }

   //── New position just opened (fill detected) ─────────────────────
   if(posOpen && lastPosTkt == 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)  != Inp_MagicNumber) continue;

         lastPosTkt = ticket;
         CancelAllPending();   // cancel opposing pending order

         PrintFormat("Fill | #%I64u  %s  %.2f lots @ %.3f  SL=%.3f",
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
//  LOT SIZING  — auto-scales to ANY balance/currency/broker
//════════════════════════════════════════════════════════════════════
double CalculateLots(double slPoints)
{
   if(!Inp_UseDynamicLots) return Inp_FixedLot;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash  = balance * Inp_RiskPct / 100.0;
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return Inp_MinLot;

   // Value at risk for 1 lot over SL distance
   double slValuePerLot = (slPoints * point / tickSize) * tickValue;
   if(slValuePerLot <= 0) return Inp_MinLot;

   double lots    = riskCash / slValuePerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(Inp_MinLot, MathMin(Inp_MaxLot, lots));

   PrintFormat("LotCalc | balance=%.2f risk=%.2f slPts=%.0f slVal/lot=%.4f → lots=%.2f",
               balance, riskCash, slPoints, slValuePerLot, lots);

   return NormalizeDouble(lots, 2);
}

//════════════════════════════════════════════════════════════════════
//  UTILITY FUNCTIONS
//════════════════════════════════════════════════════════════════════

// Current spread in points (works on ANY digits)
double GetSpreadPoints()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 10;
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;
   return MathMax(spread, 1);   // never return 0
}

// ATR in points (M1, 14-bar). Falls back to 2× spread if not ready.
double GetAtrPoints()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) < 1) return 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0 || buf[0] <= 0) return 0;
   return buf[0] / point;
}

// Session filter: 07:00 – 21:00 UTC
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= Inp_SessionStartUTC && dt.hour < Inp_SessionEndUTC);
}

// Cancel all pending GH orders on this symbol
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

// Close all open positions
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

// Check if a position is open for this symbol+magic
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
