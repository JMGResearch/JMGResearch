@echo off
::==============================================================================
:: STARTNET.CMD
:: Placed in the WinPE image at: X:\Windows\System32\startnet.cmd
::
:: This file executes automatically when WinPE boots.
:: It initializes the network stack, finds the deployment USB,
:: and launches WIPE_AND_DEPLOY.bat with no technician interaction
:: required beyond the two prompts in that script (level + tech ID).
::
:: To inject this into your WinPE image:
::   1. Mount WinPE WIM: dism /mount-wim /wimfile:boot.wim /index:1 /mountdir:C:\mount
::   2. Overwrite: copy /y startnet.cmd C:\mount\Windows\System32\startnet.cmd
::   3. Unmount:   dism /unmount-wim /mountdir:C:\mount /commit
::==============================================================================

:: Initialize WinPE network and PnP
wpeinit

:: Brief pause to allow USB storage driver enumeration
ping -n 4 127.0.0.1 >nul

:: ── FIND DEPLOYMENT USB ──────────────────────────────────────────────────────
:: Scan drive letters C through H for WIPE_AND_DEPLOY.bat
set "DEPLOY_DRIVE="

for %%D in (C D E F G H) do (
    if exist "%%D:\WIPE_AND_DEPLOY.bat" (
        set "DEPLOY_DRIVE=%%D:"
        goto :FOUND
    )
)

echo.
echo  [ERROR] Could not locate WIPE_AND_DEPLOY.bat on any drive (C-H).
echo  Ensure the deployment USB is inserted and recognized by WinPE.
echo  Check Tools folder: sdelete64.exe and nvme.exe must be present.
echo.
echo  Press any key to open a command prompt for manual troubleshooting.
pause >nul
cmd /k
goto :eof

:FOUND
echo.
echo  [*] Deployment USB found at %DEPLOY_DRIVE%
echo  [*] Launching WIPE_AND_DEPLOY.BAT...
echo.

call "%DEPLOY_DRIVE%\WIPE_AND_DEPLOY.bat"

:: If the script returns, drop to shell for diagnostics
echo.
echo  [*] Deployment script exited. Dropping to shell.
cmd /k
