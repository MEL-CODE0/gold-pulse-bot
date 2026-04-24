//+------------------------------------------------------------------+
//|                                           Gold Hunter V8.mq5     |
//|                        Reconstructed from backtest behaviour      |
//|  Inputs match exactly: Lot, Magic, Gap, SL, Trail, DailyTarget   |
//+------------------------------------------------------------------+
#property copyright "Gold Hunter V8 — Reconstructed"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//── Inputs ──────────────────────────────────────────────────────────
input double  Inp_LotSize           = 0.02;    // Lot Size
input long    Inp_MagicNumber       = 5555;    // Magic Number
input int     Inp_GapPips           = 50;      // Gap between orders (pips)
input int     Inp_StopLossPips      = 50;      // Stop Loss (pips)
input int     Inp_TrailAfterPips    = 20;      // Trail after profit (pips)
input bool    Inp_UseTrailingStop   = true;    // Use trailing stop
input double  Inp_DailyProfitTarget = 100.0;   // Daily Profit Target ($)

//── Globals ──────────────────────────────────────────────────────────
CTrade   trade;
datetime lastPlaceTime   = 0;
double   dayStartBalance = 0;
datetime currentDayBar   = 0;
bool     dailyTargetHit  = false;

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDayBar   = iTime(_Symbol, PERIOD_D1, 0);

   PrintFormat("Gold Hunter V8 started | Balance=%.2f | Magic=%I64d",
               dayStartBalance, Inp_MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Gold Hunter V8 stopped");
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //── Daily bar reset ──────────────────────────────────────────────
   datetime todayBar = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBar != currentDayBar)
   {
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      currentDayBar   = todayBar;
      dailyTargetHit  = false;
      PrintFormat("New day — balance reset to %.2f", dayStartBalance);
   }

   //── Daily profit target check ────────────────────────────────────
   if(!dailyTargetHit)
   {
      double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double totalProfit = (equity - dayStartBalance);   // realised + floating

      if(totalProfit >= Inp_DailyProfitTarget)
      {
         PrintFormat("Daily profit target hit: %.2f >= %.2f — closing all",
                     totalProfit, Inp_DailyProfitTarget);
         CloseAllPositions();
         CancelAllPending();
         dailyTargetHit = true;
         return;
      }
   }

   if(dailyTargetHit) return;

   //── Trailing stop management ─────────────────────────────────────
   if(Inp_UseTrailingStop)
      ManageTrailing();

   //── Place bracket every 60 seconds ──────────────────────────────
   if(TimeCurrent() - lastPlaceTime >= 60)
   {
      PlaceBracket();
      lastPlaceTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Place Buy Stop + Sell Stop bracket around current price           |
//+------------------------------------------------------------------+
void PlaceBracket()
{
   // Cancel stale pending orders before placing fresh ones
   CancelAllPending();

   // Don't place new bracket if a position is already open
   if(HasOpenPosition()) return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid     = (bid + ask) / 2.0;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double gapDist = Inp_GapPips * point;
   double slDist  = Inp_StopLossPips * point;

   double buyEntry  = NormalizeDouble(mid + gapDist, digits);
   double buySL     = NormalizeDouble(buyEntry - slDist, digits);

   double sellEntry = NormalizeDouble(mid - gapDist, digits);
   double sellSL    = NormalizeDouble(sellEntry + slDist, digits);

   //── Place BUY STOP ───────────────────────────────────────────────
   if(!trade.BuyStop(Inp_LotSize, buyEntry, _Symbol, buySL, 0,
                     ORDER_TIME_GTC, 0, "GH-BUY"))
   {
      PrintFormat("BuyStop failed | entry=%.2f sl=%.2f | err=%d",
                  buyEntry, buySL, GetLastError());
   }

   //── Place SELL STOP ──────────────────────────────────────────────
   if(!trade.SellStop(Inp_LotSize, sellEntry, _Symbol, sellSL, 0,
                      ORDER_TIME_GTC, 0, "GH-SELL"))
   {
      PrintFormat("SellStop failed | entry=%.2f sl=%.2f | err=%d",
                  sellEntry, sellSL, GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Trail stop-loss once position is in profit >= TrailAfterPips      |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailDist  = Inp_StopLossPips   * point;   // keep same distance as SL
   double triggerDist = Inp_TrailAfterPips * point;   // profit needed to start trailing

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
         if(profit < triggerDist) continue;           // not enough profit yet

         double idealSL = NormalizeDouble(bid - trailDist, digits);
         if(idealSL > currentSL + point)              // only move SL UP
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail BUY #%I64u | new_sl=%.2f", ticket, idealSL);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         if(profit < triggerDist) continue;           // not enough profit yet

         double idealSL = NormalizeDouble(ask + trailDist, digits);
         if(idealSL < currentSL - point)              // only move SL DOWN
         {
            trade.PositionModify(ticket, idealSL, 0);
            PrintFormat("Trail SELL #%I64u | new_sl=%.2f", ticket, idealSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cancel all pending orders for this symbol + magic                 |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Close all open positions for this symbol + magic                  |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Check if any position is open for this symbol + magic             |
//+------------------------------------------------------------------+
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
