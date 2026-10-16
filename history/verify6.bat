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
REM  Files are hashed by several worker threads at once, and
REM  progress is saved to verify_resume.txt next to this .bat,
REM  so an interrupted run can be continued.
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
#  Compiled in memory by verify.bat.
#  Windows PowerShell 3.0 or later.
# ============================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'SHA-256 Folder Verification' } catch { }

# ------------------------------------------------------------
#  SETTINGS
#
#  WorkerCount is how many files are hashed at the same time.
#  More workers help a lot on an SSD or NVMe drive, where one
#  thread cannot keep the drive busy.
#  On a MECHANICAL hard disk they hurt, because parallel reads
#  make the heads jump around. Set this to 1 or 2 if you verify
#  to or from a spinning external disk.
# ------------------------------------------------------------

# Measured on this machine: going from 1 to 4 workers cut the hashing
# time of 1.76 GiB from 1.2 s to 0.5 s, and 3000 small files from 4.0 s
# to 3.0 s. Above 4 there was no further gain in either test, and more
# threads only add contention, so 4 is the cap.
$Global:WorkerCount = [Math]::Min([Environment]::ProcessorCount, 4)
if ($Global:WorkerCount -lt 1) { $Global:WorkerCount = 1 }

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
#  Parallel hashing
#
#  Source and target files go into one queue, interleaved, so
#  that when the two folders are on two different drives both
#  drives stay busy. A pool of worker runspaces takes items off
#  the queue. The main thread only draws the progress block and
#  writes the resume file, so there is exactly one writer.
# ------------------------------------------------------------

$Global:WorkerScript = @'
param($Queue, $Results, $State, $Index)

$sha   = [System.Security.Cryptography.SHA256]::Create()
$share = ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
$item = $null
$nS = 0; $bS = [long]0
$nT = 0; $bT = [long]0

try {
    while ($Queue.TryDequeue([ref]$item)) {

        $side = $item.Side
        $State['C' + $side] = $item

        $hash = $null
        $err  = $null
        try {
            $stream = New-Object System.IO.FileStream($item.Dev, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share, 1048576, [System.IO.FileOptions]::SequentialScan)
            try { $raw = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
            $hash = [System.BitConverter]::ToString($raw).Replace('-', '')
        } catch {
            $err = $_.Exception.Message
            if ($_.Exception.InnerException) { $err = $_.Exception.InnerException.Message }
            $err = $err.Replace('\\?\UNC\', '\\').Replace('\\?\', '')
        }

        $Results.Enqueue([pscustomobject]@{
            Side  = $side
            Rel   = $item.Rel
            Size  = $item.Size
            Mtime = $item.Mtime
            Hash  = $hash
            Error = $err
        })

        if ($side -eq 'S') {
            $nS = $nS + 1
            $bS = $bS + $item.Size
            $State['FS' + $Index] = $nS
            $State['BS' + $Index] = $bS
        } else {
            $nT = $nT + 1
            $bT = $bT + $item.Size
            $State['FT' + $Index] = $nT
            $State['BT' + $Index] = $bT
        }
    }
} finally {
    try { $sha.Dispose() } catch { }
    $State['D' + $Index] = $true
}
'@

function Show-HashProgress {
    param(
        $SrcCurrent, $DstCurrent,
        [int]$SrcDone, [int]$SrcTotal, [long]$SrcBytes, [long]$SrcTotalBytes,
        [int]$DstDone, [int]$DstTotal, [long]$DstBytes, [long]$DstTotalBytes,
        [double]$Elapsed, [long]$SessionBytes
    )

    $allDone  = [long]$SrcBytes + [long]$DstBytes
    $allTotal = [long]$SrcTotalBytes + [long]$DstTotalBytes

    if ($SrcTotal -gt 0)      { $srcFilePct = ($SrcDone  * 100.0) / $SrcTotal }      else { $srcFilePct = 100.0 }
    if ($SrcTotalBytes -gt 0) { $srcBytePct = ($SrcBytes * 100.0) / $SrcTotalBytes } else { $srcBytePct = 100.0 }
    if ($DstTotal -gt 0)      { $dstFilePct = ($DstDone  * 100.0) / $DstTotal }      else { $dstFilePct = 100.0 }
    if ($DstTotalBytes -gt 0) { $dstBytePct = ($DstBytes * 100.0) / $DstTotalBytes } else { $dstBytePct = 100.0 }
    if ($allTotal -gt 0)      { $allPct     = ($allDone  * 100.0) / $allTotal }      else { $allPct     = 100.0 }

    if ($Elapsed -gt 0.5) { $speed = $SessionBytes / $Elapsed } else { $speed = 0 }
    if ($speed -gt 0 -and $allTotal -gt $allDone) {
        $eta = ($allTotal - $allDone) / $speed
    } else {
        $eta = 0
    }

    $nameWidth = 46
    try { $nameWidth = [Console]::BufferWidth - 26 } catch { }
    if ($nameWidth -lt 20) { $nameWidth = 20 }

    # A side has no current file either before a worker has picked one
    # up, or after that side is finished. Say which, instead of leaving
    # the line blank as if something went wrong.
    $sName = ''
    $sSize = ''
    if ($SrcCurrent) {
        $sName = Format-Fit $SrcCurrent.Rel $nameWidth
        $sSize = Format-Size $SrcCurrent.Size
    } elseif ($SrcDone -ge $SrcTotal) { $sName = '(done)' } else { $sName = '(starting)' }

    $tName = ''
    $tSize = ''
    if ($DstCurrent) {
        $tName = Format-Fit $DstCurrent.Rel $nameWidth
        $tSize = Format-Size $DstCurrent.Size
    } elseif ($DstDone -ge $DstTotal) { $tName = '(done)' } else { $tName = '(starting)' }

    # Both folders are hashed at the same time and they rarely run at
    # the same speed, because they usually sit on different drives.
    # Each side therefore gets its own pair of bars, so a slow side is
    # obvious at a glance. The overall figure is on the last line.
    $lines = @(
        ('  SOURCE : ' + $sName + '   ' + $sSize),
        ('   Files : ' + (New-Bar $srcFilePct) + ('{0,6:N1}%' -f $srcFilePct) + '   ' + $SrcDone + ' / ' + $SrcTotal),
        ('   Bytes : ' + (New-Bar $srcBytePct) + ('{0,6:N1}%' -f $srcBytePct) + '   ' + (Format-Size $SrcBytes) + ' / ' + (Format-Size $SrcTotalBytes)),
        ('  TARGET : ' + $tName + '   ' + $tSize),
        ('   Files : ' + (New-Bar $dstFilePct) + ('{0,6:N1}%' -f $dstFilePct) + '   ' + $DstDone + ' / ' + $DstTotal),
        ('   Bytes : ' + (New-Bar $dstBytePct) + ('{0,6:N1}%' -f $dstBytePct) + '   ' + (Format-Size $DstBytes) + ' / ' + (Format-Size $DstTotalBytes)),
        ('  Elapsed: ' + (Format-Clock $Elapsed) + '   ETA ' + (Format-Clock $eta) + '   ' + (Format-Size ([long]$speed)) + '/s   Total ' + ('{0:N1}%' -f $allPct))
    )
    Update-Block $lines
}

function Invoke-HashAll {
    param($SrcTree, $DstTree, $Known, $Writer)

    $srcMap    = @{}
    $dstMap    = @{}
    $srcErrors = New-Object 'System.Collections.Generic.List[string]'
    $dstErrors = New-Object 'System.Collections.Generic.List[string]'

    $totalFiles = $SrcTree.Files.Count + $DstTree.Files.Count
    $totalBytes = [long]$SrcTree.TotalBytes + [long]$DstTree.TotalBytes

    # Split the work into "already known from the resume file" and
    # "must be hashed now".
    $todo       = New-Object 'System.Collections.Generic.List[object]'
    $baseFiles  = 0
    $baseBytes  = [long]0
    $baseFilesS = 0
    $baseBytesS = [long]0
    $baseFilesT = 0
    $baseBytesT = [long]0
    $reusedSrc  = 0
    $reusedDst  = 0

    $sides = @(
        [pscustomobject]@{ Tag = 'S'; Tree = $SrcTree; Map = $srcMap },
        [pscustomobject]@{ Tag = 'T'; Tree = $DstTree; Map = $dstMap }
    )

    $pending = @{}
    foreach ($side in $sides) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in $side.Tree.Files) {
            $key  = $side.Tag + '|' + $file.Rel
            $hit  = $null
            if ($Known -and $Known.ContainsKey($key)) { $hit = $Known[$key] }
            if ($hit -and $hit.Size -eq $file.Size -and $hit.Mtime -eq $file.Mtime) {
                $side.Map[$file.Rel] = [pscustomobject]@{ Hash = $hit.Hash; Size = $file.Size }
                $baseFiles = $baseFiles + 1
                $baseBytes = $baseBytes + [long]$file.Size
                if ($side.Tag -eq 'S') {
                    $reusedSrc  = $reusedSrc + 1
                    $baseFilesS = $baseFilesS + 1
                    $baseBytesS = $baseBytesS + [long]$file.Size
                } else {
                    $reusedDst  = $reusedDst + 1
                    $baseFilesT = $baseFilesT + 1
                    $baseBytesT = $baseBytesT + [long]$file.Size
                }
            } else {
                $list.Add([pscustomobject]@{ Side = $side.Tag; Rel = $file.Rel; Dev = $file.Dev; Size = $file.Size; Mtime = $file.Mtime })
            }
        }
        $pending[$side.Tag] = $list
    }

    # Interleave the two sides so both drives are used at once.
    $sList = $pending['S']
    $tList = $pending['T']
    $maxLen = [Math]::Max($sList.Count, $tList.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        if ($i -lt $sList.Count) { $todo.Add($sList[$i]) }
        if ($i -lt $tList.Count) { $todo.Add($tList[$i]) }
    }

    $workers = [Math]::Min($Global:WorkerCount, [Math]::Max($todo.Count, 1))

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ('  HASHING   ' + $totalFiles + ' files, ' + (Format-Size $totalBytes) + '   (' + $workers + ' workers)')
    if (($reusedSrc + $reusedDst) -gt 0) {
        Write-Host ('  RESUMED   ' + ($reusedSrc + $reusedDst) + ' files taken from the resume file, ' + (Format-Size $baseBytes) + ' skipped') -ForegroundColor Green
    }
    Write-Host '------------------------------------------------------------'

    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($todo.Count -gt 0) {

        $queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $results = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $state   = [hashtable]::Synchronized(@{})

        foreach ($entry in $todo) { $queue.Enqueue($entry) }
        for ($i = 0; $i -lt $workers; $i++) {
            $state['FS' + $i] = 0
            $state['BS' + $i] = [long]0
            $state['FT' + $i] = 0
            $state['BT' + $i] = [long]0
            $state['D'  + $i] = $false
        }

        $pool = [runspacefactory]::CreateRunspacePool(1, $workers)
        $pool.Open()

        $shells  = New-Object 'System.Collections.Generic.List[object]'
        $handles = New-Object 'System.Collections.Generic.List[object]'

        for ($i = 0; $i -lt $workers; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            $null = $shell.AddScript($Global:WorkerScript).AddArgument($queue).AddArgument($results).AddArgument($state).AddArgument($i)
            $shells.Add($shell)
            $handles.Add($shell.BeginInvoke())
        }

        Open-Block 7

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

        while ($true) {

            & $drain

            $doneS    = $baseFilesS
            $byteS    = $baseBytesS
            $doneT    = $baseFilesT
            $byteT    = $baseBytesT
            $finished = $true
            for ($i = 0; $i -lt $workers; $i++) {
                $doneS = $doneS + [int]$state['FS' + $i]
                $byteS = $byteS + [long]$state['BS' + $i]
                $doneT = $doneT + [int]$state['FT' + $i]
                $byteT = $byteT + [long]$state['BT' + $i]
                if (-not $state['D' + $i]) { $finished = $false }
            }
            $sessBytes = ($byteS - $baseBytesS) + ($byteT - $baseBytesT)

            Show-HashProgress -SrcCurrent $state['CS'] -DstCurrent $state['CT'] -SrcDone $doneS -SrcTotal $SrcTree.Files.Count -SrcBytes $byteS -SrcTotalBytes $SrcTree.TotalBytes -DstDone $doneT -DstTotal $DstTree.Files.Count -DstBytes $byteT -DstTotalBytes $DstTree.TotalBytes -Elapsed $watch.Elapsed.TotalSeconds -SessionBytes $sessBytes

            if ($finished -and $results.IsEmpty) { break }
            Start-Sleep -Milliseconds 70
        }

        & $drain

        for ($i = 0; $i -lt $workers; $i++) {
            try { $shells[$i].EndInvoke($handles[$i]) | Out-Null }
            catch {
                $srcErrors.Add('worker thread failed -> ' + (Format-Reason $_))
            }
            try { $shells[$i].Dispose() } catch { }
        }
        try { $pool.Close(); $pool.Dispose() } catch { }

        Show-HashProgress -SrcCurrent $state['CS'] -DstCurrent $state['CT'] -SrcDone $SrcTree.Files.Count -SrcTotal $SrcTree.Files.Count -SrcBytes $SrcTree.TotalBytes -SrcTotalBytes $SrcTree.TotalBytes -DstDone $DstTree.Files.Count -DstTotal $DstTree.Files.Count -DstBytes $DstTree.TotalBytes -DstTotalBytes $DstTree.TotalBytes -Elapsed $watch.Elapsed.TotalSeconds -SessionBytes ($totalBytes - $baseBytes)
        Close-Block

    } else {
        Write-Host '  Everything was already in the resume file, nothing left to hash.'
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

    # --- hash ------------------------------------------------

    $append = ($known.Count -gt 0)
    $writer = Open-Checkpoint -Path $ResumePath -Source $source -Target $target -Append $append

    $hashed = $null
    try {
        $hashed = Invoke-HashAll -SrcTree $srcTree -DstTree $dstTree -Known $known -Writer $writer
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
Write-Host ('Workers     : ' + $Global:WorkerCount + '  (set WorkerCount to 1 or 2 near the top of')
Write-Host '              the .bat if you verify a mechanical hard disk)'
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
