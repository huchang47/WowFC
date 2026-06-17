-- fc_apu_integration_test.lua
-- 集成单元测试:APU 接入 FC 的内存映射与帧循环(任务 9.4)
--
-- 覆盖(对应 design.md Testing Strategy 的 EXAMPLE 行 / 需求 5.2、5.3、5.4):
--   - 路由:$4000-$4013 / $4015 / $4017 经 memoryMapperWrite 路由到 apu:writeRegister;
--           $4014(OAM DMA)、$4016(strobe)不路由到 apu(需求 1.1、5.2)
--   - 读取:memoryMapperLoad($4015) 返回 apu:readStatus();$4016/$4017 返回 controller:read;
--           其余只写 APU 寄存器读取返回 0(需求 1.1、5.2)
--   - 回归:$4016 仍触发 controller:strobe;$4014 仍触发 OAM DMA(cyclesToHalt=513)(需求 5.2)
--   - 帧驱动:每完成一个 NES 帧调用 apu:tick() 恰一次;帧跳过(skipN=2/3)下
--             apu:tick() 次数 = NES 帧数,与 present(onFrame)次数无关(需求 5.3、5.4)
--
-- 隔离策略(见文末说明):
--   本测试加载**真实** Core/FC.lua(去掉 UTF-8 BOM),并通过**真实** FC:new 构造实例,
--   只把 CPU/PPU/Controller/APU 四个子系统替换为记录型 mock(全局桩)。
--   因此 memoryMapperWrite/memoryMapperLoad/frame 三段逻辑全部是 FC 的真实代码,
--   断言的是真实接线行为,而非复制逻辑。doOAMDMA 也走真实实现(回归)。
--
-- 独立可运行入口(lua tests/fc_apu_integration_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 安装全局 bit(FC.lua 顶部 `local band = bit.band` 依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

-- ---------------------------------------------------------------------------
-- 加载真实 FC.lua:Core/FC.lua 带 UTF-8 BOM,标准 Lua 的 dofile 会报错,
-- 这里读源码、剥掉 BOM 后用 loadstring/load 执行(执行后设置 _G.FC 并返回)。
-- ---------------------------------------------------------------------------
local function loadModuleStripBOM(path)
    local fh = assert(io.open(path, "rb"), "无法打开 " .. path)
    local src = fh:read("*a")
    fh:close()
    if src:sub(1, 3) == "\239\187\191" then  -- EF BB BF
        src = src:sub(4)
    end
    local loader = loadstring or load
    local chunk = assert(loader(src, "@" .. path))
    return chunk()
end

-- ---------------------------------------------------------------------------
-- 子系统 mock 工厂(均为记录型替身,聚焦验证 FC 的路由/帧驱动接线)。
-- ---------------------------------------------------------------------------

-- APU mock:记录 writeRegister/readStatus/tick/reset 调用。
local function makeApuMock()
    local m = {
        writes = {},            -- 每项 { address, value }
        readStatusCount = 0,
        readStatusValue = 0xAB, -- 哨兵返回值,验证 $4015 读取确实来自 apu
        tickCount = 0,
        resetCount = 0,
    }
    function m:writeRegister(address, value)
        table.insert(self.writes, { address = address, value = value })
    end
    function m:readStatus()
        self.readStatusCount = self.readStatusCount + 1
        return self.readStatusValue
    end
    function m:tick() self.tickCount = self.tickCount + 1 end
    function m:reset() self.resetCount = self.resetCount + 1 end
    -- 是否记录过对某地址的写入
    function m:wroteAddress(address)
        for _, w in ipairs(self.writes) do
            if w.address == address then return w end
        end
        return nil
    end
    return m
end

-- Controller mock:记录 strobe 与 read。
local function makeControllerMock()
    local m = {
        strobeCalls = {},                 -- strobe 收到的值序列
        readCalls = {},                   -- read 收到的控制器号序列
        readReturns = { [1] = 0x11, [2] = 0x22 },
    }
    function m:strobe(value) table.insert(self.strobeCalls, value) end
    function m:read(num)
        table.insert(self.readCalls, num)
        return self.readReturns[num]
    end
    function m:reset() end
    function m:setButtonState() end
    return m
end

-- CPU mock:emulate 固定返回 3 cycles;mmapWrite/mmapLoad 由 FC:new 注入。
local function makeCpuMock()
    return {
        mem = {},
        cyclesToHalt = 0,
        nmiRaised = false,          -- 使 _processNMI 提前返回,避开复杂 NMI 循环
        REG_SP = 0xFF,
        REG_PC = 0,
        _cpuCycleBase = 0,
        _jmpSelfDetected = false,
        reset = function(self) end,
        emulate = function(self) return 3 end,
    }
end

-- PPU mock:累计 dots,跨过阈值即标记 frameEnded(驱动帧完成);记录 renderFrame 次数。
local function makePpuMock()
    local m = {
        buffer = {},
        spriteMem = {},             -- doOAMDMA 真实实现需要(回归)
        frameEnded = false,
        _perScanline = false,
        _dotAcc = 0,
        renderCount = 0,
        STATUS_SPRITE0HIT = 0x40,
    }
    function m:reset() end
    function m:startFrame() self._dotAcc = 0; self.frameEnded = false end
    function m:advanceDots(dots)
        self._dotAcc = self._dotAcc + (dots or 0)
        if self._dotAcc >= 300 then  -- 远小于一帧,使测试快速完成
            self.frameEnded = true
        end
    end
    function m:renderFrame() self.renderCount = self.renderCount + 1 end
    function m:setStatusFlag(flag, on) end
    function m:write(addr, value) end
    function m:read(addr) return 0 end
    return m
end

-- 安装四个子系统全局桩,返回各 mock 句柄(供断言)。
local function installStubGlobals()
    local apu = makeApuMock()
    local ctrl = makeControllerMock()
    local cpu = makeCpuMock()
    local ppu = makePpuMock()
    _G.APU = { new = function(self, nes) return apu end }
    _G.Controller = { new = function(self, nes) return ctrl end }
    _G.CPU = { new = function(self, nes) return cpu end }
    _G.PPU = { new = function(self, nes) return ppu end }
    return { apu = apu, ctrl = ctrl, cpu = cpu, ppu = ppu }
end

-- 构造一个真实 FC 实例(走真实 FC:new),mocks 为其子系统。
-- onFramePresent:可选计数器,记录 onFrame(present)被调用次数。
local function newFC(FC, presentCounter)
    local mocks = installStubGlobals()
    local fc = FC:new({
        onFrame = function(buffer, ppu)
            if presentCounter then presentCounter.count = presentCounter.count + 1 end
        end,
    })
    return fc, mocks
end

-- 加载真实 FC(只此一次,_G.FC 也被设置)。
local FC = loadModuleStripBOM("Core/FC.lua")

local allOk = true

-- ===========================================================================
-- 1) FC:new / FC:reset 接线(任务 9.1 的接线在此顺带验证,低成本)
-- ===========================================================================
do
    io.write("== FC 接线 APU(new/reset) ==\n")
    local t = Unit.new("FC wires APU")

    t:it("FC:new 创建 fc.apu", function(a)
        local fc, mocks = newFC(FC)
        a.ok(fc.apu == mocks.apu, "fc.apu 应为 APU:new 返回的实例")
    end)

    t:it("FC:reset 调用 apu:reset()", function(a)
        local fc, mocks = newFC(FC)
        fc:reset()
        a.equal(mocks.apu.resetCount, 1, "reset 应转发到 apu:reset 一次")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 2) memoryMapperWrite 路由(需求 1.1、5.2)
-- ===========================================================================
do
    io.write("== memoryMapperWrite 路由到 apu:writeRegister ==\n")
    local t = Unit.new("write routing -> apu")

    t:it("$4000-$4013 / $4015 / $4017 全部路由到 apu:writeRegister(地址+值匹配)", function(a)
        local fc, mocks = newFC(FC)
        -- 构造期望路由到 apu 的地址清单
        local apuAddrs = {}
        for addr = 0x4000, 0x4013 do apuAddrs[#apuAddrs + 1] = addr end
        apuAddrs[#apuAddrs + 1] = 0x4015
        apuAddrs[#apuAddrs + 1] = 0x4017
        -- 用与地址相关的可辨识值写入(取低字节,保证 0-255)
        for _, addr in ipairs(apuAddrs) do
            local value = bit.band(addr, 0xFF)
            fc:memoryMapperWrite(addr, value)
        end
        -- 逐一断言被记录,且值匹配
        for _, addr in ipairs(apuAddrs) do
            local w = mocks.apu:wroteAddress(addr)
            a.ok(w ~= nil, string.format("$%04X 应路由到 apu:writeRegister", addr))
            if w then
                a.equal(w.value, bit.band(addr, 0xFF),
                    string.format("$%04X 写入值应透传", addr))
            end
        end
        -- 写入次数应恰为清单长度(没有多余/遗漏)
        a.equal(#mocks.apu.writes, #apuAddrs, "apu 写入次数应等于 APU 寄存器数")
    end)

    t:it("$4014(OAM DMA)不路由到 apu", function(a)
        local fc, mocks = newFC(FC)
        fc:memoryMapperWrite(0x4014, 0x02)
        a.is_nil(mocks.apu:wroteAddress(0x4014), "$4014 不应路由到 apu")
    end)

    t:it("$4016(strobe)不路由到 apu", function(a)
        local fc, mocks = newFC(FC)
        fc:memoryMapperWrite(0x4016, 0x01)
        a.is_nil(mocks.apu:wroteAddress(0x4016), "$4016 不应路由到 apu")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 3) 回归:$4016 仍触发 controller:strobe;$4014 仍触发 OAM DMA(需求 5.2)
-- ===========================================================================
do
    io.write("== 回归:strobe 与 OAM DMA 行为不变 ==\n")
    local t = Unit.new("regression strobe/OAMDMA")

    t:it("$4016 仍触发 controller:strobe(透传值)", function(a)
        local fc, mocks = newFC(FC)
        fc:memoryMapperWrite(0x4016, 0x01)
        a.equal(#mocks.ctrl.strobeCalls, 1, "应触发一次 strobe")
        a.equal(mocks.ctrl.strobeCalls[1], 0x01, "strobe 值应透传")
    end)

    t:it("$4014 仍触发 OAM DMA(真实 doOAMDMA:cyclesToHalt=513)", function(a)
        local fc, mocks = newFC(FC)
        a.equal(mocks.cpu.cyclesToHalt, 0, "前置:cyclesToHalt=0")
        fc:memoryMapperWrite(0x4014, 0x00)
        -- 真实 doOAMDMA 拷贝 256 字节并设置 cyclesToHalt=513
        a.equal(mocks.cpu.cyclesToHalt, 513, "OAM DMA 应设置 cyclesToHalt=513")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 4) memoryMapperLoad 读取路由(需求 1.1、5.2)
-- ===========================================================================
do
    io.write("== memoryMapperLoad 读取路由 ==\n")
    local t = Unit.new("load routing")

    t:it("$4015 读取返回 apu:readStatus()", function(a)
        local fc, mocks = newFC(FC)
        local v = fc:memoryMapperLoad(0x4015)
        a.equal(v, 0xAB, "应返回 apu:readStatus 的哨兵值 0xAB")
        a.equal(mocks.apu.readStatusCount, 1, "应调用 apu:readStatus 一次")
    end)

    t:it("$4016 读取返回 controller:read(1)", function(a)
        local fc, mocks = newFC(FC)
        local v = fc:memoryMapperLoad(0x4016)
        a.equal(v, 0x11, "应返回 controller:read(1)")
        a.equal(mocks.ctrl.readCalls[1], 1, "应以控制器号 1 调用 read")
    end)

    t:it("$4017 读取返回 controller:read(2)", function(a)
        local fc, mocks = newFC(FC)
        local v = fc:memoryMapperLoad(0x4017)
        a.equal(v, 0x22, "应返回 controller:read(2)")
        a.equal(mocks.ctrl.readCalls[1], 2, "应以控制器号 2 调用 read")
    end)

    t:it("其余只写 APU 寄存器($4000/$4013)读取返回 0,且不调用 apu:readStatus", function(a)
        local fc, mocks = newFC(FC)
        a.equal(fc:memoryMapperLoad(0x4000), 0, "$4000 读取应返回 0")
        a.equal(fc:memoryMapperLoad(0x4013), 0, "$4013 读取应返回 0")
        a.equal(mocks.apu.readStatusCount, 0, "只写寄存器读取不应调用 apu:readStatus")
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 5) 帧驱动:apu:tick() 每 NES 帧一次,与 present 次数无关(需求 5.3、5.4)
-- ===========================================================================
do
    io.write("== FC:frame 每 NES 帧驱动 apu:tick() 一次 ==\n")
    local t = Unit.new("frame drives apu:tick")

    -- 构造 FC,设置帧跳过,驱动 n 个 NES 帧,返回统计。
    local function runFrames(skip, n)
        local present = { count = 0 }
        local fc, mocks = newFC(FC, present)
        fc:setFrameSkip(skip)
        fc:start()
        local allCompleted = true
        for _ = 1, n do
            local done = fc:frame()
            if not done then allCompleted = false end
        end
        return {
            ticks = mocks.apu.tickCount,
            presents = present.count,
            renders = mocks.ppu.renderCount,
            allCompleted = allCompleted,
        }
    end

    t:it("skipN=1:4 个 NES 帧 → tick 4 次,present 4 次", function(a)
        local r = runFrames(1, 4)
        a.ok(r.allCompleted, "每次 frame() 都应完成一个 NES 帧")
        a.equal(r.ticks, 4, "apu:tick 应恰调用 4 次(每 NES 帧一次)")
        a.equal(r.presents, 4, "skipN=1 时 present 4 次")
        a.equal(r.renders, 4, "skipN=1 时 renderFrame 4 次")
    end)

    t:it("skipN=2:6 个 NES 帧 → tick 仍 6 次,present 仅 3 次(与 present 无关)", function(a)
        local r = runFrames(2, 6)
        a.ok(r.allCompleted, "每次 frame() 都应完成一个 NES 帧")
        a.equal(r.ticks, 6, "帧跳过下 apu:tick 仍按 NES 帧数 = 6")
        a.equal(r.presents, 3, "skipN=2 时 present 应为 3")
        a.equal(r.renders, 3, "skipN=2 时 renderFrame 应为 3")
    end)

    t:it("skipN=3:6 个 NES 帧 → tick 仍 6 次,present 仅 2 次(与 present 无关)", function(a)
        local r = runFrames(3, 6)
        a.ok(r.allCompleted, "每次 frame() 都应完成一个 NES 帧")
        a.equal(r.ticks, 6, "帧跳过下 apu:tick 仍按 NES 帧数 = 6")
        a.equal(r.presents, 2, "skipN=3 时 present 应为 2")
        a.equal(r.renders, 2, "skipN=3 时 renderFrame 应为 2")
    end)

    t:it("tick 次数与 present 次数解耦:同样 6 帧,skip=2 与 skip=3 的 tick 相同、present 不同", function(a)
        local r2 = runFrames(2, 6)
        local r3 = runFrames(3, 6)
        a.equal(r2.ticks, r3.ticks, "不同 skipN 下 tick 次数应相同(=NES 帧数)")
        a.ok(r2.presents ~= r3.presents, "不同 skipN 下 present 次数应不同")
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== FC-APU 集成测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
