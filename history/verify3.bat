@echo off
setlocal EnableExtensions

title SHA-256 Folder Verification v3

REM ============================================================
REM  SHA-256 FOLDER VERIFICATION - v3
REM
REM  This file is only a launcher. The verification engine is
REM  the PowerShell code stored after the :::PS_BEGIN::: marker
REM  at the bottom of this file.
REM
REM  Why not pure CMD: CMD cannot safely handle file names that
REM  contain %% ! ^ or a leading ; it cannot see hidden files,
REM  empty folders, or paths longer than 260 characters, and
REM  certutil error text was being stored as if it were a hash.
REM  Those limits produced wrong results in the v2 series.
REM ============================================================

echo.
echo ============================================================
echo             SHA-256 FOLDER VERIFICATION  -  v3
echo ============================================================
echo.
echo Starting the verification engine, please wait...

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] Windows PowerShell was not found on this system.
    echo         This tool requires Windows PowerShell 3.0 or later.
    echo.
    pause
    exit /b 1
)

set "SELF=%~f0"
set "PS1=%TEMP%\verify3_%RANDOM%%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=[System.IO.File]::ReadAllLines($env:SELF); $i=[Array]::IndexOf($t,':::PS_BEGIN:::'); if($i -lt 0){ exit 1 }; [System.IO.File]::WriteAllLines($env:PS1,$t[($i+1)..($t.Length-1)])"

if errorlevel 1 (
    echo.
    echo [ERROR] Could not extract the verification engine.
    echo         Make sure this .bat file was not modified or truncated.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"

del "%PS1%" >nul 2>&1

endlocal & exit /b %RC%

:::PS_BEGIN:::
# ============================================================
#  SHA-256 FOLDER VERIFICATION - engine
#  Launched by verify3.bat. Windows PowerShell 3.0 or later.
# ============================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'SHA-256 Folder Verification v3' } catch { }

$Script:BarWidth   = 40
$Script:BlockTop   = -1
$Script:BlockLines = 0
$Script:CanDraw    = $true

# ------------------------------------------------------------
#  Helpers
# ------------------------------------------------------------

function ConvertTo-DevicePath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

# .NET exceptions raised through New-Object are wrapped in a
# "Exception calling .ctor with N argument(s)" message, and the
# text contains the internal \\?\ path. Strip both so the report
# stays readable.
function Format-Reason {
    param($ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($ErrorRecord.Exception.InnerException) {
        $msg = $ErrorRecord.Exception.InnerException.Message
    }
    $msg = $msg.Replace('\\?\UNC\', '\\').Replace('\\?\', '')
    return $msg
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    $units = @('KiB','MiB','GiB','TiB','PiB')
    $value = [double]$Bytes
    $index = -1
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    return ('{0:N2} {1}' -f $value, $units[$index])
}

function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return '--:--:--' }
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '--:--:--' }
    if ($Seconds -gt 359999) { return '99:59:59' }
    $t = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds)
}

function New-Bar {
    param([double]$Percent)
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][Math]::Floor($Percent * $Script:BarWidth / 100)
    if ($filled -gt $Script:BarWidth) { $filled = $Script:BarWidth }
    return ('[' + ('#' * $filled) + ('.' * ($Script:BarWidth - $filled)) + ']')
}

function Format-Fit {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0)    { return '' }
    if ($Text.Length -le $Width)  { return $Text }
    if ($Width -le 3)             { return $Text.Substring($Text.Length - $Width) }
    return ('...' + $Text.Substring($Text.Length - ($Width - 3)))
}

# ------------------------------------------------------------
#  Flicker free progress block
#  A fixed block of lines is reserved once, then rewritten in
#  place. Nothing is ever printed below it while it is active,
#  so the console never scrolls and never blinks.
# ------------------------------------------------------------

function Open-Block {
    param([int]$Lines)
    $Script:BlockLines = $Lines
    for ($i = 0; $i -lt $Lines; $i++) { Write-Host '' }
    try {
        $Script:BlockTop = [Console]::CursorTop - $Lines
        $Script:CanDraw  = ($Script:BlockTop -ge 0)
    } catch {
        $Script:CanDraw = $false
    }
}

function Update-Block {
    param([string[]]$Text)
    if (-not $Script:CanDraw) { return }
    try {
        $width = [Console]::BufferWidth - 1
        if ($width -lt 20) { $width = 20 }
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $Text) {
            $s = [string]$line
            if ($s.Length -gt $width) { $s = $s.Substring(0, $width) }
            $lines.Add($s.PadRight($width))
        }
        [Console]::SetCursorPosition(0, $Script:BlockTop)
        [Console]::Write([string]::Join("`r`n", $lines.ToArray()))
    } catch {
        $Script:CanDraw = $false
    }
}

function Close-Block {
    if ($Script:CanDraw) {
        try {
            [Console]::SetCursorPosition(0, $Script:BlockTop + $Script:BlockLines - 1)
            [Console]::Write("`r`n")
        } catch { }
    }
    $Script:BlockTop = -1
}

# ------------------------------------------------------------
#  Folder input, drag and drop friendly
# ------------------------------------------------------------

function Read-FolderPath {
    param([string]$Title)
    while ($true) {
        Write-Host ''
        Write-Host $Title -ForegroundColor Cyan
        Write-Host '  Drag the folder into this window and press ENTER,'
        Write-Host '  or type the full path. Enter Q to quit.'
        $raw = Read-Host '  >'
        if ($null -eq $raw) { return $null }

        # Drag and drop adds quotes around paths that contain spaces
        # and can leave a trailing space behind. v2 kept that trailing
        # space, which made every relative path wrong and reported a
        # perfect copy as completely different.
        $p = $raw.Trim()
        if ($p -eq '') { Write-Host '  [ERROR] Nothing was entered.' -ForegroundColor Yellow; continue }
        if ($p -eq 'q' -or $p -eq 'Q') { return $null }
        $p = $p.Trim('"').Trim()
        if ($p -eq '') { Write-Host '  [ERROR] Nothing was entered.' -ForegroundColor Yellow; continue }

        try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch { }

        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($p) }
        catch {
            Write-Host ('  [ERROR] Not a valid path: ' + $p) -ForegroundColor Yellow
            continue
        }

        $full = $full.TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') { $full = $full + '\' }

        if (-not [System.IO.Directory]::Exists((ConvertTo-DevicePath $full))) {
            if ([System.IO.File]::Exists((ConvertTo-DevicePath $full))) {
                Write-Host ('  [ERROR] That is a file, not a folder: ' + $full) -ForegroundColor Yellow
            } else {
                Write-Host ('  [ERROR] Folder does not exist: ' + $full) -ForegroundColor Yellow
            }
            continue
        }

        Write-Host ('  OK  ' + $full) -ForegroundColor Green
        return $full
    }
}

# ------------------------------------------------------------
#  Recursive scan
#  Uses the .NET IO API with \\?\ paths, so hidden and system
#  files are included and paths longer than 260 characters work.
# ------------------------------------------------------------

function Get-FolderTree {
    param([string]$Root)

    $files  = New-Object 'System.Collections.Generic.List[object]'
    $dirs   = New-Object 'System.Collections.Generic.List[string]'
    $links  = New-Object 'System.Collections.Generic.List[string]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $totalBytes = [long]0

    $rootDev    = ConvertTo-DevicePath $Root
    $rootPrefix = $rootDev.TrimEnd('\') + '\'

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push('')

    while ($stack.Count -gt 0) {
        $relDir = $stack.Pop()
        if ($relDir -eq '') { $absDir = $rootDev } else { $absDir = $rootPrefix + $relDir }

        $entries = $null
        try {
            $entries = [System.IO.Directory]::GetFileSystemEntries($absDir)
        } catch {
            $where = $relDir
            if ($where -eq '') { $where = '<root>' }
            $errors.Add('Cannot list folder: ' + $where + ' -> ' + (Format-Reason $_))
            continue
        }

        foreach ($entry in $entries) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($relDir -eq '') { $rel = $name } else { $rel = $relDir + '\' + $name }

            $attr = $null
            try { $attr = [System.IO.File]::GetAttributes($entry) }
            catch {
                $errors.Add('Cannot read attributes: ' + $rel + ' -> ' + (Format-Reason $_))
                continue
            }

            $isDir  = (($attr -band [System.IO.FileAttributes]::Directory)    -ne 0)
            $isLink = (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

            if ($isDir) {
                $dirs.Add($rel)
                if ($isLink) {
                    $links.Add($rel + '  (folder link or junction, contents not followed)')
                } else {
                    $stack.Push($rel)
                }
            } else {
                $size = [long]0
                try { $size = (New-Object System.IO.FileInfo($entry)).Length }
                catch { $errors.Add('Cannot read size: ' + $rel + ' -> ' + (Format-Reason $_)) }
                if ($isLink) { $links.Add($rel + '  (file link)') }
                $files.Add([pscustomobject]@{ Rel = $rel; Dev = $entry; Size = $size })
                $totalBytes = $totalBytes + $size
            }
        }
    }

    return [pscustomobject]@{
        Root       = $Root
        Files      = $files
        Dirs       = $dirs
        Links      = $links
        Errors     = $errors
        TotalBytes = $totalBytes
    }
}

# ------------------------------------------------------------
#  Hashing
# ------------------------------------------------------------

function Get-Sha256Hash {
    param([string]$DevPath, $Sha)
    $share  = ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $stream = New-Object System.IO.FileStream($DevPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share, 1048576, [System.IO.FileOptions]::SequentialScan)
    try {
        $bytes = $Sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
    }
    return [System.BitConverter]::ToString($bytes).Replace('-', '')
}

function Show-Progress {
    param(
        [string]$Label, [string]$Name, [long]$Size,
        [int]$DoneFiles, [int]$TotalFiles,
        [long]$DoneBytes, [long]$TotalBytes,
        [double]$Elapsed
    )

    if ($TotalFiles -gt 0) { $filePct = ($DoneFiles * 100.0) / $TotalFiles } else { $filePct = 100.0 }
    if ($TotalBytes -gt 0) { $bytePct = ($DoneBytes * 100.0) / $TotalBytes } else { $bytePct = 100.0 }

    if ($Elapsed -gt 0.5) { $speed = $DoneBytes / $Elapsed } else { $speed = 0 }
    if ($speed -gt 0 -and $TotalBytes -gt $DoneBytes) {
        $eta = ($TotalBytes - $DoneBytes) / $speed
    } else {
        $eta = 0
    }

    $nameWidth = 48
    try { $nameWidth = [Console]::BufferWidth - 13 } catch { }
    if ($nameWidth -lt 20) { $nameWidth = 20 }

    $lines = @(
        ('  Folder : ' + $Label),
        ('  File   : ' + (Format-Fit $Name $nameWidth)),
        ('  Size   : ' + (Format-Size $Size)),
        ('  Files  : ' + (New-Bar $filePct) + ('{0,6:N1}%' -f $filePct) + '   ' + $DoneFiles + ' / ' + $TotalFiles),
        ('  Bytes  : ' + (New-Bar $bytePct) + ('{0,6:N1}%' -f $bytePct) + '   ' + (Format-Size $DoneBytes) + ' / ' + (Format-Size $TotalBytes)),
        ('  Elapsed: ' + (Format-Clock $Elapsed) + '   ETA ' + (Format-Clock $eta) + '   ' + (Format-Size ([long]$speed)) + '/s')
    )
    Update-Block $lines
}

function Invoke-HashPhase {
    param($Tree, [string]$Label)

    $map    = @{}
    $errors = New-Object 'System.Collections.Generic.List[string]'

    $count      = $Tree.Files.Count
    $totalBytes = [long]$Tree.TotalBytes

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ('  HASHING ' + $Label + '   ' + $count + ' files, ' + (Format-Size $totalBytes))
    Write-Host '------------------------------------------------------------'

    if ($count -eq 0) {
        Write-Host '  Nothing to hash.'
        return [pscustomobject]@{ Map = $map; Errors = $errors }
    }

    Open-Block 6

    $sha        = [System.Security.Cryptography.SHA256]::Create()
    $watch      = [System.Diagnostics.Stopwatch]::StartNew()
    $doneFiles  = 0
    $doneBytes  = [long]0
    $lastDrawMs = [long](-10000)

    try {
        for ($i = 0; $i -lt $count; $i++) {

            $item = $Tree.Files[$i]

            # Draw before hashing so the name on screen is the file
            # that is actually being worked on right now.
            $now = $watch.ElapsedMilliseconds
            if ($i -eq 0 -or ($now - $lastDrawMs) -ge 80) {
                Show-Progress -Label $Label -Name $item.Rel -Size $item.Size -DoneFiles $doneFiles -TotalFiles $count -DoneBytes $doneBytes -TotalBytes $totalBytes -Elapsed $watch.Elapsed.TotalSeconds
                $lastDrawMs = $now
            }

            $hash = $null
            try {
                $hash = Get-Sha256Hash -DevPath $item.Dev -Sha $sha
            } catch {
                $errors.Add($item.Rel + ' -> ' + (Format-Reason $_))
            }

            # A file that cannot be hashed is stored as $null and can
            # never compare equal to anything. v2 stored the certutil
            # error message in place of the hash, so two unreadable
            # files were reported as a perfect match.
            # NTFS can, in rare cases, hold two names that differ only
            # by case. The map is case insensitive like Windows itself,
            # so flag the collision instead of silently dropping one.
            if ($map.ContainsKey($item.Rel)) {
                $errors.Add($item.Rel + ' -> duplicate name that differs only by upper/lower case')
            }
            $map[$item.Rel] = [pscustomobject]@{ Hash = $hash; Size = $item.Size }

            $doneFiles = $doneFiles + 1
            $doneBytes = $doneBytes + [long]$item.Size
        }
    } finally {
        try { $sha.Dispose() } catch { }
    }

    $last = $Tree.Files[$count - 1]
    Show-Progress -Label $Label -Name $last.Rel -Size $last.Size -DoneFiles $doneFiles -TotalFiles $count -DoneBytes $doneBytes -TotalBytes $totalBytes -Elapsed $watch.Elapsed.TotalSeconds
    Close-Block

    Write-Host ('  Finished in ' + (Format-Clock $watch.Elapsed.TotalSeconds) + '.')

    return [pscustomobject]@{ Map = $map; Errors = $errors }
}

# ============================================================
#  MAIN
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host '            SHA-256 FOLDER VERIFICATION  -  v3'
Write-Host '============================================================'
Write-Host ''
Write-Host 'Compares a folder with its copy, file by file, using SHA-256.'
Write-Host 'The two top folders may have different names.'
Write-Host ''
Write-Host 'Checked     : file contents, relative paths, hidden and system'
Write-Host '              files, empty sub folders, extra files.'
Write-Host 'Not checked : timestamps, permissions, attributes,'
Write-Host '              alternate data streams.'
Write-Host ''
Write-Host '============================================================'

$source = Read-FolderPath 'SOURCE folder   the original:'
if ($null -eq $source) { Write-Host ''; Write-Host 'Cancelled.'; Read-Host 'Press ENTER to close'; exit 2 }

$target = Read-FolderPath 'TARGET folder   the copy:'
if ($null -eq $target) { Write-Host ''; Write-Host 'Cancelled.'; Read-Host 'Press ENTER to close'; exit 2 }

$sCmp = $source.TrimEnd('\')
$tCmp = $target.TrimEnd('\')

if ($sCmp -ieq $tCmp) {
    Write-Host ''
    Write-Host '[ERROR] Source and Target are the same folder.' -ForegroundColor Red
    Read-Host 'Press ENTER to close'
    exit 1
}
if ($tCmp.StartsWith($sCmp + '\', [StringComparison]::OrdinalIgnoreCase) -or $sCmp.StartsWith($tCmp + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Host ''
    Write-Host '[ERROR] One folder is inside the other. Cannot verify.' -ForegroundColor Red
    Read-Host 'Press ENTER to close'
    exit 1
}

Write-Host ''
Write-Host 'Scanning folders, please wait...'

$totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

$srcTree = Get-FolderTree -Root $source
Write-Host ('  SOURCE : ' + $srcTree.Files.Count + ' files, ' + $srcTree.Dirs.Count + ' folders, ' + (Format-Size $srcTree.TotalBytes))

$dstTree = Get-FolderTree -Root $target
Write-Host ('  TARGET : ' + $dstTree.Files.Count + ' files, ' + $dstTree.Dirs.Count + ' folders, ' + (Format-Size $dstTree.TotalBytes))

$srcPhase = Invoke-HashPhase -Tree $srcTree -Label 'SOURCE'
$dstPhase = Invoke-HashPhase -Tree $dstTree -Label 'TARGET'

# ------------------------------------------------------------
#  Compare
# ------------------------------------------------------------

Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host '  COMPARING'
Write-Host '------------------------------------------------------------'

$srcMap = $srcPhase.Map
$dstMap = $dstPhase.Map

$same       = 0
$different  = 0
$missing    = 0
$extra      = 0
$hashErrors = 0

$details = New-Object 'System.Collections.Generic.List[string]'

foreach ($rel in ($srcMap.Keys | Sort-Object)) {
    $s = $srcMap[$rel]
    if (-not $dstMap.ContainsKey($rel)) {
        $details.Add('[MISSING IN TARGET]  ' + $rel)
        $missing = $missing + 1
        continue
    }
    $d = $dstMap[$rel]
    if ($null -eq $s.Hash -or $null -eq $d.Hash) {
        $details.Add('[CANNOT READ]        ' + $rel)
        if ($null -eq $s.Hash) { $details.Add('                     the SOURCE file could not be read') }
        if ($null -eq $d.Hash) { $details.Add('                     the TARGET file could not be read') }
        $hashErrors = $hashErrors + 1
        continue
    }
    if ($s.Hash -eq $d.Hash) {
        $same = $same + 1
    } else {
        $details.Add('[CONTENT DIFFERS]    ' + $rel)
        $details.Add('                     source ' + $s.Hash + '  ' + $s.Size + ' bytes')
        $details.Add('                     target ' + $d.Hash + '  ' + $d.Size + ' bytes')
        $different = $different + 1
    }
}

foreach ($rel in ($dstMap.Keys | Sort-Object)) {
    if (-not $srcMap.ContainsKey($rel)) {
        $details.Add('[EXTRA IN TARGET]    ' + $rel)
        $extra = $extra + 1
    }
}

# Folders are compared too, otherwise a lost empty folder would
# never be noticed.
$srcDirSet = @{}
foreach ($d in $srcTree.Dirs) { $srcDirSet[$d] = $true }
$dstDirSet = @{}
foreach ($d in $dstTree.Dirs) { $dstDirSet[$d] = $true }

$dirMissing = 0
$dirExtra   = 0
foreach ($d in ($srcTree.Dirs | Sort-Object)) {
    if (-not $dstDirSet.ContainsKey($d)) { $details.Add('[FOLDER MISSING IN TARGET]  ' + $d); $dirMissing = $dirMissing + 1 }
}
foreach ($d in ($dstTree.Dirs | Sort-Object)) {
    if (-not $srcDirSet.ContainsKey($d)) { $details.Add('[FOLDER EXTRA IN TARGET]    ' + $d); $dirExtra = $dirExtra + 1 }
}

foreach ($e in $srcTree.Errors)  { $details.Add('[SCAN ERROR SOURCE]  ' + $e) }
foreach ($e in $dstTree.Errors)  { $details.Add('[SCAN ERROR TARGET]  ' + $e) }
foreach ($e in $srcPhase.Errors) { $details.Add('[READ ERROR SOURCE]  ' + $e) }
foreach ($e in $dstPhase.Errors) { $details.Add('[READ ERROR TARGET]  ' + $e) }

$scanErrors = $srcTree.Errors.Count + $dstTree.Errors.Count

$notes = New-Object 'System.Collections.Generic.List[string]'
foreach ($l in $srcTree.Links) { $notes.Add('[LINK SOURCE]  ' + $l) }
foreach ($l in $dstTree.Links) { $notes.Add('[LINK TARGET]  ' + $l) }

$totalWatch.Stop()

$passed = ($different -eq 0 -and $missing -eq 0 -and $extra -eq 0 -and $hashErrors -eq 0 -and $dirMissing -eq 0 -and $dirExtra -eq 0 -and $scanErrors -eq 0)

# ------------------------------------------------------------
#  Result
# ------------------------------------------------------------

Write-Host ''
Write-Host '============================================================'
Write-Host '                   VERIFICATION RESULT'
Write-Host '============================================================'
Write-Host ''
Write-Host ('  Source : ' + $source)
Write-Host ('  Target : ' + $target)
Write-Host ''
Write-Host ('  Identical files           : {0}' -f $same)
Write-Host ('  Different content         : {0}' -f $different)
Write-Host ('  Missing in target         : {0}' -f $missing)
Write-Host ('  Extra in target           : {0}' -f $extra)
Write-Host ('  Files that cannot be read : {0}' -f $hashErrors)
Write-Host ('  Folders missing in target : {0}' -f $dirMissing)
Write-Host ('  Folders extra in target   : {0}' -f $dirExtra)
Write-Host ('  Scan errors               : {0}' -f $scanErrors)
Write-Host ('  Total time                : {0}' -f (Format-Clock $totalWatch.Elapsed.TotalSeconds))
Write-Host ''

if ($notes.Count -gt 0) {
    Write-Host '  Notes:'
    foreach ($n in $notes) { Write-Host ('    ' + $n) -ForegroundColor DarkYellow }
    Write-Host ''
}

if ($passed) {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '                 VERIFICATION PASSED' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Every source file has a file at the same relative path in'
    Write-Host '  the target with an identical SHA-256 hash, and the target'
    Write-Host '  contains nothing extra. The copy is complete and correct.'
} else {
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host '                 VERIFICATION FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ''
    $shown = 0
    foreach ($line in $details) {
        if ($shown -ge 200) { break }
        Write-Host ('  ' + $line)
        $shown = $shown + 1
    }
    if ($details.Count -gt $shown) {
        Write-Host ''
        Write-Host ('  ... and ' + ($details.Count - $shown) + ' more lines, see the report file.')
    }
}

$reportPath = $null
try {
    $stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportPath = Join-Path $env:TEMP ('verify3_report_' + $stamp + '.txt')
    $report     = New-Object 'System.Collections.Generic.List[string]'
    $report.Add('SHA-256 FOLDER VERIFICATION - v3')
    $report.Add('Date   : ' + (Get-Date))
    $report.Add('Source : ' + $source)
    $report.Add('Target : ' + $target)
    $report.Add('')
    if ($passed) { $report.Add('RESULT : PASSED - the two folders are identical') }
    else         { $report.Add('RESULT : FAILED - see the list below') }
    $report.Add('')
    $report.Add('Identical files           : ' + $same)
    $report.Add('Different content         : ' + $different)
    $report.Add('Missing in target         : ' + $missing)
    $report.Add('Extra in target           : ' + $extra)
    $report.Add('Files that cannot be read : ' + $hashErrors)
    $report.Add('Folders missing in target : ' + $dirMissing)
    $report.Add('Folders extra in target   : ' + $dirExtra)
    $report.Add('Scan errors               : ' + $scanErrors)
    $report.Add('')
    foreach ($n in $notes)   { $report.Add($n) }
    foreach ($l in $details) { $report.Add($l) }
    [System.IO.File]::WriteAllLines($reportPath, $report.ToArray(), [System.Text.Encoding]::UTF8)
} catch {
    $reportPath = $null
}

Write-Host ''
if ($reportPath) { Write-Host ('  Full report: ' + $reportPath) }
Write-Host ''
Read-Host 'Press ENTER to close'

if ($passed) { exit 0 } else { exit 1 }
