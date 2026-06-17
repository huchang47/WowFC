-- sound_toggle_persist_test.lua
-- 单元测试:声音开关命令与持久化(任务 10.3)
--
-- 覆盖(对应 design.md Testing Strategy 的 EXAMPLE 行 / 需求 4.1、4.4):
--   - 4.1:`/fc sound on|off` 改变 apu:isEnabled();`/fc help` 输出含该命令说明
--   - 4.4:设置 WOWFCDB.soundEnabled 后,经初始化路径(新建 FC 实例时回填)恢复到 APU
--
-- 隔离策略(真实加载,最小桩):
--   本测试加载**真实** WOWFC.lua(剥离 UTF-8 BOM,以 vararg 传入 addonName/addon),
--   并加载**真实** Core/APU.lua —— 被测的命令分支、ShowHelp、OnInitialize 与
--   LoadROMFromFile 回填逻辑全部是 WOWFC.lua 的真实代码。
--   仅对以下两类做桩接近似(因 WoW UI 运行时 / 重型内核不可在标准 Lua 下加载):
--     1) WoW UI 运行时:CreateFrame / SlashCmdList / C_Timer / UIParent / 渲染器 /
--        Keybinding / GetCVar/SetCVar / print —— 用"黑洞"链式桩吞掉所有 UI 调用。
--     2) FC:new:桩为返回最小 nes 对象,其 apu 字段为**真实** APU:new()(被验证对象);
--        loadROM/start/stop 为最小空实现。这样 nes.apu 的开关语义被真实验证。
--   关键:命令分支用的是 WOWFC.lua 内的文件 upvalue `nes`,本测试通过真实路径
--   (addon:LoadROMFromFile)让 `nes` 被赋值,从而命令分支能看到非 nil 的 nes
--   并真实调用 nes.apu:setEnabled / isEnabled —— 而非另起炉灶复刻逻辑。
--
-- 独立可运行入口(lua tests/sound_toggle_persist_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

-- 真实 APU(提供真实 setEnabled/isEnabled);ToneMap 先加载使表存在(不影响开关语义)。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")

-- ---------------------------------------------------------------------------
-- "黑洞"链式桩:对任意字段读取返回自身、任意调用返回自身、任意赋值吞掉。
-- 用于替身 WoW 的 Frame / FontString / Texture / 渲染器实例等 UI 对象,
-- 使 CreateMainFrame 等大量 UI 调用(SetSize/SetPoint/CreateFontString...)安全通过。
-- ---------------------------------------------------------------------------
local blackhole = setmetatable({}, {
    __index = function() return _G.__WOWFC_BLACKHOLE end,
    __call = function() return _G.__WOWFC_BLACKHOLE end,
    __newindex = function() end,
    __tostring = function() return "<stub>" end,
})
_G.__WOWFC_BLACKHOLE = blackhole

-- ---------------------------------------------------------------------------
-- 捕获 print 输出(用于断言 /fc help 含命令说明)。
-- ---------------------------------------------------------------------------
local printBuffer = {}
local function clearPrint() printBuffer = {} end
local function printText() return table.concat(printBuffer, "\n") end
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(printBuffer, table.concat(parts, "\t"))
end

-- ---------------------------------------------------------------------------
-- 一次性安装 WoW UI 运行时桩(各次加载共用,行为一致)。
-- ---------------------------------------------------------------------------
_G.UIParent = blackhole
_G.SlashCmdList = {}                                  -- 真实表,供读取注册的处理器
_G.CreateFrame = function() return blackhole end
_G.C_Timer = { NewTicker = function() return blackhole end,
               After = function() end }
_G.GetCVar = function() return "30" end               -- 任意值即可
_G.SetCVar = function() end
-- Keybinding 桩(WOWFC.lua 模块作用域 `local KB = WOWFC_Keybinding`;OnInitialize 调 KB:Load)
_G.WOWFC_Keybinding = {
    Load = function() end, Save = function() end, Show = function() end,
    IsRecording = function() return false end,
    SetTurboHeld = function() end,
    ClockTurbo = function() return nil, nil end,
    LookupKey = function() return nil end,
}
-- 渲染器工厂桩:使 CreateMainFrame 走"有渲染器"分支(避免误导性错误打印)
_G.WOWFC_UltraRenderer = { Create = function() return blackhole end }
-- ReadROMFile 命中预加载数据,使 LoadROMFromFile 拿到非 nil romData
_G.WOWFC_ROM_DATA = { ["TEST.NES"] = { [0] = 0x4E, [1] = 0x45 } }

-- ---------------------------------------------------------------------------
-- 以 vararg 加载真实 WOWFC.lua(剥离 UTF-8 BOM)。
-- ---------------------------------------------------------------------------
local function loadAddonChunk(path, ...)
    local fh = assert(io.open(path, "rb"), "无法打开 " .. path)
    local src = fh:read("*a")
    fh:close()
    if src:sub(1, 3) == "\239\187\191" then  -- EF BB BF
        src = src:sub(4)
    end
    local loader = loadstring or load
    local chunk = assert(loader(src, "@" .. path))
    return chunk(...)
end

-- FC:new 桩:返回最小 nes 对象,apu 为真实 APU:new();记录最近实例供断言。
local function makeFcStub()
    local fcStub = {}
    function fcStub:new(_opts)
        local inst = {
            apu = APU:new(nil),
            loadROM = function() return true end,
            start = function() end,
            stop = function() end,
        }
        fcStub._last = inst
        return inst
    end
    return fcStub
end

-- 加载一份全新的 addon(全新 upvalue:nes=nil),执行真实 OnInitialize。
--   initialDB:本次加载前写入 _G.WOWFCDB 的初值(模拟 SavedVariables 已读出)。
-- 返回 ctx { addon, fc, slash }。
local function loadFreshAddon(initialDB)
    _G.WOWFCDB = initialDB                 -- 可为 nil:OnInitialize 会创建并取默认值
    local addon = {}
    local fcStub = makeFcStub()
    _G.FC = fcStub
    clearPrint()
    loadAddonChunk("WOWFC.lua", "WowFC", addon)
    addon:OnInitialize()                   -- 注册 SlashCmdList["WOWFC"]、初始化 soundEnabled
    return {
        addon = addon,
        fc = fcStub,
        slash = _G.SlashCmdList["WOWFC"],
    }
end

local allOk = true

-- ===========================================================================
-- 1) 需求 4.1:/fc sound on|off 改变 apu:isEnabled()
-- ===========================================================================
do
    io.write("== /fc sound on|off 改变 apu:isEnabled() ==\n")
    local t = Unit.new("sound command toggles APU")

    t:it("加载 ROM 后,sound off / sound on 切换 apu:isEnabled()", function(a)
        local ctx = loadFreshAddon({})            -- soundEnabled 取默认 true
        ctx.addon:LoadROMFromFile("TEST.NES")     -- 真实路径设置 upvalue nes(含真实 apu)
        local apu = ctx.fc._last.apu
        a.equal(apu:isEnabled(), true, "前置:默认应启用")

        ctx.slash("sound off")
        a.equal(apu:isEnabled(), false, "/fc sound off 应关闭 APU")

        ctx.slash("sound on")
        a.equal(apu:isEnabled(), true, "/fc sound on 应开启 APU")
    end)

    t:it("命令同时把开关写入 WOWFCDB.soundEnabled(持久化)", function(a)
        local ctx = loadFreshAddon({})
        ctx.addon:LoadROMFromFile("TEST.NES")

        ctx.slash("sound off")
        a.equal(_G.WOWFCDB.soundEnabled, false, "sound off 应写 WOWFCDB.soundEnabled=false")

        ctx.slash("sound on")
        a.equal(_G.WOWFCDB.soundEnabled, true, "sound on 应写 WOWFCDB.soundEnabled=true")
    end)

    t:it("未加载 ROM 时 /fc sound on 安全(不报错、不改变全局)", function(a)
        local ctx = loadFreshAddon({})
        a.no_error(function() ctx.slash("sound on") end, "无 ROM 时 sound 命令不应抛错")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 2) 需求 4.1:/fc help 输出含 sound 命令说明
-- ===========================================================================
do
    io.write("== /fc help 输出含 sound 命令说明 ==\n")
    local t = Unit.new("help mentions sound command")

    t:it("help 文本包含 /fc sound 与开关声音说明", function(a)
        local ctx = loadFreshAddon({})
        clearPrint()
        ctx.slash("help")
        local out = printText()
        a.ok(out:find("/fc sound", 1, true) ~= nil, "help 应包含 '/fc sound'")
        a.ok(out:find("开关声音", 1, true) ~= nil, "help 应包含 '开关声音' 说明")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 3) 需求 4.4:设置 WOWFCDB.soundEnabled 后经初始化路径恢复到 APU
--    初始化路径 = OnInitialize 规范化默认值 + LoadROMFromFile 新建实例时回填。
-- ===========================================================================
do
    io.write("== WOWFCDB.soundEnabled 经初始化路径恢复到 APU ==\n")
    local t = Unit.new("persisted soundEnabled restored to APU")

    t:it("持久化 false:新建 FC 实例后 apu:isEnabled() 恢复为 false", function(a)
        local ctx = loadFreshAddon({ soundEnabled = false })  -- 模拟重载后读出的持久化值
        ctx.addon:LoadROMFromFile("TEST.NES")
        a.equal(ctx.fc._last.apu:isEnabled(), false,
            "回填路径应将持久化的 false 恢复到 APU")
    end)

    t:it("持久化 true:新建 FC 实例后 apu:isEnabled() 恢复为 true", function(a)
        local ctx = loadFreshAddon({ soundEnabled = true })
        ctx.addon:LoadROMFromFile("TEST.NES")
        a.equal(ctx.fc._last.apu:isEnabled(), true,
            "回填路径应将持久化的 true 恢复到 APU")
    end)

    t:it("无持久化值(nil):OnInitialize 取默认 true,回填后 APU 启用", function(a)
        local ctx = loadFreshAddon(nil)                       -- WOWFCDB 不存在
        a.equal(_G.WOWFCDB.soundEnabled, true,
            "OnInitialize 应将缺省 soundEnabled 规范化为 true")
        ctx.addon:LoadROMFromFile("TEST.NES")
        a.equal(ctx.fc._last.apu:isEnabled(), true, "默认 true 应回填到 APU")
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== 声音开关与持久化测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
