-- apu_leak_bug_condition_test.lua
-- 缺陷条件探索测试(apu-sound-leak 任务 1):APU 声音句柄泄漏。
-- Feature: apu-sound-leak, Property 1: For any 满足 Bug Condition(某通道持续发声且频繁跨越半音边界、在已持有未停止句柄的帧又触发新声音)的多帧发声状态序列,APU:tick() 应在覆盖 channel.handle 前先停止旧句柄,使运行结束时每个通道 (#play - #stop) <= 1,且每个被新句柄覆盖丢弃的旧句柄都有配对的 StopSound 调用(expectedBehavior(trace) 为真,资源有界、无泄漏)。
--
-- ============================================================================
-- !!! 重要:本测试是"缺陷条件探索测试",编码的是【期望行为】(资源有界)。
--     在【未修复】的 Core/APU.lua 上运行时 *预期 FAIL* —— 失败即确认缺陷存在:
--     持续发声变调时 tick() 用新句柄覆盖旧句柄却从不 stop,#play - #stop 随帧数
--     线性增长 ≫ 1。修复(任务 3.1:覆盖前先 stop 旧句柄)完成后,本【同一】测试将
--     转为 PASS(任务 3.2 Fix Checking)。请勿为让它通过而修改测试或代码。
-- ============================================================================
--
-- 用 lua-quickcheck 跑随机迭代(不自行实现框架);mock SoundBackend
-- (tests/support/sound_mock.lua)记录每次 play/stop 调用与句柄。
-- 注:本探索测试为【确定性资源泄漏】,缺陷在极少数迭代内即稳定暴露,故按用户要求
--    将随机迭代次数调小(ITERATIONS=25,见下)以加快运行;不修改共享 harness 的
--    ≥100 默认(其它 apu-sound 属性测试仍按既有规范运行)。另保留一个确定性可复现
--    场景(reproDemo)以保证缺陷稳定暴露与量化。
--
-- 期望行为(来自 design.md 的 Correctness Properties / expectedBehavior(trace)):
--   (1) 资源有界:每个通道 (countPlay - countStop) <= 1;
--   (2) 无丢弃泄漏:每个被新句柄覆盖丢弃的旧句柄都有配对的 StopSound 调用。
--
-- 生成器/驱动策略(满足 design.md 的 isBugCondition):
--   单通道隔离 —— 随机选 pulse1 / pulse2 / triangle 之一,其余通道保持静音
--   (APU:new 初始即静音),使 mock 的 play/stop 记录完全来自被测通道,逐通道归因清晰。
--   每次迭代用生成的种子驱动一个自包含 LCG 展开 N 帧"持续发声 + 相邻帧 toneIndex 必不相同"
--   的序列(频繁跨半音 → needTrigger 近乎每帧成立),从而:某通道在已持有未停止句柄的帧
--   又触发新声音(isBugCondition 成立),旧句柄被覆盖。
--   音高取自音域内小窗口[PITCH_BASE, +PITCH_WINDOW],恒能解析到非空音色路径(发声即触发 play)。
--
-- 同时保留一个具体可复现场景(reproDemo):单通道连续 60 帧发声、toneIndex 在相邻半音
-- 间反复变化(60→61→60→61…),以保证复现稳定并量化泄漏。
--
-- 标签格式与库/迭代次数沿用 apu-sound 既有规范。
-- 独立可运行入口(lua tests/apu_leak_bug_condition_test.lua),不依赖 WoW。
-- Validates: Requirements 1.1, 1.2, 1.3, 1.4

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

-- 单通道隔离:每次迭代选其一,其余保持静音。
local CHANNEL_NAMES = { "pulse1", "pulse2", "triangle" }

-- 由 MIDI 半音换算频率(Hz):f = a4 * 2^((m-69)/12)。音域内反算后可解析回该半音。
local function midiToFreq(m)
    return A4 * 2 ^ ((m - 69) / 12)
end

-- 把被测通道置为"发声"状态(直接设派生字段,聚焦 tick 的采样/触发逻辑)。
local function setSounding(apu, name, midi)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = midiToFreq(midi)
end

-- 自包含 LCG(Park-Miller 最小标准):返回 rng(n) → 1..n 的闭包。
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

-- 音高窗口:音域内一段小窗口,频繁跨半音又恒能解析到非空音色路径。
local PITCH_BASE = 60
local PITCH_WINDOW = 8           -- 取 [60, 67]
if PITCH_BASE < LOW then PITCH_BASE = LOW end
if PITCH_BASE + PITCH_WINDOW - 1 > HIGH then PITCH_WINDOW = HIGH - PITCH_BASE + 1 end

-- 生成 N 帧 toneIndex 序列,保证【相邻帧必不相同】(持续发声且频繁跨半音 → 满足 isBugCondition)。
local function buildToneSeq(n, rng)
    local seq = {}
    local prev = nil
    for i = 1, n do
        local t = PITCH_BASE + (rng(PITCH_WINDOW) - 1)   -- [PITCH_BASE, PITCH_BASE+WINDOW-1]
        if t == prev then
            -- 与上一帧相同则推进一个半音(在窗口内回绕),确保相邻帧不同。
            t = PITCH_BASE + ((t - PITCH_BASE + 1) % PITCH_WINDOW)
        end
        seq[i] = t
        prev = t
    end
    return seq
end

-- 驱动单通道多帧 tick,记录 trace:
--   plays/stops      : 该通道(隔离下即全部) play/stop 调用次数;
--   overwritten      : 被新句柄"覆盖丢弃"的旧句柄列表(tick 前后 channel.handle 由非 nil 变为不同值);
--   stoppedHandles   : mock 实际 stop 过的句柄集合;
--   maxOutstanding   : 全程任一时刻 (#play - #stop) 的峰值(资源占用上界,便于量化)。
local function driveChannel(apu, mock, name, toneSeq)
    local overwritten = {}
    local prevHandle = nil
    local maxOutstanding = 0
    for i = 1, #toneSeq do
        setSounding(apu, name, toneSeq[i])
        apu:tick()
        local cur = apu.channels[name].handle
        -- 旧句柄被新句柄替换(覆盖):无论是否在 tick 内被 stop,都记为"被覆盖的旧句柄",
        -- 期望行为要求它必须有配对 stop(条件 2)。
        if prevHandle ~= nil and cur ~= prevHandle then
            overwritten[#overwritten + 1] = prevHandle
        end
        prevHandle = cur

        local outstanding = #mock.playCalls - #mock.stopCalls
        if outstanding > maxOutstanding then
            maxOutstanding = outstanding
        end
    end

    local stoppedHandles = {}
    for _, c in ipairs(mock.stopCalls) do
        stoppedHandles[c.handle] = true
    end

    return {
        plays = #mock.playCalls,
        stops = #mock.stopCalls,
        overwritten = overwritten,
        stoppedHandles = stoppedHandles,
        maxOutstanding = maxOutstanding,
    }
end

-- expectedBehavior(trace)(design.md):资源有界 + 无丢弃泄漏。
-- 返回 ok(boolean), reason(string|nil)。
local function evaluateExpectedBehavior(trace)
    -- (1) 资源有界:运行结束时 (#play - #stop) <= 1。
    if (trace.plays - trace.stops) > 1 then
        return false, string.format(
            "资源未有界: #play=%d, #stop=%d, #play-#stop=%d (>1)",
            trace.plays, trace.stops, trace.plays - trace.stops)
    end

    -- (2) 无丢弃泄漏:每个被覆盖丢弃的旧句柄都有配对 stop。
    local leaked = 0
    for _, h in ipairs(trace.overwritten) do
        if not trace.stoppedHandles[h] then
            leaked = leaked + 1
        end
    end
    if leaked > 0 then
        return false, string.format(
            "存在被覆盖却未 stop 的句柄: %d/%d 个被覆盖旧句柄无配对 StopSound",
            leaked, #trace.overwritten)
    end

    return true, nil
end

-- ---------------------------------------------------------------------------
-- 具体可复现场景(reproDemo):单通道连续 60 帧发声,toneIndex 60↔61 反复变化。
-- 在未修复代码上量化泄漏(预期 #play≈60、#stop=0、#play-#stop≈60)。
-- ---------------------------------------------------------------------------
local function reproDemo()
    local mock = SoundMock.new()
    mock:install()
    local apu = APU:new(nil)
    local available = apu.available
    local trace
    if available then
        local seq = {}
        for i = 1, 60 do
            seq[i] = (i % 2 == 1) and 60 or 61   -- 60→61→60→61…
        end
        trace = driveChannel(apu, mock, "pulse1", seq)
    end
    mock:uninstall()
    return available, trace
end

do
    local available, trace = reproDemo()
    io.write("---- [reproDemo] 单通道 60 帧变调(60↔61)泄漏量化 ----\n")
    if not available then
        io.write("  [跳过] SoundBackend 不可用(mock 未生效?)\n")
    else
        local ok, reason = evaluateExpectedBehavior(trace)
        io.write(string.format("  #play=%d  #stop=%d  #play-#stop=%d  峰值未停句柄=%d\n",
            trace.plays, trace.stops, trace.plays - trace.stops, trace.maxOutstanding))
        io.write(string.format("  被覆盖旧句柄=%d  其中无配对 stop=%d\n",
            #trace.overwritten,
            (function()
                local n = 0
                for _, h in ipairs(trace.overwritten) do
                    if not trace.stoppedHandles[h] then n = n + 1 end
                end
                return n
            end)()))
        if ok then
            io.write("  => expectedBehavior 通过(资源有界,可能已修复)\n")
        else
            io.write("  => expectedBehavior 失败(确认泄漏): " .. reason .. "\n")
        end
    end
    io.write("----------------------------------------------------\n")
end

lqc.setup()
lqc.reset()

-- 按用户要求调小随机迭代次数以加快运行:本缺陷为确定性资源泄漏,极少数迭代内即稳定暴露,
-- 25 次足以覆盖三通道 × 多种帧数/种子并复现泄漏(无需坚持 ≥100)。
local ITERATIONS = 25

-- Feature: apu-sound-leak, Property 1: 句柄资源有界、覆盖前配对停止
property "P1(leak): 满足 Bug Condition 的持续发声变调序列下,每通道 (#play-#stop)<=1 且每个被覆盖旧句柄都有配对 stop" {
    -- 生成器:
    --   g1 = 帧数 N(20..60),保证持续发声多帧、足以使泄漏远超 1;
    --   g2 = 多帧序列随机种子(驱动自包含 LCG 展开整条 toneIndex 序列);
    --   g3 = 通道选择(1=pulse1, 2=pulse2, 3=triangle)。
    generators = { int(20, 60), int(1, 1000000), int(1, 3) },
    numtests = ITERATIONS,
    numshrinks = ITERATIONS,
    check = function(g1, g2, g3)
        local name = CHANNEL_NAMES[g3]

        -- 安装可注入 mock 使 available=true(APU:new 在安装后探测)。
        local mock = SoundMock.new()
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false   -- 前置:应可用(PlaySoundFile 已注入且映射表非空)
        end

        local rng = makeRng(g2)
        local toneSeq = buildToneSeq(g1, rng)   -- 相邻帧必不同 → 满足 isBugCondition
        local trace = driveChannel(apu, mock, name, toneSeq)
        mock:uninstall()

        -- 期望行为:资源有界 + 无丢弃泄漏(未修复代码上将失败,确认缺陷)。
        local ok = evaluateExpectedBehavior(trace)
        return ok
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 1 })

io.write("\n==== 缺陷条件探索测试 Property 1(leak)" ..
    (passed and "通过 ✅(资源有界 → 缺陷已修复)" or "失败 ❌(确认泄漏存在,符合未修复代码预期)") .. " ====\n")
os.exit(passed and 0 or 1)
