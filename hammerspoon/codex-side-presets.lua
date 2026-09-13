-- Codex side-chat preset switcher for Hammerspoon.
-- Load from ~/.hammerspoon/init.lua with:
-- dofile(os.getenv("HOME") .. "/.hammerspoon/codex-side-presets.lua")

-- Codex side-chat model presets. These intentionally do not edit config.toml.
local home = assert(os.getenv("HOME"), "HOME is not set")
local codexBundleID = "com.openai.codex"
local codexConfigPath = home .. "/.codex/config.toml"
local codexSideStatePath = home .. "/.codex/codex-side-preset-state.json"
local codexSideBusy = false
local codexSideActiveContext = nil

local codexSidePresets = {
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
  hs.printf("Codex side preset: %s", message)
  hs.notify.new({title = "Codex 当前侧栏", informativeText = message}):send()
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

local function elementFrame(element)
  local position = axAttribute(element, "AXPosition")
  local size = axAttribute(element, "AXSize")
  if not position or not size then return nil end
  return {x = position.x, y = position.y, w = size.w, h = size.h}
end

local function sameFrame(a, b)
  return math.abs(a.x - b.x) <= 3 and math.abs(a.y - b.y) <= 3
    and math.abs(a.w - b.w) <= 3 and math.abs(a.h - b.h) <= 3
end

local function modelControlsInWindow(axWindow)
  local controls = {}
  local seen = {}
  walkAX(axWindow, function(element)
    if axAttribute(element, "AXRole") ~= "AXPopUpButton" then return nil end
    local text = axText(element):lower()
    if not text:find("gpt%-5%.6") then return nil end
    local frame = elementFrame(element)
    if not frame or frame.w < 60 or frame.h < 20 then return nil end
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

local function findSideContext(targetWindow)
  local base, err = codexApplicationContext()
  if not base then return nil, err end
  if not targetWindow then return nil, "未锁定触发时的 Codex 窗口" end
  local targetFrame = targetWindow:frame()
  local axWindows = axAttribute(base.root, "AXWindows") or {}

  for _, axWindow in ipairs(axWindows) do
    local frame = elementFrame(axWindow)
    local sameTarget = frame and sameFrame(frame, targetFrame)
    local controls = sameTarget and modelControlsInWindow(axWindow) or {}
    -- Require both composer model controls. Text markers are unsafe because a
    -- normal transcript can itself contain the words "side chat" or "侧栏".
    if frame and #controls >= 2 then
      local sideModel = controls[#controls]
      local modelPoint = {
        x = sideModel.frame.x + sideModel.frame.w / 2,
        y = sideModel.frame.y + sideModel.frame.h / 2,
      }
      -- Two model controls in one conversation window are the strongest
      -- structural signal: the rightmost one belongs to the side composer.
      -- Do not additionally compare screen coordinates here. Electron can
      -- report AXWindow and child coordinates in different display spaces
      -- during a monitor transition even though their relative order is valid.
      return {
        app = base.app,
        root = base.root,
        axWindow = axWindow,
        window = targetWindow,
        frame = frame,
        modelElement = sideModel.element,
        modelPoint = modelPoint,
      }
    end
  end

  return nil, "当前 Codex 窗口未检测到侧栏输入区"
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
  -- Lock the exact Codex window that was last focused when SwiftBar invoked
  -- the URL. Never substitute mainWindow(), the largest window, or another
  -- window: users may have multiple Codex conversations open.
  local targetWindow = app:focusedWindow()
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
    hs.eventtap.keyStroke({"cmd", "alt"}, "s", 0, app)
    waitForSideChat(callback, true, 1, targetWindow)
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

local function pressAXElement(element)
  if not element then return false end
  local ok, result = pcall(function() return element:performAction("AXPress") end)
  return ok and result ~= false
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

local function strengthPopover(context)
  local effortItem = findAXMenuItem(context, function(text)
    local lower = text:lower()
    return text == "强度" or lower == "reasoning effort" or lower == "effort"
  end)
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
  return effortItem, nil
end

local function openStrengthPopover(context, callback)
  local function openNow()
    if not pressAXElement(context.modelElement) then
      callback(nil)
      return
    end
    pollForMenuItem(context, function(text)
      local lower = text:lower()
      return text:find("选择模型", 1, true) or lower:find("choose model", 1, true)
    end, callback)
  end

  -- Recover cleanly when a previous run left the strength popover open.
  if strengthPopover(context) then
    if not pressAXElement(context.modelElement) then
      callback(nil)
      return
    end
    hs.timer.doAfter(0.2, openNow)
  else
    openNow()
  end
end

local function verifyPreset(context, preset)
  -- Verify only the side composer's collapsed model button. Reading the open
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

local function readEffortIndex(root)
  local found = walkAX(root, function(element)
    local text = axText(element)
    local index = text:match("第%s*(%d+)%s*项")
      or text:lower():match("(%d+)%s*of%s*%d+")
    if index then return tonumber(index) end
    return nil
  end)
  return type(found) == "number" and found or nil
end

local function pollForEffortIndex(context, expected, callback, attempt)
  attempt = attempt or 1
  local _, popoverRoot = strengthPopover(context)
  if popoverRoot and readEffortIndex(popoverRoot) == expected then
    callback(true, popoverRoot)
    return
  end
  if attempt >= 8 then
    callback(false, popoverRoot)
    return
  end
  hs.timer.doAfter(0.1, function()
    pollForEffortIndex(context, expected, callback, attempt + 1)
  end)
end

local function writeSideState(presetKey, windowTitle)
  local tempPath = codexSideStatePath .. ".tmp"
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
  return os.rename(tempPath, codexSideStatePath) ~= nil
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
  if type(state.preset) ~= "string" or not codexSidePresets[state.preset] then return nil end
  return state.preset
end

local function dismissSidePopover(context)
  local app = context and context.app or nil
  hs.eventtap.keyStroke({}, "escape", 50000, app)
end

local function commitSidePopover(context)
  -- Pressing the already-open model control toggles the popover closed without
  -- moving the pointer. Unlike Escape, this commits the selected effort.
  return context and pressAXElement(context.modelElement) or false
end

local function finishPreset(success, message)
  codexSideBusy = false
  local context = codexSideActiveContext
  codexSideActiveContext = nil
  if not success then dismissSidePopover(context) end
  codexNotify(message)
  return success
end

local function applyPresetAttempt(presetKey, preset, configBefore, context, attempt)
  openStrengthPopover(context, function(chooseModelItem)
    if not chooseModelItem then
      if attempt == 1 then
        hs.eventtap.keyStroke({}, "escape", 50000, context.app)
        hs.timer.doAfter(0.25, function()
          local refreshed = findSideContext(context.window)
          if refreshed then
            applyPresetAttempt(presetKey, preset, configBefore, refreshed, 2)
          else
            finishPreset(false, "无法重新定位当前侧栏")
          end
        end)
      else
        finishPreset(false, "未找到侧栏的模型菜单")
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
        codexSideActiveContext = refreshed

        local function configureOpenPopover()
          local effortItem = findAXMenuItem(refreshed, function(text)
            local lower = text:lower()
            return text == "强度" or lower == "reasoning effort" or lower == "effort"
          end)
          if not effortItem then
            finishPreset(false, "未找到侧栏的推理强度控件")
            return
          end

          hs.timer.doAfter(0.18, function()
            local _, effortFocusTarget = strengthPopover(refreshed)
            if not effortFocusTarget then
              finishPreset(false, "未找到侧栏推理强度的可聚焦容器")
              return
            end

            local function adjustAndVerify(retry)
              local focusedWindow = refreshed.app:focusedWindow()
              if not refreshed.app:isFrontmost()
                  or not focusedWindow
                  or focusedWindow:id() ~= refreshed.window:id() then
                finishPreset(false, "当前 Codex 窗口失去焦点，已停止强度切换")
                return
              end

              -- The Electron slider exposes no writable AXValue. It does,
              -- however, accept the documented Left/Right keys after its AX
              -- group is focused. Post normal foreground key events here;
              -- application-targeted events do not reach this web control.
              local _, currentRoot = strengthPopover(refreshed)
              local currentIndex = currentRoot and readEffortIndex(currentRoot) or nil
              if currentIndex then
                local key = currentIndex < preset.effortIndex and "right" or "left"
                for _ = 1, math.abs(preset.effortIndex - currentIndex) do
                  hs.eventtap.keyStroke({}, key, 60000)
                end
              else
                -- Conservative fallback for a future client that temporarily
                -- omits the announced current index.
                for _ = 1, 6 do
                  hs.eventtap.keyStroke({}, "left", 60000)
                end
                for _ = 2, preset.effortIndex do
                  hs.eventtap.keyStroke({}, "right", 60000)
                end
              end

              pollForEffortIndex(refreshed, preset.effortIndex, function(matched, activeRoot)
                if not matched then
                  local activeItem = strengthPopover(refreshed)
                  if retry == 0 and activeItem then
                    focusAXElement(activeRoot, refreshed.root, function(retryFocused)
                      if retryFocused then
                        hs.timer.doAfter(0.15, function()
                          adjustAndVerify(1)
                        end)
                      else
                        finishPreset(false, "重试时无法聚焦侧栏的推理强度控件")
                      end
                    end)
                    return
                  end
                  finishPreset(false, "方向键调整后强度回读不一致")
                  return
                end
              if not commitSidePopover(refreshed) then
                finishPreset(false, "无法提交侧栏的推理强度选择")
                return
              end
              hs.timer.doAfter(0.45, function()
              if strengthPopover(refreshed) then
                finishPreset(false, "推理强度弹窗未能自动关闭")
                return
              end
              local verifiedContext = findSideContext(refreshed.window)
              if not verifiedContext or not verifyPreset(verifiedContext, preset) then
                finishPreset(false, "设置后回读不一致；未记录最近应用状态")
                return
              end
              if readFile(codexConfigPath) ~= configBefore then
                finishPreset(false, "检测到 config.toml 发生变化；已拒绝记录状态")
                return
              end
              local windowTitle = verifiedContext.window and verifiedContext.window:title() or ""
              if not writeSideState(presetKey, windowTitle) then
                finishPreset(false, "侧栏已切换，但状态文件写入失败")
                return
              end
              refreshSwiftBarCodexPlugin()
              codexSideActiveContext = verifiedContext
              finishPreset(true, "已应用 " .. preset.label .. "；全局配置未变化")
              end)
              end)
            end

            focusAXElement(effortFocusTarget, refreshed.root, function(focused)
              if not focused then
                finishPreset(false, "无法聚焦侧栏的推理强度控件")
                return
              end
              adjustAndVerify(0)
            end)
          end)
        end

        if popoverAlreadyOpen then
          configureOpenPopover()
        else
          openStrengthPopover(refreshed, function(opened)
            if not opened then
              finishPreset(false, "未找到侧栏的模型与强度菜单")
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
        local effortItem = strengthPopover(context)
        if effortItem then
          configureStrength(context, true)
          return
        end

        -- Some client versions close the picker after model selection. Only
        -- those versions need the old re-locate-and-open path.
        waitForSideChat(function(refreshed, refreshErr)
          if not refreshed then
            finishPreset(false, refreshErr or "选择模型后无法重新定位侧栏")
            return
          end
          configureStrength(refreshed, false)
        end, false, 1, context.window)
      end)
    end)
  end)
end

local function applyCodexSidePreset(presetKey)
  local preset = codexSidePresets[presetKey]
  if not preset then
    codexNotify("已拒绝未知预设：" .. tostring(presetKey))
    return
  end
  if codexSideBusy then
    codexNotify("已有侧栏切换正在进行")
    return
  end
  local configBefore = readFile(codexConfigPath)
  if not configBefore then
    codexNotify("无法读取 config.toml，已停止操作")
    return
  end
  codexSideBusy = true
  ensureSideChat(function(context, status)
    if not context then
      finishPreset(false, status)
      return
    end
    local function beginPreset()
      local refreshed, refreshErr = findSideContext(context.window)
      if not refreshed then
        finishPreset(false, refreshErr or "侧栏出现后无法重新定位")
        return
      end
      codexSideActiveContext = refreshed
      applyPresetAttempt(presetKey, preset, configBefore, refreshed, 1)
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

hs.urlevent.bind("codex-side-preset", function(_, params)
  applyCodexSidePreset(params and params.preset or nil)
end)

hs.urlevent.bind("codex-side-open", function()
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

