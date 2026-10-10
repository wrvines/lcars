# =============================================================================
# LCARS uninstaller for Windows (Windows Terminal + PowerShell)
# =============================================================================
# Self-contained on purpose: the installer copies it to
#   %LOCALAPPDATA%\lcars\uninstall.ps1
# so it still works after the repository is deleted or moved.
#
# It does NOT need the install manifest. Without it, it scans the known
# locations for the `# >>> lcars >>>` marker and removes the files the theme
# owns. With the manifest it also restores your Windows Terminal settings.json
# and PowerShell profile backups.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install\uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\lcars\uninstall.ps1"
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Purge,
    [switch]$Restore,
    [string]$RestoreStamp = '',
    [string]$LcarsDir,
    [string]$SettingsPath,
    [string]$ProfilePath,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$MarkStart = '# >>> lcars >>>'
$MarkEnd = '# <<< lcars <<<'
$SchemeName = 'LCARS'
$ProfileName = 'LCARS'
$ProfileGuid = '{7c1a2f5e-47b4-4c1a-9e3d-4c4152533031}'
$ManifestName = '.lcars-install.json'
$Script:Leftovers = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$Text) { Write-Host "`n== $Text" }
function Write-Info([string]$Text) { Write-Host "   $Text" }
function Write-Warn2([string]$Text) { Write-Warning "   $Text" }
function Write-Fail([string]$Text) {
    Write-Host "`nERROR: $Text" -ForegroundColor Red
    exit 1
}
function Confirm-Action([string]$Text) {
    if ($Yes) { return $true }
    $reply = Read-Host "   $Text [y/N]"
    return ($reply -match '^(y|yes)$')
}
function Invoke-Dry([scriptblock]$Action, [string]$Description) {
    if ($DryRun) { Write-Host "   [dry-run] $Description" } else { & $Action }
}

function Show-Usage {
    @"
LCARS uninstaller for Windows

usage: powershell -ExecutionPolicy Bypass -File install\uninstall.ps1 [options]
       powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\lcars\uninstall.ps1"

options:
  -DryRun            show what would change; change nothing
  -Yes               assume yes for prompts
  -Purge             also delete backups and the LCARS directory
  -Restore           restore files from the latest backup
  -RestoreStamp TS   restore from a specific backup stamp (YYYYmmdd-HHmmss)
  -LcarsDir PATH     LCARS install directory   (default: %LOCALAPPDATA%\lcars)
  -SettingsPath PATH override Windows Terminal settings.json
  -ProfilePath PATH  override PowerShell profile
  -Help              this help
"@
}

if ($Help) { Show-Usage; exit 0 }

# --- path discovery ----------------------------------------------------------

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LcarsDir -or $LcarsDir -eq '') {
    # The shipped copy at <LCARS_DIR>\uninstall.ps1 can identify its own
    # directory from the LCARS layout, even when the manifest is gone.
    $looksLikeInstall = (Test-Path (Join-Path $Here $ManifestName)) -or
        (Test-Path (Join-Path $Here 'profile.ps1')) -or
        (Test-Path (Join-Path $Here 'starship.toml')) -or
        (Test-Path (Join-Path $Here 'assets'))
    if ($looksLikeInstall) {
        $LcarsDir = $Here
    } else {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = Join-Path $HOME '.local\share' }
        $LcarsDir = Join-Path $base 'lcars'
    }
}
$ManifestPath = Join-Path $LcarsDir $ManifestName

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Set-PropertyValue($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Remove-JsonComments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); continue }
        if ($ch -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i++
            continue
        }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

function Read-JsonFile([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    return (Remove-JsonComments $raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 32
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Read-Manifest {
    if (Test-Path $ManifestPath) {
        return (Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json)
    }
    return $null
}

function Get-WtSettingsPath {
    if ($SettingsPath) { return $SettingsPath }
    if ($env:LCARS_WT_SETTINGS) { return $env:LCARS_WT_SETTINGS }
    if (-not $env:LOCALAPPDATA) { return $null }
    $candidates = @()
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $packages) {
        $candidates += Get-ChildItem -Path $packages -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.WindowsTerminal*' } |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }
    }
    $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal Preview\settings.json'
    $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal Canary\settings.json'
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Get-PsProfilePath {
    if ($ProfilePath) { return $ProfilePath }
    if ($PROFILE.CurrentUserCurrentHost) { return $PROFILE.CurrentUserCurrentHost }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return (Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
    }
    return (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
}

# --- marked block removal ----------------------------------------------------

function Remove-MarkedBlock([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.IndexOf($MarkStart) -lt 0) {
        if ($text -match 'lcars' -or $text -match 'LCARS_DIR') {
            Write-Warn2 "marker not found in $Path, but it still references LCARS"
            $Script:Leftovers.Add($Path)
        }
        return
    }
    if ($DryRun) {
        Write-Host "   [dry-run] remove LCARS block from $Path"
        return
    }
    $pattern = "(?ms)^\s*" + [regex]::Escape($MarkStart) + ".*?" + [regex]::Escape($MarkEnd) + "\s*"
    $updated = [regex]::Replace($text, $pattern, '')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $updated, $utf8)
    Write-Info "cleaned $Path"
}

# --- known files -------------------------------------------------------------

function Get-KnownRelativePaths {
    @(
        'starship.toml',
        'fastfetch.jsonc',
        'profile.ps1',
        'tmux.conf',
        'uninstall.ps1'
    )
}

function Remove-KnownFiles {
    foreach ($rel in Get-KnownRelativePaths) {
        $path = Join-Path $LcarsDir $rel
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Invoke-Dry { Remove-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue } "rm $path"
        }
    }
    foreach ($sub in @('sounds', 'assets')) {
        $dir = Join-Path $LcarsDir $sub
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Invoke-Dry { Remove-Item -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue } "rm $($_.FullName)"
            }
        }
    }
}

function Remove-ManifestFiles($Manifest) {
    foreach ($path in @(Get-PropertyValue $Manifest 'created' @())) {
        if (-not $path) { continue }
        if (-not $path.StartsWith($LcarsDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and
                -not ((Get-Content -Raw -LiteralPath $path -ErrorAction SilentlyContinue) -match '\S')) {
                Invoke-Dry { Remove-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue } "rm $path"
            }
            continue
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Invoke-Dry { Remove-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue } "rm $path"
        }
    }
    # remove now-empty directories, deepest first
    if ((Test-Path $LcarsDir) -and -not $DryRun) {
        $dirs = Get-ChildItem -Path $LcarsDir -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\backups*' } |
            Sort-Object { $_.FullName.Length } -Descending
        foreach ($dir in $dirs) {
            if (-not (Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# --- Windows Terminal cleanup ------------------------------------------------

function Remove-WtTheme($Manifest) {
    $wtPath = $null
    $scheme = $SchemeName
    $guid = $ProfileGuid
    $changedDefault = $false
    $prevDefault = $null

    if ($Manifest) {
        $patch = Get-PropertyValue $Manifest 'json_patch' $null
        if ($patch) {
            $wtPath = Get-PropertyValue $patch 'settings_path' $null
            $scheme = Get-PropertyValue $patch 'scheme' $SchemeName
            $guid = Get-PropertyValue $patch 'profile_guid' $ProfileGuid
            $changedDefault = [bool](Get-PropertyValue $patch 'changed_default' $false)
            $prevDefault = Get-PropertyValue $patch 'prev_default' $null
        }
    }
    if (-not $wtPath) { $wtPath = Get-WtSettingsPath }
    if (-not $wtPath -or -not (Test-Path $wtPath)) { return }

    Write-Step "Windows Terminal cleanup"
    Write-Info $wtPath
    $settings = Read-JsonFile $wtPath
    if ($DryRun) {
        Write-Host "   [dry-run] remove scheme '$scheme' and profile '$guid' from $wtPath"
        return
    }

    $schemes = @(Get-PropertyValue $settings 'schemes' @()) |
        Where-Object { (Get-PropertyValue $_ 'name' '') -ne $scheme }
    Set-PropertyValue $settings 'schemes' @($schemes)

    $profilesNode = Get-PropertyValue $settings 'profiles' $null
    $remaining = @()
    if ($profilesNode) {
        $list = @(Get-PropertyValue $profilesNode 'list' @())
        $remaining = @($list | Where-Object {
            (Get-PropertyValue $_ 'guid' '') -ne $guid -and
            (Get-PropertyValue $_ 'name' '') -ne $ProfileName
        })
        Set-PropertyValue $profilesNode 'list' $remaining
    }

    $currentDefault = Get-PropertyValue $settings 'defaultProfile' $null
    if ($changedDefault -and $currentDefault -eq $guid) {
        if ($prevDefault) {
            Set-PropertyValue $settings 'defaultProfile' $prevDefault
            Write-Info "default profile restored"
        } else {
            $fallback = $remaining | Where-Object { Get-PropertyValue $_ 'guid' $null } | Select-Object -First 1
            if ($fallback) {
                Set-PropertyValue $settings 'defaultProfile' (Get-PropertyValue $fallback 'guid' $null)
                Write-Info "default profile reset to '$(Get-PropertyValue $fallback 'name' 'unnamed')'"
            } else {
                Set-PropertyValue $settings 'defaultProfile' $null
            }
        }
    }
    Write-JsonFile $wtPath $settings
    Write-Info "removed scheme '$scheme' and profile '$ProfileName'"
}

# --- restore -----------------------------------------------------------------

function Restore-Lcars([string]$Stamp) {
    $manifest = Read-Manifest
    if (-not $manifest) { Write-Fail "no manifest found at $ManifestPath" }

    $dir = $null
    if ($Stamp) {
        $dir = Join-Path (Join-Path $LcarsDir 'backups') $Stamp
        if (-not (Test-Path $dir)) { Write-Fail "backup directory not found: $dir" }
    } else {
        $dir = Get-PropertyValue $manifest 'backup_dir' $null
        if (-not $dir -or -not (Test-Path $dir)) {
            Write-Warn2 "no backup directory recorded (nothing needed backing up)"
            return
        }
    }

    Write-Step "Restoring files from $dir"
    foreach ($entry in @(Get-PropertyValue $manifest 'patched' @())) {
        $path = Get-PropertyValue $entry 'path' $null
        if (-not $path -or -not (Get-PropertyValue $entry 'backup' $null)) { continue }
        $rel = $path
        if ($path.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $path.Substring($env:USERPROFILE.Length).TrimStart('\')
        } else {
            $rel = $path.TrimStart('\')
        }
        $src = Join-Path $dir $rel
        if (Test-Path $src) {
            Invoke-Dry { Copy-Item -Force -LiteralPath $src -Destination $path } "restore $path"
            Write-Info "restored $path"
        }
    }
    $patch = Get-PropertyValue $manifest 'json_patch' $null
    if ($patch) {
        $backup = Get-PropertyValue $patch 'backup' $null
        $settingsPath = Get-PropertyValue $patch 'settings_path' $null
        if ($backup -and (Test-Path $backup) -and $settingsPath) {
            Invoke-Dry { Copy-Item -Force -LiteralPath $backup -Destination $settingsPath } "restore $settingsPath"
            Write-Info "restored $settingsPath"
        }
    }
    Write-Step "Done"
    if ($DryRun) { Write-Info "dry-run complete - nothing was changed" }
    else { Write-Info "files rolled back to their pre-install state; reinstall to re-enable LCARS" }
}

# --- uninstall ---------------------------------------------------------------

function Uninstall-Lcars {
    $manifest = Read-Manifest
    Write-Step "Uninstalling LCARS"
    Write-Info "install directory: $LcarsDir"
    if ($manifest) { Write-Info "manifest: found" }
    else { Write-Warn2 "no manifest found - scanning known locations for LCARS blocks" }

    # 1. Marked blocks in the PowerShell profile.
    $profiles = New-Object System.Collections.Generic.List[string]
    if ($manifest) {
        foreach ($entry in @(Get-PropertyValue $manifest 'patched' @())) {
            $p = Get-PropertyValue $entry 'path' $null
            if ($p) { $profiles.Add($p) }
        }
    }
    $profiles.Add((Get-PsProfilePath))
    foreach ($p in ($profiles | Select-Object -Unique)) {
        Remove-MarkedBlock $p
    }

    # 2. Windows Terminal scheme + profile.
    Remove-WtTheme $manifest

    # 3. Files the theme owns.
    Write-Step "Removing LCARS files"
    if ($manifest) { Remove-ManifestFiles $manifest } else { Remove-KnownFiles }

    # 4. Purge.
    if ($Purge -and (Test-Path $LcarsDir)) {
        if ($manifest -or $Yes) {
            Invoke-Dry { Remove-Item -Recurse -Force -LiteralPath $LcarsDir } "purge $LcarsDir (including backups)"
            Write-Info "purged $LcarsDir"
        } else {
            Write-Warn2 "refusing to purge without a manifest; use -Yes"
        }
    }

    # 5. Manifest itself.
    if (Test-Path $ManifestPath) { Invoke-Dry { Remove-Item -Force $ManifestPath } "rm $ManifestPath" }

    Write-Step "Done"
    if (-not $Purge -and (Test-Path (Join-Path $LcarsDir 'backups'))) {
        Write-Info "backups kept in $LcarsDir\backups (use -Purge to remove)"
    }
    foreach ($left in $Script:Leftovers) { Write-Warn2 "manual cleanup may be needed in: $left" }
    Write-Info "restart Windows Terminal for a clean shell"
}

# --- dispatch ----------------------------------------------------------------

try {
    if ($Restore) { Restore-Lcars $RestoreStamp }
    else { Uninstall-Lcars }
} catch {
    Write-Fail $_.Exception.Message
}
