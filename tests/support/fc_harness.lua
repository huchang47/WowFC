-- fc_harness.lua
-- 让整套 FC(CPU/PPU/APU/Mapper/ROM)在命令行 headless 跑真实 ROM 的测试夹具。
-- 用途:
--   1. CPU 优化的"正确性护栏"——逐帧 framebuffer 指纹,确保优化前后画面一致。
--   2. "优化模拟"——量化访存调用次数(与位运算实现无关的硬指标)与相对耗时。
--
-- 注意:命令行是 Lua 5.1 + 纯 Lua 位运算桩,位运算比真机(原生 C bitlib)慢得多,
-- 故 headless 的绝对 ms 不代表真机,只用相对趋势 + 访存计数。性能最终以真机
-- /fc prof 的 ms_main_loop 为准。

local M = {}

local bit_stub = require("tests.support.bit_stub")

local function installGlobals()
    _G.bit = _G.bit or bit_stub.bit
    if not _G.GetTime then
        local t = 0
        _G.GetTime = function() t = t + 1 / 60; return t end
    end
    _G.debugprofilestop = _G.debugprofilestop or function() return os.clock() * 1000 end
    _G.C_Timer = _G.C_Timer or {
        After = function() end,
        NewTicker = function() return { Cancel = function() end } end,
    }
    -- FC 核心不建 UI;保险提供吃掉一切调用的 CreateFrame 桩
    _G.CreateFrame = _G.CreateFrame or function()
        return setmetatable({}, { __index = function() return function() end end })
    end
    -- 不提供 PlaySoundFile → APU 自动降级(不发声),不影响 CPU/PPU 正确性
end

local loaded = false
-- Lua 5.1 的 loadfile 不跳过 UTF-8 BOM(WoW 能加载是因其运行时会处理),
-- 这里读出后剥掉 BOM 再 loadstring,chunkname 带文件名以便报错定位。
local function loadLuaFile(path)
    local fh = assert(io.open(path, "rb"), "无法打开 " .. path)
    local src = fh:read("*a")
    fh:close()
    if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
    return loadstring(src, "@" .. path)
end

local function loadModules()
    if loaded then return end
    installGlobals()
    -- 按 TOC 顺序加载(跳过 UI/生成数据);Mapper 在 FC 之后即可,createMapper 运行时才查
    local files = {
        "Utils/BitOps.lua",
        "Utils/Buffer.lua",
        "Core/CPU.lua",
        "Core/PPU.lua",
        "Core/APU.lua",
        "Core/ROM.lua",
        "Core/Controller.lua",
        "Core/FC.lua",
        "Core/Mappers/Mapper0.lua",
        "Core/Mappers/Mapper1.lua",
        "Core/Mappers/Mapper2.lua",
        "Core/Mappers/Mapper3.lua",
        "Core/Mappers/Mapper4.lua",
    }
    for _, f in ipairs(files) do
        local chunk, err = loadLuaFile(f)
        if not chunk then error("加载失败 " .. f .. ": " .. tostring(err)) end
        chunk()
    end
    loaded = true
end
M.loadModules = loadModules

function M.readRom(path)
    local fh = assert(io.open(path, "rb"), "无法打开 ROM: " .. tostring(path))
    local data = fh:read("*a")
    fh:close()
    return data
end

-- 创建并加载一个已 start 的 FC 实例。romData 为 .nes 字节串。
function M.newFC(romData)
    loadModules()
    local fc = FC:new({
        onFrame = function() end,
        onStatusUpdate = function() end,
    })
    if not fc:loadROM(romData) then error("loadROM 失败(ROM 解析错误)") end
    fc:start()
    return fc
end

function M.runFrames(fc, n)
    for _ = 1, n do fc:frame() end
end

-- framebuffer 指纹:多项式滚动哈希,纯算术(不依赖 bit,且避免 double 溢出),
-- 同输入确定可复现。只用于"优化前后是否一致"的判断。
function M.hashFramebuffer(fc)
    local buf = fc.ppu.buffer
    local h = 0
    for i = 0, 256 * 240 - 1 do
        h = (h * 1000003 + (buf[i] or 0)) % 2147483647
    end
    return h
end

-- 在实例上包一层 memoryMapperLoad 计数器(cpuLoad 走 cpu.nes:memoryMapperLoad,
-- 实例字段优先,故能被拦截)。返回 reader 取当前计数。PRG 直读优化后,0x8000+
-- 不再进这条慢路径,计数应明显下降——这是与位运算无关的硬指标。
function M.instrumentLoads(fc)
    local orig = getmetatable(fc).memoryMapperLoad
    local count = 0
    fc.memoryMapperLoad = function(self, addr)
        count = count + 1
        return orig(self, addr)
    end
    return function() return count end
end

return M
