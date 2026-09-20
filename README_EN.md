# Codex Side Preset Switcher

English | [简体中文](README.md)

A macOS menu-bar utility for switching model and reasoning-effort presets in the current Codex Desktop main thread or side chat.

It combines [SwiftBar](https://github.com/swiftbar/SwiftBar) with [Hammerspoon](https://www.hammerspoon.org/) and uses the macOS Accessibility API. It does not move or click the mouse.

> This is an unofficial UI-automation project. It auto-detects the newer combined picker and the older separated picker, and writes privacy-safe diagnostics before stopping on unknown structures.

## Features

- Switch the current main thread or side chat between four paired presets:
  - Luna Max
  - Terra High
  - Sol Medium
  - Sol High
- Open a side chat and apply the most recently successful side-chat preset.
- Change `model` and `model_reasoning_effort` defaults for newly created tasks.
- Keep current-main-thread and side-chat changes separate from `~/.codex/config.toml`.
- Lock automation to the Codex window that was focused when the action started.
- Support built-in and external displays without screen-coordinate calibration.
- Verify the selected model and reasoning level before recording success.
- Detect actionable Accessibility roles such as `AXMenuItem`, `AXButton`, and `AXRadioButton` from the live tree instead of hard-coding one localized label or app version.
- Check control compatibility from SwiftBar without changing a model.
- Refuse unknown presets and stop safely when focus or Accessibility controls are unavailable.

## Requirements

- macOS
- Codex Desktop
- [Hammerspoon](https://www.hammerspoon.org/)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- Accessibility permission for Hammerspoon under **System Settings → Privacy & Security → Accessibility**

## Install

1. Copy the Hammerspoon module:

   ```sh
   cp hammerspoon/codex-side-presets.lua ~/.hammerspoon/
   ```

2. Add this line to `~/.hammerspoon/init.lua`:

   ```lua
   dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")
   ```

3. Copy the SwiftBar plugin into the plugin directory selected in SwiftBar Preferences:

   ```sh
   cp swiftbar/codex-model.1m.sh /path/to/your/swiftbar/plugins/
   chmod +x /path/to/your/swiftbar/plugins/codex-model.1m.sh
   ```

4. Reload the Hammerspoon configuration and refresh SwiftBar.

## Usage

Open the SwiftBar menu:

- **New-task defaults** edits `~/.codex/config.toml`. The plugin creates `config.toml.swiftbar-backup` before replacing the file.
- **Current main thread** changes only the main composer in the window that triggered the action. It does not edit global configuration or operate the side chat.
- **Current side chat** changes only the open side chat. It does not edit the global Codex configuration.
- **Open side chat and apply recent preset** first uses the Codex menu item's Accessibility action; if the menu is temporarily absent from the Accessibility tree, it falls back to the working `Cmd-Option-S` shortcut in the current build, then reapplies the last verified preset. It never moves the mouse.
- **Check Codex control compatibility** reads whether the current window's main and side composers are recognizable, without switching either one.

The “recently successful” label is historical state, not a live reading. Manual changes made afterward are not overwritten until another preset is selected.

## How it works

The Hammerspoon module:

1. Captures the currently focused Codex window.
2. Finds composer model controls: the leftmost belongs to the main thread, and the rightmost belongs to the side chat when a second control exists.
3. Selects the combined or separated picker adapter from the live Accessibility structure and scopes it by position relative to the target composer.
4. Normalizes model names for exact matching and uses Accessibility `AXPress`; unavailable models never fall back to a similar entry.
5. Reads the current and total reasoning stops and sends exactly one delta-only left/right key sequence, with no reset or corrective second pass.
6. Uses `Escape` to commit and close the popover, reads the Accessibility state back, and confirms `config.toml` is unchanged.
7. Writes successful main and side presets separately to `~/.codex/codex-main-preset-state.json` and `~/.codex/codex-side-preset-state.json`.

The latest compatibility check or failure stage is written to `~/.codex/codex-preset-diagnostics/latest.json`. It contains only the Codex version, picker roles, selector type, relative geometry, and failure stage—not conversation or composer text.

No global mouse event tap, cursor movement, or fixed screen coordinates are used.

## Limitations

- This currently targets the visible Codex Desktop controls for GPT-5.6 Luna, Terra, and Sol.
- It assumes the leftmost model control belongs to the main thread and the rightmost of two controls belongs to the side chat.
- Model labels or Accessibility hierarchy changes in Codex Desktop can break automation. Failures should show a Hammerspoon notification without falling back to the main composer.
- Switching either composer briefly brings Codex to the foreground because keyboard focus is required for the reasoning slider.

## Safety

- Back up `~/.codex/config.toml` before first use.
- Review the preset model identifiers in both scripts when Codex models change.
- Do not add mouse-coordinate fallback logic: it can target the wrong conversation or display.

## License

[MIT](LICENSE)
