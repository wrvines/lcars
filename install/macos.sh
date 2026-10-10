#!/usr/bin/env bash
# =============================================================================
# LCARS installer for macOS (Ghostty + Terminal.app)
# =============================================================================
# Run from the repository root or any subdirectory:
#   sh install/macos.sh                       install (Ghostty + Terminal.app)
#   sh install/macos.sh --dry-run             preview changes
#   sh install/macos.sh --uninstall           remove everything it installed
#   sh install/macos.sh --no-terminal-default keep your current default profile
# =============================================================================

set -u

# Re-exec under bash if invoked with a POSIX shell (e.g. `sh install/macos.sh`).
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

LCARS_HERE="$(cd "$(dirname "$0")" && pwd)"
LCARS_REPO="$(cd "$LCARS_HERE/.." && pwd)"
# shellcheck source=common.sh
. "$LCARS_HERE/common.sh"

LCARS_TERM_DEFAULT=1
LCARS_TERM_PROFILE="LCARS"

usage() {
    cat <<'EOF'
LCARS installer for macOS

usage: sh install/macos.sh [options]

options:
  --dry-run              show what would change; change nothing
  --yes, -y              assume yes for prompts
  --reinstall            refresh files over an existing install
  --uninstall            remove LCARS (blocks, files, Terminal.app profile)
  --purge                with --uninstall: also delete backups and the LCARS dir
  --restore [STAMP]      restore files from backups (latest, or STAMP)
  --no-terminal-default  import the Terminal.app profile but do not set it default
  --no-terminal          skip Terminal.app entirely (Ghostty only)
  --no-ghostty           skip the Ghostty config block
  --no-shell             skip the shell rc block
  --no-tmux              skip the tmux config block
  --help, -h             this help

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
        --no-terminal-default) LCARS_TERM_DEFAULT=0 ;;
        --no-terminal) LCARS_SKIP_TERMINAL=1 ;;
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

LCARS_PLATFORM="macos"

# --- Terminal.app platform hooks ---------------------------------------------

lcars_platform_install() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    if [ "${LCARS_SKIP_TERMINAL:-0}" = 1 ]; then
        lcars_log "Terminal.app integration skipped (--no-terminal)"
        return 0
    fi
    lcars_step "Terminal.app profile"
    local file="$LCARS_REPO/terminal-app/LCARS.terminal"
    if [ ! -f "$file" ]; then
        lcars_warn "terminal-app/LCARS.terminal missing; run: python3 tools/make_terminal_profile.py"
        return 0
    fi
    if [ "$LCARS_TERM_DEFAULT" = 1 ]; then
        LCARS_TERM_PREV_DEFAULT="$(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null || true)"
        LCARS_TERM_PREV_STARTUP="$(defaults read com.apple.Terminal 'Startup Window Settings' 2>/dev/null || true)"
    fi
    if lcars_dry; then
        printf '   [dry-run] import %s via Terminal.app\n' "$file"
        if [ "$LCARS_TERM_DEFAULT" = 1 ]; then
            printf '   [dry-run] set LCARS as default (previous: %s)\n' "${LCARS_TERM_PREV_DEFAULT:-none}"
        fi
    else
        open -a Terminal "$file" \
            || lcars_warn "could not open the profile; double-click $file manually"
        lcars_log "imported Terminal.app profile 'LCARS'"
        if [ "$LCARS_TERM_DEFAULT" = 1 ]; then
            defaults write com.apple.Terminal 'Default Window Settings' -string "$LCARS_TERM_PROFILE"
            defaults write com.apple.Terminal 'Startup Window Settings' -string "$LCARS_TERM_PROFILE"
            LCARS_TERM_CHANGED_DEFAULT=true
            lcars_log "set as default profile (previous: ${LCARS_TERM_PREV_DEFAULT:-none})"
        else
            LCARS_TERM_CHANGED_DEFAULT=false
        fi
    fi
    LCARS_TERM_INSTALLED=true
    lcars_log "background image: Settings > Profiles > LCARS > Text > Background > Image"
    lcars_log "  (macOS 15 and earlier: Window > Background Image)"
    lcars_log "  choose assets/lcars-frame-termapp@2x.png for the best result"
}

# Terminal.app cleanup (profile + default restoration) lives in
# install/uninstall.sh, which is copied to $LCARS_DIR/uninstall.sh.

case "$MODE" in
    install)
        if [ "$(uname -s)" != "Darwin" ]; then
            lcars_warn "this is not macOS — Terminal.app steps will be skipped"
        fi
        lcars_install "$LCARS_REPO" "$WITH_GHOSTTY" "$WITH_SHELL" "$WITH_TMUX"
        ;;
    uninstall)
        set --
        [ "$LCARS_DRY_RUN" = 1 ] && set -- "$@" --dry-run
        [ "$LCARS_ASSUME_YES" = 1 ] && set -- "$@" --yes
        [ "$PURGE" = 1 ] && set -- "$@" --purge
        exec sh "$LCARS_HERE/uninstall.sh" "$@"
        ;;
    restore)
        set -- --restore
        [ "$LCARS_DRY_RUN" = 1 ] && set -- "$@" --dry-run
        [ "$LCARS_ASSUME_YES" = 1 ] && set -- "$@" --yes
        [ -n "$RESTORE_TS" ] && set -- "$@" "$RESTORE_TS"
        exec sh "$LCARS_HERE/uninstall.sh" "$@"
        ;;
esac
