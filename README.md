# LCARS Terminal Theme

A Star Trek: The Next Generation console for three terminals:

| Terminal | Platform | Palette | Frame art | Shader | Prompt | Splash | Beeps |
|---|---|---|---|---|---|---|---|
| **Ghostty** | macOS / Linux | ✅ | ✅ | ✅ | ✅ | ✅ image | ✅ custom bell |
| **Terminal.app** | macOS | ✅ | ✅ (dimmed) | — | ✅ | text | ✅ |
| **Windows Terminal** | Windows | ✅ | ✅ | — | ✅ | text | ✅ |

The look comes from four layers: an LCARS color palette, generated frame art
(PNG) behind the terminal grid, a Starship prompt made of pills, and optional
extras (fastfetch splash panel, tmux status bar, LCARS chirps).

Everything is reversible. The installers never rewrite your config files —
they append marked blocks that `--uninstall` removes surgically, and they
snapshot anything they touch before touching it.

---

## Requirements

- **Python 3** — the installers use it for the manifest; the asset generator
  uses only the standard library (no pip installs).
- **Ghostty 1.2+** for the background frame (`background-image`),
  **1.3+ on macOS** for the custom audio bell. Older versions still get the
  palette, prompt, and splash.
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

Always rehearsable and reversible:

```sh
sh install/linux.sh --dry-run      # show every change, touch nothing
sh install/linux.sh --uninstall    # remove blocks + LCARS files
sh install/linux.sh --uninstall --purge   # also delete backups
sh install/linux.sh --restore      # roll files back to pre-install state
sh install/linux.sh --restore 20260919-193010   # a specific backup stamp
sh install/linux.sh --reinstall    # refresh files over an existing install
```

`macos.sh` and `windows.ps1` accept the same options (PowerShell uses
`-DryRun`, `-Uninstall`, `-Purge`, `-Restore`, `-RestoreStamp`, `-Reinstall`).

After installing, open a new terminal window/tab.

### What the installer changes

| Where | What | How it is undone |
|---|---|---|
| `~/.config/lcars` (macOS/Linux), `%LOCALAPPDATA%\lcars` (Windows) | owned outright: themes, frame art, sounds, starship/fastfetch config | directory removed (backups kept unless `--purge`) |
| Ghostty `config` | `config-file = .../ghostty.conf` inside a `# >>> lcars >>>` block | block removed |
| `~/.zshrc` / `~/.bashrc` | source line inside a marked block | block removed |
| `~/.tmux.conf` or `~/.config/tmux/tmux.conf` | `source-file` inside a marked block | block removed |
| PowerShell `$PROFILE` | `#region`-style marked block dot-sourcing `profile.ps1` | block removed |
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

### Frame art

Generated variants: 16:9, 21:9, 4:3 (each with an `@2x` retina version) plus a
dimmed variant for Terminal.app. Pick a different one by editing the
`background-image` line in the installed `ghostty/ghostty.conf` (Ghostty) or
`backgroundImage` in Windows Terminal.

- **Alignment**: Ghostty stretches the image to the window, and terminal
  padding is fixed in points, so the frame aligns exactly only at the design
  sizes. Keep `window-padding-x = 48` or increase it; for exotic window sizes,
  regenerate the art with a matching canvas by editing the `jobs` list in
  `tools/generate.py`.
- **Terminal.app**: the background image cannot be installed by a script
  (macOS stores it as a bookmark blob). Set it once in *Terminal → Settings →
  Profiles → LCARS → Text → Background → Image → Choose…* using
  `assets/lcars-frame-termapp@2x.png` (on macOS 15 and earlier this setting is
  under *Window → Background Image*). It is deliberately dimmed because
  Terminal.app has no text padding. The splash overlay is skipped there.

### Shader (Ghostty only)

`ghostty/shaders/lcars-crt.glsl` adds subtle scanlines and a vignette. Tune the
defines at the top of the file, or disable it by commenting the
`custom-shader` line. Invalid shaders can blank the window — if that happens,
unset `custom-shader` and reload.

### Prompt

`prompt/starship.toml` defines the pill segments. It is loaded through
`STARSHIP_CONFIG`, so your own `starship.toml` keeps working elsewhere.

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
- **Ghostty older than 1.2** — background images and the audio bell are
  unavailable; everything else works.
- **Frame text overlap** — raise `window-padding-x`/`window-padding-y` in the
  installed `ghostty.conf` (values are points, so they don't scale with the
  window; on a 2x display 48 points = 96 physical pixels).
- **Windows Terminal didn't change** — the installer patches the settings.json
  it finds (Store, Preview, or unpackaged). If your install is in a different
  location, pass `-SettingsPath`. WT reloads automatically; open a new tab.
- **Terminal.app profile** — if Terminal was running during uninstall, remove
  the profile manually: *Settings → Profiles → LCARS → ⊖*.
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
ghostty/                        theme, config, CRT shader
terminal-app/LCARS.terminal     generated Terminal.app profile
windows/                        WT color scheme + profile snippet
prompt/starship.toml            shared prompt for zsh/bash/PowerShell
fastfetch/config.jsonc          splash config (Kitty image on Ghostty)
tmux/lcars.conf                 status bar theme
shell/shell.sh                  zsh/bash integration
powershell/profile.ps1          PowerShell integration
assets/, sounds/                generated at build time
install/                        per-OS installers with manifest + backups
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
