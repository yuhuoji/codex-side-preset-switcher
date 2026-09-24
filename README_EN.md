# Codex Model and Reasoning Preset Switcher

English | [简体中文](README.md)

A macOS menu-bar utility for switching the model and reasoning effort of the current Codex Desktop main thread, side chat, or new-task defaults.

It combines [SwiftBar](https://github.com/swiftbar/SwiftBar), [Hammerspoon](https://www.hammerspoon.org/), and the macOS Accessibility API. Switching uses Accessibility actions, focus, and app-targeted arrow keys; it does not move or simulate mouse clicks.

> This is unofficial UI automation. If a Codex update changes the Accessibility hierarchy, the tool stops safely and writes privacy-safe diagnostics instead of guessing at another conversation.

## Presets

The default configuration puts GPT-6 in the primary menu and keeps GPT-5.6 as a compatibility group:

- GPT-6 Astra Max
- GPT-6 Sol High
- GPT-6 Sol Medium
- GPT-6 Luna Max
- GPT-5.6 Luna Max
- GPT-5.6 Terra High
- GPT-5.6 Sol Medium
- GPT-5.6 Sol High

Actual availability still depends on the current Codex account and client rollout. If the exact target model is not exposed by the current UI, the switcher stops rather than selecting a similar model. The model and reasoning controls are beneath the Codex Desktop composer; see the [OpenAI Models documentation](https://learn.chatgpt.com/docs/models?translationFallback=ja-JP).

## AI-editable JSON configuration

The single source of truth is [`codex-presets.json`](codex-presets.json) in the repository. The live path is:

```text
~/.codex/codex-presets.json
```

The recommended setup makes the live path point to the repository file, so you can ask the AI:

> Modify only `codex-presets.json`: add a GPT-6 Sol High preset, keep `version=1`, do not edit Hammerspoon, SwiftBar, or `config.toml`, and validate the JSON afterward.

The schema is:

```json
{
  "version": 1,
  "presets": [
    {
      "id": "gpt6-sol-high",
      "label": "GPT-6 Sol High",
      "group": "GPT-6",
      "model": "gpt-6-sol",
      "model_label": "GPT-6 Sol",
      "effort": "high",
      "effort_index": 3,
      "aliases": [],
      "enabled": true,
      "legacy": false
    }
  ]
}
```

`id` is the stable menu and URL identifier. Existing IDs `luna-max`, `terra-high`, `sol-medium`, and `sol-high` are retained for old state files and links. `label` is the menu text; `group` controls the menu section; `model` is the API ID; `model_label` is the exact Desktop label; `effort` must be `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`; `effort_index` is the 1-based slider stop; `aliases` are exact display aliases; `enabled=false` hides a preset; and `legacy` marks a compatibility entry.

After editing:

1. Run `jq empty codex-presets.json`, or ask the AI to validate it.
2. Click **Reload preset configuration** in SwiftBar.
3. SwiftBar regenerates all groups from the JSON. Invalid JSON, duplicate IDs, missing fields, or unsupported effort levels disable switching instead of operating Codex.

SwiftBar also provides **Open/edit preset configuration (for AI)**. It opens `~/.codex/codex-presets.json`; when that path is a symlink, edits are written directly to the repository file.

## Features

- Switch the current main thread or side chat with one paired model/effort action.
- Generate GPT-6 and GPT-5.6 compatibility groups dynamically from one JSON file.
- Open the side chat and apply the most recently successful side-chat preset.
- Change `model` and `model_reasoning_effort` in `~/.codex/config.toml` for new tasks only when the user explicitly chooses the New-task defaults menu.
- Keep current main-thread and side-chat changes separate from `config.toml`, and verify that the file is unchanged before recording success.
- Lock automation to the Codex window focused when the action starts, including built-in and external displays.
- Read back the selected model and reasoning effort before writing recent-state files.
- Support the current combined picker and older separated picker.
- Provide SwiftBar compatibility checks and configuration reload actions.
- Write diagnostics to `~/.codex/codex-preset-diagnostics/latest.json` without recording conversation or composer text.

## Requirements

- macOS
- Codex Desktop
- [Hammerspoon](https://www.hammerspoon.org/)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- `/usr/bin/jq`
- Hammerspoon CLI, usually `/opt/homebrew/bin/hs` (or `/usr/local/bin/hs` on Intel Homebrew)
- Accessibility permission for Hammerspoon under **System Settings → Privacy & Security → Accessibility**

## Installation

From the repository directory:

```sh
cp hammerspoon/codex-side-presets.lua ~/.hammerspoon/
cp swiftbar/codex-model.1m.sh /path/to/your/swiftbar/plugins/
cp swiftbar/codex-hammerspoon-dispatch.sh /path/to/your/swiftbar/plugins/
chmod +x /path/to/your/swiftbar/plugins/codex-model.1m.sh \
  /path/to/your/swiftbar/plugins/codex-hammerspoon-dispatch.sh
```

Add this line to `~/.hammerspoon/init.lua`:

```lua
require("hs.ipc")
dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")
```

If the live JSON does not exist, link it to the repository so it remains easy for the AI to edit:

```sh
ln -s /absolute/path/to/codex-side-preset-switcher/codex-presets.json ~/.codex/codex-presets.json
```

If a live file already exists, keep it instead of overwriting it; a regular JSON file is supported too. Click **Reload config** in Hammerspoon and refresh SwiftBar afterward.

SwiftBar actions use Hammerspoon CLI IPC instead of depending on the system's
`hammerspoon://` LaunchServices registration. If `hs` is elsewhere, set
`CODEX_HAMMERSPOON_CLI` before launching SwiftBar. The original URL handlers
remain available for backwards compatibility.

## Usage

Open the SwiftBar menu:

- **New-task defaults** edits global `config.toml` and creates `config.toml.swiftbar-backup` before replacement.
- **Current main thread** changes only the main composer in the triggering window.
- **Current side chat** changes only the right-hand side composer in the triggering window.
- **Open side chat and apply recent preset** opens the side chat when needed, then applies the most recently verified side preset.
- **Check Codex control compatibility** reads the current main and side controls without changing a model.
- **Reload preset configuration** reloads the JSON without editing the Lua or shell implementation.

“Recently successful” is historical state, not a live readback. Manual changes made in Codex are not overwritten until another preset is selected.

## How it works and safety boundaries

Hammerspoon locks the triggering Codex window, finds the target composer in the Accessibility tree, and distinguishes main versus side by their relative positions. Model matching is exact across `model`, `model_label`, and `aliases`. The current effort stop is read first, then only the required left/right delta is sent; the slider is never reset or corrected in a second pass.

Main-thread and side-chat actions do not write `config.toml`. The implementation has no mouse movement, global mouse listener, fixed screen coordinates, or simulated mouse clicks. When a Codex update makes the controls unrecognizable, it stops, notifies the user, and writes a diagnostic file.

## License

[MIT](LICENSE)
