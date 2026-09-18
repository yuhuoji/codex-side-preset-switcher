-- Codex main-thread and side-chat preset switcher for Hammerspoon.
-- Load from ~/.hammerspoon/init.lua with:
-- dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")

-- Codex composer model presets. These intentionally do not edit config.toml.
local home = assert(os.getenv("HOME"), "HOME is not set")
local codexBundleID = "com.openai.codex"
local codexConfigPath = home .. "/.codex/config.toml"
local codexMainStatePath = home .. "/.codex/codex-main-preset-state.json"
local codexSideStatePath = home .. "/.codex/codex-side-preset-state.json"
local codexPresetBusy = false
local codexPresetActiveContext = nil
local codexPresetScopeLabel = "当前侧栏"

local codexPresets = {
  ["luna-max"] = {
    label = "Luna Max",
    model = "GPT-5.6 Luna",
    effortIndex = 5,
    effortLabels = {"最高", "max"},
  },
  ["terra-high"] = {
    label = "Terra High",
    model = "GPT-5.6 Terra",
    effortIndex = 3,
    effortLabels = {"高", "high"},
  },
  ["sol-medium"] = {
    label = "Sol Medium",
    model = "GPT-5.6 Sol",
    effortIndex = 2,
    effortLabels = {"中", "medium"},
  },
  ["sol-high"] = {
    label = "Sol High",
    model = "GPT-5.6 Sol",
    effortIndex = 3,
    effortLabels = {"高", "high"},
  },
}

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
  if not position or not size then return nil end
  return {x = position.x, y = position.y, w = size.w, h = size.h}
end

local function sameFrame(a, b, tolerance)
  tolerance = tolerance or 3
  return math.abs(a.x - b.x) <= tolerance and math.abs(a.y - b.y) <= tolerance
    and math.abs(a.w - b.w) <= tolerance and math.abs(a.h - b.h) <= tolerance
end

local function isModelControl(element)
  local role = axAttribute(element, "AXRole")
  if role ~= "AXPopUpButton" and role ~= "AXMenuButton" then return false end
  local text = axText(element):lower()
  -- When the model/effort popover is open, Codex temporarily renames the
  -- same model button to "选择强度" instead of exposing the GPT model name.
  return text:find("gpt%-5%.6") ~= nil
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
  -- Prefer the actual menu item's AXPress. Codex versions have changed the
  -- keyboard shortcut (the current build advertises ⌘B), while the menu
  -- action remains stable. AXPress does not move or click the mouse.
  local menuItem = findSidebarToggle(app)
  if menuItem and pressAXElement(menuItem) then return true end

  -- Conservative fallback for a build that temporarily omits menu items from
  -- its AX tree. This is the shortcut currently advertised by Codex.
  if app then
    hs.eventtap.keyStroke({"cmd"}, "b", 0, app)
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

local function findAXMenuItem(context, matcher)
  context.root = hs.axuielement.applicationElement(context.app)
  local best = nil
  local bestScore = math.huge
  walkAX(context.root, function(element)
    if axAttribute(element, "AXRole") ~= "AXMenuItem"
        or not matcher(axText(element), element) then
      return nil
    end
    local frame = elementFrame(element)
    if frame and context.modelPoint then
      local centerX = frame.x + frame.w / 2
      local centerY = frame.y + frame.h / 2
      local score = math.abs(centerX - context.modelPoint.x)
        + math.abs(centerY - context.modelPoint.y)
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
    elseif not best then
      best = element
    end
    return nil
  end)
  return best
end

local function sameAXElement(left, right)
  if not left or not right then return false end
  if left == right then return true end
  local leftNode = axAttribute(left, "ChromeAXNodeId")
  local rightNode = axAttribute(right, "ChromeAXNodeId")
  return leftNode ~= nil and rightNode ~= nil and leftNode == rightNode
end

local function focusAXElement(element, appRoot, callback, attempt)
  if not element then
    callback(false)
    return
  end
  attempt = attempt or 1
  if attempt == 1 then
    -- setAttributeValue() often returns nil even when Chromium rejects or
    -- ignores the request. Never treat the setter return value as proof that
    -- keyboard focus moved.
    pcall(function() element:setAttributeValue("AXFocused", true) end)
  end

  local focused = axAttribute(element, "AXFocused") == true
  local focusedElement = appRoot and axAttribute(appRoot, "AXFocusedUIElement") or nil
  if focused or sameAXElement(element, focusedElement) then
    callback(true)
    return
  end
  if attempt >= 8 then
    callback(false)
    return
  end
  hs.timer.doAfter(0.05, function()
    focusAXElement(element, appRoot, callback, attempt + 1)
  end)
end

local function pollForMenuItem(context, matcher, callback, attempt)
  attempt = attempt or 1
  local item = findAXMenuItem(context, matcher)
  if item then
    callback(item)
    return
  end
  if attempt > 12 then
    callback(nil)
    return
  end
  hs.timer.doAfter(0.1, function()
    pollForMenuItem(context, matcher, callback, attempt + 1)
  end)
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

local function strengthPopover(context)
  local effortItem = findAXMenuItem(context, isEffortText)
  if not effortItem then return nil, nil end

  -- Chromium exposes the actual keyboard-focus owner through
  -- AXFocusableAncestor. It is the outer "选择强度" group, not the effort
  -- menu item's immediate parent. Focusing the immediate parent leaves arrow
  -- keys attached to whichever control was previously active.
  local focusTarget = axAttribute(effortItem, "AXFocusableAncestor")
  if focusTarget then return effortItem, focusTarget end

  local current = effortItem
  for _ = 1, 8 do
    current = axAttribute(current, "AXParent")
    if not current then break end
    local role = axAttribute(current, "AXRole")
    local title = axAttribute(current, "AXTitle")
    if role == "AXGroup"
        and (title == "选择强度" or title == "Choose effort") then
      return effortItem, current
    end
  end
  -- Some Codex builds omit AXFocusableAncestor while the popover is still
  -- usable. The menu item itself is the safest last-resort focus target; it
  -- keeps keyboard focus in the selected composer instead of failing over to
  -- the other composer or to a mouse coordinate.
  return effortItem, effortItem
end

local function openStrengthPopover(context, callback)
  -- If a previous invocation left the popover open, reuse it. Toggling it
  -- closed and open again is what caused the visible stuck state and the
  -- later second strength adjustment.
  local existing = findAXMenuItem(context, isChooseModelText)
  if existing then
    callback(existing)
    return
  end

  if strengthPopover(context) then
    pollForMenuItem(context, isChooseModelText, callback)
    return
  end

  if not pressAXElement(context.modelElement) then
    callback(nil)
    return
  end
  pollForMenuItem(context, isChooseModelText, callback)
end

local function verifyPreset(context, preset)
  -- Verify only the target composer's collapsed model button. Reading the open
  -- popover can produce a false positive because its slider announces the
  -- requested stop before Codex commits it.
  local text = axText(context.modelElement)
  local lower = text:lower()
  if not lower:find(preset.model:lower(), 1, true) then return false end
  for _, label in ipairs(preset.effortLabels or {}) do
    if lower:find(label:lower(), 1, true) then return true end
  end
  return false
end

local function effortIndexFromText(text)
  local index = text:match("第%s*(%d+)%s*项")
    or text:lower():match("(%d+)%s*of%s*%d+")
  return index and tonumber(index) or nil
end

local function readEffortIndexNear(root, effortItem)
  if not root or not effortItem then return nil end
  local effortFrame = elementFrame(effortItem)
  if not effortFrame then return nil end

  -- Chromium exposes the current slider stop as a tiny AXStaticText next to
  -- the slider, e.g. "GPT-5.6 Luna 最高，第 5 项，共 5 项。". It is not
  -- necessarily a descendant of AXFocusableAncestor, so search the current
  -- AX window and choose the announcement geometrically nearest to this
  -- composer's effort item. This also prevents the main and side popovers
  -- from being confused when both are present.
  local effortCenterX = effortFrame.x + effortFrame.w / 2
  local effortCenterY = effortFrame.y + effortFrame.h / 2
  local candidates = {}
  walkAX(root, function(element)
    local index = effortIndexFromText(axText(element))
    if not index then return nil end
    local frame = elementFrame(element)
    if not frame then return nil end
    local centerX = frame.x + frame.w / 2
    local centerY = frame.y + frame.h / 2
    local dx = math.abs(centerX - effortCenterX)
    local dy = math.abs(centerY - effortCenterY)
    if dx <= 220 and dy <= 120 then
      table.insert(candidates, {index = index, score = dx + dy * 2})
    end
    return nil
  end)

  table.sort(candidates, function(left, right)
    return left.score < right.score
  end)
  return candidates[1] and candidates[1].index or nil
end

local function composerPopoverIsOpen(context)
  if not context then return false end
  if strengthPopover(context) then return true end
  local text = axText(context.modelElement):lower()
  return text:find("选择强度", 1, true) ~= nil
    or text:find("choose effort", 1, true) ~= nil
end

local function sendEffortKeys(keys, index, callback)
  index = index or 1
  if index > #keys then
    callback()
    return
  end
  -- Send one key at a time. A burst can be dropped by Electron, while a
  -- second corrective burst visibly resets the slider and applies it twice.
  hs.eventtap.keyStroke({}, keys[index], 0)
  hs.timer.doAfter(0.08, function()
    sendEffortKeys(keys, index + 1, callback)
  end)
end

local function waitForEffortIndex(context, expected, callback, attempt)
  attempt = attempt or 1
  local effortItem = strengthPopover(context)
  local current = effortItem
      and readEffortIndexNear(context.axWindow or context.root, effortItem)
      or nil
  if current == expected then
    callback(true)
    return
  end
  if attempt >= 12 then
    callback(false)
    return
  end
  hs.timer.doAfter(0.08, function()
    waitForEffortIndex(context, expected, callback, attempt + 1)
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
  if type(state.preset) ~= "string" or not codexPresets[state.preset] then return nil end
  return state.preset
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
  codexPresetBusy = false
  local context = codexPresetActiveContext
  codexPresetActiveContext = nil
  if not success then dismissPresetPopover(context) end
  codexNotify(message)
  return success
end

local mainScope = {
  label = "当前主线程",
  subject = "主线程",
  statePath = codexMainStatePath,
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
  findContext = findSideContext,
  ensureContext = ensureSideChat,
  waitForContext = function(callback, targetWindow)
    waitForSideChat(callback, false, 1, targetWindow)
  end,
}

local function applyPresetAttempt(presetKey, preset, configBefore, context, attempt, scope)
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

    pressAXElement(chooseModelItem)
    pollForMenuItem(context, function(text)
      return text:lower():find(preset.model:lower(), 1, true) ~= nil
    end, function(modelItem)
      if not modelItem then
        finishPreset(false, "模型列表中未找到 " .. preset.model)
        return
      end
      if not pressAXElement(modelItem) then
        finishPreset(false, "无法选择模型 " .. preset.model)
        return
      end

      local function configureStrength(refreshed, popoverAlreadyOpen)
        codexPresetActiveContext = refreshed

        local function configureOpenPopover()
          local effortItem, effortFocusTarget = strengthPopover(refreshed)
          if not effortItem then
            finishPreset(false, "未找到" .. scope.subject .. "的推理强度控件")
            return
          end
          local function adjustAndVerify()
            local focusedWindow = refreshed.app:focusedWindow()
            if not refreshed.app:isFrontmost()
                or not focusedWindow
                or focusedWindow:id() ~= refreshed.window:id() then
              finishPreset(false, "当前 Codex 窗口失去焦点，已停止强度切换")
              return
            end

            -- The current AX tree announces the selected stop as "第 n 项，
            -- 共 5 项". Read it and send exactly the required delta. If a
            -- future client omits that value, stop safely instead of blindly
            -- resetting to the lowest stop and sending a second sequence.
            local currentEffortItem = strengthPopover(refreshed)
            local currentIndex = currentEffortItem
                and readEffortIndexNear(
                  refreshed.axWindow or refreshed.root,
                  currentEffortItem
                )
                or nil
            if not currentIndex then
              finishPreset(false, "无法读取" .. scope.subject .. "的当前推理强度")
              return
            end

            local keys = {}
            local key = currentIndex < preset.effortIndex and "right" or "left"
            for _ = 1, math.abs(preset.effortIndex - currentIndex) do
              table.insert(keys, key)
            end

            sendEffortKeys(keys, 1, function()
              -- Wait for the AX announcement to catch up, but never send a
              -- corrective key sequence here. That was the source of the
              -- visible two-stage slider movement.
              waitForEffortIndex(refreshed, preset.effortIndex, function(adjusted)
                if not adjusted then
                  finishPreset(false, "推理强度调整后回读不一致")
                  return
                end

                local commitContext = scope.findContext(refreshed.window) or refreshed
                if not commitPresetPopover(commitContext) then
                  finishPreset(false, "无法提交" .. scope.subject .. "的推理强度选择")
                  return
                end

                local closeRetried = false
                local function verifyCommitted(attempt)
                  local verifiedContext = scope.findContext(refreshed.window)
                  if verifiedContext and not composerPopoverIsOpen(verifiedContext) then
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
                    if readFile(codexConfigPath) ~= configBefore then
                      finishPreset(false, "检测到 config.toml 发生变化；已拒绝记录状态")
                      return
                    end
                    local windowTitle = verifiedContext.window
                        and verifiedContext.window:title() or ""
                    if not writePresetState(scope.statePath, presetKey, windowTitle) then
                      finishPreset(false, scope.subject .. "已切换，但状态文件写入失败")
                      return
                    end
                    refreshSwiftBarCodexPlugin()
                    codexPresetActiveContext = verifiedContext
                    finishPreset(true, scope.subject .. "已应用 " .. preset.label
                      .. "；全局配置未变化")
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
          end

          focusAXElement(effortFocusTarget, refreshed.root, function(focused)
            if not focused then
              finishPreset(false, "无法聚焦" .. scope.subject .. "的推理强度控件")
              return
            end
            adjustAndVerify()
          end)
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

      hs.timer.doAfter(0.4, function()
        -- Selecting a model returns to the already-open model/strength
        -- popover. Reuse it immediately. Waiting for the two collapsed model
        -- controls here deadlocks until the user manually clicks elsewhere.
        local refreshed = scope.findContext(context.window) or context
        local effortItem = strengthPopover(refreshed)
        if effortItem then
          configureStrength(refreshed, true)
          return
        end

        -- Some client versions close the picker after model selection. Only
        -- those versions need the old re-locate-and-open path.
        scope.waitForContext(function(refreshed, refreshErr)
          if not refreshed then
            finishPreset(false, refreshErr or "选择模型后无法重新定位" .. scope.subject)
            return
          end
          configureStrength(refreshed, false)
        end, context.window)
      end)
    end)
  end)
end

local function applyCodexComposerPreset(presetKey, scope)
  codexPresetScopeLabel = scope.label
  local preset = codexPresets[presetKey]
  if not preset then
    codexNotify("已拒绝未知预设：" .. tostring(presetKey))
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

hs.urlevent.bind("codex-main-preset", function(_, params)
  applyCodexMainPreset(params and params.preset or nil)
end)

hs.urlevent.bind("codex-side-preset", function(_, params)
  applyCodexSidePreset(params and params.preset or nil)
end)

hs.urlevent.bind("codex-side-open", function()
  codexPresetScopeLabel = sideScope.label
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
end)
