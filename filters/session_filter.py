"""
Session filter — only trade during active gold market hours.
Default window: 07:00-21:00 UTC (London pre-market through NY close).
"""

from datetime import datetime, timezone
import config
from utils.logger import get_logger

log = get_logger("SessionFilter")


def is_session_active(dt_utc: datetime | None = None) -> bool:
    """Return True if current UTC time is within the configured trading window."""
    if not config.SESSION_ENABLED:
        return True

    now = dt_utc or datetime.now(timezone.utc)
    hour = now.hour + now.minute / 60.0

    active = config.SESSION_START_UTC <= hour < config.SESSION_END_UTC
    if not active:
        log.debug(
            f"Outside session ({now.strftime('%H:%M')} UTC). "
            f"Window: {config.SESSION_START_UTC:02d}:00 - {config.SESSION_END_UTC:02d}:00 UTC"
        )
    return active


def minutes_until_session(dt_utc: datetime | None = None) -> float:
    """How many minutes until the next session opens."""
    now = dt_utc or datetime.now(timezone.utc)
    current_min = now.hour * 60 + now.minute
    open_min    = config.SESSION_START_UTC * 60

    if current_min < open_min:
        return open_min - current_min
    # Already past today's open — next open is tomorrow
    return (24 * 60 - current_min) + open_min
