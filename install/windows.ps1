# =============================================================================
# LCARS installer for Windows (Windows Terminal + PowerShell)
# =============================================================================
# Usage:
#   powershell -ExecutionPolicy Bypass -File install\windows.ps1
#   powershell -ExecutionPolicy Bypass -File install\windows.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File install\windows.ps1 -Uninstall
#
# Everything is reversible: marked blocks in your PowerShell profile, surgical
# edits to Windows Terminal settings.json (with a backup), and files confined
# to %LOCALAPPDATA%\lcars.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Reinstall,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Restore,
    [string]$RestoreStamp = '',
    [switch]$NoSounds,
    [switch]$KeepDefault,
    [string]$SettingsPath,
    [string]$LcarsDir,
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
$Script:Created = New-Object System.Collections.Generic.List[string]
$Script:BackupDir = $null
$Script:ManifestPath = $null

function Write-Step([string]$Text) { Write-Host "`n== $Text" }
function Write-Info([string]$Text) { Write-Host "   $Text" }
function Write-Warn([string]$Text) { Write-Warning "   $Text" }
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
    if ($DryRun) {
        Write-Host "   [dry-run] $Description"
    } else {
        & $Action
    }
}

# --- repo layout -------------------------------------------------------------

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Here
if (-not $LcarsDir -or $LcarsDir -eq '') {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $HOME '.local\share' }
    $LcarsDir = Join-Path $base 'lcars'
}
$Script:ManifestPath = Join-Path $LcarsDir '.lcars-install.json'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Script:BackupDir = Join-Path (Join-Path $LcarsDir 'backups') $Timestamp

function Show-Usage {
    @"
LCARS installer for Windows

usage: powershell -ExecutionPolicy Bypass -File install\windows.ps1 [options]

options:
  -DryRun            show what would change; change nothing
  -Yes               assume yes for prompts
  -Reinstall         refresh files over an existing install
  -Uninstall         remove LCARS (blocks, files, WT scheme and profile)
  -Purge             with -Uninstall: also delete backups and the LCARS dir
  -Restore           restore files from the latest backup
  -RestoreStamp TS   restore from a specific backup stamp (YYYYmmdd-HHmmss)
  -NoSounds          install without prompt beeps
  -KeepDefault       do not set the LCARS Windows Terminal profile as default
  -SettingsPath PATH override Windows Terminal settings.json (testing)
  -LcarsDir PATH     override install directory   (testing)
  -ProfilePath PATH  override PowerShell profile  (testing)
  -Help              this help
"@
}

if ($Help) { Show-Usage; exit 0 }

# --- helpers -----------------------------------------------------------------

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

function Get-UnescapedPath([string]$Path) { return $Path.Replace('\', '\\') }

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

function Copy-Owned([string]$Source, [string]$Destination) {
    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path $dir)) {
        Invoke-Dry { New-Item -ItemType Directory -Force -Path $dir | Out-Null } "mkdir $dir"
        $Script:Created.Add($dir)
    }
    Invoke-Dry { Copy-Item -Force -LiteralPath $Source -Destination $Destination } "copy $Source -> $Destination"
    if (-not $DryRun -and -not (Test-Path $Destination)) { Write-Fail "failed to copy $Source" }
    $Script:Created.Add($Destination)
}

function Backup-File([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $rel = $Path
    if ($Path.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $Path.Substring($env:USERPROFILE.Length).TrimStart('\')
    } else {
        $rel = $Path.TrimStart('\')
    }
    $dst = Join-Path $Script:BackupDir $rel
    Invoke-Dry {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -Force -LiteralPath $Path -Destination $dst
    } "backup $Path -> $dst"
    return $dst
}

function Get-WtSettingsPath {
    if ($SettingsPath) { return $SettingsPath }
    if (-not $env:LOCALAPPDATA) { return $null }
    $candidates = @()
    # Store / Preview / Canary / Dev package installs
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $packages) {
        $candidates += Get-ChildItem -Path $packages -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.WindowsTerminal*' } |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }
    }
    # unpackaged installs (winget/Scoop/portable)
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

function Add-MarkedBlock([string]$Path, [string]$Content) {
    if (Test-Path $Path) {
        $existing = [System.IO.File]::ReadAllText($Path)
    } else {
        $existing = ''
    }
    if (-not (Test-Path $Path)) { $Script:Created.Add($Path) }
    $block = "$MarkStart`r`n$Content`r`n$MarkEnd`r`n"
    $pattern = "(?ms)^\s*" + [regex]::Escape($MarkStart) + ".*?" + [regex]::Escape($MarkEnd) + "\s*"
    if ([regex]::IsMatch($existing, [regex]::Escape($MarkStart))) {
        $updated = [regex]::Replace($existing, $pattern, $block.Replace('$', '$$'))
    } else {
        $updated = $existing.TrimEnd() + "`r`n`r`n" + $block
    }
    Invoke-Dry { $utf8 = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($Path, $updated, $utf8) } "update marked block in $Path"
}

function Read-Manifest {
    if (Test-Path $Script:ManifestPath) {
        return (Get-Content -Raw -LiteralPath $Script:ManifestPath | ConvertFrom-Json)
    }
    return $null
}

# --- content -----------------------------------------------------------------

function Get-LcarsProfileObject([string]$CommandLine) {
    $image = Join-Path (Join-Path $LcarsDir 'assets') 'lcars-frame-16x9.png'
    return [ordered]@{
        guid                       = $ProfileGuid
        name                       = $ProfileName
        commandline                = $CommandLine
        colorScheme                = $SchemeName
        font                       = [ordered]@{ face = 'JetBrains Mono'; size = 12 }
        backgroundImage            = $image
        backgroundImageOpacity     = 0.75
        backgroundImageStretchMode = 'fill'
        backgroundImageAlignment   = 'center'
        padding                    = '32, 24, 32, 24'
        cursorShape                = 'filledBox'
        antialiasingMode           = 'grayscale'
        scrollbarState             = 'hidden'
    }
}

function Get-LcarsSchemeObject {
    $schemePath = Join-Path (Join-Path $Repo 'windows') 'lcars-scheme.json'
    return (Get-Content -Raw -LiteralPath $schemePath | ConvertFrom-Json)
}

# --- install -----------------------------------------------------------------

function Install-Lcars {
    if (-not (Test-Path (Join-Path $Repo 'palette'))) {
        Write-Fail "cannot find repository files (run this from the repo: install\windows.ps1)"
    }

    $manifest = Read-Manifest
    if ($manifest -and -not $Reinstall) {
        Write-Fail "LCARS already installed (manifest: $Script:ManifestPath). Use -Reinstall to refresh, or -Uninstall first."
    }
    if ($manifest) {
        $priorBackup = Get-PropertyValue $manifest 'backup_dir' $null
        if ($priorBackup -and (Test-Path $priorBackup)) {
            $Script:BackupDir = $priorBackup
        } else {
            # fall back to the directory of any still-existing recorded backup
            $candidates = @()
            foreach ($entry in @($manifest.patched)) {
                if ($entry.backup) { $candidates += $entry.backup }
            }
            $jsonPatchOld = Get-PropertyValue $manifest 'json_patch' $null
            if ($jsonPatchOld -and $jsonPatchOld.backup) { $candidates += $jsonPatchOld.backup }
            foreach ($candidate in $candidates) {
                if (Test-Path $candidate) {
                    $Script:BackupDir = Split-Path -Parent $candidate
                    break
                }
            }
        }
    }
    if (-not $manifest -and (Test-Path $LcarsDir) -and -not $DryRun) {
        Write-Warn "$LcarsDir exists but has no LCARS manifest"
        if (-not (Confirm-Action "Continue and let LCARS manage files in that directory?")) {
            Write-Fail "aborted"
        }
    }

    Write-Step "Installing LCARS files -> $LcarsDir"
    Copy-Owned (Join-Path $Repo 'prompt\starship.toml') (Join-Path $LcarsDir 'starship.toml')
    Copy-Owned (Join-Path $HERE '..\fastfetch\config.jsonc') (Join-Path $LcarsDir 'fastfetch.jsonc')
    Copy-Owned (Join-Path $HERE '..\powershell\profile.ps1') (Join-Path $LcarsDir 'profile.ps1')
    Copy-Owned (Join-Path $HERE '..\tmux\lcars.conf') (Join-Path $LcarsDir 'tmux.conf')
    # Self-contained uninstaller: survives deletion/moving of the repository.
    Copy-Owned (Join-Path $HERE 'uninstall.ps1') (Join-Path $LcarsDir 'uninstall.ps1')
    foreach ($sound in Get-ChildItem -Path (Join-Path $HERE '..\sounds') -Filter '*.wav') {
        if ($NoSounds) { continue }
        Copy-Owned $sound.FullName (Join-Path (Join-Path $LcarsDir 'sounds') $sound.Name)
    }
    foreach ($asset in Get-ChildItem -Path (Join-Path $HERE '..\assets') -Filter '*.png') {
        Copy-Owned $asset.FullName (Join-Path (Join-Path $LcarsDir 'assets') $asset.Name)
    }

    # token substitution in fastfetch config (JSON-escaped path)
    $ffPath = Join-Path $LcarsDir 'fastfetch.jsonc'
    if (-not $DryRun) {
        $ff = [System.IO.File]::ReadAllText($ffPath)
        $ff = $ff.Replace('__LCARS_DIR__', (Get-UnescapedPath $LcarsDir))
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ffPath, $ff, $utf8)
    } else {
        Write-Host "   [dry-run] substitute __LCARS_DIR__ in $ffPath"
    }

    # --- PowerShell profile region ---
    $psProfile = Get-PsProfilePath
    Write-Step "PowerShell profile"
    Write-Info $psProfile
    $region = ''
    if ($NoSounds) { $region += "`$env:LCARS_SOUND = '0'`r`n" }
    $region += ". `"$(Join-Path $LcarsDir 'profile.ps1')`""
    $profileBackup = $null
    if ($manifest) {
        foreach ($entry in @($manifest.patched)) {
            if ($entry.path -eq $psProfile -and $entry.backup) { $profileBackup = $entry.backup }
        }
    }
    if (-not $profileBackup -and (Test-Path $psProfile)) { $profileBackup = Backup-File $psProfile }
    Add-MarkedBlock $psProfile $region

    # --- Windows Terminal ---
    $wtPath = Get-WtSettingsPath
    $jsonPatch = $null
    if (-not $wtPath) {
        Write-Warn "Windows Terminal settings.json not found - skipping WT theme"
        Write-Warn "looked in %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal*\LocalState and"
        Write-Warn "%LOCALAPPDATA%\Microsoft\Windows Terminal\ - if yours is elsewhere, rerun with:"
        Write-Warn "  -SettingsPath C:\path\to\settings.json"
    } else {
        Write-Step "Windows Terminal"
        Write-Info $wtPath
        $settings = Read-JsonFile $wtPath
        $wtBackup = $null
        if ($manifest -and $manifest.json_patch -and $manifest.json_patch.backup -and (Test-Path $manifest.json_patch.backup)) {
            $wtBackup = $manifest.json_patch.backup
        } else {
            $wtBackup = Backup-File $wtPath
        }

        $commandLine = 'powershell.exe'
        if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { $commandLine = 'pwsh.exe' }
        $newProfile = Get-LcarsProfileObject $commandLine
        $newScheme = Get-LcarsSchemeObject

        $prevDefault = Get-PropertyValue $settings 'defaultProfile' $null
        $changedDefault = $false
        if (-not $KeepDefault) {
            $changedDefault = ($prevDefault -ne $ProfileGuid)
        }

        if (-not $DryRun) {
            $schemes = @(Get-PropertyValue $settings 'schemes' @())
            $schemes = @($schemes | Where-Object { $_.name -ne $SchemeName })
            $schemes += $newScheme
            Set-PropertyValue $settings 'schemes' $schemes

            $profilesNode = Get-PropertyValue $settings 'profiles' $null
            $list = @()
            if ($profilesNode) { $list = @(Get-PropertyValue $profilesNode 'list' @()) }
            $list = @($list | Where-Object { $_.guid -ne $ProfileGuid })
            $list += [pscustomobject]$newProfile

            if ($profilesNode -is [System.Array]) {
                Set-PropertyValue $settings 'profiles' ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = $list })
            } elseif ($profilesNode) {
                Set-PropertyValue $profilesNode 'list' $list
            } else {
                Set-PropertyValue $settings 'profiles' ([pscustomobject]@{ list = $list })
            }

            if (-not $KeepDefault) {
                Set-PropertyValue $settings 'defaultProfile' $ProfileGuid
            }
            Write-JsonFile $wtPath $settings
            Write-Info "added color scheme '$SchemeName' and profile '$ProfileName'"
            if (-not $KeepDefault) { Write-Info "set as default profile (previous: $prevDefault)" }

            # verify what was actually written
            $check = Read-JsonFile $wtPath
            $checkSchemes = @(Get-PropertyValue $check 'schemes' @())
            $checkProfiles = Get-PropertyValue $check 'profiles' $null
            $checkList = @()
            if ($checkProfiles) { $checkList = @(Get-PropertyValue $checkProfiles 'list' @()) }
            $hasScheme = @($checkSchemes | Where-Object { $_.name -eq $SchemeName }).Count -gt 0
            $hasProfile = @($checkList | Where-Object { $_.guid -eq $ProfileGuid }).Count -gt 0
            $currentDefault = Get-PropertyValue $check 'defaultProfile' ''
            Write-Info "verified: scheme=$hasScheme profile=$hasProfile default=$currentDefault"
            if (-not ($hasScheme -and $hasProfile)) {
                Write-Warn "verification failed - Windows Terminal may not pick up the theme"
            }
        } else {
            Write-Host "   [dry-run] add scheme '$SchemeName' and profile '$ProfileName' to $wtPath"
        }

        $jsonPatch = [ordered]@{
            settings_path   = $wtPath
            backup          = $wtBackup
            scheme          = $SchemeName
            profile_guid    = $ProfileGuid
            changed_default = $changedDefault
            prev_default    = $prevDefault
        }
    }

    # --- manifest ---
    $manifestObject = [ordered]@{
        version        = 1
        lcars_version  = '1.0.0'
        platform       = 'windows'
        installed_at   = $Timestamp
        lcars_dir      = $LcarsDir
        backup_dir     = $Script:BackupDir
        created        = @($Script:Created | Sort-Object -Unique)
        patched        = @(
            [ordered]@{
                path   = $psProfile
                backup = $profileBackup
                start  = $MarkStart
                end    = $MarkEnd
            }
        )
        json_patch     = $jsonPatch
    }
    if ($DryRun) {
        Write-Host "   [dry-run] write $Script:ManifestPath"
    } else {
        [System.IO.File]::WriteAllText($Script:ManifestPath, ($manifestObject | ConvertTo-Json -Depth 32),
            (New-Object System.Text.UTF8Encoding($false)))
    }

    # --- hints ---
    Write-Step "Optional dependencies"
    if (-not (Get-Command starship.exe -ErrorAction SilentlyContinue)) {
        Write-Warn "starship not found - prompt inactive (winget install Starship.Starship)"
    }
    if (-not (Get-Command fastfetch.exe -ErrorAction SilentlyContinue)) {
        Write-Warn "fastfetch not found - splash inactive (winget install fastfetch)"
    }
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        Write-Warn "pwsh (PowerShell 7) not found - the LCARS profile will use Windows PowerShell 5.1"
    }

    Write-Step "Done"
    if ($DryRun) {
        Write-Info "dry-run complete - nothing was changed"
    } else {
        Write-Info "LCARS installed to $LcarsDir"
        Write-Info "open a NEW Windows Terminal tab to see the theme"
        Write-Info 'toggles: $env:LCARS_SPLASH=0, $env:LCARS_SOUND=0'
        Write-Info "uninstall: powershell -File `"$LcarsDir\uninstall.ps1`""
    }
}

# --- dispatch ----------------------------------------------------------------

# Uninstall and restore live in install\uninstall.ps1 (also copied to
# $LcarsDir\uninstall.ps1) so they keep working after the repo is gone.
$Uninstaller = Join-Path $Here 'uninstall.ps1'

try {
    if ($Uninstall -or $Restore) {
        if (-not (Test-Path $Uninstaller)) {
            Write-Fail "uninstaller not found at $Uninstaller"
        }
        $forward = @()
        if ($DryRun) { $forward += '-DryRun' }
        if ($Yes) { $forward += '-Yes' }
        if ($Purge) { $forward += '-Purge' }
        if ($Restore) { $forward += '-Restore' }
        if ($RestoreStamp) { $forward += @('-RestoreStamp', $RestoreStamp) }
        if ($LcarsDir) { $forward += @('-LcarsDir', $LcarsDir) }
        if ($SettingsPath) { $forward += @('-SettingsPath', $SettingsPath) }
        if ($ProfilePath) { $forward += @('-ProfilePath', $ProfilePath) }
        & $Uninstaller @forward
        exit $LASTEXITCODE
    }
    Install-Lcars
} catch {
    Write-Fail $_.Exception.Message
}
