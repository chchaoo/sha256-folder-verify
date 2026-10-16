@echo off
setlocal EnableExtensions

echo.
echo ========================================
echo       SHA-256 Folder Verification
echo ========================================
echo.

REM Select Source Folder
for /f "delims=" %%A in ('powershell -NoProfile -Command ^
    "Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description='Select Source Folder'; $d.ShowNewFolderButton=$false; if($d.ShowDialog() -eq 'OK'){Write-Output $d.SelectedPath}"') do set "SOURCE=%%A"

if not defined SOURCE (
    echo [CANCELLED] No source folder was selected.
    pause
    exit /b 1
)

echo Source folder:
echo %SOURCE%
echo.

REM Select Target Folder
for /f "delims=" %%A in ('powershell -NoProfile -Command ^
    "Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description='Select Target Folder'; $d.ShowNewFolderButton=$false; if($d.ShowDialog() -eq 'OK'){Write-Output $d.SelectedPath}"') do set "TARGET=%%A"

if not defined TARGET (
    echo [CANCELLED] No target folder was selected.
    pause
    exit /b 1
)

echo Target folder:
echo %TARGET%
echo.

if /I "%SOURCE%"=="%TARGET%" (
    echo [ERROR] Source and target folders cannot be the same.
    pause
    exit /b 1
)

set "SRC_HASH=%TEMP%\sha256_source_%RANDOM%.txt"
set "DST_HASH=%TEMP%\sha256_target_%RANDOM%.txt"

echo [1/3] Calculating SHA-256 hashes for the source folder...
echo This may take some time. Please wait.
echo.

powershell -NoProfile -ExecutionPolicy Bypass ^
    "$root=(Resolve-Path -LiteralPath '%SOURCE%').Path; " ^
    "Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { " ^
    "$rel=$_.FullName.Substring($root.Length).TrimStart('\'); " ^
    "$hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; " ^
    "$hash + '  ' + $rel " ^
    "} | Sort-Object | Set-Content -LiteralPath '%SRC_HASH%' -Encoding UTF8"

if errorlevel 1 (
    echo.
    echo [ERROR] Failed to calculate the source folder.
    del "%SRC_HASH%" >nul 2>&1
    pause
    exit /b 1
)

echo [2/3] Calculating SHA-256 hashes for the target folder...
echo This may take some time. Please wait.
echo.

powershell -NoProfile -ExecutionPolicy Bypass ^
    "$root=(Resolve-Path -LiteralPath '%TARGET%').Path; " ^
    "Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { " ^
    "$rel=$_.FullName.Substring($root.Length).TrimStart('\'); " ^
    "$hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; " ^
    "$hash + '  ' + $rel " ^
    "} | Sort-Object | Set-Content -LiteralPath '%DST_HASH%' -Encoding UTF8"

if errorlevel 1 (
    echo.
    echo [ERROR] Failed to calculate the target folder.
    del "%SRC_HASH%" >nul 2>&1
    del "%DST_HASH%" >nul 2>&1
    pause
    exit /b 1
)

echo [3/3] Comparing SHA-256 manifests...
echo.

fc /b "%SRC_HASH%" "%DST_HASH%" >nul

if errorlevel 1 (
    echo.
    echo ========================================
    echo        [ VERIFICATION FAILED ]
    echo ========================================
    echo.
    echo The two folders are NOT identical.
    echo.
    echo Possible differences:
    echo   - File contents are different
    echo   - Files are missing
    echo   - Extra files exist
    echo   - File paths are different
    echo.
    echo Detailed differences:
    echo ----------------------------------------
    fc "%SRC_HASH%" "%DST_HASH%"
    echo ----------------------------------------
    echo.
) else (
    echo.
    echo ========================================
    echo        [ VERIFICATION PASSED ]
    echo ========================================
    echo.
    echo The two folders are identical.
    echo.
    echo SHA-256 verification confirms:
    echo   - All file contents are identical
    echo   - All relative paths are identical
    echo   - No files are missing
    echo   - No extra files exist
    echo.
)

del "%SRC_HASH%" >nul 2>&1
del "%DST_HASH%" >nul 2>&1

pause
