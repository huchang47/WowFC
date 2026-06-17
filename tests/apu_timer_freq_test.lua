-- apu_timer_freq_test.lua
-- 单元测试:APU.timerToFrequency(timer, channelKind)(任务 3.2)
-- 验证 NES 方波/三角波 timer→频率换算公式,以及 timer 过小时返回 nil(不发声)。
--
-- 独立可运行入口(lua tests/apu_timer_freq_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit),再加载 APU 模块。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

dofile("Core/APU.lua")  -- 定义全局 _G.APU

local allOk = true

-- 浮点近似相等
local function approx(a, b)
    return math.abs(a - b) < 1e-6
end

do
    io.write("== APU.timerToFrequency ==\n")
    local t = Unit.new("timerToFrequency")

    t:it("pulse 按 f = CPU_CLOCK / (16 * (timer+1)) 换算", function(a)
        local timer = 1000
        local expected = APU.CPU_CLOCK / (16 * (timer + 1))
        a.ok(approx(APU.timerToFrequency(timer, "pulse"), expected),
            "pulse 频率应符合公式")
    end)

    t:it("triangle 按 f = CPU_CLOCK / (32 * (timer+1)) 换算", function(a)
        local timer = 1000
        local expected = APU.CPU_CLOCK / (32 * (timer + 1))
        a.ok(approx(APU.timerToFrequency(timer, "triangle"), expected),
            "triangle 频率应符合公式")
    end)

    t:it("triangle 频率为同 timer pulse 的一半", function(a)
        local timer = 500
        local p = APU.timerToFrequency(timer, "pulse")
        local tr = APU.timerToFrequency(timer, "triangle")
        a.ok(approx(p / 2, tr), "triangle 应为 pulse 的一半")
    end)

    t:it("未知/缺省 channelKind 按 pulse 处理", function(a)
        local timer = 500
        a.ok(approx(APU.timerToFrequency(timer, "pulse"),
                    APU.timerToFrequency(timer, "noise")),
            "未知类型应回退到 pulse 系数")
    end)

    t:it("timer 最大值(2047)频率在可听范围内", function(a)
        local f = APU.timerToFrequency(2047, "pulse")
        a.ok(f ~= nil, "timer=2047 应可发声")
        a.ok(f > 0 and f <= APU.AUDIBLE_MAX_HZ, "频率应落在可听范围")
    end)

    t:it("timer 过小(0)频率超可听上限返回 nil", function(a)
        a.is_nil(APU.timerToFrequency(0, "pulse"), "pulse timer=0 应不发声")
        a.is_nil(APU.timerToFrequency(0, "triangle"), "triangle timer=0 应不发声")
    end)

    t:it("C7(≈2093Hz)对应的正常 timer 不被误判为不发声", function(a)
        -- pulse: timer 使 f≈2093Hz → timer ≈ CPU_CLOCK/(16*2093) - 1 ≈ 52.4
        local f = APU.timerToFrequency(53, "pulse")
        a.ok(f ~= nil, "C7 附近频率应正常发声,不被阈值裁掉")
        a.ok(f <= APU.AUDIBLE_MAX_HZ, "应在可听上限内")
    end)

    t:it("可听上限阈值边界:刚好超过 20000Hz 的最小 timer 返回 nil", function(a)
        -- pulse: f > 20000 → timer+1 < CPU_CLOCK/(16*20000)=5.593 → timer <= 4
        a.is_nil(APU.timerToFrequency(4, "pulse"), "timer=4 频率>20kHz 应 nil")
        a.ok(APU.timerToFrequency(5, "pulse") ~= nil, "timer=5 频率<20kHz 应发声")
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== timerToFrequency 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
