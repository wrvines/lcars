#!/usr/bin/env bash
# =============================================================================
# Black-box tests for the LCARS uninstaller (install/uninstall.sh)
# =============================================================================
# Runs entirely against a throwaway HOME, so it never touches your real
# config. Exercises the failure modes that used to make uninstall a no-op:
# a missing manifest, hand-edited markers, a deleted repository, partial
# installs, dry-run, purge, restore and double-uninstall.
#
#   bash tools/test-uninstall.sh
# =============================================================================

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/lcars-uninstall-test.$$"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

ok()  { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # check DESCRIPTION COMMAND...
    local desc="$1"
    shift
    if "$@"; then ok "$desc"; else bad "$desc"; fi
}

setup() {
    rm -rf "$WORK"
    mkdir -p "$WORK/home/.config/ghostty"
    export HOME="$WORK/home"
    unset LCARS_DIR
    export LCARS_GHOSTTY_CONFIG="$HOME/.config/ghostty/config"
    export LCARS_SHELL_RC="$HOME/.bashrc"
    export LCARS_TMUX_CONFIG="$HOME/.tmux.conf"
    printf '# ghostty\nfont-size = 12\n' > "$LCARS_GHOSTTY_CONFIG"
    printf '# bashrc\nexport FOO=1\n' > "$LCARS_SHELL_RC"
    printf '# tmux\nset -g mouse on\n' > "$LCARS_TMUX_CONFIG"
}

install() { sh "$REPO/install/linux.sh" --yes >/dev/null 2>&1; }
uninstall() { sh "$REPO/install/uninstall.sh" "$@" >/dev/null 2>&1; }
marker_count() { grep -hF '# >>> lcars >>>' "$LCARS_GHOSTTY_CONFIG" "$LCARS_SHELL_RC" "$LCARS_TMUX_CONFIG" 2>/dev/null | wc -l | tr -d ' '; }

echo "== 1. install then uninstall =="
setup; install
check "installer wrote 3 marked blocks" [ "$(marker_count)" = 3 ]
uninstall --yes
check "all marked blocks removed" [ "$(marker_count)" = 0 ]
check "manifest removed" [ ! -f "$HOME/.config/lcars/.lcars-install.json" ]
check "theme files removed" [ ! -f "$HOME/.config/lcars/ghostty/ghostty.conf" ]
check "user config preserved" grep -q 'font-size = 12' "$LCARS_GHOSTTY_CONFIG"

echo "== 2. manifest deleted: still cleans =="
setup; install
rm -f "$HOME/.config/lcars/.lcars-install.json"
uninstall --yes
check "blocks removed without manifest" [ "$(marker_count)" = 0 ]
check "known files removed without manifest" [ ! -f "$HOME/.config/lcars/starship.toml" ]

echo "== 3. installed copy survives a deleted repository =="
setup; install
check "installer shipped an uninstaller" [ -f "$HOME/.config/lcars/uninstall.sh" ]
( cd / && sh "$HOME/.config/lcars/uninstall.sh" --yes >/dev/null 2>&1 )
check "shipped uninstaller cleaned everything" [ "$(marker_count)" = 0 ]

echo "== 4. reinstall then uninstall =="
setup; install; install
check "reinstall did not duplicate blocks" [ "$(marker_count)" = 3 ]
uninstall --yes
check "uninstall after reinstall" [ "$(marker_count)" = 0 ]

echo "== 5. double uninstall is safe =="
setup; install
uninstall --yes
check "second uninstall exits 0" uninstall --yes

echo "== 6. purge removes backups and the directory =="
setup; install
uninstall --purge --yes
check "LCARS directory purged" [ ! -d "$HOME/.config/lcars" ]

echo "== 7. dry-run changes nothing =="
setup; install
before="$(cat "$LCARS_GHOSTTY_CONFIG")"
uninstall --dry-run --yes
check "dry-run kept the block" [ "$(marker_count)" = 3 ]
check "dry-run kept file contents" [ "$before" = "$(cat "$LCARS_GHOSTTY_CONFIG")" ]

echo "== 8. hand-edited marker is reported =="
setup; install
sed -i.bak '/# >>> lcars >>>/d' "$LCARS_GHOSTTY_CONFIG"
OUT="$(sh "$REPO/install/uninstall.sh" --yes 2>&1)"
check "orphaned LCARS reference is flagged" bash -c "printf '%s' \"\$1\" | grep -qi 'still references LCARS'" _ "$OUT"
check "uninstall still removes the manifest" [ ! -f "$HOME/.config/lcars/.lcars-install.json" ]

echo "== 9. restore rolls files back =="
setup; install
sh "$REPO/install/linux.sh" --restore --yes >/dev/null 2>&1
check "restore removed the block" bash -c "! grep -qF '# >>> lcars >>>' '$LCARS_GHOSTTY_CONFIG'"
check "restore kept original content" grep -q 'font-size = 12' "$LCARS_GHOSTTY_CONFIG"

echo "== 10. delegated installer flags =="
setup; install
sh "$REPO/install/linux.sh" --uninstall --yes >/dev/null 2>&1
check "linux.sh --uninstall delegates" [ "$(marker_count)" = 0 ]

echo "== 11. custom install directory =="
setup
export LCARS_DIR="$HOME/custom-lcars"
sh "$REPO/install/linux.sh" --yes >/dev/null 2>&1
check "installer honoured custom LCARS_DIR" [ -f "$LCARS_DIR/ghostty/ghostty.conf" ]
unset LCARS_DIR
sh "$REPO/install/uninstall.sh" --dir "$HOME/custom-lcars" --purge --yes >/dev/null 2>&1
check "uninstaller cleaned custom dir" [ ! -d "$HOME/custom-lcars" ]
check "user config preserved after custom uninstall" grep -q 'font-size = 12' "$LCARS_GHOSTTY_CONFIG"

echo "== 12. shipped copy self-locates custom dir without manifest =="
setup
export LCARS_DIR="$HOME/custom-lcars"
sh "$REPO/install/linux.sh" --yes >/dev/null 2>&1
rm -f "$LCARS_DIR/.lcars-install.json"
unset LCARS_DIR
sh "$HOME/custom-lcars/uninstall.sh" --purge --yes >/dev/null 2>&1
check "custom dir cleaned by shipped copy" [ ! -d "$HOME/custom-lcars" ]
check "marked blocks removed" [ "$(marker_count)" = 0 ]

echo "== 13. uninstall-macos.sh delegates from the repo =="
setup; install
sh "$REPO/uninstall-macos.sh" --yes >/dev/null 2>&1
check "delegated and cleaned" [ "$(marker_count)" = 0 ]
check "manifest removed" [ ! -f "$HOME/.config/lcars/.lcars-install.json" ]

echo "== 14. uninstall-macos.sh rescue path (copied alone, old install) =="
setup
export LCARS_GHOSTTY_CONFIG="$HOME/.config/ghostty/config"
export LCARS_SHELL_RC="$HOME/.zshrc"
export LCARS_TMUX_CONFIG="$HOME/.tmux.conf"
# simulate an OLD install: blocks + files, no shipped uninstaller, no manifest
printf 'font-size = 12\n\n# >>> lcars >>>\nconfig-file = x\n# <<< lcars <<<\n' > "$LCARS_GHOSTTY_CONFIG"
printf '# zshrc\n\n# >>> lcars >>>\nexport LCARS_DIR=x\n# <<< lcars <<<\n' > "$LCARS_SHELL_RC"
printf 'set -g mouse on\n' > "$LCARS_TMUX_CONFIG"
mkdir -p "$HOME/.config/lcars/sounds"
echo x > "$HOME/.config/lcars/starship.toml"
echo x > "$HOME/.config/lcars/sounds/lcars-ok.wav"
RESCUE="$WORK/alone"
mkdir -p "$RESCUE"
cp "$REPO/uninstall-macos.sh" "$RESCUE/uninstall-macos.sh"
( cd "$RESCUE" && sh uninstall-macos.sh >/dev/null 2>&1 )
check "rescue removed all blocks" [ "$(marker_count)" = 0 ]
check "rescue preserved user content" bash -c "grep -q 'font-size = 12' '$HOME/.config/ghostty/config' && grep -q '# zshrc' '$HOME/.zshrc'"
check "rescue removed theme files" [ ! -f "$HOME/.config/lcars/starship.toml" ]

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
