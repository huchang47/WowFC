-- apu_property_p6_test.lua
-- 属性测试 P6(任务 6.4):通道静音或被禁用则停止且不再续播。
-- Feature: apu-sound, Property 6: For any 通道由"发声"变为"静音 / 未使能"的状态转换,tick() 不应再为该通道触发播放;若该通道持有播放句柄且平台支持停止,则应对其调用一次停止。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代(不自行实现框架)。
--
-- 生成器策略(对应 design.md 测试策略"随机生成跨帧的 enable/timer 变化,驱动多帧 tick"):
--   单通道隔离 —— 其它通道始终保持静音(APU:new 初始即静音),使 mock 的 play/stop
--   记录完全来自被测通道,断言清晰。随机化四个维度:
--     ① 通道选择        : pulse1(pulse 音色) / triangle(triangle 音色)
--     ② 初始发声音高    : 音域 [low, high] 内,经 midiToFreq 反算频率驱动发声
--     ③ 转入静音的方式  : 清 enabled(未使能) 或 清 lengthNonZero(length 为零)
--     ④ 是否获得句柄    : 正常(mock 返回非 nil handle) / 被静音(playReturnsNil,handle 为 nil)
--     ⑤ 持续静音的额外帧数(1..5):验证转静音后续帧不再触发、不再 stop
--
-- 驱动序列(三段):
--   帧1(发声)    : 通道由静音→发声,tick() 触发一次 play 并记录 handle;
--   帧2(转静音)  : 清 enabled 或 lengthNonZero 使通道转为不发声,tick() ——
--                    · 不应为该通道新增 play(发声→静音不触发);
--                    · 若发声帧获得了 handle,应恰调用一次 stop 且句柄匹配;
--                    · 若未获得 handle(被静音),不应调用 stop;
--   帧3..(持续静音): 再 tick 若干帧,既不再新增 play,也不再 stop(只在转换帧停止一次)。
--
-- 注:发声帧与静音帧相邻不受节流影响 —— 节流仅约束"触发 play"的帧间隔,而静音帧
--     本身不触发 play(走 stop 分支),故无需插入空转帧。
--
-- 独立可运行入口(lua tests/apu_property_p6_test.lua),不依赖 WoW。
-- Validates: Requirements 3.3

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

-- 把被测通道置为"发声"状态(直接设派生字段,聚焦 tick 的采样/触发逻辑)。
local function setSounding(apu, name, midi)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = midiToFreq(midi)
end

-- 把被测通道转为"静音/未使能":
--   way==0 → 清 enabled(模拟 $4015 清使能位,未使能)
--   way==1 → 清 lengthNonZero(模拟 length counter 归零)
-- 两种方式都使 sampleChannelTone 得 nil(不发声)。
local function setSilent(apu, name, way)
    local ch = apu.channels[name]
    if way == 0 then
        ch.enabled = false
    else
        ch.lengthNonZero = false
    end
end

-- 单次随机用例:返回是否通过(boolean)。封装以保证无论何路径都只 uninstall 一次。
local function runCase(apu, mock, name, midi, silenceWay, extraFrames)
    -- 前置:mock 已注入,APU 应探测为可用。
    if not apu.available then
        return false
    end

    -- 帧1:发声 → 应触发一次 play 并记录 handle(被静音时 handle 为 nil)。
    setSounding(apu, name, midi)
    apu:tick()
    local playsAfterSound = #mock.playCalls
    local handleAfterSound = apu.channels[name].handle
    if playsAfterSound ~= 1 then
        return false  -- 发声帧应恰触发一次(音域内必能解析到路径)
    end

    -- 帧2:转静音/未使能 → 不新增 play;按是否持有 handle 决定是否 stop 一次。
    setSilent(apu, name, silenceWay)
    apu:tick()

    -- 断言①:发声→静音的那次 tick 不为该通道新增 play。
    if #mock.playCalls ~= playsAfterSound then
        return false
    end

    -- 断言②:句柄存在则恰停止一次且句柄匹配;未获得句柄则不应 stop。
    if handleAfterSound ~= nil then
        if #mock.stopCalls ~= 1 then
            return false
        end
        if mock.stopCalls[1].handle ~= handleAfterSound then
            return false
        end
    else
        if #mock.stopCalls ~= 0 then
            return false
        end
    end
    local stopsAfterSilence = #mock.stopCalls

    -- 帧3..:持续静音若干帧 → 既不再新增 play,也不再 stop。
    for _ = 1, extraFrames do
        apu:tick()
    end
    if #mock.playCalls ~= playsAfterSound then
        return false
    end
    if #mock.stopCalls ~= stopsAfterSilence then
        return false
    end

    return true
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 6: 通道静音或被禁用则停止且不再续播
property "P6: 通道静音/未使能则停止一次且不再续播(转静音帧及后续帧不触发 play)" {
    -- 生成器:
    --   g1 = 初始发声音高(音域内)
    --   g2 = 通道选择(0=pulse1/pulse 音色,1=triangle/triangle 音色)
    --   g3 = 转入静音方式(0=清 enabled,1=清 lengthNonZero)
    --   g4 = 是否获得句柄(0=正常返回 handle,1=被静音 playReturnsNil→handle 为 nil)
    --   g5 = 持续静音的额外帧数(1..5)
    generators = { int(LOW, HIGH), int(0, 1), int(0, 1), int(0, 1), int(1, 5) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g1, g2, g3, g4, g5)
        local name = (g2 == 1) and "triangle" or "pulse1"

        -- 安装可注入 mock 使 available=true(APU:new 在安装后探测)。
        -- g4==1 时模拟"被静音"使 play 返回 nil(发声帧不获得 handle)。
        local mock = SoundMock.new({ playReturnsNil = (g4 == 1) })
        mock:install()
        local apu = APU:new(nil)

        local ok = runCase(apu, mock, name, g1, g3, g5)

        mock:uninstall()
        return ok
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 6 })

io.write("\n==== 属性测试 P6" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
