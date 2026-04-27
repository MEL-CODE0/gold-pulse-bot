"""
GoldHunterV8 v5.0 — Python Backtester
=======================================
Pulls real M1 bars from MT5, simulates the adaptive bracket strategy,
and reports balance curve + drawdown.

Run:  python backtest/backtest_v5.py
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime, timezone

# ── Parameters to test ────────────────────────────────────────────────────────
SYMBOL        = "XAUUSDc"
START_DATE    = datetime(2024, 1, 1, tzinfo=timezone.utc)
END_DATE      = datetime(2026, 4, 1, tzinfo=timezone.utc)
START_BALANCE = 1197.0          # USC

SPREAD_PTS    = 280.0           # Fixed spread assumption (XAUUSDc typical)
SESSION_START = 7               # UTC hour
SESSION_END   = 21              # UTC hour

# Grid of configs to test — we try multiple risk levels to find lowest drawdown
CONFIGS = [
    {"name": "Risk 1.0%",  "risk": 0.010, "gap_atr": 0.25, "sl_spread": 1.5, "sl_atr": 0.5, "trail_atr": 0.28, "trail_trig": 0.4, "be_sl": 0.7},
    {"name": "Risk 0.5%",  "risk": 0.005, "gap_atr": 0.25, "sl_spread": 1.5, "sl_atr": 0.5, "trail_atr": 0.28, "trail_trig": 0.4, "be_sl": 0.7},
    {"name": "Risk 0.3%",  "risk": 0.003, "gap_atr": 0.25, "sl_spread": 1.5, "sl_atr": 0.5, "trail_atr": 0.28, "trail_trig": 0.4, "be_sl": 0.7},
    {"name": "Risk 0.5% TightSL", "risk": 0.005, "gap_atr": 0.20, "sl_spread": 2.0, "sl_atr": 0.6, "trail_atr": 0.25, "trail_trig": 0.5, "be_sl": 0.6},
    {"name": "Risk 0.5% WideSL",  "risk": 0.005, "gap_atr": 0.30, "sl_spread": 1.2, "sl_atr": 0.4, "trail_atr": 0.30, "trail_trig": 0.3, "be_sl": 0.8},
]

MIN_LOT  = 0.01
MAX_LOT  = 1.00
LOT_STEP = 0.01
TICK_VAL = 0.10    # USC per point per lot on XAUUSDc (from live test)
POINT    = 0.001

# ── MT5 data fetch ────────────────────────────────────────────────────────────

def fetch_bars():
    print("Connecting to MT5...")
    if not mt5.initialize():
        print(f"MT5 init failed: {mt5.last_error()}")
        sys.exit(1)

    print(f"Fetching M1 bars {START_DATE.date()} to {END_DATE.date()} ...")
    bars = mt5.copy_rates_range(SYMBOL, mt5.TIMEFRAME_M1, START_DATE, END_DATE)
    mt5.shutdown()

    if bars is None or len(bars) == 0:
        print("No data returned from MT5")
        sys.exit(1)

    df = pd.DataFrame(bars)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.set_index("time", inplace=True)
    print(f"Loaded {len(df):,} M1 bars")
    return df

# ── ATR calculation ────────────────────────────────────────────────────────────

def compute_atr(df, period=14):
    high  = df["high"]
    low   = df["low"]
    close = df["close"].shift(1)
    tr    = pd.concat([high - low,
                       (high - close).abs(),
                       (low  - close).abs()], axis=1).max(axis=1)
    atr   = tr.rolling(period).mean()
    return (atr / POINT).fillna(0)   # in points

# ── Lot sizing ────────────────────────────────────────────────────────────────

def calc_lots(balance, sl_pts, risk_pct):
    risk_cash      = balance * risk_pct
    sl_value_per_lot = sl_pts * TICK_VAL
    if sl_value_per_lot <= 0:
        return MIN_LOT
    lots = risk_cash / sl_value_per_lot
    lots = max(MIN_LOT, min(MAX_LOT, round(round(lots / LOT_STEP) * LOT_STEP, 2)))
    return lots

# ── Session check ─────────────────────────────────────────────────────────────

def in_session(ts):
    return SESSION_START <= ts.hour < SESSION_END

# ── Single backtest run ───────────────────────────────────────────────────────

def run_backtest(df, atr_series, cfg):
    balance      = START_BALANCE
    peak_balance = START_BALANCE
    max_dd       = 0.0
    min_balance  = START_BALANCE

    balance_curve = [START_BALANCE]
    dates_curve   = [df.index[0]]

    # Position state
    in_pos        = False
    pos_type      = None   # 'buy' or 'sell'
    pos_entry     = 0.0
    pos_sl        = 0.0
    pos_lots      = 0.0
    pos_open_bar  = 0

    # Pending bracket
    has_pending   = False
    buy_entry     = 0.0
    buy_sl        = 0.0
    sell_entry    = 0.0
    sell_sl       = 0.0
    pend_lots     = 0.0
    pend_bar      = 0
    placed_atr    = 0.0

    total_trades  = 0
    wins          = 0
    losses        = 0

    last_order_bar = -60   # force first placement at bar 14+

    bars = df.values        # [open, high, low, close, tick_vol, spread, real_vol]
    col  = {c: i for i, c in enumerate(df.columns)}
    O, H, L, C = col["open"], col["high"], col["low"], col["close"]

    n = len(bars)

    for i in range(14, n):
        bar   = bars[i]
        ts    = df.index[i]
        atr   = atr_series.iloc[i]
        o, h, l, c = bar[O], bar[H], bar[L], bar[C]

        if atr <= 0:
            continue

        # ── 1. Check if open position hits SL ─────────────────────────────────
        if in_pos:
            hit_sl = False
            pnl    = 0.0

            if pos_type == "buy":
                if l <= pos_sl:
                    # SL hit — exit at SL
                    pnl    = (pos_sl - pos_entry) / POINT * TICK_VAL * pos_lots
                    hit_sl = True
                else:
                    # Trail stop
                    trail_step = max(atr * cfg["trail_atr"] * POINT,
                                     SPREAD_PTS * 0.1 * POINT)
                    trail_trig = SPREAD_PTS * cfg["trail_trig"] * POINT
                    profit     = c - pos_entry
                    if profit >= trail_trig:
                        # Break-even
                        sl_dist = pos_entry - pos_sl
                        if sl_dist > 0 and profit >= sl_dist * cfg["be_sl"]:
                            be_sl = pos_entry + SPREAD_PTS * 0.2 * POINT
                            if be_sl > pos_sl + POINT:
                                pos_sl = be_sl
                        # Trail
                        ideal_sl = c - trail_step
                        if ideal_sl > pos_sl + POINT:
                            pos_sl = ideal_sl

            elif pos_type == "sell":
                if h >= pos_sl:
                    pnl    = (pos_entry - pos_sl) / POINT * TICK_VAL * pos_lots
                    hit_sl = True
                else:
                    trail_step = max(atr * cfg["trail_atr"] * POINT,
                                     SPREAD_PTS * 0.1 * POINT)
                    trail_trig = SPREAD_PTS * cfg["trail_trig"] * POINT
                    profit     = pos_entry - c
                    if profit >= trail_trig:
                        sl_dist = pos_sl - pos_entry
                        if sl_dist > 0 and profit >= sl_dist * cfg["be_sl"]:
                            be_sl = pos_entry - SPREAD_PTS * 0.2 * POINT
                            if be_sl < pos_sl - POINT:
                                pos_sl = be_sl
                        ideal_sl = c + trail_step
                        if ideal_sl < pos_sl - POINT:
                            pos_sl = ideal_sl

            if hit_sl:
                balance += pnl
                total_trades += 1
                if pnl >= 0:
                    wins += 1
                else:
                    losses += 1
                in_pos = False
                has_pending = False
                last_order_bar = i   # brief cooldown

                balance_curve.append(balance)
                dates_curve.append(ts)

                if balance > peak_balance:
                    peak_balance = balance
                dd = (peak_balance - balance) / peak_balance * 100
                if dd > max_dd:
                    max_dd = dd
                if balance < min_balance:
                    min_balance = balance

        # ── 2. Fill pending orders ────────────────────────────────────────────
        if has_pending and not in_pos:
            # Cancel pending if placed more than 2 bars ago (bracket stale)
            if i - pend_bar > 2:
                has_pending = False
            else:
                filled = False
                if h >= buy_entry:
                    in_pos    = True
                    pos_type  = "buy"
                    pos_entry = buy_entry
                    pos_sl    = buy_sl
                    pos_lots  = pend_lots
                    filled    = True
                elif l <= sell_entry:
                    in_pos    = True
                    pos_type  = "sell"
                    pos_entry = sell_entry
                    pos_sl    = sell_sl
                    pos_lots  = pend_lots
                    filled    = True

                if filled:
                    has_pending = False

        # ── 3. Place new bracket every 60 bars (≈ 60 min) ────────────────────
        if (not in_pos and not has_pending
                and in_session(ts)
                and i - last_order_bar >= 60):

            gap_pts = max(atr * cfg["gap_atr"], SPREAD_PTS * 0.5)
            sl_pts  = max(SPREAD_PTS * cfg["sl_spread"], atr * cfg["sl_atr"])
            sl_pts  = max(sl_pts, SPREAD_PTS * 1.2)

            mid = (o + c) / 2.0

            buy_entry  = mid + gap_pts * POINT
            buy_sl     = buy_entry - sl_pts * POINT
            sell_entry = mid - gap_pts * POINT
            sell_sl    = sell_entry + sl_pts * POINT

            pend_lots  = calc_lots(balance, sl_pts, cfg["risk"])
            pend_bar   = i
            placed_atr = atr
            has_pending = True
            last_order_bar = i

    # ── Summary ───────────────────────────────────────────────────────────────
    net_pct  = (balance - START_BALANCE) / START_BALANCE * 100
    win_rate = wins / total_trades * 100 if total_trades > 0 else 0

    return {
        "name":         cfg["name"],
        "end_balance":  balance,
        "net_pct":      net_pct,
        "max_dd":       max_dd,
        "min_balance":  min_balance,
        "trades":       total_trades,
        "win_rate":     win_rate,
        "curve":        balance_curve,
        "dates":        dates_curve,
        "risk":         cfg["risk"],
    }

# ── Monthly snapshot ──────────────────────────────────────────────────────────

def monthly_summary(result):
    curve  = result["curve"]
    dates  = result["dates"]
    if not dates:
        return
    monthly = {}
    for dt, bal in zip(dates, curve):
        key = dt.strftime("%Y.%m")
        monthly[key] = bal
    print(f"\n  Monthly balance ({result['name']}):")
    prev = None
    for m in sorted(monthly):
        b = monthly[m]
        if prev:
            pct = (b - prev) / prev * 100
            tag = "+" if b >= prev else ""
            flag = " <-- DANGER" if pct < -15 else ""
            print(f"    {m}  {b:>14,.2f} USC  ({tag}{pct:.1f}%){flag}")
        else:
            print(f"    {m}  {b:>14,.2f} USC")
        prev = b

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    df  = fetch_bars()
    atr = compute_atr(df)

    print("\n" + "="*62)
    print("  BACKTEST RESULTS — GoldHunterV8 v5.0 Parameter Grid")
    print("="*62)
    print(f"  Period  : {df.index[0].date()} to {df.index[-1].date()}")
    print(f"  Start   : {START_BALANCE:.2f} USC")
    print(f"  Spread  : {SPREAD_PTS:.0f} pts (fixed)")
    print("="*62)

    results = []
    for cfg in CONFIGS:
        r = run_backtest(df, atr, cfg)
        results.append(r)
        print(f"\n  [{r['name']}]")
        print(f"    End balance : {r['end_balance']:>14,.2f} USC")
        print(f"    Net profit  : {r['net_pct']:>10.1f}%")
        print(f"    Max drawdown: {r['max_dd']:>10.2f}%  {'OK' if r['max_dd'] < 30 else 'HIGH' if r['max_dd'] < 50 else 'DANGEROUS'}")
        print(f"    Min balance : {r['min_balance']:>14,.2f} USC")
        print(f"    Trades      : {r['trades']:,}")
        print(f"    Win rate    : {r['win_rate']:.1f}%")

    # Best config = lowest drawdown with > 50% win rate
    valid    = [r for r in results if r["win_rate"] > 45]
    best     = min(valid, key=lambda r: r["max_dd"]) if valid else min(results, key=lambda r: r["max_dd"])

    print("\n" + "="*62)
    print(f"  RECOMMENDED CONFIG: {best['name']}")
    print(f"  Max drawdown : {best['max_dd']:.2f}%")
    print(f"  End balance  : {best['end_balance']:,.2f} USC")
    print(f"  Risk/trade   : {best['risk']*100:.1f}%")
    print("="*62)

    monthly_summary(best)

    # Write best risk to config
    best_risk = best["risk"]
    print(f"\n  Writing RISK_PCT_PER_TRADE = {best_risk} to config.py ...")

    config_path = os.path.join(os.path.dirname(__file__), "..", "config.py")
    with open(config_path, "r") as f:
        config_text = f.read()

    import re
    new_config = re.sub(
        r"RISK_PCT_PER_TRADE\s*=\s*[\d.]+",
        f"RISK_PCT_PER_TRADE   = {best_risk}",
        config_text
    )
    with open(config_path, "w") as f:
        f.write(new_config)

    print(f"  config.py updated: RISK_PCT_PER_TRADE = {best_risk}")
    print("\n  Done. Review results above, then run: python main.py")


if __name__ == "__main__":
    main()
