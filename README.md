# Windows Terminal Modernization Script

Windows Terminal Modernization Script contains my preferred Windows terminal setup for Command Prompt, powered by:

- **Clink** (line editing, history autosuggestions, completions): <https://github.com/chrisant996/clink>
- **Starship** (fast, modern prompt): <https://github.com/starship/starship>
- **clink-completions** (community completion scripts): <https://github.com/vladimir-kotikov/clink-completions>
- **Nerd Fonts** (icon-enabled fonts; FiraCode Nerd Font): <https://github.com/ryanoasis/nerd-fonts>
- **Windows Terminal** (recommended host): <https://github.com/microsoft/terminal>

The goal is to make a clean Command Prompt experience that feels modern while staying lightweight and reliable.

## Why this exists

On macOS and Linux, a good-looking and highly functional terminal experience is often close to the default. On Windows, getting a comparable setup usually takes a lot of manual customization across multiple tools (prompt theming, fonts, completion, autosuggestions, and terminal profile tweaks). This project aims to be a one-click solution that installs and configures everything in a consistent way, so a fresh Windows install can be ready quickly.

## What this installs and configures

The PowerShell installer script (`setup.ps1`) does the following:

1. Verifies **Git** is installed and available on PATH  
   - If Git is missing, the script stops and tells you to install Git first.

2. Installs required packages using **winget**  
   - Clink  
   - Starship  
   winget reference: <https://learn.microsoft.com/windows/package-manager/winget/>

3. Integrates Starship into Command Prompt through Clink  
   - Creates a Clink Lua script to load `starship init cmd` automatically.

4. Installs clink-completions  
   - Clones (or updates) the `clink-completions` repository.
   - Registers it with Clink so completion scripts are loaded.
   - Treats already-installed registration as a non-fatal state.

5. Installs Nerd Fonts (FiraCode Nerd Font)  
   - Downloads the zip release and installs fonts for the current user.
   - Skips font files that already exist instead of failing on re-runs.

6. Applies my Starship configuration  
   - Lets you choose a Starship preset interactively at the end of the script.
   - Generates `%USERPROFILE%\.config\starship.toml` from the selected preset.
   - Prepends optional overrides from `configs\starship_overrides.txt` without rewriting the preset in a way that corrupts Unicode glyphs.

7. Applies my Clink preferences  
   - Sets the Clink logo to none.
   - Enables the desired autosuggestion/completion behavior.
   - Applies optional settings from `configs\clink.overrides.txt`.
   - Skips unsupported Clink settings with a warning instead of stopping the whole setup.

8. Optionally updates Windows Terminal (if detected)  
   - Backs up `settings.json` before editing it.
   - Updates the Command Prompt profile to use:  
     `%SystemRoot%\System32\cmd.exe /d /q /k cls`
   - Sets the startup directory to the current user profile.
   - Applies a Nerd Font to the Command Prompt profile.

9. Creates setup logs  
   - Writes a log file and a separate PowerShell transcript to help troubleshoot failures and repeated runs.

## Files in this repo

- `setup.ps1`  
  The main installer. Intended to be run on a fresh Windows install.

- `run-setup.cmd`  
  A small launcher that invokes the PowerShell script with ExecutionPolicy Bypass so the user can run it easily.

- `configs\`  
   A folder containing small override files that customize the generated Clink and Starship configuration without replacing the whole upstream config.

## Configuration and overrides

This project keeps customization minimal and version-resilient by generating a fresh base configuration from upstream tools, then applying a small set of overrides.

### How overrides are applied

- **Starship theme preset**: the script generates `%USERPROFILE%\.config\starship.toml` using `starship preset <preset> -o ...`.
- **Starship overrides file**: if present, `configs/starship_overrides.txt` is read as UTF-8 and prepended to the generated preset before the final `starship.toml` is written.
- **Clink overrides file**: if present, `configs/clink.overrides.txt` is applied line-by-line as `clink set <key> <value>`.

### Starship overrides (`configs/starship_overrides.txt`)

Optional. A plain UTF-8 text file containing top-level Starship TOML entries that should appear before the generated preset.

This is the preferred place for small customizations such as:

#### `add_newline = false`

Starship can insert an extra blank line before the prompt. This project disables that behavior by prepending the override before the generated preset content.

Example `configs/starship_overrides.txt`:

```toml
add_newline = false
```

### Clink overrides (`configs/clink.overrides.txt`)

Optional. A plain `key=value` file. Each non-empty, non-comment line is applied as:

- `clink set <key> <value>`

Use this to keep only the Clink settings you care about. Common settings used in this project:

#### `clink.logo=none`

Disables Clink’s startup logo/banner so cmd starts cleanly (Clink still loads and works normally).

#### `autosuggest.enable=true`

Enables inline autosuggestions while typing (typically based on your history). You can accept a suggestion using the usual Clink keybinding (commonly Right Arrow / End).

#### `autosuggest.hint=true`

Shows Clink’s on-screen hint for autosuggestions (a small hint that indicates which key accepts the suggestion). Set to `false` if you want a cleaner UI.

Unsupported or removed Clink settings are skipped with a warning instead of failing the whole script.

Example `configs/clink.overrides.txt`:

```text
clink.logo=none
autosuggest.enable=true
autosuggest.hint=true
```

## Theme selection (Starship presets)

At the end of the script run, you can choose a Starship preset by number. The script writes the selected preset into:

- `%USERPROFILE%\.config\starship.toml`

If `configs/starship_overrides.txt` exists, those overrides are prepended before the final file is written.

You can preview and compare the available presets here:
<https://starship.rs/presets/>

## Requirements

- Windows 10/11
- Windows Terminal (optional, but recommended)
- winget (App Installer)
- Git for Windows must be installed and available on PATH: <https://git-scm.com/download/win>

## Recommended Git installation options

Install Git for Windows first. During installation, choose options that make it easier to work from Command Prompt:

1. Ensure Git is added to PATH  
   You want Git to be usable from Command Prompt and PowerShell, not only from Git Bash.

2. Enable Git’s Unix tools on PATH  
   In the Git for Windows installer this is typically the option that adds Unix tools (such as `touch`, `mkdir`, `ls`, `rm`, `sed`, `awk`) to PATH so they are available from Command Prompt and PowerShell.

If you want Command Prompt to have “Linux-like” commands (for example `touch`), this installer choice is the simplest way to get it. After installing Git with those options, open a new terminal and verify:

- `git --version`
- `touch --version` (or just `touch test.txt`)

Note: if `touch` is available, it is coming from Git for Windows (or another Unix-tools distribution), not from cmd itself.

## How to run

### Option 1: Run using the launcher (recommended)

Double-click `run-setup.cmd`.

This launches PowerShell with the correct flags and runs the installer.

### Option 2: Run directly from PowerShell

From the repo folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

Useful optional switches supported by the script include:

- `-NonInteractive`
- `-StarshipPreset <preset>`
- `-SkipFonts`
- `-SkipTerminalProfile`
- `-SkipCompletions`
- `-SkipPackageInstall`

## After installation

1. Close and reopen Windows Terminal (or any cmd window).
2. Select Command Prompt.
3. In Windows Terminal settings, set the font to a Nerd Font (for example “FiraCode Nerd Font Mono”) if you want the icons to render correctly.

If the script updated Windows Terminal’s default profile successfully, opening Windows Terminal should start in Command Prompt with a cleared screen.

## Troubleshooting

### Git missing

If the script exits early complaining about Git, install Git for Windows and ensure `git` works in a new terminal:

```cmd
git --version
```

### Font icons look wrong

In Windows Terminal settings for the profile you use, set the font face to the Nerd Font you installed (FiraCode Nerd Font).

### Windows Terminal default profile not set

The script only updates Windows Terminal if it finds Terminal’s `settings.json`. If Terminal is not installed yet, or has never been launched, the settings file may not exist. Install/launch Windows Terminal once and re-run the script.

### Clink override setting fails or is ignored

If a line in `configs/clink.overrides.txt` refers to a setting that does not exist in your installed Clink version, the script skips it with a warning instead of failing. Remove outdated settings from the overrides file if you want a cleaner run.

### Need failure details

The script writes a structured log plus a PowerShell transcript under the repo’s `logs\` folder. Use those files to diagnose package install issues, Clink registration issues, or Windows Terminal profile edits.

## Notes on customization

- Starship configuration is written to:  
  `%USERPROFILE%\.config\starship.toml`

- Clink state/settings are stored under:  
  `%LOCALAPPDATA%\clink`

- Optional Starship overrides are read from:  
  `configs\starship_overrides.txt`

- Optional Clink overrides are read from:  
  `configs\clink.overrides.txt`

- Setup logs are written under:  
  `logs\`

Modify these files after setup if you want to tweak modules, colors, or behaviors.
