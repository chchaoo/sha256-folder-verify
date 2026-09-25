@echo off
setlocal EnableExtensions

title SHA-256 Folder Verification v4

REM ============================================================
REM  SHA-256 FOLDER VERIFICATION - v4
REM
REM  One single .bat file. Nothing is ever written to disk.
REM
REM  The engine is the PowerShell code stored after the
REM  :::PS_BEGIN::: marker at the bottom of this file. The
REM  command line below does NOT carry that code, it only tells
REM  PowerShell to read this .bat file itself, take the lines
REM  after the marker and compile them in memory. So the command
REM  line stays about 200 characters no matter how long the
REM  engine grows, and no temporary .ps1 is ever created.
REM
REM  v3 extracted the engine to %TEMP% and deleted it afterwards.
REM  Closing the window with the X button skipped that delete and
REM  left the file behind. This version cannot leave anything.
REM ============================================================

echo.
echo ============================================================
echo             SHA-256 FOLDER VERIFICATION  -  v4
echo ============================================================
echo.
echo Starting, please wait...

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

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=[System.IO.File]::ReadAllLines($env:SELF); $i=[Array]::IndexOf($t,':::PS_BEGIN:::'); if($i -lt 0){ exit 9 }; $code=[string]::Join([Environment]::NewLine,$t[($i+1)..($t.Length-1)]); & ([scriptblock]::Create($code))"

if errorlevel 9 (
    echo.
    echo [ERROR] The engine marker was not found inside this file.
    echo         Make sure this .bat was not modified or truncated.
    echo.
    pause
)

endlocal & exit /b 0

:::PS_BEGIN:::
# ============================================================
#  SHA-256 FOLDER VERIFICATION - engine
#  Compiled in memory by verify4.bat. No file is written.
#  Windows PowerShell 3.0 or later.
# ============================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'SHA-256 Folder Verification v4' } catch { }

# Global scope, not script scope. This code runs as a script block
# compiled at run time, so $Script: would be ambiguous here.
$Global:BarWidth   = 40
$Global:BlockTop   = -1
$Global:BlockLines = 0
$Global:CanDraw    = $true

# ------------------------------------------------------------
#  Helpers
# ------------------------------------------------------------

function ConvertTo-DevicePath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

# .NET exceptions raised through New-Object are wrapped in an
# "Exception calling .ctor with N argument(s)" message, and the
# text contains the internal \\?\ path. Strip both so the result
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
    $filled = [int][Math]::Floor($Percent * $Global:BarWidth / 100)
    if ($filled -gt $Global:BarWidth) { $filled = $Global:BarWidth }
    return ('[' + ('#' * $filled) + ('.' * ($Global:BarWidth - $filled)) + ']')
}

function Format-Fit {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0)    { return '' }
    if ($Text.Length -le $Width)  { return $Text }
    if ($Width -le 3)             { return $Text.Substring($Text.Length - $Width) }
    return ('...' + $Text.Substring($Text.Length - ($Width - 3)))
}

# A real console window always waits for the user, so pressing ENTER
# on an empty prompt can safely mean "ask me again". But if stdin was
# redirected from a file or a pipe, end of stream also reads as an
# empty line, for ever, and the main loop would spin at full speed.
# Detect that one case and stop.
function Exit-IfInputEnded {
    $redirected = $false
    try { $redirected = [Console]::IsInputRedirected } catch { }
    if ($redirected) {
        Write-Host ''
        Write-Host '[INFO] The input stream ended. Exiting.'
        [Environment]::Exit(0)
    }
}

function Wait-AnyKey {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
    try {
        while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
        [Console]::ReadKey($true) | Out-Null
    } catch {
        Read-Host | Out-Null
    }
}

# ------------------------------------------------------------
#  Flicker free progress block
#  A fixed block of lines is reserved once, then rewritten in
#  place. Nothing is ever printed below it while it is active,
#  so the console never scrolls and never blinks.
# ------------------------------------------------------------

function Open-Block {
    param([int]$Lines)
    $Global:BlockLines = $Lines
    for ($i = 0; $i -lt $Lines; $i++) { Write-Host '' }
    try {
        $Global:BlockTop = [Console]::CursorTop - $Lines
        $Global:CanDraw  = ($Global:BlockTop -ge 0)
    } catch {
        $Global:CanDraw = $false
    }
}

function Update-Block {
    param([string[]]$Text)
    if (-not $Global:CanDraw) { return }
    try {
        $width = [Console]::BufferWidth - 1
        if ($width -lt 20) { $width = 20 }
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $Text) {
            $s = [string]$line
            if ($s.Length -gt $width) { $s = $s.Substring(0, $width) }
            $lines.Add($s.PadRight($width))
        }
        [Console]::SetCursorPosition(0, $Global:BlockTop)
        [Console]::Write([string]::Join("`r`n", $lines.ToArray()))
    } catch {
        $Global:CanDraw = $false
    }
}

function Close-Block {
    if ($Global:CanDraw) {
        try {
            [Console]::SetCursorPosition(0, $Global:BlockTop + $Global:BlockLines - 1)
            [Console]::Write("`r`n")
        } catch { }
    }
    $Global:BlockTop = -1
}

# ------------------------------------------------------------
#  Folder input, drag and drop friendly
#  Never returns until a real existing folder was given. The only
#  way out of the program is the X button of the window.
# ------------------------------------------------------------

function Read-FolderPath {
    param([string]$Title)
    while ($true) {
        Write-Host ''
        Write-Host $Title -ForegroundColor Cyan
        Write-Host '  Drag the folder into this window and press ENTER,'
        Write-Host '  or type the full path.'
        $raw = Read-Host '  >'
        if ($null -eq $raw) { $raw = '' }

        # Drag and drop adds quotes around paths that contain spaces
        # and can leave a trailing space behind. v2 kept that trailing
        # space, which made every relative path wrong and reported a
        # perfect copy as completely different.
        $p = $raw.Trim()
        if ($p -eq '') { Exit-IfInputEnded; Write-Host '  [ERROR] Nothing was entered.' -ForegroundColor Yellow; continue }
        $p = $p.Trim('"').Trim()
        if ($p -eq '') { Exit-IfInputEnded; Write-Host '  [ERROR] Nothing was entered.' -ForegroundColor Yellow; continue }

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
#  Everything is kept in memory, no list file is written.
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

            # NTFS can, in rare cases, hold two names that differ only
            # by case. The map is case insensitive like Windows itself,
            # so flag the collision instead of silently dropping one.
            if ($map.ContainsKey($item.Rel)) {
                $errors.Add($item.Rel + ' -> duplicate name that differs only by upper/lower case')
            }

            # A file that cannot be hashed is stored as $null and can
            # never compare equal to anything. v2 stored the certutil
            # error message in place of the hash, so two unreadable
            # files were reported as a perfect match.
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

# ------------------------------------------------------------
#  One complete verification round
# ------------------------------------------------------------

function Invoke-Round {

    $source = Read-FolderPath 'SOURCE folder   the original:'
    $target = Read-FolderPath 'TARGET folder   the copy:'

    $sCmp = $source.TrimEnd('\')
    $tCmp = $target.TrimEnd('\')

    if ($sCmp -ieq $tCmp) {
        Write-Host ''
        Write-Host '[ERROR] Source and Target are the same folder.' -ForegroundColor Red
        return
    }
    if ($tCmp.StartsWith($sCmp + '\', [StringComparison]::OrdinalIgnoreCase) -or $sCmp.StartsWith($tCmp + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ''
        Write-Host '[ERROR] One folder is inside the other. Cannot verify.' -ForegroundColor Red
        return
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
            if ($shown -ge 500) { break }
            Write-Host ('  ' + $line)
            $shown = $shown + 1
        }
        if ($details.Count -gt $shown) {
            Write-Host ''
            Write-Host ('  ... and ' + ($details.Count - $shown) + ' more lines, not shown.') -ForegroundColor Yellow
            Write-Host '  Nothing is saved to disk, so scroll up now if you need them.' -ForegroundColor Yellow
        }
    }
}

# ============================================================
#  MAIN LOOP
#  Runs forever. The only way out is the X button of the window.
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host '            SHA-256 FOLDER VERIFICATION  -  v4'
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
Write-Host 'Nothing is written to disk. Results are shown on screen only.'
Write-Host 'To quit, close this window with the X button.'
Write-Host ''
Write-Host '============================================================'

$round = 0

while ($true) {

    $round = $round + 1

    if ($round -gt 1) {
        Write-Host ''
        Write-Host ''
        Write-Host '############################################################' -ForegroundColor DarkGray
        Write-Host ('#  ROUND ' + $round) -ForegroundColor DarkGray
        Write-Host '############################################################' -ForegroundColor DarkGray
    }

    try {
        Invoke-Round
    } catch {
        Write-Host ''
        Write-Host ('[UNEXPECTED ERROR] ' + (Format-Reason $_)) -ForegroundColor Red
        $Global:BlockTop = -1
    }

    Wait-AnyKey 'Press any key to start the next round, or close this window to quit.'
}
