-- Codex main-thread and side-chat preset switcher for Hammerspoon.
-- Load from ~/.hammerspoon/init.lua with:
-- dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")

-- Codex composer model presets. Main-thread changes also sync config.toml so
-- newly created threads use the same model and reasoning effort.
local home = assert(os.getenv("HOME"), "HOME is not set")
local codexBundleID = "com.openai.codex"
local codexConfigPath = home .. "/.codex/config.toml"
local codexConfigBackupPath = home .. "/.codex/config.toml.swiftbar-backup"
local codexPresetConfigPath = home .. "/.codex/codex-presets.json"
local codexMainStatePath = home .. "/.codex/codex-main-preset-state.json"
local codexSideStatePath = home .. "/.codex/codex-side-preset-state.json"
local codexDiagnosticsDir = home .. "/.codex/codex-preset-diagnostics"
local codexDiagnosticsPath = codexDiagnosticsDir .. "/latest.json"
local codexPresetBusy = false
local codexPresetRunID = 0
local codexPresetTimeoutTimer = nil
local codexPresetActiveContext = nil
local codexPresetScopeLabel = "当前侧栏"
local codexPresetStage = "idle"

local codexPresets = {}
local codexPresetList = {}
local codexPresetConfigVersion = nil
local codexPresetConfigSource = nil
local codexPresetConfigError = nil

local function codexNotify(message)
  hs.printf("Codex preset (%s): %s", codexPresetScopeLabel, message)
  hs.notify.new({title = "Codex " .. codexPresetScopeLabel, informativeText = message}):send()
end

local function readFile(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function writeAtomicFile(path, contents)
  local tempPath = path .. ".codex-preset-tmp"
  os.remove(tempPath)
  local file, openError = io.open(tempPath, "wb")
  if not file then return false, tostring(openError or "无法创建临时文件") end
  local ok, writeError = pcall(function()
    file:write(contents)
    file:flush()
    file:close()
  end)
  if not ok then
    pcall(function() file:close() end)
    os.remove(tempPath)
    return false, tostring(writeError)
  end
  local chmodStatus = os.execute("/bin/chmod 600 " .. shellQuote(tempPath))
  if chmodStatus ~= true and chmodStatus ~= 0 then
    os.remove(tempPath)
    return false, "无法设置临时文件权限"
  end
  if not os.rename(tempPath, path) then
    os.remove(tempPath)
    return false, "无法原子替换 " .. path
  end
  return true, nil
end

local function updateTopLevelConfig(contents, model, effort)
  local newline = contents:find("\r\n", 1, true) and "\r\n" or "\n"
  local normalized = contents:gsub("\r\n", "\n")
  local lines = {}
  local inTopLevel = true
  local modelCount = 0
  local effortCount = 0
  local modelValue = '"' .. tostring(model):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  local effortValue = '"' .. tostring(effort):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'

  for line in (normalized .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*%[[^%]]+%]%s*$") then
      inTopLevel = false
    elseif inTopLevel then
      local prefix, suffix = line:match("^(%s*model%s*=%s*)\"[^\"]*\"(.*)$")
      if prefix then
        line = prefix .. modelValue .. suffix
        modelCount = modelCount + 1
      else
        prefix, suffix = line:match("^(%s*model_reasoning_effort%s*=%s*)\"[^\"]*\"(.*)$")
        if prefix then
          line = prefix .. effortValue .. suffix
          effortCount = effortCount + 1
        end
      end
    end
    table.insert(lines, line)
  end

  if modelCount ~= 1 or effortCount ~= 1 then
    return nil, string.format(
      "config.toml 顶层字段数量异常（model=%d，model_reasoning_effort=%d）",
      modelCount, effortCount
    )
  end
  return table.concat(lines, newline), nil
end

local function syncMainPresetToConfig(preset, configBefore)
  local attributes = hs.fs.attributes(codexConfigPath)
  if not attributes or attributes.mode ~= "file" then
    return false, "config.toml 不存在或不是普通文件"
  end
  local updatedConfig, updateError = updateTopLevelConfig(
    configBefore, preset.model, preset.effortKey
  )
  if not updatedConfig then return false, updateError end

  local backupOK, backupError = writeAtomicFile(codexConfigBackupPath, configBefore)
  if not backupOK then return false, "无法写入 config.toml 备份：" .. backupError end
  local configOK, configError = writeAtomicFile(codexConfigPath, updatedConfig)
  if not configOK then return false, "无法写入 config.toml：" .. configError end
  if readFile(codexConfigPath) ~= updatedConfig then
    writeAtomicFile(codexConfigPath, configBefore)
    return false, "config.toml 回读不一致，已尝试恢复原内容"
  end
  return true, nil
end

-- Keep a first-run fallback so the module can still be loaded before the
-- user-level JSON has been installed. Actions remain disabled until the JSON
-- validates, so a missing or malformed file can never trigger a UI change.
local defaultPresetDefinitions = {
  {
    id = "gpt6-astra-max",
    label = "GPT-6 Astra Max",
    group = "GPT-6",
    model = "gpt-6-astra",
    model_label = "GPT-6 Astra",
    effort = "max",
    effort_index = 5,
    aliases = {},
    enabled = true,
    legacy = false,
  },
  {
    id = "gpt6-sol-high",
    label = "GPT-6 Sol High",
    group = "GPT-6",
    model = "gpt-6-sol",
    model_label = "GPT-6 Sol",
    effort = "high",
    effort_index = 3,
    aliases = {},
    enabled = true,
    legacy = false,
  },
  {
    id = "gpt6-sol-medium",
    label = "GPT-6 Sol Medium",
    group = "GPT-6",
    model = "gpt-6-sol",
    model_label = "GPT-6 Sol",
    effort = "medium",
    effort_index = 2,
    aliases = {},
    enabled = true,
    legacy = false,
  },
  {
    id = "gpt6-luna-max",
    label = "GPT-6 Luna Max",
    group = "GPT-6",
    model = "gpt-6-luna",
    model_label = "GPT-6 Luna",
    effort = "max",
    effort_index = 5,
    aliases = {},
    enabled = true,
    legacy = false,
  },
}

local supportedEfforts = {
  low = true,
  medium = true,
  high = true,
  xhigh = true,
  max = true,
  ultra = true,
}

local effortAliases = {
  standard = "medium",
  light = "low",
  minimal = "low",
  ["very-high"] = "xhigh",
  ["very high"] = "xhigh",
  ["extra-high"] = "xhigh",
  ["extra high"] = "xhigh",
}

local effortLabelsByKey = {
  low = {"低", "low", "light", "minimal"},
  medium = {"中", "标准", "medium", "standard"},
  high = {"高", "high"},
  xhigh = {"极高", "xhigh", "very high", "extra high"},
  max = {"最高", "max", "highest"},
  ultra = {"ultra", "极限"},
}

local modelEffortSuffixes = {
  low = true,
  medium = true,
  standard = true,
  high = true,
  xhigh = true,
  veryhigh = true,
  extrahigh = true,
  max = true,
  highest = true,
  ultra = true,
}

local function normalizeModelToken(value)
  return tostring(value or ""):lower()
    :gsub("gpt", "")
    :gsub("[^%w%.]+", "")
end

local function canonicalEffortKey(value)
  if type(value) ~= "string" then return nil end
  local lower = value:lower()
  if supportedEfforts[lower] then return lower end
  return effortAliases[lower]
end

local function copyStrings(values)
  local copy = {}
  for _, value in ipairs(values or {}) do table.insert(copy, value) end
  return copy
end

local function modelTextMatchesPreset(text, preset)
  local compact = normalizeModelToken(text)
  if compact == "" then return false end
  for _, variant in ipairs(preset.modelVariants or {}) do
    local target = normalizeModelToken(variant)
    if target ~= "" then
      if compact == target then return true end
      if compact:sub(1, #target) == target then
        local suffix = compact:sub(#target + 1)
        if suffix == "" or modelEffortSuffixes[suffix] then return true end
      end
    end
  end
  return false
end

local function validatePresetDefinition(raw, index)
  if type(raw) ~= "table" then return nil, "第 " .. index .. " 个预设不是对象" end
  for _, field in ipairs({"id", "label", "group", "model", "model_label", "effort", "effort_index"}) do
    if raw[field] == nil then
      return nil, string.format("第 %d 个预设缺少 %s", index, field)
    end
  end
  for _, field in ipairs({"id", "label", "group", "model", "model_label", "effort"}) do
    if type(raw[field]) ~= "string" or raw[field] == "" then
      return nil, string.format("第 %d 个预设的 %s 必须是非空字符串", index, field)
    end
  end
  if not raw.id:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") then
    return nil, string.format("第 %d 个预设的 id 只能包含字母、数字、点、下划线和短横线", index)
  end
  if type(raw.effort_index) ~= "number"
      or raw.effort_index < 1 or raw.effort_index % 1 ~= 0 then
    return nil, string.format("第 %d 个预设的 effort_index 必须是正整数", index)
  end
  local effortKey = canonicalEffortKey(raw.effort)
  if not effortKey then
    return nil, string.format("第 %d 个预设的 effort 不受支持：%s", index, raw.effort)
  end
  if raw.aliases ~= nil and type(raw.aliases) ~= "table" then
    return nil, string.format("第 %d 个预设的 aliases 必须是数组", index)
  end
  for _, alias in ipairs(raw.aliases or {}) do
    if type(alias) ~= "string" or alias == "" then
      return nil, string.format("第 %d 个预设的 aliases 只能包含非空字符串", index)
    end
  end
  if raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then
    return nil, string.format("第 %d 个预设的 enabled 必须是布尔值", index)
  end
  if raw.legacy ~= nil and type(raw.legacy) ~= "boolean" then
    return nil, string.format("第 %d 个预设的 legacy 必须是布尔值", index)
  end
  return {
    id = raw.id,
    label = raw.label,
    group = raw.group,
    model = raw.model,
    modelLabel = raw.model_label,
    modelKey = raw.model:lower(),
    modelVariants = {raw.model, raw.model_label, table.unpack(raw.aliases or {})},
    effortKey = effortKey,
    effortIndex = raw.effort_index,
    effortLabels = copyStrings(effortLabelsByKey[effortKey]),
    aliases = copyStrings(raw.aliases),
    enabled = raw.enabled ~= false,
    legacy = raw.legacy == true,
  }
end

local function installPresetDefinitions(config, source)
  codexPresets = {}
  codexPresetList = {}
  if type(config) ~= "table" or config.version ~= 1 or type(config.presets) ~= "table"
      or #config.presets == 0 then
    codexPresetConfigError = "配置必须是 version=1 且包含非空 presets 数组"
    return false
  end
  local seen = {}
  for index, raw in ipairs(config.presets) do
    local preset, err = validatePresetDefinition(raw, index)
    if not preset then
      codexPresetConfigError = err
      codexPresets = {}
      codexPresetList = {}
      return false
    end
    if seen[preset.id] then
      codexPresetConfigError = "预设 id 重复：" .. preset.id
      codexPresets = {}
      codexPresetList = {}
      return false
    end
    seen[preset.id] = true
    codexPresets[preset.id] = preset
    table.insert(codexPresetList, preset)
  end
  codexPresetConfigVersion = config.version
  codexPresetConfigSource = source
  codexPresetConfigError = nil
  return true
end

local function loadCodexPresetConfig()
  local contents = readFile(codexPresetConfigPath)
  if not contents then
    installPresetDefinitions({version = 1, presets = defaultPresetDefinitions}, "embedded-default")
    codexPresetConfigError = "找不到 " .. codexPresetConfigPath
    return false, codexPresetConfigError
  end
  local ok, decoded = pcall(hs.json.decode, contents)
  if not ok or type(decoded) ~= "table" then
    codexPresets = {}
    codexPresetList = {}
    codexPresetConfigError = "JSON 格式无法解析"
    return false, codexPresetConfigError
  end
  local installed = installPresetDefinitions(decoded, codexPresetConfigPath)
  if not installed then return false, codexPresetConfigError end
  return true, nil
end

loadCodexPresetConfig()

local function axAttribute(element, name)
  local ok, value = pcall(function() return element:attributeValue(name) end)
  if ok then return value end
  return nil
end

local function axText(element)
  local parts = {}
  for _, name in ipairs({"AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXHelp"}) do
    local value = axAttribute(element, name)
    if type(value) == "string" and value ~= "" then
      table.insert(parts, value)
    end
  end
  return table.concat(parts, " ")
end

local function axStrings(element)
  local values = {}
  for _, name in ipairs({"AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXHelp"}) do
    local value = axAttribute(element, name)
    if type(value) == "string" and value ~= "" then
      table.insert(values, value)
    end
  end
  return values
end

local function modelKeyFromText(text)
  for _, preset in ipairs(codexPresetList) do
    if modelTextMatchesPreset(text, preset) then return preset.modelKey end
  end
  return nil
end

local function elementMatchesModel(element, modelKey)
  for _, value in ipairs(axStrings(element)) do
    if modelKeyFromText(value) == modelKey then return true end
  end
  return false
end

local function walkAX(root, visitor)
  local visited = 0
  local function walk(element, depth)
    if depth > 40 or visited > 200000 then return nil end
    visited = visited + 1
    local result = visitor(element)
    if result then return result end
    local children = axAttribute(element, "AXChildren")
    if children then
      -- Electron appends the right-hand side chat after the main thread.
      -- Visit from right to left so a long main transcript cannot starve it.
      for index = #children, 1, -1 do
        local childResult = walk(children[index], depth + 1)
        if childResult then return childResult end
      end
    end
    return nil
  end
  return walk(root, 0)
end

local function codexApplicationContext()
  local app = hs.application.get(codexBundleID)
  if not app then return nil, "Codex 未运行" end
  local root = hs.axuielement.applicationElement(app)
  if not root then return nil, "无法读取 Codex 辅助功能树" end
  return {app = app, root = root}
end

local function lockCodexWindow(app)
  local focused = app and app:focusedWindow() or nil
  if focused then return focused end

  -- SwiftBar/Hammerspoon can temporarily own keyboard focus while the URL
  -- handler starts. If Codex exposes exactly one window, it is safe to use
  -- that visible window; with multiple windows, stop rather than guessing.
  local windows = app and app:allWindows() or {}
  if #windows == 1 then return windows[1] end
  return nil
end

local function elementFrame(element)
  local position = axAttribute(element, "AXPosition")
  local size = axAttribute(element, "AXSize")
  if position and size then
    return {x = position.x, y = position.y, w = size.w, h = size.h}
  end

  -- Chromium's tiny live-region announcement for the combined
  -- model/reasoning picker can expose AXFrame without exposing AXPosition and
  -- AXSize separately. Accept the aggregate frame so the current "n of m"
  -- stop remains readable across both accessibility representations.
  local frame = axAttribute(element, "AXFrame")
  if frame and frame.x and frame.y and frame.w and frame.h then
    return {x = frame.x, y = frame.y, w = frame.w, h = frame.h}
  end
  return nil
end

local function sameFrame(a, b, tolerance)
  tolerance = tolerance or 3
  return math.abs(a.x - b.x) <= tolerance and math.abs(a.y - b.y) <= tolerance
    and math.abs(a.w - b.w) <= tolerance and math.abs(a.h - b.h) <= tolerance
end

local actionableRoles = {
  AXMenuItem = true,
  AXButton = true,
  AXRadioButton = true,
  AXCheckBox = true,
  AXPopUpButton = true,
  AXMenuButton = true,
}

local function relativeFrame(frame, windowFrame)
  if not frame or not windowFrame then return nil end
  return {
    x = math.floor(frame.x - windowFrame.x + 0.5),
    y = math.floor(frame.y - windowFrame.y + 0.5),
    w = math.floor(frame.w + 0.5),
    h = math.floor(frame.h + 0.5),
  }
end

local function codexVersion()
  local ok, info = pcall(hs.application.infoForBundleID, codexBundleID)
  if not ok or type(info) ~= "table" then return "unknown" end
  return info.CFBundleShortVersionString or info.CFBundleVersion or "unknown"
end

local function diagnosticControl(element, windowFrame)
  if not element then return nil end
  local role = axAttribute(element, "AXRole") or "unknown"
  local title = axText(element)
  -- Diagnostics are deliberately limited to picker controls. Never persist
  -- text areas, static transcript text, or arbitrary accessibility values.
  if not actionableRoles[role] then title = "" end
  return {
    role = role,
    title = title,
    frame = relativeFrame(elementFrame(element), windowFrame),
  }
end

local function writeDiagnostics(stage, context, details)
  details = details or {}
  local payload = {
    recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    codex_version = codexVersion(),
    stage = stage,
    scope = context and context.targetKind or details.scope or "unknown",
    preset_config_source = codexPresetConfigSource,
    preset_config_version = codexPresetConfigVersion,
    preset_config_error = codexPresetConfigError,
    preset_id = details.preset_id,
    preset_model = details.preset_model,
    preset_effort = details.preset_effort,
    selector_type = details.selector_type or "unknown",
    failure = details.failure,
    main_detected = details.main_detected,
    side_detected = details.side_detected,
    effort_reader = details.effort_reader,
    effort_reader_after_keys = details.effort_reader_after_keys,
    effort_index_before = details.effort_index_before,
    effort_index_after_keys = details.effort_index_after_keys,
    effort_index_target = details.effort_index_target,
    controls = {},
  }
  if context then
    table.insert(payload.controls, diagnosticControl(context.modelElement, context.frame))
    if details.chooseModelItem then
      table.insert(payload.controls, diagnosticControl(details.chooseModelItem, context.frame))
    end
    if details.effortItem then
      table.insert(payload.controls, diagnosticControl(details.effortItem, context.frame))
    end
  end
  pcall(function()
    if not hs.fs.attributes(codexDiagnosticsDir) then hs.fs.mkdir(codexDiagnosticsDir) end
    local tempPath = codexDiagnosticsPath .. ".tmp"
    local file = assert(io.open(tempPath, "wb"))
    file:write(hs.json.encode(payload, true), "\n")
    file:close()
    assert(os.rename(tempPath, codexDiagnosticsPath))
  end)
end

local function isModelControl(element)
  local role = axAttribute(element, "AXRole")
  if role ~= "AXPopUpButton" and role ~= "AXMenuButton" then return false end
  local text = axText(element):lower()
  -- When the model/effort popover is open, Codex temporarily renames the
  -- same model button to "选择强度" instead of exposing the GPT model name.
  return modelKeyFromText(text) ~= nil
    or text:find("选择强度", 1, true) ~= nil
    or text:find("choose effort", 1, true) ~= nil
end

local function modelControlsInWindow(axWindow, windowFrame)
  local controls = {}
  local seen = {}
  walkAX(axWindow, function(element)
    if not isModelControl(element) then return nil end
    local frame = elementFrame(element)
    if not frame or frame.w < 60 or frame.h < 20 then return nil end
    -- The composer is at the bottom of the window. This avoids treating an
    -- unrelated model-like control in a transcript or future side panel as a
    -- composer control.
    if windowFrame and frame.y < windowFrame.y + windowFrame.h * 0.6 then
      return nil
    end
    local key = string.format("%.0f:%.0f:%.0f:%.0f", frame.x, frame.y, frame.w, frame.h)
    if not seen[key] then
      seen[key] = true
      table.insert(controls, {element = element, frame = frame})
    end
    return nil
  end)
  table.sort(controls, function(a, b) return a.frame.x < b.frame.x end)
  return controls
end

local function findComposerContext(targetWindow, targetKind)
  local base, err = codexApplicationContext()
  if not base then return nil, err end
  if not targetWindow then return nil, "未锁定触发时的 Codex 窗口" end
  local targetFrame = targetWindow:frame()
  local axWindows = axAttribute(base.root, "AXWindows") or {}

  for _, axWindow in ipairs(axWindows) do
    local frame = elementFrame(axWindow)
    -- AX and NSScreen window frames can differ by a few pixels after a
    -- display-scale or title-bar transition. Keep the match tight enough not
    -- to jump to another window, but do not require byte-for-byte geometry.
    local sameTarget = frame and sameFrame(frame, targetFrame, 12)
    local controls = sameTarget and modelControlsInWindow(axWindow, frame) or {}
    local requiredControls = targetKind == "side" and 2 or 1
    if frame and #controls >= requiredControls then
      -- In a window with a side chat, the main composer is leftmost and the
      -- side composer is rightmost. With no side chat, the sole control is the
      -- main composer. This relative ordering works across multiple displays.
      local selectedModel = targetKind == "side" and controls[#controls] or controls[1]
      local modelPoint = {
        x = selectedModel.frame.x + selectedModel.frame.w / 2,
        y = selectedModel.frame.y + selectedModel.frame.h / 2,
      }
      return {
        app = base.app,
        root = base.root,
        axWindow = axWindow,
        window = targetWindow,
        frame = frame,
        modelElement = selectedModel.element,
        modelPoint = modelPoint,
        targetKind = targetKind,
      }
    end
  end

  if targetKind == "side" then
    return nil, "当前 Codex 窗口未检测到侧栏输入区"
  end
  return nil, "当前 Codex 窗口未检测到主线程输入区"
end

local function findMainContext(targetWindow)
  return findComposerContext(targetWindow, "main")
end

local function findSideContext(targetWindow)
  return findComposerContext(targetWindow, "side")
end

local function pressAXElement(element)
  if not element then return false end
  local ok, result = pcall(function() return element:performAction("AXPress") end)
  return ok and result ~= false
end

local function findSidebarToggle(app)
  local root = hs.axuielement.applicationElement(app)
  if not root then return nil end
  return walkAX(root, function(element)
    if axAttribute(element, "AXRole") ~= "AXMenuItem" then return nil end
    local text = axText(element):lower()
    if text:find("切换侧边栏", 1, true)
        or text:find("toggle sidebar", 1, true) then
      return element
    end
    return nil
  end)
end

local function toggleCodexSidebar(app)
  -- Prefer the actual menu item's AXPress. The menu shortcut label has
  -- changed between Codex builds, while the menu action remains stable.
  -- AXPress does not move or click the mouse.
  local menuItem = findSidebarToggle(app)
  if menuItem and pressAXElement(menuItem) then return true end

  -- Conservative fallback for a build that temporarily omits menu items from
  -- its AX tree. In the current desktop build the working Side chat command
  -- is still Cmd-Option-S; Cmd-B may be shown by a nearby menu item but does
  -- not open the Side chat in this window.
  if app then
    hs.eventtap.keyStroke({"cmd", "alt"}, "s", 0, app)
    return true
  end
  return false
end

local function waitForSideChat(callback, opened, attempt, targetWindow)
  attempt = attempt or 1
  local context = findSideContext(targetWindow)
  if context then
    callback(context, opened)
    return
  end
  if attempt > 100 then
    callback(nil, "等待侧栏出现超时")
    return
  end
  hs.timer.doAfter(0.2, function()
    waitForSideChat(callback, opened, attempt + 1, targetWindow)
  end)
end

local function ensureSideChat(callback)
  local app = hs.application.get(codexBundleID)
  if not app then
    callback(nil, "Codex 未运行")
    return
  end
  -- Lock the exact focused Codex window when possible. If SwiftBar owns focus
  -- at URL-dispatch time, lock the only Codex window instead of guessing among
  -- multiple conversations.
  local targetWindow = lockCodexWindow(app)
  if not targetWindow then
    callback(nil, "无法锁定触发时的 Codex 窗口")
    return
  end
  app:activate(true)
  if targetWindow then targetWindow:raise(); targetWindow:focus() end
  local hammerspoonApp = hs.application.get("org.hammerspoon.Hammerspoon")
  if hammerspoonApp then hammerspoonApp:hide() end
  -- AX coordinates and children can be stale while focus moves back from the
  -- SwiftBar/Hammerspoon menu, especially when Codex is on another display.
  hs.timer.doAfter(1.2, function()
    local context = findSideContext(targetWindow)
    if context then
      callback(context, false)
      return
    end
    if not toggleCodexSidebar(app) then
      callback(nil, "无法打开 Codex 侧栏")
      return
    end
    waitForSideChat(callback, true, 1, targetWindow)
  end)
end

local function waitForMainThread(callback, attempt, targetWindow)
  attempt = attempt or 1
  local context = findMainContext(targetWindow)
  if context then
    callback(context, false)
    return
  end
  if attempt > 20 then
    callback(nil, "等待主线程输入区出现超时")
    return
  end
  hs.timer.doAfter(0.1, function()
    waitForMainThread(callback, attempt + 1, targetWindow)
  end)
end

local function ensureMainThread(callback)
  local app = hs.application.get(codexBundleID)
  if not app then
    callback(nil, "Codex 未运行")
    return
  end
  -- Lock the exact focused Codex window when possible. If SwiftBar owns focus
  -- at URL-dispatch time, lock the only Codex window instead of guessing among
  -- multiple conversations.
  local targetWindow = lockCodexWindow(app)
  if not targetWindow then
    callback(nil, "无法锁定触发时的 Codex 窗口")
    return
  end
  app:activate(true)
  targetWindow:raise()
  targetWindow:focus()
  local hammerspoonApp = hs.application.get("org.hammerspoon.Hammerspoon")
  if hammerspoonApp then hammerspoonApp:hide() end
  hs.timer.doAfter(1.2, function()
    waitForMainThread(callback, 1, targetWindow)
  end)
end

local function pickerCandidate(context, element)
  local role = axAttribute(element, "AXRole")
  if not actionableRoles[role] then return nil end
  local frame = elementFrame(element)
  if not frame or frame.w < 12 or frame.h < 12 or not context.modelPoint then return nil end
  if context.frame then
    local margin = 24
    if frame.x < context.frame.x - margin
        or frame.y < context.frame.y - margin
        or frame.x + frame.w > context.frame.x + context.frame.w + margin
        or frame.y + frame.h > context.frame.y + context.frame.h + margin then
      return nil
    end
  end
  local centerX = frame.x + frame.w / 2
  local centerY = frame.y + frame.h / 2
  local dx = math.abs(centerX - context.modelPoint.x)
  local dy = math.abs(centerY - context.modelPoint.y)
  if dx > 380 or dy > 520 then return nil end
  return frame, dx + dy * 1.35
end

local function findPickerAction(context, matcher, structuralMatcher)
  context.root = hs.axuielement.applicationElement(context.app)
  local best = nil
  local bestScore = math.huge
  walkAX(context.root, function(element)
    local frame, score = pickerCandidate(context, element)
    if not frame then return nil end
    local textMatch = matcher and matcher(axText(element), element) or false
    local structureMatch = structuralMatcher and structuralMatcher(frame, element) or false
    if not textMatch and not structureMatch then return nil end
    if structureMatch and not textMatch then score = score + 500 end
    local parent = axAttribute(element, "AXParent")
    if axAttribute(element, "AXFocused") == true
        or (parent and axAttribute(parent, "AXFocused") == true) then
      score = score - 10000
    end
    if axAttribute(element, "AXEnabled") == false then score = score + 20000 end
    if score < bestScore then
      best = element
      bestScore = score
    end
    return nil
  end)
  return best
end

local function findAXMenuItem(context, matcher)
  -- Kept as a compatibility wrapper for older callers and clients. The
  -- implementation now accepts every actionable picker role.
  return findPickerAction(context, matcher, nil)
end

local function sameAXElement(left, right)
  if not left or not right then return false end
  if left == right then return true end
  local leftNode = axAttribute(left, "ChromeAXNodeId")
  local rightNode = axAttribute(right, "ChromeAXNodeId")
  return leftNode ~= nil and rightNode ~= nil and leftNode == rightNode
end

local function currentFocusedElement(app)
  if not app then return nil end
  local ok, root = pcall(hs.axuielement.applicationElement, app)
  if not ok or not root then return nil end
  return axAttribute(root, "AXFocusedUIElement")
end

local function focusAXElement(element, app, callback, attempt)
  if not element then
    callback(false)
    return
  end
  attempt = attempt or 1
  -- setAttributeValue() often returns nil even when Chromium rejects or
  -- ignores the request. Re-assert it on every retry and verify the actual
  -- application focus receiver below; AXFocused on the node alone can be
  -- stale while the outer "选择强度" group remains focused.
  pcall(function() element:setAttributeValue("AXFocused", true) end)

  local focused = axAttribute(element, "AXFocused") == true
  local focusedElement = currentFocusedElement(app)
  if focused or sameAXElement(element, focusedElement) then
    -- Chromium updates AXFocused before it moves the actual application
    -- focus receiver. Give that hand-off time to settle, then sample it one
    -- more time; sending an arrow during this gap is silently dropped by the
    -- combined picker and the receiver can briefly fall back to the model
    -- button even after the first AXFocused read succeeded.
    hs.timer.doAfter(0.55, function()
      local settledElement = currentFocusedElement(app)
      if sameAXElement(element, settledElement) then
        hs.timer.doAfter(0.12, function()
          local stableElement = currentFocusedElement(app)
          if sameAXElement(element, stableElement) then
            callback(true)
          elseif attempt >= 8 then
            callback(false)
          else
            focusAXElement(element, app, callback, attempt + 1)
          end
        end)
      elseif attempt >= 8 then
        callback(false)
      else
        focusAXElement(element, app, callback, attempt + 1)
      end
    end)
    return
  end
  if attempt >= 8 then
    callback(false)
    return
  end
  hs.timer.doAfter(0.05, function()
    focusAXElement(element, app, callback, attempt + 1)
  end)
end

local function pollForPickerAction(context, matcher, structuralMatcher, callback, attempt)
  attempt = attempt or 1
  local item = findPickerAction(context, matcher, structuralMatcher)
  if item then
    callback(item)
    return
  end
  if attempt >= 30 then
    callback(nil)
    return
  end
  hs.timer.doAfter(0.1, function()
    pollForPickerAction(context, matcher, structuralMatcher, callback, attempt + 1)
  end)
end


local function pollForMenuItem(context, matcher, callback, attempt)
  pollForPickerAction(context, matcher, nil, callback, attempt)
end

local function isChooseModelText(text)
  local lower = text:lower()
  return lower:find("选择模型", 1, true) ~= nil
    or lower:find("choose model", 1, true) ~= nil
end

local function isEffortText(text)
  local lower = text:lower()
  -- axText() includes both AXTitle and AXDescription. The current Codex item
  -- is therefore "强度 强度", not exactly "强度".
  return lower:find("强度", 1, true) ~= nil
    or lower:find("reasoning effort", 1, true) ~= nil
    or lower:find("effort", 1, true) ~= nil
end

local function chooseModelStructure(context, frame)
  local modelFrame = elementFrame(context.modelElement)
  if not modelFrame then return false end
  local centerX = frame.x + frame.w / 2
  local modelCenterX = modelFrame.x + modelFrame.w / 2
  local verticalGap = modelFrame.y - (frame.y + frame.h)
  return math.abs(centerX - modelCenterX) <= 170
    and verticalGap >= 25 and verticalGap <= 150
    and frame.h >= 20 and frame.h <= 75
    and frame.w <= 190
end

local function effortStructure(context, frame)
  local modelFrame = elementFrame(context.modelElement)
  if not modelFrame then return false end
  local centerX = frame.x + frame.w / 2
  local modelCenterX = modelFrame.x + modelFrame.w / 2
  local verticalGap = modelFrame.y - (frame.y + frame.h)
  return math.abs(centerX - modelCenterX) <= 170
    and verticalGap >= -12 and verticalGap <= 80
    and frame.w >= math.max(150, modelFrame.w * 1.25)
    and frame.h >= 20 and frame.h <= 70
end

local function findChooseModelAction(context)
  return findPickerAction(context, isChooseModelText, function(frame)
    return chooseModelStructure(context, frame)
  end)
end

local function findEffortAction(context)
  local modelFrame = elementFrame(context.modelElement)
  local function isCollapsedModelButton(element)
    local role = axAttribute(element, "AXRole")
    if sameAXElement(element, context.modelElement) then return true end
    local frame = elementFrame(element)
    if modelFrame and frame and sameFrame(frame, modelFrame, 3) then return true end
    -- A merged picker can expose the model button's effort description even
    -- after its title has changed. A legacy standalone effort popup has no
    -- model key and remains eligible below.
    return (role == "AXPopUpButton" or role == "AXMenuButton")
      and modelKeyFromText(axText(element)) ~= nil
  end
  return findPickerAction(context, function(text, element)
    -- In the merged picker the collapsed model button carries an
    -- AXDescription containing "选择强度". It is not the effort receiver;
    -- never let its description satisfy the effort matcher.
    if isCollapsedModelButton(element) then return false end
    return isEffortText(text)
  end, function(frame, element)
    if isCollapsedModelButton(element) then return false end
    return effortStructure(context, frame)
  end)
end

local function strengthPopover(context)
  local effortItem = findEffortAction(context)
  if not effortItem then return nil, nil end

  -- Current Chromium exposes the actual keyboard receiver as the "强度"
  -- AXMenuItem with a SliderKeyboardControl DOM class. Its AXFocused
  -- attribute is writable even while the outer "选择强度" group reports
  -- focused=true. Focus this node directly so arrow events reach the slider.
  local ok, settable = pcall(function()
    return effortItem:isAttributeSettable("AXFocused")
  end)
  if ok and settable then return effortItem, effortItem end

  -- Compatibility fallback for older Chromium accessibility trees.
  local current = effortItem
  for _ = 1, 8 do
    current = axAttribute(current, "AXParent")
    if not current then break end
    local role = axAttribute(current, "AXRole")
    local title = axAttribute(current, "AXTitle")
    if role == "AXGroup"
        and (axAttribute(current, "AXFocused") == true
          or title == "选择强度" or title == "Choose effort") then
      return effortItem, current
    end
  end

  local focusTarget = axAttribute(effortItem, "AXFocusableAncestor")
  if focusTarget and not sameAXElement(focusTarget, effortItem) then
    return effortItem, focusTarget
  end
  -- Some Codex builds omit AXFocusableAncestor while the popover is still
  -- usable. The menu item itself is the safest last-resort focus target; it
  -- keeps keyboard focus in the selected composer instead of failing over to
  -- the other composer or to a mouse coordinate.
  return effortItem, effortItem
end

local function frameInsideWindow(element, windowFrame)
  local frame = elementFrame(element)
  if not frame or not windowFrame then return false end
  local margin = 24
  return frame.x >= windowFrame.x - margin
    and frame.y >= windowFrame.y - margin
    and frame.x + frame.w <= windowFrame.x + windowFrame.w + margin
    and frame.y + frame.h <= windowFrame.y + windowFrame.h + margin
end

local function openStrengthPopover(context, callback)
  -- If a previous invocation left the popover open, reuse it. Toggling it
  -- closed and open again is what caused the visible stuck state and the
  -- later second strength adjustment.
  local existing = findChooseModelAction(context)
  if existing then
    callback(existing)
    return
  end

  if strengthPopover(context) then
    pollForPickerAction(context, isChooseModelText, function(frame)
      return chooseModelStructure(context, frame)
    end, callback)
    return
  end

  if not pressAXElement(context.modelElement) then
    callback(nil)
    return
  end
  pollForPickerAction(context, isChooseModelText, function(frame)
    return chooseModelStructure(context, frame)
  end, callback)
end

local function selectorType(context)
  local text = axText(context.modelElement)
  if modelKeyFromText(text) then
    for _, label in ipairs({
      "最高", "极高", "极限", "高", "标准", "中", "低",
      "ultra", "xhigh", "max", "high", "standard", "medium", "low",
    }) do
      if text:lower():find(label:lower(), 1, true) then return "combined-picker" end
    end
  end
  return "legacy-separated-picker"
end

local function findModelOption(context, preset)
  local modelFrame = elementFrame(context.modelElement)
  local option = findPickerAction(context, function(_, element)
    local role = axAttribute(element, "AXRole")
    if role == "AXPopUpButton" or role == "AXMenuButton" then return false end
    local frame = elementFrame(element)
    if modelFrame and frame and sameFrame(modelFrame, frame, 3) then return false end
    return elementMatchesModel(element, preset.modelKey)
  end, nil)
  if option then return option end

  -- Some Codex builds briefly expose the model list as an application-level
  -- portal whose AXWindow/AXFrame is not attached to the same subtree as the
  -- composer. The normal picker candidate filter intentionally rejects that
  -- stale ancestry. Keep the fallback geometry-only, but still pin it to the
  -- exact composer's model button and the locked window so it cannot select a
  -- model from the other composer or another window.
  if not modelFrame then return nil end
  local root = hs.axuielement.applicationElement(context.app)
  local modelCenterX = modelFrame.x + modelFrame.w / 2
  local modelCenterY = modelFrame.y + modelFrame.h / 2
  local best = nil
  local bestScore = math.huge
  walkAX(root, function(element)
    local role = axAttribute(element, "AXRole")
    if role ~= "AXMenuItem" and role ~= "AXRadioButton"
        and role ~= "AXCheckBox" and role ~= "AXButton" then
      return nil
    end
    if not elementMatchesModel(element, preset.modelKey) then return nil end
    local frame = elementFrame(element)
    if not frame then return nil end
    if context.frame then
      local margin = 24
      if frame.x < context.frame.x - margin
          or frame.y < context.frame.y - margin
          or frame.x + frame.w > context.frame.x + context.frame.w + margin
          or frame.y + frame.h > context.frame.y + context.frame.h + margin then
        return nil
      end
    end
    local centerX = frame.x + frame.w / 2
    local centerY = frame.y + frame.h / 2
    local dx = math.abs(centerX - modelCenterX)
    local dy = math.abs(centerY - modelCenterY)
    if dx > 320 or dy < 18 or dy > 620 then return nil end
    local score = dx + dy * 1.2
    if role ~= "AXMenuItem" then score = score + 30 end
    if score < bestScore then
      best = element
      bestScore = score
    end
    return nil
  end)
  return best
end

local function pollForModelOption(context, preset, callback, attempt)
  attempt = attempt or 1
  local option = findModelOption(context, preset)
  if option then callback(option); return end
  if attempt >= 30 then callback(nil); return end
  hs.timer.doAfter(0.1, function()
    pollForModelOption(context, preset, callback, attempt + 1)
  end)
end

local function effortKeyFromText(text)
  local lower = tostring(text or ""):lower()
  -- Order matters: "最高" contains "高". Convert the combined control's
  -- title to one semantic value before comparison instead of using substring
  -- matching, which previously accepted Sol 最高 as Sol High.
  if lower:find("最高", 1, true) or lower:find("max", 1, true) then return "max" end
  if lower:find("极限", 1, true) or lower:find("ultra", 1, true) then return "ultra" end
  if lower:find("极高", 1, true) or lower:find("very high", 1, true)
      or lower:find("extra high", 1, true) or lower:find("xhigh", 1, true) then
    return "xhigh"
  end
  if lower:find("高", 1, true) or lower:find("high", 1, true) then return "high" end
  if lower:find("标准", 1, true) or lower:find("中", 1, true)
      or lower:find("standard", 1, true) or lower:find("medium", 1, true) then
    return "medium"
  end
  if lower:find("低", 1, true) or lower:find("low", 1, true) then return "low" end
  if lower:find("最小", 1, true) or lower:find("minimal", 1, true) then return "minimal" end
  return nil
end

local function verifyPreset(context, preset)
  -- Verify only the target composer's collapsed model button. Reading the open
  -- popover can produce a false positive because its slider announces the
  -- requested stop before Codex commits it.
  local text = axText(context.modelElement)
  if modelKeyFromText(text) ~= preset.modelKey then return false end
  return effortKeyFromText(text) == preset.effortKey
end

local function effortPositionFromText(text)
  local index = text:match("第%s*(%d+)%s*项")
    or text:lower():match("(%d+)%s*of%s*%d+")
  local total = text:match("共%s*(%d+)%s*项")
    or text:lower():match("%d+%s*of%s*(%d+)")
  return index and tonumber(index) or nil, total and tonumber(total) or nil
end

local function effortPositionFromElement(element)
  for _, name in ipairs({"AXTitle", "AXDescription", "AXValue", "AXHelp"}) do
    local value = axAttribute(element, name)
    if value ~= nil then
      local index, total = effortPositionFromText(tostring(value))
      if index then return index, total end
    end
  end
  return nil, nil
end

local function readEffortIndexNear(root, effortItem, expectedModelKey)
  local debug = {parsed = 0, framed = 0, nearby = 0}
  if not root or not effortItem then return nil, nil, debug end
  local effortFrame = elementFrame(effortItem)
  if not effortFrame then return nil, nil, debug end

  -- Chromium exposes the current slider stop as a tiny AXStaticText next to
  -- the slider, e.g. "GPT-6 Luna 最高，第 5 项，共 5 项。". It is not
  -- necessarily a descendant of AXFocusableAncestor, so search the current
  -- AX window and choose the announcement geometrically nearest to this
  -- composer's effort item. This also prevents the main and side popovers
  -- from being confused when both are present.
  local effortCenterX = effortFrame.x + effortFrame.w / 2
  local effortCenterY = effortFrame.y + effortFrame.h / 2
  local candidates = {}
  local seen = {}
  local function collect(searchRoot, requireModelMatch)
    if not searchRoot or seen[searchRoot] then return end
    seen[searchRoot] = true
    walkAX(searchRoot, function(element)
      local index, total = effortPositionFromElement(element)
      if not index then return nil end
      debug.parsed = debug.parsed + 1
      local text = axText(element)
      local candidateModelKey = modelKeyFromText(text)
      if requireModelMatch and expectedModelKey and candidateModelKey
          and candidateModelKey ~= expectedModelKey then
        return nil
      end
      if requireModelMatch and expectedModelKey and not candidateModelKey then
        return nil
      end
      local frame = elementFrame(element)
      if not frame then return nil end
      debug.framed = debug.framed + 1
      local centerX = frame.x + frame.w / 2
      local centerY = frame.y + frame.h / 2
      local dx = math.abs(centerX - effortCenterX)
      local dy = math.abs(centerY - effortCenterY)
      if dx <= 220 and dy <= 120 then
        debug.nearby = debug.nearby + 1
        table.insert(candidates, {index = index, total = total, score = dx + dy * 2})
      end
      return nil
    end)
  end

  -- In current Chromium builds the tiny "n of m" announcement is a sibling
  -- of the effort item. Search its nearest ancestor popover first so a long
  -- transcript cannot consume the global traversal budget.
  local ancestor = effortItem
  for _ = 1, 8 do
    ancestor = axAttribute(ancestor, "AXParent")
    if not ancestor then break end
    collect(ancestor, expectedModelKey ~= nil)
    if #candidates > 0 then break end
  end
  -- A window may contain both main and side pickers. The announcement is a
  -- tiny application-level live region, so the fallback must match the
  -- model of the composer being configured; nearest geometry alone can pick
  -- the other composer's stale announcement after a Codex update.
  if #candidates == 0 then collect(root, true) end

  table.sort(candidates, function(left, right)
    return left.score < right.score
  end)
  if not candidates[1] then return nil, nil, debug end
  return candidates[1].index, candidates[1].total, debug
end

local function composerPopoverIsOpen(context)
  if not context then return false end
  if strengthPopover(context) then return true end
  local text = axText(context.modelElement):lower()
  return text:find("选择强度", 1, true) ~= nil
    or text:find("choose effort", 1, true) ~= nil
end

local function sendEffortKeys(app, keys, index, callback)
  index = index or 1
  if index > #keys then
    callback()
    return
  end
  -- The combined picker is an Electron accessibility control. A CGEvent
  -- posted globally can be swallowed by the popover; an app-targeted
  -- keyStroke is delivered after the AX focus assignment and does not move
  -- the mouse pointer.
  hs.eventtap.keyStroke({}, keys[index], 0, app)
  hs.timer.doAfter(0.12, function()
    sendEffortKeys(app, keys, index + 1, callback)
  end)
end

local function writePresetState(statePath, presetKey, windowTitle)
  local tempPath = statePath .. ".tmp"
  local payload = hs.json.encode({
    preset = presetKey,
    applied_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    codex_window_title = windowTitle or "",
  }, true)
  local file = io.open(tempPath, "wb")
  if not file then return false end
  file:write(payload)
  file:write("\n")
  file:close()
  return os.rename(tempPath, statePath) ~= nil
end

local function refreshSwiftBarCodexPlugin()
  -- The SwiftBar menu item returns before this asynchronous UI automation
  -- finishes. Refresh only after the verified state has been persisted.
  hs.task.new("/usr/bin/open", nil, {
    "-g",
    "swiftbar://refreshplugin?plugin=codex-model.1m.sh",
  }):start()
end

local function readSideStatePreset()
  local contents = readFile(codexSideStatePath)
  if not contents then return nil end
  local ok, state = pcall(hs.json.decode, contents)
  if not ok or type(state) ~= "table" then return nil end
  if type(state.preset) ~= "string"
      or not codexPresets[state.preset]
      or not codexPresets[state.preset].enabled then
    return nil
  end
  return state.preset
end

local function ensurePresetConfigFile()
  if readFile(codexPresetConfigPath) then return true end
  local parent = home .. "/.codex"
  if not hs.fs.attributes(parent) then hs.fs.mkdir(parent) end
  local tempPath = codexPresetConfigPath .. ".tmp"
  local file = io.open(tempPath, "wb")
  if not file then return false end
  file:write(hs.json.encode({version = 1, presets = defaultPresetDefinitions}, true))
  file:write("\n")
  file:close()
  return os.rename(tempPath, codexPresetConfigPath) ~= nil
end

local function openPresetConfig()
  if not ensurePresetConfigFile() then
    codexNotify("无法创建预设配置文件：" .. codexPresetConfigPath)
    return
  end
  hs.task.new("/usr/bin/open", nil, {"-a", "TextEdit", codexPresetConfigPath}):start()
  codexNotify("已打开预设配置；保存后点击 SwiftBar 的重新加载")
end

local function reloadPresetConfig()
  local ok, err = loadCodexPresetConfig()
  if ok then
    codexNotify("预设配置已重新加载，共 " .. #codexPresetList .. " 个有效预设")
  else
    codexNotify("预设配置错误，未进行模型切换：" .. tostring(err))
  end
  refreshSwiftBarCodexPlugin()
end

local function dismissPresetPopover(context)
  local app = context and context.app or nil
  if not app then return false end
  local ok = pcall(function()
    if not app:isFrontmost() then app:activate(true) end
    hs.eventtap.keyStroke({}, "escape", 0, app)
  end)
  return ok
end

local function commitPresetPopover(context)
  -- Escape commits the selected slider stop and closes the Electron popover.
  -- AXPress on the model button is timing-sensitive after arrow-key input and
  -- can leave the visible popover open until the user clicks elsewhere.
  return dismissPresetPopover(context)
end

local function finishPreset(success, message)
  if not codexPresetBusy then
    return
  end
  if codexPresetTimeoutTimer then
    codexPresetTimeoutTimer:stop()
    codexPresetTimeoutTimer = nil
  end
  codexPresetBusy = false
  local context = codexPresetActiveContext
  codexPresetActiveContext = nil
  if not success then dismissPresetPopover(context) end
  local diagnosticDetails = {
    selector_type = context and selectorType(context) or "unknown",
    preset_id = context and context.presetKey or nil,
    preset_model = context and context.presetModel or nil,
    preset_effort = context and context.presetEffort or nil,
    effort_reader = context and context.effortReader or nil,
    effort_reader_after_keys = context and context.effortReaderAfterKeys or nil,
    effort_index_before = context and context.effortIndexBefore or nil,
    effort_index_after_keys = context and context.effortIndexAfterKeys or nil,
    effort_index_target = context and context.effortIndexTarget or nil,
  }
  if not success then diagnosticDetails.failure = message end
  writeDiagnostics(success and "complete" or codexPresetStage, context, diagnosticDetails)
  codexPresetStage = "idle"
  codexNotify(message)
  return success
end

local mainScope = {
  label = "当前主线程",
  subject = "主线程",
  statePath = codexMainStatePath,
  syncsGlobal = true,
  findContext = findMainContext,
  ensureContext = ensureMainThread,
  waitForContext = function(callback, targetWindow)
    waitForMainThread(callback, 1, targetWindow)
  end,
}

local sideScope = {
  label = "当前侧栏",
  subject = "侧栏",
  statePath = codexSideStatePath,
  syncsGlobal = false,
  findContext = findSideContext,
  ensureContext = ensureSideChat,
  waitForContext = function(callback, targetWindow)
    waitForSideChat(callback, false, 1, targetWindow)
  end,
}

local function applyPresetAttempt(presetKey, preset, configBefore, context, attempt, scope)
  context.presetKey = presetKey
  context.presetModel = preset.model
  context.presetEffort = preset.effortKey
  codexPresetStage = "open-picker"
  openStrengthPopover(context, function(chooseModelItem)
    if not chooseModelItem then
      if attempt == 1 then
        hs.eventtap.keyStroke({}, "escape", 50000, context.app)
        hs.timer.doAfter(0.25, function()
          local refreshed = scope.findContext(context.window)
          if refreshed then
            applyPresetAttempt(presetKey, preset, configBefore, refreshed, 2, scope)
          else
            finishPreset(false, "无法重新定位当前" .. scope.subject)
          end
        end)
      else
        finishPreset(false, "未找到" .. scope.subject .. "的模型菜单")
      end
      return
    end

    codexPresetStage = "open-model-list"
    pressAXElement(chooseModelItem)
    -- Let the model portal mount before the first tree read. The polling
    -- loop below remains bounded, but the short initial turn avoids the
    -- update race introduced by the merged model/effort picker.
    hs.timer.doAfter(0.18, function()
    pollForModelOption(context, preset, function(modelItem)
      if not modelItem then
        finishPreset(false, "模型列表中未找到 " .. preset.model)
        return
      end
      codexPresetStage = "select-model"
      if not pressAXElement(modelItem) then
        finishPreset(false, "无法选择模型 " .. preset.model)
        return
      end

      local function configureStrength(refreshed, popoverAlreadyOpen)
        codexPresetActiveContext = refreshed
        refreshed.presetKey = presetKey
        refreshed.presetModel = preset.model
        refreshed.presetEffort = preset.effortKey

        local function configureOpenPopover()
          local effortItem, effortFocusTarget = strengthPopover(refreshed)
          if not effortItem then
            finishPreset(false, "未找到" .. scope.subject .. "的推理强度控件")
            return
          end

          -- Chromium exposes the current "第 n 项，共 m 项" announcement
          -- only while the combined picker is open but before its effort
          -- control receives keyboard focus. Capture it now: focusing first
          -- makes the live-region node disappear in Codex 26.915.31945.
          local currentIndex, totalStops, effortReader = readEffortIndexNear(
            refreshed.root or refreshed.axWindow,
            effortItem,
            preset.modelKey
          )
          refreshed.effortReader = effortReader
          if not currentIndex then
            finishPreset(false, "无法读取" .. scope.subject .. "的当前推理强度")
            return
          end
          refreshed.effortIndexBefore = currentIndex
          refreshed.effortIndexTarget = preset.effortIndex
          if totalStops and preset.effortIndex > totalStops then
            finishPreset(false, string.format(
              "%s当前仅有 %d 档推理强度，预设需要第 %d 档",
              scope.subject, totalStops, preset.effortIndex
            ))
            return
          end

          local function adjustAndVerify()
            -- The combined picker is a transient Chromium surface. During URL
            -- dispatch, SwiftBar or Hammerspoon can remain the macOS frontmost
            -- app briefly even though the picker focus is valid. Validate the
            -- picker's geometry against the exact locked Codex window instead.
            -- Chromium mounts this popover under the application root rather
            -- than as a descendant of AXWindow, so ancestry is not reliable.
            if not frameInsideWindow(effortItem, refreshed.frame) then
              finishPreset(false, "推理强度控件已离开触发时的 Codex 窗口")
              return
            end

            -- The current AX tree announces the selected stop as "第 n 项，
            -- 共 m 项". Read it and send exactly the required delta. If a
            -- future client omits that value, stop safely instead of blindly
            -- resetting to the lowest stop and sending a second sequence.
            -- Keep the exact effort item captured before focus moved. The
            -- combined Electron picker can temporarily change its accessible
            -- title/role after focus, which makes a second lookup race the
            -- already-open control and return nil.
            codexPresetStage = "adjust-effort"
            local keys = {}
            local key = currentIndex < preset.effortIndex and "right" or "left"
            for _ = 1, math.abs(preset.effortIndex - currentIndex) do
              table.insert(keys, key)
            end

            -- URL dispatch can leave Hammerspoon frontmost even though the AX
            -- popover is valid. Activate only the locked Codex app, then hand
            -- focus to the exact effort node below. Calling window:focus()
            -- after the popover is mounted can make Chromium restore focus to
            -- the model button immediately before the arrow is posted.
            refreshed.app:activate(true)
            hs.timer.doAfter(0.15, function()
              if not refreshed.app:isFrontmost() then
                finishPreset(false, "无法将键盘焦点交还给触发时的 Codex 窗口")
                return
              end
              focusAXElement(effortFocusTarget, refreshed.app, function(refocused)
                if not refocused then
                  finishPreset(false, "推理强度控件在按键前失去焦点")
                  return
                end
                sendEffortKeys(refreshed.app, keys, 1, function()
              -- Capture a single diagnostic read before closing. It is not
              -- used to send a corrective sequence: the production path must
              -- never reset the slider and move it a second time.
              local afterIndex, _, afterReader = readEffortIndexNear(
                refreshed.root or refreshed.axWindow,
                effortItem,
                preset.modelKey
              )
              refreshed.effortReaderAfterKeys = afterReader
              refreshed.effortIndexAfterKeys = afterIndex
              local actualFocus = currentFocusedElement(refreshed.app)
              print(string.format(
                "Codex preset effort %s before=%s afterKeys=%s target=%s keys=%d focus=%s:%s",
                scope.subject,
                tostring(refreshed.effortIndexBefore),
                tostring(afterIndex),
                tostring(refreshed.effortIndexTarget),
                #keys,
                tostring(actualFocus and axAttribute(actualFocus, "AXRole") or "nil"),
                tostring(actualFocus and axAttribute(actualFocus, "AXTitle") or "")
              ))
              -- Electron needs a short render/update turn after the final
              -- arrow. Closing immediately can discard the change even
              -- though the key reached the focused slider.
              hs.timer.doAfter(0.55, function()
                codexPresetStage = "commit-picker"
                local commitContext = scope.findContext(refreshed.window) or refreshed
                if not commitPresetPopover(commitContext) then
                  finishPreset(false, "无法提交" .. scope.subject .. "的推理强度选择")
                  return
                end

                local closeRetried = false
                local function verifyCommitted(attempt)
                  local verifiedContext = scope.findContext(refreshed.window)
                  if verifiedContext and not composerPopoverIsOpen(verifiedContext) then
                    verifiedContext.presetKey = presetKey
                    verifiedContext.presetModel = preset.model
                    verifiedContext.presetEffort = preset.effortKey
                    if not verifyPreset(verifiedContext, preset) then
                      if attempt >= 20 then
                        finishPreset(false, "设置后回读不一致；未记录最近应用状态")
                        return
                      end
                      hs.timer.doAfter(0.12, function()
                        verifyCommitted(attempt + 1)
                      end)
                      return
                    end
                    local configMessage
                    if scope.syncsGlobal then
                      if readFile(codexConfigPath) ~= configBefore then
                        finishPreset(false, "检测到 config.toml 被其他程序修改；已拒绝同步新任务配置")
                        return
                      end
                      local synced, syncError = syncMainPresetToConfig(preset, configBefore)
                      if not synced then
                        finishPreset(false, "主线程已切换，但新任务配置同步失败：" .. tostring(syncError))
                        return
                      end
                      configMessage = "；新任务默认已同步"
                    else
                      if readFile(codexConfigPath) ~= configBefore then
                        finishPreset(false, "检测到 config.toml 发生变化；已拒绝记录状态")
                        return
                      end
                      configMessage = "；全局配置未变化"
                    end
                    codexPresetStage = "verify"
                    local windowTitle = verifiedContext.window
                        and verifiedContext.window:title() or ""
                    if not writePresetState(scope.statePath, presetKey, windowTitle) then
                      finishPreset(false, scope.subject .. "已切换，但状态文件写入失败")
                      return
                    end
                    refreshSwiftBarCodexPlugin()
                    codexPresetActiveContext = verifiedContext
                    finishPreset(true, scope.subject .. "已应用 " .. preset.label .. configMessage)
                    return
                  end

                  -- Escape normally closes the popover. If Chromium leaves it
                  -- open while the AX tree settles, give it one controlled
                  -- keyboard retry; this still never moves the mouse or sends
                  -- arrows.
                  if attempt >= 20 then
                    finishPreset(false, "推理强度弹窗未能自动关闭")
                    return
                  end
                  if attempt >= 3 and not closeRetried and verifiedContext then
                    closeRetried = true
                    dismissPresetPopover(verifiedContext)
                  end
                  hs.timer.doAfter(0.12, function()
                    verifyCommitted(attempt + 1)
                  end)
                end

                hs.timer.doAfter(0.2, function()
                  verifyCommitted(1)
                end)
              end)
                end)
              end)
            end)
          end

          -- adjustAndVerify() performs the single required focus hand-off
          -- after the live-region index has been read. Focusing here as well
          -- made the merged picker receive two consecutive focus requests
          -- and could make the first arrow sequence look like a retry.
          adjustAndVerify()
        end

        if popoverAlreadyOpen then
          configureOpenPopover()
        else
          openStrengthPopover(refreshed, function(opened)
            if not opened then
              finishPreset(false, "未找到" .. scope.subject .. "的模型与强度菜单")
              return
            end
            configureOpenPopover()
          end)
        end
      end

      hs.timer.doAfter(0.15, function()
        -- Selecting a model returns to the already-open model/strength
        -- popover. Reuse it immediately. Waiting for the two collapsed model
        -- controls here deadlocks until the user manually clicks elsewhere.
        local function waitForStrengthPopover(refreshed, attempt)
          local effortItem = strengthPopover(refreshed)
          if effortItem then
            configureStrength(refreshed, true)
            return
          end
          if attempt >= 30 then
            -- Some client versions close the picker after model selection.
            -- Only those versions need the old re-locate-and-open path.
            scope.waitForContext(function(nextContext, refreshErr)
              if not nextContext then
                finishPreset(false, refreshErr or "选择模型后无法重新定位" .. scope.subject)
                return
              end
              configureStrength(nextContext, false)
            end, context.window)
            return
          end
          hs.timer.doAfter(0.1, function()
            local nextContext = scope.findContext(context.window) or refreshed
            waitForStrengthPopover(nextContext, attempt + 1)
          end)
        end
        local refreshed = scope.findContext(context.window) or context
        waitForStrengthPopover(refreshed, 1)
      end)
    end)
    end)
  end)
end

local function applyCodexComposerPreset(presetKey, scope)
  codexPresetScopeLabel = scope.label
  local configOK, configError = loadCodexPresetConfig()
  if not configOK then
    codexNotify("预设配置错误，未操作 Codex：" .. tostring(configError))
    return
  end
  local preset = codexPresets[presetKey]
  if not preset or not preset.enabled then
    codexNotify("已拒绝未知或已停用预设：" .. tostring(presetKey))
    return
  end
  if codexPresetBusy then
    codexNotify("已有模型切换正在进行")
    return
  end
  local configBefore = readFile(codexConfigPath)
  if not configBefore then
    codexNotify("无法读取 config.toml，已停止操作")
    return
  end
  codexPresetBusy = true
  codexPresetRunID = codexPresetRunID + 1
  local runID = codexPresetRunID
  codexPresetStage = "locate-composer"
  codexPresetTimeoutTimer = hs.timer.doAfter(45, function()
    if codexPresetBusy and codexPresetRunID == runID then
      codexPresetStage = "timeout"
      finishPreset(false, "切换超时，已停止操作；请查看兼容性诊断")
    end
  end)
  scope.ensureContext(function(context, status)
    if not context then
      finishPreset(false, status)
      return
    end
    local function beginPreset()
      local refreshed, refreshErr = scope.findContext(context.window)
      if not refreshed then
        finishPreset(false, refreshErr or scope.subject .. "出现后无法重新定位")
        return
      end
      codexPresetActiveContext = refreshed
      refreshed.presetKey = presetKey
      refreshed.presetModel = preset.model
      refreshed.presetEffort = preset.effortKey
      applyPresetAttempt(presetKey, preset, configBefore, refreshed, 1, scope)
    end
    -- A newly opened Electron panel can enter the AX tree before its composer
    -- has finished binding keyboard events. Let that panel settle first.
    if status == true then
      hs.timer.doAfter(1.0, beginPreset)
    else
      beginPreset()
    end
  end)
end

local function applyCodexMainPreset(presetKey)
  applyCodexComposerPreset(presetKey, mainScope)
end

local function applyCodexSidePreset(presetKey)
  applyCodexComposerPreset(presetKey, sideScope)
end

local function checkCodexPickerCompatibility()
  codexPresetScopeLabel = "控件兼容性"
  local app = hs.application.get(codexBundleID)
  if not app then
    writeDiagnostics("compatibility-check", nil, {
      scope = "window",
      failure = "Codex 未运行",
      main_detected = false,
      side_detected = false,
    })
    codexNotify("Codex 未运行")
    return
  end
  local targetWindow = lockCodexWindow(app)
  if not targetWindow then
    writeDiagnostics("compatibility-check", nil, {
      scope = "window",
      failure = "无法锁定 Codex 窗口",
      main_detected = false,
      side_detected = false,
    })
    codexNotify("无法锁定当前 Codex 窗口")
    return
  end
  local mainContext = findMainContext(targetWindow)
  local sideContext = findSideContext(targetWindow)
  writeDiagnostics("compatibility-check", mainContext or sideContext, {
    selector_type = mainContext and selectorType(mainContext) or "unknown",
    main_detected = mainContext ~= nil,
    side_detected = sideContext ~= nil,
  })
  local mainText = mainContext and "主线程 ✓" or "主线程无法识别"
  local sideText = sideContext and "侧栏 ✓" or "侧栏未打开或无法识别"
  codexNotify(mainText .. "；" .. sideText)
  refreshSwiftBarCodexPlugin()
end

local function openCodexSideWithRecentPreset()
  codexPresetScopeLabel = sideScope.label
  local configOK, configError = loadCodexPresetConfig()
  if not configOK then
    codexNotify("预设配置错误，未打开并应用侧栏：" .. tostring(configError))
    return
  end
  local recentPreset = readSideStatePreset()
  if recentPreset then
    applyCodexSidePreset(recentPreset)
    return
  end
  ensureSideChat(function(context, err)
    if not context then
      codexNotify(err)
      return
    end
      codexNotify("侧栏已打开；尚无最近应用预设")
  end)
end

-- SwiftBar normally reaches this module through the URL handlers below. The
-- Hammerspoon CLI also calls this exported dispatcher, which keeps menu
-- actions working even when LaunchServices has lost the hammerspoon scheme.
local function dispatchCodexPresetEvent(eventName, presetKey)
  if eventName == "codex-main-preset" then
    applyCodexMainPreset(presetKey)
  elseif eventName == "codex-side-preset" then
    applyCodexSidePreset(presetKey)
  elseif eventName == "codex-side-open" then
    openCodexSideWithRecentPreset()
  elseif eventName == "codex-preset-check" then
    checkCodexPickerCompatibility()
  elseif eventName == "codex-preset-reload" then
    reloadPresetConfig()
  elseif eventName == "codex-preset-open-config" then
    openPresetConfig()
  else
    codexNotify("未知的预设操作：" .. tostring(eventName))
  end
end

_G.codexPresetDispatch = dispatchCodexPresetEvent

hs.urlevent.bind("codex-main-preset", function(_, params)
  dispatchCodexPresetEvent("codex-main-preset", params and params.preset or nil)
end)

hs.urlevent.bind("codex-side-preset", function(_, params)
  dispatchCodexPresetEvent("codex-side-preset", params and params.preset or nil)
end)

hs.urlevent.bind("codex-side-open", function()
  dispatchCodexPresetEvent("codex-side-open")
end)

hs.urlevent.bind("codex-preset-check", function()
  dispatchCodexPresetEvent("codex-preset-check")
end)

hs.urlevent.bind("codex-preset-reload", function()
  dispatchCodexPresetEvent("codex-preset-reload")
end)

hs.urlevent.bind("codex-preset-open-config", function()
  dispatchCodexPresetEvent("codex-preset-open-config")
end)
