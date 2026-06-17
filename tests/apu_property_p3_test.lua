-- apu_property_p3_test.lua
-- 属性测试 P3(任务 4.4):读取 $4015 反映各通道激活状态。
-- Feature: apu-sound, Property 3: For any 三个发声通道的 length-counter 非零状态组合,读取 $4015 返回字节的 bit0 / bit1 / bit2 应分别等于 Pulse1 / Pulse2 / Triangle 的非零状态,且未支持通道(Noise/DMC)对应位恒为 0。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代。
-- 生成策略:用 int(0,7) 生成 0–7 的整数,其 bit0/bit1/bit2 分别设定
--   pulse1 / pulse2 / triangle 的 lengthNonZero,从而覆盖三通道的全部 8 种组合。
-- 直接设置各通道 channel.lengthNonZero 字段再调 readStatus(),以最忠实地验证
--   "readStatus 的 bit 反映各通道 lengthNonZero" 这一语义(不经由 $4015 使能位耦合)。
-- check 断言:
--   bit0(0x01) == pulse1.lengthNonZero
--   bit1(0x02) == pulse2.lengthNonZero
--   bit2(0x04) == triangle.lengthNonZero
--   bit3(0x08) == 0(Noise 未支持)
--   bit4(0x10) == 0(DMC 未支持)
--   更高位(>= 0x20) 恒 0
-- 位判定用全局 bit 桩(band),与被测实现口径一致。
--
-- 独立可运行入口(lua tests/apu_property_p3_test.lua),不依赖 WoW。
-- Validates: Requirements 1.4

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit;位判定也用它),再加载 APU。
local bit_stub = require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local b = bit_stub.bit

-- 新建一个不依赖 FC 的 APU 实例(readStatus 不触碰 nes)。
local function newApu()
    return APU:new(nil)
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 3: 读取 $4015 反映各通道激活状态
property "P3: 读取 $4015 的 bit0/1/2 反映 pulse1/pulse2/triangle 的 lengthNonZero,bit3/bit4 及高位恒 0" {
    generators = { int(0, 7) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(combo)
        -- 由 0–7 的整数解码出三通道 lengthNonZero 的一种组合(共 8 种)。
        local p1  = b.band(combo, 0x01) ~= 0
        local p2  = b.band(combo, 0x02) ~= 0
        local tri = b.band(combo, 0x04) ~= 0

        -- 直接设置各通道 lengthNonZero,验证 readStatus 的位映射语义。
        local apu = newApu()
        apu.channels.pulse1.lengthNonZero   = p1
        apu.channels.pulse2.lengthNonZero   = p2
        apu.channels.triangle.lengthNonZero = tri

        local status = apu:readStatus()

        -- bit0/1/2 分别等于三通道非零状态。
        local okBit0 = (b.band(status, 0x01) ~= 0) == p1
        local okBit1 = (b.band(status, 0x02) ~= 0) == p2
        local okBit2 = (b.band(status, 0x04) ~= 0) == tri
        -- bit3(Noise)/bit4(DMC) 未支持,恒 0。
        local okBit3 = b.band(status, 0x08) == 0
        local okBit4 = b.band(status, 0x10) == 0
        -- 更高位(>= 0x20)恒 0:等价于 status 不超过 0x07。
        local okHigh = b.band(status, 0xE0) == 0

        return okBit0 and okBit1 and okBit2 and okBit3 and okBit4 and okHigh
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 3 })

io.write("\n==== 属性测试 P3" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
