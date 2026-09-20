#!/usr/bin/env bash
# =============================================================================
# LCARS installer shared library (sourced by linux.sh and macos.sh)
# =============================================================================
# Bash 3.2 compatible (macOS system bash). No associative arrays.
# =============================================================================

LCARS_MARK_START="# >>> lcars >>>"
LCARS_MARK_END="# <<< lcars <<<"
LCARS_MANIFEST_NAME=".lcars-install.json"
LCARS_VERSION="1.0.0"

LCARS_DIR="${LCARS_DIR:-$HOME/.config/lcars}"
LCARS_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LCARS_LIB="$LCARS_INSTALL_DIR/lib"
LCARS_US="$(printf '\037')"
LCARS_PLATFORM=""
LCARS_DRY_RUN=0
LCARS_ASSUME_YES=0
LCARS_REINSTALL=0
LCARS_BACKUP_DIR=""
LCARS_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LCARS_MANIFEST=""
LCARS_CREATED=()
LCARS_PATCHED=()
LCARS_PYTHON=""

# --- output ------------------------------------------------------------------

lcars_step() { printf '\n== %s\n' "$*"; }
lcars_log()  { printf '   %s\n' "$*"; }
lcars_warn() { printf '   ! %s\n' "$*" >&2; }
lcars_die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

lcars_confirm() {
    [ "$LCARS_ASSUME_YES" = 1 ] && return 0
    printf '   %s [y/N] ' "$1"
    read -r _lcars_reply
    case "$_lcars_reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

lcars_dry() { [ "$LCARS_DRY_RUN" = 1 ]; }

lcars_run() {
    if lcars_dry; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# --- preflight ---------------------------------------------------------------

lcars_preflight() {
    if command -v python3 >/dev/null 2>&1; then
        LCARS_PYTHON="$(command -v python3)"
    else
        lcars_die "python3 is required (macOS: install Xcode Command Line Tools; Debian/Ubuntu: apt install python3)"
    fi
    LCARS_MANIFEST="$LCARS_DIR/$LCARS_MANIFEST_NAME"
    LCARS_BACKUP_DIR="$LCARS_DIR/backups/$LCARS_TIMESTAMP"
}

lcars_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

lcars_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

lcars_sed_escape() {
    printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'
}

# --- owned files -------------------------------------------------------------

lcars_ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        lcars_run mkdir -p "$dir"
        LCARS_CREATED+=("$dir")
    fi
}

# lcars_copy SRC DST — records DST as owned (deleted on uninstall)
lcars_copy() {
    local src="$1" dst="$2"
    [ -f "$src" ] || lcars_die "missing source file: $src"
    lcars_ensure_dir "$(dirname "$dst")"
    lcars_run cp "$src" "$dst"
    if ! lcars_dry && [ ! -f "$dst" ]; then
        lcars_die "failed to copy $src -> $dst"
    fi
    LCARS_CREATED+=("$dst")
}

lcars_replace_token() {
    local file="$1" token="$2" value="$3"
    if lcars_dry; then
        printf '   [dry-run] substitute %s in %s\n' "$token" "$file"
        return 0
    fi
    local escaped tmp
    escaped="$(lcars_sed_escape "$value")"
    tmp="$file.lcars-tmp"
    sed "s|$token|$escaped|g" "$file" > "$tmp" && mv "$tmp" "$file"
}

# --- backups -----------------------------------------------------------------

LCARS_LAST_BACKUP=""

# lcars_backup FILE — copies under the backup dir mirroring its absolute path
lcars_backup() {
    local path="$1"
    LCARS_LAST_BACKUP=""
    [ -f "$path" ] || return 0
    local rel dst
    case "$path" in
        "$HOME"/*) rel="${path#"$HOME"/}" ;;
        *) rel="$(printf '%s' "$path" | sed 's|^/||')" ;;
    esac
    dst="$LCARS_BACKUP_DIR/$rel"
    if lcars_dry; then
        printf '   [dry-run] backup %s -> %s\n' "$path" "$dst"
        LCARS_LAST_BACKUP="$dst"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$path" "$dst"
    LCARS_LAST_BACKUP="$dst"
}

# Backup only if we have not patched this file in a previous install.
lcars_backup_once() {
    local path="$1"
    if [ -f "$LCARS_MANIFEST" ]; then
        local prior
        prior="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" patched-entry "$LCARS_MANIFEST" "$path" 2>/dev/null | cut -d"$LCARS_US" -f1)"
        if [ -n "$prior" ]; then
            LCARS_LAST_BACKUP="$prior"
            return 0
        fi
    fi
    lcars_backup "$path"
}

# --- marked blocks -----------------------------------------------------------

# lcars_block_upsert FILE START END CONTENT_FILE
lcars_block_upsert() {
    local file="$1" start="$2" end="$3" content="$4"
    local backup=""
    if [ -f "$file" ]; then
        lcars_backup_once "$file"
        backup="$LCARS_LAST_BACKUP"
    fi
    LCARS_PATCHED+=("$(printf '%s\037%s\037%s\037%s' "$file" "$backup" "$start" "$end")")

    if lcars_dry; then
        printf '   [dry-run] upsert marked block in %s\n' "$file"
        return 0
    fi
    lcars_ensure_dir "$(dirname "$file")"
    if [ ! -f "$file" ]; then
        : > "$file"
        LCARS_CREATED+=("$file")
    fi
    if grep -qF "$start" "$file"; then
        local tmp="$file.lcars-tmp"
        awk -v s="$start" -v e="$end" -v c="$content" '
            BEGIN { body = ""; while ((getline line < c) > 0) body = body line "\n"; close(c); skip = 0 }
            index($0, s) { print s; printf "%s", body; skip = 1; next }
            index($0, e) { print e; skip = 0; next }
            !skip { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        {
            printf '\n%s\n' "$start"
            cat "$content"
            printf '%s\n' "$end"
        } >> "$file"
    fi
}

# lcars_block_remove FILE START END — returns 0 if the file was modified
lcars_block_remove() {
    local file="$1" start="$2" end="$3"
    [ -f "$file" ] || return 0
    if ! grep -qF "$start" "$file"; then
        return 0
    fi
    if lcars_dry; then
        printf '   [dry-run] remove marked block from %s\n' "$file"
        return 0
    fi
    local tmp="$file.lcars-tmp"
    awk -v s="$start" -v e="$end" '
        index($0, s) { skip = 1; next }
        index($0, e) { skip = 0; next }
        !skip { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    # collapse trailing blank lines we introduced
    awk 'BEGIN { blanks = 0 } /^[[:space:]]*$/ { blanks++; next } { while (blanks > 0) { print ""; blanks-- } print }' \
        "$file" > "$tmp" && mv "$tmp" "$file"
    return 0
}

# --- manifest ----------------------------------------------------------------

lcars_manifest_write() {
    lcars_dry && { printf '   [dry-run] write %s\n' "$LCARS_MANIFEST"; return 0; }
    mkdir -p "$(dirname "$LCARS_MANIFEST")"
    {
        printf '{\n'
        printf '  "version": 1,\n'
        printf '  "lcars_version": "%s",\n' "$(lcars_json_escape "$LCARS_VERSION")"
        printf '  "platform": "%s",\n' "$(lcars_json_escape "$LCARS_PLATFORM")"
        printf '  "installed_at": "%s",\n' "$(lcars_json_escape "$LCARS_TIMESTAMP")"
        printf '  "lcars_dir": "%s",\n' "$(lcars_json_escape "$LCARS_DIR")"
        printf '  "backup_dir": "%s",\n' "$(lcars_json_escape "$LCARS_BACKUP_DIR")"
        printf '  "created": [\n'
        printf '%s\n' "${LCARS_CREATED[@]+"${LCARS_CREATED[@]}"}" | sort -u | while IFS= read -r p; do
            [ -n "$p" ] || continue
            printf '    "%s",\n' "$(lcars_json_escape "$p")"
        done | sed '$ s/,$//'
        printf '\n  ],\n'
        printf '  "patched": [\n'
        if [ "${#LCARS_PATCHED[@]}" -gt 0 ]; then
            printf '%s\n' "${LCARS_PATCHED[@]}" | {
                _lcars_i=0
                while IFS= read -r entry; do
                    local path backup start end
                    IFS="$LCARS_US" read -r path backup start end <<EOF
$entry
EOF
                    [ "$_lcars_i" = 0 ] || printf ',\n'
                    printf '    {"path": "%s", "backup": "%s", "start": "%s", "end": "%s"}' \
                        "$(lcars_json_escape "$path")" "$(lcars_json_escape "$backup")" \
                        "$(lcars_json_escape "$start")" "$(lcars_json_escape "$end")"
                    _lcars_i=1
                done
            }
        fi
        printf '\n  ],\n'
        printf '  "terminal_app": {\n'
        printf '    "installed": %s,\n' "${LCARS_TERM_INSTALLED:-false}"
        printf '    "profile": "%s",\n' "$(lcars_json_escape "${LCARS_TERM_PROFILE:-}")"
        printf '    "prev_default": "%s",\n' "$(lcars_json_escape "${LCARS_TERM_PREV_DEFAULT:-}")"
        printf '    "prev_startup": "%s",\n' "$(lcars_json_escape "${LCARS_TERM_PREV_STARTUP:-}")"
        printf '    "changed_default": %s\n' "${LCARS_TERM_CHANGED_DEFAULT:-false}"
        printf '  }\n'
        printf '}\n'
    } > "$LCARS_MANIFEST"
}

# --- paths -------------------------------------------------------------------

lcars_ghostty_config() {
    if [ -n "${LCARS_GHOSTTY_CONFIG:-}" ]; then
        printf '%s' "$LCARS_GHOSTTY_CONFIG"
        return 0
    fi
    local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config"
    local mac="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
    if [ -f "$xdg" ]; then printf '%s' "$xdg"; return 0; fi
    if [ -f "$mac" ]; then printf '%s' "$mac"; return 0; fi
    case "$(uname -s)" in
        Darwin) printf '%s' "$mac" ;;
        *) printf '%s' "$xdg" ;;
    esac
}

lcars_shell_rc() {
    if [ -n "${LCARS_SHELL_RC:-}" ]; then
        printf '%s' "$LCARS_SHELL_RC"
        return 0
    fi
    local name
    name="$(basename "${SHELL:-/bin/bash}")"
    case "$name" in
        zsh) printf '%s' "$HOME/.zshrc" ;;
        bash) printf '%s' "$HOME/.bashrc" ;;
        *)
            if [ -f "$HOME/.zshrc" ]; then printf '%s' "$HOME/.zshrc"
            else printf '%s' "$HOME/.bashrc"; fi
            ;;
    esac
}

lcars_tmux_config() {
    if [ -n "${LCARS_TMUX_CONFIG:-}" ]; then
        printf '%s' "$LCARS_TMUX_CONFIG"
        return 0
    fi
    if [ -f "$HOME/.config/tmux/tmux.conf" ]; then
        printf '%s' "$HOME/.config/tmux/tmux.conf"
    else
        printf '%s' "$HOME/.tmux.conf"
    fi
}

# --- deletion safety ---------------------------------------------------------

lcars_remove_owned() {
    local path="$1"
    case "$path" in
        "$LCARS_DIR"/*) ;;
        *)
            lcars_warn "refusing to delete path outside LCARS dir: $path"
            return 0
            ;;
    esac
    [ -e "$path" ] || return 0
    if [ -d "$path" ]; then
        lcars_run rmdir "$path" 2>/dev/null || true
    else
        lcars_run rm -f "$path"
    fi
}

# --- install flows -----------------------------------------------------------

lcars_quote_value() {
    case "$1" in
        *[!A-Za-z0-9_/.:@%+=-]*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

lcars_install_files() {
    local repo="$1"
    lcars_step "Installing LCARS files -> $LCARS_DIR"
    lcars_ensure_dir "$LCARS_DIR"
    lcars_copy "$repo/ghostty/ghostty.conf" "$LCARS_DIR/ghostty/ghostty.conf"
    lcars_copy "$repo/ghostty/shaders/lcars-frame.glsl" "$LCARS_DIR/ghostty/shaders/lcars-frame.glsl"
    lcars_copy "$repo/ghostty/shaders/lcars-crt.glsl" "$LCARS_DIR/ghostty/shaders/lcars-crt.glsl"
    lcars_copy "$repo/ghostty/themes/lcars" "$LCARS_DIR/ghostty/themes/lcars"
    lcars_copy "$repo/prompt/starship.toml" "$LCARS_DIR/starship.toml"
    lcars_copy "$repo/fastfetch/config.jsonc" "$LCARS_DIR/fastfetch.jsonc"
    lcars_copy "$repo/tmux/lcars.conf" "$LCARS_DIR/tmux.conf"
    lcars_copy "$repo/shell/shell.sh" "$LCARS_DIR/shell.sh"
    lcars_copy "$repo/powershell/profile.ps1" "$LCARS_DIR/profile.ps1"
    local f
    for f in "$repo"/sounds/*.wav; do
        [ -f "$f" ] || continue
        lcars_copy "$f" "$LCARS_DIR/sounds/$(basename "$f")"
    done
    for f in "$repo"/assets/*.png; do
        [ -f "$f" ] || continue
        lcars_copy "$f" "$LCARS_DIR/assets/$(basename "$f")"
    done
    lcars_replace_token "$LCARS_DIR/ghostty/ghostty.conf" "__LCARS_DIR__" "$LCARS_DIR"
    lcars_replace_token "$LCARS_DIR/fastfetch.jsonc" "__LCARS_DIR__" "$LCARS_DIR"
}

lcars_ghostty_bin() {
    if command -v ghostty >/dev/null 2>&1; then
        command -v ghostty
        return 0
    fi
    if [ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]; then
        printf '%s' "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        return 0
    fi
    return 1
}

lcars_ghostty_check() {
    local bin ver nums major minor
    bin="$(lcars_ghostty_bin)" || {
        lcars_warn "Ghostty CLI not found — skipping version check"
        return 0
    }
    ver="$("$bin" +version 2>/dev/null | head -n 1)"
    nums="$(printf '%s' "$ver" | sed -n 's/.* \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
    [ -n "$nums" ] || return 0
    major="${nums%% *}"
    minor="${nums##* }"
    if [ "$major" -eq 0 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 2 ]; }; then
        lcars_warn "Ghostty $major.$minor detected — frame art needs 1.2+; palette/prompt still work"
    elif [ "$major" -eq 1 ] && [ "$minor" -lt 3 ] && [ "$(uname -s)" = "Darwin" ]; then
        lcars_warn "Ghostty $major.$minor — custom audio bell needs 1.3+ on macOS (system bell will be used)"
    fi
}

lcars_install_ghostty() {
    local cfg conf tmp
    cfg="$(lcars_ghostty_config)"
    conf="$LCARS_DIR/ghostty/ghostty.conf"
    if [ -z "${LCARS_GHOSTTY_CONFIG:-}" ] && [ ! -f "$cfg" ]; then
        if ! lcars_ghostty_bin >/dev/null 2>&1 && [ ! -d "$(dirname "$cfg")" ]; then
            lcars_warn "Ghostty not detected ($cfg) — skipping"
            if [ "$(uname -s)" = "Darwin" ]; then
                lcars_warn "install Ghostty first (brew install --cask ghostty), launch it once, then rerun"
            else
                lcars_warn "install Ghostty first, then rerun this installer"
            fi
            return 0
        fi
    fi
    lcars_step "Ghostty integration"
    lcars_ghostty_check
    tmp="$(mktemp)"
    printf 'config-file = %s\n' "$(lcars_quote_value "$conf")" > "$tmp"
    lcars_log "$cfg"
    lcars_block_upsert "$cfg" "$LCARS_MARK_START" "$LCARS_MARK_END" "$tmp"
    rm -f "$tmp"
}

lcars_install_shell() {
    local rc tmp
    rc="$(lcars_shell_rc)"
    lcars_step "Shell integration"
    tmp="$(mktemp)"
    {
        printf 'export LCARS_DIR=%s\n' "$(lcars_quote_value "$LCARS_DIR")"
        printf '[ -f "$LCARS_DIR/shell.sh" ] && . "$LCARS_DIR/shell.sh"\n'
    } > "$tmp"
    lcars_log "$rc"
    lcars_block_upsert "$rc" "$LCARS_MARK_START" "$LCARS_MARK_END" "$tmp"
    rm -f "$tmp"
}

lcars_install_tmux() {
    local tconf tmp
    tconf="$(lcars_tmux_config)"
    if ! command -v tmux >/dev/null 2>&1 && [ ! -f "$tconf" ]; then
        lcars_warn "tmux not found — skipping status bar theme"
        return 0
    fi
    lcars_step "tmux integration"
    tmp="$(mktemp)"
    printf 'source-file %s\n' "$(lcars_quote_value "$LCARS_DIR/tmux.conf")" > "$tmp"
    lcars_log "$tconf"
    lcars_block_upsert "$tconf" "$LCARS_MARK_START" "$LCARS_MARK_END" "$tmp"
    rm -f "$tmp"
}

lcars_hints() {
    lcars_step "Optional dependencies"
    command -v starship >/dev/null 2>&1 \
        || lcars_warn "starship not found — prompt inactive (macOS: brew install starship, Linux: https://starship.rs)"
    command -v fastfetch >/dev/null 2>&1 \
        || lcars_warn "fastfetch not found — splash inactive (macOS: brew install fastfetch, Linux: https://github.com/fastfetch-cli/fastfetch)"
    command -v tmux >/dev/null 2>&1 \
        || lcars_warn "tmux not found — status bar theme unused"
}

lcars_install() {
    local repo="$1"
    local with_ghostty="$2" with_shell="$3" with_tmux="$4"
    lcars_preflight

    if [ -f "$LCARS_MANIFEST" ] && [ "$LCARS_REINSTALL" != 1 ]; then
        lcars_die "LCARS already installed (manifest: $LCARS_MANIFEST). Use --reinstall to refresh files, or --uninstall first."
    fi
    if [ -d "$LCARS_DIR" ] && [ ! -f "$LCARS_MANIFEST" ]; then
        lcars_warn "$LCARS_DIR exists but has no LCARS manifest"
        lcars_confirm "Continue and let LCARS manage files in that directory?" \
            || lcars_die "aborted"
    fi

    if [ -f "$LCARS_MANIFEST" ]; then
        # reinstall: keep the original created/backup bookkeeping
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            LCARS_CREATED+=("$p")
        done <<EOF
$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" created "$LCARS_MANIFEST" 2>/dev/null)
EOF
        local prior_backup
        prior_backup="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" field "$LCARS_MANIFEST" backup_dir)"
        if [ -n "$prior_backup" ] && [ -d "$prior_backup" ]; then
            LCARS_BACKUP_DIR="$prior_backup"
        fi
        lcars_log "reinstalling over existing installation"
    fi

    lcars_install_files "$repo"
    [ "$with_ghostty" = 1 ] && lcars_install_ghostty
    [ "$with_shell" = 1 ] && lcars_install_shell
    [ "$with_tmux" = 1 ] && lcars_install_tmux

    if [ "$(type -t lcars_platform_install)" = "function" ]; then
        lcars_platform_install
    fi

    lcars_manifest_write
    lcars_hints
    lcars_step "Done"
    if lcars_dry; then
        lcars_log "dry-run complete — nothing was changed"
    else
        lcars_log "LCARS installed to $LCARS_DIR"
        lcars_log "restart your terminal(s) to see the theme"
        lcars_log "toggles: LCARS_SPLASH=0 (no splash), LCARS_SOUND=0 (no beeps)"
        lcars_log "uninstall: sh install/$(basename "$0") --uninstall"
    fi
}

lcars_uninstall() {
    local purge="$1" n=0
    lcars_preflight
    lcars_step "Uninstalling LCARS"

    if [ ! -f "$LCARS_MANIFEST" ]; then
        lcars_warn "no manifest at $LCARS_MANIFEST — best-effort removal"
    fi

    if [ -f "$LCARS_MANIFEST" ]; then
        while IFS="$LCARS_US" read -r path backup start end; do
            [ -n "$path" ] || continue
            if [ -f "$path" ] && grep -qF "$start" "$path"; then
                lcars_block_remove "$path" "$start" "$end"
                lcars_log "cleaned $path"
                n=$((n + 1))
            elif [ -f "$path" ]; then
                lcars_warn "marker missing in $path (hand-edited?) — leaving that file alone"
            fi
        done <<EOF
$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" patched "$LCARS_MANIFEST" 2>/dev/null)
EOF
    fi

    if [ "$(type -t lcars_platform_uninstall)" = "function" ]; then
        lcars_platform_uninstall
    fi

    if [ -f "$LCARS_MANIFEST" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in
                "$LCARS_DIR"/*)
                    lcars_remove_owned "$p"
                    ;;
                *)
                    if [ -f "$p" ] && ! grep -q '[^[:space:]]' "$p"; then
                        lcars_run rm -f "$p"
                        lcars_log "removed empty file $p"
                    fi
                    ;;
            esac
        done <<EOF
$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" created "$LCARS_MANIFEST" 2>/dev/null)
EOF
    fi

    if [ -d "$LCARS_DIR" ] && ! lcars_dry; then
        find "$LCARS_DIR" -type d 2>/dev/null | awk '{ print length, $0 }' \
            | sort -rn | cut -d' ' -f2- | while IFS= read -r d; do
            [ "$d" = "$LCARS_DIR" ] && continue
            case "$d" in
                */backups|*/backups/*) continue ;;
            esac
            rmdir "$d" 2>/dev/null || true
        done
    fi

    if [ "$purge" = 1 ]; then
        if [ -d "$LCARS_DIR" ]; then
            if [ -f "$LCARS_MANIFEST" ] || [ "$LCARS_ASSUME_YES" = 1 ]; then
                lcars_run rm -rf "$LCARS_DIR"
                lcars_log "purged $LCARS_DIR (including backups)"
            else
                lcars_warn "refusing to purge without a manifest; use --yes"
            fi
        fi
    fi

    [ -f "$LCARS_MANIFEST" ] && lcars_run rm -f "$LCARS_MANIFEST"

    lcars_step "Done"
    lcars_log "removed LCARS blocks ($n files)"
    if [ "$purge" != 1 ] && [ -d "$LCARS_DIR/backups" ]; then
        lcars_log "backups kept in $LCARS_DIR/backups (use --purge to remove)"
    fi
    lcars_log "restart your terminal(s) for a clean shell"
}

lcars_restore_cmd() {
    local ts="$1"
    lcars_preflight
    lcars_restore "$LCARS_MANIFEST" "$ts"
    if [ "$(type -t lcars_platform_restore)" = "function" ]; then
        lcars_platform_restore
    fi
    lcars_step "Done"
    if lcars_dry; then
        lcars_log "dry-run complete — nothing was changed"
    else
        lcars_log "files rolled back to their pre-install state"
        lcars_log "marked blocks are gone from restored files; run with --reinstall to re-enable LCARS"
    fi
}

# --- restore -----------------------------------------------------------------

lcars_restore() {
    local manifest="$1" ts="${2:-}" dir
    [ -f "$manifest" ] || lcars_die "no manifest found at $manifest"
    if [ -n "$ts" ]; then
        dir="$LCARS_DIR/backups/$ts"
        [ -d "$dir" ] || lcars_die "backup directory not found: $dir"
    else
        dir="$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" field "$manifest" backup_dir)"
        if [ -z "$dir" ] || [ ! -d "$dir" ]; then
            lcars_warn "no backup directory recorded (nothing needed backing up)"
            return 0
        fi
    fi
    lcars_log "restoring files from $dir"
    local path backup start end count=0
    while IFS="$LCARS_US" read -r path backup start end; do
        [ -n "$path" ] || continue
        local rel
        case "$path" in
            "$HOME"/*) rel="${path#"$HOME"/}" ;;
            *) rel="$(printf '%s' "$path" | sed 's|^/||')" ;;
        esac
        local src="$dir/$rel"
        if [ -f "$src" ]; then
            if lcars_dry; then
                printf '   [dry-run] restore %s\n' "$path"
            else
                cp "$src" "$path"
                lcars_log "restored $path"
            fi
            count=$((count + 1))
        fi
    done <<EOF
$("$LCARS_PYTHON" "$LCARS_LIB/manifest.py" patched "$manifest" 2>/dev/null)
EOF
    lcars_log "restored $count files"
}
