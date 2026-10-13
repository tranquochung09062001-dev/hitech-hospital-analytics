@echo off
REM Chay 1 lan (chuot phai > Run as administrator khong bat buoc)
REM Tao lich chay pipeline 05:30 moi ngay + luu mat khau DB vao bien moi truong
chcp 65001 >nul
set /p PGPASS=Nhap mat khau PostgreSQL (user postgres): 
setx HITECH_DB_PASSWORD "%PGPASS%" >nul
schtasks /Create /TN "Hitech Hospital\ETL hang ngay" /TR "\"%~dp0run_pipeline.bat\"" /SC DAILY /ST 05:30 /RL HIGHEST /F
if %errorlevel%==0 (echo Da tao lich: 05:30 hang ngay.) else (echo Tao lich that bai - thu chay lai bang Run as administrator.)
echo Chay thu ngay bay gio...
schtasks /Run /TN "Hitech Hospital\ETL hang ngay"
pause
