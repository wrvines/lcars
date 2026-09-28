$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path (Join-Path $Repo 'install') 'windows.ps1'
$ThemeSource = Join-Path (Join-Path $Repo 'opencode') 'lcars.json'
$TestRoot = Join-Path $env:TEMP ('lcars-opencode-test-' + [guid]::NewGuid().ToString('N'))
$PreviousXdg = $env:XDG_CONFIG_HOME

function Assert-Theme([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "expected file: $Path" }
    $actual = [System.IO.File]::ReadAllText($Path)
    if ($actual -cne $Expected) { throw "unexpected contents: $Path" }
}

function Invoke-Lcars(
    [string]$CaseDir,
    [switch]$DryRun,
    [switch]$Reinstall,
    [switch]$Restore,
    [switch]$Uninstall
) {
    $lcarsDir = Join-Path $CaseDir 'lcars'
    $profilePath = Join-Path $CaseDir 'profile.ps1'
    $settingsPath = Join-Path $CaseDir 'settings.json'
    $arguments = @{
        LcarsDir = $lcarsDir
        ProfilePath = $profilePath
        SettingsPath = $settingsPath
        KeepDefault = $true
        Yes = $true
        NoSounds = $true
    }
    if ($DryRun) { $arguments.DryRun = $true }
    if ($Reinstall) { $arguments.Reinstall = $true }
    if ($Restore) { $arguments.Restore = $true }
    if ($Uninstall) { $arguments.Uninstall = $true }
    & $Installer @arguments
    if (-not $?) { throw "Windows installer failed" }
}

function Initialize-Case([string]$CaseDir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $CaseDir 'home') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $CaseDir 'settings.json'), '{"defaultProfile":"{00000000-0000-0000-0000-000000000001}","profiles":{"list":[]},"schemes":[]}')
    $env:XDG_CONFIG_HOME = Join-Path $CaseDir 'config'
}

try {
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    $sourceContents = [System.IO.File]::ReadAllText($ThemeSource)

    # New theme: dry-run is inert, then restore and uninstall remove only what
    # LCARS added. Reinstall must retain the original ownership record.
    $newCase = Join-Path $TestRoot 'new-theme'
    Initialize-Case $newCase
    Invoke-Lcars $newCase -DryRun
    $newTheme = Join-Path $env:XDG_CONFIG_HOME 'opencode\themes\lcars.json'
    if (Test-Path $newTheme) { throw 'dry-run created the OpenCode theme' }
    if (Test-Path (Join-Path $newCase 'lcars')) { throw 'dry-run created the LCARS directory' }

    Invoke-Lcars $newCase
    Assert-Theme $newTheme $sourceContents
    $manifestPath = Join-Path (Join-Path $newCase 'lcars') '.lcars-install.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.managed_files.Count -ne 1 -or $manifest.managed_files[0].backup) { throw 'new theme ownership was not recorded' }
    Invoke-Lcars $newCase -Reinstall -DryRun
    Assert-Theme $newTheme $sourceContents
    Invoke-Lcars $newCase -Reinstall
    Invoke-Lcars $newCase -Restore
    if (Test-Path $newTheme) { throw 'restore did not remove the newly installed theme' }
    if (Test-Path (Join-Path $env:XDG_CONFIG_HOME 'opencode\themes')) { throw 'restore left the created themes directory' }
    Invoke-Lcars $newCase -Reinstall
    Invoke-Lcars $newCase -Uninstall
    if (Test-Path $newTheme) { throw 'uninstall did not remove the newly installed theme' }

    # Existing theme: restore and uninstall must return the exact prior bytes.
    $existingCase = Join-Path $TestRoot 'existing-theme'
    Initialize-Case $existingCase
    $existingTheme = Join-Path $env:XDG_CONFIG_HOME 'opencode\themes\lcars.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $existingTheme) | Out-Null
    $original = '{"theme":"user"}'
    [System.IO.File]::WriteAllText($existingTheme, $original)
    Invoke-Lcars $existingCase -DryRun
    Assert-Theme $existingTheme $original
    Invoke-Lcars $existingCase
    Assert-Theme $existingTheme $sourceContents
    $manifestPath = Join-Path (Join-Path $existingCase 'lcars') '.lcars-install.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $backup = $manifest.managed_files[0].backup
    Assert-Theme $backup $original
    Invoke-Lcars $existingCase -Reinstall
    Invoke-Lcars $existingCase -Restore
    Assert-Theme $existingTheme $original
    Invoke-Lcars $existingCase -Reinstall
    Invoke-Lcars $existingCase -Uninstall
    Assert-Theme $existingTheme $original

    Write-Host 'OpenCode Windows installer rollback checks passed'
} finally {
    if ($null -eq $PreviousXdg) { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    else { $env:XDG_CONFIG_HOME = $PreviousXdg }
    if (Test-Path $TestRoot) { Remove-Item -Recurse -Force $TestRoot }
}
