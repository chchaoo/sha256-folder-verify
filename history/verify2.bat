```bat
@echo off
setlocal EnableExtensions EnableDelayedExpansion

title SHA-256 Folder Verification

echo.
echo ============================================================
echo                 SHA-256 FOLDER VERIFICATION
echo ============================================================
echo.
echo This script compares two folders recursively.
echo.
echo Source and Target folder names can be different.
echo.
echo ============================================================
echo.

REM ============================================================
REM Select Source Folder
REM ============================================================

echo Source folder:
echo Drag the SOURCE folder into this window, then press ENTER.
echo.

set /p "SOURCE=> "

REM Remove quotation marks automatically added by Windows Explorer
set "SOURCE=%SOURCE:"=%"

if not exist "%SOURCE%\." (
    echo.
    echo [ERROR] Source folder does not exist.
    echo.
    pause
    exit /b 1
)

echo.
echo Source folder:
echo %SOURCE%
echo.

REM ============================================================
REM Select Target Folder
REM ============================================================

echo Target folder:
echo Drag the TARGET folder into this window, then press ENTER.
echo.

set /p "TARGET=> "

REM Remove quotation marks automatically added by Windows Explorer
set "TARGET=%TARGET:"=%"

if not exist "%TARGET%\." (
    echo.
    echo [ERROR] Target folder does not exist.
    echo.
    pause
    exit /b 1
)

echo.
echo Target folder:
echo %TARGET%
echo.

if /I "%SOURCE%"=="%TARGET%" (
    echo [ERROR] Source and Target cannot be the same folder.
    echo.
    pause
    exit /b 1
)

REM ============================================================
REM Temporary files
REM ============================================================

set "WORK=%TEMP%\SHA256_VERIFY_%RANDOM%%RANDOM%"
mkdir "%WORK%" >nul 2>&1

set "SOURCE_LIST=%WORK%\source_files.txt"
set "TARGET_LIST=%WORK%\target_files.txt"

set "SOURCE_HASH=%WORK%\source_hashes.txt"
set "TARGET_HASH=%WORK%\target_hashes.txt"

set "RESULT=%WORK%\results.txt"

REM ============================================================
REM Count files
REM ============================================================

echo.
echo Scanning folders...
echo.

set /a SOURCE_COUNT=0
set /a TARGET_COUNT=0

for /r "%SOURCE%" %%F in (*) do (
    set /a SOURCE_COUNT+=1
)

for /r "%TARGET%" %%F in (*) do (
    set /a TARGET_COUNT+=1
)

echo Source files: !SOURCE_COUNT!
echo Target files: !TARGET_COUNT!
echo.

if !SOURCE_COUNT! EQU 0 (
    echo [ERROR] Source folder contains no files.
    rd /s /q "%WORK%" >nul 2>&1
    pause
    exit /b 1
)

REM ============================================================
REM Create relative file lists
REM ============================================================

echo Creating file lists...
echo.

for /r "%SOURCE%" %%F in (*) do (
    set "FULL=%%F"
    set "REL=!FULL:%SOURCE%=!"
    if "!REL:~0,1!"=="\" set "REL=!REL:~1!"
    echo !REL!>>"%SOURCE_LIST%"
)

for /r "%TARGET%" %%F in (*) do (
    set "FULL=%%F"
    set "REL=!FULL:%TARGET%=!"
    if "!REL:~0,1!"=="\" set "REL=!REL:~1!"
    echo !REL!>>"%TARGET_LIST%"
)

REM ============================================================
REM Calculate SOURCE SHA-256
REM ============================================================

echo.
echo ============================================================
echo                 PROCESSING SOURCE
echo ============================================================
echo.

set /a CURRENT=0

for /f "usebackq delims=" %%R in ("%SOURCE_LIST%") do (

    set /a CURRENT+=1
    set /a PERCENT=CURRENT*100/SOURCE_COUNT

    set "REL=%%R"
    set "FILE=%SOURCE%\!REL!"

    set "HASH="

    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    echo !REL!^|!HASH!>>"%SOURCE_HASH%"

    cls
    echo.
    echo ============================================================
    echo                 SHA-256 VERIFICATION
    echo ============================================================
    echo.
    echo Source folder:
    echo %SOURCE%
    echo.
    echo Target folder:
    echo %TARGET%
    echo.
    echo ============================================================
    echo                 PROCESSING SOURCE
    echo ============================================================
    echo.
    echo File: !REL!
    echo Path: !FILE!
    echo.
    echo Progress: !CURRENT! / !SOURCE_COUNT!  [!PERCENT!%%]
    echo.

    call :ProgressBar !PERCENT!
)

REM ============================================================
REM Calculate TARGET SHA-256
REM ============================================================

echo.
echo.
echo ============================================================
echo                 PROCESSING TARGET
echo ============================================================
echo.

set /a CURRENT=0

for /f "usebackq delims=" %%R in ("%TARGET_LIST%") do (

    set /a CURRENT+=1
    set /a PERCENT=CURRENT*100/TARGET_COUNT

    set "REL=%%R"
    set "FILE=%TARGET%\!REL!"

    set "HASH="

    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    echo !REL!^|!HASH!>>"%TARGET_HASH%"

    cls
    echo.
    echo ============================================================
    echo                 SHA-256 VERIFICATION
    echo ============================================================
    echo.
    echo Source folder:
    echo %SOURCE%
    echo.
    echo Target folder:
    echo %TARGET%
    echo.
    echo ============================================================
    echo                 PROCESSING TARGET
    echo ============================================================
    echo.
    echo File: !REL!
    echo Path: !FILE!
    echo.
    echo Progress: !CURRENT! / !TARGET_COUNT!  [!PERCENT!%%]
    echo.

    call :ProgressBar !PERCENT!
)

REM ============================================================
REM Compare SOURCE against TARGET
REM ============================================================

cls
echo.
echo ============================================================
echo                 COMPARING RESULTS
echo ============================================================
echo.
echo Please wait...
echo.

set /a OK=0
set /a WRONG=0
set /a MISSING=0
set /a EXTRA=0

REM ------------------------------------------------------------
REM Check every SOURCE file
REM ------------------------------------------------------------

for /f "usebackq tokens=1,* delims=|" %%A in ("%SOURCE_HASH%") do (

    set "REL=%%A"
    set "SOURCE_SHA=%%B"
    set "TARGET_SHA="

    for /f "tokens=1,* delims=|" %%C in ('findstr /b /l /c:"!REL!|" "%TARGET_HASH%" 2^>nul') do (
        set "TARGET_SHA=%%D"
    )

    if not defined TARGET_SHA (
        echo MISSING IN TARGET: !REL!>>"%RESULT%"
        set /a MISSING+=1
    ) else (
        if /I "!SOURCE_SHA!"=="!TARGET_SHA!" (
            echo OK: !REL!>>"%RESULT%"
            set /a OK+=1
        ) else (
            echo WRONG: !REL!>>"%RESULT%"
            echo   Source SHA-256: !SOURCE_SHA!>>"%RESULT%"
            echo   Target SHA-256: !TARGET_SHA!>>"%RESULT%"
            set /a WRONG+=1
        )
    )
)

REM ------------------------------------------------------------
REM Check for EXTRA files in TARGET
REM ------------------------------------------------------------

for /f "usebackq tokens=1,* delims=|" %%A in ("%TARGET_HASH%") do (

    set "REL=%%A"

    findstr /b /l /c:"!REL!|" "%SOURCE_HASH%" >nul 2>&1

    if errorlevel 1 (
        echo EXTRA IN TARGET: !REL!>>"%RESULT%"
        set /a EXTRA+=1
    )
)

REM ============================================================
REM Final Result
REM ============================================================

cls

echo.
echo ============================================================
echo                    VERIFICATION RESULT
echo ============================================================
echo.

echo Source folder:
echo %SOURCE%
echo.
echo Target folder:
echo %TARGET%
echo.

echo ------------------------------------------------------------
echo Summary
echo ------------------------------------------------------------
echo.
echo Matching files:       !OK!
echo Different files:      !WRONG!
echo Missing in Target:    !MISSING!
echo Extra in Target:      !EXTRA!
echo.

if !WRONG! EQU 0 if !MISSING! EQU 0 if !EXTRA! EQU 0 (
    echo ============================================================
    echo                 VERIFICATION PASSED
    echo ============================================================
    echo.
    echo All files are identical.
    echo SHA-256 verification completed successfully.
    echo.
) else (
    echo ============================================================
    echo                 VERIFICATION FAILED
    echo ============================================================
    echo.
    echo The following files have problems:
    echo.
    echo ------------------------------------------------------------

    type "%RESULT%"

    echo ------------------------------------------------------------
    echo.
)

echo.
echo Verification complete.
echo.

rd /s /q "%WORK%" >nul 2>&1

pause
exit /b 0


REM ============================================================
REM Progress Bar
REM ============================================================

:ProgressBar

set "BAR="

set /a FILLED=%1/2

for /l %%N in (1,1,50) do (
    if %%N LEQ !FILLED! (
        set "BAR=!BAR!#"
    ) else (
        set "BAR=!BAR!-"
    )
)

echo [!BAR!] %1%%

exit /b
```
