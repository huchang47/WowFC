-- apu_property_p1_test.lua
-- 属性测试 P1(任务 3.3):timer 按 NES 公式换算为频率。
-- Feature: apu-sound, Property 1: For any 11 位 timer 值(0–2047)与通道类型(pulse / triangle),将其低 8 位与高 3 位分别写入对应周期寄存器后,该通道解析出的频率应等于 CPU_CLOCK / (div * (timer + 1)),其中 pulse 的 div=16、triangle 的 div=32。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代:生成器覆盖 timer 0–2047(含边界 0 与 2047)
-- 与通道类型 pulse/triangle。直接对 APU.timerToFrequency 断言频率等于公式值
-- (浮点近似比较);对会因频率超可听上限而返回 nil 的极小 timer,断言
-- "返回 nil 当且仅当公式频率 > AUDIBLE_MAX_HZ"。
--
-- 独立可运行入口(lua tests/apu_property_p1_test.lua),不依赖 WoW。
-- Validates: Requirements 1.2

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit;拆/拼 11 位 timer 也用它),再加载 APU。
local bit_stub = require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local b = bit_stub.bit

-- 浮点近似相等:actual 与 expected 走完全相同的公式,差应为 0;
-- 仍留极小相对容差以防不同求值顺序带来的舍入差异。
local function approx(actual, expected)
    return math.abs(actual - expected) <= 1e-6 * math.max(1, math.abs(expected))
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 1: timer 按 NES 公式换算为频率
property "P1: timer 按 NES 公式(pulse div=16 / triangle div=32)换算为频率" {
    generators = { int(0, 2047), elements({ "pulse", "triangle" }) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(timer, kind)
        -- 模拟周期寄存器写入:把 11 位 timer 拆成低 8 位 + 高 3 位再拼回,
        -- 体现"低 8 位与高 3 位分别写入对应周期寄存器"的语义。
        local low = b.band(timer, 0xFF)
        local high3 = b.band(b.rshift(timer, 8), 0x07)
        local t = b.bor(low, b.lshift(high3, 8))

        -- 期望频率:pulse 分频 16、triangle 分频 32。
        local div = (kind == "triangle") and 32 or 16
        local expected = APU.CPU_CLOCK / (div * (t + 1))

        local actual = APU.timerToFrequency(t, kind)

        if expected > APU.AUDIBLE_MAX_HZ then
            -- 频率超可听上限:应返回 nil(不发声)。
            return actual == nil
        end
        -- 否则应返回与公式一致的频率。
        return actual ~= nil and approx(actual, expected)
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 1 })

io.write("\n==== 属性测试 P1" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
