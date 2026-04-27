@echo off
title GoldPulse Bot
color 0A
echo ============================================
echo   GoldPulse Bot v5.0 - Starting...
echo   Account: 161549427 (Exness-MT5Real21)
echo   Symbol : XAUUSDc  Risk: 0.5%% per trade
echo ============================================
echo.
echo IMPORTANT: Keep MetaTrader 5 open while bot runs.
echo Press Ctrl+C to stop the bot safely.
echo.
cd /d "%~dp0"
python main.py
pause
