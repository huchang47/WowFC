-- apu_property_p2_test.lua
-- 属性测试 P2(任务 4.2):写入 $4015 按位更新通道使能状态。
-- Feature: apu-sound, Property 2: For any 写入 $4015 的字节值(0–255),Pulse1 / Pulse2 / Triangle 通道的使能标志应分别等于该字节的 bit0 / bit1 / bit2。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代:生成器覆盖字节值 0–255(含边界 0 与 255)。
-- 每次新建 APU 实例,writeRegister(0x4015, byte),断言:
--   pulse1.enabled   == (bit0 置位)
--   pulse2.enabled   == (bit1 置位)
--   triangle.enabled == (bit2 置位)
-- 位判定用全局 bit 桩(band),与被测实现口径一致。
--
-- 独立可运行入口(lua tests/apu_property_p2_test.lua),不依赖 WoW。
-- Validates: Requirements 1.3

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit;位判定也用它),再加载 APU。
local bit_stub = require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local b = bit_stub.bit

-- 新建一个不依赖 FC 的 APU 实例(writeRegister 不触碰 nes)。
local function newApu()
    return APU:new(nil)
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 2: 写入 $4015 按位更新通道使能状态
property "P2: 写入 $4015 按 bit0/1/2 更新 pulse1/pulse2/triangle 使能状态" {
    generators = { int(0, 255) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(byte)
        local apu = newApu()
        apu:writeRegister(0x4015, byte)

        -- 期望:三通道使能分别等于字节的 bit0 / bit1 / bit2。
        local expectP1  = b.band(byte, 0x01) ~= 0
        local expectP2  = b.band(byte, 0x02) ~= 0
        local expectTri = b.band(byte, 0x04) ~= 0

        local ch = apu.channels
        return ch.pulse1.enabled == expectP1
            and ch.pulse2.enabled == expectP2
            and ch.triangle.enabled == expectTri
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 2 })

io.write("\n==== 属性测试 P2" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
