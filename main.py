"""
GoldPulse Bot — Entry Point
============================
Run:   python main.py
Stop:  Ctrl+C
"""

import os
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as mt5
from dotenv import load_dotenv

# Load .env credentials
load_dotenv()

# Add project root to path so sub-packages can import config cleanly
sys.path.insert(0, os.path.dirname(__file__))

import config
from execution.mt5_trader import connect, disconnect
from strategy.gold_pulse  import GoldPulseStrategy
from utils.logger         import get_logger

log = get_logger("Main")


def get_credentials() -> tuple[int, str, str]:
    """Read MT5 credentials from .env → environment variables."""
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
    log.info("=" * 60)
    log.info("  GoldPulse Bot  |  XAUUSD Scalper")
    log.info(f"  Symbol  : {config.SYMBOL}")
    log.info(f"  Risk/trade: {config.RISK_PCT_PER_TRADE*100:.1f}%")
    log.info(f"  Session : {config.SESSION_START_UTC:02d}:00 - {config.SESSION_END_UTC:02d}:00 UTC")
    log.info(f"  Max DD  : {config.MAX_DAILY_LOSS_PCT*100:.1f}% daily")
    log.info("=" * 60)

    login, password, server = get_credentials()

    # Connect to MT5
    if not connect(login, password, server):
        sys.exit(1)

    try:
        # Verify symbol is available
        if not mt5.symbol_select(config.SYMBOL, True):
            log.error(f"Symbol {config.SYMBOL} not found on this account/broker")
            sys.exit(1)

        # Record start-of-day balance for daily loss limit tracking
        account = mt5.account_info()
        start_balance = account.balance
        log.info(f"Start-of-day balance: ${start_balance:,.2f}")

        # Auto-reset balance at midnight UTC
        current_day = datetime.now(timezone.utc).date()

        strategy = GoldPulseStrategy(start_of_day_balance=start_balance)

        log.info("Bot running. Press Ctrl+C to stop.")

        while True:
            # Midnight reset
            today = datetime.now(timezone.utc).date()
            if today != current_day:
                account = mt5.account_info()
                start_balance = account.balance
                strategy.start_of_day_balance = start_balance
                current_day = today
                log.info(f"New day started — balance reset to ${start_balance:,.2f}")

            strategy._tick()
            time.sleep(1)

    except KeyboardInterrupt:
        log.info("Shutdown requested by user")
    except Exception as e:
        log.error(f"Fatal error: {e}", exc_info=True)
    finally:
        disconnect()
        log.info("GoldPulse Bot stopped.")


if __name__ == "__main__":
    main()
