"""
News filter — skip trades around high-impact economic events.
Uses the ForexFactory weekly JSON calendar (unofficial but reliable).
Falls back gracefully if the network is unavailable.
"""

import json
import os
import time
from datetime import datetime, timezone, timedelta
from typing import Optional

import requests

import config
from utils.logger import get_logger

log = get_logger("NewsFilter")

_cache: list[dict] = []
_cache_expires: float = 0.0       # Unix timestamp when cache is stale


# ── Internal helpers ──────────────────────────────────────────────────────────

def _fetch_calendar() -> list[dict]:
    """Download this week's ForexFactory calendar. Returns [] on failure."""
    try:
        r = requests.get(config.NEWS_CALENDAR_URL, timeout=10)
        r.raise_for_status()
        events = r.json()
        log.info(f"News calendar fetched: {len(events)} events this week")
        return events
    except Exception as e:
        log.warning(f"Could not fetch news calendar: {e}")
        return []


def _load_cache() -> None:
    """Load events from disk cache if fresh, otherwise re-fetch."""
    global _cache, _cache_expires

    now = time.time()
    if _cache and now < _cache_expires:
        return  # in-memory cache still valid

    # Try disk cache
    if os.path.exists(config.NEWS_CACHE_FILE):
        try:
            with open(config.NEWS_CACHE_FILE, encoding="utf-8") as f:
                data = json.load(f)
            saved_at = data.get("saved_at", 0)
            if now - saved_at < config.NEWS_CACHE_TTL_MINUTES * 60:
                _cache = data["events"]
                _cache_expires = saved_at + config.NEWS_CACHE_TTL_MINUTES * 60
                log.debug(f"Loaded {len(_cache)} events from disk cache")
                return
        except Exception:
            pass

    # Re-fetch
    events = _fetch_calendar()
    _cache = events
    _cache_expires = now + config.NEWS_CACHE_TTL_MINUTES * 60

    try:
        with open(config.NEWS_CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"saved_at": now, "events": events}, f, indent=2)
    except Exception as e:
        log.warning(f"Could not write news cache: {e}")


def _parse_event_time(event: dict) -> Optional[datetime]:
    """Parse ForexFactory event time to UTC datetime."""
    try:
        date_str = event.get("date", "")
        time_str = event.get("time", "")
        if not date_str or time_str.lower() in ("", "all day", "tentative"):
            return None

        # FF format: "01-13-2025" + "8:30am"
        dt_str = f"{date_str} {time_str}"
        # ForexFactory times are Eastern US time (ET)
        from zoneinfo import ZoneInfo
        et_tz = ZoneInfo("America/New_York")
        dt_et = datetime.strptime(dt_str, "%m-%d-%Y %I:%M%p").replace(tzinfo=et_tz)
        return dt_et.astimezone(timezone.utc)
    except Exception:
        return None


# ── Public API ────────────────────────────────────────────────────────────────

def is_news_window(dt_utc: Optional[datetime] = None) -> tuple[bool, str]:
    """
    Return (True, reason) if we're within the news blackout window,
    or (False, "") if clear to trade.
    """
    if not config.NEWS_FILTER_ENABLED:
        return False, ""

    _load_cache()

    now = dt_utc or datetime.now(timezone.utc)
    buf = timedelta(minutes=config.NEWS_BUFFER_MINUTES)

    for event in _cache:
        # Only block high-impact events for watched currencies
        if event.get("impact", "").lower() != "high":
            continue
        if event.get("currency", "") not in config.NEWS_CURRENCIES:
            continue

        event_dt = _parse_event_time(event)
        if event_dt is None:
            continue

        if (event_dt - buf) <= now <= (event_dt + buf):
            title = event.get("title", "Unknown event")
            mins  = int((event_dt - now).total_seconds() / 60)
            sign  = "in" if mins >= 0 else "ago"
            reason = f"News blackout: '{title}' ({abs(mins)}min {sign})"
            log.info(reason)
            return True, reason

    return False, ""


def next_news_event(dt_utc: Optional[datetime] = None) -> Optional[dict]:
    """Return the next upcoming high-impact USD/XAU event, or None."""
    _load_cache()
    now = dt_utc or datetime.now(timezone.utc)

    upcoming = []
    for ev in _cache:
        if ev.get("impact", "").lower() != "high":
            continue
        if ev.get("currency", "") not in config.NEWS_CURRENCIES:
            continue
        dt = _parse_event_time(ev)
        if dt and dt > now:
            upcoming.append((dt, ev))

    if not upcoming:
        return None
    upcoming.sort(key=lambda x: x[0])
    dt, ev = upcoming[0]
    return {"title": ev.get("title"), "time_utc": dt, "currency": ev.get("currency")}
