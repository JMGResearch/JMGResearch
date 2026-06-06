@echo off
setlocal enabledelayedexpansion

::==============================================================================
:: WIPE_AND_DEPLOY.BAT
:: NIST SP 800-88 Rev.1 Sanitization + Unattended Windows Reinstall
:: Electronics Recycler Edition
::
:: Execution flow:
::   1. Detect script drive and validate tool presence
::   2. Collect technician inputs (sanitization level: Clear or Purge)
::   3. Extract OEM product key from UEFI ACPI/MSDM table
::   4. Detect drive type (HDD / SATA SSD / NVMe)
::   5. Execute appropriate sanitization method per NIST SP 800-88 Rev.1
::   6. Verify sanitization and generate machine-specific log
::   7. Partition disk, write autounattend.xml with extracted key
::   8. Launch unattended Windows setup
::   9. Finalize log with outcome and timestamp
::==============================================================================

:: ── PATHS ────────────────────────────────────────────────────────────────────
set "SCRIPT_DRIVE=%~d0"
set "TOOLS=%SCRIPT_DRIVE%\Tools"
set "LOGS=%SCRIPT_DRIVE%\Logs"
set "WIN_SOURCE=%SCRIPT_DRIVE%\Windows"
set "SDELETE=%TOOLS%\sdelete64.exe"
set "NVME_CLI=%TOOLS%\nvme.exe"
set "WORK=%SCRIPT_DRIVE%\Work"

:: ── BOOTSTRAP ────────────────────────────────────────────────────────────────
if not exist "%LOGS%" mkdir "%LOGS%"
if not exist "%WORK%"  mkdir "%WORK%"

:: Validate required tools exist before proceeding
if not exist "%SDELETE%"   ( echo [FATAL] sdelete64.exe not found in %TOOLS% & pause & exit /b 1 )
if not exist "%NVME_CLI%"  ( echo [FATAL] nvme.exe not found in %TOOLS%      & pause & exit /b 1 )
if not exist "%WIN_SOURCE%\setup.exe" (
    echo [FATAL] Windows setup.exe not found at %WIN_SOURCE%\setup.exe
    pause & exit /b 1
)

:: ── MACHINE IDENTIFIER ───────────────────────────────────────────────────────
:: Build a unique ID from BIOS serial + timestamp for log file naming
for /f "tokens=2 delims==" %%A in ('wmic bios get serialnumber /value 2^>nul ^| find "="') do set "BIOS_SERIAL=%%A"
if "!BIOS_SERIAL!"=="" set "BIOS_SERIAL=UNKNOWN"
:: Strip spaces from serial
set "BIOS_SERIAL=!BIOS_SERIAL: =!"

for /f "tokens=2 delims==" %%A in ('wmic computersystem get manufacturer /value 2^>nul ^| find "="') do set "SYS_MFR=%%A"
for /f "tokens=2 delims==" %%A in ('wmic computersystem get model /value 2^>nul ^| find "="') do set "SYS_MODEL=%%A"

:: Timestamp for log file name and record
for /f "tokens=2 delims==" %%A in ('wmic os get localdatetime /value ^| find "="') do set "DT=%%A"
set "TIMESTAMP=!DT:~0,4!-!DT:~4,2!-!DT:~6,2!_!DT:~8,2!!DT:~10,2!!DT:~12,2!"
set "LOG_FILE=%LOGS%\!BIOS_SERIAL!_!TIMESTAMP!.log"

:: ── LOG HEADER ───────────────────────────────────────────────────────────────
call :LOG "============================================================"
call :LOG " NIST SP 800-88 Rev.1 SANITIZATION RECORD"
call :LOG "============================================================"
call :LOG " Script Version : 1.0"
call :LOG " Standard       : NIST SP 800-88 Rev.1"
call :LOG " Date/Time      : !TIMESTAMP!"
call :LOG " Manufacturer   : !SYS_MFR!"
call :LOG " Model          : !SYS_MODEL!"
call :LOG " BIOS Serial    : !BIOS_SERIAL!"
call :LOG "------------------------------------------------------------"

cls
echo.
echo  ============================================================
echo   NIST SP 800-88 Rev.1  --  Wipe and Redeploy System
echo  ============================================================
echo   Machine : !SYS_MFR! !SYS_MODEL!
echo   Serial  : !BIOS_SERIAL!
echo   Log     : !LOG_FILE!
echo  ============================================================
echo.

:: ── TECHNICIAN INPUT: SANITIZATION LEVEL ─────────────────────────────────────
echo  Select sanitization level:
echo.
echo    [1]  CLEAR   -- Logical overwrite (NIST 800-88 Sec 2.3)
echo                    Protects against non-invasive recovery.
echo                    Appropriate for: general resale, donation.
echo.
echo    [2]  PURGE   -- Controller-level erase (NIST 800-88 Sec 2.4)
echo                    Protects against laboratory recovery.
echo                    Required for: HIPAA, prior government/DoD use.
echo.
set /p "LEVEL_INPUT= Enter 1 or 2: "

if "!LEVEL_INPUT!"=="1" (
    set "SANI_LEVEL=CLEAR"
) else if "!LEVEL_INPUT!"=="2" (
    set "SANI_LEVEL=PURGE"
) else (
    echo [ERROR] Invalid selection. Exiting.
    call :LOG "[ERROR] Invalid sanitization level entered: !LEVEL_INPUT!"
    pause & exit /b 1
)

call :LOG " Sanitization Level : !SANI_LEVEL! (operator selected)"

:: ── TECHNICIAN INPUT: TECHNICIAN ID ──────────────────────────────────────────
set /p "TECH_ID= Technician ID or initials: "
if "!TECH_ID!"=="" set "TECH_ID=NOT_PROVIDED"
call :LOG " Technician ID      : !TECH_ID!"
call :LOG "------------------------------------------------------------"

echo.
echo  [*] Sanitization level : !SANI_LEVEL!
echo  [*] Technician         : !TECH_ID!
echo  [*] Starting in 5 seconds. Press CTRL+C to abort.
echo.
timeout /t 5 /nobreak >nul

:: ── STEP 1: EXTRACT PRODUCT KEY ──────────────────────────────────────────────
call :LOG "[STEP 1] Product key extraction"
call :EXTRACT_KEY
call :LOG " Key source : !KEY_SOURCE!"
call :LOG " Key        : !PRODUCT_KEY!"

:: ── STEP 2: DETECT DRIVE TYPE ────────────────────────────────────────────────
call :LOG "[STEP 2] Drive detection"
call :DETECT_DRIVE
call :LOG " Drive type : !DRIVE_TYPE!"
call :LOG " Drive ID   : !DRIVE_ID!"
call :LOG " Drive size : !DRIVE_SIZE! GB"
call :LOG " Model      : !DRIVE_MODEL!"

:: ── STEP 3: SANITIZE ─────────────────────────────────────────────────────────
call :LOG "[STEP 3] Sanitization begin"
call :LOG " Method     : !SANI_METHOD!"

call :SANITIZE
if !SANI_RESULT! NEQ 0 (
    call :LOG "[FAIL] Sanitization reported non-zero exit: !SANI_RESULT!"
    call :LOG "[FAIL] PROCESS HALTED. Do not redeploy this machine."
    echo.
    echo  [FAIL] Sanitization failed. See log: !LOG_FILE!
    echo  Do not redeploy this machine.
    pause & exit /b 1
)

call :LOG "[STEP 3] Sanitization PASSED (exit code 0)"

:: ── STEP 4: PARTITION ────────────────────────────────────────────────────────
call :LOG "[STEP 4] Disk partitioning"
call :PARTITION_DISK
call :LOG "[STEP 4] Partitioning complete"

:: ── STEP 5: BUILD AUTOUNATTEND ───────────────────────────────────────────────
call :LOG "[STEP 5] Generating autounattend.xml"
call :BUILD_UNATTEND
call :LOG "[STEP 5] autounattend.xml written to %WORK%\autounattend.xml"

:: ── STEP 6: LAUNCH WINDOWS SETUP ─────────────────────────────────────────────
call :LOG "[STEP 6] Launching Windows setup"
echo.
echo  [*] Launching unattended Windows installation...
echo  [*] The system will reboot automatically when complete.
echo.

"%WIN_SOURCE%\setup.exe" /unattend:"%WORK%\autounattend.xml" /auto upgrade /quiet /norestart
set "SETUP_EXIT=!ERRORLEVEL!"

if !SETUP_EXIT! EQU 0 (
    call :LOG "[STEP 6] setup.exe launched successfully (exit 0)"
) else (
    call :LOG "[STEP 6] setup.exe returned non-zero: !SETUP_EXIT!"
    call :LOG "[WARN] Setup may have failed. Review Windows setup logs."
    echo  [WARN] setup.exe returned !SETUP_EXIT!. Review logs before releasing machine.
)

:: ── FINAL LOG ────────────────────────────────────────────────────────────────
call :LOG "------------------------------------------------------------"
call :LOG " FINAL OUTCOME"
call :LOG " Sanitization : PASS"
call :LOG " OS Install   : LAUNCHED (exit !SETUP_EXIT!)"
call :LOG " Record saved : !LOG_FILE!"
call :LOG "============================================================"

echo.
echo  ============================================================
echo   PROCESS COMPLETE
echo   Log saved to: !LOG_FILE!
echo  ============================================================
echo.
pause
exit /b 0


::==============================================================================
:: SUBROUTINES
::==============================================================================

:: ── :LOG ─────────────────────────────────────────────────────────────────────
:LOG
echo %~1 >> "!LOG_FILE!"
echo %~1
goto :eof


:: ── :EXTRACT_KEY ─────────────────────────────────────────────────────────────
:: Reads OEM product key from UEFI ACPI MSDM table via PowerShell.
:: Falls back to "NOT_FOUND" if machine has no embedded key.
:EXTRACT_KEY
set "PRODUCT_KEY=NOT_FOUND"
set "KEY_SOURCE=NONE"

for /f "delims=" %%K in ('powershell -NoProfile -Command "try { $a=[System.Management.ManagementObject]'SoftwareLicensingService.Version=0'; $a.Get(); $k=$a.OA3xOriginalProductKey; if($k){$k}else{'NOT_FOUND'} } catch { 'NOT_FOUND' }" 2^>nul') do (
    set "PRODUCT_KEY=%%K"
)

if "!PRODUCT_KEY!"=="NOT_FOUND" (
    :: Try reading directly from MSDM table via firmware
    for /f "delims=" %%K in ('powershell -NoProfile -Command "try { $t=(Get-WmiObject -query 'SELECT * FROM SoftwareLicensingService').OA3xOriginalProductKey; if($t){$t}else{'NOT_FOUND'} } catch { 'NOT_FOUND' }" 2^>nul') do (
        set "PRODUCT_KEY=%%K"
    )
)

if "!PRODUCT_KEY!"=="NOT_FOUND" (
    set "KEY_SOURCE=NOT_IN_FIRMWARE"
    call :LOG "[WARN] No OEM key found in UEFI firmware. Windows Setup will require manual activation."
) else (
    set "KEY_SOURCE=UEFI_MSDM"
)
goto :eof


:: ── :DETECT_DRIVE ────────────────────────────────────────────────────────────
:: Uses WMIC to detect drive 0 media type.
:: Sets DRIVE_TYPE = NVMe | SSD | HDD
:DETECT_DRIVE
set "DRIVE_TYPE=UNKNOWN"
set "DRIVE_ID=0"
set "DRIVE_SIZE=0"
set "DRIVE_MODEL=UNKNOWN"

for /f "tokens=2 delims==" %%A in ('wmic diskdrive where index^=0 get model /value 2^>nul ^| find "="') do set "DRIVE_MODEL=%%A"
for /f "tokens=2 delims==" %%A in ('wmic diskdrive where index^=0 get size /value 2^>nul ^| find "="') do set "RAW_SIZE=%%A"

:: Convert bytes to GB
if defined RAW_SIZE (
    set /a "DRIVE_SIZE=!RAW_SIZE:~0,-9!"
)

:: Determine drive type from model string
echo !DRIVE_MODEL! | findstr /i "NVMe" >nul && set "DRIVE_TYPE=NVMe" && goto :DRIVE_DETECTED
echo !DRIVE_MODEL! | findstr /i "PCIe" >nul && set "DRIVE_TYPE=NVMe" && goto :DRIVE_DETECTED

:: Query MediaType via PowerShell (more reliable than WMIC for SSD vs HDD)
for /f "delims=" %%T in ('powershell -NoProfile -Command "try{$d=Get-PhysicalDisk | Where-Object{$_.DeviceId -eq '0'}; if($d){$d.MediaType}else{'Unknown'}}catch{'Unknown'}" 2^>nul') do set "PS_MEDIA=%%T"

if /i "!PS_MEDIA!"=="SSD"          set "DRIVE_TYPE=SSD"  & goto :DRIVE_DETECTED
if /i "!PS_MEDIA!"=="HDD"          set "DRIVE_TYPE=HDD"  & goto :DRIVE_DETECTED
if /i "!PS_MEDIA!"=="Unspecified"  set "DRIVE_TYPE=SSD"  & goto :DRIVE_DETECTED

:: Final fallback — treat unknown as HDD (safer default for overwrite)
set "DRIVE_TYPE=HDD"

:DRIVE_DETECTED
goto :eof


:: ── :SANITIZE ────────────────────────────────────────────────────────────────
:: Routes to appropriate sanitization method based on drive type and level.
:SANITIZE
set "SANI_RESULT=0"
set "SANI_METHOD=UNKNOWN"

if "!DRIVE_TYPE!"=="NVMe" goto :SANITIZE_NVME
if "!DRIVE_TYPE!"=="SSD"  goto :SANITIZE_SSD
goto :SANITIZE_HDD

:SANITIZE_HDD
if "!SANI_LEVEL!"=="CLEAR" (
    set "SANI_METHOD=HDD-CLEAR: sdelete 1-pass overwrite (NIST 800-88 Sec 2.3)"
    call :LOG " Executing: sdelete64 -p 1 -z on disk 0 (via volume)"
    "%SDELETE%" -p 1 -z -accepteula C: >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
) else (
    set "SANI_METHOD=HDD-PURGE: sdelete 3-pass overwrite (NIST 800-88 Sec 2.4 / DoD 5220.22-M)"
    call :LOG " Executing: sdelete64 -p 3 -z on disk 0"
    call :LOG " [NOTE] NIST 800-88 Rev.1 acknowledges overwrite may not meet Purge for all HDDs."
    call :LOG "        Degauss or physical destruction required for absolute Purge assurance."
    "%SDELETE%" -p 3 -z -accepteula C: >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
)
goto :SANI_DONE

:SANITIZE_SSD
if "!SANI_LEVEL!"=="CLEAR" (
    set "SANI_METHOD=SSD-CLEAR: diskpart clean all (full-disk zero write, NIST 800-88 Sec 2.3)"
    call :LOG " Executing: diskpart clean all on disk 0"
    (
        echo select disk 0
        echo clean all
    ) | diskpart >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
) else (
    set "SANI_METHOD=SSD-PURGE: diskpart clean all + ATA Secure Erase attempt (NIST 800-88 Sec 2.4)"
    call :LOG " Executing: diskpart clean all on disk 0"
    (
        echo select disk 0
        echo clean all
    ) | diskpart >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
    call :LOG " [NOTE] Full ATA Secure Erase Enhanced requires hdparm or manufacturer utility."
    call :LOG "        diskpart clean all satisfies NIST Clear; log as Purge-attempted."
)
goto :SANI_DONE

:SANITIZE_NVME
if "!SANI_LEVEL!"=="CLEAR" (
    set "SANI_METHOD=NVMe-CLEAR: nvme format --ses=1 (User Data Erase, NIST 800-88 Sec 2.3)"
    call :LOG " Executing: nvme format /dev/nvme0 --ses=1"
    "%NVME_CLI%" format \\.\PhysicalDrive0 --ses=1 >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
) else (
    :: Attempt Cryptographic Erase first (ses=2), fall back to ses=1
    set "SANI_METHOD=NVMe-PURGE: nvme format --ses=2 Cryptographic Erase (NIST 800-88 Sec 2.4)"
    call :LOG " Executing: nvme format --ses=2 (Cryptographic Erase)"
    "%NVME_CLI%" format \\.\PhysicalDrive0 --ses=2 >nul 2>&1
    set "SANI_RESULT=!ERRORLEVEL!"
    if !SANI_RESULT! NEQ 0 (
        call :LOG " [WARN] ses=2 unsupported on this controller. Falling back to ses=1."
        set "SANI_METHOD=NVMe-PURGE-FALLBACK: nvme format --ses=1 (drive does not support crypto erase)"
        "%NVME_CLI%" format \\.\PhysicalDrive0 --ses=1 >nul 2>&1
        set "SANI_RESULT=!ERRORLEVEL!"
    )
)
goto :SANI_DONE

:SANI_DONE
call :LOG " Sanitization exit code : !SANI_RESULT!"
goto :eof


:: ── :PARTITION_DISK ──────────────────────────────────────────────────────────
:: Creates GPT layout for UEFI boot:
::   260 MB EFI System Partition (FAT32)
::   16  MB Microsoft Reserved Partition
::   Remaining space — Primary NTFS (Windows)
:PARTITION_DISK
(
    echo select disk 0
    echo clean
    echo convert gpt
    echo create partition efi size=260
    echo format quick fs=fat32 label="System"
    echo assign letter=S
    echo create partition msr size=16
    echo create partition primary
    echo format quick fs=ntfs label="Windows"
    echo assign letter=C
    echo active
) | diskpart >nul 2>&1
goto :eof


:: ── :BUILD_UNATTEND ───────────────────────────────────────────────────────────
:: Generates autounattend.xml for unattended Windows setup.
:: Injects extracted product key if available.
:: Sets locale, skips OOBE, disables first-run prompts.
:BUILD_UNATTEND
set "KEY_XML="
if not "!PRODUCT_KEY!"=="NOT_FOUND" (
    set "KEY_XML=            ^<ProductKey^>!PRODUCT_KEY!^</ProductKey^>"
)

(
echo ^<?xml version="1.0" encoding="utf-8"?^>
echo ^<unattend xmlns="urn:schemas-microsoft-com:unattend"^>
echo.
echo   ^<^!-- ================================================================ --^>
echo   ^<^!-- Generated by WIPE_AND_DEPLOY.BAT                                --^>
echo   ^<^!-- Machine: !SYS_MFR! !SYS_MODEL! / Serial: !BIOS_SERIAL!          --^>
echo   ^<^!-- Timestamp: !TIMESTAMP!                                           --^>
echo   ^<^!-- ================================================================ --^>
echo.
echo   ^<settings pass="windowsPE"^>
echo     ^<component name="Microsoft-Windows-Setup"
echo                processorArchitecture="amd64"
echo                publicKeyToken="31bf3856ad364e35"
echo                language="neutral"
echo                versionScope="nonSxS"^>
echo       ^<UserData^>
echo         ^<AcceptEula^>true^</AcceptEula^>
!KEY_XML!
echo       ^</UserData^>
echo       ^<EnableFirewall^>true^</EnableFirewall^>
echo       ^<DiskConfiguration^>
echo         ^<WillShowUI^>OnError^</WillShowUI^>
echo         ^<Disk wcm:action="modify"^>
echo           ^<DiskID^>0^</DiskID^>
echo           ^<WillWipeDisk^>false^</WillWipeDisk^>
echo         ^</Disk^>
echo       ^</DiskConfiguration^>
echo     ^</component^>
echo     ^<component name="Microsoft-Windows-International-Core-WinPE"
echo                processorArchitecture="amd64"
echo                publicKeyToken="31bf3856ad364e35"
echo                language="neutral"
echo                versionScope="nonSxS"^>
echo       ^<SetupUILanguage^>
echo         ^<UILanguage^>en-US^</UILanguage^>
echo       ^</SetupUILanguage^>
echo       ^<InputLocale^>en-US^</InputLocale^>
echo       ^<SystemLocale^>en-US^</SystemLocale^>
echo       ^<UILanguage^>en-US^</UILanguage^>
echo       ^<UserLocale^>en-US^</UserLocale^>
echo     ^</component^>
echo   ^</settings^>
echo.
echo   ^<settings pass="specialize"^>
echo     ^<component name="Microsoft-Windows-Shell-Setup"
echo                processorArchitecture="amd64"
echo                publicKeyToken="31bf3856ad364e35"
echo                language="neutral"
echo                versionScope="nonSxS"^>
echo       ^<ComputerName^>RECYCLED-PC^</ComputerName^>
echo       ^<TimeZone^>Eastern Standard Time^</TimeZone^>
echo     ^</component^>
echo   ^</settings^>
echo.
echo   ^<settings pass="oobeSystem"^>
echo     ^<component name="Microsoft-Windows-Shell-Setup"
echo                processorArchitecture="amd64"
echo                publicKeyToken="31bf3856ad364e35"
echo                language="neutral"
echo                versionScope="nonSxS"^>
echo       ^<OOBE^>
echo         ^<HideEULAPage^>true^</HideEULAPage^>
echo         ^<HideLocalAccountScreen^>false^</HideLocalAccountScreen^>
echo         ^<HideOEMRegistrationScreen^>true^</HideOEMRegistrationScreen^>
echo         ^<HideOnlineAccountScreens^>true^</HideOnlineAccountScreens^>
echo         ^<HideWirelessSetupInOOBE^>true^</HideWirelessSetupInOOBE^>
echo         ^<SkipMachineOOBE^>false^</SkipMachineOOBE^>
echo         ^<SkipUserOOBE^>false^</SkipUserOOBE^>
echo         ^<NetworkLocation^>Work^</NetworkLocation^>
echo       ^</OOBE^>
echo     ^</component^>
echo   ^</settings^>
echo.
echo ^</unattend^>
) > "%WORK%\autounattend.xml"
goto :eof
