@echo off
setlocal EnableExtensions EnableDelayedExpansion

title SHA-256 Folder Verification

REM ============================================================
REM SHA-256 FOLDER VERIFICATION
REM Pure CMD / BAT
REM ============================================================

REM Create ANSI escape character
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"

echo.
echo ============================================================
echo                 SHA-256 FOLDER VERIFICATION
echo ============================================================
echo.
echo This script compares two folders recursively.
echo.
echo Source and Target folder names can be different.
echo.
echo File contents are verified using SHA-256.
echo File size is read from Windows file system information.
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

if !TARGET_COUNT! EQU 0 (
    echo [ERROR] Target folder contains no files.
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
REM PROCESS SOURCE
REM ============================================================

echo.
echo ============================================================
echo                 PROCESSING SOURCE
echo ============================================================
echo.

echo Current file:
echo.
echo Progress:
echo.

set /a CURRENT=0

for /f "usebackq delims=" %%R in ("%SOURCE_LIST%") do (

    set /a CURRENT+=1
    set /a PERCENT=CURRENT*100/SOURCE_COUNT

    set "REL=%%R"
    set "FILE=%SOURCE%\!REL!"
    set "HASH="

    REM Get SHA-256 from Windows certutil
    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    if not defined HASH (
        set "HASH=HASH_ERROR"
    )

    echo !REL!^|!HASH!>>"%SOURCE_HASH%"

    call :UpdateDisplay "SOURCE" "!REL!" "!FILE!" !CURRENT! !SOURCE_COUNT! !PERCENT!
)

REM ============================================================
REM PROCESS TARGET
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

    REM Get SHA-256 from Windows certutil
    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    if not defined HASH (
        set "HASH=HASH_ERROR"
    )

    echo !REL!^|!HASH!>>"%TARGET_HASH%"

    call :UpdateDisplay "TARGET" "!REL!" "!FILE!" !CURRENT! !TARGET_COUNT! !PERCENT!
)

REM ============================================================
REM COMPARE RESULTS
REM ============================================================

echo.
echo.
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
set /a HASHERROR=0

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

        echo NOT FOUND IN TARGET: !REL!>>"%RESULT%"
        set /a MISSING+=1

    ) else (

        if /I "!SOURCE_SHA!"=="HASH_ERROR" (

            echo HASH ERROR IN SOURCE: !REL!>>"%RESULT%"
            set /a HASHERROR+=1

        ) else if /I "!TARGET_SHA!"=="HASH_ERROR" (

            echo HASH ERROR IN TARGET: !REL!>>"%RESULT%"
            set /a HASHERROR+=1

        ) else if /I "!SOURCE_SHA!"=="!TARGET_SHA!" (

            echo OK: !REL!>>"%RESULT%"
            set /a OK+=1

        ) else (

            echo DIFFERENT: !REL!>>"%RESULT%"
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
        echo NOT FOUND IN SOURCE: !REL!>>"%RESULT%"
        set /a EXTRA+=1
    )
)

REM ============================================================
REM FINAL RESULT
REM ============================================================

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
echo Not found in Target:  !MISSING!
echo Not found in Source:  !EXTRA!
echo Hash errors:          !HASHERROR!
echo.

if !WRONG! EQU 0 if !MISSING! EQU 0 if !EXTRA! EQU 0 if !HASHERROR! EQU 0 (

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
REM Update Display Without CLS
REM ============================================================

:UpdateDisplay

set "MODE=%~1"
set "REL=%~2"
set "FILE=%~3"
set "CURRENT=%~4"
set "TOTAL=%~5"
set "PERCENT=%~6"

REM ------------------------------------------------------------
REM Get file size from Windows
REM ------------------------------------------------------------

set "FILE_SIZE_BYTES=0"

for %%F in ("!FILE!") do (
    set "FILE_SIZE_BYTES=%%~zF"
)

REM Convert Windows-reported bytes to MiB
set /a FILE_SIZE_MIB=FILE_SIZE_BYTES/1048576

REM ------------------------------------------------------------
REM Build progress bar
REM ------------------------------------------------------------

set /a FILLED=PERCENT/2

set "BAR="

for /l %%N in (1,1,50) do (
    if %%N LEQ !FILLED! (
        set "BAR=!BAR!#"
    ) else (
        set "BAR=!BAR!-"
    )
)

REM ------------------------------------------------------------
REM Move cursor up 4 lines
REM ------------------------------------------------------------

<nul set /p "=!ESC![4A"

REM Clear and rewrite current file line
<nul set /p "=!ESC![2K"
echo File: !REL!

REM Clear and rewrite path line
<nul set /p "=!ESC![2K"
echo Path: !FILE!

REM Clear and rewrite size line
<nul set /p "=!ESC![2K"
echo Size: !FILE_SIZE_MIB! MiB

REM Clear and rewrite progress line
<nul set /p "=!ESC![2K"
echo Progress: !CURRENT! / !TOTAL!  [!BAR!] !PERCENT!%%

exit /b