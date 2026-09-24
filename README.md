# Codex 模型与推理强度快捷切换器

[English](README_EN.md) | 简体中文

这是一个 macOS 菜单栏工具，用于切换 Codex Desktop 当前主线程、侧栏，以及新任务默认使用的模型和推理强度。

它组合使用 [SwiftBar](https://github.com/swiftbar/SwiftBar)、[Hammerspoon](https://www.hammerspoon.org/) 和 macOS 辅助功能 API。切换过程只使用辅助功能动作、焦点和键盘方向键，不移动或模拟点击鼠标。

> 这是非官方的界面自动化工具。Codex 更新后如果辅助功能结构发生变化，工具会安全失败并生成脱敏诊断，不会盲点其他对话。

## 当前预设

默认配置把 GPT-6 放在主菜单，把 GPT-5.6 保留为兼容回退组：

- GPT-6 Astra Max
- GPT-6 Sol High
- GPT-6 Sol Medium
- GPT-6 Luna Max
- GPT-5.6 Luna Max
- GPT-5.6 Terra High
- GPT-5.6 Sol Medium
- GPT-5.6 Sol High

GPT-6 的具体可用性仍由当前 Codex 账户和客户端灰度决定；如果当前界面没有精确显示目标模型，工具会停止，不会选择相近模型。模型和推理强度控件位于 Codex Desktop 输入框下方，参见 [OpenAI Models 文档](https://learn.chatgpt.com/docs/models?translationFallback=ja-JP)。

## 用 JSON 让 AI 修改预设

唯一的预设配置是项目根目录的 [`codex-presets.json`](codex-presets.json)。实际运行路径是：

```text
~/.codex/codex-presets.json
```

本机默认安装会让运行路径指向项目里的 JSON，因此以后可以直接对 AI 说：

> 请只修改 `codex-presets.json`：新增一个 GPT-6 Sol High 预设，保持 `version=1`，不要修改 Hammerspoon、SwiftBar 或 `config.toml`；修改后运行 JSON 校验。

配置文件采用以下结构：

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

字段说明：

- `id`：菜单和 URL 使用的稳定标识，只能包含字母、数字、点、下划线和短横线。已有的 `luna-max`、`terra-high`、`sol-medium`、`sol-high` 请不要改名，否则旧状态和旧链接无法复用。
- `label`：SwiftBar 中显示的名称。
- `group`：菜单分组名称，例如 `GPT-6`、`GPT-5.6 兼容` 或自定义分组。
- `model`：模型 API ID，例如 `gpt-6-astra`、`gpt-6-sol`、`gpt-6-luna`。
- `model_label`：Codex Desktop 中显示的模型名称，用于精确匹配。
- `effort`：`low`、`medium`、`high`、`xhigh`、`max` 或 `ultra`。
- `effort_index`：该模型在当前 UI 滑块中的档位，从 1 开始；需要和模型实际支持的档位数一致。
- `aliases`：模型显示名称发生变化时可添加的精确别名，不用于模糊匹配。
- `enabled`：设为 `false` 可以暂时隐藏预设；删除对象则彻底移除。
- `legacy`：仅用于标记兼容预设，不会改变切换逻辑。

修改后：

1. 运行 `jq empty codex-presets.json`，或让 AI 运行 JSON 校验。
2. 在 SwiftBar 中点击“重新加载预设配置”。
3. 菜单会按 JSON 立即重新生成。配置损坏、ID 重复或字段缺失时只显示错误，不会操作 Codex。

菜单也提供“打开/编辑预设配置（让 AI 修改此文件）”。它打开的是 `~/.codex/codex-presets.json`；如果该路径是仓库软链接，编辑结果会直接落到项目文件中。

## 功能

- 一键切换当前主线程或侧栏的模型与推理强度。
- GPT-6 推荐组与 GPT-5.6 兼容组动态生成，不再把预设硬编码在两份脚本里。
- 打开侧栏并应用最近一次成功使用的侧栏预设。
- 通过“新任务默认配置”修改 `~/.codex/config.toml` 的 `model` 和 `model_reasoning_effort`；只有主动点击该组菜单时才会修改全局默认。
- 主线程、侧栏切换不会修改 `config.toml`，并在操作前后检查内容不变。
- 操作开始时锁定触发时的 Codex 窗口，适配内置屏和外接显示器。
- 设置完成后回读模型和推理强度，验证成功后才记录最近状态。
- 支持新版“模型 + 推理强度”组合选择器和旧版分离式选择器。
- SwiftBar 提供控件兼容性检查和预设重新加载。
- 失败时写入 `~/.codex/codex-preset-diagnostics/latest.json`，不记录对话内容或输入框文本。

## 环境要求

- macOS
- Codex Desktop
- [Hammerspoon](https://www.hammerspoon.org/)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- `/usr/bin/jq`
- 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Hammerspoon 控制电脑

## 安装

在仓库目录执行：

```sh
cp hammerspoon/codex-side-presets.lua ~/.hammerspoon/
cp swiftbar/codex-model.1m.sh /你的/SwiftBar/插件目录/
chmod +x /你的/SwiftBar/插件目录/codex-model.1m.sh
```

在 `~/.hammerspoon/init.lua` 中加入：

```lua
dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")
```

如果 `~/.codex/codex-presets.json` 不存在，建议把它链接到仓库配置，方便以后让 AI 修改：

```sh
ln -s /你的仓库绝对路径/codex-presets.json ~/.codex/codex-presets.json
```

如果该文件已经存在，请先保留现有配置，不要直接覆盖；运行端也支持普通 JSON 文件。完成后在 Hammerspoon 点击 **Reload config**，再刷新 SwiftBar。

## 使用方法

点击菜单栏中的 SwiftBar 项目：

- **新任务默认配置**：修改全局 `config.toml`，只影响之后新建的任务，并保留 `config.toml.swiftbar-backup` 备份。
- **当前主线程**：只切换当前触发窗口的主线程，不修改全局配置或侧栏。
- **当前侧栏**：只切换当前窗口右侧侧栏，不修改全局配置。
- **打开侧栏并应用最近预设**：侧栏关闭时自动打开，然后应用最近一次验证成功的侧栏预设。
- **检查 Codex 控件兼容性**：只读取当前窗口的主线程和侧栏控件，不切换模型。
- **重新加载预设配置**：重新读取 JSON，不需要同时修改 Lua 或 Shell。

“最近成功”是历史记录，不是实时读取结果。你在 Codex 中手动调整后，工具不会覆盖，只有再次点击预设才会切换。

## 工作原理与安全边界

Hammerspoon 会锁定触发时的 Codex 窗口，通过辅助功能树查找目标输入区，并按主线程/侧栏的相对位置区分两个选择器。模型名称按 `model`、`model_label` 和 `aliases` 精确匹配；推理强度先读取当前档位，只发送需要的左右方向键，不先归零、不进行第二轮校正。

切换主线程或侧栏时不会写入 `config.toml`，也不使用鼠标移动、全局鼠标监听、固定屏幕坐标或模拟鼠标点击。Codex 更新导致控件无法识别时，脚本会停止、通知并写诊断文件。

## 许可证

[MIT](LICENSE)
