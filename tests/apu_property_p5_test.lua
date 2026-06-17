-- apu_property_p5_test.lua
-- 属性测试 P5(任务 6.2):有效音色变化触发匹配的播放。
-- Feature: apu-sound, Property 5: For any 通道连续两帧的状态,当"有效音色"(通道发声且 toneIndex 非空)相对上一帧发生变化(由静音变为发声,或持续发声中跨越半音边界)时,tick() 应通过后端触发一次播放,且其文件路径与新的(通道波形 + 音高)相匹配。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代(不自行实现框架)。
--
-- 生成器策略(对应 design.md 测试策略"随机生成跨帧的 enable/timer 变化,驱动多帧 tick"):
--   单通道隔离测试 —— 其它通道始终保持静音,使 mock.playCalls 完全来自被测通道,断言清晰。
--   为每帧独立采样"是否发声"与"目标音高",并让第二帧音高在第一帧基础上做小幅半音偏移,
--   从而充分覆盖四类跨帧转换:
--     ① 静音→发声      (s1=否, s2=是)        → 应触发
--     ② 持续发声跨半音  (s1=s2=是, m1≠m2)     → 应触发
--     ③ 同音延续        (s1=s2=是, m1==m2)    → 不应触发
--     ④ 持续静音/发声→静音 (s2=否)            → 不应触发(停止逻辑属任务 6.3,此处只断言"不新增播放")
--   音高取自映射表音域 [low, high],经 midiToFreq 反算频率驱动 tick,使 frequencyToToneIndex
--   能解析回该半音并在映射表中找到非空路径。pulse 与 triangle 两类通道都覆盖。
--
-- 断言(以第二帧相对第一帧的"播放新增量" delta = tick 后 - tick 前 playCalls 数衡量):
--   · 当有效音色发生变化(tone2 非空且 tone2 ≠ tone1)时:delta == 1,
--     且新增的那次 play 的 path == toneIndexToPath(tone2, kind)、channel == "SFX";
--   · 当有效音色未变化(同音延续 或 第二帧静音)时:delta == 0。
--
-- 注:本测试聚焦"播放触发"语义(playCalls),不对 StopSound 调用做强断言,
--     以免与任务 6.3(停止增强)耦合。
--
-- 独立可运行入口(lua tests/apu_property_p5_test.lua),不依赖 WoW。
-- Validates: Requirements 3.1, 3.2

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

-- 由 MIDI 半音换算频率(Hz):f = a4 * 2^((m-69)/12)。
-- 反算后经 frequencyToToneIndex 标准四舍五入应精确回到整数 m(音域内)。
local function midiToFreq(m)
    return A4 * 2 ^ ((m - 69) / 12)
end

-- 裁剪到音域 [LOW, HIGH]。
local function clampMidi(m)
    if m < LOW then return LOW end
    if m > HIGH then return HIGH end
    return m
end

-- 计算某帧的"有效音色":发声时为该半音,静音时为 nil(与 tick 内口径一致)。
local function effectiveTone(sounding, midi)
    if sounding then return midi end
    return nil
end

-- 把被测通道置为本帧状态(直接设派生字段,聚焦 tick 的采样/触发逻辑):
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

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 5: 有效音色变化触发匹配的播放
property "P5: 有效音色变化触发匹配的播放(静音→发声 / 跨半音 重新触发,未变化不触发)" {
    -- 生成器:
    --   g1 = 第一帧目标半音(音域内)
    --   g2 = 第一帧是否发声(0/1)
    --   g3 = 第二帧相对第一帧的半音偏移(-3..3;0 表示同音,非 0 多为跨半音)
    --   g4 = 第二帧是否发声(0/1)
    --   g5 = 通道选择(0=pulse1/pulse 音色,1=triangle/triangle 音色)
    generators = { int(LOW, HIGH), int(0, 1), int(-3, 3), int(0, 1), int(0, 1) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g1, g2, g3, g4, g5)
        local m1 = g1
        local s1 = (g2 == 1)
        local m2 = clampMidi(g1 + g3)
        local s2 = (g4 == 1)
        local useTri = (g5 == 1)

        local name = useTri and "triangle" or "pulse1"
        local kind = useTri and "triangle" or "pulse"

        -- 安装可注入 mock 使 available=true(APU:new 在安装后探测)。
        local mock = SoundMock.new()
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false  -- 前置:应可用(PlaySoundFile 已注入且映射表非空)
        end

        -- 第一帧
        applyFrame(apu, name, s1, m1)
        apu:tick()
        local c1 = #mock.playCalls

        -- 第二帧
        applyFrame(apu, name, s2, m2)
        apu:tick()
        local c2 = #mock.playCalls
        mock:uninstall()

        -- 期望的有效音色与"是否应触发"。
        local tone1 = effectiveTone(s1, m1)
        local tone2 = effectiveTone(s2, m2)
        local shouldTrigger = (tone2 ~= nil) and (tone2 ~= tone1)

        local delta = c2 - c1
        if shouldTrigger then
            -- 有效音色变化:第二帧应恰新增一次匹配播放。
            if delta ~= 1 then
                return false
            end
            local last = mock.playCalls[c2]
            if last.channel ~= "SFX" then
                return false
            end
            local expectPath = APU.toneIndexToPath(tone2, kind)
            if last.path ~= expectPath then
                return false
            end
            return true
        else
            -- 同音延续 / 第二帧静音:不应新增播放。
            return delta == 0
        end
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 5 })

io.write("\n==== 属性测试 P5" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
