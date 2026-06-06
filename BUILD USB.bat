@echo off
setlocal enabledelayedexpansion

::==============================================================================
:: BUILD_USB.BAT
:: Run this ONCE on a Windows workstation to prepare the deployment USB.
:: Point it at your USB drive letter and Windows ISO mount point.
::
:: Expected result:
::   USB:\
::     WIPE_AND_DEPLOY.bat
::     Tools\
::       sdelete64.exe       (Microsoft Sysinternals)
::       nvme.exe            (nvme-cli Windows port)
::     Windows\             (copied from mounted ISO)
::       setup.exe
::       sources\
::       boot\
::       ... etc
::     Logs\                (created at runtime, one .log per machine)
::     Work\                (runtime temp — autounattend.xml written here)
::==============================================================================

:: ── CONFIGURATION — EDIT THESE ───────────────────────────────────────────────
set "USB_DRIVE=E:"
set "ISO_MOUNT=D:"
set "TOOLS_SOURCE=C:\DeployTools"
:: ─────────────────────────────────────────────────────────────────────────────

echo.
echo  ============================================================
echo   WipeDeploy USB Builder
echo  ============================================================
echo   USB Drive   : %USB_DRIVE%
echo   ISO Mount   : %ISO_MOUNT%
echo   Tools Source: %TOOLS_SOURCE%
echo  ============================================================
echo.
echo  This will copy Windows source files and tools to the USB.
echo  Ensure the USB is formatted NTFS before proceeding.
echo.
pause

:: Validate paths
if not exist "%USB_DRIVE%\" ( echo [ERROR] USB drive %USB_DRIVE% not found. & exit /b 1 )
if not exist "%ISO_MOUNT%\setup.exe" ( echo [ERROR] Windows setup.exe not found at %ISO_MOUNT%. Mount the ISO first. & exit /b 1 )
if not exist "%TOOLS_SOURCE%\sdelete64.exe" ( echo [ERROR] sdelete64.exe not found in %TOOLS_SOURCE%. & exit /b 1 )
if not exist "%TOOLS_SOURCE%\nvme.exe" ( echo [ERROR] nvme.exe not found in %TOOLS_SOURCE%. & exit /b 1 )

:: Create folder structure
echo [1/4] Creating directory structure...
for %%D in (Tools Logs Work Windows) do (
    if not exist "%USB_DRIVE%\%%D" mkdir "%USB_DRIVE%\%%D"
)

:: Copy tools
echo [2/4] Copying sanitization tools...
copy /y "%TOOLS_SOURCE%\sdelete64.exe" "%USB_DRIVE%\Tools\" >nul
copy /y "%TOOLS_SOURCE%\nvme.exe"      "%USB_DRIVE%\Tools\" >nul

:: Copy Windows source
echo [3/4] Copying Windows installation source (this may take several minutes)...
robocopy "%ISO_MOUNT%" "%USB_DRIVE%\Windows" /e /ndl /nfl /np
if %ERRORLEVEL% GTR 7 (
    echo [ERROR] Robocopy failed with error %ERRORLEVEL%. Check source and destination.
    exit /b 1
)

:: Copy main script
echo [4/4] Copying deployment script...
copy /y "%~dp0WIPE_AND_DEPLOY.bat" "%USB_DRIVE%\" >nul

echo.
echo  ============================================================
echo   USB build complete.
echo.
echo   Verify the following before deploying:
echo     %USB_DRIVE%\WIPE_AND_DEPLOY.bat     -- present
echo     %USB_DRIVE%\Tools\sdelete64.exe     -- present
echo     %USB_DRIVE%\Tools\nvme.exe          -- present
echo     %USB_DRIVE%\Windows\setup.exe       -- present
echo  ============================================================
echo.
dir "%USB_DRIVE%\" /b
echo.
pause
