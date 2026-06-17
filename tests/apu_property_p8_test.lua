-- apu_property_p8_test.lua
-- 属性测试 P8(任务 7.2):声音关闭后零触发。
-- Feature: apu-sound, Property 8: For any 通道发声状态,当声音被关闭(setEnabled(false))后,任意次数的 tick() 都不应产生任何播放触发。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代(不自行实现框架)。
--
-- 生成器策略(对应 design.md 测试策略"随机生成跨帧的 enable/timer 变化,驱动多帧 tick"):
--   每次迭代随机生成"发声段(可选) → 关闭 → 静默段"三段时间线,逐帧对三个通道
--   (pulse1/pulse2/triangle)随机设置"是否发声 + 目标音高",充分覆盖各种发声状态。
--   lqc 仅暴露标量生成器,不便直接生成变长序列;故由生成的种子驱动一个自包含 LCG
--   (Park-Miller 最小标准),在 check 内确定性地展开整条多帧序列。该 LCG 仅用局部状态,
--   不触碰 lqc 自身的全局 RNG,既可变长又可复现(与 P7 同源策略)。
--   音高取自音域 [LOW, HIGH] 内的小窗口,保证恒能解析到非空音色路径
--   (发声即会触发 play —— 若未关闭的话),使"关闭后零触发"的断言有实际约束力。
--
-- 两类场景(由 preFrames 统一覆盖):
--   ① 直接关闭后驱动多帧(preFrames==0):setEnabled(false) → 多帧 tick(每帧随机改通道状态),
--      断言整段静默期 playCalls 增量恒为 0。
--   ② 先发声若干帧 → 关闭 → 再多帧(preFrames>0):先在启用态驱动若干帧(可能触发若干 play
--      并使部分通道持有 handle),记录关闭前 play 数;关闭那一刻可能有 stop,但
--      不应有 play;此后任意多帧 tick 都不应有任何新增 play。
--
-- 断言(以"关闭前的 playCalls 数"为基线 baseline):
--   · setEnabled(false) 调用本身不新增 play(可能 stop,但 play 数不变);
--   · 关闭后每一帧 tick 之后,#mock.playCalls 恒等于 baseline(零触发);
--   · 全程 apu:isEnabled() 为 false。
--   句柄场景(正常返回 handle / 被静音返回 nil)由 playReturnsNil 随机覆盖,
--   确保"关闭时是否需要 stop 持有的 handle"两条路径都被穿过,但都不得产生 play。
--
-- 独立可运行入口(lua tests/apu_property_p8_test.lua),不依赖 WoW。
-- Validates: Requirements 4.2

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

-- 三通道固定遍历名(与 APU 内部 CHANNEL_ORDER 一致)。
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

-- 音高窗口:在音域内取一段小窗口(频繁变化),恒能解析到非空路径(发声即会触发 play)。
local PITCH_BASE = 48           -- 起点(>= LOW=36)
local PITCH_WINDOW = 8          -- 取 49..56,均在 [LOW, HIGH] 内
if PITCH_BASE < LOW then PITCH_BASE = LOW end
if PITCH_BASE + PITCH_WINDOW > HIGH then PITCH_WINDOW = HIGH - PITCH_BASE end

-- 逐通道随机设置本帧"发声 + 音高"(高发声概率 + 小音高窗口 → 频繁音色变化)。
local function driveRandomFrame(apu, rng)
    for _, name in ipairs(CHANNELS) do
        local sounding = (rng(4) <= 3)                 -- 约 75% 发声
        local midi = PITCH_BASE + rng(PITCH_WINDOW)    -- 音域内的小窗口
        applyFrame(apu, name, sounding, midi)
    end
end

-- 单次随机用例:返回是否通过(boolean)。封装以保证逻辑清晰、断言集中。
local function runCase(apu, mock, preFrames, postFrames, rng)
    -- 前置:mock 已注入,APU 应探测为可用 —— 否则发声也不会触发 play,
    -- "关闭后零触发"将失去约束力(无法区分是关闭起效还是后端不可用)。
    if not apu.available then
        return false
    end

    -- ① 启用态:先驱动 preFrames 帧(可能触发若干 play、令部分通道持有 handle)。
    --    preFrames==0 时即"直接关闭后驱动多帧"场景。
    for _ = 1, preFrames do
        driveRandomFrame(apu, rng)
        apu:tick()
    end

    -- 记录关闭前的 play 基线。
    local baseline = #mock.playCalls

    -- ② 关闭声音:这一刻可能对持有 handle 的通道调 stop,但绝不应产生 play。
    apu:setEnabled(false)
    if apu:isEnabled() ~= false then
        return false                          -- 关闭后状态必须为 false
    end
    if #mock.playCalls ~= baseline then
        return false                          -- 关闭动作本身不得新增 play
    end

    -- ③ 静默态:驱动 postFrames 帧,每帧随机改通道状态(含频繁的"静音→发声/跨半音"
    --    —— 若未关闭这些都会触发 play)。断言整段静默期 play 数恒等于 baseline。
    for _ = 1, postFrames do
        driveRandomFrame(apu, rng)
        apu:tick()
        if #mock.playCalls ~= baseline then
            return false                      -- 关闭后任意帧 tick 都不得新增 play(零触发)
        end
        if apu:isEnabled() ~= false then
            return false
        end
    end

    return true
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 8: 声音关闭后零触发
property "P8: 声音关闭后任意多帧 tick 零触发(关闭那刻可有 stop 但不得有 play)" {
    -- 生成器:
    --   g1 = 关闭前的发声帧数 preFrames(0..8;0=直接关闭后驱动多帧)
    --   g2 = 关闭后的静默帧数 postFrames(1..12)
    --   g3 = 多帧序列随机种子(驱动自包含 LCG 展开整条序列)
    --   g4 = 是否被静音(0=play 正常返回 handle;1=playReturnsNil→关闭时无 handle 可 stop)
    generators = { int(0, 8), int(1, 12), int(1, 1000000), int(0, 1) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g1, g2, g3, g4)
        -- 安装可注入 mock 使 available=true(APU:new 在安装后探测)。
        -- g4==1 时模拟"被静音"使发声帧不获得 handle(关闭时走"无 handle"分支)。
        local mock = SoundMock.new({ playReturnsNil = (g4 == 1) })
        mock:install()
        local apu = APU:new(nil)

        local rng = makeRng(g3)
        local ok = runCase(apu, mock, g1, g2, rng)

        mock:uninstall()
        return ok
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 8 })

io.write("\n==== 属性测试 P8" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
