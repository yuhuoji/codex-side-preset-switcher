# Codex 侧栏模型预设切换器

[English](README_EN.md) | 简体中文

一个用于切换 Codex Desktop 当前侧栏模型与推理强度的 macOS 菜单栏工具。

项目组合使用 [SwiftBar](https://github.com/swiftbar/SwiftBar)、[Hammerspoon](https://www.hammerspoon.org/) 与 macOS 辅助功能 API。切换过程不会移动或点击鼠标。

> 这是一个非官方界面自动化项目。Codex Desktop 更新界面或辅助功能结构后，可能需要同步调整控件定位规则。

## 功能

- 一键切换当前侧栏的模型与推理强度：
  - Luna Max
  - Terra High
  - Sol Medium
  - Sol High
- 打开侧栏并自动应用最近一次成功使用的侧栏预设。
- 修改新建任务使用的 `model` 和 `model_reasoning_effort` 默认值。
- 当前侧栏切换与 `~/.codex/config.toml` 全局配置相互隔离。
- 操作开始时锁定当前获得焦点的 Codex 窗口，避免切换到其他对话。
- 支持 Mac 内置屏幕和外接显示器，无需校准屏幕坐标。
- 设置完成后回读模型与推理强度，验证成功才记录状态。
- 遇到未知预设、焦点丢失或控件不可用时安全停止。

## 环境要求

- macOS
- Codex Desktop
- [Hammerspoon](https://www.hammerspoon.org/)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- 在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 Hammerspoon 控制电脑

## 安装

1. 将 Hammerspoon 模块复制到配置目录：

   ```sh
   cp hammerspoon/codex-side-presets.lua ~/.hammerspoon/
   ```

2. 在 `~/.hammerspoon/init.lua` 中加入：

   ```lua
   dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")
   ```

3. 将 SwiftBar 插件复制到 SwiftBar 偏好设置中选定的插件目录：

   ```sh
   cp swiftbar/codex-model.1m.sh /你的/SwiftBar/插件目录/
   chmod +x /你的/SwiftBar/插件目录/codex-model.1m.sh
   ```

4. 在 Hammerspoon 中执行 **Reload Config**，然后刷新 SwiftBar。

## 使用方法

点击菜单栏中的 SwiftBar 项目：

- **新任务默认配置**：修改 `~/.codex/config.toml`，仅影响之后新建的任务。插件替换配置前会生成 `config.toml.swiftbar-backup` 备份。
- **当前侧栏**：只切换当前打开的侧栏，不修改 Codex 全局配置。
- **打开侧栏并应用最近预设**：调用 Codex 现有的 `⌘⌥S` 命令打开侧栏，并重新应用最近一次验证成功的预设。

菜单中的“最近成功”是历史记录，不是实时读取结果。你之后在 Codex 中手动调整模型或推理强度时，脚本不会覆盖；只有再次点击预设才会执行切换。

## 工作原理

Hammerspoon 模块会：

1. 锁定触发操作时获得焦点的 Codex 窗口。
2. 在该窗口中查找两个模型控件，并选择最右侧的侧栏输入区控件。
3. 通过辅助功能的 `AXPress` 操作选择模型。
4. 聚焦推理强度控件，通过左右方向键调整档位。
5. 回读辅助功能状态、关闭弹窗，并确认 `config.toml` 没有变化。
6. 将最近一次成功预设写入 `~/.codex/codex-side-preset-state.json`。

实现中不使用全局鼠标监听、鼠标移动、模拟点击或固定屏幕坐标。

## 已知限制

- 当前预设面向 Codex Desktop 中显示的 GPT-5.6 Luna、Terra 和 Sol。
- 当前实现假定：同一 Codex 对话窗口出现两个模型控件时，最右侧控件属于侧栏输入区。
- Codex Desktop 修改模型名称或辅助功能结构后，自动化可能失效。此时脚本应显示 Hammerspoon 通知并停止，不会回退操作主对话输入区。
- 切换当前侧栏时需要让 Codex 短暂置于前台，因为推理强度滑块需要键盘焦点。

## 安全说明

- 首次使用前建议自行备份 `~/.codex/config.toml`。
- Codex 模型更新后，请检查两个脚本中的预设模型标识。
- 不建议加入鼠标坐标兜底逻辑，否则可能在多窗口或多显示器环境下操作错误的对话。

## 许可证

[MIT](LICENSE)

