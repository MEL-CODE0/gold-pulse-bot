"""
Spread & volatility filter.
Blocks trading when spread is abnormally wide (news/low liquidity)
or when ATR indicates a dead or explosive market.
"""

import MetaTrader5 as mt5
import pandas as pd

import config
from utils.logger import get_logger

log = get_logger("SpreadFilter")


def get_current_spread_points() -> float:
    """Return current bid/ask spread in price points (not pips)."""
    tick = mt5.symbol_info_tick(config.SYMBOL)
    if tick is None:
        return 0.0
    info = mt5.symbol_info(config.SYMBOL)
    if info is None:
        return 0.0
    spread_price = tick.ask - tick.bid
    # Convert to points (smallest price increment)
    point = info.point
    return round(spread_price / point) if point else 0.0


def is_spread_ok() -> tuple[bool, float]:
    """Return (True, spread_pts) if spread is acceptable, (False, spread_pts) if too wide."""
    if not config.SPREAD_FILTER_ENABLED:
        return True, 0.0

    spread = get_current_spread_points()
    ok = spread <= config.MAX_SPREAD_POINTS
    if not ok:
        log.info(f"Spread too wide: {spread:.0f} pts (max {config.MAX_SPREAD_POINTS})")
    return ok, spread


def get_atr_points(period: int = 14, timeframe: int = mt5.TIMEFRAME_M1) -> float:
    """Compute ATR(period) on the given timeframe. Returns value in price points."""
    bars = mt5.copy_rates_from_pos(config.SYMBOL, timeframe, 0, period + 5)
    if bars is None or len(bars) < period + 1:
        return 0.0

    df = pd.DataFrame(bars)
    df["prev_close"] = df["close"].shift(1)
    df["tr"] = df[["high", "low", "prev_close"]].apply(
        lambda r: max(r["high"] - r["low"],
                      abs(r["high"] - r["prev_close"]),
                      abs(r["low"]  - r["prev_close"])),
        axis=1,
    )
    atr_price = df["tr"].iloc[-period:].mean()
    info = mt5.symbol_info(config.SYMBOL)
    point = info.point if info else 0.00001
    return atr_price / point


def is_volatility_ok() -> tuple[bool, float]:
    """
    Return (True, atr_pts) if volatility is in the acceptable band.
    Too low  → dead market (holiday / after-hours).
    Too high → news spike (dangerous fills, massive slippage).
    """
    if not config.VOLATILITY_FILTER_ENABLED:
        return True, 0.0

    atr = get_atr_points(period=config.TRAIL_ATR_PERIOD)

    if atr < config.ATR_MIN_POINTS:
        log.info(f"ATR too low: {atr:.0f} pts < {config.ATR_MIN_POINTS} (dead market)")
        return False, atr

    if atr > config.ATR_MAX_POINTS:
        log.info(f"ATR too high: {atr:.0f} pts > {config.ATR_MAX_POINTS} (news spike)")
        return False, atr

    return True, atr
