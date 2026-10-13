@echo off
REM Chay pipeline Excel -> raw -> staging -> dwh (Task Scheduler goi file nay)
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
where py >/dev/null 2>&1
if %errorlevel%==0 (
    py -3 run_pipeline.py
) else (
    python run_pipeline.py
)
exit /b %errorlevel%
