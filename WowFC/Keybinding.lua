-- Keybinding.lua
-- 自定义按键映射模块。
-- 数据结构、持久化、UI、连发逻辑都在这里。
-- WOWFC.lua 在 OnKeyDown/OnKeyUp/OnMouseDown/OnMouseUp 转发到这里。

local _G = _G

-- 模块对象。由 WOWFC.lua 在初始化时取出来用。
WOWFC_Keybinding = {}
local M = WOWFC_Keybinding

-- ============================================================
-- 默认按键映射
-- ============================================================
-- 每个 NES 按钮可绑定多个 WoW 键。WoW 的 OnKeyDown 给的 key 名见
-- https://warcraft.wiki.gg/wiki/Key_codes,鼠标按钮见 OnMouseDown 文档。
-- ============================================================
M.DEFAULT_BINDINGS = {
    [Controller.BUTTON_A]      = { "K" },
    [Controller.BUTTON_B]      = { "J" },
    [Controller.BUTTON_SELECT] = { "B" },
    [Controller.BUTTON_START]  = { "N", "SPACE" },
    [Controller.BUTTON_UP]     = { "W" },
    [Controller.BUTTON_DOWN]   = { "S" },
    [Controller.BUTTON_LEFT]   = { "A" },
    [Controller.BUTTON_RIGHT]  = { "D" },
}

-- 连发槽:turbo 槽分别绑到 A/B 上,30Hz 切换
M.DEFAULT_TURBO_BINDINGS = {
    A = {},  -- 默认未绑定
    B = {},
}

-- NES 按钮显示名(中文)
M.BUTTON_NAMES = {
    [Controller.BUTTON_A]      = "A",
    [Controller.BUTTON_B]      = "B",
    [Controller.BUTTON_SELECT] = "选择",
    [Controller.BUTTON_START]  = "开始",
    [Controller.BUTTON_UP]     = "↑ 上",
    [Controller.BUTTON_DOWN]   = "↓ 下",
    [Controller.BUTTON_LEFT]   = "← 左",
    [Controller.BUTTON_RIGHT]  = "→ 右",
}

-- 按钮顺序(UI 显示用)
M.BUTTON_ORDER = {
    Controller.BUTTON_A,
    Controller.BUTTON_B,
    Controller.BUTTON_SELECT,
    Controller.BUTTON_START,
    Controller.BUTTON_UP,
    Controller.BUTTON_DOWN,
    Controller.BUTTON_LEFT,
    Controller.BUTTON_RIGHT,
}

-- ============================================================
-- 当前生效的绑定 + 反向查找表
-- ============================================================
M.bindings = nil       -- [nesButton] = { "Z", ... }
M.turboBindings = nil  -- { A = {"C"}, B = {"V"} }
M._reverseMap = {}     -- [wowKey] = nesButton  (单值,先到先得)
M._reverseTurboMap = {} -- [wowKey] = "A" / "B"
M._turboHeld = { A = false, B = false }  -- 当前是否按住连发键
M._turboToggle = false                    -- 30Hz toggle 翻转位

-- 深拷贝默认绑定到工作表(避免 SavedVariables 持久化引用)
local function cloneList(list)
    local copy = {}
    for i, v in ipairs(list) do copy[i] = v end
    return copy
end

local function cloneBindings(src)
    local copy = {}
    for k, v in pairs(src) do
        copy[k] = cloneList(v)
    end
    return copy
end

-- ============================================================
-- 加载/保存(配合 SavedVariables WOWFCDB)
-- ============================================================
function M:Load()
    _G.WOWFCDB = _G.WOWFCDB or {}
    local db = _G.WOWFCDB

    if db.keybindings then
        self.bindings = cloneBindings(db.keybindings)
    else
        self.bindings = cloneBindings(self.DEFAULT_BINDINGS)
    end

    if db.turboBindings then
        self.turboBindings = cloneBindings(db.turboBindings)
    else
        self.turboBindings = cloneBindings(self.DEFAULT_TURBO_BINDINGS)
    end

    self:RebuildReverseMap()
end

function M:Save()
    _G.WOWFCDB = _G.WOWFCDB or {}
    _G.WOWFCDB.keybindings = cloneBindings(self.bindings)
    _G.WOWFCDB.turboBindings = cloneBindings(self.turboBindings)
end

function M:RebuildReverseMap()
    self._reverseMap = {}
    self._reverseTurboMap = {}
    for nesButton, keys in pairs(self.bindings or {}) do
        for _, k in ipairs(keys) do
            -- 一个 WoW 键只能绑到一个 NES 按钮上,后绑覆盖前绑
            self._reverseMap[k] = nesButton
        end
    end
    for slot, keys in pairs(self.turboBindings or {}) do
        for _, k in ipairs(keys) do
            self._reverseTurboMap[k] = slot
        end
    end
end

function M:ResetToDefault()
    self.bindings = cloneBindings(self.DEFAULT_BINDINGS)
    self.turboBindings = cloneBindings(self.DEFAULT_TURBO_BINDINGS)
    self:RebuildReverseMap()
    self:Save()
end

-- ============================================================
-- 按钮绑定增删
-- ============================================================
-- 在所有按钮绑定中移除指定 key(防止冲突,一个 WoW 键只能绑 1 处)
function M:_RemoveKeyEverywhere(key)
    for _, keys in pairs(self.bindings or {}) do
        for i = #keys, 1, -1 do
            if keys[i] == key then table.remove(keys, i) end
        end
    end
    for _, keys in pairs(self.turboBindings or {}) do
        for i = #keys, 1, -1 do
            if keys[i] == key then table.remove(keys, i) end
        end
    end
end

function M:AddBinding(nesButton, wowKey)
    self:_RemoveKeyEverywhere(wowKey)
    if not self.bindings[nesButton] then self.bindings[nesButton] = {} end
    table.insert(self.bindings[nesButton], wowKey)
    self:RebuildReverseMap()
    self:Save()
end

function M:AddTurboBinding(slot, wowKey)
    self:_RemoveKeyEverywhere(wowKey)
    if not self.turboBindings[slot] then self.turboBindings[slot] = {} end
    table.insert(self.turboBindings[slot], wowKey)
    self:RebuildReverseMap()
    self:Save()
end

function M:ClearBinding(nesButton)
    self.bindings[nesButton] = {}
    self:RebuildReverseMap()
    self:Save()
end

function M:ClearTurboBinding(slot)
    self.turboBindings[slot] = {}
    self:RebuildReverseMap()
    self:Save()
end

-- ============================================================
-- 反向查找:WoW 键 → NES 按钮
-- ============================================================
-- 返回 (nesButton, isTurbo, turboSlot)
-- 三种结果:
--   1) 普通绑定:        nesButton 是数字(0..7), isTurbo=false
--   2) 连发绑定:        nesButton 是 0(A) 或 1(B), isTurbo=true, turboSlot="A"/"B"
--   3) 未绑定:          nesButton=nil
function M:LookupKey(wowKey)
    local turbo = self._reverseTurboMap[wowKey]
    if turbo then
        local nesBtn = (turbo == "A") and Controller.BUTTON_A or Controller.BUTTON_B
        return nesBtn, true, turbo
    end
    local nesBtn = self._reverseMap[wowKey]
    if nesBtn then
        return nesBtn, false, nil
    end
    return nil
end

-- ============================================================
-- 连发(turbo)
-- ============================================================
-- 由 WOWFC.lua 在 OnKeyDown/OnMouseDown 时调用,设置连发槽 hold 状态
function M:SetTurboHeld(slot, held)
    self._turboHeld[slot] = held and true or false
end

-- 由 FC frame loop 每帧调用一次,做 30Hz toggle。
-- 按住连发键时,A/B 状态以 30Hz 切换(60fps / 2)。
-- 返回两个布尔:turboAState, turboBState (true=按下, false=释放, nil=未启用 turbo)
function M:ClockTurbo()
    if not self._turboHeld.A and not self._turboHeld.B then
        return nil, nil
    end
    self._turboToggle = not self._turboToggle
    local aState = self._turboHeld.A and self._turboToggle or nil
    local bState = self._turboHeld.B and self._turboToggle or nil
    return aState, bState
end

function M:IsAnyTurboHeld()
    return self._turboHeld.A or self._turboHeld.B
end

-- ============================================================
-- 改键 UI 浮窗
-- ============================================================
-- 浮窗结构:
--   标题 + 一段提示文字
--   8 行 NES 按钮,每行 [按钮名] [当前绑定显示] [+ 添加] [清空]
--   2 行连发槽,同上
--   底部 [恢复默认] [关闭]
--
-- 点 [+ 添加] 进入"录键"模式:浮窗顶部红字提示"按下要绑定的键(ESC 取消)..."
-- 这时浮窗独占键盘事件,接收的下一个非 ESC 输入会被绑定到对应按钮。
-- 启用 WoW gamepad(设置 → 操作 → 启用游戏手柄)后,手柄按钮也走 OnKeyDown,
-- 所以无需额外代码即可绑定 PadAButton/PadDPadUp 等手柄按键。
-- ESC 取消录键。
-- 录键期间 FC 不接收输入(避免改键时角色乱动)。

local KeybindingFrame = nil
local KEY_BLACKLIST = {  -- 不允许绑的键
    ESCAPE = true,        -- 永远保留为退出操控/取消录键
}

-- 把按钮的当前绑定列表转成可读字符串
local function bindingsToString(keys)
    if not keys or #keys == 0 then return "(未绑定)" end
    return table.concat(keys, ", ")
end

-- 创建浮窗(懒构造)
function M:CreateUI()
    if KeybindingFrame then return KeybindingFrame end

    local f = CreateFrame("Frame", "WOWFCKeybindingFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(420, 460)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    f.TitleBg:SetHeight(30)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", f.TitleBg, "TOP", 0, -8)
    f.title:SetText("WOWFC 按键设置")

    -- 顶部说明文字 / 录键提示
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hint:SetPoint("TOP", f, "TOP", 0, -36)
    f.hint:SetWidth(380)
    f.hint:SetJustifyH("CENTER")
    f.hint:SetText("点 [+] 添加按键(键盘或手柄),ESC 退出")

    -- 录键状态:一旦进入,所有键盘输入都被吞掉用于绑定
    f._recording = false
    f._recordTarget = nil   -- { type="button"|"turbo", id=nesButton|"A"|"B" }

    -- 行布局参数
    local rowH = 26
    local rowW = 380
    local nameX = 20
    local keysX = 100
    local addBtnX = 260
    local clearBtnX = 320

    f._rows = {}

    local function makeRow(parent, y, label, type_, id)
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(rowW, rowH)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name:SetWidth(80)
        row.name:SetJustifyH("LEFT")
        row.name:SetText(label)

        row.keys = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.keys:SetPoint("LEFT", row, "LEFT", keysX - nameX, 0)
        row.keys:SetWidth(150)
        row.keys:SetJustifyH("LEFT")
        row.keys:SetText("(未绑定)")

        local addBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        addBtn:SetSize(50, 20)
        addBtn:SetPoint("LEFT", row, "LEFT", addBtnX - nameX, 0)
        addBtn:SetText("+ 添加")
        addBtn:SetScript("OnClick", function()
            M:_BeginRecord(type_, id)
        end)

        local clearBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        clearBtn:SetSize(50, 20)
        clearBtn:SetPoint("LEFT", row, "LEFT", clearBtnX - nameX, 0)
        clearBtn:SetText("清空")
        clearBtn:SetScript("OnClick", function()
            if type_ == "button" then
                M:ClearBinding(id)
            else
                M:ClearTurboBinding(id)
            end
            M:RefreshUI()
        end)

        row.type = type_
        row.id = id
        return row
    end

    local y = -64
    -- 8 个 NES 按钮
    for _, btn in ipairs(M.BUTTON_ORDER) do
        local row = makeRow(f, y, M.BUTTON_NAMES[btn], "button", btn)
        f._rows[#f._rows + 1] = row
        y = y - rowH
    end

    -- 分隔线 + 标签
    local turboLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    turboLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y - 8)
    turboLabel:SetText("连发(按住 30Hz 自动按):")
    y = y - 22

    -- 2 个连发槽
    for _, slot in ipairs({ "A", "B" }) do
        local row = makeRow(f, y, "连发 " .. slot, "turbo", slot)
        f._rows[#f._rows + 1] = row
        y = y - rowH
    end

    -- 底部按钮
    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 22)
    resetBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 16)
    resetBtn:SetText("恢复默认")
    resetBtn:SetScript("OnClick", function()
        M:ResetToDefault()
        M:RefreshUI()
    end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    closeBtn:SetText("关闭")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- 接收键盘(包括 WoW 启用 gamepad 后的手柄按键如 PadAButton)
    -- 录键模式下消费按键,平时穿透给 WoW
    f:SetPropagateKeyboardInput(true)
    f:EnableKeyboard(true)
    f:EnableMouse(true)  -- 仅用于拖动窗口
    f:SetScript("OnKeyDown", function(self, key)
        M:_OnRecordKey(key)
    end)

    KeybindingFrame = f
    M:RefreshUI()
    return f
end

function M:RefreshUI()
    if not KeybindingFrame then return end
    for _, row in ipairs(KeybindingFrame._rows) do
        if row.type == "button" then
            row.keys:SetText(bindingsToString(self.bindings[row.id]))
        else
            row.keys:SetText(bindingsToString(self.turboBindings[row.id]))
        end
    end
end

function M:_BeginRecord(type_, id)
    if not KeybindingFrame then return end
    KeybindingFrame._recording = true
    KeybindingFrame._recordTarget = { type = type_, id = id }
    -- 录键时独占键盘,避免按键穿透到 WoW
    KeybindingFrame:SetPropagateKeyboardInput(false)
    local label
    if type_ == "button" then
        label = self.BUTTON_NAMES[id] or tostring(id)
    else
        label = "连发 " .. tostring(id)
    end
    KeybindingFrame.hint:SetText(
        "|cffff8800按下要绑定到 [" .. label .. "] 的键(ESC 取消)|r")
end

function M:_EndRecord(canceled)
    if not KeybindingFrame then return end
    KeybindingFrame._recording = false
    KeybindingFrame._recordTarget = nil
    KeybindingFrame:SetPropagateKeyboardInput(true)
    if canceled then
        KeybindingFrame.hint:SetText("点 [+] 添加按键(键盘或手柄),ESC 退出")
    else
        KeybindingFrame.hint:SetText("|cff00ff00已添加|r — 点 [+] 继续添加,或关闭窗口")
    end
end

function M:_OnRecordKey(key)
    if not KeybindingFrame or not KeybindingFrame._recording then return end
    if key == "ESCAPE" then
        self:_EndRecord(true)
        return
    end
    if KEY_BLACKLIST[key] then
        return  -- 忽略黑名单键
    end
    local target = KeybindingFrame._recordTarget
    if not target then
        self:_EndRecord(true)
        return
    end
    if target.type == "button" then
        self:AddBinding(target.id, key)
    else
        self:AddTurboBinding(target.id, key)
    end
    self:RefreshUI()
    self:_EndRecord(false)
end

function M:Show()
    self:CreateUI()
    KeybindingFrame:Show()
end

function M:IsRecording()
    return KeybindingFrame and KeybindingFrame._recording
end
