# =============================================================================
# LCARS uninstaller — repository-root convenience wrapper
# =============================================================================
# Runs install\uninstall.ps1, which is also copied to
# %LOCALAPPDATA%\lcars\uninstall.ps1 at install time so it works after this
# repository is deleted.
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -DryRun
# =============================================================================

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path (Join-Path $Here 'install') 'uninstall.ps1'
& $Target @args
exit $LASTEXITCODE
