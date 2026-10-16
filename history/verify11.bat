@echo off
setlocal EnableExtensions

title SHA-256 Folder Verification

REM ============================================================
REM  SHA-256 FOLDER VERIFICATION
REM
REM  One single .bat file.
REM
REM  The engine is the PowerShell code stored after the
REM  :::PS_BEGIN::: marker at the bottom of this file. The
REM  command line below does NOT carry that code, it only tells
REM  PowerShell to read this .bat file itself, take the lines
REM  after the marker and compile them in memory. So the command
REM  line stays about 200 characters no matter how long the
REM  engine grows, and no temporary .ps1 is ever created.
REM
REM  Each folder is read by one single thread, file after file,
REM  which is what a mechanical hard disk needs. Folders on two
REM  physical disks are read at the same time, folders on the
REM  same physical disk one after the other, even when they are
REM  on two different partitions of it.
REM
REM  Progress is saved to verify_resume.txt next to the .bat, so
REM  an interrupted run can be continued. The name is fixed and
REM  does not depend on the name of the .bat file.
REM
REM  The resume file is the only file this tool ever writes, it
REM  sits next to the .bat where you can see it, and it is
REM  deleted as soon as a verification finishes.
REM ============================================================

echo.
echo ============================================================
echo                 SHA-256 FOLDER VERIFICATION
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
set "RESUMEFILE=%~dp0verify_resume.txt"

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
#  Compiled in memory by the .bat file that contains it.
#  Windows PowerShell 3.0 or later.
# ============================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'SHA-256 Folder Verification' } catch { }

# ------------------------------------------------------------
#  SETTINGS
# ------------------------------------------------------------

$Global:ResumeMagic = 'SHA256-FOLDER-VERIFY-RESUME'
$Global:BarWidth    = 40
$Global:BlockTop    = -1
$Global:BlockLines  = 0
$Global:CanDraw     = $true

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

# Format-Clock is fixed width for the progress block. For the two
# summary lines a short form reads better, and a run that takes half
# a second no longer shows up as 00:00:00.
function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return '--' }
    if ($Seconds -lt 60) { return ('{0:N1} s' -f $Seconds) }
    return (Format-Clock $Seconds)
}

function New-Bar {
    param([double]$Percent)
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][Math]::Floor($Percent * $Global:BarWidth / 100)
    if ($filled -gt $Global:BarWidth) { $filled = $Global:BarWidth }
    return ('[' + ('#' * $filled) + ('.' * ($Global:BarWidth - $filled)) + ']')
}

# ------------------------------------------------------------
#  Console column width
#
#  The console gives a Chinese, Japanese or Korean character, and
#  a full width form, TWO columns, but the string counts it as ONE
#  character. Anything that cuts or pads a line by .Length is
#  therefore wrong as soon as a file name contains such a
#  character: the line comes out wider than the window and wraps
#  into the next row. So every cut and pad on the progress block
#  is done in columns, not in characters.
#
#  A character outside the Basic Multilingual Plane is a surrogate
#  pair of two UTF-16 units. It is counted as two columns and is
#  never split. Combining marks and zero width characters take no
#  column.
# ------------------------------------------------------------

function Get-CharWidth {
    param([int]$Code)
    if ($Code -lt 0x0300) { return 1 }
    if ($Code -le 0x036F) { return 0 }
    if ($Code -ge 0x200B -and $Code -le 0x200F) { return 0 }
    if ($Code -ge 0xD800 -and $Code -le 0xDBFF) { return 2 }
    if ($Code -ge 0xDC00 -and $Code -le 0xDFFF) { return 0 }
    if (($Code -ge 0x1100 -and $Code -le 0x115F) -or
        ($Code -ge 0x2E80 -and $Code -le 0x303E) -or
        ($Code -ge 0x3041 -and $Code -le 0x33FF) -or
        ($Code -ge 0x3400 -and $Code -le 0x4DBF) -or
        ($Code -ge 0x4E00 -and $Code -le 0x9FFF) -or
        ($Code -ge 0xA000 -and $Code -le 0xA4CF) -or
        ($Code -ge 0xAC00 -and $Code -le 0xD7A3) -or
        ($Code -ge 0xF900 -and $Code -le 0xFAFF) -or
        ($Code -ge 0xFE30 -and $Code -le 0xFE4F) -or
        ($Code -ge 0xFF00 -and $Code -le 0xFF60) -or
        ($Code -ge 0xFFE0 -and $Code -le 0xFFE6)) { return 2 }
    return 1
}

function Get-TextWidth {
    param([string]$Text)
    if ($null -eq $Text) { return 0 }
    if ($Text -match '^[\x20-\x7E]*$') { return $Text.Length }
    $w = 0
    foreach ($c in $Text.ToCharArray()) { $w = $w + (Get-CharWidth ([int]$c)) }
    return $w
}

# Longest start of the text that fits in Width columns.
function Limit-Width {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { return '' }
    if ($Width -le 0)    { return '' }
    if ($Text -match '^[\x20-\x7E]*$') {
        if ($Text.Length -le $Width) { return $Text }
        return $Text.Substring(0, $Width)
    }
    $used = 0
    $i    = 0
    while ($i -lt $Text.Length) {
        $n = 1
        if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) { $n = 2 }
        $w = Get-CharWidth ([int]$Text[$i])
        if (($used + $w) -gt $Width) { break }
        $used = $used + $w
        $i    = $i + $n
    }
    return $Text.Substring(0, $i)
}

# Fit a file name into Width columns. The END of the path is kept,
# because that is the part that tells which file it is.
function Format-Fit {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0)    { return '' }
    if ((Get-TextWidth $Text) -le $Width) { return $Text }
    if ($Width -le 3)    { return ('.' * $Width) }
    $room = $Width - 3
    $used = 0
    $i    = $Text.Length
    while ($i -gt 0) {
        $n = 1
        if ([char]::IsLowSurrogate($Text[$i - 1]) -and ($i - 2) -ge 0 -and [char]::IsHighSurrogate($Text[$i - 2])) { $n = 2 }
        $w = Get-CharWidth ([int]$Text[$i - $n])
        if (($used + $w) -gt $room) { break }
        $used = $used + $w
        $i    = $i - $n
    }
    return ('...' + $Text.Substring($i))
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
        # Plain exit, not [Environment]::Exit. Both end the process from
        # inside the compiled script block, but Environment::Exit spends
        # about 2.4 seconds in teardown while exit takes about 0.1.
        exit 0
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

function Read-YesNo {
    param([string]$Question)
    while ($true) {
        Write-Host ''
        Write-Host $Question -ForegroundColor Cyan
        $answer = Read-Host '  [Y/N]'
        if ($null -eq $answer) { $answer = '' }
        $answer = $answer.Trim()
        if ($answer -eq '')  { Exit-IfInputEnded; continue }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host '  Please answer Y or N.' -ForegroundColor Yellow
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

# Every row of the block is drawn on its own: jump to the start of
# the row, write the text cut to the window width in columns, then
# blank the rest of the row. How much is blanked is taken from the
# column the cursor really reached, not from a calculation, so the
# row is cleared exactly to its end even if the console draws a
# character wider or narrower than expected. The last column of the
# window is never written, because writing there makes the console
# wrap to the next row.
function Update-Block {
    param([string[]]$Text)
    if (-not $Global:CanDraw) { return }
    try {
        $width = [Console]::BufferWidth - 1
        if ($width -lt 20) { $width = 20 }
        for ($i = 0; $i -lt $Global:BlockLines; $i++) {
            $s = ''
            if ($i -lt $Text.Count) { $s = Limit-Width ([string]$Text[$i]) $width }
            $row = $Global:BlockTop + $i
            [Console]::SetCursorPosition(0, $row)
            if ($s.Length -gt 0) { [Console]::Write($s) }
            $col = $width
            if ([Console]::CursorTop -eq $row) { $col = [Console]::CursorLeft }
            if ($col -lt $width) { [Console]::Write(' ' * ($width - $col)) }
        }
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
        # and can leave a trailing space behind. Keeping that space
        # would make every relative path wrong, and a perfect copy
        # would be reported as completely different.
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
#  The whole tree is kept in memory.
# ------------------------------------------------------------

function Get-FolderTree {
    param([string]$Root, [string]$ExcludeDev)

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

            # The resume file lives next to the .bat. If the .bat happens
            # to sit inside one of the two folders, the resume file would
            # look like an extra file that the other side does not have.
            if ($ExcludeDev -and ($entry -ieq $ExcludeDev)) { continue }

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
                $size  = [long]0
                $mtime = [long]0
                try {
                    $info  = New-Object System.IO.FileInfo($entry)
                    $size  = $info.Length
                    $mtime = $info.LastWriteTimeUtc.Ticks
                }
                catch { $errors.Add('Cannot read size: ' + $rel + ' -> ' + (Format-Reason $_)) }
                if ($isLink) { $links.Add($rel + '  (file link)') }
                $files.Add([pscustomobject]@{ Rel = $rel; Dev = $entry; Size = $size; Mtime = $mtime })
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
#  Resume file
#
#  Format, UTF-8, one record per line:
#     SHA256-FOLDER-VERIFY-RESUME
#     SRC|<source folder>
#     DST|<target folder>
#     S|<size>|<mtime ticks>|<sha256>|<relative path>
#     T|<size>|<mtime ticks>|<sha256>|<relative path>
#
#  The relative path is last because it is the only field that
#  may contain almost anything. Windows file names cannot contain
#  a vertical bar, so the first four fields split cleanly.
#
#  Only successfully hashed files are written. A file that could
#  not be read is left out on purpose, so it is tried again.
#  Size and modification time are stored with every hash, and a
#  stored hash is only reused when both still match, so a file
#  that changed after the interruption is hashed again.
# ------------------------------------------------------------

function Read-Checkpoint {
    param([string]$Path)

    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) }
    catch { return $null }

    if ($lines.Length -lt 3)                     { return $null }
    if ($lines[0] -ne $Global:ResumeMagic)       { return $null }
    if (-not $lines[1].StartsWith('SRC|'))       { return $null }
    if (-not $lines[2].StartsWith('DST|'))       { return $null }

    $known = @{}
    for ($i = 3; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -eq '') { continue }
        $parts = $line.Split([char]124, 5)
        if ($parts.Length -lt 5) { continue }
        if ($parts[0] -ne 'S' -and $parts[0] -ne 'T') { continue }
        try {
            $known[$parts[0] + '|' + $parts[4]] = [pscustomobject]@{
                Size  = [long]$parts[1]
                Mtime = [long]$parts[2]
                Hash  = $parts[3]
            }
        } catch { }
    }

    return [pscustomobject]@{
        Source = $lines[1].Substring(4)
        Target = $lines[2].Substring(4)
        Known  = $known
        Count  = $known.Count
    }
}

function Remove-Checkpoint {
    param([string]$Path)
    try {
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
        return $true
    } catch {
        Write-Host ('  [WARNING] Could not delete the resume file: ' + (Format-Reason $_)) -ForegroundColor Yellow
        return $false
    }
}

function Open-Checkpoint {
    param([string]$Path, [string]$Source, [string]$Target, [bool]$Append)
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($Path, $Append, $enc)
        $writer.AutoFlush = $true
        if (-not $Append) {
            $writer.WriteLine($Global:ResumeMagic)
            $writer.WriteLine('SRC|' + $Source)
            $writer.WriteLine('DST|' + $Target)
        }
        return $writer
    } catch {
        Write-Host ''
        Write-Host ('[WARNING] Cannot write the resume file next to this .bat:') -ForegroundColor Yellow
        Write-Host ('          ' + (Format-Reason $_)) -ForegroundColor Yellow
        Write-Host  '          The verification will run, but it cannot be resumed.' -ForegroundColor Yellow
        return $null
    }
}

# ------------------------------------------------------------
#  Hashing, one reader thread per folder
#
#  A mechanical hard disk is fast only while it reads one file
#  from start to end without interruption. Several threads
#  reading from the same disk make the heads jump between files
#  and the throughput collapses. So each folder gets exactly ONE
#  reader thread, which reads its files strictly one after
#  another, in the order the scan found them.
#
#  When the two folders are on different physical disks, the two
#  readers run at the same time, so both disks stay busy. When
#  they are on the same physical disk, even on two different
#  partitions or drive letters of it, the target reader only
#  starts after the source reader has finished, so that one disk
#  is never read at two places at once.
#
#  The main thread only draws the progress block and writes the
#  resume file, so the resume file has exactly one writer.
# ------------------------------------------------------------

# The reader hashes each file in 1 MiB blocks and publishes the
# byte count after every block, so progress and speed move even
# while one very large file is being read.
#
# It also collects what is needed to find the fixed cost of one
# file, the time spent on a file apart from reading its bytes
# (finding it on disk, opening it, the seek to its first block).
# Every finished file is one sample of (size, seconds), and the
# reader keeps the five running sums of a least squares fit of
#
#     seconds = A + K * size
#
# where A is that fixed cost. Samples fade out with a time
# constant of 15 seconds, so only recent files count.

$Global:ReaderScript = @'
param($Queue, $Results, $State, $Side)

$share = ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
$buf   = New-Object byte[] 1048576
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$item  = $null
$n     = 0
$b     = [long]0
$tau   = 15.0
$w  = 0.0; $sx  = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
$last  = 0.0

try {
    while ($Queue.TryDequeue([ref]$item)) {

        $State['C' + $Side] = $item
        $t0   = $clock.Elapsed.TotalSeconds
        $hash = $null
        $err  = $null
        $got  = [long]0
        $sha  = $null

        try {
            $sha    = [System.Security.Cryptography.SHA256]::Create()
            $stream = New-Object System.IO.FileStream($item.Dev, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share, 4096, [System.IO.FileOptions]::SequentialScan)
            try {
                while (($r = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                    $null = $sha.TransformBlock($buf, 0, $r, $null, 0)
                    $got  = $got + $r
                    if ($got -lt $item.Size) { $State['B' + $Side] = $b + $got } else { $State['B' + $Side] = $b + $item.Size }
                }
                $null = $sha.TransformFinalBlock($buf, 0, 0)
                $hash = [System.BitConverter]::ToString($sha.Hash).Replace('-', '')
            } finally { $stream.Dispose() }
        } catch {
            $err = $_.Exception.Message
            if ($_.Exception.InnerException) { $err = $_.Exception.InnerException.Message }
            $err = $err.Replace('\\?\UNC\', '\\').Replace('\\?\', '')
        } finally {
            if ($sha) { try { $sha.Dispose() } catch { } }
        }

        $t1 = $clock.Elapsed.TotalSeconds

        # Only files that were read completely are timing samples.
        if (-not $err) {
            $f   = [Math]::Exp(-($t1 - $last) / $tau)
            $x   = $got / 1048576.0
            $y   = $t1 - $t0
            $w   = $w   * $f + 1.0
            $sx  = $sx  * $f + $x
            $sy  = $sy  * $f + $y
            $sxx = $sxx * $f + $x * $x
            $sxy = $sxy * $f + $x * $y
            $last = $t1
            $State['M' + $Side] = @($w, $sx, $sy, $sxx, $sxy)
        }

        $Results.Enqueue([pscustomobject]@{
            Side  = $Side
            Rel   = $item.Rel
            Size  = $item.Size
            Mtime = $item.Mtime
            Hash  = $hash
            Error = $err
        })

        $n = $n + 1
        $b = $b + $item.Size
        $State['F' + $Side] = $n
        $State['B' + $Side] = $b
    }
} finally {
    $State['E' + $Side] = $clock.Elapsed.TotalSeconds
    $State['C' + $Side] = $null
    $State['D' + $Side] = $true
}
'@

# ------------------------------------------------------------
#  Which physical disk a folder is on
#
#  Drive letters are not enough: two partitions of one disk have
#  two letters but share one set of heads. So the letter is
#  followed down through WMI, from logical disk to partition to
#  physical disk. A SUBST drive is first replaced by the folder it
#  points to. A volume that spans several disks gives all of them.
#  A network path is keyed by its server, so two shares of the
#  same NAS are also read one after the other.
#
#  If the disk cannot be found out, the two folders are treated as
#  being on the same disk. Reading one after the other is only
#  slower, reading at the same time on one disk is much slower.
# ------------------------------------------------------------

function Resolve-SubstPath {
    param([string]$Path)
    $p = $Path
    for ($round = 0; $round -lt 8; $round++) {
        if ($p -notmatch '^[A-Za-z]:') { break }
        $letter = $p.Substring(0, 2).ToUpperInvariant()
        $lines  = $null
        try { $lines = @(& subst.exe 2>$null) } catch { break }
        $hit = $null
        foreach ($line in $lines) {
            $s = [string]$line
            if ($s.Length -gt 8 -and $s.Substring(0, 2).ToUpperInvariant() -eq $letter -and $s.IndexOf(': => ') -eq 3) {
                $hit = $s.Substring(8)
                break
            }
        }
        if (-not $hit) { break }
        $rest = $p.Substring(2).TrimStart('\')
        if ($rest -eq '') { $p = $hit } else { $p = $hit.TrimEnd('\') + '\' + $rest }
    }
    return $p
}

function Get-DiskInfo {
    param([string]$Path)

    $p = Resolve-SubstPath $Path

    if ($p.StartsWith('\\')) {
        $server = $p.Substring(2).Split('\')[0].ToUpperInvariant()
        return [pscustomobject]@{ Keys = @('NET:' + $server); Label = ('network share on ' + $server); Known = $true }
    }

    if ($p -notmatch '^[A-Za-z]:') {
        return [pscustomobject]@{ Keys = @(); Label = 'unknown'; Known = $false }
    }
    $letter = $p.Substring(0, 2).ToUpperInvariant()

    try {
        $ld = Get-WmiObject -Class Win32_LogicalDisk -Filter ("DeviceID='" + $letter + "'") -ErrorAction Stop
        if ($ld -and $ld.DriveType -eq 4 -and $ld.ProviderName) {
            $server = ([string]$ld.ProviderName).TrimStart('\').Split('\')[0].ToUpperInvariant()
            return [pscustomobject]@{ Keys = @('NET:' + $server); Label = ('network share on ' + $server); Known = $true }
        }

        $parts = @(Get-WmiObject -Query ("ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='" + $letter + "'} WHERE AssocClass=Win32_LogicalDiskToPartition") -ErrorAction Stop)
        $indexes = @($parts | ForEach-Object { [int]$_.DiskIndex } | Sort-Object -Unique)
        if ($indexes.Count -eq 0) {
            return [pscustomobject]@{ Keys = @(); Label = ($letter + ' unknown disk'); Known = $false }
        }

        $keys  = @()
        $names = @()
        foreach ($i in $indexes) {
            $keys += ('DISK:' + $i)
            $model = ''
            try {
                $drive = Get-WmiObject -Class Win32_DiskDrive -Filter ('Index=' + $i) -ErrorAction Stop
                if ($drive -and $drive.Model) { $model = ([string]$drive.Model).Trim() }
            } catch { }
            if ($model -ne '') { $names += ('disk ' + $i + '  ' + $model) } else { $names += ('disk ' + $i) }
        }
        return [pscustomobject]@{ Keys = $keys; Label = ($letter + '  ' + ($names -join ' + ')); Known = $true }
    } catch {
        return [pscustomobject]@{ Keys = @(); Label = ($letter + ' unknown disk'); Known = $false }
    }
}

function Get-ReadPlan {
    param([string]$Source, [string]$Target)

    $s = Get-DiskInfo $Source
    $t = Get-DiskInfo $Target

    $shared = $false
    foreach ($k in $s.Keys) { if ($t.Keys -contains $k) { $shared = $true } }

    if (-not $s.Known -or -not $t.Known) {
        $sequential = $true
        $reason     = 'one folder after the other, the disks could not be identified'
    } elseif ($shared) {
        $sequential = $true
        $reason     = 'one folder after the other, both are on the same disk or server'
    } else {
        $sequential = $false
        $reason     = 'both folders at once, one thread each, they are on different disks'
    }

    return [pscustomobject]@{
        Sequential  = $sequential
        Reason      = $reason
        SourceLabel = $s.Label
        TargetLabel = $t.Label
    }
}

# ------------------------------------------------------------
#  Time estimate
#
#  For each side:
#
#     remaining = A * (files not yet started)
#               + K * (MiB not yet read)
#
#  K, seconds per MiB, comes straight from the read speed measured
#  over the last 3 seconds, the same speed that is shown on screen.
#  A, the fixed cost per file, is only needed when small and large
#  files are mixed: a speed measured on large files says nothing
#  about thousands of small ones still waiting, and the other way
#  round. The time A took for the files finished in the window is
#  taken out before K is worked out, so it is not counted twice.
#  When remaining files look like the recent ones, the result is
#  simply remaining bytes divided by the current speed.
#
#  With two disks read at the same time the run ends when the
#  slower side ends, so the estimate is the larger of the two.
#  With one disk read side after side the two are added, and
#  until the target has figures of its own it borrows the
#  source's, because it is the same disk.
# ------------------------------------------------------------

$Global:SpeedWindow = 3.0

# The fixed cost per file from the running sums, or $null when the
# recent files do not allow it. A fit needs files of clearly
# different sizes; when they are all about the same size, the
# fixed cost and the read time cannot be told apart.
function Get-FixedCost {
    param($Sums)
    if (-not $Sums) { return $null }
    $w = [double]$Sums[0]; $sx = [double]$Sums[1]; $sy = [double]$Sums[2]; $sxx = [double]$Sums[3]; $sxy = [double]$Sums[4]
    if ($w -lt 3 -or $sx -le 0) { return $null }
    $den = $w * $sxx - $sx * $sx
    if ($den -le (0.05 * $w * $sxx)) { return $null }
    $k = ($w * $sxy - $sx * $sy) / $den
    $a = ($sy - $k * $sx) / $w
    if ($k -le 0 -or $a -lt 0) { return $null }
    return $a
}

function Get-SideSeconds {
    param($Model, [double]$FilesLeft, [double]$BytesLeft)
    if ($null -eq $Model) { return -1.0 }
    if ($BytesLeft -gt 0 -and $null -eq $Model.K) { return -1.0 }
    $s = $Model.A * $FilesLeft
    if ($BytesLeft -gt 0) { $s = $s + $Model.K * ($BytesLeft / 1048576.0) }
    return $s
}

# ------------------------------------------------------------
#  Progress block
# ------------------------------------------------------------

function Get-SideLabel {
    param($View, [int]$Width)
    if ($View.Phase -eq 'done') {
        if ($View.Average -gt 0) { return ('(done)   average ' + (Format-Size ([long]$View.Average)) + '/s') }
        return '(done)'
    }
    if ($View.Phase -eq 'wait') { return '(waiting, same disk as the source)' }
    if ($null -eq $View.Current) { return '(starting)' }

    if ($View.Speed -ge 0) { $speed = (Format-Size ([long]$View.Speed)) + '/s' } else { $speed = '--' }
    return (('{0,14}' -f $speed) + '   ' + (Format-Fit $View.Current.Rel $Width) + '   ' + (Format-Size $View.Current.Size))
}

function Show-HashProgress {
    param($Src, $Dst, [double]$Elapsed, [double]$Eta)

    $allDone  = [long]$Src.Bytes + [long]$Dst.Bytes
    $allTotal = [long]$Src.TotalBytes + [long]$Dst.TotalBytes
    if ($allTotal -gt 0) { $allPct = ($allDone * 100.0) / $allTotal } else { $allPct = 100.0 }

    $cols = 80
    try { $cols = [Console]::BufferWidth } catch { }

    # A Bytes row is the longest: 11 columns of label, the bar with its
    # two brackets, 7 for the percentage, then up to 12 + 3 + 12 for the
    # two sizes, and the last console column is never written to. The
    # bar shrinks so that this row still fits in an 80 column window.
    $Global:BarWidth = $cols - 1 - 50
    if ($Global:BarWidth -gt 40) { $Global:BarWidth = 40 }
    if ($Global:BarWidth -lt 10) { $Global:BarWidth = 10 }

    # 11 columns of label, 14 for the speed, 3 spaces, the name, 3
    # spaces, up to 12 for the size, and the last column stays free.
    $nameWidth = $cols - 44
    if ($nameWidth -lt 20) { $nameWidth = 20 }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $first = $true
    foreach ($pair in @(@('  SOURCE : ', $Src), @('  TARGET : ', $Dst))) {
        if (-not $first) { $lines.Add('') }
        $first = $false
        $v = $pair[1]
        if ($v.Total -gt 0)      { $filePct = ($v.Done  * 100.0) / $v.Total }      else { $filePct = 100.0 }
        if ($v.TotalBytes -gt 0) { $bytePct = ($v.Bytes * 100.0) / $v.TotalBytes } else { $bytePct = 100.0 }
        $lines.Add($pair[0] + (Get-SideLabel $v $nameWidth))
        $lines.Add('   Files : ' + (New-Bar $filePct) + ('{0,6:N1}%' -f $filePct) + '   ' + $v.Done + ' / ' + $v.Total)
        $lines.Add('   Bytes : ' + (New-Bar $bytePct) + ('{0,6:N1}%' -f $bytePct) + '   ' + (Format-Size $v.Bytes) + ' / ' + (Format-Size $v.TotalBytes))
    }
    $lines.Add('')
    $lines.Add('  Elapsed: ' + (Format-Clock $Elapsed) + '   ETA ' + (Format-Clock $Eta) + '   Total ' + ('{0:N1}%' -f $allPct))

    Update-Block $lines.ToArray()
}

function Invoke-HashAll {
    param($SrcTree, $DstTree, $Known, $Writer, $Plan)

    $sequential = [bool]$Plan.Sequential

    $srcMap    = @{}
    $dstMap    = @{}
    $srcErrors = New-Object 'System.Collections.Generic.List[string]'
    $dstErrors = New-Object 'System.Collections.Generic.List[string]'

    $totalFiles = $SrcTree.Files.Count + $DstTree.Files.Count
    $totalBytes = [long]$SrcTree.TotalBytes + [long]$DstTree.TotalBytes

    $sides = @(
        [pscustomobject]@{ Tag = 'S'; Tree = $SrcTree; Map = $srcMap; Errors = $srcErrors },
        [pscustomobject]@{ Tag = 'T'; Tree = $DstTree; Map = $dstMap; Errors = $dstErrors }
    )

    # Split the work into "already known from the resume file" and
    # "must be read now". Each side gets its own queue.
    $queues     = @{}
    $baseFiles  = @{ 'S' = 0;       'T' = 0 }
    $baseBytes  = @{ 'S' = [long]0; 'T' = [long]0 }
    $queueFiles = @{ 'S' = 0;       'T' = 0 }
    $queueBytes = @{ 'S' = [long]0; 'T' = [long]0 }

    foreach ($side in $sides) {
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        foreach ($file in $side.Tree.Files) {
            $key = $side.Tag + '|' + $file.Rel
            $hit = $null
            if ($Known -and $Known.ContainsKey($key)) { $hit = $Known[$key] }
            if ($hit -and $hit.Size -eq $file.Size -and $hit.Mtime -eq $file.Mtime) {
                $side.Map[$file.Rel] = [pscustomobject]@{ Hash = $hit.Hash; Size = $file.Size }
                $baseFiles[$side.Tag] = $baseFiles[$side.Tag] + 1
                $baseBytes[$side.Tag] = $baseBytes[$side.Tag] + [long]$file.Size
            } else {
                $queue.Enqueue([pscustomobject]@{ Side = $side.Tag; Rel = $file.Rel; Dev = $file.Dev; Size = $file.Size; Mtime = $file.Mtime })
                $queueFiles[$side.Tag] = $queueFiles[$side.Tag] + 1
                $queueBytes[$side.Tag] = $queueBytes[$side.Tag] + [long]$file.Size
            }
        }
        $queues[$side.Tag] = $queue
    }

    $reusedFiles = $baseFiles['S'] + $baseFiles['T']
    $reusedBytes = $baseBytes['S'] + $baseBytes['T']
    $todoCount   = $queueFiles['S'] + $queueFiles['T']

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ('  HASHING   ' + $totalFiles + ' files, ' + (Format-Size $totalBytes))
    Write-Host ('  SOURCE    ' + $Plan.SourceLabel)
    Write-Host ('  TARGET    ' + $Plan.TargetLabel)
    Write-Host ('  READING   ' + $Plan.Reason)
    if ($reusedFiles -gt 0) {
        Write-Host ('  RESUMED   ' + $reusedFiles + ' files taken from the resume file, ' + (Format-Size $reusedBytes) + ' skipped') -ForegroundColor Green
    }
    Write-Host '------------------------------------------------------------'

    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($todoCount -gt 0) {

        $results = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $state   = [hashtable]::Synchronized(@{})
        foreach ($tag in @('S', 'T')) {
            $state['F' + $tag] = 0
            $state['B' + $tag] = [long]0
            $state['C' + $tag] = $null
            $state['D' + $tag] = $false
            $state['M' + $tag] = $null
            $state['E' + $tag] = 0.0
        }

        $pool = [runspacefactory]::CreateRunspacePool(1, 2)
        $pool.Open()

        $readers = @{}
        $started = @{}
        $startReader = {
            param([string]$Tag)
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            $null = $shell.AddScript($Global:ReaderScript).AddArgument($queues[$Tag]).AddArgument($results).AddArgument($state).AddArgument($Tag)
            $started[$Tag] = $watch.Elapsed.TotalSeconds
            $readers[$Tag] = [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
        }

        $drain = {
            $item = $null
            while ($results.TryDequeue([ref]$item)) {
                if ($item.Side -eq 'S') { $map = $srcMap; $errs = $srcErrors } else { $map = $dstMap; $errs = $dstErrors }

                # NTFS can, in rare cases, hold two names that differ only
                # by case. The map is case insensitive like Windows itself,
                # so flag the collision instead of silently dropping one.
                if ($map.ContainsKey($item.Rel)) {
                    $errs.Add($item.Rel + ' -> duplicate name that differs only by upper/lower case')
                }

                # A file that cannot be hashed is stored as $null and can
                # never compare equal to anything, not even to another
                # unreadable file. Storing an error message in place of
                # the hash would make two unreadable files look identical.
                $map[$item.Rel] = [pscustomobject]@{ Hash = $item.Hash; Size = $item.Size }

                if ($item.Error) { $errs.Add($item.Rel + ' -> ' + $item.Error) }

                # Only successful hashes go into the resume file.
                if ($Writer -and $item.Hash) {
                    try { $Writer.WriteLine($item.Side + '|' + $item.Size + '|' + $item.Mtime + '|' + $item.Hash + '|' + $item.Rel) } catch { }
                }
            }
        }

        # The speed shown next to each side, and the one the estimate
        # uses, is measured over the last SpeedWindow seconds, from the
        # counts the reader publishes after every 1 MiB block.
        $history = @{
            'S' = New-Object 'System.Collections.Generic.List[object]'
            'T' = New-Object 'System.Collections.Generic.List[object]'
        }
        $models = @{ 'S' = $null; 'T' = $null }
        $lastA  = @{ 'S' = 0.0;   'T' = 0.0 }

        # Everything the display and the estimate need about one side.
        $getView = {
            param([string]$Tag, $Tree, [double]$Now)

            $sessFiles = [int]$state['F' + $Tag]
            $sessBytes = [long]$state['B' + $Tag]
            $current   = $state['C' + $Tag]
            $isDone    = [bool]$state['D' + $Tag]
            $isStarted = $readers.ContainsKey($Tag)

            if ($isDone)        { $phase = 'done' }
            elseif ($isStarted) { $phase = 'run' }
            else                { $phase = 'wait' }

            $sideSecs = 0.0
            if ($isStarted) {
                if ($isDone) { $sideSecs = [double]$state['E' + $Tag] } else { $sideSecs = $Now - $started[$Tag] }
            }

            # Measuring window: from the oldest kept point, which is the
            # last one at least SpeedWindow seconds old, or the moment
            # the reader started while it has not run that long yet.
            $h = $history[$Tag]
            if ($isStarted -and -not $isDone) {
                if ($h.Count -eq 0) { $h.Add(@([double]$started[$Tag], [long]0, 0)) }
                $h.Add(@($Now, $sessBytes, $sessFiles))
                while ($h.Count -gt 2 -and ($Now - [double]$h[1][0]) -ge $Global:SpeedWindow) { $h.RemoveAt(0) }
            }

            $speed = -1.0
            if ($phase -eq 'run' -and $h.Count -ge 2) {
                $o    = $h[0]
                $span = $Now - [double]$o[0]
                $db   = $sessBytes - [long]$o[1]
                $dn   = $sessFiles - [int]$o[2]
                if ($span -ge 0.5) {
                    $speed = $db / $span

                    $a = Get-FixedCost $state['M' + $Tag]
                    if ($null -ne $a) { $lastA[$Tag] = $a } else { $a = $lastA[$Tag] }

                    if ($db -gt 0) {
                        # Take the fixed cost of the files finished in the
                        # window out of the window, the rest is reading.
                        $readTime = $span - $a * $dn
                        if ($readTime -lt (0.1 * $span)) { $a = 0.0; $readTime = $span }
                        $models[$Tag] = [pscustomobject]@{ A = $a; K = ($readTime / ($db / 1048576.0)) }
                    } elseif ($dn -gt 0) {
                        # Only empty files in the window: all the time is
                        # per file, the speed per byte stays as it was.
                        $k = $null
                        if ($models[$Tag]) { $k = $models[$Tag].K }
                        $models[$Tag] = [pscustomobject]@{ A = ($span / $dn); K = $k }
                    }
                    # Nothing moved at all (a long seek, a disk waking
                    # up): keep the last figures.
                }
            }

            $average = 0.0
            if ($isDone -and $sideSecs -gt 0.1) { $average = $sessBytes / $sideSecs }

            $filesLeft = $queueFiles[$Tag] - $sessFiles
            if ($current -and -not $isDone) { $filesLeft = $filesLeft - 1 }
            if ($filesLeft -lt 0) { $filesLeft = 0 }
            $bytesLeft = $queueBytes[$Tag] - $sessBytes
            if ($bytesLeft -lt 0) { $bytesLeft = 0 }

            return [pscustomobject]@{
                Phase      = $phase
                Current    = $current
                Done       = $baseFiles[$Tag] + $sessFiles
                Total      = $Tree.Files.Count
                Bytes      = $baseBytes[$Tag] + $sessBytes
                TotalBytes = [long]$Tree.TotalBytes
                Speed      = $speed
                Average    = $average
                SideSecs   = $sideSecs
                FilesLeft  = $filesLeft
                BytesLeft  = $bytesLeft
                Model      = $models[$Tag]
            }
        }

        $getEta = {
            param($S, $T)

            if ($S.Phase -eq 'done') { $etaS = 0.0 } else { $etaS = Get-SideSeconds $S.Model $S.FilesLeft $S.BytesLeft }

            if ($T.Phase -eq 'done') {
                $etaT = 0.0
            } else {
                $modelT = $T.Model
                # Same disk: until the target has figures of its own,
                # the source's are the best guess.
                if ($sequential -and ($null -eq $modelT -or $T.Phase -eq 'wait')) { $modelT = $S.Model }
                if ($null -eq $modelT -and $S.Phase -eq 'done' -and $T.Phase -eq 'run') { $modelT = $S.Model }
                $etaT = Get-SideSeconds $modelT $T.FilesLeft $T.BytesLeft
            }

            if ($etaS -lt 0 -or $etaT -lt 0) { return -1.0 }
            if ($sequential) { return ($etaS + $etaT) }
            return [Math]::Max($etaS, $etaT)
        }

        & $startReader 'S'
        if (-not $sequential) { & $startReader 'T' }

        Open-Block 9

        while ($true) {

            & $drain

            # Same disk: the target reader starts only once the source
            # reader has read its last file.
            if (-not $readers.ContainsKey('T') -and $state['DS']) { & $startReader 'T' }

            $now = $watch.Elapsed.TotalSeconds
            $vS  = & $getView 'S' $SrcTree $now
            $vT  = & $getView 'T' $DstTree $now
            $eta = & $getEta $vS $vT

            Show-HashProgress -Src $vS -Dst $vT -Elapsed $now -Eta $eta

            if ($readers.ContainsKey('T') -and $state['DS'] -and $state['DT'] -and $results.IsEmpty) { break }
            Start-Sleep -Milliseconds 100
        }

        & $drain

        foreach ($side in $sides) {
            $reader = $readers[$side.Tag]
            if ($null -eq $reader) { continue }
            try { $reader.Shell.EndInvoke($reader.Handle) | Out-Null }
            catch { $side.Errors.Add('reader thread failed -> ' + (Format-Reason $_)) }
            try { $reader.Shell.Dispose() } catch { }
        }
        try { $pool.Close(); $pool.Dispose() } catch { }

        $now = $watch.Elapsed.TotalSeconds
        $vS  = & $getView 'S' $SrcTree $now
        $vT  = & $getView 'T' $DstTree $now
        Show-HashProgress -Src $vS -Dst $vT -Elapsed $now -Eta 0
        Close-Block

    } else {
        Write-Host '  Everything was already in the resume file, nothing left to read.'
    }

    # If a reader thread died half way, the files it never reached are
    # not in the map. Without this they would show up as missing or as
    # extra on the other side, which points at the wrong problem. Mark
    # them as unreadable instead, so the result says what happened.
    foreach ($side in $sides) {
        foreach ($file in $side.Tree.Files) {
            if (-not $side.Map.ContainsKey($file.Rel)) {
                $side.Map[$file.Rel] = [pscustomobject]@{ Hash = $null; Size = $file.Size }
                $side.Errors.Add($file.Rel + ' -> was not read, the reader thread stopped early')
            }
        }
    }

    Write-Host ('  Finished in ' + (Format-Duration $watch.Elapsed.TotalSeconds) + '.')

    return [pscustomobject]@{
        SrcMap    = $srcMap
        DstMap    = $dstMap
        SrcErrors = $srcErrors
        DstErrors = $dstErrors
    }
}

# ------------------------------------------------------------
#  One complete verification round
# ------------------------------------------------------------

function Invoke-Round {
    param([string]$ResumePath)

    $source = $null
    $target = $null
    $known  = $null

    # --- resume file -----------------------------------------

    if ([System.IO.File]::Exists($ResumePath)) {

        $checkpoint = Read-Checkpoint $ResumePath

        if ($null -eq $checkpoint) {
            Write-Host ''
            Write-Host '[WARNING] A resume file was found but it cannot be read.' -ForegroundColor Yellow
            Write-Host '          Deleting it and starting fresh.' -ForegroundColor Yellow
            Remove-Checkpoint $ResumePath | Out-Null
        } else {
            Write-Host ''
            Write-Host '------------------------------------------------------------'
            Write-Host '  UNFINISHED VERIFICATION FOUND' -ForegroundColor Yellow
            Write-Host '------------------------------------------------------------'
            Write-Host ('  File   : ' + $ResumePath)
            Write-Host ('  Source : ' + $checkpoint.Source)
            Write-Host ('  Target : ' + $checkpoint.Target)
            Write-Host ('  Done   : ' + $checkpoint.Count + ' files already hashed')
            Write-Host ''
            Write-Host '  Y = continue that verification'
            Write-Host '  N = delete the saved progress and start a new verification'

            $continue = Read-YesNo 'Continue the unfinished verification?'

            if ($continue) {
                $srcOk = [System.IO.Directory]::Exists((ConvertTo-DevicePath $checkpoint.Source))
                $dstOk = [System.IO.Directory]::Exists((ConvertTo-DevicePath $checkpoint.Target))
                if ($srcOk -and $dstOk) {
                    $source = $checkpoint.Source
                    $target = $checkpoint.Target
                    $known  = $checkpoint.Known
                    Write-Host ''
                    Write-Host '  Continuing.' -ForegroundColor Green
                } else {
                    Write-Host ''
                    if (-not $srcOk) { Write-Host ('  [ERROR] The source folder no longer exists: ' + $checkpoint.Source) -ForegroundColor Red }
                    if (-not $dstOk) { Write-Host ('  [ERROR] The target folder no longer exists: ' + $checkpoint.Target) -ForegroundColor Red }
                    Write-Host  '  The saved progress cannot be used. Deleting it.' -ForegroundColor Yellow
                    Remove-Checkpoint $ResumePath | Out-Null
                }
            } else {
                Write-Host ''
                Write-Host '  Deleting the saved progress.' -ForegroundColor Yellow
                Remove-Checkpoint $ResumePath | Out-Null
            }
        }
    }

    # --- folders ---------------------------------------------

    if ($null -eq $source) {
        $source = Read-FolderPath 'SOURCE folder   the original:'
        $target = Read-FolderPath 'TARGET folder   the copy:'
        $known  = @{}
    }

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

    # --- scan ------------------------------------------------

    Write-Host ''
    Write-Host 'Scanning folders, please wait...'

    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $excludeDev = ConvertTo-DevicePath $ResumePath

    $srcTree = Get-FolderTree -Root $source -ExcludeDev $excludeDev
    Write-Host ('  SOURCE : ' + $srcTree.Files.Count + ' files, ' + $srcTree.Dirs.Count + ' folders, ' + (Format-Size $srcTree.TotalBytes))

    $dstTree = Get-FolderTree -Root $target -ExcludeDev $excludeDev
    Write-Host ('  TARGET : ' + $dstTree.Files.Count + ' files, ' + $dstTree.Dirs.Count + ' folders, ' + (Format-Size $dstTree.TotalBytes))

    $plan = Get-ReadPlan $source $target

    # --- hash ------------------------------------------------

    $append = ($known.Count -gt 0)
    $writer = Open-Checkpoint -Path $ResumePath -Source $source -Target $target -Append $append

    $hashed = $null
    try {
        $hashed = Invoke-HashAll -SrcTree $srcTree -DstTree $dstTree -Known $known -Writer $writer -Plan $plan
    } finally {
        if ($writer) { try { $writer.Flush(); $writer.Dispose() } catch { } }
    }

    # --- compare ---------------------------------------------

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host '  COMPARING'
    Write-Host '------------------------------------------------------------'

    $srcMap = $hashed.SrcMap
    $dstMap = $hashed.DstMap

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

    foreach ($e in $srcTree.Errors)     { $details.Add('[SCAN ERROR SOURCE]  ' + $e) }
    foreach ($e in $dstTree.Errors)     { $details.Add('[SCAN ERROR TARGET]  ' + $e) }
    foreach ($e in $hashed.SrcErrors)   { $details.Add('[READ ERROR SOURCE]  ' + $e) }
    foreach ($e in $hashed.DstErrors)   { $details.Add('[READ ERROR TARGET]  ' + $e) }

    $scanErrors = $srcTree.Errors.Count + $dstTree.Errors.Count

    $notes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $srcTree.Links) { $notes.Add('[LINK SOURCE]  ' + $l) }
    foreach ($l in $dstTree.Links) { $notes.Add('[LINK TARGET]  ' + $l) }

    $totalWatch.Stop()

    $passed = ($different -eq 0 -and $missing -eq 0 -and $extra -eq 0 -and $hashErrors -eq 0 -and $dirMissing -eq 0 -and $dirExtra -eq 0 -and $scanErrors -eq 0)

    # --- result ----------------------------------------------

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
    Write-Host ('  Total time                : {0}' -f (Format-Duration $totalWatch.Elapsed.TotalSeconds))
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

    # The verification ran to the end, so the saved progress is no
    # longer needed. This happens whether the run was a fresh one,
    # a resumed one, or one that started over after the resume file
    # was rejected.
    Write-Host ''
    if (Remove-Checkpoint $ResumePath) {
        Write-Host '  Resume file deleted, nothing is left on disk.' -ForegroundColor DarkGray
    }
}

# ============================================================
#  MAIN LOOP
#  Runs forever. The only way out is the X button of the window.
# ============================================================

$resumePath = $env:RESUMEFILE
if ([string]::IsNullOrEmpty($resumePath)) {
    $resumePath = Join-Path ([System.IO.Path]::GetDirectoryName($env:SELF)) 'verify_resume.txt'
}

Write-Host ''
Write-Host '============================================================'
Write-Host '                SHA-256 FOLDER VERIFICATION'
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
Write-Host 'Reading     : one thread per folder, every file is read from'
Write-Host '              start to end before the next one. Folders on'
Write-Host '              the same physical disk are read one after the'
Write-Host '              other, even on two different partitions.'
Write-Host ''
Write-Host 'Progress is saved to:'
Write-Host ('  ' + $resumePath)
Write-Host 'so an interrupted run can be continued. It is deleted as soon'
Write-Host 'as a verification finishes. Results are shown on screen only.'
Write-Host ''
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
        Invoke-Round -ResumePath $resumePath
    } catch {
        Write-Host ''
        Write-Host ('[UNEXPECTED ERROR] ' + (Format-Reason $_)) -ForegroundColor Red
        Write-Host '  The resume file was kept, so you can try again.' -ForegroundColor Yellow
        $Global:BlockTop = -1
    }

    Wait-AnyKey 'Press any key to start the next round, or close this window to quit.'
}
