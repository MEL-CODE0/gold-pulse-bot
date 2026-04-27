"""
GoldPulse Strategy  —  Adaptive v5.0
======================================
Tick-reactive: every loop iteration (~1 s) the bot:
  1. Updates spread EMA  (learns broker's normal spread automatically)
  2. Checks for spread spike → cancels pending IMMEDIATELY
  3. Manages trailing stop  (every second, not every 15 s)
  4. Detects position fills / closes
  5. Refreshes bracket if spread or ATR shifted > REFRESH_CHANGE_PCT
  6. Full order cycle every ORDER_INTERVAL_SEC

NO hardcoded pip values — SL, gap, and trail are all multipliers of
live spread and ATR so they adapt to any broker automatically.
"""

import time
from datetime import datetime, timedelta, timezone
from typing import Optional

import MetaTrader5 as mt5

import config
from execution.mt5_trader import (
    cancel_all_pending,
    close_position,
    get_digits,
    get_open_position,
    get_point,
    get_tick,
    has_pending_orders,
    modify_sl,
    place_buy_stop,
    place_sell_stop,
)
from filters.news_filter    import is_news_window
from filters.session_filter import is_session_active
from filters.spread_filter  import get_atr_points, get_current_spread_points, is_spread_spike
from risk.sizer             import calculate_lot_size, is_daily_loss_limit_hit
from utils.logger           import get_logger

log = get_logger("GoldPulse")


class GoldPulseStrategy:
    """Stateful strategy runner — instantiate once, call ._tick() every second."""

    def __init__(self, start_of_day_balance: float):
        self.start_of_day_balance = start_of_day_balance

        self._consec_losses: int = 0
        self._pause_until: Optional[float] = None

        self._last_order_time: float = 0.0
        self._last_position_ticket: Optional[int] = None

        # Spread EMA — auto-learns broker's normal spread (α = 0.01)
        self._spread_ema: Optional[float] = None

        # Snapshot of spread/ATR at time of last bracket placement
        self._placed_spread: float = 0.0
        self._placed_atr:    float = 0.0
        self._last_place_ts: float = 0.0

    # ── Public entry point ────────────────────────────────────────────────────

    def run_forever(self) -> None:
        log.info("GoldPulse v5.0 started")
        try:
            while True:
                self._tick()
                time.sleep(1)
        except KeyboardInterrupt:
            log.info("Strategy stopped by user")
        except Exception as e:
            log.error(f"Fatal error in strategy loop: {e}", exc_info=True)
            raise

    # ── Main loop iteration ───────────────────────────────────────────────────

    def _tick(self) -> None:
        now = time.time()

        # 1. Read live market data
        spread_pts = get_current_spread_points()
        atr_pts    = get_atr_points(period=config.TRAIL_ATR_PERIOD)
        if atr_pts <= 0:
            atr_pts = spread_pts * 2.0   # fallback before enough bars load

        # 2. Update spread EMA continuously
        self._update_spread_ema(spread_pts)

        # 3. Spread spike → cancel pending orders IMMEDIATELY
        spike, _ = is_spread_spike(self._spread_ema or 0)
        if spike and has_pending_orders():
            log.info(f"Spike cancel | spread={spread_pts:.0f}  avg={self._spread_ema:.0f}")
            cancel_all_pending()
            self._last_place_ts = 0   # force re-place when spread normalises

        # 4. Trailing stop — runs every second
        self._manage_trailing(spread_pts, atr_pts)

        # 5. Detect fill / close
        self._check_position_state()

        # 6. Refresh orders if market conditions shifted significantly
        if self._should_refresh(spread_pts, atr_pts):
            log.info(
                f"REFRESH | spread {self._placed_spread:.0f}→{spread_pts:.0f}  "
                f"ATR {self._placed_atr:.0f}→{atr_pts:.0f}"
            )
            self._place_bracket(spread_pts, atr_pts)
            return

        # 7. Full order cycle every ORDER_INTERVAL_SEC
        if now - self._last_order_time >= config.ORDER_INTERVAL_SEC:
            self._order_cycle(spread_pts, atr_pts)
            self._last_order_time = now

    # ── Spread EMA ────────────────────────────────────────────────────────────

    def _update_spread_ema(self, spread_pts: float) -> None:
        if spread_pts <= 0:
            return
        if self._spread_ema is None:
            self._spread_ema = spread_pts
        else:
            α = config.SPREAD_EMA_ALPHA
            self._spread_ema = self._spread_ema * (1 - α) + spread_pts * α

    # ── Should refresh orders? ────────────────────────────────────────────────

    def _should_refresh(self, spread_pts: float, atr_pts: float) -> bool:
        if not has_pending_orders():               return False
        if get_open_position() is not None:        return False
        if self._placed_spread <= 0:               return False
        if self._placed_atr    <= 0:               return False
        elapsed = time.time() - self._last_place_ts
        if elapsed < config.MIN_REORDER_SEC:       return False

        spread_chg = abs(spread_pts - self._placed_spread) / self._placed_spread * 100
        atr_chg    = abs(atr_pts    - self._placed_atr)    / self._placed_atr    * 100
        return spread_chg > config.REFRESH_CHANGE_PCT or atr_chg > config.REFRESH_CHANGE_PCT

    # ── Order cycle ───────────────────────────────────────────────────────────

    def _order_cycle(self, spread_pts: float, atr_pts: float) -> None:
        now_utc = datetime.now(timezone.utc)

        # Daily loss limit
        if is_daily_loss_limit_hit(self.start_of_day_balance):
            log.warning("Daily loss limit hit — halting today")
            cancel_all_pending()
            return

        # Consecutive loss pause
        if self._pause_until and time.time() < self._pause_until:
            remaining = int((self._pause_until - time.time()) / 60)
            if remaining % 5 == 0:
                log.info(f"Loss pause — {remaining} min remaining")
            return

        # Skip if position open
        if get_open_position() is not None:
            return

        # Session filter
        if not is_session_active(now_utc):
            cancel_all_pending()
            return

        # News filter
        in_news, reason = is_news_window(now_utc)
        if in_news:
            log.info(f"News window — {reason}")
            cancel_all_pending()
            return

        # Don't place during a spread spike
        spike, _ = is_spread_spike(self._spread_ema or 0)
        if spike:
            cancel_all_pending()
            return

        self._place_bracket(spread_pts, atr_pts)

    # ── Place bracket — fully adaptive ───────────────────────────────────────

    def _place_bracket(self, spread_pts: float, atr_pts: float) -> None:
        cancel_all_pending()

        tick = get_tick()
        if tick is None:
            return

        point  = get_point()
        digits = get_digits()
        mid    = (tick.bid + tick.ask) / 2.0

        # GAP: small fraction of ATR so entries fill on normal momentum
        gap_pts = atr_pts * config.GAP_ATR_MULT
        gap_pts = max(gap_pts, spread_pts * 0.5)   # floor: >= half spread

        # SL: wider than both spread and ATR noise
        sl_pts  = max(spread_pts * config.SL_SPREAD_MULT,
                      atr_pts    * config.SL_ATR_MULT)
        sl_pts  = max(sl_pts, spread_pts * 1.2)    # hard floor: 1.2× spread

        gap_dist = gap_pts * point
        sl_dist  = sl_pts  * point

        buy_entry  = round(mid + gap_dist, digits)
        buy_sl     = round(buy_entry  - sl_dist, digits)
        sell_entry = round(mid - gap_dist, digits)
        sell_sl    = round(sell_entry + sl_dist, digits)

        lots = calculate_lot_size(sl_pts)

        log.info(
            f"BRACKET | spread={spread_pts:.0f} avg={self._spread_ema or 0:.0f} | "
            f"gap={gap_pts:.0f} SL={sl_pts:.0f} ATR={atr_pts:.0f} | lots={lots}"
        )
        log.info(
            f"  BUY@{buy_entry:.3f}  sl={buy_sl:.3f}  |  "
            f"SELL@{sell_entry:.3f}  sl={sell_sl:.3f}"
        )

        place_buy_stop (buy_entry,  buy_sl,  lots, comment="GP-BUY")
        place_sell_stop(sell_entry, sell_sl, lots, comment="GP-SELL")

        # Record conditions for refresh detection
        self._placed_spread = spread_pts
        self._placed_atr    = atr_pts
        self._last_place_ts = time.time()

    # ── Trailing stop ─────────────────────────────────────────────────────────

    def _manage_trailing(self, spread_pts: float, atr_pts: float) -> None:
        pos = get_open_position()
        if pos is None:
            return

        tick = get_tick()
        if tick is None:
            return

        point  = get_point()
        digits = get_digits()
        is_buy = pos.type == mt5.POSITION_TYPE_BUY

        # Trail step adapts to live volatility
        trail_step = atr_pts * config.TRAIL_ATR_MULT * point
        trail_step = max(trail_step, spread_pts * 0.1 * point)  # min: 10% of spread

        # Trail activates when profit >= fraction of spread
        trail_trig = spread_pts * config.TRAIL_TRIG_MULT * point

        current_sl = pos.sl

        if is_buy:
            profit = tick.bid - pos.price_open
            if profit < trail_trig:
                return

            new_sl = current_sl

            # Break-even: lock entry once profit >= SL × BE_mult
            sl_dist = pos.price_open - current_sl
            if sl_dist > 0 and profit >= sl_dist * config.BE_SL_MULT:
                be_sl = round(pos.price_open + spread_pts * 0.2 * point, digits)
                if be_sl > new_sl + point:
                    new_sl = be_sl

            # Standard trail: pull SL up behind bid
            ideal_sl = round(tick.bid - trail_step, digits)
            if ideal_sl > new_sl + point:
                new_sl = ideal_sl

            if new_sl > current_sl + point:
                modify_sl(pos.ticket, new_sl)
                log.info(
                    f"Trail BUY  #{pos.ticket} | "
                    f"{current_sl:.3f} → {new_sl:.3f}  "
                    f"(+{(new_sl - current_sl) / point:.0f} pts)"
                )

        else:  # SELL
            profit = pos.price_open - tick.ask
            if profit < trail_trig:
                return

            new_sl = current_sl

            sl_dist = current_sl - pos.price_open
            if sl_dist > 0 and profit >= sl_dist * config.BE_SL_MULT:
                be_sl = round(pos.price_open - spread_pts * 0.2 * point, digits)
                if be_sl < new_sl - point:
                    new_sl = be_sl

            ideal_sl = round(tick.ask + trail_step, digits)
            if ideal_sl < new_sl - point:
                new_sl = ideal_sl

            if new_sl < current_sl - point:
                modify_sl(pos.ticket, new_sl)
                log.info(
                    f"Trail SELL #{pos.ticket} | "
                    f"{current_sl:.3f} → {new_sl:.3f}  "
                    f"(+{(current_sl - new_sl) / point:.0f} pts)"
                )

    # ── Position state detection ──────────────────────────────────────────────

    def _check_position_state(self) -> None:
        pos = get_open_position()

        # Position just closed
        if pos is None and self._last_position_ticket is not None:
            self._on_position_closed(self._last_position_ticket)
            self._last_position_ticket = None
            self._placed_spread = 0.0   # reset so next cycle places fresh
            self._placed_atr    = 0.0
            self._last_place_ts = 0.0
            return

        # New fill detected
        if pos is not None and pos.ticket != self._last_position_ticket:
            log.info(
                f"FILLED #{pos.ticket}  "
                f"{'BUY' if pos.type == mt5.POSITION_TYPE_BUY else 'SELL'}  "
                f"{pos.volume} lots @ {pos.price_open:.3f}  SL={pos.sl:.3f}"
            )
            cancel_all_pending()   # remove opposing pending order immediately
            self._last_position_ticket = pos.ticket

    # ── Post-close handler ────────────────────────────────────────────────────

    def _on_position_closed(self, ticket: int) -> None:
        deals = mt5.history_deals_get(
            datetime.now(timezone.utc) - timedelta(minutes=10),
            datetime.now(timezone.utc),
        )
        if not deals:
            return

        close_deal = next(
            (d for d in deals
             if d.position_id == ticket and d.entry == mt5.DEAL_ENTRY_OUT),
            None,
        )
        if close_deal is None:
            return

        pnl = close_deal.profit + close_deal.swap + close_deal.commission

        if pnl < 0:
            self._consec_losses += 1
            log.info(f"Loss #{self._consec_losses} | P&L={pnl:.2f}")
            if self._consec_losses >= config.CONSEC_LOSS_LIMIT:
                self._pause_until = time.time() + config.CONSEC_LOSS_PAUSE_MIN * 60
                log.warning(
                    f"{config.CONSEC_LOSS_LIMIT} consecutive losses — "
                    f"pausing {config.CONSEC_LOSS_PAUSE_MIN} min"
                )
        else:
            if self._consec_losses > 0:
                log.info(f"Win after {self._consec_losses} losses — counter reset")
            self._consec_losses = 0

        log.info(
            f"Trade closed #{ticket}  P&L={pnl:.2f}  "
            f"consec_losses={self._consec_losses}"
        )
