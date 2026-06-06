@echo off
setlocal enabledelayedexpansion

::==============================================================================
:: VIEW_LOGS.BAT
:: Displays a summary of all sanitization records on the USB.
:: Run from the USB drive in WinPE or on any Windows workstation.
::
:: Output: machine count, pass/fail count, list of log files with outcomes.
:: Option to print a specific log to screen for review.
::==============================================================================

set "SCRIPT_DRIVE=%~d0"
set "LOGS=%SCRIPT_DRIVE%\Logs"

if not exist "%LOGS%\" (
    echo [INFO] No Logs directory found. No machines have been processed yet.
    pause & exit /b 0
)

:: Count log files
set "TOTAL=0"
set "PASS=0"
set "FAIL=0"

for %%F in ("%LOGS%\*.log") do (
    set /a TOTAL+=1
    findstr /i "Sanitization : PASS" "%%F" >nul 2>&1 && set /a PASS+=1
    findstr /i "FAIL" "%%F" >nul 2>&1 && (
        findstr /i "Sanitization : PASS" "%%F" >nul 2>&1 || set /a FAIL+=1
    )
)

cls
echo.
echo  ============================================================
echo   WipeDeploy -- Sanitization Log Summary
echo  ============================================================
echo   Log directory : %LOGS%
echo   Total records : !TOTAL!
echo   Passed        : !PASS!
echo   Failed/Review : !FAIL!
echo  ============================================================
echo.

if !TOTAL! EQU 0 (
    echo  No log records found.
    pause & exit /b 0
)

echo  Recent records:
echo  ---------------------------------------------------------------
set "IDX=0"
for %%F in ("%LOGS%\*.log") do (
    set /a IDX+=1
    set "FNAME=%%~nF"
    set "OUTCOME=UNKNOWN"
    findstr /i "Sanitization : PASS" "%%F" >nul 2>&1 && set "OUTCOME=PASS"
    findstr /i "\[FAIL\]" "%%F" >nul 2>&1 && set "OUTCOME=FAIL"
    echo   [!IDX!] !FNAME!  --  !OUTCOME!
)

echo.
set /p "VIEW_NUM= Enter number to view full log, or ENTER to exit: "
if "!VIEW_NUM!"=="" exit /b 0

set "IDX=0"
for %%F in ("%LOGS%\*.log") do (
    set /a IDX+=1
    if !IDX! EQU !VIEW_NUM! (
        echo.
        echo  ============================================================
        type "%%F"
        echo  ============================================================
        echo.
    )
)

pause
exit /b 0
