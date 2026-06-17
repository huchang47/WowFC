-- apu_property_p7_test.lua
-- 属性测试 P7(任务 6.6):触发节流不变式。
-- Feature: apu-sound, Property 7: For any 驱动多帧 tick() 的寄存器写入序列,单次 tick() 触发的播放次数不超过 maxTriggersPerTick。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代(不自行实现框架)。
--
-- 节流语义(取消同音去抖后):
--   节流仅保留"单帧触发计数上限"(maxTriggersPerTick)这一道闸门,用于防止单帧内大量触发
--   造成卡顿/爆音。原"同一音色最小帧间隔去抖"已按用户要求取消 —— 同一音色可在相邻帧立即
--   重触发,故本属性不再校验帧间隔不变式(minFramesBetweenTriggers 字段保留但不再约束触发)。
--
-- 生成器策略(对应 design.md 测试策略"随机生成跨帧的 enable/timer 变化,驱动多帧 tick"):
--   每次迭代随机生成 N 帧(5..20),逐帧对三个通道(pulse1/pulse2/triangle)随机设置
--   "是否发声 + 目标音高",制造频繁的音色变化(高发声概率 + 小音高窗口)以充分压测节流。
--   lqc 仅暴露标量生成器(int/byte/...),不便直接生成变长序列;故由生成的种子驱动一个
--   自包含 LCG(Park-Miller 最小标准),在 check 内确定性地展开整个多帧序列。
--   该 LCG 仅用局部状态,不触碰 lqc 自身的全局 RNG,既可变长又可复现。
--   音高取自音域 [LOW, HIGH] 内的小窗口,保证恒能解析到非空音色路径(发声即触发 play)。
--
-- 观测方式(可靠归因):
--   · 不变式①(单次 tick 触发数 <= maxTriggersPerTick):
--       每帧记录 mock.playCalls 在 tick 前后的增量 delta —— 这是"真实 play 调用"数,
--       断言 delta <= apu.throttle.maxTriggersPerTick。
--   · 交叉校验(把 lastTriggerFrame 这一代理量绑定到真实 play 调用):
--       本帧 lastTriggerFrame 发生变化的通道数,应恰等于本帧 play 调用增量 delta。
--       这保证"每次 lastTriggerFrame 变化都对应一次真实 play 触发",使观测可靠。
--
-- 节流配置覆盖:
--   随机决定使用默认 maxTriggersPerTick(=3)或收紧值(1..3);断言一律读取 apu.throttle
--   的实际值,故默认与收紧配置均被覆盖且参数化正确。
--
-- 独立可运行入口(lua tests/apu_property_p7_test.lua),不依赖 WoW。
-- Validates: Requirements 3.4

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit),再接入 lqc 与 sound mock。
require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")
local SoundMock = require("tests.support.sound_mock")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU 与 APU.SoundBackend

local MAP = _G.WOWFC_APU_TONEMAP
local A4 = MAP.a4 or 440
local LOW, HIGH = MAP.range.low, MAP.range.high

-- 三通道固定遍历名(与 APU 内部 CHANNEL_ORDER 一致,便于逐通道归因)。
local CHANNELS = { "pulse1", "pulse2", "triangle" }

-- 由 MIDI 半音换算频率(Hz):f = a4 * 2^((m-69)/12)。音域内反算后可解析回该半音。
local function midiToFreq(m)
    return A4 * 2 ^ ((m - 69) / 12)
end

-- 自包含 LCG(Park-Miller 最小标准):返回一个 rng(n) → 1..n 的闭包。
-- 仅用局部 state,不触碰 lqc 全局 RNG;同一 seed 可复现整条多帧序列。
local function makeRng(seed)
    local state = seed % 2147483647
    if state <= 0 then
        state = state + 2147483646
    end
    return function(n)
        state = (state * 16807) % 2147483647
        return (state % n) + 1
    end
end

-- 按生成的状态把某通道置为本帧状态(直接设派生字段,聚焦 tick 的采样/触发逻辑):
--   发声 → enabled + lengthNonZero + freq=midiToFreq(midi)
--   静音 → 清 enabled/lengthNonZero(使 sampleChannelTone 得 nil)
local function applyFrame(apu, name, sounding, midi)
    local ch = apu.channels[name]
    if sounding then
        ch.enabled = true
        ch.lengthNonZero = true
        ch.freq = midiToFreq(midi)
    else
        ch.enabled = false
        ch.lengthNonZero = false
    end
end

-- 音高窗口:在音域内取一段小窗口(频繁变化以压测节流),恒能解析到非空路径。
local PITCH_BASE = 48           -- 起点(>= LOW)
local PITCH_WINDOW = 8          -- 取一段窗口,均在 [LOW, HIGH] 内
if PITCH_BASE < LOW then PITCH_BASE = LOW end
if PITCH_BASE + PITCH_WINDOW > HIGH then PITCH_WINDOW = HIGH - PITCH_BASE end

-- 单次随机用例:返回是否通过(boolean)。封装以保证无论何路径都只 uninstall 一次。
local function runCase(apu, mock, nFrames, rng)
    -- 前置:mock 已注入,APU 应探测为可用(否则不会有任何触发,无法验证节流)。
    if not apu.available then
        return false
    end

    local maxPerTick = apu.throttle.maxTriggersPerTick

    for _ = 1, nFrames do
        -- 逐通道随机设置本帧"发声 + 音高"(高发声概率 + 小音高窗口 → 频繁音色变化)。
        for _, name in ipairs(CHANNELS) do
            local sounding = (rng(4) <= 3)                 -- 约 75% 发声
            local midi = PITCH_BASE + rng(PITCH_WINDOW)    -- 音域内的小窗口
            applyFrame(apu, name, sounding, midi)
        end

        -- tick 前快照:真实 play 调用数 + 各通道 lastTriggerFrame。
        local playsBefore = #mock.playCalls
        local beforeLTF = {}
        for _, name in ipairs(CHANNELS) do
            beforeLTF[name] = apu.channels[name].lastTriggerFrame
        end

        apu:tick()

        -- 不变式①:单次 tick 真实 play 触发数不超过 maxTriggersPerTick。
        local delta = #mock.playCalls - playsBefore
        if delta > maxPerTick then
            return false
        end

        -- 逐通道归因:lastTriggerFrame 变化即本帧触发;统计触发通道数用于交叉校验。
        local triggeredChannels = 0
        for _, name in ipairs(CHANNELS) do
            if apu.channels[name].lastTriggerFrame ~= beforeLTF[name] then
                triggeredChannels = triggeredChannels + 1
            end
        end

        -- 交叉校验:lastTriggerFrame 变化的通道数应恰等于真实 play 增量,
        -- 保证"每次 lastTriggerFrame 变化都对应一次真实 play 触发"(观测可靠)。
        if triggeredChannels ~= delta then
            return false
        end
    end

    return true
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 7: 触发节流不变式
property "P7: 触发节流不变式(单次 tick 触发数 <= maxTriggersPerTick)" {
    -- 生成器:
    --   g1 = 帧数 N(5..20)
    --   g2 = 多帧序列随机种子(驱动自包含 LCG 展开整条序列)
    --   g3 = 节流配置选择(1=默认 maxTriggersPerTick=3;0=收紧为 g4)
    --   g4 = 收紧时的 maxTriggersPerTick(1..3)
    generators = { int(5, 20), int(1, 1000000), int(0, 1), int(1, 3) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g1, g2, g3, g4)
        -- 安装可注入 mock 使 available=true(APU:new 在安装后探测)。
        local mock = SoundMock.new()
        mock:install()
        local apu = APU:new(nil)

        -- 节流配置:g3==1 用默认;否则收紧 maxTriggersPerTick 为随机 g4。
        if g3 == 0 then
            apu.throttle.maxTriggersPerTick = g4
        end

        local rng = makeRng(g2)
        local ok = runCase(apu, mock, g1, rng)

        mock:uninstall()
        return ok
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 7 })

io.write("\n==== 属性测试 P7" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
