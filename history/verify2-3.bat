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
echo File sizes are read directly from Windows.
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
REM Count files and calculate total size
REM ============================================================

echo.
echo Scanning folders...
echo.

set /a SOURCE_COUNT=0
set /a TARGET_COUNT=0

REM Total size is stored in MiB for progress calculation.
REM Individual file sizes are still read directly from Windows.

set /a SOURCE_TOTAL_MIB=0
set /a TARGET_TOTAL_MIB=0

for /r "%SOURCE%" %%F in (*) do (
    set /a SOURCE_COUNT+=1
    set "FILE_SIZE=%%~zF"
    set /a FILE_MIB=FILE_SIZE/1048576
    set /a SOURCE_TOTAL_MIB+=FILE_MIB
)

for /r "%TARGET%" %%F in (*) do (
    set /a TARGET_COUNT+=1
    set "FILE_SIZE=%%~zF"
    set /a FILE_MIB=FILE_SIZE/1048576
    set /a TARGET_TOTAL_MIB+=FILE_MIB
)

echo Source files: !SOURCE_COUNT!
call :FormatSizeFromMiB !SOURCE_TOTAL_MIB! SOURCE_TOTAL_TEXT
echo Source size:  !SOURCE_TOTAL_TEXT!

echo Target files: !TARGET_COUNT!
call :FormatSizeFromMiB !TARGET_TOTAL_MIB! TARGET_TOTAL_TEXT
echo Target size:  !TARGET_TOTAL_TEXT!
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
echo Size:
echo.
echo File progress:
echo.
echo Size progress:
echo.

set /a CURRENT=0
set /a PROCESSED_MIB=0

for /f "usebackq delims=" %%R in ("%SOURCE_LIST%") do (

    set /a CURRENT+=1
    set /a FILE_PERCENT=CURRENT*100/SOURCE_COUNT

    set "REL=%%R"
    set "FILE=%SOURCE%\!REL!"
    set "HASH="

    REM Get current file size directly from Windows
    for %%F in ("!FILE!") do (
        set "FILE_SIZE=%%~zF"
    )

    REM Get SHA-256 from Windows certutil
    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    if not defined HASH (
        set "HASH=HASH_ERROR"
    )

    echo !REL!^|!HASH!>>"%SOURCE_HASH%"

    REM Add current file size to processed MiB
    set /a CURRENT_FILE_MIB=FILE_SIZE/1048576
    set /a PROCESSED_MIB+=CURRENT_FILE_MIB

    REM Calculate size progress
    if !SOURCE_TOTAL_MIB! GTR 0 (
        set /a SIZE_PERCENT=PROCESSED_MIB*100/SOURCE_TOTAL_MIB
    ) else (
        set /a SIZE_PERCENT=100
    )

    if !SIZE_PERCENT! GTR 100 set /a SIZE_PERCENT=100

    call :UpdateDisplay "SOURCE" "!REL!" "!FILE!" "!FILE_SIZE!" !CURRENT! !SOURCE_COUNT! !FILE_PERCENT! !SIZE_PERCENT!
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
set /a PROCESSED_MIB=0

for /f "usebackq delims=" %%R in ("%TARGET_LIST%") do (

    set /a CURRENT+=1
    set /a FILE_PERCENT=CURRENT*100/TARGET_COUNT

    set "REL=%%R"
    set "FILE=%TARGET%\!REL!"
    set "HASH="

    REM Get current file size directly from Windows
    for %%F in ("!FILE!") do (
        set "FILE_SIZE=%%~zF"
    )

    REM Get SHA-256 from Windows certutil
    for /f "skip=1 delims=" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do (
        if not defined HASH set "HASH=%%H"
    )

    if not defined HASH (
        set "HASH=HASH_ERROR"
    )

    echo !REL!^|!HASH!>>"%TARGET_HASH%"

    REM Add current file size to processed MiB
    set /a CURRENT_FILE_MIB=FILE_SIZE/1048576
    set /a PROCESSED_MIB+=CURRENT_FILE_MIB

    REM Calculate size progress
    if !TARGET_TOTAL_MIB! GTR 0 (
        set /a SIZE_PERCENT=PROCESSED_MIB*100/TARGET_TOTAL_MIB
    ) else (
        set /a SIZE_PERCENT=100
    )

    if !SIZE_PERCENT! GTR 100 set /a SIZE_PERCENT=100

    call :UpdateDisplay "TARGET" "!REL!" "!FILE!" "!FILE_SIZE!" !CURRENT! !TARGET_COUNT! !FILE_PERCENT! !SIZE_PERCENT!
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
set "FILE_SIZE=%~4"
set "CURRENT=%~5"
set "TOTAL=%~6"
set "FILE_PERCENT=%~7"
set "SIZE_PERCENT=%~8"

REM ------------------------------------------------------------
REM Convert current file size
REM ------------------------------------------------------------

set /a FILE_SIZE_KIB=FILE_SIZE/1024

if !FILE_SIZE_KIB! LSS 1024 (

    set "SIZE_TEXT=!FILE_SIZE_KIB! KiB"

) else (

    set /a FILE_SIZE_MIB=FILE_SIZE/1048576
    set "SIZE_TEXT=!FILE_SIZE_MIB! MiB"
)

REM ------------------------------------------------------------
REM Build file-count progress bar
REM ------------------------------------------------------------

set /a FILLED=FILE_PERCENT/2

set "FILE_BAR="

for /l %%N in (1,1,50) do (
    if %%N LEQ !FILLED! (
        set "FILE_BAR=!FILE_BAR!#"
    ) else (
        set "FILE_BAR=!FILE_BAR!-"
    )
)

REM ------------------------------------------------------------
REM Build size progress bar
REM ------------------------------------------------------------

set /a FILLED=SIZE_PERCENT/2

set "SIZE_BAR="

for /l %%N in (1,1,50) do (
    if %%N LEQ !FILLED! (
        set "SIZE_BAR=!SIZE_BAR!#"
    ) else (
        set "SIZE_BAR=!SIZE_BAR!-"
    )
)

REM ------------------------------------------------------------
REM Move cursor up 5 lines
REM ------------------------------------------------------------

<nul set /p "=!ESC![5A"

REM Clear and rewrite current file line
<nul set /p "=!ESC![2K"
echo File: !REL!

REM Clear and rewrite path line
<nul set /p "=!ESC![2K"
echo Path: !FILE!

REM Clear and rewrite size line
<nul set /p "=!ESC![2K"
echo Size: !SIZE_TEXT!

REM Clear and rewrite file-count progress line
<nul set /p "=!ESC![2K"
echo File progress: !CURRENT! / !TOTAL!  [!FILE_BAR!] !FILE_PERCENT!%%

REM Clear and rewrite size progress line
<nul set /p "=!ESC![2K"
echo Size progress: [!SIZE_BAR!] !SIZE_PERCENT!%%

exit /b


REM ============================================================
REM Format Total Size
REM ============================================================

:FormatSizeFromMiB

set "TOTAL_MIB=%~1"
set "OUTPUT_VAR=%~2"

if !TOTAL_MIB! LSS 1 (
    set "%OUTPUT_VAR%=0 KiB"
    exit /b
)

if !TOTAL_MIB! LSS 1024 (
    set "%OUTPUT_VAR%=!TOTAL_MIB! MiB"
    exit /b
)

REM Display large totals in MiB as requested.
set "%OUTPUT_VAR%=!TOTAL_MIB! MiB"

exit /b