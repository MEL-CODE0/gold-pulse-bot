"""
MT5 order execution layer  (Adaptive v5.0)
==========================================
Key fix: ORDER_FILLING_FOK (required by Exness).
         ORDER_FILLING_IOC was causing all orders to fail silently.
"""

import MetaTrader5 as mt5

import config
from utils.logger import get_logger

log = get_logger("MT5Trader")


# ── Connection ────────────────────────────────────────────────────────────────

def connect(login: int, password: str, server: str) -> bool:
    if not mt5.initialize():
        log.error(f"MT5 initialize() failed: {mt5.last_error()}")
        return False

    info = mt5.account_info()

    if info and info.login == login:
        log.info(
            f"Using active MT5 session | Account: {info.login} | "
            f"Broker: {info.company} | Balance: {info.balance:.2f} {info.currency}"
        )
        _log_symbol_info()
        return True

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
        _log_symbol_info()
        return True

    log.error(
        f"MT5 active account ({info.login if info else 'none'}) != requested ({login}). "
        "Set MT5_PASSWORD in .env to allow switching accounts."
    )
    mt5.shutdown()
    return False


def _log_symbol_info() -> None:
    """Print broker-specific symbol parameters on startup for diagnostics."""
    info = mt5.symbol_info(config.SYMBOL)
    if info is None:
        log.warning(f"Cannot read symbol info for {config.SYMBOL}")
        return
    tick = mt5.symbol_info_tick(config.SYMBOL)
    spread = round((tick.ask - tick.bid) / info.point) if tick and info.point else 0
    log.info(
        f"Symbol info | {config.SYMBOL}  digits={info.digits}  "
        f"point={info.point:.6f}  tick_size={info.trade_tick_size:.6f}  "
        f"tick_value={info.trade_tick_value:.6f}  contract={info.trade_contract_size:.2f}  "
        f"spread~{spread:.0f}pts"
    )


def disconnect() -> None:
    mt5.shutdown()
    log.info("MT5 disconnected")


# ── Symbol helpers ────────────────────────────────────────────────────────────

def get_tick() -> mt5.Tick | None:
    tick = mt5.symbol_info_tick(config.SYMBOL)
    if tick is None:
        log.warning(f"No tick data for {config.SYMBOL}")
    return tick


def get_point() -> float:
    info = mt5.symbol_info(config.SYMBOL)
    return info.point if info else 0.001


def get_digits() -> int:
    info = mt5.symbol_info(config.SYMBOL)
    return info.digits if info else 2


def normalise_price(price: float) -> float:
    return round(price, get_digits())


# ── Pending orders ────────────────────────────────────────────────────────────

def cancel_all_pending() -> int:
    orders = mt5.orders_get(symbol=config.SYMBOL) or []
    cancelled = 0
    for order in orders:
        if order.magic != config.BOT_MAGIC:
            continue
        if order.type not in (mt5.ORDER_TYPE_BUY_STOP, mt5.ORDER_TYPE_SELL_STOP):
            continue
        result = mt5.order_send({
            "action": mt5.TRADE_ACTION_REMOVE,
            "order":  order.ticket,
        })
        if result and result.retcode == mt5.TRADE_RETCODE_DONE:
            cancelled += 1
            log.debug(f"Cancelled order #{order.ticket}")
        else:
            log.warning(f"Cancel failed #{order.ticket}: {result}")
    return cancelled


def has_pending_orders() -> bool:
    orders = mt5.orders_get(symbol=config.SYMBOL) or []
    return any(
        o.magic == config.BOT_MAGIC and
        o.type in (mt5.ORDER_TYPE_BUY_STOP, mt5.ORDER_TYPE_SELL_STOP)
        for o in orders
    )


def place_buy_stop(entry: float, sl: float, lots: float,
                   comment: str = "GP-BUY") -> int | None:
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
        "type_filling": mt5.ORDER_FILLING_FOK,   # FOK required by Exness
        "type_time":    mt5.ORDER_TIME_GTC,
    }
    result = mt5.order_send(req)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        log.info(f"BUY STOP  | entry={entry:.3f}  sl={sl:.3f}  lots={lots}  #{result.order}")
        return result.order
    log.warning(f"BUY STOP failed | entry={entry:.3f}  err={result.retcode if result else '?'}")
    return None


def place_sell_stop(entry: float, sl: float, lots: float,
                    comment: str = "GP-SELL") -> int | None:
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
        "type_filling": mt5.ORDER_FILLING_FOK,   # FOK required by Exness
        "type_time":    mt5.ORDER_TIME_GTC,
    }
    result = mt5.order_send(req)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        log.info(f"SELL STOP | entry={entry:.3f}  sl={sl:.3f}  lots={lots}  #{result.order}")
        return result.order
    log.warning(f"SELL STOP failed | entry={entry:.3f}  err={result.retcode if result else '?'}")
    return None


# ── Open positions ────────────────────────────────────────────────────────────

def get_open_position() -> mt5.TradePosition | None:
    positions = mt5.positions_get(symbol=config.SYMBOL) or []
    for pos in positions:
        if pos.magic == config.BOT_MAGIC:
            return pos
    return None


def modify_sl(ticket: int, new_sl: float) -> bool:
    result = mt5.order_send({
        "action":   mt5.TRADE_ACTION_SLTP,
        "position": ticket,
        "sl":       normalise_price(new_sl),
        "tp":       0.0,
    })
    ok = result and result.retcode == mt5.TRADE_RETCODE_DONE
    if ok:
        log.debug(f"SL updated #{ticket} → {new_sl:.3f}")
    else:
        log.warning(f"SL update failed #{ticket}: {result.retcode if result else '?'}")
    return ok


def close_position(position: mt5.TradePosition) -> bool:
    tick = get_tick()
    if tick is None:
        return False
    is_buy = position.type == mt5.POSITION_TYPE_BUY
    price  = tick.bid if is_buy else tick.ask
    result = mt5.order_send({
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       config.SYMBOL,
        "volume":       position.volume,
        "type":         mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
        "position":     position.ticket,
        "price":        normalise_price(price),
        "magic":        config.BOT_MAGIC,
        "comment":      "GP-CLOSE",
        "type_filling": mt5.ORDER_FILLING_FOK,
    })
    ok = result and result.retcode == mt5.TRADE_RETCODE_DONE
    if ok:
        log.info(f"Closed #{position.ticket} at {price:.3f}")
    else:
        log.warning(f"Close failed #{position.ticket}: {result.retcode if result else '?'}")
    return ok
