"""
GoldPulse Strategy — Core Logic
================================
Improved clone of Gold Hunter V8 with:
  - Dynamic spread-aware entry buffer
  - ATR-based trailing stop (adapts to volatility)
  - Session, news, spread, volatility filters
  - % risk position sizing
  - Consecutive loss protection
  - Daily loss limit halt

Cycle (every ORDER_INTERVAL_SEC seconds):
  1. Run all filters
  2. If open position exists → manage trailing stop only
  3. If flat → cancel stale pending, place fresh buy stop + sell stop
"""

import time
from datetime import datetime, timezone
from typing import Optional

import MetaTrader5 as mt5

import config
from execution.mt5_trader import (
    cancel_all_pending,
    close_position,
    get_open_position,
    get_point,
    get_tick,
    modify_sl,
    place_buy_stop,
    place_sell_stop,
)
from filters.news_filter    import is_news_window
from filters.session_filter import is_session_active
from filters.spread_filter  import get_atr_points, is_spread_ok, is_volatility_ok
from risk.sizer             import calculate_lot_size, is_daily_loss_limit_hit
from utils.logger           import get_logger

log = get_logger("GoldPulse")


class GoldPulseStrategy:
    """Stateful strategy runner — instantiate once and call .run_forever()."""

    def __init__(self, start_of_day_balance: float):
        self.start_of_day_balance = start_of_day_balance
        self._consec_losses       = 0
        self._pause_until: Optional[float] = None   # Unix timestamp
        self._last_order_time: float = 0.0
        self._last_trail_time: float = 0.0
        self._last_position_ticket: Optional[int] = None  # detect new fills

    # ── Main loop ─────────────────────────────────────────────────────────────

    def run_forever(self) -> None:
        """Main infinite loop. Call from main.py after MT5 connection."""
        log.info("GoldPulse strategy started")
        try:
            while True:
                self._tick()
                time.sleep(1)
        except KeyboardInterrupt:
            log.info("Strategy stopped by user")
        except Exception as e:
            log.error(f"Unexpected error in strategy loop: {e}", exc_info=True)
            raise

    def _tick(self) -> None:
        """Called every second. Routes to order cycle or trailing management."""
        now = time.time()

        # ── Trailing stop update (every TRAIL_CHECK_SEC) ──────────────────────
        if now - self._last_trail_time >= config.TRAIL_CHECK_SEC:
            self._manage_trailing()
            self._last_trail_time = now

        # ── New order cycle (every ORDER_INTERVAL_SEC) ────────────────────────
        if now - self._last_order_time >= config.ORDER_INTERVAL_SEC:
            self._order_cycle()
            self._last_order_time = now

    # ── Order cycle ───────────────────────────────────────────────────────────

    def _order_cycle(self) -> None:
        """Main decision point: check filters, then place or skip orders."""
        now_utc = datetime.now(timezone.utc)

        # 1. Daily loss limit
        if is_daily_loss_limit_hit(self.start_of_day_balance):
            log.warning("Daily loss limit hit — halting for today")
            return

        # 2. Consecutive loss pause
        if self._pause_until and time.time() < self._pause_until:
            remaining = int((self._pause_until - time.time()) / 60)
            log.info(f"Consecutive loss pause — {remaining}min remaining")
            return

        # 3. If a position is already open, don't place new orders
        pos = get_open_position()
        if pos:
            log.debug(f"Position open #{pos.ticket} — skipping new order cycle")
            return

        # 4. Session filter
        if not is_session_active(now_utc):
            log.debug("Outside session window")
            cancel_all_pending()   # clean up any orphaned pending orders
            return

        # 5. News filter
        in_news, reason = is_news_window(now_utc)
        if in_news:
            log.info(f"News filter active — {reason}")
            cancel_all_pending()
            return

        # 6. Spread filter
        spread_ok, spread_pts = is_spread_ok()
        if not spread_ok:
            cancel_all_pending()
            return

        # 7. Volatility filter
        vol_ok, atr_pts = is_volatility_ok()
        if not vol_ok:
            cancel_all_pending()
            return

        # 8. Place new buy stop + sell stop
        self._place_bracket(spread_pts, atr_pts)

    def _place_bracket(self, spread_pts: float, atr_pts: float) -> None:
        """Cancel old pending orders and place a fresh buy stop + sell stop pair."""
        cancel_all_pending()

        tick = get_tick()
        if tick is None:
            return

        point    = get_point()
        mid      = (tick.bid + tick.ask) / 2.0

        # SL distance: at least BASE_STOP_POINTS, or spread * SPREAD_MULTIPLIER
        sl_dist  = max(
            config.BASE_STOP_POINTS * point,
            spread_pts * point * config.SPREAD_MULTIPLIER,
        )

        # Entry buffer: how far from mid the stop orders sit
        buf      = sl_dist * config.ENTRY_BUFFER_FACTOR

        buy_entry  = mid + buf
        buy_sl     = buy_entry - sl_dist

        sell_entry = mid - buf
        sell_sl    = sell_entry + sl_dist

        sl_points  = sl_dist / point
        lots       = calculate_lot_size(sl_points)

        log.info(
            f"Bracket | mid={mid:.2f}  buf={buf/point:.0f}pts  "
            f"SL={sl_dist/point:.0f}pts  ATR={atr_pts:.0f}pts  "
            f"spread={spread_pts:.0f}pts  lots={lots}"
        )

        place_buy_stop( buy_entry,  buy_sl,  lots, comment="GP-BUY")
        place_sell_stop(sell_entry, sell_sl, lots, comment="GP-SELL")

    # ── Trailing stop management ──────────────────────────────────────────────

    def _manage_trailing(self) -> None:
        """Ratchet stop-loss to lock in profit as price moves in our favour."""
        pos = get_open_position()
        if pos is None:
            # Position just closed — check if it was a loss
            if self._last_position_ticket is not None:
                self._on_position_closed(self._last_position_ticket)
                self._last_position_ticket = None
            return

        # New position opened (fill detected)
        if pos.ticket != self._last_position_ticket:
            log.info(
                f"Position filled | #{pos.ticket}  "
                f"{'BUY' if pos.type==mt5.POSITION_TYPE_BUY else 'SELL'}  "
                f"{pos.volume} lots @ {pos.price_open:.2f}  SL={pos.sl:.2f}"
            )
            cancel_all_pending()   # cancel the opposing stop order
            self._last_position_ticket = pos.ticket
            return

        tick = get_tick()
        if tick is None:
            return

        point        = get_point()
        atr          = get_atr_points(period=config.TRAIL_ATR_PERIOD)
        trail_step   = max(
            config.TRAIL_MIN_POINTS * point,
            atr * point * config.TRAIL_ATR_MULT,
        )

        is_buy = pos.type == mt5.POSITION_TYPE_BUY

        if is_buy:
            # For a long: trail SL up when bid > current_sl + trail_step
            ideal_sl = tick.bid - trail_step
            if ideal_sl > pos.sl + point:   # only move UP, never DOWN
                modify_sl(pos.ticket, ideal_sl)
        else:
            # For a short: trail SL down when ask < current_sl - trail_step
            ideal_sl = tick.ask + trail_step
            if ideal_sl < pos.sl - point:   # only move DOWN, never UP
                modify_sl(pos.ticket, ideal_sl)

    # ── Post-close handlers ───────────────────────────────────────────────────

    def _on_position_closed(self, ticket: int) -> None:
        """Check closed trade P&L and update consecutive loss counter."""
        from datetime import timedelta
        deals = mt5.history_deals_get(
            datetime.now(timezone.utc) - timedelta(minutes=5),
            datetime.now(timezone.utc),
        )
        if not deals:
            return

        # Find the closing deal for this position
        close_deal = next(
            (d for d in deals
             if d.position_id == ticket and d.entry == mt5.DEAL_ENTRY_OUT),
            None
        )
        if close_deal is None:
            return

        pnl = close_deal.profit + close_deal.swap + close_deal.commission

        if pnl < 0:
            self._consec_losses += 1
            log.info(f"Loss #{self._consec_losses} in a row | P&L=${pnl:.2f}")
            if self._consec_losses >= config.CONSEC_LOSS_LIMIT:
                self._pause_until = time.time() + config.CONSEC_LOSS_PAUSE_MIN * 60
                log.warning(
                    f"{config.CONSEC_LOSS_LIMIT} consecutive losses — "
                    f"pausing {config.CONSEC_LOSS_PAUSE_MIN}min"
                )
        else:
            if self._consec_losses > 0:
                log.info(f"Win after {self._consec_losses} losses — resetting counter")
            self._consec_losses = 0

        log.info(f"Trade closed | ticket={ticket}  P&L=${pnl:.2f}  consec_loss={self._consec_losses}")
