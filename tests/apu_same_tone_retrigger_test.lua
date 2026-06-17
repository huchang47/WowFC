-- apu_same_tone_retrigger_test.lua
-- 单元测试:同一个音的连续(重新)发声不再被过滤(修复 apu-same-tone-retrigger)。
--
-- 缺陷:tick 的触发判定原为 needTrigger = (nowTone ~= nil) and (nowTone ~= prevTone),
--   只在"音高变化"时触发,导致游戏对同一音高的【重新敲击】(连续音符/重复音效)被吞掉 ——
--   第二次及以后的同音不发声。
-- 修复:写 length 高位寄存器($4003/$4007/$400B,通道使能)= 一次 note-on(重新发声)信号,
--   置 channel.noteOn=true;tick 即使 nowTone == prevTone 也触发一次,并在帧末消费清除该信号。
--   "持续按住的同音"(不写 length 高位)仍不会每帧重触发。
--
-- 通过真实写寄存器路径($4015 使能 + $4002/$4003 周期)驱动,而非直接设派生字段,
-- 以覆盖 writeRegister → tick 的完整 note-on 链路。用 mock SoundBackend 断言 play 序列。
--
-- 独立可运行入口(lua tests/apu_same_tone_retrigger_test.lua),不依赖 WoW。

package.path = package.path .. ";./?.lua"

require("tests.support.bit_stub")
local Unit = require("tests.support.unit")
local SoundMock = require("tests.support.sound_mock")

dofile("Utils/APUToneMap_Generated.lua")  -- 定义 _G.WOWFC_APU_TONEMAP
dofile("Core/APU.lua")                     -- 定义 _G.APU 与 APU.SoundBackend

local allOk = true

-- 工具:在确保全局还原的作用域内运行(避免 mock 污染其它测试)。
local function withSavedGlobals(fn)
    local savedPlay = rawget(_G, "PlaySoundFile")
    local savedStop = rawget(_G, "StopSound")
    local ok, err = pcall(fn)
    _G.PlaySoundFile = savedPlay
    _G.StopSound = savedStop
    if not ok then error(err) end
end

-- 通过写寄存器把 pulse1 设为"使能 + 给定 11 位 timer + length load"。
-- 写 $4015 使能位,$4002 低 8 位,$4003 高 3 位(同时触发 length load → noteOn)。
local function noteOnPulse1(apu, timer)
    local lo = timer % 256
    local hi = math.floor(timer / 256) % 8       -- 高 3 位
    apu:writeRegister(0x4015, 0x01)              -- 使能 pulse1
    apu:writeRegister(0x4002, lo)                -- 周期低 8 位
    apu:writeRegister(0x4003, hi)                -- 周期高 3 位 + length load(note-on)
end

-- 选一个落在可听音域、能稳定解析到非空音色路径的 timer。
-- timer 较小 → 频率较高;这里用一个中等值,确保 freq 在音域内。
local TIMER_A = 253     -- 任取一个使 pulse 频率落在音域内的周期值

-- ===========================================================================
-- 场景 1(核心):同一音高连续 note-on 应每次都触发一次 play(不被过滤)
-- ===========================================================================
do
    io.write("== 同音重新敲击:每次 note-on 都触发一次 play ==\n")
    local t = Unit.new("same-tone re-trigger via length reload")

    t:it("同一 timer 连续三帧各写一次 length 高位:应 play 三次(同音不被过滤)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            a.ok(apu.available == true, "前置:应可用")

            -- 帧1:首次 note-on。
            noteOnPulse1(apu, TIMER_A)
            apu:tick()
            a.equal(#mock.playCalls, 1, "帧1 应触发一次 play")
            local firstPath = mock.playCalls[1].path
            a.ok(firstPath ~= nil, "应解析到非空音色路径")

            -- 帧2:同一音高再次 note-on(重新敲击)。修复前会被过滤(nowTone==prevTone)。
            noteOnPulse1(apu, TIMER_A)
            apu:tick()
            a.equal(#mock.playCalls, 2, "帧2 同音重新敲击应再触发一次 play(不被过滤)")
            a.equal(mock.playCalls[2].path, firstPath, "同音重触发路径应一致")

            -- 帧3:再次同音 note-on。
            noteOnPulse1(apu, TIMER_A)
            apu:tick()
            a.equal(#mock.playCalls, 3, "帧3 同音重新敲击应再触发一次 play")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 场景 2(回归):持续按住的同音(不写 length 高位)仍不每帧重触发
-- ===========================================================================
do
    io.write("== 回归:持续按住同音(无新 note-on)不每帧重触发 ==\n")
    local t = Unit.new("sustained same tone not retriggered")

    t:it("一次 note-on 后连续多帧 tick(不再写寄存器):仅首帧触发一次", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)

            noteOnPulse1(apu, TIMER_A)   -- 单次 note-on
            apu:tick()
            apu:tick()                   -- 持续按住:不再写 length 高位
            apu:tick()
            a.equal(#mock.playCalls, 1, "持续同音仅首帧触发一次(noteOn 已被消费清除)")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 场景 3(节流):同帧多通道同音 note-on 仍受 maxTriggersPerTick 约束
-- ===========================================================================
do
    io.write("== 回归:同音 note-on 仍受 maxTriggersPerTick 节流 ==\n")
    local t = Unit.new("same-tone note-on respects throttle")

    t:it("三通道同帧 note-on,上限 2 时本帧只 play 2 次", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu.throttle.maxTriggersPerTick = 2

            local lo = TIMER_A % 256
            local hi = math.floor(TIMER_A / 256) % 8
            apu:writeRegister(0x4015, 0x07)   -- 同时使能 pulse1/pulse2/triangle
            -- 三通道各写一次 length 高位(note-on)。
            apu:writeRegister(0x4002, lo); apu:writeRegister(0x4003, hi)   -- pulse1
            apu:writeRegister(0x4006, lo); apu:writeRegister(0x4007, hi)   -- pulse2
            apu:writeRegister(0x400A, lo); apu:writeRegister(0x400B, hi)   -- triangle
            apu:tick()
            a.equal(#mock.playCalls, 2, "本帧 play 次数应被 maxTriggersPerTick(2) 限制")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== 同音重触发修复单元测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
