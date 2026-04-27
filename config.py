"""
GoldPulse Bot — Configuration  (Adaptive v5.0)
===============================================
NO hardcoded pip/point values.
Everything is a multiplier applied to live spread and ATR,
so the bot works on any broker, symbol, or digits without changes.
"""

# ── Symbol ────────────────────────────────────────────────────────────────────
SYMBOL    = "XAUUSDc"           # Exness Standard Cent — change if needed
BOT_MAGIC = 20250001

# ── Timing ────────────────────────────────────────────────────────────────────
ORDER_INTERVAL_SEC   = 60       # Full order cycle every 60 s
TRAIL_CHECK_SEC      = 1        # Trailing checked every loop iteration (~1 s)
REFRESH_CHANGE_PCT   = 15.0     # Re-place orders when spread/ATR drifts > this %
MIN_REORDER_SEC      = 10       # Minimum seconds between order refreshes

# ── Adaptive distances  (multipliers × live spread / ATR) ────────────────────
#   These work on ANY broker automatically — never edit for a new account.
GAP_ATR_MULT          = 0.25   # Entry gap  = ATR × this      (~37 pts on XAUUSDc)
SL_SPREAD_MULT        = 1.5    # SL >= spread × this          (clears spread noise)
SL_ATR_MULT           = 0.5    # SL >= ATR   × this           (clears volatility)
TRAIL_ATR_MULT        = 0.28   # Trail step  = ATR × this
TRAIL_TRIG_MULT       = 0.4    # Trail activates at profit >= spread × this
BE_SL_MULT            = 0.7    # Break-even at profit >= SL × this
SPREAD_SPIKE_X        = 2.0    # Cancel pending if spread > spread_ema × this

# ── Spread EMA ────────────────────────────────────────────────────────────────
SPREAD_EMA_ALPHA      = 0.01   # α for exponential moving average of spread
                                # α=0.01 → ~100-sample smoothing (stable baseline)

# ── Risk management ───────────────────────────────────────────────────────────
RISK_PCT_PER_TRADE   = 0.005   # 0.5% of account balance per trade (safer for live)
MIN_LOT              = 0.01
MAX_LOT              = 1.00
LOT_STEP             = 0.01

# ── Daily loss limit ──────────────────────────────────────────────────────────
MAX_DAILY_LOSS_PCT   = 0.02    # Halt if day loss > 2 %
DAILY_RESET_HOUR_UTC = 0

# ── Session filter (UTC hours) ────────────────────────────────────────────────
SESSION_ENABLED      = True
SESSION_START_UTC    = 7       # London pre-market
SESSION_END_UTC      = 21      # NY session close

# ── News filter ───────────────────────────────────────────────────────────────
NEWS_FILTER_ENABLED      = True
NEWS_BUFFER_MINUTES      = 30
NEWS_CURRENCIES          = ["USD", "XAU"]
NEWS_CALENDAR_URL        = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
NEWS_CACHE_FILE          = "news_cache.json"
NEWS_CACHE_TTL_MINUTES   = 60

# ── Consecutive loss protection ───────────────────────────────────────────────
CONSEC_LOSS_LIMIT        = 5
CONSEC_LOSS_PAUSE_MIN    = 60

# ── Trailing ATR period ───────────────────────────────────────────────────────
TRAIL_ATR_PERIOD         = 14   # ATR(14) on M1

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL   = "INFO"
LOG_FILE    = "goldpulse.log"
LOG_CONSOLE = True
