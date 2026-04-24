"""
Position sizer for GoldPulse.
Sizes each trade so that the SL distance risks exactly RISK_PCT_PER_TRADE
of current account balance, clamped to [MIN_LOT, MAX_LOT].
"""

import MetaTrader5 as mt5
import config
from utils.logger import get_logger

log = get_logger("Sizer")


def calculate_lot_size(sl_points: float) -> float:
    """
    Parameters
    ----------
    sl_points : float
        Distance from entry to stop-loss in price points.

    Returns
    -------
    float
        Lot size rounded to the nearest LOT_STEP.
    """
    account = mt5.account_info()
    if account is None:
        log.warning("Could not fetch account info — using minimum lot")
        return config.MIN_LOT

    balance   = account.balance
    risk_cash = balance * config.RISK_PCT_PER_TRADE   # e.g. $10,000 * 0.005 = $50

    info = mt5.symbol_info(config.SYMBOL)
    if info is None:
        log.warning("Could not fetch symbol info — using minimum lot")
        return config.MIN_LOT

    # tick_value = profit per 1 full lot per 1 tick movement
    # tick_size  = size of 1 tick in price
    # point_value = profit per 1 lot per 1 point = tick_value / tick_size * point
    point        = info.point               # e.g. 0.01 for XAUUSD
    tick_value   = info.trade_tick_value    # USD per 1 lot per 1 tick
    tick_size    = info.trade_tick_size     # size of 1 tick in price

    if tick_size == 0 or tick_value == 0:
        log.warning("Symbol tick data unavailable — using minimum lot")
        return config.MIN_LOT

    # Value of sl_points in USD for 1 standard lot
    sl_value_per_lot = (sl_points * point / tick_size) * tick_value

    if sl_value_per_lot <= 0:
        return config.MIN_LOT

    raw_lots = risk_cash / sl_value_per_lot

    # Round to valid lot step
    step     = config.LOT_STEP
    lots     = round(round(raw_lots / step) * step, 2)
    lots     = max(config.MIN_LOT, min(lots, config.MAX_LOT))

    log.debug(
        f"Sizer: balance=${balance:.2f}  risk=${risk_cash:.2f}  "
        f"SL={sl_points:.0f}pts  sl_val/lot=${sl_value_per_lot:.4f}  "
        f"lots={lots}"
    )
    return lots


def get_daily_pnl() -> float:
    """Return today's realised + unrealised P&L in account currency."""
    from datetime import datetime, timezone, timedelta

    account = mt5.account_info()
    if account is None:
        return 0.0

    # Realised: closed deals today
    today_start = datetime.now(timezone.utc).replace(
        hour=config.DAILY_RESET_HOUR_UTC, minute=0, second=0, microsecond=0
    )
    if datetime.now(timezone.utc) < today_start:
        today_start -= timedelta(days=1)

    deals = mt5.history_deals_get(today_start, datetime.now(timezone.utc))
    realised = sum(d.profit for d in deals) if deals else 0.0

    # Unrealised: open positions
    positions = mt5.positions_get(symbol=config.SYMBOL)
    unrealised = sum(p.profit for p in positions) if positions else 0.0

    return realised + unrealised


def is_daily_loss_limit_hit(start_of_day_balance: float) -> bool:
    """Return True if today's loss has exceeded MAX_DAILY_LOSS_PCT."""
    pnl = get_daily_pnl()
    if pnl >= 0:
        return False
    loss_pct = abs(pnl) / start_of_day_balance
    hit = loss_pct >= config.MAX_DAILY_LOSS_PCT
    if hit:
        log.warning(
            f"Daily loss limit hit: {loss_pct*100:.2f}% >= {config.MAX_DAILY_LOSS_PCT*100:.1f}%"
            f"  (P&L: ${pnl:.2f})"
        )
    return hit
