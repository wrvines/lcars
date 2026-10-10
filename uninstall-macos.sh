#!/usr/bin/env bash
# =============================================================================
# LCARS single-file uninstaller for macOS
# =============================================================================
# This is the "rescue" copy: one file, no repository, no manifest. Copy it to
# the Mac where LCARS is installed and run:
#
#   sh uninstall-macos.sh [--dry-run] [--purge] [--dir PATH]
#
# It first looks for the full uninstaller (this repo's install/uninstall.sh, or
# the copy the installer ships at ~/.config/lcars/uninstall.sh) and hands off to
# it when found. When neither exists — a pre-existing install, a deleted repo —
# it removes LCARS on its own:
#   * the `# >>> lcars >>>` … `# <<< lcars <<<` block from your shell rc,
#     Ghostty config, tmux config and PowerShell profile
#   * the LCARS files under ~/.config/lcars (backups kept unless --purge)
#   * the Terminal.app "LCARS" profile, restoring a sane default
#
# Options:
#   --dry-run   show what would change; change nothing
#   --purge     also delete backups and the whole LCARS directory
#   --dir PATH  LCARS install directory (default: ~/.config/lcars)
#   --yes, -y   assume yes (no prompts)
#   --help, -h  this help
# =============================================================================

set -u

# Re-exec under bash if invoked with a POSIX shell (e.g. `sh uninstall-macos.sh`).
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

MARK_START="# >>> lcars >>>"
MARK_END="# <<< lcars <<<"
MANIFEST_NAME=".lcars-install.json"
PROFILE_NAME="LCARS"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LCARS_DIR="${LCARS_DIR:-$HOME/.config/lcars}"

# --- hand off to the full uninstaller when one is available ------------------

for candidate in \
    "$SELF_DIR/install/uninstall.sh" \
    "$LCARS_DIR/uninstall.sh" \
    "$HOME/.config/lcars/uninstall.sh"
do
    [ -f "$candidate" ] || continue
    [ "$candidate" = "$0" ] && continue
    exec sh "$candidate" "$@"
done

# --- rescue path (no other uninstaller present) ------------------------------

DRY=0
PURGE=0

usage() {
    cat <<'EOF'
LCARS single-file uninstaller for macOS

usage: sh uninstall-macos.sh [options]

options:
  --dry-run   show what would change; change nothing
  --purge     also delete backups and the whole LCARS directory
  --dir PATH  LCARS install directory (default: ~/.config/lcars)
  --yes, -y   assume yes (no prompts)
  --help, -h  this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --purge) PURGE=1 ;;
        --yes|-y) : ;;
        --dir)
            [ $# -ge 2 ] || { printf 'ERROR: --dir needs a path\n' >&2; exit 2; }
            LCARS_DIR="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf 'unknown option: %s\n\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
dry()  { [ "$DRY" = 1 ]; }

run() {
    if dry; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

step "LCARS rescue uninstall (single file)"
info "install directory: $LCARS_DIR"

# 1. Config blocks.
for file in \
    "${LCARS_GHOSTTY_CONFIG:-}" \
    "$HOME/.config/ghostty/config" \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
    "${LCARS_SHELL_RC:-}" \
    "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile" \
    "${LCARS_TMUX_CONFIG:-}" \
    "$HOME/.tmux.conf" "$HOME/.config/tmux/tmux.conf" \
    "$HOME/.config/powershell/Microsoft.PowerShell_profile.ps1"
do
    [ -n "$file" ] && [ -f "$file" ] || continue
    if ! grep -qF "$MARK_START" "$file"; then
        if grep -Eq 'lcars/|LCARS_DIR' "$file" 2>/dev/null; then
            warn "$file still references LCARS but its marker is gone — clean it by hand"
        fi
        continue
    fi
    if dry; then
        printf '   [dry-run] remove LCARS block from %s\n' "$file"
        continue
    fi
    awk -v s="$MARK_START" -v e="$MARK_END" '
        index($0, s) { skip = 1; next }
        index($0, e) { skip = 0; next }
        !skip { print }
    ' "$file" > "$file.lcars-tmp" && mv "$file.lcars-tmp" "$file"
    info "cleaned $file"
done

# 2. Terminal.app profile (macOS only).
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    if dry; then
        printf '   [dry-run] remove Terminal.app profile %s\n' "$PROFILE_NAME"
    else
        current="$(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null || true)"
        if /usr/libexec/PlistBuddy -c "Delete :Window Settings:${PROFILE_NAME}" \
            "$HOME/Library/Preferences/com.apple.Terminal.plist" 2>/dev/null; then
            info "removed Terminal.app profile '${PROFILE_NAME}'"
        fi
        if [ "$current" = "$PROFILE_NAME" ]; then
            defaults write com.apple.Terminal 'Default Window Settings' -string Basic 2>/dev/null || true
            info "Terminal.app default set back to Basic"
        fi
        killall cfprefsd 2>/dev/null || true
    fi
fi

# 3. Theme files.
step "Removing LCARS files"
if [ ! -d "$LCARS_DIR" ]; then
    info "nothing at $LCARS_DIR"
elif [ "$PURGE" = 1 ]; then
    run rm -rf "$LCARS_DIR"
    info "purged $LCARS_DIR"
elif dry; then
    printf '   [dry-run] remove LCARS files under %s (keeping backups)\n' "$LCARS_DIR"
else
    rm -f "$LCARS_DIR"/ghostty/ghostty.conf \
          "$LCARS_DIR"/ghostty/shaders/lcars-frame.glsl \
          "$LCARS_DIR"/ghostty/shaders/lcars-crt.glsl \
          "$LCARS_DIR"/ghostty/themes/lcars \
          "$LCARS_DIR"/starship.toml \
          "$LCARS_DIR"/fastfetch.jsonc \
          "$LCARS_DIR"/tmux.conf \
          "$LCARS_DIR"/shell.sh \
          "$LCARS_DIR"/profile.ps1 \
          "$LCARS_DIR"/uninstall.sh 2>/dev/null
    find "$LCARS_DIR/sounds" -type f -name '*.wav' -delete 2>/dev/null || true
    find "$LCARS_DIR/assets" -type f -name '*.png' -delete 2>/dev/null || true
    find "$LCARS_DIR" -type d 2>/dev/null | awk '{ print length, $0 }' \
        | sort -rn | cut -d' ' -f2- | while IFS= read -r dir; do
        [ "$dir" = "$LCARS_DIR" ] && continue
        case "$dir" in */backups|*/backups/*) continue ;; esac
        rmdir "$dir" 2>/dev/null || true
    done
    if [ -f "$LCARS_DIR/$MANIFEST_NAME" ]; then
        rm -f "$LCARS_DIR/$MANIFEST_NAME"
    fi
    if [ -d "$LCARS_DIR/backups" ]; then
        info "removed LCARS files (backups kept in $LCARS_DIR/backups)"
    else
        rmdir "$LCARS_DIR" 2>/dev/null || true
        info "removed $LCARS_DIR"
    fi
fi

step "Done"
info "open a new terminal window/tab"
warn "rescue mode: run 'sh install/uninstall.sh' from the repo for full cleanup"
