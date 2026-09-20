# =============================================================================
# LCARS PowerShell integration
# =============================================================================
# Dot-sourced from a marked region in your PowerShell profile by the installer.
# Works in Windows PowerShell 5.1 and PowerShell 7+. Everything degrades
# gracefully when starship/fastfetch are not installed.
#
# Toggles:
#   $env:LCARS_SPLASH = '0'   disable the fastfetch splash
#   $env:LCARS_SOUND  = '0'   disable prompt beeps
# =============================================================================

$env:LCARS_DIR = Split-Path -Parent $PSCommandPath

# --- Starship prompt ---------------------------------------------------------

$env:STARSHIP_CONFIG = Join-Path $env:LCARS_DIR 'starship.toml'
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}

# --- PSReadLine colors -------------------------------------------------------

if (Get-Module -ListAvailable PSReadLine -ErrorAction SilentlyContinue) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue
    try {
        Set-PSReadLineOption -Colors @{
            Default   = '#FFCC99'
            Command   = '#FFCC99'
            Parameter = '#99CCFF'
            Operator  = '#CC99CC'
            Variable  = '#FF9966'
            String    = '#99CC66'
            Number    = '#FFDD88'
            Type      = '#99E0E0'
            Comment   = '#996699'
            Keyword   = '#FF9900'
            Error     = '#FF5555'
            Member    = '#99CCFF'
        }
    } catch {
        # Older PSReadLine builds do not accept hex colors; keep defaults.
    }
    try { Set-PSReadLineOption -BellStyle None } catch { }
}

# --- splash (once per shell) -------------------------------------------------

if ($env:LCARS_SPLASH -ne '0' -and -not $env:LCARS_SPLASH_SHOWN) {
    $env:LCARS_SPLASH_SHOWN = '1'
    if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
        # Windows Terminal does not render the Kitty protocol yet; use text.
        fastfetch --config (Join-Path $env:LCARS_DIR 'fastfetch.jsonc') --logo none 2>$null
    }
}

# --- prompt beeps ------------------------------------------------------------

if ($env:LCARS_SOUND -ne '0') {
    $script:__lcarsConfirm = Join-Path $env:LCARS_DIR 'sounds/lcars-ok.wav'
    $script:__lcarsAlert = Join-Path $env:LCARS_DIR 'sounds/lcars-alert.wav'
    $script:__lcarsHistory = -1
    $script:__lcarsPrevPrompt = $function:prompt

    function global:prompt {
        $count = @(Get-History -ErrorAction SilentlyContinue).Count
        if ($script:__lcarsHistory -ge 0 -and $count -ne $script:__lcarsHistory) {
            $file = if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
                $script:__lcarsConfirm
            } else {
                $script:__lcarsAlert
            }
            try {
                $player = New-Object System.Media.SoundPlayer $file
                $player.Play()
            } catch { }
        }
        $script:__lcarsHistory = $count
        if ($script:__lcarsPrevPrompt) {
            & $script:__lcarsPrevPrompt
        } else {
            "PS $($executionContext.SessionState.Path.CurrentLocation)> "
        }
    }
}
