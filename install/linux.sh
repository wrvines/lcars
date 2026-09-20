#!/usr/bin/env bash
# =============================================================================
# LCARS installer for Linux (Ghostty)
# =============================================================================
# Run from the repository root or any subdirectory:
#   sh install/linux.sh              install
#   sh install/linux.sh --dry-run    preview changes
#   sh install/linux.sh --uninstall  remove everything it installed
# =============================================================================

set -u

# Re-exec under bash if invoked with a POSIX shell (e.g. `sh install/linux.sh`).
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

LCARS_HERE="$(cd "$(dirname "$0")" && pwd)"
LCARS_REPO="$(cd "$LCARS_HERE/.." && pwd)"
# shellcheck source=common.sh
. "$LCARS_HERE/common.sh"

usage() {
    cat <<'EOF'
LCARS installer for Linux

usage: sh install/linux.sh [options]

options:
  --dry-run          show what would change; change nothing
  --yes, -y          assume yes for prompts
  --reinstall        refresh files over an existing install
  --uninstall        remove LCARS (marked blocks + owned files)
  --purge            with --uninstall: also delete backups and the LCARS dir
  --restore [STAMP]  restore files from backups (latest, or STAMP=YYYYmmdd-HHMMSS)
  --no-ghostty       skip the Ghostty config block
  --no-shell         skip the shell rc block
  --no-tmux          skip the tmux config block
  --help, -h         this help

environment overrides (also handy for testing):
  LCARS_DIR            install directory   (default: ~/.config/lcars)
  LCARS_GHOSTTY_CONFIG path to Ghostty config
  LCARS_SHELL_RC       path to zshrc/bashrc
  LCARS_TMUX_CONFIG    path to tmux.conf
EOF
}

MODE=install
PURGE=0
RESTORE_TS=""
WITH_GHOSTTY=1
WITH_SHELL=1
WITH_TMUX=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) LCARS_DRY_RUN=1 ;;
        --yes|-y) LCARS_ASSUME_YES=1 ;;
        --reinstall) LCARS_REINSTALL=1 ;;
        --uninstall) MODE=uninstall ;;
        --purge) PURGE=1 ;;
        --restore)
            MODE=restore
            if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
                RESTORE_TS="$2"
                shift
            fi
            ;;
        --no-ghostty) WITH_GHOSTTY=0 ;;
        --no-shell) WITH_SHELL=0 ;;
        --no-tmux) WITH_TMUX=0 ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf 'unknown option: %s\n\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

if [ "$(uname -s)" = "Darwin" ]; then
    LCARS_WRONG_PLATFORM=1
fi

LCARS_PLATFORM="linux"

case "$MODE" in
    install)
        if [ -n "${LCARS_WRONG_PLATFORM:-}" ]; then
            lcars_warn "this is macOS — use install/macos.sh for the Terminal.app integration"
        fi
        lcars_install "$LCARS_REPO" "$WITH_GHOSTTY" "$WITH_SHELL" "$WITH_TMUX"
        ;;
    uninstall)
        lcars_uninstall "$PURGE"
        ;;
    restore)
        lcars_restore_cmd "$RESTORE_TS"
        ;;
esac
