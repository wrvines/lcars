#!/usr/bin/env sh
# =============================================================================
# LCARS uninstaller — repository-root convenience wrapper
# =============================================================================
# Runs install/uninstall.sh, which is also copied to <LCARS_DIR>/uninstall.sh
# at install time so it works after this repository is deleted.
#
#   sh uninstall.sh              remove LCARS (keeps backups)
#   sh uninstall.sh --purge      remove LCARS and its backups
#   sh uninstall.sh --dry-run    preview only
#   sh uninstall.sh --help       full option list
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
exec sh "$HERE/install/uninstall.sh" "$@"
