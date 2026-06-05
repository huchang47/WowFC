-- WOWFC.lua
-- 魔兽世界 FC 模拟器插件主文件
-- 使用渲染器模块输出画面

local addonName, addon = ...

-- 全局命名空间
WOWFC = addon

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
local RendererFactory = _G.WOWFC_TileRenderer or _G.WOWFC_UltraRenderer

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

-- 按键映射模块(Keybinding.lua)
-- 提供:
--   M:Load() / M:Save()
--   M:LookupKey(wowKey) → (nesButton, isTurbo, turboSlot)
--   M:SetTurboHeld(slot, held)
--   M:ClockTurbo() → (aState, bState) for FC frame loop
--   M:Show() 弹出改键浮窗
--   M:IsRecording() 是否在录键中(录键时 FC 不接收输入)
local KB = WOWFC_Keybinding

-- 初始化
function addon:OnInitialize()
    print(string.format("|cff00ff00WOWFC|r v%s |cff888888— 魔兽世界里的 FC 模拟器|r",
        ADDON_VERSION))
    print("|cff888888输入 |r|cffffff00/fc|r|cff888888 打开/关闭。键盘按 |r|cffffff00ESC|r|cff888888 退出操控模式。|r")

    -- 加载持久化按键映射(SavedVariables WOWFCDB.keybindings)
    KB:Load()

    -- 初始化声音总开关持久化(SavedVariables WOWFCDB.soundEnabled),默认开启。
    -- ADDON_LOADED 时 SavedVariables 已可读;此处规范化默认值,供新建 FC 实例回填。
    WOWFCDB = WOWFCDB or {}
    if WOWFCDB.soundEnabled == nil then WOWFCDB.soundEnabled = true end

    -- 创建主窗口
    self:CreateMainFrame()

    -- 注册斜杠命令
    SLASH_WOWFC1 = "/fc"
    SLASH_WOWFC2 = "/wfc"
    SLASH_WOWFC3 = "/wowfc"
    SlashCmdList["WOWFC"] = function(msg)
        msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if msg == "prof" then
            if nes then nes:dumpProfile() else print("|cffff0000WOWFC|r: 未加载ROM") end
        elseif msg == "profreset" then
            if nes then nes:resetProfile() print("|cff00ff00WOWFC|r: profile 已清零") end
        elseif msg:match("^skip%s") or msg == "skip" then
            local rest = msg:match("^skip%s+(.+)$")
            if not nes then
                print("|cffff0000WOWFC|r: 未加载ROM")
            elseif rest == "auto" then
                nes:setFrameSkip("auto")
                print("|cff00ff00WOWFC|r: 帧跳过 = auto (动态调节)")
            elseif rest and tonumber(rest) then
                local applied = nes:setFrameSkip(tonumber(rest))
                if applied == 1 then
                    print("|cff00ff00WOWFC|r: 帧跳过 = 1 (每帧渲染,目标 60fps)")
                else
                    print(string.format(
                        "|cff00ff00WOWFC|r: 帧跳过 skipN=%d (UI 约 %.0f fps,关闭 auto)",
                        applied, 60 / applied))
                end
            else
                local mode = nes._frameSkipAuto and "auto" or "manual"
                print(string.format("|cffff8800WOWFC|r: 当前 skipN=%d (%s)。用法 /fc skip <1-10|auto>",
                    nes._frameSkip or 1, mode))
            end
        elseif msg == "debug" then
            self:ShowDebugInfo()
        elseif msg:match("^scanline") then
            local rest = msg:match("^scanline%s+(%S+)$")
            if not nes then
                print("|cffff0000WOWFC|r: 未加载ROM")
            elseif rest == "on" then
                local r = nes:setScanlineMode(true)
                if r then
                    print("|cff00ff00WOWFC|r: 逐扫描线渲染已|cff00ff00开启|r(支持 mid-frame 分屏/sprite0-hit,约 2x 开销)")
                else
                    print("|cffff8800WOWFC|r: 当前为 SMB1 专用路径,逐扫描线开关无效")
                end
            elseif rest == "off" then
                nes:setScanlineMode(false)
                print("|cff00ff00WOWFC|r: 逐扫描线渲染已|cffff0000关闭|r(vblank 整帧快照,性能最优)")
            else
                print(string.format("|cffff8800WOWFC|r: 逐扫描线 = %s。用法 /fc scanline <on|off>",
                    nes:getScanlineMode() and "on" or "off"))
            end
        elseif msg:match("^sound") then
            -- 声音总开关:/fc sound on|off,委托 APU:setEnabled
            local rest = msg:match("^sound%s+(%S+)$")
            if not nes then
                print("|cffff0000WOWFC|r: 未加载ROM")
            elseif rest == "on" then
                WOWFCDB = WOWFCDB or {}
                WOWFCDB.soundEnabled = true
                nes.apu:setEnabled(true)
                print("|cff00ff00WOWFC|r: 声音已|cff00ff00开启|r")
            elseif rest == "off" then
                WOWFCDB = WOWFCDB or {}
                WOWFCDB.soundEnabled = false
                nes.apu:setEnabled(false)
                print("|cff00ff00WOWFC|r: 声音已|cffff0000关闭|r")
            else
                print(string.format("|cffff8800WOWFC|r: 声音 = %s。用法 /fc sound <on|off>",
                    nes.apu:isEnabled() and "on" or "off"))
            end
        elseif msg == "boost" then
            WOWFCDB = WOWFCDB or {}
            WOWFCDB.boostDisabled = not WOWFCDB.boostDisabled
            if WOWFCDB.boostDisabled then
                self:ApplyPerfCVars(false)
                print("|cff00ff00WOWFC|r: 性能增强已|cffff0000关闭|r(不再解除 WoW 帧率上限)")
            else
                print("|cff00ff00WOWFC|r: 性能增强已|cff00ff00开启|r(模拟器运行时解除 WoW 帧率上限)")
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
    MainFrame = CreateFrame("Frame", "WOWFCMainFrame", UIParent, "BasicFrameTemplateWithInset")
    MainFrame:SetSize(SCREEN_WIDTH * SCALE + 40, SCREEN_HEIGHT * SCALE + 120)
    MainFrame:SetPoint("CENTER")
    MainFrame:SetMovable(true)
    MainFrame:EnableMouse(true)
    MainFrame:RegisterForDrag("LeftButton")
    MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
    MainFrame:SetScript("OnDragStop", MainFrame.StopMovingOrSizing)
    MainFrame:SetFrameStrata("HIGH")
    MainFrame:Hide()

    -- 标题
    MainFrame.TitleBg:SetHeight(30)
    MainFrame.title = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    MainFrame.title:SetPoint("TOP", MainFrame.TitleBg, "TOP", 0, -8)
    MainFrame.title:SetText("WOWFC v" .. ADDON_VERSION .. " - FC 模拟器")

    -- 状态文本
    MainFrame.statusText = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    MainFrame.statusText:SetPoint("TOP", MainFrame, "TOP", 0, -35)
    MainFrame.statusText:SetText("未加载 ROM - 点击'加载 ROM'开始")

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
        MainFrame.statusText:SetText("渲染器加载失败")
        print("|cffff0000WOWFC|r: 未找到渲染器模块，请检查 UltraRenderer.lua 是否已加载")
    end

    -- 按钮区域
    local buttonY = -SCREEN_HEIGHT * SCALE - 65

    -- 加载 ROM 按钮
    local loadBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    loadBtn:SetSize(70, 22)
    loadBtn:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 15, buttonY)
    loadBtn:SetText("加载ROM")
    loadBtn:SetScript("OnClick", function()
        self:ShowROMLoader()
    end)

    -- 开始/暂停按钮
    local pauseBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    pauseBtn:SetSize(60, 22)
    pauseBtn:SetPoint("LEFT", loadBtn, "RIGHT", 5, 0)
    pauseBtn:SetText("开始")
    pauseBtn:SetScript("OnClick", function()
        self:TogglePause()
    end)
    MainFrame.pauseBtn = pauseBtn

    -- 重置按钮
    local resetBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(60, 22)
    resetBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 5, 0)
    resetBtn:SetText("重置")
    resetBtn:SetScript("OnClick", function()
        self:ResetFC()
    end)

    -- 调试按钮
    local debugBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    debugBtn:SetSize(60, 22)
    debugBtn:SetPoint("LEFT", resetBtn, "RIGHT", 5, 0)
    debugBtn:SetText("调试")
    debugBtn:SetScript("OnClick", function()
        self:ShowDebugInfo()
    end)

    -- 操控开关:玩 FC 时按下,FC 独占键盘,WoW 角色不响应;
    -- 再按一次切回 WoW 控制(WoW 角色恢复响应,FC 不接收)。
    -- 也可以按 ESC 一键退出操控模式。
    local controlBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    controlBtn:SetSize(80, 22)
    controlBtn:SetPoint("LEFT", debugBtn, "RIGHT", 5, 0)
    controlBtn:SetText("操控:关")
    MainFrame.controlBtn = controlBtn
    addon._controlMode = false  -- 默认关:WoW 优先,FC 不响应键盘

    local function applyControlMode(on)
        addon._controlMode = on and true or false
        if addon._controlMode then
            -- 独占键盘:WoW 角色不响应方向键/Z/Enter 等
            MainFrame:SetPropagateKeyboardInput(false)
            controlBtn:SetText("操控:开")
            MainFrame.statusText:SetText("操控模式 (按 ESC 退出)")
        else
            -- 释放键盘:WoW 恢复正常,FC 不接收按键(避免双开)
            MainFrame:SetPropagateKeyboardInput(true)
            controlBtn:SetText("操控:关")
            MainFrame.statusText:SetText("WoW 控制模式 (点窗口或按钮启用操控)")
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

    -- 按键设置按钮:打开自定义按键浮窗
    local keysBtn = CreateFrame("Button", nil, MainFrame, "UIPanelButtonTemplate")
    keysBtn:SetSize(60, 22)
    keysBtn:SetPoint("LEFT", controlBtn, "RIGHT", 5, 0)
    keysBtn:SetText("按键")
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
            local modeName = renderer.GetModeName and renderer:GetModeName() or "未知"
            MainFrame.fpsText:SetText(string.format("FPS:%d %s", renderFps, modeName))
        end
    end)
end

-- 显示/隐藏窗口
function addon:ToggleFrame()
    if MainFrame:IsShown() then
        MainFrame:Hide()
        self:StopGameLoop()
        -- 关窗时一并关掉操控,避免独占键盘后忘了切回 WoW
        if self._applyControlMode and self._controlMode then
            self._applyControlMode(false)
        end
    else
        MainFrame:Show()
    end
end

-- ROM 文件列表
local ROM_LIST = {}

-- 扫描 ROMs
function addon:ScanROMs()
    ROM_LIST = {}
    
    -- 从预加载数据中查找
    if _G.WOWFC_ROM_DATA then
        for filename, _ in pairs(_G.WOWFC_ROM_DATA) do
            table.insert(ROM_LIST, filename)
        end
    end
    
    -- 从SavedVariables查找
    if WOWFCDB and WOWFCDB.roms then
        for filename, _ in pairs(WOWFCDB.roms) do
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
        print("|cffff8800WOWFC|r: 没有找到任何 ROM。请把 .nes 文件放进 |cffffff00WowFC/ROMs|r 目录,跑一下转换工具,然后 /reload 即可看到游戏列表。")
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
    ROMSelectorFrame = CreateFrame("Frame", "WOWFCROMSelector", UIParent, "BasicFrameTemplateWithInset")
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
    ROMSelectorFrame.title:SetText("选择游戏")

    -- 说明
    local desc = ROMSelectorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    desc:SetPoint("TOP", ROMSelectorFrame, "TOP", 0, -40)
    desc:SetText("点击游戏名称加载：")

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
    closeBtn:SetText("关闭")
    closeBtn:SetScript("OnClick", function()
        ROMSelectorFrame:Hide()
    end)

    ROMSelectorFrame:Show()
end

-- 从文件加载 ROM
function addon:LoadROMFromFile(filename)
    MainFrame.statusText:SetText("加载中: " .. filename)

    -- 创建 FC 实例
    if not nes then
        nes = FC:new({
            onFrame = function(buffer, dirty_tiles)
                addon:OnFrame(buffer, dirty_tiles)
            end,
            onStatusUpdate = function(status)
                MainFrame.statusText:SetText(status)
            end
        })

        -- 回填持久化的声音开关到新建实例的 APU,使重载后保留上次设置。
        WOWFCDB = WOWFCDB or {}
        if WOWFCDB.soundEnabled == nil then WOWFCDB.soundEnabled = true end
        nes.apu:setEnabled(WOWFCDB.soundEnabled)
    end

    -- 读取 ROM 文件
    local romData = self:ReadROMFile(filename)

    if not romData then
        MainFrame.statusText:SetText("ROM 文件读取失败: " .. filename)
        print("|cffff0000WOWFC|r: 无法读取 " .. filename .. ",请确认文件存在于 ROMs 目录")
        return
    end

    -- 加载ROM
    local success, err = pcall(function()
        return nes:loadROM(romData)
    end)

    if success and err then
        MainFrame.statusText:SetText("已加载: " .. filename)
        print("|cff00ff00WOWFC|r: 已加载 " .. filename .. ",祝玩得开心!")

        isRunning = true
        MainFrame.pauseBtn:SetText("暂停")
        self:StartGameLoop()

        -- 加载 ROM 成功后自动开启操控模式,避免玩家手动找开关。
        -- ESC 可一键退出,松键时自动释放按钮,避免按键卡死。
        if self._applyControlMode then
            self._applyControlMode(true)
        end
    else
        MainFrame.statusText:SetText("ROM 加载失败")
        print("|cffff0000WOWFC|r: ROM 加载失败: " .. tostring(err))
    end
end

-- 读取 ROM 文件
function addon:ReadROMFile(filename)
    -- 优先使用预加载数据(addon 自带 ROM)
    if _G.WOWFC_ROM_DATA and _G.WOWFC_ROM_DATA[filename] then
        local data = _G.WOWFC_ROM_DATA[filename]
        local copy = {}
        for k, v in pairs(data) do
            copy[k] = v
        end
        return copy
    end

    -- 否则从 SavedVariables 读(玩家自己导入的)
    if WOWFCDB and WOWFCDB.roms and WOWFCDB.roms[filename] then
        return WOWFCDB.roms[filename]
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
function addon:TogglePause()
    if not nes then
        print("|cffff0000WOWFC|r: 请先加载ROM")
        return
    end

    if isRunning then
        self:StopGameLoop()
        MainFrame.pauseBtn:SetText("继续")
        isRunning = false
    else
        self:StartGameLoop()
        MainFrame.pauseBtn:SetText("暂停")
        isRunning = true
    end
end

-- 启动游戏循环
-- 用 OnUpdate driver(每个 WoW 渲染帧触发)替代 C_Timer.NewTicker(1/60)。
-- C_Timer 最多 60Hz,且 frame() 超时会丢 tick;OnUpdate 跟随 WoW 帧率,
-- 配合固定时间步进(fixed timestep)既不会让 NES 跑太快,也能在 WoW 高帧率时追帧。
function addon:StartGameLoop()
    self:StopGameLoop()

    nes:start()

    -- 解除 WoW 帧率上限,让 OnUpdate 触发更密集(打开模拟器期间)。
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
                print("|cffff0000WOWFC|r: 运行错误: " .. tostring(err))
                isRunning = false
                nes:stop()
                MainFrame.pauseBtn:SetText("开始")
                return
            end
        end
        -- 如果一帧都追不上(frame() 比 NES_FRAME_TIME 还慢),丢弃多余累积,
        -- 避免 _accum 无限膨胀导致越来越卡
        if self._accum > NES_FRAME_TIME * MAX_CATCHUP then
            self._accum = 0
        end
    end)
end

-- 停止游戏循环
function addon:StopGameLoop()
    if self._driver then
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
    if WOWFCDB and WOWFCDB.boostDisabled then
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
        nes:reset()
        MainFrame.pauseBtn:SetText("开始")
        isRunning = false
        MainFrame.statusText:SetText("已重置")
        
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

-- 帧渲染回调（接收调色板索引buffer + dirty_tiles集合）
function addon:OnFrame(buffer, dirty_tiles)
    -- 连发(turbo)处理:30Hz 切换 A/B,每帧 toggle 一次。
    -- 实际是 60fps / 2 = 30Hz,因为 ClockTurbo 在每次 OnFrame 时切换。
    -- 注意只在操控模式下生效(避免在 WoW 模式下乱按)。
    if self._controlMode and nes then
        local aState, bState = KB:ClockTurbo()
        if aState ~= nil then
            nes:setButtonState(1, Controller.BUTTON_A, aState)
        end
        if bState ~= nil then
            nes:setButtonState(1, Controller.BUTTON_B, bState)
        end
    end

    if not buffer or not renderer then return end

    renderer.Render(renderer, buffer, dirty_tiles)

    frameCount = frameCount + 1
end

-- 显示调试信息
function addon:ShowDebugInfo()
    if not nes then
        print("|cffff0000WOWFC|r: 未加载ROM")
        return
    end
    
    print("|cff00ff00=== WOWFC 调试信息 ===|r")
    
    local dirtyCount = 0
    if nes.ppu and nes.ppu.dirty_tiles then
        for _ in pairs(nes.ppu.dirty_tiles) do dirtyCount = dirtyCount + 1 end
    end
    print(string.format("帧计数: %d  DirtyTiles: %d", frameCount, dirtyCount))
    
    -- PPU状态
    if nes.ppu then
        print(string.format("PPU扫描线: %d", nes.ppu.scanline))
        print(string.format("背景显示: %s", nes.ppu.f_bgVisibility == 1 and "开" or "关"))
        print(string.format("精灵显示: %s", nes.ppu.f_spVisibility == 1 and "开" or "关"))
        print(string.format("NMI: %s", nes.ppu.f_nmiOnVblank == 1 and "启用" or "禁用"))
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
    print(string.format("|cff00ff00=== WOWFC v%s 帮助 ===|r", ADDON_VERSION))
    print("|cffffd700【打开/关闭】|r |cffffff00/fc|r 切换主窗口")
    print("|cffffd700【操控模式】|r 点窗口下方 |cffffff00操控|r 按钮切换。开启时 FC 独占键盘,WoW 角色不响应。")
    print("                |cffffff00ESC|r 一键退出操控模式。加载 ROM 时自动开启。")
    print("|cffffd700【自定义按键】|r 点 |cffffff00按键|r 按钮。支持键盘 / 手柄 / 连发(30Hz 自动按 A/B)。")
    print("                启用手柄前先在 |cffffff00WoW 设置 → 操作 → 启用游戏手柄|r 中开启。")
    print("|cffffd700【默认按键】|r")
    print("  方向键 = 移动   Z = A   X = B   Enter/Space = Start   Tab = Select")
    print("|cffffd700【命令】|r")
    print("  |cffffff00/fc skip <N>|r  帧跳过(1=关,2-10=每 N 帧渲染一帧;或 |cffffff00auto|r 自动)")
    print("  |cffffff00/fc prof|r       性能数据  |cffffff00/fc profreset|r 清零")
    print("  |cffffff00/fc boost|r      开关性能增强(运行时解除 WoW 帧率上限)")
    print("  |cffffff00/fc sound <on|off>|r 开关声音(预录制音色文件对位播放)")
    print("  |cffffff00/fc debug|r      运行时状态")
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
    end
end)

-- 导出
_G["WOWFC"] = addon
