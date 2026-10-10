#!/usr/bin/env bash
# =============================================================================
# LCARS uninstaller (macOS + Linux, Ghostty / Terminal.app)
# =============================================================================
# This script is self-contained on purpose: the installer copies it to
#   <LCARS_DIR>/uninstall.sh
# so it still works after the repository is deleted or moved.
#
# It does NOT need the install manifest. When the manifest is missing (deleted
# repo, lost file, partial install) it falls back to scanning the known config
# locations for the `# >>> lcars >>>` marker and removing the files the theme
# owns. When the manifest is present it uses it for a precise cleanup and can
# also restore your pre-install files.
#
# Usage:
#   sh install/uninstall.sh [options]
#   sh ~/.config/lcars/uninstall.sh [options]
#
# Options:
#   --dry-run           show what would change; change nothing
#   --yes, -y           do not prompt
#   --purge             also delete backups and the LCARS directory
#   --keep-backups      keep backups (default)
#   --restore [STAMP]   roll back files touched by the installer, then stop
#   --dir PATH          LCARS install directory (default: auto-detected)
#   --help, -h          this help
#
# Environment overrides (same names as the installer, handy for testing):
#   LCARS_DIR, LCARS_GHOSTTY_CONFIG, LCARS_SHELL_RC, LCARS_TMUX_CONFIG
# =============================================================================

set -u

# Re-exec under bash if invoked with a POSIX shell (e.g. `sh uninstall.sh`).
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

MARK_START="# >>> lcars >>>"
MARK_END="# <<< lcars <<<"
MANIFEST_NAME=".lcars-install.json"
PROFILE_NAME="LCARS"
US="$(printf '\037')"

DRY_RUN=0
ASSUME_YES=0
PURGE=0
MODE="uninstall"
RESTORE_TS=""
DIR_EXPLICIT=0
CLEANED_FILES=0
REMOVED_FILES=0
REMOVED_DIRS=0
LEFTOVERS=""
TMP_SEEN="$(mktemp "${TMPDIR:-/tmp}/lcars-seen.XXXXXX")"
trap 'rm -f "$TMP_SEEN"' EXIT INT TERM

# --- output ------------------------------------------------------------------

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

dry() { [ "$DRY_RUN" = 1 ]; }

run() {
    if dry; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
LCARS uninstaller

usage: sh install/uninstall.sh [options]            # from the repo
       sh ~/.config/lcars/uninstall.sh [options]    # after the repo is gone

options:
  --dry-run          show what would change; change nothing
  --yes, -y          assume yes for prompts
  --purge            also delete backups and the LCARS directory
  --keep-backups     keep backups (default)
  --restore [STAMP]  restore files from backups (latest, or STAMP=YYYYmmdd-HHMMSS)
  --dir PATH         LCARS install directory (default: auto-detected)
  --help, -h         this help

environment overrides:
  LCARS_DIR            install directory   (default: ~/.config/lcars)
  LCARS_GHOSTTY_CONFIG path to Ghostty config
  LCARS_SHELL_RC       path to zshrc/bashrc
  LCARS_TMUX_CONFIG    path to tmux.conf
EOF
}

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --purge) PURGE=1 ;;
        --keep-backups) PURGE=0 ;;
        --restore)
            MODE="restore"
            if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
                RESTORE_TS="$2"
                shift
            fi
            ;;
        --dir)
            [ $# -ge 2 ] || die "--dir needs a path"
            LCARS_DIR="$2"
            DIR_EXPLICIT=1
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

# --- locate the LCARS directory ----------------------------------------------

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(uname -s 2>/dev/null || printf unknown)"

# shellcheck disable=SC2034
LCARS_DIR="${LCARS_DIR:-}"
[ -n "$LCARS_DIR" ] && DIR_EXPLICIT=1

if [ -z "$LCARS_DIR" ] && [ -f "$SELF_DIR/$MANIFEST_NAME" ]; then
    LCARS_DIR="$SELF_DIR"
fi
# A shipped copy at <LCARS_DIR>/uninstall.sh can identify its own directory
# even when the manifest is gone (the layout contains shell.sh / ghostty/).
if [ -z "$LCARS_DIR" ] && [ "$(basename "$0")" = "uninstall.sh" ]; then
    if [ -f "$SELF_DIR/shell.sh" ] || [ -d "$SELF_DIR/ghostty" ] || [ -f "$SELF_DIR/starship.toml" ]; then
        LCARS_DIR="$SELF_DIR"
    fi
fi
if [ -z "$LCARS_DIR" ]; then
    LCARS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lcars"
fi
MANIFEST="$LCARS_DIR/$MANIFEST_NAME"

# The manifest may record a custom install directory; trust it if the default
# does not exist. This is what makes a custom `LCARS_DIR=...` install removable.
if [ "$DIR_EXPLICIT" = 0 ] && [ ! -f "$MANIFEST" ]; then
    for candidate in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/lcars/$MANIFEST_NAME" \
        "$HOME/.config/lcars/$MANIFEST_NAME"
    do
        if [ -f "$candidate" ]; then
            MANIFEST="$candidate"
            LCARS_DIR="$(dirname "$candidate")"
            break
        fi
    done
fi

# --- manifest helpers (python3 when available, grep fallback otherwise) ------

have_python=0
command -v python3 >/dev/null 2>&1 && have_python=1

manifest_py() {
    [ "$have_python" = 1 ] || return 1
    [ -f "$MANIFEST" ] || return 1
    LCARS_MARK_START="$MARK_START" LCARS_MARK_END="$MARK_END" \
        python3 - "$MANIFEST" "$@" <<'PY'
import json, os, sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
except Exception:
    sys.exit(1)

mark_start = os.environ.get("LCARS_MARK_START", "")
mark_end = os.environ.get("LCARS_MARK_END", "")
cmd = sys.argv[2]
if cmd == "lcars_dir":
    print(manifest.get("lcars_dir", ""))
elif cmd == "backup_dir":
    print(manifest.get("backup_dir", ""))
elif cmd == "created":
    for entry in manifest.get("created", []):
        print(entry)
elif cmd == "patched":
    for entry in manifest.get("patched", []):
        print("\x1f".join([
            entry.get("path", ""),
            entry.get("backup", ""),
            entry.get("start", mark_start),
            entry.get("end", mark_end),
        ]))
elif cmd == "terminal":
    terminal = manifest.get("terminal_app", {}) or {}
    value = terminal.get(sys.argv[3], "")
    print(value if isinstance(value, str) else json.dumps(value))
PY
}

# Without python3, parse the machine-generated manifest with sed. The writer
# always emits `"key": "value"` with two-space indentation, which is enough.
manifest_sed_field() {
    [ -f "$MANIFEST" ] || return 1
    sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\\(.*\\)\",[[:space:]]*$/\\1/p" "$MANIFEST" | head -n 1
}

manifest_dir() {
    if manifest_py lcars_dir 2>/dev/null; then
        return 0
    fi
    manifest_sed_field lcars_dir
}

manifest_backup_dir() {
    if manifest_py backup_dir 2>/dev/null; then
        return 0
    fi
    manifest_sed_field backup_dir
}

manifest_created() {
    if [ "$have_python" = 1 ]; then
        manifest_py created 2>/dev/null && return 0
    fi
    [ -f "$MANIFEST" ] || return 0
    awk '
        /^[[:space:]]*"created": \[/ { inside = 1; next }
        inside && /^[[:space:]]*\]/ { inside = 0 }
        inside {
            line = $0
            sub(/^[[:space:]]*"/, "", line)
            sub(/",[[:space:]]*$/, "", line)
            if (line != "") print line
        }
    ' "$MANIFEST"
}

manifest_patched() {
    if [ "$have_python" = 1 ]; then
        manifest_py patched 2>/dev/null && return 0
    fi
    [ -f "$MANIFEST" ] || return 0
    # Each patched entry is a single line: {"path": "...", "backup": "..."}
    grep '"path":' "$MANIFEST" | while IFS= read -r line; do
        _p="$(printf '%s' "$line" | sed -n 's/.*"path":[[:space:]]*"\([^"]*\)".*/\1/p')"
        _b="$(printf '%s' "$line" | sed -n 's/.*"backup":[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$_p" ] || continue
        printf '%s%s%s%s%s\n' "$_p" "$US" "$_b" "$US$MARK_START" "$US$MARK_END"
    done
}

manifest_terminal() {
    if manifest_py terminal "$1" 2>/dev/null; then
        return 0
    fi
    manifest_sed_field "$1"
}

# --- marked block removal ----------------------------------------------------

# strip_marked_block FILE START END — removes the block; prints nothing.
strip_marked_block() {
    local file="$1" start="$2" end="$3" tmp
    tmp="$file.lcars-uninstall-tmp"
    awk -v s="$start" -v e="$end" '
        index($0, s) { skip = 1; next }
        index($0, e) { skip = 0; next }
        !skip { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    # drop trailing blank lines the removal may have left behind
    awk '
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = 1; i <= last; i++) print lines[i]
        }
    ' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    mv "$tmp" "$file"
}

# clean_file FILE — remove a marked block if present. Returns 0 when it acted.
# Each file is considered at most once, even if it appears in both the manifest
# and the no-manifest candidate sweep.
clean_file() {
    local file="$1" before after
    [ -f "$file" ] || return 1
    if grep -qxF "$file" "$TMP_SEEN" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$file" >> "$TMP_SEEN"
    if ! grep -qF "$MARK_START" "$file"; then
        # A partial/hand-edited marker can still leave a live `config-file` /
        # `source-file` line pointing at LCARS. Flag it so the user knows.
        if grep -Eq 'lcars/|LCARS_DIR' "$file" 2>/dev/null; then
            warn "marker not found in $file, but it still references LCARS"
            LEFTOVERS="$LEFTOVERS $file"
        fi
        return 1
    fi
    if dry; then
        printf '   [dry-run] remove LCARS block from %s\n' "$file"
        return 0
    fi
    before="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
    strip_marked_block "$file" "$MARK_START" "$MARK_END"
    after="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
    if [ "$before" != "$after" ]; then
        info "cleaned $file"
        CLEANED_FILES=$((CLEANED_FILES + 1))
        return 0
    fi
    return 1
}

# candidate_files — the config files the installer may have patched. Emits only
# paths that exist. Works without a manifest.
candidate_files() {
    _emit() { [ -n "$1" ] && [ -f "$1" ] && printf '%s\n' "$1"; }
    _emit "${LCARS_GHOSTTY_CONFIG:-}"
    _emit "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config"
    _emit "$HOME/.config/ghostty/config"
    _emit "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
    _emit "${LCARS_SHELL_RC:-}"
    _emit "$HOME/.zshrc"
    _emit "$HOME/.bashrc"
    _emit "$HOME/.bash_profile"
    _emit "$HOME/.zprofile"
    _emit "$HOME/.profile"
    _emit "${LCARS_TMUX_CONFIG:-}"
    _emit "$HOME/.tmux.conf"
    _emit "$HOME/.config/tmux/tmux.conf"
    # pwsh (PowerShell 7) on macOS/Linux; the Windows installer uses its own.
    _emit "$HOME/.config/powershell/Microsoft.PowerShell_profile.ps1"
    _emit "$HOME/.config/powershell/profile.ps1"
}

# --- owned file removal ------------------------------------------------------

# Paths the installer creates relative to LCARS_DIR. Used for a manifest-less
# cleanup so a lost manifest never strands theme files.
known_owned_rel() {
    cat <<'EOF'
ghostty/ghostty.conf
ghostty/shaders/lcars-frame.glsl
ghostty/shaders/lcars-crt.glsl
ghostty/themes/lcars
starship.toml
fastfetch.jsonc
tmux.conf
shell.sh
profile.ps1
uninstall.sh
EOF
}

remove_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    if [ -d "$path" ]; then
        return 0
    fi
    run rm -f "$path"
    REMOVED_FILES=$((REMOVED_FILES + 1))
}

remove_empty_dirs() {
    local root="$1" dir
    [ -d "$root" ] || return 0
    dry && return 0
    find "$root" -type d 2>/dev/null | awk '{ print length, $0 }' \
        | sort -rn | cut -d' ' -f2- | while IFS= read -r dir; do
        [ "$dir" = "$root" ] && continue
        case "$dir" in
            */backups|*/backups/*) continue ;;
        esac
        rmdir "$dir" 2>/dev/null && REMOVED_DIRS=$((REMOVED_DIRS + 1))
    done
}

known_owned_cleanup() {
    local rel
    remove_path "$LCARS_DIR/uninstall.sh"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        remove_path "$LCARS_DIR/$rel"
    done <<EOF
$(known_owned_rel)
EOF
    if [ -d "$LCARS_DIR/sounds" ]; then
        find "$LCARS_DIR/sounds" -type f -name '*.wav' 2>/dev/null | while IFS= read -r f; do
            run rm -f "$f"
        done
    fi
    if [ -d "$LCARS_DIR/assets" ]; then
        find "$LCARS_DIR/assets" -type f -name '*.png' 2>/dev/null | while IFS= read -r f; do
            run rm -f "$f"
        done
    fi
}

manifest_owned_cleanup() {
    local p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            "$LCARS_DIR"/*)
                remove_path "$p"
                ;;
            *)
                # An empty file we created outside LCARS_DIR (e.g. a profile we
                # touched but did not otherwise modify) is safe to delete.
                if [ -f "$p" ] && ! grep -q '[^[:space:]]' "$p"; then
                    remove_path "$p"
                fi
                ;;
        esac
    done <<EOF
$(manifest_created)
EOF
}

# --- macOS Terminal.app cleanup ----------------------------------------------

terminal_running() {
    pgrep -x Terminal >/dev/null 2>&1
}

terminal_app_cleanup() {
    [ "$PLATFORM" = "Darwin" ] || return 0
    command -v defaults >/dev/null 2>&1 || return 0

    local installed changed prev_def prev_start profile plist current_default
    installed="$(manifest_terminal installed 2>/dev/null || true)"
    changed="$(manifest_terminal changed_default 2>/dev/null || true)"
    prev_def="$(manifest_terminal prev_default 2>/dev/null || true)"
    prev_start="$(manifest_terminal prev_startup 2>/dev/null || true)"
    profile="$(manifest_terminal profile 2>/dev/null || true)"
    [ -n "$profile" ] || profile="$PROFILE_NAME"

    # No manifest? Decide from the live settings whether LCARS is the default.
    if [ -z "$installed" ]; then
        current_default="$(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null || true)"
        if [ "$current_default" = "$profile" ]; then
            changed=true
        else
            return 0
        fi
    fi
    [ "$installed" = "true" ] || [ "$changed" = "true" ] || return 0

    step "Terminal.app cleanup"
    if [ "$changed" = "true" ]; then
        if [ -n "$prev_def" ]; then
            run defaults write com.apple.Terminal 'Default Window Settings' -string "$prev_def"
            info "default profile restored to '$prev_def'"
        else
            run defaults delete com.apple.Terminal 'Default Window Settings' 2>/dev/null || true
        fi
        if [ -n "$prev_start" ]; then
            run defaults write com.apple.Terminal 'Startup Window Settings' -string "$prev_start"
        fi
    fi

    plist="$HOME/Library/Preferences/com.apple.Terminal.plist"
    if terminal_running; then
        warn "Terminal.app is running — remove the profile manually:"
        warn "  Terminal > Settings > Profiles > ${profile} > minus button"
        LEFTOVERS="$LEFTOVERS Terminal.app profile:$profile"
    elif dry; then
        printf '   [dry-run] remove profile %s from com.apple.Terminal\n' "$profile"
    else
        if /usr/libexec/PlistBuddy -c "Delete :Window Settings:${profile}" "$plist" 2>/dev/null; then
            killall cfprefsd 2>/dev/null || true
            info "removed Terminal.app profile '${profile}'"
        else
            warn "could not remove the profile automatically:"
            warn "  Terminal > Settings > Profiles > ${profile} > minus button"
            LEFTOVERS="$LEFTOVERS Terminal.app profile:$profile"
        fi
    fi
}

# --- restore -----------------------------------------------------------------

restore_files() {
    local ts="$1" dir rel src count=0
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST (cannot restore without one)"
    if [ -n "$ts" ]; then
        dir="$LCARS_DIR/backups/$ts"
        [ -d "$dir" ] || die "backup directory not found: $dir"
    else
        dir="$(manifest_backup_dir)"
        if [ -z "$dir" ] || [ ! -d "$dir" ]; then
            warn "no backup directory recorded (nothing needed backing up)"
            return 0
        fi
    fi
    info "restoring files from $dir"

    while IFS="$US" read -r path backup start end; do
        [ -n "$path" ] || continue
        case "$path" in
            "$HOME"/*) rel="${path#"$HOME"/}" ;;
            *) rel="$(printf '%s' "$path" | sed 's|^/||')" ;;
        esac
        src="$dir/$rel"
        [ -f "$src" ] || continue
        if dry; then
            printf '   [dry-run] restore %s\n' "$path"
        else
            cp "$src" "$path" && info "restored $path"
        fi
        count=$((count + 1))
    done <<EOF
$(manifest_patched)
EOF
    info "restored $count file(s)"
}

# --- main uninstall ----------------------------------------------------------

uninstall() {
    step "Uninstalling LCARS"
    info "install directory: $LCARS_DIR"
    if [ -f "$MANIFEST" ]; then
        info "manifest: found"
        local recorded
        recorded="$(manifest_dir)"
        if [ -n "$recorded" ] && [ "$recorded" != "$LCARS_DIR" ] && [ -d "$recorded" ]; then
            warn "manifest records a different directory: $recorded"
        fi
    else
        warn "no manifest found — scanning known locations for LCARS blocks"
    fi

    # 1. Remove marked blocks. Prefer manifest paths, then sweep candidates.
    if [ -f "$MANIFEST" ]; then
        while IFS="$US" read -r path backup start end; do
            [ -n "$path" ] || continue
            [ -n "$start" ] || start="$MARK_START"
            [ -n "$end" ] || end="$MARK_END"
            clean_file "$path" || true
        done <<EOF
$(manifest_patched)
EOF
    fi
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        clean_file "$file" || true
    done <<EOF
$(candidate_files | sort -u)
EOF

    # 2. macOS Terminal.app (profile + default restoration).
    terminal_app_cleanup

    # 3. Owned files. The manifest is authoritative; without it, fall back to
    #    the known layout.
    step "Removing LCARS files"
    if [ -f "$MANIFEST" ]; then
        manifest_owned_cleanup
    else
        known_owned_cleanup
    fi
    remove_empty_dirs "$LCARS_DIR"

    # 4. Purge.
    if [ "$PURGE" = 1 ]; then
        if [ -d "$LCARS_DIR" ]; then
            if [ -f "$MANIFEST" ] || [ "$ASSUME_YES" = 1 ]; then
                run rm -rf "$LCARS_DIR"
                info "purged $LCARS_DIR (including backups)"
            else
                warn "refusing to purge without a manifest; pass --yes to confirm"
            fi
        fi
    fi

    # 5. The manifest itself.
    if [ -f "$MANIFEST" ]; then
        run rm -f "$MANIFEST"
    fi

    step "Done"
    info "removed LCARS blocks from $CLEANED_FILES file(s)"
    if [ "$PURGE" != 1 ] && [ -d "$LCARS_DIR/backups" ]; then
        info "backups kept in $LCARS_DIR/backups (use --purge to remove)"
    elif [ -d "$LCARS_DIR" ] && [ ! -f "$MANIFEST" ] && [ "$PURGE" != 1 ]; then
        left="$(find "$LCARS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)"
        if [ -z "$left" ]; then
            run rmdir "$LCARS_DIR" 2>/dev/null || true
        else
            info "remaining in $LCARS_DIR: $(find "$LCARS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ') item(s)"
        fi
    fi

    if [ -n "$LEFTOVERS" ]; then
        warn "manual cleanup may still be needed in:$LEFTOVERS"
    fi

    info "restart your terminal(s) for a clean shell"
}

case "$MODE" in
    uninstall) uninstall ;;
    restore)   restore_files "$RESTORE_TS" ;;
esac
