-- apu_leak_preservation_test.lua
-- 保持属性测试(apu-sound-leak 任务 2):非缺陷输入行为不变(基线)。
-- Feature: apu-sound-leak, Property 2: For any 不满足 Bug Condition(isBugCondition 返回 false)
--   的输入(后端不可用、发声→静音转换、首次发声无旧句柄、声音关闭、任意寄存器写入序列),
--   修复后的 APU:tick()(F')应产生与修复前(F)完全相同的可观察行为 —— 保持触发判定与 play
--   调用序列(路径/通道/次数/顺序)、节流上限、声音总开关、"发声→静音"停止与静默降级语义不变
--   (既有属性 P1–P9 不受影响)。
--
-- ============================================================================
-- !!! 观察优先(observation-first):本测试断言的"基线行为"已先在【未修复】的
--     Core/APU.lua 上实测观察确认(见任务 2 观察记录):
--       · 首次发声(无旧句柄): play=1, stop=0, path=Sound\pulse_060.wav, channel=SFX
--       · 发声→静音→再发声: play=2, stop=1, 静音帧清空 handle
--       · 同音持续 N 帧→静音: 仅首帧 play=1, 静音转换 stop=1, handle 清空
--       · 降级 available==false(缺 PlaySoundFile 或映射表为空): 既不 play 也不 stop
--       · 总开关 setEnabled(false): 关闭后任意 tick 零触发
--     故本测试在【未修复】代码上【预期 PASS】(确认这是需保持的基线)。修复(任务 3.1)
--     完成后,本【同一组】测试将仍 PASS(任务 3.3 Preservation Checking,确认无回归)。
-- ============================================================================
--
-- 非缺陷输入域的构造(保证 isBugCondition 恒为 false):
--   用"每通道状态机"驱动多帧序列 —— 通道在"静音 / 发声"间切换,且【同一段发声内音高恒定】、
--   两段发声之间必有静音帧。于是:
--     · 发声段内只有首帧触发(音色不变,后续帧 needTrigger 不成立),不会覆盖仍持有的旧句柄;
--     · 新发声段只从"静音态"开始(上一帧静音已 stop 并清空 handle),触发帧不持有旧句柄。
--   即任一触发帧都【不】满足"已持有未停止句柄又触发新声音",故全程非缺陷输入。
--   (跨半音"持续发声变调"才是缺陷条件,由任务 1 的 Property 1 覆盖,此处刻意排除。)
--
-- 用 lua-quickcheck 跑随机迭代(不自行实现框架);mock SoundBackend
-- (tests/support/sound_mock.lua)记录每次 play/stop 调用与句柄;LCG 在 check 内确定性
-- 展开变长多帧序列(与既有 P7/P8 同源策略),既可变长又可复现。
-- 注:按用户要求将每条属性的随机迭代次数由 100 调小至 25(FAST_ITERATIONS),以加快测试运行;
--     保持检查为确定性基线对照,25 次随机展开已能覆盖多帧状态机的多样路径。
--
-- 标签格式与库/迭代次数沿用 apu-sound 既有规范。
-- 独立可运行入口(lua tests/apu_leak_preservation_test.lua),不依赖 WoW。
-- Validates: Requirements 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6

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
-- 通道波形(用于断言 play 路径 = toneIndexToPath(tone, kind))。
local KIND = { pulse1 = "pulse", pulse2 = "pulse", triangle = "triangle" }

-- 由 MIDI 半音换算频率(Hz):f = a4 * 2^((m-69)/12)。音域内反算后可解析回该半音。
local function midiToFreq(m)
    return A4 * 2 ^ ((m - 69) / 12)
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

-- 音高窗口:音域内一段小窗口,恒能解析到非空音色路径(发声即触发 play)。
local PITCH_BASE = 60
local PITCH_WINDOW = 8           -- 取 [60, 67]
if PITCH_BASE < LOW then PITCH_BASE = LOW end
if PITCH_BASE + PITCH_WINDOW - 1 > HIGH then PITCH_WINDOW = HIGH - PITCH_BASE + 1 end

-- 把通道置为本帧状态(直接设派生字段,聚焦 tick 的采样/触发逻辑)。
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

-- 每通道状态机:维持"发声段内音高恒定、段间必有静音"的非缺陷输入不变量。
--   silent → 以约 50% 概率开始一段新发声(随机取窗口内音高);否则继续静音。
--   sounding → 以约 33% 概率转静音;否则继续发声且【保持同一音高】。
-- 返回本帧 (sounding, tone)。
local function stepChannel(st, rng)
    if not st.sounding then
        if rng(2) == 1 then
            st.sounding = true
            st.tone = PITCH_BASE + (rng(PITCH_WINDOW) - 1)
        end
    else
        if rng(3) == 1 then
            st.sounding = false
            st.tone = nil
        end
        -- 否则:保持发声且同音(tone 不变)→ 段内不再触发,不覆盖活动句柄。
    end
    return st.sounding, st.tone
end

lqc.setup()
lqc.reset()

-- 每条属性的随机迭代次数:按用户要求调小(由 100 降至 25)以加快测试运行速度。
-- lqc 中 property 的 numtests 字段优先于全局默认(见 lqc/property.lua),故逐属性显式指定即可生效。
-- 保持检查为确定性行为对照(基线行为不变),25 次随机展开已能覆盖多帧状态机的多样路径。
local FAST_ITERATIONS = 25

-- ---------------------------------------------------------------------------
-- Property 2(保持-a): play 序列保持(首次发声 / 静音后再发声;非缺陷触发)。
--   单通道隔离,逐帧断言 play 增量 == 期望(仅"静音→发声"触发一次),
--   且触发帧的 path == toneIndexToPath(tone, kind)、channel == "SFX"(P5/P1–P4 解析保持);
--   全程 #play - #stop <= 1(确认确为非缺陷输入,资源本就有界)。
--   Validates: Requirements 3.1, 3.6
-- ---------------------------------------------------------------------------
property "P2(保持): 非缺陷序列下 play 序列(次数/路径/通道/顺序)与基线一致, #play-#stop<=1" {
    -- 生成器:g1=帧数 N(10..40); g2=序列种子; g3=通道(1=pulse1,2=pulse2,3=triangle)。
    generators = { int(10, 40), int(1, 1000000), int(1, 3) },
    numtests = FAST_ITERATIONS,
    check = function(g1, g2, g3)
        local name = CHANNELS[g3]
        local kind = KIND[name]

        local mock = SoundMock.new()
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false   -- 前置:应可用(PlaySoundFile 已注入且映射表非空)
        end

        local rng = makeRng(g2)
        local st = { sounding = false, tone = nil }
        local prevEffTone = nil        -- 上一帧有效音色(发声为 tone,静音为 nil)
        local ok = true
        local maxOutstanding = 0

        for _ = 1, g1 do
            local sounding, tone = stepChannel(st, rng)
            local nowEff = sounding and tone or nil
            -- 期望:仅"有效音色由 != 变为新值"时触发(本构造下即"静音→发声"段首帧)。
            local expectTrigger = (nowEff ~= nil) and (nowEff ~= prevEffTone)

            applyFrame(apu, name, sounding, tone)
            local before = #mock.playCalls
            apu:tick()
            local delta = #mock.playCalls - before

            if expectTrigger then
                if delta ~= 1 then ok = false; break end
                local last = mock.playCalls[#mock.playCalls]
                if last.channel ~= "SFX" then ok = false; break end
                if last.path ~= APU.toneIndexToPath(nowEff, kind) then ok = false; break end
            else
                if delta ~= 0 then ok = false; break end
            end

            local outstanding = #mock.playCalls - #mock.stopCalls
            if outstanding > maxOutstanding then maxOutstanding = outstanding end
            prevEffTone = nowEff
        end

        -- 非缺陷输入下资源本就有界(任一时刻净持有句柄数 <= 1)。
        if maxOutstanding > 1 then ok = false end

        mock:uninstall()
        return ok
    end,
}

-- ---------------------------------------------------------------------------
-- Property 2(保持-b): 发声→静音停止保持(P6)。
--   纯"同音持续发声 → 静音"序列:仅首帧 play 一次;静音转换帧 stop 一次并清空 handle;
--   后续持续静音帧既不再 play 也不再 stop。
--   Validates: Requirements 3.2
-- ---------------------------------------------------------------------------
property "P2(保持): 发声→静音仅在转换帧停止一次并清空 handle, 后续静音帧不再 play/stop" {
    -- 生成器:g1=发声帧数(1..6); g2=音高(窗口内); g3=通道; g4=转静音方式(0清enabled/1清length);
    --         g5=持续静音额外帧数(1..5); g6=是否被静音(0正常handle/1 playReturnsNil)。
    generators = { int(1, 6), int(0, PITCH_WINDOW - 1), int(1, 3), int(0, 1), int(1, 5), int(0, 1) },
    numtests = FAST_ITERATIONS,
    check = function(g1, g2, g3, g4, g5, g6)
        local name = CHANNELS[g3]
        local midi = PITCH_BASE + g2

        local mock = SoundMock.new({ playReturnsNil = (g6 == 1) })
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false
        end

        -- 同音持续发声 g1 帧:仅首帧触发一次 play(后续同音不触发)。
        for _ = 1, g1 do
            applyFrame(apu, name, true, midi)
            apu:tick()
        end
        local playsAfterSound = #mock.playCalls
        local handleAfterSound = apu.channels[name].handle
        local ok = (playsAfterSound == 1)

        -- 转静音(清 enabled 或清 lengthNonZero):不新增 play;持有句柄则恰 stop 一次并清空。
        local ch = apu.channels[name]
        if g4 == 0 then ch.enabled = false else ch.lengthNonZero = false end
        apu:tick()
        if #mock.playCalls ~= playsAfterSound then ok = false end
        if handleAfterSound ~= nil then
            if #mock.stopCalls ~= 1 or mock.stopCalls[1].handle ~= handleAfterSound then ok = false end
            if apu.channels[name].handle ~= nil then ok = false end
        else
            if #mock.stopCalls ~= 0 then ok = false end
        end
        local stopsAfterSilence = #mock.stopCalls

        -- 持续静音额外帧:既不再 play 也不再 stop(只在转换帧停止一次)。
        for _ = 1, g5 do applyFrame(apu, name, false, midi); apu:tick() end
        if #mock.playCalls ~= playsAfterSound then ok = false end
        if #mock.stopCalls ~= stopsAfterSilence then ok = false end

        mock:uninstall()
        return ok
    end,
}

-- ---------------------------------------------------------------------------
-- Property 2(保持-c): 节流上限保持(P7)。
--   三通道各按"段内同音、段间静音"状态机驱动(非缺陷);断言单次 tick 真实 play 增量
--   恒 <= apu.throttle.maxTriggersPerTick;并交叉校验 lastTriggerFrame 变化通道数 == play 增量。
--   覆盖默认(=3)与收紧(1..3)配置。
--   Validates: Requirements 3.3
-- ---------------------------------------------------------------------------
property "P2(保持): 非缺陷序列下单次 tick 触发数 <= maxTriggersPerTick(默认与收紧配置)" {
    -- 生成器:g1=帧数 N(5..20); g2=序列种子; g3=节流配置(1默认3/0收紧); g4=收紧值(1..3)。
    generators = { int(5, 20), int(1, 1000000), int(0, 1), int(1, 3) },
    numtests = FAST_ITERATIONS,
    check = function(g1, g2, g3, g4)
        local mock = SoundMock.new()
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false
        end
        if g3 == 0 then
            apu.throttle.maxTriggersPerTick = g4
        end
        local maxPerTick = apu.throttle.maxTriggersPerTick

        local rng = makeRng(g2)
        local states = {}
        for _, name in ipairs(CHANNELS) do states[name] = { sounding = false, tone = nil } end

        local ok = true
        for _ = 1, g1 do
            for _, name in ipairs(CHANNELS) do
                local sounding, tone = stepChannel(states[name], rng)
                applyFrame(apu, name, sounding, tone)
            end

            local playsBefore = #mock.playCalls
            local beforeLTF = {}
            for _, name in ipairs(CHANNELS) do
                beforeLTF[name] = apu.channels[name].lastTriggerFrame
            end

            apu:tick()

            local delta = #mock.playCalls - playsBefore
            if delta > maxPerTick then ok = false; break end

            local triggered = 0
            for _, name in ipairs(CHANNELS) do
                if apu.channels[name].lastTriggerFrame ~= beforeLTF[name] then
                    triggered = triggered + 1
                end
            end
            if triggered ~= delta then ok = false; break end   -- 触发归因可靠
        end

        mock:uninstall()
        return ok
    end,
}

-- ---------------------------------------------------------------------------
-- Property 2(保持-d): 总开关保持(P8)。
--   setEnabled(false) 后任意多帧 tick 零触发;关闭那刻可有 stop 但不得有 play。
--   Validates: Requirements 3.4
-- ---------------------------------------------------------------------------
property "P2(保持): setEnabled(false) 后任意多帧 tick 零触发(关闭那刻可 stop 但不得 play)" {
    -- 生成器:g1=关闭前帧数(0..8); g2=关闭后帧数(1..12); g3=序列种子; g4=是否被静音(0/1)。
    generators = { int(0, 8), int(1, 12), int(1, 1000000), int(0, 1) },
    numtests = FAST_ITERATIONS,
    check = function(g1, g2, g3, g4)
        local mock = SoundMock.new({ playReturnsNil = (g4 == 1) })
        mock:install()
        local apu = APU:new(nil)
        if not apu.available then
            mock:uninstall()
            return false
        end

        local rng = makeRng(g3)
        local states = {}
        for _, name in ipairs(CHANNELS) do states[name] = { sounding = false, tone = nil } end
        local function driveFrame()
            for _, name in ipairs(CHANNELS) do
                local sounding, tone = stepChannel(states[name], rng)
                applyFrame(apu, name, sounding, tone)
            end
            apu:tick()
        end

        -- 启用态:先驱动 g1 帧(可能触发并令通道持有 handle)。
        for _ = 1, g1 do driveFrame() end
        local baseline = #mock.playCalls

        -- 关闭:可能对持有 handle 的通道 stop,但绝不应 play。
        apu:setEnabled(false)
        local ok = (apu:isEnabled() == false) and (#mock.playCalls == baseline)

        -- 静默态:任意多帧 tick 零触发(play 数恒等于 baseline)。
        for _ = 1, g2 do
            driveFrame()
            if #mock.playCalls ~= baseline then ok = false; break end
            if apu:isEnabled() ~= false then ok = false; break end
        end

        mock:uninstall()
        return ok
    end,
}

-- ---------------------------------------------------------------------------
-- Property 2(保持-e): 降级保持(available==false 既不 play 也不 stop)。
--   场景①:映射表为空(pulse/triangle 分组空) → available=false;此时即便 mock 已注入
--           (PlaySoundFile 存在),驱动发声+静音序列也【既不 play 也不 stop】。
--   场景②:完全缺失 PlaySoundFile → available=false;驱动序列绝不抛错,通道 handle 恒为 nil。
--   Validates: Requirements 2.4, 3.5
-- ---------------------------------------------------------------------------
property "P2(保持): 后端不可用(空映射表/缺 PlaySoundFile)时既不 play 也不 stop, 且不抛错" {
    -- 生成器:g1=帧数 N(3..15); g2=序列种子; g3=降级场景(0空映射表+mock计数;1缺PlaySoundFile)。
    generators = { int(3, 15), int(1, 1000000), int(0, 1) },
    numtests = FAST_ITERATIONS,
    check = function(g1, g2, g3)
        local rng = makeRng(g2)
        local states = {}
        for _, name in ipairs(CHANNELS) do states[name] = { sounding = false, tone = nil } end

        if g3 == 0 then
            -- 场景①:临时把映射表替换为"空分组"(保留 a4/range),触发空映射降级。
            local savedMap = _G.WOWFC_APU_TONEMAP
            _G.WOWFC_APU_TONEMAP = { a4 = A4, range = { low = LOW, high = HIGH }, pulse = {}, triangle = {} }
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            local ok = (apu.available == false)   -- 空映射表 → 降级
            local err = nil
            local pok, perr = pcall(function()
                for _ = 1, g1 do
                    for _, name in ipairs(CHANNELS) do
                        local sounding, tone = stepChannel(states[name], rng)
                        applyFrame(apu, name, sounding, tone)
                    end
                    apu:tick()
                end
            end)
            if not pok then ok = false; err = perr end
            -- 核心断言:降级时既不 play 也不 stop(mock 计数为 0)。
            if #mock.playCalls ~= 0 or #mock.stopCalls ~= 0 then ok = false end
            mock:uninstall()
            _G.WOWFC_APU_TONEMAP = savedMap
            if not ok and err then io.write("\n[2e-空映射 反例] seed=" .. g2 .. " err=" .. tostring(err) .. "\n") end
            return ok
        else
            -- 场景②:完全缺失 PlaySoundFile(不安装 mock)→ available=false;驱动序列绝不抛错。
            local savedP, savedS = rawget(_G, "PlaySoundFile"), rawget(_G, "StopSound")
            _G.PlaySoundFile = nil
            _G.StopSound = nil
            local apu = APU:new(nil)
            local ok = (apu.available == false)
            local pok, perr = pcall(function()
                for _ = 1, g1 do
                    for _, name in ipairs(CHANNELS) do
                        local sounding, tone = stepChannel(states[name], rng)
                        applyFrame(apu, name, sounding, tone)
                    end
                    apu:tick()
                end
            end)
            if not pok then ok = false end
            -- 降级时不持有任何句柄(从未成功 play)。
            for _, name in ipairs(CHANNELS) do
                if apu.channels[name].handle ~= nil then ok = false end
            end
            _G.PlaySoundFile = savedP
            _G.StopSound = savedS
            if not pok then io.write("\n[2e-缺后端 反例] seed=" .. g2 .. " err=" .. tostring(perr) .. "\n") end
            return ok
        end
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 2 })

io.write("\n==== 保持属性测试 Property 2(preservation)" ..
    (passed and "通过 ✅(非缺陷输入基线行为确认,需在修复后保持)" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
