"""
GoldPulse Bot — Configuration
All tunable parameters in one place. Edit here, never touch strategy logic.
"""

# ── Symbol ────────────────────────────────────────────────────────────────────
SYMBOL          = "XAUUSD"
BOT_MAGIC       = 20250001          # unique magic number for this bot's orders

# ── Order cycle ───────────────────────────────────────────────────────────────
ORDER_INTERVAL_SEC   = 60           # re-place pending orders every N seconds
CANCEL_BEFORE_REOPEN = True         # always cancel stale pending before new cycle

# ── Stop levels (in price points, e.g. 0.50 = 50 points on XAUUSD) ───────────
BASE_STOP_POINTS     = 50           # minimum SL distance (0.50 price pts)
SPREAD_MULTIPLIER    = 1.5          # dynamic SL = max(BASE, spread * this)
ENTRY_BUFFER_FACTOR  = 0.55         # stop entry at price ± (sl_dist * factor)

# ── Trailing stop ─────────────────────────────────────────────────────────────
TRAIL_ATR_PERIOD     = 14           # ATR period for trailing step calculation
TRAIL_ATR_MULT       = 0.4          # trailing step = ATR(14,M1) * this
TRAIL_MIN_POINTS     = 30           # never trail tighter than this (30 pts)
TRAIL_CHECK_SEC      = 15           # check/update trailing stop every N seconds

# ── Risk management ───────────────────────────────────────────────────────────
RISK_PCT_PER_TRADE   = 0.005        # 0.5% of account balance per trade
MIN_LOT              = 0.01
MAX_LOT              = 1.00
LOT_STEP             = 0.01

# ── Daily loss limit ──────────────────────────────────────────────────────────
MAX_DAILY_LOSS_PCT   = 0.02         # halt if day's loss > 2% of start-of-day balance
DAILY_RESET_HOUR_UTC = 0            # reset daily P&L counter at 00:00 UTC

# ── Session filter (UTC hours) ────────────────────────────────────────────────
SESSION_ENABLED      = True
SESSION_START_UTC    = 7            # 07:00 UTC — London pre-market open
SESSION_END_UTC      = 21           # 21:00 UTC — NY session close

# ── Spread filter ─────────────────────────────────────────────────────────────
SPREAD_FILTER_ENABLED   = True
MAX_SPREAD_POINTS       = 80        # skip if spread > 0.80 price pts (widened)

# ── Volatility filter (ATR) ───────────────────────────────────────────────────
VOLATILITY_FILTER_ENABLED = True
ATR_MIN_POINTS            = 20      # skip if ATR < 0.20 pts (dead market)
ATR_MAX_POINTS            = 500     # skip if ATR > 5.00 pts (news spike)

# ── News filter ───────────────────────────────────────────────────────────────
NEWS_FILTER_ENABLED      = True
NEWS_BUFFER_MINUTES      = 30       # skip ±30 min around high-impact events
NEWS_CURRENCIES          = ["USD", "XAU"]   # watch these currencies
NEWS_CALENDAR_URL        = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
NEWS_CACHE_FILE          = "news_cache.json"
NEWS_CACHE_TTL_MINUTES   = 60       # refresh news cache every 60 min

# ── Consecutive loss protection ───────────────────────────────────────────────
CONSEC_LOSS_LIMIT        = 5        # pause after N consecutive losses
CONSEC_LOSS_PAUSE_MIN    = 60       # pause duration in minutes

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL   = "INFO"                # DEBUG / INFO / WARNING / ERROR
LOG_FILE    = "goldpulse.log"
LOG_CONSOLE = True
