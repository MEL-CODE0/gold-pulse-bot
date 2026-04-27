"""
GoldPulse Bot  —  Entry Point  (Adaptive v5.0)
Run:   python main.py
Stop:  Ctrl+C
"""

import os
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5
from dotenv import load_dotenv

load_dotenv()
sys.path.insert(0, os.path.dirname(__file__))

import config
from execution.mt5_trader import connect, disconnect
from strategy.gold_pulse  import GoldPulseStrategy
from utils.logger         import get_logger

log = get_logger("Main")


def get_credentials() -> tuple[int, str, str]:
    login_str = os.getenv("MT5_LOGIN", "")
    password  = os.getenv("MT5_PASSWORD", "")
    server    = os.getenv("MT5_SERVER", "")

    if not all([login_str, server]):
        log.error(
            "MT5 credentials missing. "
            "Copy .env.example to .env and fill in MT5_LOGIN and MT5_SERVER."
        )
        sys.exit(1)

    try:
        login = int(login_str)
    except ValueError:
        log.error(f"MT5_LOGIN must be an integer, got: {login_str!r}")
        sys.exit(1)

    return login, password, server


def main() -> None:
    log.info("=" * 62)
    log.info("  GoldPulse Bot  v5.0  —  Tick-Reactive Adaptive Scalper")
    log.info(f"  Symbol      : {config.SYMBOL}")
    log.info(f"  Risk/trade  : {config.RISK_PCT_PER_TRADE * 100:.1f}%")
    log.info(f"  Session UTC : {config.SESSION_START_UTC:02d}:00 – {config.SESSION_END_UTC:02d}:00")
    log.info(f"  Max DD/day  : {config.MAX_DAILY_LOSS_PCT * 100:.1f}%")
    log.info(f"  Gap mult    : ATR × {config.GAP_ATR_MULT}")
    log.info(f"  SL mult     : max(spread×{config.SL_SPREAD_MULT}, ATR×{config.SL_ATR_MULT})")
    log.info(f"  Trail mult  : ATR × {config.TRAIL_ATR_MULT}")
    log.info(f"  Spike filter: spread > avg × {config.SPREAD_SPIKE_X}")
    log.info(f"  Auto-refresh: when spread/ATR shifts > {config.REFRESH_CHANGE_PCT:.0f}%")
    log.info("=" * 62)

    login, password, server = get_credentials()

    if not connect(login, password, server):
        sys.exit(1)

    try:
        if not mt5.symbol_select(config.SYMBOL, True):
            log.error(f"Symbol {config.SYMBOL} not available on this account/broker")
            sys.exit(1)

        account        = mt5.account_info()
        start_balance  = account.balance
        log.info(f"Start-of-day balance: {start_balance:.2f} {account.currency}")

        current_day = datetime.now(timezone.utc).date()
        strategy    = GoldPulseStrategy(start_of_day_balance=start_balance)

        log.info("Bot running. Press Ctrl+C to stop.")

        while True:
            # Midnight reset
            today = datetime.now(timezone.utc).date()
            if today != current_day:
                account       = mt5.account_info()
                start_balance = account.balance
                strategy.start_of_day_balance = start_balance
                current_day   = today
                log.info(f"New day — balance reset to {start_balance:.2f}")

            strategy._tick()
            time.sleep(0.5)   # 0.5 s loop = faster reaction than 1 s

    except KeyboardInterrupt:
        log.info("Shutdown requested")
    except Exception as e:
        log.error(f"Fatal error: {e}", exc_info=True)
    finally:
        disconnect()
        log.info("GoldPulse Bot stopped.")


if __name__ == "__main__":
    main()
