"""
Spread & ATR helpers  (Adaptive v5.0)
======================================
No hard-coded point values.
- get_current_spread_points()  → live spread in points
- get_atr_points()             → smoothed ATR(14,M1) in points
- is_spread_spike(spread_ema)  → True only when spread is abnormally wide

The bot passes spread and ATR into its own distance calculations.
There are no fixed min/max ATR filters — those were blocking trading.
"""

import MetaTrader5 as mt5
import pandas as pd

import config
from utils.logger import get_logger

log = get_logger("SpreadFilter")


def get_current_spread_points() -> float:
    """Return current bid/ask spread in price points."""
    tick = mt5.symbol_info_tick(config.SYMBOL)
    info = mt5.symbol_info(config.SYMBOL)
    if tick is None or info is None or info.point == 0:
        return 0.0
    return round((tick.ask - tick.bid) / info.point)


def get_atr_points(period: int = 14,
                   timeframe: int = mt5.TIMEFRAME_M1,
                   smooth: int = 3) -> float:
    """
    Compute ATR in price points.
    Uses average of the last `smooth` ATR values to reduce single-bar spikes.
    Returns 0.0 if insufficient data.
    """
    bars = mt5.copy_rates_from_pos(config.SYMBOL, timeframe, 0, period + smooth + 5)
    if bars is None or len(bars) < period + smooth:
        return 0.0

    df = pd.DataFrame(bars)
    df["prev_close"] = df["close"].shift(1)
    df["tr"] = df.apply(
        lambda r: max(
            r["high"] - r["low"],
            abs(r["high"] - r["prev_close"]) if pd.notna(r["prev_close"]) else 0,
            abs(r["low"]  - r["prev_close"]) if pd.notna(r["prev_close"]) else 0,
        ),
        axis=1,
    )

    info = mt5.symbol_info(config.SYMBOL)
    point = info.point if info else 0.00001

    # Rolling ATR, then average the last `smooth` ATR readings
    df["atr"] = df["tr"].rolling(period).mean()
    recent_atr = df["atr"].dropna().iloc[-smooth:]
    if recent_atr.empty:
        return 0.0

    return float(recent_atr.mean()) / point


def is_spread_spike(spread_ema: float) -> tuple[bool, float]:
    """
    Return (is_spike, current_spread_pts).
    A spike is spread > spread_ema × SPREAD_SPIKE_X.
    Returns (False, spread) during normal conditions.
    """
    spread = get_current_spread_points()
    if spread_ema <= 0:
        return False, spread   # EMA not ready yet — allow trading

    spike = spread > spread_ema * config.SPREAD_SPIKE_X
    if spike:
        log.info(f"Spread spike: {spread:.0f} pts  (avg={spread_ema:.0f}  "
                 f"threshold={spread_ema * config.SPREAD_SPIKE_X:.0f})")
    return spike, spread
