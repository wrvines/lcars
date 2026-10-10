# LCARS Terminal Theme

A Star Trek: The Next Generation console for three terminals:

| Terminal | Platform | Palette | Frame | Shader | Prompt | Splash | Beeps |
|---|---|---|---|---|---|---|---|
| **Ghostty** | macOS / Linux | ✅ | ✅ size-aware shader | ✅ CRT | ✅ | ✅ image | ✅ custom bell |
| **Terminal.app** | macOS | ✅ | ✅ dimmed PNG | — | ✅ | text | ✅ |
| **Windows Terminal** | Windows | ✅ | ✅ PNG | — | ✅ | text | ✅ |

The look comes from four layers: an LCARS color palette, an LCARS frame, a
Starship prompt made of pills, and optional extras (fastfetch splash panel,
tmux status bar, LCARS chirps).

On Ghostty the frame is drawn by a shader, so it hugs the window edge at any
size and stays visible over full-screen apps. The other terminals use
generated frame art (PNG) behind the terminal grid.

Everything is reversible. The installers never rewrite your config files —
they append marked blocks that the uninstaller removes surgically, and they
snapshot anything they touch before touching it. A self-contained uninstaller
is installed alongside the theme (`~/.config/lcars/uninstall.sh`, or
`%LOCALAPPDATA%\lcars\uninstall.ps1`), so you can remove LCARS even after
deleting this repository — you do not need the manifest or the original clone.

---

## Requirements

- **Python 3** — the installers use it for the manifest; the asset generator
  uses only the standard library (no pip installs).
- **Ghostty** for the frame, prompt, and splash (**1.2+** only if you switch
  the frame to the PNG `background-image` fallback). **1.3+ on macOS** for the
  custom audio bell. Older versions still get the palette, prompt, and splash.
- Optional, detected but not required: `starship`, `fastfetch`, `tmux`.
  The installers print hints if they are missing.

## Quick start

Clone or download this repository, then run the installer for your platform.

```sh
# Linux
sh install/linux.sh

# macOS (Ghostty + Terminal.app)
sh install/macos.sh

# Windows (Windows Terminal + PowerShell)
powershell -ExecutionPolicy Bypass -File install\windows.ps1
```

### Uninstalling

The simplest way is from this repository:

```sh
sh uninstall.sh                       # macOS / Linux
# or: sh install/linux.sh --uninstall
#     sh install/macos.sh --uninstall
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File install\windows.ps1 -Uninstall
```

The uninstaller is **self-contained**: it finds the marked config blocks and
the theme files by itself, so it works whether or not the install manifest is
still present.

If you installed (or ran `--reinstall`) with this version, the installer also
dropped a copy next to the theme, so you can uninstall without the repository:

```sh
sh ~/.config/lcars/uninstall.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\lcars\uninstall.ps1"
```

If that file is missing — for example your install predates this version — use
the repository commands above. (Reinstalling is not required: the repository
script uninstalls an older install just as well.)

**Run the uninstaller on the machine where LCARS is installed.** These scripts
only change the computer they run on, so a Linux repo cannot clean up a Mac.
If the repository (or the shipped copy above) is not on the machine you want to
clean, do one of these on *that* machine:

- clone this repository there and run `sh uninstall.sh`; or
- copy the single self-contained file
  [`uninstall-macos.sh`](uninstall-macos.sh) across and run it — this is the
  one-file macOS uninstaller, useful when you only have this repo on another
  machine:

  ```sh
  # on the machine that has the repo (e.g. a Linux box):
  scp uninstall-macos.sh you@mac.local:~/

  # on the Mac:
  sh ~/uninstall-macos.sh --dry-run   # preview
  sh ~/uninstall-macos.sh             # remove LCARS
  sh ~/uninstall-macos.sh --purge     # also delete backups
  ```

  It hands off to the full uninstaller when one is present (the repo's
  `install/uninstall.sh` or `~/.config/lcars/uninstall.sh`), and otherwise
  removes the marked blocks, the theme files and the Terminal.app profile by
  itself. It needs nothing else from the repository, and works on an old
  install with no manifest. (Any platform can copy `install/uninstall.sh` the
  same way; it is self-contained too.); or
- remove it by hand:

```sh
# 1. remove the marked block from each config file (repeat for your files)
for f in ~/.zshrc ~/.bashrc ~/.config/ghostty/config \
         "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
         ~/.tmux.conf ~/.config/tmux/tmux.conf; do
  [ -f "$f" ] || continue
  awk '/# >>> lcars >>>/{s=1;next} /# <<< lcars <<</{s=0;next} !s' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
# 2. delete the theme files
rm -rf ~/.config/lcars
# 3. macOS only: quit Terminal, then remove the profile (optional)
/usr/libexec/PlistBuddy -c "Delete :Window Settings:LCARS" \
  ~/Library/Preferences/com.apple.Terminal.plist 2>/dev/null
killall cfprefsd 2>/dev/null
```

Then open a new terminal window/tab. The uninstaller removes the marked blocks
from your shell rc, Ghostty config, tmux config and PowerShell profile; removes
the LCARS files; restores the default profile it changed (Windows Terminal,
Terminal.app); and deletes the manifest. Backups are kept in
`<lcars dir>/backups/` unless you ask for `--purge` (`-Purge` on Windows).

Useful flags (all platforms; PowerShell uses `-DryRun`, `-Yes`, `-Purge`):

```sh
sh ~/.config/lcars/uninstall.sh --dry-run   # show every change, touch nothing
sh ~/.config/lcars/uninstall.sh --yes       # no prompts
sh ~/.config/lcars/uninstall.sh --purge     # also delete backups + the LCARS dir
sh ~/.config/lcars/uninstall.sh --restore   # roll files back to pre-install state
sh ~/.config/lcars/uninstall.sh --dir ~/.config/lcars   # custom install directory
```

If you installed to a custom `LCARS_DIR`, pass `--dir` (or set `LCARS_DIR`) so
the uninstaller looks in the right place. Nothing is destroyed that LCARS did
not create: the uninstaller only deletes files under the LCARS directory and
only edits files that still contain the `# >>> lcars >>>` marker.

Two cases where cleanup cannot be fully automatic:

- **Terminal.app was open** — macOS caches the profile list while it runs, so
  quit Terminal and rerun, or remove the profile by hand:
  *Terminal → Settings → Profiles → LCARS → ⊖*.
- **You edited a marked block by hand** and broke the marker — the uninstaller
  warns about the file instead of guessing. Remove the leftover LCARS lines
  manually; the warning names the file.

### Other modes

These are alternatives, not a sequence — run the one you want, substituting
your platform's script for `linux.sh` (`macos.sh`; or `windows.ps1` with
single-dash flags `-DryRun`, `-Restore`, `-RestoreStamp`, `-Reinstall`):

```sh
sh install/linux.sh --dry-run      # show every change, touch nothing
sh install/linux.sh --restore      # roll files back to pre-install state
sh install/linux.sh --restore 20260919-193010   # a specific backup stamp
sh install/linux.sh --reinstall    # refresh files over an existing install
```

`--dry-run` combines with any mode, e.g. `--uninstall --dry-run`. `--restore`
and `--reinstall` need the manifest, so they stop working once you have
uninstalled; `--reinstall` recreates everything from the repository.

After installing, open a new terminal window/tab.

### What the installer changes

| Where | What | How it is undone |
|---|---|---|
| `~/.config/lcars` (macOS/Linux), `%LOCALAPPDATA%\lcars` (Windows) | owned outright: themes, frame art, sounds, starship/fastfetch config, **and the uninstaller itself** | directory removed (backups kept unless `--purge`) |
| Ghostty `config` | `config-file = .../ghostty.conf` inside a `# >>> lcars >>>` block | block removed |
| `~/.zshrc` / `~/.bashrc` | source line inside a marked block | block removed |
| `~/.tmux.conf` or `~/.config/tmux/tmux.conf` | `source-file` inside a marked block | block removed |
| PowerShell `$PROFILE` | marked block dot-sourcing `profile.ps1` | block removed |
| `~/.config/starship.toml` | **never touched** — `STARSHIP_CONFIG` is set inside the block | env var disappears with the block |
| Windows Terminal `settings.json` | `LCARS` scheme + profile (fixed GUID), default profile set | entries removed, previous default restored |
| Terminal.app | profile imported, set as default | profile removed, previous default restored |

Backups live in `\<lcars dir\>/backups/<timestamp>/` and mirror the original
paths. `--restore` copies them back; you can also do it by hand.

## Customizing

### Colors

The single source of truth is `palette/lcars.json`. Change a hex value, then:

```sh
python3 tools/generate.py                 # regenerate frame art + sounds
python3 tools/make_terminal_profile.py    # regenerate terminal-app/LCARS.terminal
sh install/linux.sh --reinstall           # refresh the installed copies
```

`tools/generate.py` also takes `--preview` to render an ASCII preview of the
frame and splash right in your terminal.

### Frame

On Ghostty the frame is a post-process shader, `ghostty/shaders/lcars-frame.glsl`:

- **Size-aware**: it is drawn in the window, not stretched with an image. The
  band thickness follows the window height (clamped), so it stays aligned at
  any window size, aspect ratio, or DPI. The corner radius scales with the
  same band, and `window-padding-x/y` only need to clear it — the shipped
  values (`48` / `40`) hold everywhere.
- **Always visible**: custom shaders run over the rendered screen, so the
  frame shows through tmux, editors, and any other app that paints opaque
  backgrounds. A background image would be covered by those apps.
- **Tuning**: the defines at the top of the file control the thickness
  (`BAND_FRACTION`, `BAND_MIN`, `BAND_MAX`) and corner radius
  (`CORNER_FRACTION`). If you widen the band, raise `window-padding-x/y` to
  match. Colors are palette values, so `python3 tools/check.py` keeps them in
  sync with `palette/lcars.json`.

The generated PNG art (`tools/generate.py`) is still used by Terminal.app and
Windows Terminal. It can also replace the shader on Ghostty: comment the
`lcars-frame.glsl` `custom-shader` line in `ghostty.conf` and uncomment the
`background-image` block there.

- **PNG alignment**: Ghostty stretches the image to the window and terminal
  padding is fixed in points, so the art aligns exactly only at its design
  size (16:9, 21:9, 4:3). For exotic window sizes, regenerate the art with a
  matching canvas by editing the `jobs` list in `tools/generate.py`.
- **Terminal.app**: the background image cannot be installed by a script
  (macOS stores it as a bookmark blob). Set it once in *Terminal → Settings →
  Profiles → LCARS → Text → Background → Image → Choose…* using
  `assets/lcars-frame-termapp@2x.png` (on macOS 15 and earlier this setting is
  under *Window → Background Image*). It is deliberately dimmed because
  Terminal.app has no text padding. The splash overlay is skipped there.

### Shader (Ghostty only)

Two passes ship: `lcars-frame.glsl` (the frame) and `lcars-crt.glsl` (subtle
scanlines and vignette). Tune the defines at the top of each file, or disable
a pass by commenting its `custom-shader` line. Invalid shaders can blank the
window — if that happens, unset `custom-shader` and reload.

### Prompt

`prompt/starship.toml` defines the pill segments. It is loaded through
`STARSHIP_CONFIG`, so your own `starship.toml` keeps working elsewhere.

### opencode TUI

`opencode/lcars.json` is a drop-in [opencode](https://opencode.ai) theme built
from the bundled `opencode` theme with two LCARS changes: the text you type is
ice (`#99CCFF`) and bold items in replies are sunset (`#FF9900`). The cool input
color keeps what you type distinct from the warm emphasis in replies.

```sh
mkdir -p ~/.config/opencode/themes
cp opencode/lcars.json ~/.config/opencode/themes/
# then set "theme": "lcars" in ~/.config/opencode/tui.json, or use /themes
```

### Sound

Three generated chirps: `lcars-confirm` (shell ready), `lcars-ok` (success),
`lcars-alert` (non-zero exit). Ghostty's audio bell points at `lcars-confirm`;
the shell prompt plays ok/alert. Disable everything with `LCARS_SOUND=0`, or
disable just the splash with `LCARS_SPLASH=0`. Volume lives in
`bell-audio-volume` in `ghostty.conf`.

## Troubleshooting

- **Ghostty shows a config error** — run `ghostty +validate-config`. Config
  locations: `~/.config/ghostty/config` (Linux),
  `~/Library/Application Support/com.mitchellh.ghostty/config` (macOS).
- **Ghostty older than 1.2** — the PNG frame fallback and the audio bell are
  unavailable; the shader frame, palette, prompt, and splash still work.
- **Frame text overlap** — with the shader frame the shipped padding always
  clears the band; if you raise `BAND_FRACTION`/`BAND_MAX` in
  `lcars-frame.glsl`, raise `window-padding-x/y` to match. If you switched to
  the PNG art, padding is in points and does not scale with the window, so
  tall or high-DPI windows need larger values (on a 2x display 48 points = 96
  physical pixels).
- **Frame disappears in tmux / an editor** — that is the PNG art being covered
  by the app's background. Check which layer is active:
  `ghostty +show-config | grep -E 'background-image|custom-shader'`. The
  shader frame (the default) cannot be covered by apps.
- **Windows Terminal didn't change** — the installer patches the settings.json
  it finds (Store, Preview, or unpackaged). If your install is in a different
  location, pass `-SettingsPath`. WT reloads automatically; open a new tab.
- **Terminal.app profile** — if Terminal was running during uninstall, quit it
  and rerun `sh ~/.config/lcars/uninstall.sh`, or remove the profile manually:
  *Settings → Profiles → LCARS → ⊖*.
- **Uninstall did nothing / "no manifest found"** — that is fine: the
  uninstaller also works without the manifest. If it still finds nothing,
  point it at your install directory with `--dir` (or `-LcarsDir` on Windows),
  e.g. `sh ~/.config/lcars/uninstall.sh --dir ~/.config/lcars`.
- **`sh: install/macos.sh: No such file or directory`** — you are not in the
  repository root, or the repo is not on the machine you ran the command on.
  The scripts only affect the computer they run on; run them on the machine
  where LCARS is installed (see [Uninstalling](#uninstalling)).
- **`sh ~/.config/lcars/uninstall.sh` → "No such file"** — the shipped copy
  only exists if you installed with a version that includes it. Run
  `sh uninstall.sh` from the repository instead. If the repository is also
  gone, remove the `# >>> lcars >>>` … `# <<< lcars <<<` block from your shell
  rc, Ghostty config and tmux config, then delete `~/.config/lcars` by hand.
- **A leftover `lcars` line after uninstall** — a marked block was edited by
  hand and lost its `# >>> lcars >>>` marker. The uninstaller names the file in
  a warning; delete the leftover lines and rerun.
- **Command not found: starship / fastfetch** — install them and restart the
  shell: `brew install starship fastfetch` (macOS), `winget install
  Starship.Starship fastfetch` (Windows), or see
  [starship.rs](https://starship.rs) / [fastfetch](https://github.com/fastfetch-cli/fastfetch).
- **LCARS fonts (Antonio, Okuda, LCARS GTJ3) look broken in the terminal** —
  they are proportional display fonts and break the character grid. The theme
  uses a monospace font for text and bakes real LCARS-style lettering into the
  generated art instead.

## Repository layout

```
palette/lcars.json              canonical colors (edit me)
tools/generate.py               frame art + splash + beeps (stdlib only)
tools/make_terminal_profile.py  Terminal.app profile generator
tools/check.py                  repo self-check (run before shipping changes)
ghostty/                        theme, config, frame + CRT shaders
terminal-app/LCARS.terminal     generated Terminal.app profile
windows/                        WT color scheme + profile snippet
opencode/lcars.json             opencode TUI theme (ice input, sunset bold)
prompt/starship.toml            shared prompt for zsh/bash/PowerShell
fastfetch/config.jsonc          splash config (Kitty image on Ghostty)
tmux/lcars.conf                 status bar theme
shell/shell.sh                  zsh/bash integration
powershell/profile.ps1          PowerShell integration
assets/, sounds/                generated at build time
install/                        per-OS installers with manifest + backups
install/uninstall.sh            self-contained uninstaller (macOS/Linux)
install/uninstall.ps1           self-contained uninstaller (Windows)
uninstall.sh, uninstall.ps1     repo-root uninstall entry points
uninstall-macos.sh              single-file macOS uninstaller (copy anywhere)
tools/test-uninstall.sh         uninstaller test suite
```

Validate everything after edits with:

```sh
python3 tools/check.py
```

## Credits

Fan project. LCARS, Star Trek, and related marks are trademarks of
CBS/Paramount. All art and sounds here are generated from scratch by the
scripts in this repository; the palette is an interpretation of the
Okudagram aesthetic for terminal use.
