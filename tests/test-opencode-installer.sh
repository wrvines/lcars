#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_installer() {
    local case_dir="$1"
    shift
    env \
        HOME="$case_dir/home" \
        XDG_CONFIG_HOME="$case_dir/config" \
        LCARS_DIR="$case_dir/lcars" \
        bash "$ROOT/install/linux.sh" --yes --no-ghostty --no-shell --no-tmux "$@" \
        >"$case_dir/output.log" 2>&1
}

assert_file_equals() {
    local path="$1" expected="$2"
    [ -f "$path" ] || { echo "expected file: $path" >&2; exit 1; }
    [ "$(cat "$path")" = "$expected" ] || { echo "unexpected contents: $path" >&2; exit 1; }
}

# A dry-run must leave both the OpenCode config and LCARS install untouched.
new_case="$TEST_ROOT/new-theme"
mkdir -p "$new_case/home"
run_installer "$new_case" --dry-run
new_theme="$new_case/config/opencode/themes/lcars.json"
[ ! -e "$new_theme" ]
[ ! -e "$new_case/lcars" ]

# Install, reinstall, restore, then uninstall a theme that did not exist before.
run_installer "$new_case"
[ -f "$new_theme" ]
python3 - "$new_case/lcars/.lcars-install.json" "$new_theme" <<'PY'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
entry, = manifest["managed_files"]
assert entry["path"] == sys.argv[2]
assert entry["backup"] == ""
assert entry["config_dir_created"] is True
assert entry["themes_dir_created"] is True
PY
before="$(sha256sum "$new_theme" | cut -d' ' -f1)"
run_installer "$new_case" --reinstall --dry-run
[ "$(sha256sum "$new_theme" | cut -d' ' -f1)" = "$before" ]
run_installer "$new_case" --reinstall
run_installer "$new_case" --restore --dry-run
[ -f "$new_theme" ]
run_installer "$new_case" --restore
[ ! -e "$new_theme" ]
[ ! -e "$new_case/config/opencode/themes" ]
[ ! -e "$new_case/config/opencode" ]
run_installer "$new_case" --reinstall
run_installer "$new_case" --uninstall
[ ! -e "$new_theme" ]
[ ! -e "$new_case/config/opencode/themes" ]

# Preserve and restore an existing theme across reinstall, dry-run, restore,
# and uninstall. Directories that predated LCARS must remain in place.
existing_case="$TEST_ROOT/existing-theme"
mkdir -p "$existing_case/home" "$existing_case/config/opencode/themes"
existing_theme="$existing_case/config/opencode/themes/lcars.json"
printf '%s\n' 'user theme contents' > "$existing_theme"
run_installer "$existing_case" --dry-run
assert_file_equals "$existing_theme" 'user theme contents'
[ ! -e "$existing_case/lcars" ]
run_installer "$existing_case"
cmp -s "$ROOT/opencode/lcars.json" "$existing_theme"
python3 - "$existing_case/lcars/.lcars-install.json" <<'PY'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
entry, = manifest["managed_files"]
assert entry["backup"] and pathlib.Path(entry["backup"]).is_file()
assert pathlib.Path(entry["backup"]).read_text() == "user theme contents\n"
assert entry["config_dir_created"] is False
assert entry["themes_dir_created"] is False
PY
backup="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["managed_files"][0]["backup"])' "$existing_case/lcars/.lcars-install.json")"
stamp="$(python3 -c 'import json,sys,pathlib; print(pathlib.Path(json.load(open(sys.argv[1]))["backup_dir"]).name)' "$existing_case/lcars/.lcars-install.json")"
run_installer "$existing_case" --reinstall --dry-run
cmp -s "$ROOT/opencode/lcars.json" "$existing_theme"
assert_file_equals "$backup" 'user theme contents'
run_installer "$existing_case" --reinstall
run_installer "$existing_case" --restore "$stamp" --dry-run
cmp -s "$ROOT/opencode/lcars.json" "$existing_theme"
run_installer "$existing_case" --restore "$stamp"
assert_file_equals "$existing_theme" 'user theme contents'
[ -d "$existing_case/config/opencode/themes" ]
run_installer "$existing_case" --reinstall
run_installer "$existing_case" --uninstall
assert_file_equals "$existing_theme" 'user theme contents'

echo "OpenCode installer rollback checks passed"
