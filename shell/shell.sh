#!/usr/bin/env bash
# =============================================================================
# LCARS shell integration for zsh and bash
# =============================================================================
# Sourced from a marked block in your shell rc by the installer. Everything is
# optional and degrades gracefully: missing starship/fastfetch/audio players
# are simply skipped.
#
# Toggles (export before the shell starts, or set in your rc):
#   LCARS_SPLASH=0   disable the fastfetch splash
#   LCARS_SOUND=0    disable prompt beeps
# =============================================================================

LCARS_DIR="${LCARS_DIR:-$HOME/.config/lcars}"

# --- Starship prompt ---------------------------------------------------------

export STARSHIP_CONFIG="$LCARS_DIR/starship.toml"
if command -v starship >/dev/null 2>&1; then
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval "$(starship init zsh)"
    elif [ -n "${BASH_VERSION:-}" ]; then
        eval "$(starship init bash)"
    fi
fi

# --- splash (once per shell) -------------------------------------------------

if [ -z "${LCARS_SPLASH_SHOWN:-}" ]; then
    export LCARS_SPLASH_SHOWN=1
    if [ "${LCARS_SPLASH:-1}" != "0" ] && command -v fastfetch >/dev/null 2>&1; then
        case "${TERM_PROGRAM:-}${TERM:-}" in
            *[Gg]hostty*)
                # Ghostty speaks the Kitty graphics protocol: show the panel.
                fastfetch --config "$LCARS_DIR/fastfetch.jsonc" 2>/dev/null \
                    || fastfetch --config "$LCARS_DIR/fastfetch.jsonc" --logo none
                ;;
            *)
                # Terminal.app and friends: text-only splash.
                fastfetch --config "$LCARS_DIR/fastfetch.jsonc" --logo none 2>/dev/null || true
                ;;
        esac
    fi
fi

# --- prompt beeps ------------------------------------------------------------

__lcars_play() {
    case "$(uname -s)" in
        Darwin)
            command -v afplay >/dev/null 2>&1 && afplay "$1" >/dev/null 2>&1 &
            ;;
        *)
            if command -v paplay >/dev/null 2>&1; then
                paplay "$1" >/dev/null 2>&1 &
            elif command -v aplay >/dev/null 2>&1; then
                aplay -q "$1" >/dev/null 2>&1 &
            elif command -v ffplay >/dev/null 2>&1; then
                ffplay -nodisp -autoexit -loglevel quiet "$1" >/dev/null 2>&1 &
            fi
            ;;
    esac
}

__lcars_prompt_sound() {
    local lcars_status=$?
    if [ "${LCARS_SOUND:-1}" != "0" ] && [ -n "${LCARS_BEEP_ARMED:-}" ]; then
        if [ "$lcars_status" -eq 0 ]; then
            __lcars_play "$LCARS_DIR/sounds/lcars-ok.wav"
        else
            __lcars_play "$LCARS_DIR/sounds/lcars-alert.wav"
        fi
    fi
    LCARS_BEEP_ARMED=1
}

if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd __lcars_prompt_sound
elif [ -n "${BASH_VERSION:-}" ]; then
    case ";${PROMPT_COMMAND:-};" in
        *";__lcars_prompt_sound;"*) ;;
        *) PROMPT_COMMAND="__lcars_prompt_sound${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
fi
