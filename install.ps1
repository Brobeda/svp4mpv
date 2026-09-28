#Requires -Version 5.1
<#
.SYNOPSIS
    svp4mpv interactive installer.
.PARAMETER NoPause
    Do not wait for Enter at the end (used by the install.bat launcher).
#>
[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # much faster Invoke-WebRequest on Windows PowerShell 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'svp4mpv Universal Auto-Installer' } catch {}

# ------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------
$RepoUrl      = 'https://github.com/xrun1/svp4mpv/archive/refs/heads/master.zip'
$VsScriptUrl  = 'https://github.com/vapoursynth/vapoursynth/releases/download/R72/Install-Portable-VapourSynth-R72.ps1'
$HwdecLine    = 'hwdec=d3d11va-copy'
$SvpBinding   = 'Alt+Shift+s script-binding svp4mpv/svp-menu'
$UoscButton   = 'command:slow_motion_video:script-binding svp4mpv/svp-menu?SVP'
$SvpMarker    = 'svp4mpv/svp-menu'
# uosc's stock layout, used only if uosc.conf has no controls= line yet
$UoscDefaultControls = 'menu,gap,<video,audio>subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,gap,space,<video,audio>speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
function Write-Banner([string]$Text) {
    $line = '=' * 52
    Write-Host $line
    Write-Host " $Text"
    Write-Host $line
}

function Write-Step([string]$Text) { Write-Host $Text -ForegroundColor Cyan }

function Read-Choice([string]$Prompt, [string[]]$Valid) {
    while ($true) {
        $r = (Read-Host $Prompt).Trim()
        if ($Valid -contains $r) { return $r }
        Write-Host 'Invalid choice, try again.'
        Write-Host
    }
}

function Read-YesNo([string]$Prompt, [bool]$DefaultYes = $true) {
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $r = (Read-Host "$Prompt [$hint]").Trim().ToLower()
        if ($r -eq '') { return $DefaultYes }
        if ($r -in 'y', 'yes') { return $true }
        if ($r -in 'n', 'no')  { return $false }
        Write-Host 'Please answer y or n.'
    }
}

# Copies a directory tree. -OnlyMissing: never overwrite. -KeepExistingExt: don't overwrite existing files with these extensions.
function Copy-Tree {
    param([string]$Source, [string]$Destination, [switch]$OnlyMissing, [string[]]$KeepExistingExt = @())
    $src = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
    Get-ChildItem -LiteralPath $src -Recurse -File -Force | ForEach-Object {
        $rel  = $_.FullName.Substring($src.Length).TrimStart('\')
        $dest = Join-Path $Destination $rel
        if (Test-Path -LiteralPath $dest) {
            if ($OnlyMissing) { return }
            if ($KeepExistingExt -contains $_.Extension) { Write-Host "  Keeping existing $rel"; return }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-Config([string]$Path, [string]$Prefix) {
    $name = '{0}_bak_{1}.conf' -f $Prefix, $script:Timestamp
    Copy-Item -LiteralPath $Path -Destination (Join-Path $BaseConfigDir $name) -Force
    Write-Host "  Created backup: $name"
}

# Appends a line, keeping the file's existing newline style
function Add-LineToText([string]$Text, [string]$Line) {
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
    $trimmed = $Text.TrimEnd()
    if ($trimmed.Length -eq 0) { return $Line + $nl }
    return $trimmed + $nl + $Line + $nl
}

# Creates the file, or replaces every line matching $Pattern, or appends $Line if nothing matches.
# Makes a timestamped backup only when the file actually changes.
function Update-ConfigLine {
    param([string]$Path, [string]$Pattern, [string]$Line, [string]$BackupPrefix)
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Utf8 $Path ($Line + [Environment]::NewLine)
        Write-Host "  Created $leaf"
        return
    }
    $content = [IO.File]::ReadAllText($Path)
    $rx = [regex]::new($Pattern, 'Multiline, IgnoreCase')
    if ($rx.IsMatch($content)) {
        $new = $rx.Replace($content, $Line.Replace('$', '$$'))
    } else {
        $new = Add-LineToText $content $Line
    }
    if ($new -ceq $content) { Write-Host "  $leaf already up to date."; return }
    Backup-Config $Path $BackupPrefix
    Write-Utf8 $Path $new
    Write-Host "  Updated $leaf"
}

# Inserts the SVP button into a uosc "controls=" value, wherever the user's layout allows.
# Preferred spot: in front of the speed control (and the "space" just before it), which turns
#   ...,gap,space,<video,audio>speed,...  into  ...,gap,<SVP button>,gap,space,<video,audio>speed,...
# Fallbacks: before the first "space", otherwise at the end.
function Add-SvpToUoscControls([string]$Controls) {
    # split on commas that are not inside <...> conditions such as <video,audio>
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($t in [regex]::Split($Controls.Trim(), ',(?![^<>]*>)')) { $items.Add($t) }

    $at = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Trim() -match '^(<[^>]*>)?speed(:.*)?$') { $at = $i; break }
    }
    if ($at -ge 0) {
        if ($at -gt 0 -and $items[$at - 1].Trim() -eq 'space') { $at-- }
    } else {
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($items[$i].Trim() -eq 'space') { $at = $i; break }
        }
        if ($at -lt 0) { $at = $items.Count }
    }

    $ins = @()
    if ($at -gt 0 -and $items[$at - 1].Trim() -ne 'gap') { $ins += 'gap' }
    $ins += $UoscButton
    if ($at -lt $items.Count -and $items[$at].Trim() -ne 'gap') { $ins += 'gap' }
    $items.InsertRange($at, [string[]]$ins)
    return ($items -join ',')
}

function Update-UoscConf {
    $optsDir = Join-Path $BaseConfigDir 'script-opts'
    $path    = Join-Path $optsDir 'uosc.conf'

    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Force -Path $optsDir | Out-Null
        Write-Utf8 $path ('controls=' + (Add-SvpToUoscControls $UoscDefaultControls) + [Environment]::NewLine)
        Write-Host '  uosc.conf not found: created it with the default uosc layout plus the SVP button.'
        return
    }

    $content = [IO.File]::ReadAllText($path)
    $rx    = [regex]::new('^([ \t]*controls[ \t]*=[ \t]*)([^\r\n]*)$', 'Multiline, IgnoreCase')
    $found = $rx.Matches($content)

    if ($found.Count -gt 0) {
        $g       = $found[$found.Count - 1].Groups[2]     # last definition wins in mpv
        $current = $g.Value.Trim()
        if ($current.Contains($SvpMarker)) { Write-Host '  uosc controls already contain the SVP button.'; return }
        if ($current -eq '') { Write-Host '  controls= is empty in uosc.conf, leaving it untouched.'; return }
        $new = $content.Substring(0, $g.Index) + (Add-SvpToUoscControls $current) + $content.Substring($g.Index + $g.Length)
    } else {
        # no controls= line: uosc is using its defaults, so write those plus the button
        $new = Add-LineToText $content ('controls=' + (Add-SvpToUoscControls $UoscDefaultControls))
    }

    Backup-Config $path 'uosc'
    Write-Utf8 $path $new
    Write-Host '  Added the SVP button to uosc controls.'
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
$exitCode = 0
$TempDir  = Join-Path $env:TEMP 'svp4mpv_install'

try {
    Write-Banner 'svp4mpv Interactive Setup Script'
    Write-Host

    # ---- Step 1: player ----
    Write-Step '[1/4] Select your media player flavor:'
    Write-Host '  1) Standard MPV (mpv)'
    Write-Host '  2) MPV.NET (mpv.net)'
    $PlayerName = if ((Read-Choice 'Enter choice (1-2)' @('1', '2')) -eq '1') { 'mpv' } else { 'mpv.net' }
    Write-Host "Selected Player: $PlayerName"
    Write-Host

    # ---- Step 2: config location ----
    Write-Step '[2/4] Choose your configuration type:'
    Write-Host "  1) Standard System-wide (%APPDATA%\$PlayerName\)"
    Write-Host "  2) Local Portable Mode (inside an adjacent 'portable_config' folder)"
    if ((Read-Choice 'Enter choice (1-2)' @('1', '2')) -eq '1') {
        $BaseConfigDir = Join-Path $env:APPDATA $PlayerName
    } else {
        $candidates = @((Join-Path $ScriptDir '..\..\portable_config'), (Join-Path $ScriptDir '..\portable_config'))
        $existing = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($existing) { $BaseConfigDir = [IO.Path]::GetFullPath($existing) }
        else           { $BaseConfigDir = Join-Path $ScriptDir 'portable_config' }
    }
    Write-Host "Target Configuration Root: $BaseConfigDir"
    Write-Host

    $ScriptsDir        = Join-Path $BaseConfigDir 'scripts'
    $ScriptFolder      = Join-Path $ScriptsDir 'svp4mpv'
    $LegacyFolder      = Join-Path $ScriptsDir 'svp4mpv-master'
    $PortableVsFolder  = Join-Path $ScriptFolder 'vapoursynth'
    $UoscDir           = Join-Path $ScriptsDir 'uosc'

    # ---- Step 3: VapourSynth ----
    Write-Step '[3/4] VapourSynth Deployment Option:'
    Write-Host '  1) Download and configure localized VapourSynth R72 automatically'
    Write-Host '  2) Skip (I already have VapourSynth R72 installed on system PATH or root)'
    $RunVsInstall = (Read-Choice 'Enter choice (1-2)' @('1', '2')) -eq '1'
    Write-Host

    # ---- Step 4: optional uosc button ----
    $AddUoscButton = $false
    if (Test-Path -LiteralPath $UoscDir) {
        Write-Step '[4/4] uosc detected.'
        $AddUoscButton = Read-YesNo 'Add an SVP button to the uosc control bar?' $true
    } else {
        Write-Step '[4/4] uosc not found, skipping the optional uosc button.'
    }
    Write-Host

    # ---- Legacy folder check: scripts\svp4mpv-master ----
    if (Test-Path -LiteralPath $LegacyFolder) {
        $legacyDone = $false
        while (-not $legacyDone) {
            Write-Banner 'Existing installation found:'
            Write-Host " $LegacyFolder"
            Write-Host
            Write-Host ' This is the folder name used by the main branch.'
            Write-Host ' This fork uses "svp4mpv" instead. Having both would make'
            Write-Host ' mpv load the script twice, so please choose:'
            Write-Host
            Write-Host '  1) Rename to "svp4mpv" and update in place (keeps your .conf files)'
            Write-Host '  2) Delete the old folder (WARNING: removes all its files and settings)'
            Write-Host '  3) Leave it alone (not recommended)'
            $choice = Read-Choice 'Enter choice (1-3)' @('1', '2', '3')

            switch ($choice) {
                '1' {
                    try {
                        if (Test-Path -LiteralPath $ScriptFolder) {
                            Write-Host 'A "svp4mpv" folder already exists. Merging missing files from svp4mpv-master...'
                            Copy-Tree -Source $LegacyFolder -Destination $ScriptFolder -OnlyMissing
                            Remove-Item -LiteralPath $LegacyFolder -Recurse -Force
                            Write-Host 'Merged and removed svp4mpv-master.'
                        } else {
                            Rename-Item -LiteralPath $LegacyFolder -NewName 'svp4mpv'
                            Write-Host 'Renamed svp4mpv-master to svp4mpv. Existing files will be kept.'
                        }
                    } catch {
                        throw "Could not rename/merge the folder. Is mpv currently running? Close it and re-run the installer. ($($_.Exception.Message))"
                    }
                    $legacyDone = $true
                }
                '2' {
                    Write-Host
                    Write-Host 'WARNING: This will PERMANENTLY delete:' -ForegroundColor Yellow
                    Write-Host "  $LegacyFolder" -ForegroundColor Yellow
                    Write-Host 'All files inside, including your configuration files, will be lost.' -ForegroundColor Yellow
                    $confirm = Read-Host 'Type YES to confirm deletion, anything else to go back'
                    if ($confirm.Trim() -ieq 'YES') {
                        try {
                            Remove-Item -LiteralPath $LegacyFolder -Recurse -Force
                        } catch {
                            throw "Could not delete the folder. Is mpv currently running? Close it and re-run the installer. ($($_.Exception.Message))"
                        }
                        Write-Host 'Deleted svp4mpv-master.'
                        $legacyDone = $true
                    } else {
                        Write-Host 'Deletion cancelled.'
                    }
                }
                '3' {
                    Write-Host 'Leaving svp4mpv-master in place. Remember to remove or disable it later.'
                    $legacyDone = $true
                }
            }
            Write-Host
        }
    }

    # ==================================================================
    # EXECUTION PHASE
    # ==================================================================
    Write-Banner 'Executing Installation Plan...'
    $script:Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    if (Test-Path -LiteralPath $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $BaseConfigDir, $ScriptFolder, $TempDir | Out-Null

    # ---- [1/5] Script files ----
    Write-Step '[1/5] Downloading latest repository archive (master branch)...'
    $zip     = Join-Path $TempDir 'repo.zip'
    $extract = Join-Path $TempDir 'repo'
    Invoke-WebRequest -Uri $RepoUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $srcRoot = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $srcRoot) { throw 'The downloaded archive was empty or had an unexpected layout.' }
    Copy-Tree -Source $srcRoot.FullName -Destination $ScriptFolder -KeepExistingExt '.conf'

    # ---- [2/5] VapourSynth ----
    if ($RunVsInstall) {
        Write-Step "[2/5] Downloading and installing portable VapourSynth R72 into $PortableVsFolder..."
        $vsScript = Join-Path $TempDir 'Install-VS.ps1'
        Invoke-WebRequest -Uri $VsScriptUrl -OutFile $vsScript -UseBasicParsing
        $psExe = (Get-Process -Id $PID).Path
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $vsScript -VSVersion 72 -TargetFolder $PortableVsFolder -PythonVersionMajor 3 -PythonVersionMinor 13 -Unattended
        if ($LASTEXITCODE -ne 0) { throw "The VapourSynth installer failed (exit code $LASTEXITCODE)." }
    } else {
        Write-Step '[2/5] Skipping VapourSynth download per request.'
    }

    # ---- [3/5] mpv.conf ----
    Write-Step '[3/5] Checking hardware acceleration in mpv.conf...'
    Update-ConfigLine -Path (Join-Path $BaseConfigDir 'mpv.conf') `
                      -Pattern '^[ \t]*hwdec[ \t]*=[^\r\n]*$' -Line $HwdecLine -BackupPrefix 'mpv'

    # ---- [4/5] input.conf ----
    Write-Step '[4/5] Checking svp4mpv menu keybinding in input.conf...'
    Update-ConfigLine -Path (Join-Path $BaseConfigDir 'input.conf') `
                      -Pattern '^[ \t]*Alt\+Shift\+s[ \t]+[^\r\n]*$' -Line $SvpBinding -BackupPrefix 'input'

    # ---- [5/5] uosc button ----
    if ($AddUoscButton) {
        Write-Step '[5/5] Adding the SVP button to uosc...'
        Update-UoscConf
    } else {
        Write-Step '[5/5] Skipping uosc button.'
    }

    Write-Host
    Write-Banner 'SUCCESS! Installation complete.'
    Write-Host " Target Script Location: $ScriptFolder"
}
catch {
    Write-Host
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($TempDir -and (Test-Path -LiteralPath $TempDir)) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host
if (-not $NoPause) { Read-Host 'Press Enter to exit' | Out-Null }
exit $exitCode
