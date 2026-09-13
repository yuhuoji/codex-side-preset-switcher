# Codex Side Preset Switcher

A macOS menu-bar utility for switching model and reasoning-effort presets in the current Codex Desktop side chat.

It combines [SwiftBar](https://github.com/swiftbar/SwiftBar) with [Hammerspoon](https://www.hammerspoon.org/) and uses the macOS Accessibility API. It does not move or click the mouse.

> This is an unofficial UI-automation project. Codex Desktop UI updates may require selector adjustments.

## Features

- Switch the current side chat between four paired presets:
  - Luna Max
  - Terra High
  - Sol Medium
  - Sol High
- Open a side chat and apply the most recently successful side-chat preset.
- Change `model` and `model_reasoning_effort` defaults for newly created tasks.
- Keep current-side-chat changes separate from `~/.codex/config.toml`.
- Lock automation to the Codex window that was focused when the action started.
- Support built-in and external displays without screen-coordinate calibration.
- Verify the selected model and reasoning level before recording success.
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
- **Current side chat** changes only the open side chat. It does not edit the global Codex configuration.
- **Open side chat and apply recent preset** opens the side chat with Codex's existing `⌘⌥S` command and reapplies the last verified preset.

The “recently successful” label is historical state, not a live reading. Manual changes made afterward are not overwritten until another preset is selected.

## How it works

The Hammerspoon module:

1. Captures the currently focused Codex window.
2. Finds two model controls and selects the rightmost one, which belongs to the side composer.
3. Uses Accessibility `AXPress` actions to select the model.
4. Focuses the reasoning control and uses documented left/right keyboard navigation.
5. Reads the Accessibility state back, closes the popover, and confirms `config.toml` is unchanged.
6. Writes the last successful side preset to `~/.codex/codex-side-preset-state.json`.

No global mouse event tap, cursor movement, or fixed screen coordinates are used.

## Limitations

- This currently targets the visible Codex Desktop controls for GPT-5.6 Luna, Terra, and Sol.
- It assumes the side composer is represented by the rightmost of two model controls in the focused Codex window.
- Model labels or Accessibility hierarchy changes in Codex Desktop can break automation. Failures should show a Hammerspoon notification without falling back to the main composer.
- Current-side-chat switching briefly brings Codex to the foreground because keyboard focus is required for the reasoning slider.

## Safety

- Back up `~/.codex/config.toml` before first use.
- Review the preset model identifiers in both scripts when Codex models change.
- Do not add mouse-coordinate fallback logic: it can target the wrong conversation or display.

## License

[MIT](LICENSE)
