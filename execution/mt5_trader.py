"""
MT5 order execution layer for GoldPulse.
Handles: connection, pending order placement, SL modification, cancellation.
"""

import time
from typing import Optional

import MetaTrader5 as mt5

import config
from utils.logger import get_logger

log = get_logger("MT5Trader")


# ── Connection ────────────────────────────────────────────────────────────────

def connect(login: int, password: str, server: str) -> bool:
    """
    Initialise MT5 and verify the correct account is active.
    If MT5 is already running and logged into `login`, we reuse that session.
    If a password is provided and the account differs, we attempt a fresh login.
    """
    if not mt5.initialize():
        log.error(f"MT5 initialize() failed: {mt5.last_error()}")
        return False

    info = mt5.account_info()

    # Already on the right account — just reuse the active session
    if info and info.login == login:
        log.info(
            f"Using active MT5 session | Account: {info.login} | "
            f"Broker: {info.company} | Balance: {info.balance:.2f} {info.currency}"
        )
        return True

    # Different account or not logged in — attempt explicit login
    if password:
        if not mt5.login(login, password=password, server=server):
            log.error(f"MT5 login failed: {mt5.last_error()}")
            mt5.shutdown()
            return False
        info = mt5.account_info()
        log.info(
            f"Connected | Account: {info.login} | "
            f"Broker: {info.company} | Balance: {info.balance:.2f} {info.currency}"
        )
        return True

    log.error(
        f"MT5 active account ({info.login if info else 'none'}) != requested ({login}). "
        "Set MT5_PASSWORD in .env to allow switching accounts."
    )
    mt5.shutdown()
    return False


def disconnect() -> None:
    mt5.shutdown()
    log.info("MT5 disconnected")


# ── Symbol helpers ────────────────────────────────────────────────────────────

def get_tick() -> Optional[mt5.Tick]:
    tick = mt5.symbol_info_tick(config.SYMBOL)
    if tick is None:
        log.warning(f"No tick data for {config.SYMBOL}")
    return tick


def get_point() -> float:
    info = mt5.symbol_info(config.SYMBOL)
    return info.point if info else 0.01


def normalise_price(price: float) -> float:
    """Round price to symbol's digit precision."""
    info = mt5.symbol_info(config.SYMBOL)
    digits = info.digits if info else 2
    return round(price, digits)


# ── Pending orders ────────────────────────────────────────────────────────────

def cancel_all_pending() -> int:
    """Cancel all pending orders for this symbol placed by this bot. Returns count."""
    orders = mt5.orders_get(symbol=config.SYMBOL) or []
    cancelled = 0
    for order in orders:
        if order.magic != config.BOT_MAGIC:
            continue
        if order.type not in (mt5.ORDER_TYPE_BUY_STOP, mt5.ORDER_TYPE_SELL_STOP):
            continue
        req = {
            "action":  mt5.TRADE_ACTION_REMOVE,
            "order":   order.ticket,
        }
        result = mt5.order_send(req)
        if result and result.retcode == mt5.TRADE_RETCODE_DONE:
            cancelled += 1
            log.debug(f"Cancelled order #{order.ticket}")
        else:
            log.warning(f"Failed to cancel #{order.ticket}: {result}")
    return cancelled


def place_buy_stop(entry: float, sl: float, lots: float,
                   comment: str = "GP-BUY") -> Optional[int]:
    """Place a BUY STOP order. Returns ticket on success, None on failure."""
    req = {
        "action":       mt5.TRADE_ACTION_PENDING,
        "symbol":       config.SYMBOL,
        "volume":       lots,
        "type":         mt5.ORDER_TYPE_BUY_STOP,
        "price":        normalise_price(entry),
        "sl":           normalise_price(sl),
        "tp":           0.0,
        "magic":        config.BOT_MAGIC,
        "comment":      comment,
        "type_filling": mt5.ORDER_FILLING_IOC,
        "type_time":    mt5.ORDER_TIME_GTC,
    }
    result = mt5.order_send(req)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        log.info(f"BUY STOP placed  | entry={entry:.2f}  sl={sl:.2f}  lots={lots}  ticket={result.order}")
        return result.order
    log.warning(f"BUY STOP failed  | entry={entry:.2f}  sl={sl:.2f}  retcode={result.retcode if result else '?'}")
    return None


def place_sell_stop(entry: float, sl: float, lots: float,
                    comment: str = "GP-SELL") -> Optional[int]:
    """Place a SELL STOP order. Returns ticket on success, None on failure."""
    req = {
        "action":       mt5.TRADE_ACTION_PENDING,
        "symbol":       config.SYMBOL,
        "volume":       lots,
        "type":         mt5.ORDER_TYPE_SELL_STOP,
        "price":        normalise_price(entry),
        "sl":           normalise_price(sl),
        "tp":           0.0,
        "magic":        config.BOT_MAGIC,
        "comment":      comment,
        "type_filling": mt5.ORDER_FILLING_IOC,
        "type_time":    mt5.ORDER_TIME_GTC,
    }
    result = mt5.order_send(req)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        log.info(f"SELL STOP placed | entry={entry:.2f}  sl={sl:.2f}  lots={lots}  ticket={result.order}")
        return result.order
    log.warning(f"SELL STOP failed | entry={entry:.2f}  sl={sl:.2f}  retcode={result.retcode if result else '?'}")
    return None


# ── Open positions ────────────────────────────────────────────────────────────

def get_open_position() -> Optional[mt5.TradePosition]:
    """Return the first open position for this symbol/magic, or None."""
    positions = mt5.positions_get(symbol=config.SYMBOL) or []
    for pos in positions:
        if pos.magic == config.BOT_MAGIC:
            return pos
    return None


def modify_sl(ticket: int, new_sl: float) -> bool:
    """Move stop-loss on an open position."""
    req = {
        "action":   mt5.TRADE_ACTION_SLTP,
        "position": ticket,
        "sl":       normalise_price(new_sl),
        "tp":       0.0,
    }
    result = mt5.order_send(req)
    ok = result and result.retcode == mt5.TRADE_RETCODE_DONE
    if ok:
        log.debug(f"SL updated | position #{ticket}  new_sl={new_sl:.2f}")
    else:
        log.warning(f"SL update failed | #{ticket}  retcode={result.retcode if result else '?'}")
    return ok


def close_position(position: mt5.TradePosition) -> bool:
    """Market-close an open position immediately."""
    tick = get_tick()
    if tick is None:
        return False

    is_buy  = position.type == mt5.POSITION_TYPE_BUY
    price   = tick.bid if is_buy else tick.ask
    order_t = mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY

    req = {
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       config.SYMBOL,
        "volume":       position.volume,
        "type":         order_t,
        "position":     position.ticket,
        "price":        normalise_price(price),
        "magic":        config.BOT_MAGIC,
        "comment":      "GP-CLOSE",
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    result = mt5.order_send(req)
    ok = result and result.retcode == mt5.TRADE_RETCODE_DONE
    if ok:
        log.info(f"Position #{position.ticket} closed at {price:.2f}")
    else:
        log.warning(f"Close failed #{position.ticket}: retcode={result.retcode if result else '?'}")
    return ok
