-- WowFC.lua
-- 魔兽世界 FC 模拟器插件主文件
-- 使用渲染器模块输出画面

local addonName, addon = ...

-- 全局命名空间
WowFC = addon

-- 从 toc 读取版本号,避免代码里硬编码 vN.M 不同步
local function getAddonVersion()
    local v
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        v = C_AddOns.GetAddOnMetadata(addonName, "Version")
    elseif GetAddOnMetadata then
        v = GetAddOnMetadata(addonName, "Version")
    end
    return v or "?"
end
local ADDON_VERSION = getAddonVersion()

-- 兼容旧命名和当前的 UltraRenderer 导出
local RendererFactory = _G.WowFC_TileRenderer or _G.WowFC_UltraRenderer

-- 常量
local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 240
local SCALE = 2

-- 主框架
local MainFrame = nil
local ScreenContainer = nil
local nes = nil
local isRunning = false
local renderer = nil

-- 帧计数器
local frameCount = 0
local lastFrameTime = 0
local frameTimer = nil

local WOW_MUTE_CVARS = {
    "Sound_EnableSFX",
    "Sound_EnableMusic",
    "Sound_EnableAmbience",
    "Sound_EnableDialog",
    "Sound_EnableErrorSpeech",
}

-- 按键映射模块(Keybinding.lua)
-- 提供:
--   M:Load() / M:Save()
--   M:LookupKey(wowKey) → (nesButton, isTurbo, turboSlot)
--   M:SetTurboHeld(slot, held)
--   M:ClockTurbo() → (aState, bState) for FC frame loop
--   M:Show() 弹出改键浮窗
--   M:IsRecording() 是否在录键中(录键时 FC 不接收输入)
local KB = WowFC_Keybinding

-- 本地化字符串表
local L = _G.WowFC_Locale or {}

-- 初始化
function addon:OnInitialize()
    print(string.format("|cff00ff00WowFC|r v%s |cff888888— %s|r",
        ADDON_VERSION, L["ADDON_TITLE"] or "FC Emulator in World of Warcraft"))
    print(L["TOGGLE_HINT"] or "Type |cffffff00/fc|r to open/close. Press |cffffff00ESC|r to exit control mode.")

    -- 加载持久化按键映射(SavedVariables WowFCDB.keybindings)
    KB:Load()

    -- 初始化声音总开关持久化(SavedVariables WowFCDB.soundEnabled),默认开启。
    -- ADDON_LOADED 时 SavedVariables 已可读;此处规范化默认值,供新建 FC 实例回填。
    WowFCDB = WowFCDB or {}
    if WowFCDB.soundEnabled == nil then WowFCDB.soundEnabled = true end

    -- 创建主窗口
    self:CreateMainFrame()

    -- 注册斜杠命令
    SLASH_WowFC1 = "/fc"
    SLASH_WowFC2 = "/wfc"
    SLASH_WowFC3 = "/WowFC"
    SlashCmdList["WowFC"] = function(msg)
        msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if msg == "prof" then
            if nes then nes:dumpProfile() else print("|cffff0000WowFC|r: " .. (L["MSG_NO_ROM"] or "No ROM loaded")) end
        elseif msg == "profreset" then
            if nes then nes:resetProfile() print("|cff00ff00WowFC|r: " .. (L["MSG_PROFILE_RESET"] or "Profile reset")) end
        elseif msg:match("^skip%s") or msg == "skip" then
            local rest = msg:match("^skip%s+(.+)$")
            if not nes then
                print("|cffff0000WowFC|r: " .. (L["MSG_NO_ROM"] or "No ROM loaded"))
            elseif rest == "auto" then
                nes:setFrameSkip("auto")
                print("|cff00ff00WowFC|r: " .. (L["MSG_SKIP_AUTO"] or "Frame skip = auto (dynamic)"))
            elseif rest and tonumber(rest) then
                local applied = nes:setFrameSkip(tonumber(rest))
                if applied == 1 then
                    print("|cff00ff00WowFC|r: " .. (L["MSG_SKIP_1"] or "Frame skip = 1 (render every frame, target 60fps)"))
                else
                    print(string.format("|cff00ff00WowFC|r: " ..
                        (L["MSG_SKIP_N"] or "Frame skip skipN=%d (UI approx %.0f fps, auto off)"),
                        applied, 60 / applied))
                end
            else
                local mode = nes._frameSkipAuto and "auto" or "manual"
                print(string.format("|cffff8800WowFC|r: " ..
                    (L["MSG_SKIP_CURRENT"] or "Current skipN=%d (%s). Usage: /fc skip <1-10|auto>"),
                    nes._frameSkip or 1, mode))
            end
        elseif msg == "debug" then
            self:ShowDebugInfo()
        elseif msg:match("^bench") then
            -- 渲染器 A/B 基准:对比 UltraRenderer(SetColorTexture)与
            -- PaletteRenderer(SetTexCoord)在真实帧上的 Present 耗时。
            -- 用法 /fc bench [帧数] [回放遍数],默认 60 帧 × 10 遍。
            if not _G.WowFC_Bench then
                print("|cffff0000WowFC|r: " .. (L["MSG_BENCH_NOT_LOADED"] or "Bench module not loaded"))
            elseif not isRunning or not nes then
                print("|cffff8800WowFC|r: " .. (L["MSG_BENCH_NEED_ROM"] or "Please load and run a ROM first (benchmark needs real frames)"))
            else
                local f, r = msg:match("^bench%s+(%d+)%s+(%d+)$")
                if not f then f = msg:match("^bench%s+(%d+)$") end
                _G.WowFC_Bench:Start(tonumber(f) or 60, tonumber(r) or 3)
            end
        elseif msg:match("^scanline") then
            local rest = msg:match("^scanline%s+(%S+)$")
            if not nes then
                print("|cffff0000WowFC|r: " .. (L["MSG_NO_ROM"] or "No ROM loaded"))
            elseif rest == "on" then
                local r = nes:setScanlineMode(true)
                if r then
                    print("|cff00ff00WowFC|r: " .. (L["MSG_SCANLINE_ON"] or "Scanline rendering enabled (~2x cost)"))
                else
                    print("|cffff8800WowFC|r: " .. (L["MSG_SCANLINE_SMB1"] or "Current path is SMB1-only; scanline toggle has no effect"))
                end
            elseif rest == "off" then
                nes:setScanlineMode(false)
                print("|cff00ff00WowFC|r: " .. (L["MSG_SCANLINE_OFF"] or "Scanline rendering disabled (best performance)"))
            else
                print(string.format("|cffff8800WowFC|r: " ..
                    (L["MSG_SCANLINE_CURRENT"] or "Scanline = %s. Usage: /fc scanline <on|off>"),
                    nes:getScanlineMode() and "on" or "off"))
            end
        elseif msg:match("^sound") then
            -- 声音总开关:/fc sound on|off,委托 APU:setEnabled
            local rest = msg:match("^sound%s+(%S+)$")
            if not nes then
                print("|cffff0000WowFC|r: " .. (L["MSG_NO_ROM"] or "No ROM loaded"))
            elseif rest == "on" then
                WowFCDB = WowFCDB or {}
                WowFCDB.soundEnabled = true
                nes.apu:setEnabled(true)
                if self._updateSoundButton then self._updateSoundButton() end
                print("|cff00ff00WowFC|r: " .. (L["MSG_SOUND_ON"] or "Sound enabled"))
            elseif rest == "off" then
                WowFCDB = WowFCDB or {}
                WowFCDB.soundEnabled = false
                nes.apu:setEnabled(false)
                if self._updateSoundButton then self._updateSoundButton() end
                print("|cff00ff00WowFC|r: " .. (L["MSG_SOUND_OFF"] or "Sound disabled"))
            else
                print(string.format("|cffff8800WowFC|r: " ..
                    (L["MSG_SOUND_CURRENT"] or "Sound = %s. Usage: /fc sound <on|off>"),
                    nes.apu:isEnabled() and "on" or "off"))
            end
        elseif msg == "boost" then
            WowFCDB = WowFCDB or {}
            WowFCDB.boostDisabled = not WowFCDB.boostDisabled
            if WowFCDB.boostDisabled then
                self:ApplyPerfCVars(false)
                print("|cff00ff00WowFC|r: " .. (L["MSG_BOOST_OFF"] or "Performance boost disabled"))
            else
                print("|cff00ff00WowFC|r: " .. (L["MSG_BOOST_ON"] or "Performance boost enabled"))
                if isRunning then self:ApplyPerfCVars(true) end
            end
        elseif msg == "help" then
            self:ShowHelp()
        else
            self:ToggleFrame()
        end
    end
end

-- 创建主窗口
function addon:CreateMainFrame()
    -- 主框架
    MainFrame = CreateFrame("Frame", "WowFCMainFrame", UIParent, "BasicFrameTemplateWithInset")
    MainFrame:SetSize(SCREEN_WIDTH * SCALE + 40, SCREEN_HEIGHT * SCALE + 120)
    MainFrame:SetPoint("CENTER")
    MainFrame:SetMovable(true)
    MainFrame:EnableMouse(true)
    MainFrame:RegisterForDrag("LeftButton")
    MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
    MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)
    MainFrame:SetFrameStrata("HIGH")
    MainFrame:Hide()
    MainFrame:SetScript("OnHide", function()
        if isRunning then
            addon:PauseGame()
        else
            addon:RestoreWoWSound()
        end
        if addon._applyControlMode and addon._controlMode then
            addon._applyControlMode(false)
        end
    end)

    -- 标题
    MainFrame.TitleBg:SetHeight(30)
    MainFrame.title = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    MainFrame.title:SetPoint("TOP", MainFrame.TitleBg, "TOP", 0, -8)
    MainFrame.title:SetText("WowFC v" .. ADDON_VERSION .. " - " .. (L["TITLE_SUFFIX"] or "FC Emulator"))

    -- 状态文本
    MainFrame.statusText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    MainFrame.statusText:SetPoint("TOP", MainFrame, "TOP", 0, -35)
    MainFrame.statusText:SetText(L["STATUS_NO_ROM"] or "No ROM loaded - click 'Load ROM' to start")

    -- FPS显示
    MainFrame.fpsText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    MainFrame.fpsText:SetPoint("TOPRIGHT", MainFrame, "TOPRIGHT", -10, -35)
    MainFrame.fpsText:SetText("FPS: --")

    -- 游戏画面容器
    ScreenContainer = CreateFrame("Frame", nil, MainFrame)
    ScreenContainer:SetSize(SCREEN_WIDTH * SCALE, SCREEN_HEIGHT * SCALE)
    ScreenContainer:SetPoint("TOP", MainFrame, "TOP", 0, -55)
    
    -- 黑色背景
    ScreenContainer.bg = ScreenContainer:CreateTexture(nil, "BACKGROUND")
    ScreenContainer.bg:SetAllPoints()
    ScreenContainer.bg:SetColorTexture(0, 0, 0)

    -- 创建渲染器。由渲染器直接按 SCALE 输出，避免容器再次缩放导致布局错位。
    if RendererFactory and RendererFactory.Create then
        renderer = RendererFactory:Create(ScreenContainer, {
            scale = SCALE,
            targetFps = 30,
        })
    else
        renderer = nil
        MainFrame.statusText:SetText(L["STATUS_RENDERER_FAIL"] or "Renderer failed to load")
        print("|cffff0000WowFC|r: " .. (L["MSG_RENDERER_NOT_FOUND"] or "Renderer module not found; please check that UltraRenderer.lua is loaded"))
    end

    -- 按钮区域
    local buttonY = -SCREEN_HEIGHT * SCALE - 65
    local gap = 6
    local loadW, normalW, controlW = 82, 70, 98

    -- 加载 ROM 按钮
    local loadBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    loadBtn:SetSize(loadW, 24)
    loadBtn:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 15, buttonY)
    loadBtn:SetText(L["BTN_LOAD_ROM"] or "Load ROM")
    loadBtn:SetScript("OnClick", function()
        self:ShowROMLoader()
    end)

    -- 开始/暂停按钮
    local pauseBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    pauseBtn:SetSize(normalW, 24)
    pauseBtn:SetPoint("LEFT", loadBtn, "RIGHT", gap, 0)
    pauseBtn:SetText(L["BTN_START"] or "Start")
    pauseBtn:SetScript("OnClick", function()
        self:TogglePause()
    end)
    MainFrame.pauseBtn = pauseBtn

    -- 重置按钮
    local resetBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(normalW, 24)
    resetBtn:SetPoint("LEFT", pauseBtn, "RIGHT", gap, 0)
    resetBtn:SetText(L["BTN_RESET"] or "Reset")
    resetBtn:SetScript("OnClick", function()
        self:ResetFC()
    end)

    -- 声音开关按钮
    local soundBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    soundBtn:SetSize(controlW, 24)
    soundBtn:SetPoint("LEFT", resetBtn, "RIGHT", gap, 0)
    MainFrame.soundBtn = soundBtn

    -- 操控开关:玩 FC 时按下,FC 独占键盘,WoW 角色不响应;
    -- 再按一次切回 WoW 控制(WoW 角色恢复响应,FC 不接收)。
    -- 也可以按 ESC 一键退出操控模式。
    local controlBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    controlBtn:SetSize(controlW, 24)
    controlBtn:SetPoint("LEFT", soundBtn, "RIGHT", gap, 0)
    controlBtn:SetText(L["BTN_CONTROL_OFF"] or "Control: Off")
    MainFrame.controlBtn = controlBtn
    addon._controlMode = false  -- 默认关:WoW 优先,FC 不响应键盘

    local function applyControlMode(on)
        addon._controlMode = on and true or false
        if addon._controlMode then
            -- 独占键盘:WoW 角色不响应方向键/Z/Enter 等
            MainFrame:SetPropagateKeyboardInput(false)
            controlBtn:SetText(L["BTN_CONTROL_ON"] or "Control: On")
            MainFrame.statusText:SetText(L["STATUS_CONTROL_ON"] or "Control mode (press ESC to exit)")
        else
            -- 释放键盘:WoW 恢复正常,FC 不接收按键(避免双开)
            MainFrame:SetPropagateKeyboardInput(true)
            controlBtn:SetText(L["BTN_CONTROL_OFF"] or "Control: Off")
            MainFrame.statusText:SetText(L["STATUS_CONTROL_OFF"] or "WoW control mode (click window or button to enable control)")
            -- 释放所有按钮 + 清连发,避免离开操控模式时按键卡住
            if nes then
                for btn = 0, 7 do
                    nes:setButtonState(1, btn, false)
                end
            end
            KB:SetTurboHeld("A", false)
            KB:SetTurboHeld("B", false)
        end
    end
    addon._applyControlMode = applyControlMode

    controlBtn:SetScript("OnClick", function()
        applyControlMode(not addon._controlMode)
    end)

    local function updateSoundButton()
        WowFCDB = WowFCDB or {}
        if WowFCDB.soundEnabled == nil then WowFCDB.soundEnabled = true end
        if WowFCDB.soundEnabled then
            soundBtn:SetText(L["BTN_SOUND_ON"] or "Sound: On")
        else
            soundBtn:SetText(L["BTN_SOUND_OFF"] or "Sound: Off")
        end
    end
    addon._updateSoundButton = updateSoundButton

    soundBtn:SetScript("OnClick", function()
        WowFCDB = WowFCDB or {}
        if WowFCDB.soundEnabled == nil then WowFCDB.soundEnabled = true end
        WowFCDB.soundEnabled = not WowFCDB.soundEnabled
        if nes and nes.apu then
            nes.apu:setEnabled(WowFCDB.soundEnabled)
        end
        updateSoundButton()
        print("|cff00ff00WowFC|r: " .. (WowFCDB.soundEnabled and (L["MSG_SOUND_ON"] or "Sound enabled") or (L["MSG_SOUND_OFF"] or "Sound disabled")))
    end)
    updateSoundButton()

    -- 按键设置按钮:打开自定义按键浮窗
    local keysBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    keysBtn:SetSize(normalW, 24)
    keysBtn:SetPoint("LEFT", controlBtn, "RIGHT", gap, 0)
    keysBtn:SetText(L["BTN_KEYS"] or "Keys")
    keysBtn:SetScript("OnClick", function()
        KB:Show()
    end)

    -- 键盘输入处理
    MainFrame:SetScript("OnKeyDown", function(self, key)
        addon:OnKeyDown(key)
    end)
    MainFrame:SetScript("OnKeyUp", function(self, key)
        addon:OnKeyUp(key)
    end)
    -- 默认 propagate=true:WoW 正常响应键盘,FC 不接收(避免双开)。
    -- 玩家点"操控:开"按钮才独占键盘,让 FC 接收输入,WoW 角色不响应。
    -- 详见 applyControlMode() 函数的注释。
    MainFrame:SetPropagateKeyboardInput(true)

    -- 更新FPS显示
    C_Timer.NewTicker(0.5, function()
        if renderer and isRunning then
            local renderFps = renderer.currentFps or 0
            local modeName = renderer.GetModeName and renderer:GetModeName() or (L["UNKNOWN"] or "Unknown")
            MainFrame.fpsText:SetText(string.format("FPS:%d %s", renderFps, modeName))
        end
    end)
end

-- 显示/隐藏窗口
function addon:ToggleFrame()
    if MainFrame:IsShown() then
        MainFrame:Hide()
    else
        MainFrame:Show()
    end
end

-- ROM 文件列表
function addon:MuteWoWSound()
    if not (GetCVar and SetCVar) then return end
    if not self._savedSoundCVars then
        self._savedSoundCVars = {}
        for _, name in ipairs(WOW_MUTE_CVARS) do
            self._savedSoundCVars[name] = GetCVar(name)
        end
    end
    for _, name in ipairs(WOW_MUTE_CVARS) do
        if self._savedSoundCVars[name] ~= nil then
            SetCVar(name, "0")
        end
    end
end

function addon:RestoreWoWSound()
    if not self._savedSoundCVars then return end
    if SetCVar then
        for name, value in pairs(self._savedSoundCVars) do
            if value ~= nil then
                SetCVar(name, value)
            end
        end
    end
    self._savedSoundCVars = nil
end

local ROM_LIST = {}

-- 扫描 ROMs
function addon:ScanROMs()
    ROM_LIST = {}
    
    -- 从预加载数据中查找
    if _G.WowFC_ROM_DATA then
        for filename, _ in pairs(_G.WowFC_ROM_DATA) do
            table.insert(ROM_LIST, filename)
        end
    end
    
    -- 从SavedVariables查找
    if WowFCDB and WowFCDB.roms then
        for filename, _ in pairs(WowFCDB.roms) do
            local found = false
            for _, existing in ipairs(ROM_LIST) do
                if existing == filename then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(ROM_LIST, filename)
            end
        end
    end
    
    -- 默认ROM
    if #ROM_LIST == 0 then
        table.insert(ROM_LIST, "MARIO.NES")
    end
    
    return ROM_LIST
end

-- ROM选择器
local ROMSelectorFrame = nil

function addon:ShowROMLoader()
    self:ScanROMs()

    if #ROM_LIST == 0 then
        print("|cffff8800WowFC|r: " .. (L["MSG_NO_ROMS_FOUND"] or "No ROMs found. Put .nes files into WowFC/ROMs, run the converter, then /reload."))
        return
    end

    -- 如果已存在则刷新内容并显示
    if ROMSelectorFrame then
        ROMSelectorFrame:Refresh()
        ROMSelectorFrame:Show()
        return
    end

    -- 紧凑布局参数:多列网格 + 固定高度滚动框。
    -- ROM 数量增长时,窗口高度不变,内容超出就滚动,方便后期添加更多游戏。
    local COLS = 3              -- 每行按钮数
    local BTN_W = 150           -- 按钮宽
    local BTN_H = 22            -- 按钮高
    local GAP_X = 6             -- 横向间距
    local GAP_Y = 4             -- 纵向间距
    local PAD_X = 12            -- 左右内边距
    local PAD_TOP = 56          -- 顶部留给标题/说明
    local PAD_BOT = 44          -- 底部留给关闭按钮
    local FRAME_W = PAD_X * 2 + COLS * BTN_W + (COLS - 1) * GAP_X + 24 -- +24 给滚动条留位
    local FRAME_H = 420         -- 固定高度,内容超出则滚动

    -- 创建选择器
    ROMSelectorFrame = CreateFrame("Frame", "WowFCROMSelector", UIParent, "BasicFrameTemplateWithInset")
    ROMSelectorFrame:SetSize(FRAME_W, FRAME_H)
    ROMSelectorFrame:SetPoint("CENTER")
    ROMSelectorFrame:SetMovable(true)
    ROMSelectorFrame:EnableMouse(true)
    ROMSelectorFrame:RegisterForDrag("LeftButton")
    ROMSelectorFrame:SetScript("OnDragStart", ROMSelectorFrame.StartMoving)
    ROMSelectorFrame:SetScript("OnDragStop", ROMSelectorFrame.StopMovingOrSizing)
    ROMSelectorFrame:SetFrameStrata("DIALOG")

    -- 标题
    ROMSelectorFrame.TitleBg:SetHeight(30)
    ROMSelectorFrame.title = ROMSelectorFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ROMSelectorFrame.title:SetPoint("TOP", ROMSelectorFrame.TitleBg, "TOP", 0, -8)
    ROMSelectorFrame.title:SetText(L["TITLE_SELECT_GAME"] or "Select Game")

    -- 说明
    local desc = ROMSelectorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    desc:SetPoint("TOP", ROMSelectorFrame, "TOP", 0, -40)
    desc:SetText(L["DESC_SELECT_GAME"] or "Click a game title to load:")

    -- 滚动框
    local scroll = CreateFrame("ScrollFrame", "$parentScroll", ROMSelectorFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", ROMSelectorFrame, "TOPLEFT", PAD_X, -PAD_TOP)
    scroll:SetPoint("BOTTOMRIGHT", ROMSelectorFrame, "BOTTOMRIGHT", -PAD_X - 22, PAD_BOT)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(COLS * BTN_W + (COLS - 1) * GAP_X, 1) -- 高度由 Refresh 设置
    scroll:SetScrollChild(content)

    -- 按钮池,Refresh 时复用
    local buttons = {}

    function ROMSelectorFrame:Refresh()
        -- 隐藏多余按钮
        for i = #ROM_LIST + 1, #buttons do
            buttons[i]:Hide()
        end

        for i, rom in ipairs(ROM_LIST) do
            local btn = buttons[i]
            if not btn then
                btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
                btn:SetSize(BTN_W, BTN_H)
                -- 缩小字号,长名字也能塞下
                local fs = btn:GetFontString()
                if fs then
                    fs:SetFont(fs:GetFont(), 10, "")
                    fs:SetWidth(BTN_W - 8)
                    fs:SetWordWrap(false)
                    fs:SetJustifyH("CENTER")
                end
                buttons[i] = btn
            end

            local col = (i - 1) % COLS
            local row = math.floor((i - 1) / COLS)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", col * (BTN_W + GAP_X), -row * (BTN_H + GAP_Y))
            btn:SetText(rom)
            btn:SetScript("OnClick", function()
                ROMSelectorFrame:Hide()
                addon:LoadROMFromFile(rom)
            end)
            -- tooltip 显示完整文件名,避免按钮内文字被截断时看不全
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(rom, 1, 1, 1)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            btn:Show()
        end

        local rows = math.ceil(#ROM_LIST / COLS)
        local h = rows * BTN_H + math.max(0, rows - 1) * GAP_Y
        content:SetHeight(math.max(h, 1))
    end

    ROMSelectorFrame:Refresh()

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, ROMSelectorFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 22)
    closeBtn:SetPoint("BOTTOM", ROMSelectorFrame, "BOTTOM", 0, 15)
    closeBtn:SetText(L["BTN_CLOSE"] or "Close")
    closeBtn:SetScript("OnClick", function()
        ROMSelectorFrame:Hide()
    end)

    ROMSelectorFrame:Show()
end

-- 从文件加载 ROM
function addon:LoadROMFromFile(filename)
    MainFrame.statusText:SetText((L["STATUS_LOADING"] or "Loading: ") .. filename)

    -- 创建 FC 实例
    if not nes then
        nes = FC:new({
            onFrame = function(buffer, dirty_tiles)
                addon:OnFrame(buffer, dirty_tiles)
            end,
            onNesFrame = function()
                addon:OnNesFrame()
            end,
            onStatusUpdate = function(status)
                MainFrame.statusText:SetText(status)
            end
        })

        -- 回填持久化的声音开关到新建实例的 APU,使重载后保留上次设置。
        WowFCDB = WowFCDB or {}
        if WowFCDB.soundEnabled == nil then WowFCDB.soundEnabled = true end
        nes.apu:setEnabled(WowFCDB.soundEnabled)
    end

    -- 读取 ROM 文件
    local romData = self:ReadROMFile(filename)

    if not romData then
        MainFrame.statusText:SetText((L["STATUS_ROM_READ_FAIL"] or "ROM read failed: ") .. filename)
        print("|cffff0000WowFC|r: " .. (L["MSG_CANNOT_READ"] or "Cannot read ") .. filename .. (L["MSG_CHECK_ROMS_DIR"] or ", please make sure the file exists in the ROMs directory"))
        return
    end

    -- 加载ROM
    local success, err = pcall(function()
        return nes:loadROM(romData)
    end)

    if success and err then
        MainFrame.statusText:SetText((L["STATUS_LOADED"] or "Loaded: ") .. filename)
        print("|cff00ff00WowFC|r: " .. (L["STATUS_LOADED"] or "Loaded: ") .. filename .. ", " .. (L["MSG_HAVE_FUN"] or "Have fun!"))

        isRunning = true
        MainFrame.pauseBtn:SetText(L["BTN_PAUSE"] or "Pause")
        self:StartGameLoop()

        -- 加载 ROM 成功后自动开启操控模式,避免玩家手动找开关。
        -- ESC 可一键退出,松键时自动释放按钮,避免按键卡死。
        if self._applyControlMode then
            self._applyControlMode(true)
        end
    else
        MainFrame.statusText:SetText(L["STATUS_LOAD_FAILED"] or "ROM load failed")
        print("|cffff0000WowFC|r: " .. (L["MSG_LOAD_FAILED"] or "ROM load failed: ") .. tostring(err))
    end
end

-- 读取 ROM 文件
function addon:ReadROMFile(filename)
    -- 优先使用预加载数据(addon 自带 ROM)
    if _G.WowFC_ROM_DATA and _G.WowFC_ROM_DATA[filename] then
        local data = _G.WowFC_ROM_DATA[filename]
        local copy = {}
        for k, v in pairs(data) do
            copy[k] = v
        end
        return copy
    end

    -- 否则从 SavedVariables 读(玩家自己导入的)
    if WowFCDB and WowFCDB.roms and WowFCDB.roms[filename] then
        return WowFCDB.roms[filename]
    end

    return nil
end

-- 渲染调试帧（用于检查PPU是否工作）
function addon:RenderDebugFrame()
    if not nes or not nes.ppu then return end
    
    -- 强制渲染一帧
    nes.ppu:renderFrame()
    
    -- 显示到屏幕（传nil dirty_tiles强制全屏重绘）
    if renderer then
        renderer.Render(renderer, nes.ppu.buffer, nil)
    end
end

-- 开始/暂停
function addon:PauseGame()
    if not isRunning then
        self:RestoreWoWSound()
        return false
    end
    self:StopGameLoop()
    if MainFrame and MainFrame.pauseBtn then MainFrame.pauseBtn:SetText(L["BTN_RESUME"] or "Resume") end
    isRunning = false
    self:RestoreWoWSound()
    return true
end

function addon:ResumeGame()
    if not nes then return false end
    self:StartGameLoop()
    if MainFrame and MainFrame.pauseBtn then MainFrame.pauseBtn:SetText(L["BTN_PAUSE"] or "Pause") end
    if self._applyControlMode then
        self._applyControlMode(true)
    end
    isRunning = true
    return true
end

function addon:TogglePause()
    if not nes then
        print("|cffff0000WowFC|r: " .. (L["MSG_PLEASE_LOAD_ROM"] or "Please load a ROM first"))
        return
    end

    if isRunning then
        self:PauseGame()
    else
        self:ResumeGame()
    end
end

-- 基准期间暂停/恢复游戏循环。
-- bench 要密集回放,若游戏循环(每帧 CPU+PPU+渲染)还在后台跑,两者累计 CPU 会
-- 触发 WoW 对单个 addon 的执行配额上限。暂停后让 bench 独占,测量也更干净。
function addon:PauseForBench()
    return self:PauseGame()
end

function addon:ResumeAfterBench()
    self:ResumeGame()
end

-- 启动游戏循环
-- 用 OnUpdate driver(每个 WoW 渲染帧触发)替代 C_Timer.NewTicker(1/60)。
-- C_Timer 最多 60Hz,且 frame() 超时会丢 tick;OnUpdate 跟随 WoW 帧率,
-- 配合固定时间步进(fixed timestep)既不会让 NES 跑太快,也能在 WoW 高帧率时追帧。
function addon:StartGameLoop()
    self:StopGameLoop()

    nes:start()
    self:MuteWoWSound()

    -- 声音/渲染分离:模拟+apu:tick 按固定时间步每 NES 帧推进(声音准时),
    -- 渲染交给下面 OnUpdate 末尾的 presentDeferred,每 WoW 帧最多一次。
    nes.deferPresent = true
    -- maxfps/maxfpsbk 是非保护 CVar,插件可改。关闭模拟器时恢复。
    self:ApplyPerfCVars(true)

    if not self._driver then
        self._driver = CreateFrame("Frame", nil, UIParent)
    end

    local NES_FRAME_TIME = 1 / 60   -- 一个 NES 帧的目标时长(秒)
    local MAX_CATCHUP = 4           -- 单个 WoW 帧内最多追几个 NES 帧(防卡死螺旋)
    self._accum = 0

    self._driver:SetScript("OnUpdate", function(_, elapsed)
        if not (isRunning and nes) then return end

        self._accum = self._accum + elapsed
        local budget = MAX_CATCHUP
        -- 固定时间步进:积累够一个 NES 帧时长就推进一帧,落后时追帧(有上限)
        while self._accum >= NES_FRAME_TIME and budget > 0 do
            self._accum = self._accum - NES_FRAME_TIME
            budget = budget - 1
            local ok, err = pcall(function()
                nes:frame()
            end)
            if not ok then
                print("|cffff0000WowFC|r: " .. (L["MSG_RUNTIME_ERROR"] or "Runtime error: ") .. tostring(err))
                isRunning = false
                nes:stop()
                self:RestoreWoWSound()
                MainFrame.pauseBtn:SetText(L["BTN_START"] or "Start")
                return
            end
        end
        -- 如果一帧都追不上(frame() 比 NES_FRAME_TIME 还慢),丢弃多余累积,
        -- 避免 _accum 无限膨胀导致越来越卡
        if self._accum > NES_FRAME_TIME * MAX_CATCHUP then
            self._accum = 0
        end

        -- 渲染与模拟解耦:每个 WoW 帧最多渲染一次最新帧(声音/渲染分离的关键)。
        -- 模拟上面已按固定步追完(apu:tick 已按 NES 时间线触发),这里只把最新画面画出来;
        -- 渲染重也只发生一次,不会回头拖慢声音节奏。
        if isRunning and nes then
            local ok = pcall(function() nes:presentDeferred() end)
            if not ok then end  -- 渲染异常不应中断模拟/声音
        end
    end)
end

-- 停止游戏循环
function addon:StopGameLoop()    if self._driver then
        self._driver:SetScript("OnUpdate", nil)
    end
    if frameTimer then
        frameTimer:Cancel()
        frameTimer = nil
    end
    if nes then
        nes:stop()
    end
    -- 恢复 WoW 帧率设置
    self:ApplyPerfCVars(false)
end

-- 打开模拟器时解除帧率上限,关闭时恢复。
-- 仅改非保护 CVar(maxfps / maxfpsbk),不碰画质等受保护设置。
-- 玩家可用 /fc boost 关闭此行为(有些机器不限帧会过热)。
function addon:ApplyPerfCVars(enable)
    -- 玩家关掉了 boost → 不动 CVar
    if WowFCDB and WowFCDB.boostDisabled then
        -- 若之前已经改过,确保恢复
        if self._savedCVars and SetCVar then
            if self._savedCVars.maxfps then SetCVar("maxfps", self._savedCVars.maxfps) end
            if self._savedCVars.maxfpsbk then SetCVar("maxfpsbk", self._savedCVars.maxfpsbk) end
            self._savedCVars = nil
        end
        return
    end

    if enable then
        if not self._savedCVars then
            self._savedCVars = {
                maxfps   = GetCVar and GetCVar("maxfps") or nil,
                maxfpsbk = GetCVar and GetCVar("maxfpsbk") or nil,
            }
            -- 解除前台 + 后台限帧,让 WoW 主线程跑得更密集
            if SetCVar then
                SetCVar("maxfps", "0")
                SetCVar("maxfpsbk", "0")
            end
        end
    else
        if self._savedCVars and SetCVar then
            if self._savedCVars.maxfps then
                SetCVar("maxfps", self._savedCVars.maxfps)
            end
            if self._savedCVars.maxfpsbk then
                SetCVar("maxfpsbk", self._savedCVars.maxfpsbk)
            end
        end
        self._savedCVars = nil
    end
end

-- 重置
function addon:ResetFC()
    if nes then
        self:StopGameLoop()
        self:RestoreWoWSound()
        nes:reset()
        MainFrame.pauseBtn:SetText(L["BTN_START"] or "Start")
        isRunning = false
        MainFrame.statusText:SetText(L["STATUS_RESET"] or "Reset")
        
        -- 清空屏幕
        if renderer then
            local emptyBuffer = {}
            for i = 0, SCREEN_WIDTH * SCREEN_HEIGHT - 1 do
                emptyBuffer[i] = 0
            end
            renderer.Render(renderer, emptyBuffer, nil)
        end
    end
end

-- 键盘按下
function addon:OnKeyDown(key)
    -- 改键浮窗在录键模式时,FC 完全不响应键盘,避免改键时角色乱动
    if KB:IsRecording() then return end

    -- ESC:无论何时按下都退出操控模式(给玩家快速退出 + 避免键盘卡死)
    if key == "ESCAPE" and self._controlMode then
        self._applyControlMode(false)
        return
    end
    -- 仅在操控模式下处理 NES 按键
    if not self._controlMode then return end
    if not nes then return end

    -- 反查键位:可能是普通绑定、连发绑定、或未绑定
    local nesBtn, isTurbo, turboSlot = KB:LookupKey(key)
    if not nesBtn then return end
    if isTurbo then
        KB:SetTurboHeld(turboSlot, true)
    else
        nes:setButtonState(1, nesBtn, true)
    end
end

-- 键盘释放
function addon:OnKeyUp(key)
    if not nes then return end
    -- 不论操控模式状态,都释放(避免离开模式时按键残留为按下)
    local nesBtn, isTurbo, turboSlot = KB:LookupKey(key)
    if not nesBtn then return end
    if isTurbo then
        KB:SetTurboHeld(turboSlot, false)
        -- 同时确保 A/B 状态清零(连发结束后不应留下按下状态)
        nes:setButtonState(1, nesBtn, false)
    else
        nes:setButtonState(1, nesBtn, false)
    end
end

-- 每个 NES 帧(60Hz)调用:处理必须按 NES 时间线推进的逻辑(连发/turbo)。
-- 与渲染分离 —— 即使渲染降频/卡顿,连发频率仍稳定(声音/渲染分离后不能再借渲染回调计时)。
function addon:OnNesFrame()
    -- 连发(turbo)处理:30Hz 切换 A/B(60fps / 2,每个 NES 帧 toggle 一次)。
    -- 仅在操控模式下生效(避免在 WoW 模式下乱按)。
    if self._controlMode and nes then
        local aState, bState = KB:ClockTurbo()
        if aState ~= nil then
            nes:setButtonState(1, Controller.BUTTON_A, aState)
        end
        if bState ~= nil then
            nes:setButtonState(1, Controller.BUTTON_B, bState)
        end
    end
end

-- 渲染回调(接收调色板索引 buffer + ppu 元数据)。
-- 由 present 驱动调用:deferPresent 模式下每 WoW 帧一次,否则每 NES 帧一次。只负责绘制。
function addon:OnFrame(buffer, dirty_tiles)
    if not buffer or not renderer then return end

    renderer.Render(renderer, buffer, dirty_tiles)

    -- 基准录制(仅在 /fc bench 录制期间有开销,平时一次表判断即返回)
    if _G.WowFC_Bench and _G.WowFC_Bench:IsRecording() then
        _G.WowFC_Bench:Capture(buffer, dirty_tiles)
    end

    frameCount = frameCount + 1
end

-- 显示调试信息
function addon:ShowDebugInfo()
    if not nes then
        print("|cffff0000WowFC|r: " .. (L["MSG_NO_ROM"] or "No ROM loaded"))
        return
    end
    
    print("|cff00ff00" .. (L["TITLE_DEBUG_INFO"] or "=== WowFC Debug Info ===") .. "|r")
    
    local dirtyCount = 0
    if nes.ppu and nes.ppu.dirty_tiles then
        for _ in pairs(nes.ppu.dirty_tiles) do dirtyCount = dirtyCount + 1 end
    end
    print(string.format(L["DEBUG_FRAME_COUNT"] or "Frames: %d  DirtyTiles: %d", frameCount, dirtyCount))
    
    -- PPU状态
    if nes.ppu then
        print(string.format(L["DEBUG_PPU_SCANLINE"] or "PPU Scanline: %d", nes.ppu.scanline))
        print(string.format(L["DEBUG_BG_DISPLAY"] or "BG Display: %s", nes.ppu.f_bgVisibility == 1 and (L["ON"] or "On") or (L["OFF"] or "Off")))
        print(string.format(L["DEBUG_SP_DISPLAY"] or "Sprite Display: %s", nes.ppu.f_spVisibility == 1 and (L["ON"] or "On") or (L["OFF"] or "Off")))
        print(string.format(L["DEBUG_NMI"] or "NMI: %s", nes.ppu.f_nmiOnVblank == 1 and (L["ENABLED"] or "Enabled") or (L["DISABLED"] or "Disabled")))
    end
    
    -- CPU状态
    if nes.cpu then
        print(string.format("CPU PC: $%04X", nes.cpu.REG_PC))
        print(string.format("CPU A: $%02X X: $%02X Y: $%02X", 
            nes.cpu.REG_ACC, nes.cpu.REG_X, nes.cpu.REG_Y))
    end
    
    print("|cff00ff00========================|r")
end

-- 显示帮助
function addon:ShowHelp()
    print(string.format("|cff00ff00" .. (L["TITLE_HELP"] or "=== WowFC v%s Help ===") .. "|r", ADDON_VERSION))
    print(L["HELP_TOGGLE"] or "|cffffd700[Open/Close]|r |cffffff00/fc|r toggles the main window")
    print(L["HELP_CONTROL"] or "|cffffd700[Control Mode]|r Click the Control button. When on, FC takes keyboard input and WoW character does not respond.")
    print(L["HELP_CONTROL_ESC"] or "                |cffffff00ESC|r exits control mode instantly. Auto-enabled when loading a ROM.")
    print(L["HELP_KEYBINDING"] or "|cffffd700[Custom Keys]|r Click Keys. Supports keyboard / gamepad / turbo (30Hz auto A/B).")
    print(L["HELP_KEYBINDING_PAD"] or "                Enable gamepad first in |cffffff00WoW Settings → Controls → Enable Gamepad|r.")
    print(L["HELP_DEFAULT_KEYS"] or "|cffffd700[Default Keys]|r")
    print(L["HELP_DEFAULT_KEYS_DETAIL"] or "  Arrows = move   Z = A   X = B   Enter/Space = Start   Tab = Select")
    print(L["HELP_COMMANDS"] or "|cffffd700[Commands]|r")
    print(L["HELP_CMD_SKIP"] or "  |cffffff00/fc skip <N>|r  Frame skip (1=off, 2-10=render 1/N frames; or |cffffff00auto|r)")
    print(L["HELP_CMD_PROF"] or "  |cffffff00/fc prof|r       Performance data  |cffffff00/fc profreset|r reset")
    print(L["HELP_CMD_BENCH"] or "  |cffffff00/fc bench [N]|r  Renderer A/B benchmark")
    print(L["HELP_CMD_BOOST"] or "  |cffffff00/fc boost|r      Toggle performance boost")
    print(L["HELP_CMD_SOUND"] or "  |cffffff00/fc sound <on|off>|r Toggle sound")
    print(L["HELP_CMD_DEBUG"] or "  |cffffff00/fc debug|r      Runtime status")
end

-- 事件注册
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        addon:OnInitialize()
    elseif event == "PLAYER_LOGOUT" then
        -- 保险:登出 / 重载前恢复帧率 CVar,
        -- 避免 maxfps=0 被持久化到 WoW 设置,影响下次进游戏
        addon:ApplyPerfCVars(false)
        addon:RestoreWoWSound()
    end
end)

-- 导出
_G["WowFC"] = addon
