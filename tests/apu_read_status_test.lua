-- apu_read_status_test.lua
-- 单元测试:APU:readStatus()(任务 4.3)
-- 验证 $4015 读取字节按位反映各通道 lengthNonZero:
--   bit0=Pulse1、bit1=Pulse2、bit2=Triangle;bit3(Noise)/bit4(DMC) 恒 0。
--
-- 独立可运行入口(lua tests/apu_read_status_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local allOk = true

-- 新建一个不依赖 FC 的 APU 实例。
local function newApu()
    return APU:new(nil)
end

do
    io.write("== APU:readStatus 反映各通道 lengthNonZero ==\n")
    local t = Unit.new("readStatus")

    t:it("初始状态(三通道未激活)返回 0", function(a)
        local apu = newApu()
        a.equal(apu:readStatus(), 0, "无通道激活应返回 0")
    end)

    t:it("仅 Pulse1 激活 → bit0(0x01)", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x01)
        a.equal(apu:readStatus(), 0x01, "仅 bit0 置位")
    end)

    t:it("仅 Pulse2 激活 → bit1(0x02)", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x02)
        a.equal(apu:readStatus(), 0x02, "仅 bit1 置位")
    end)

    t:it("仅 Triangle 激活 → bit2(0x04)", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x04)
        a.equal(apu:readStatus(), 0x04, "仅 bit2 置位")
    end)

    t:it("三通道全激活 → 0x07(bit0-2),高位恒 0", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x07)
        a.equal(apu:readStatus(), 0x07, "bit0-2 全置位")
    end)

    t:it("写 $4015 高位(Noise/DMC 等)不影响 readStatus 的 bit3/bit4", function(a)
        local apu = newApu()
        -- bit3(Noise)/bit4(DMC) 在 $4015 被写入,但本版本不解析,readStatus 恒 0。
        apu:writeRegister(0x4015, 0x18)  -- 0b11000 → 仅 Noise/DMC 使能位
        a.equal(apu:readStatus(), 0x00, "Noise/DMC 不发声,状态字应为 0")
    end)

    t:it("混合:Pulse1 + Triangle 激活 → 0x05", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x05)  -- bit0 + bit2
        a.equal(apu:readStatus(), 0x05, "bit0 与 bit2 置位")
    end)

    t:it("禁用后状态清零", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x07)
        apu:writeRegister(0x4015, 0x00)
        a.equal(apu:readStatus(), 0x00, "禁用三通道后返回 0")
    end)

    t:it("返回值始终是 0-255 的整数字节", function(a)
        local apu = newApu()
        apu:writeRegister(0x4015, 0x07)
        local s = apu:readStatus()
        a.ok(type(s) == "number", "应为 number")
        a.ok(s >= 0 and s <= 255, "应在 0-255 范围")
        a.ok(s == math.floor(s), "应为整数")
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== readStatus 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
