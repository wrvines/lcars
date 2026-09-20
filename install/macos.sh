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
    lcars_log "background image: Settings > Profiles > LCARS > Window > Background Image"
    lcars_log "  use assets/lcars-frame-termapp@2x.png for the best result"
}

lcars_platform_uninstall() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    if [ ! -f "$LCARS_MANIFEST" ]; then
        return 0
    fi
    local installed changed prev_def prev_start profile
    installed="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" installed)"
    [ "$installed" = "true" ] || return 0
    changed="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" changed_default)"
    prev_def="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" prev_default)"
    prev_start="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" prev_startup)"
    profile="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" profile)"
    : "${profile:=LCARS}"

    lcars_step "Terminal.app cleanup"
    if [ "$changed" = "true" ]; then
        if [ -n "$prev_def" ]; then
            lcars_run defaults write com.apple.Terminal 'Default Window Settings' -string "$prev_def"
            lcars_log "default profile restored to '$prev_def'"
        else
            lcars_run defaults delete com.apple.Terminal 'Default Window Settings' 2>/dev/null || true
        fi
        if [ -n "$prev_start" ]; then
            lcars_run defaults write com.apple.Terminal 'Startup Window Settings' -string "$prev_start"
        fi
    fi

    if pgrep -x Terminal >/dev/null 2>&1; then
        lcars_warn "Terminal.app is running — remove the profile manually:"
        lcars_warn "  Terminal > Settings > Profiles > ${profile} > minus button"
    elif lcars_dry; then
        printf '   [dry-run] remove profile %s from com.apple.Terminal\n' "$profile"
    else
        if /usr/libexec/PlistBuddy -c "Delete :Window Settings:${profile}" \
            "$HOME/Library/Preferences/com.apple.Terminal.plist" 2>/dev/null; then
            killall cfprefsd 2>/dev/null || true
            lcars_log "removed Terminal.app profile '${profile}'"
        else
            lcars_warn "could not remove the profile automatically:"
            lcars_warn "  Terminal > Settings > Profiles > ${profile} > minus button"
        fi
    fi
}

lcars_platform_restore() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    if [ ! -f "$LCARS_MANIFEST" ]; then
        return 0
    fi
    local changed prev_def prev_start
    changed="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" changed_default)"
    [ "$changed" = "true" ] || return 0
    prev_def="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" prev_default)"
    prev_start="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" terminal-field "$LCARS_MANIFEST" prev_startup)"
    if [ -n "$prev_def" ]; then
        lcars_run defaults write com.apple.Terminal 'Default Window Settings' -string "$prev_def"
        lcars_log "Terminal.app default profile restored to '$prev_def'"
    fi
    if [ -n "$prev_start" ]; then
        lcars_run defaults write com.apple.Terminal 'Startup Window Settings' -string "$prev_start"
    fi
}

case "$MODE" in
    install)
        if [ "$(uname -s)" != "Darwin" ]; then
            lcars_warn "this is not macOS — Terminal.app steps will be skipped"
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
