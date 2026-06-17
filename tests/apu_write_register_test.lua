-- apu_write_register_test.lua
-- 单元测试:APU:writeRegister(address, value)(任务 4.1)
-- 验证寄存器写入记录到影子寄存器、周期寄存器更新 timer/频率、$4015 更新使能位,
-- 以及对未支持寄存器/越界地址的安全忽略(不报错)。
--
-- 独立可运行入口(lua tests/apu_write_register_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local allOk = true

-- 浮点近似相等
local function approx(a, b)
    return math.abs(a - b) < 1e-6
end

-- 新建一个不依赖 FC 的 APU 实例(writeRegister 不触碰 nes)。
local function newApu()
    return APU:new(nil)
end

do
    io.write("== APU:writeRegister 周期寄存器 → timer/频率 ==\n")
    local t = Unit.new("writeRegister period")

    t:it("Pulse1:$4002 低 8 位 + $4003 高 3 位拼出 11 位 timer", function(a)
        local apu = newApu()
        apu:writeRegister(0x4002, 0xCD)
        apu:writeRegister(0x4003, 0x05)  -- bit0-2 = 0b101
        a.equal(apu.channels.pulse1.timer, 0x5CD, "timer 应为 0x5CD")
        local expected = APU.timerToFrequency(0x5CD, "pulse")
        a.ok(approx(apu.channels.pulse1.freq, expected), "freq 应符合 pulse 公式")
    end)

    t:it("$4003 仅取高 3 位(bit3-7 被忽略)", function(a)
        local apu = newApu()
        apu:writeRegister(0x4002, 0x00)
        apu:writeRegister(0x4003, 0xFD)  -- 0b11111101 → 低 3 位 = 0b101 = 5
        a.equal(apu.channels.pulse1.timer, bit.lshift(5, 8), "高位仅取 bit0-2")
    end)

    t:it("Pulse2:$4006/$4007 更新 pulse2 timer", function(a)
        local apu = newApu()
        apu:writeRegister(0x4006, 0xFF)
        apu:writeRegister(0x4007, 0x07)
        a.equal(apu.channels.pulse2.timer, 0x7FF, "应为最大 11 位值 0x7FF")
    end)

    t:it("Triangle:$400A/$400B 更新 triangle timer 与频率(三角公式)", function(a)
        local apu = newApu()
        apu:writeRegister(0x400A, 0xE8)  -- 1000 低 8 位
        apu:writeRegister(0x400B, 0x03)  -- 高 3 位 = 0b11 → 1000 | (3<<8)
        local expectedTimer = bit.bor(0xE8, bit.lshift(3, 8))
        a.equal(apu.channels.triangle.timer, expectedTimer, "triangle timer")
        local expected = APU.timerToFrequency(expectedTimer, "triangle")
        a.ok(approx(apu.channels.triangle.freq, expected), "freq 应符合 triangle 公式")
    end)

    t:it("timer 过小导致频率超上限时 freq 为 nil(不发声)", function(a)
        local apu = newApu()
        apu:writeRegister(0x4002, 0x00)
        apu:writeRegister(0x4003, 0x00)  -- timer=0
        a.equal(apu.channels.pulse1.timer, 0, "timer 应为 0")
        a.is_nil(apu.channels.pulse1.freq, "timer=0 频率超上限,freq 应为 nil")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== APU:writeRegister $4015 → 使能位 ==\n")
    local t = Unit.new("writeRegister $4015")

    t:it("bit0/1/2 分别更新 pulse1/pulse2/triangle 使能", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x05)  -- 0b101 → pulse1 与 triangle 开,pulse2 关
        a.equal(apu.channels.pulse1.enabled, true, "bit0 → pulse1")
        a.equal(apu.channels.pulse2.enabled, false, "bit1=0 → pulse2 关")
        a.equal(apu.channels.triangle.enabled, true, "bit2 → triangle")
    end)

    t:it("全 1(0x07)三通道全开,lengthNonZero 同步置真", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x07)
        a.equal(apu.channels.pulse1.enabled, true)
        a.equal(apu.channels.pulse2.enabled, true)
        a.equal(apu.channels.triangle.enabled, true)
        a.equal(apu.channels.pulse1.lengthNonZero, true, "使能 → lengthNonZero")
        a.equal(apu.channels.triangle.lengthNonZero, true)
    end)

    t:it("清使能位(0x00)三通道关,lengthNonZero 清零", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x07)
        apu:writeRegister(0x4015, 0x00)
        a.equal(apu.channels.pulse1.enabled, false)
        a.equal(apu.channels.pulse2.enabled, false)
        a.equal(apu.channels.triangle.enabled, false)
        a.equal(apu.channels.pulse1.lengthNonZero, false, "禁用 → lengthNonZero=false")
    end)

    t:it("使能后写周期高位寄存器($4003)保持 lengthNonZero 为真", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x01)  -- pulse1 使能
        apu:writeRegister(0x4003, 0x02)  -- length load 近似
        a.equal(apu.channels.pulse1.lengthNonZero, true, "写 $4003 伴随 length load")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== APU:writeRegister 影子寄存器记录 ==\n")
    local t = Unit.new("writeRegister regs")

    t:it("$4000-$4017 范围内写入记录到 regs", function(a)
        local apu = newApu()
        apu:writeRegister(0x4000, 0x9F)
        apu:writeRegister(0x4010, 0x11)  -- DMC 未支持,但仍记录
        apu:writeRegister(0x4017, 0xC0)
        a.equal(apu.regs[0x4000], 0x9F, "$4000 应记录")
        a.equal(apu.regs[0x4010], 0x11, "$4010(DMC) 应记录但不解析")
        a.equal(apu.regs[0x4017], 0xC0, "$4017 应记录")
    end)

    t:it("未支持寄存器($4010-$4013)不影响通道状态", function(a)
        local apu = newApu()
        apu:writeRegister(0x4010, 0xFF)
        apu:writeRegister(0x4011, 0xFF)
        apu:writeRegister(0x4012, 0xFF)
        apu:writeRegister(0x4013, 0xFF)
        a.equal(apu.channels.pulse1.timer, 0, "DMC 写入不应改 pulse1 timer")
        a.equal(apu.channels.pulse1.enabled, false, "DMC 写入不应改使能")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== APU:writeRegister 安全性(越界/异常输入不报错) ==\n")
    local t = Unit.new("writeRegister safety")

    t:it("越界地址($3FFF/$4018/0)安全忽略,不记录、不报错", function(a)
        local apu = newApu()
        a.no_error(function()
            apu:writeRegister(0x3FFF, 0x10)
            apu:writeRegister(0x4018, 0x10)
            apu:writeRegister(0, 0x10)
            apu:writeRegister(0xFFFF, 0x10)
        end, "越界地址不应抛错")
        a.is_nil(apu.regs[0x3FFF], "越界地址不应进入 regs")
        a.is_nil(apu.regs[0x4018], "越界地址不应进入 regs")
    end)

    t:it("非数字地址安全忽略,不报错", function(a)
        local apu = newApu()
        a.no_error(function()
            apu:writeRegister(nil, 0x10)
            apu:writeRegister("4002", 0x10)
        end, "非数字地址不应抛错")
    end)

    t:it("异常 value(>255 / 负 / nil)经掩码不报错", function(a)
        local apu = newApu()
        a.no_error(function()
            apu:writeRegister(0x4015, 0x1FF)  -- 超 255
            apu:writeRegister(0x4002, -1)
            apu:writeRegister(0x4015, nil)
        end, "异常 value 不应抛错")
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== writeRegister 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
