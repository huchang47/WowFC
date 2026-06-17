-- apu_enabled_test.lua
-- 单元测试:APU:setEnabled(on) 与 APU:isEnabled()(任务 7.1)
-- 验证:
--   - isEnabled 反映 self.enabled 状态(默认 true;setEnabled 真/假值切换)
--   - setEnabled(false):停止所有持有 handle 的发声通道(stop 句柄匹配)并清空 handle
--   - setEnabled(false) 后 tick 直接返回:不触发任何 play、不递增 frameCounter
--   - available=false 降级时 setEnabled(false) 不调用 stop(静默降级)
--   - 关闭再开启后能从静音状态重新触发(prevActiveTone 已归零)
--
-- 注:属性测试 P8(声音关闭后零触发)留给任务 7.2。
-- 独立可运行入口(lua tests/apu_enabled_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

require("tests.support.bit_stub")
local Unit = require("tests.support.unit")
local SoundMock = require("tests.support.sound_mock")

dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")

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

-- 工具:把某通道置为"使能 + length 非零 + 给定 freq"的发声状态。
local function setSounding(apu, name, freq)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = freq
end

local FREQ_C4 = 261.6256
local PATH_PULSE_60 = "Interface\\AddOns\\WowFC\\Sound\\pulse_060.wav"

do
    io.write("== isEnabled 反映开关状态 ==\n")
    local t = Unit.new("isEnabled state")

    t:it("默认启用;setEnabled(false)/true 切换状态", function(a)
        local apu = APU:new(nil)
        a.equal(apu:isEnabled(), true, "默认应启用")
        apu:setEnabled(false)
        a.equal(apu:isEnabled(), false, "关闭后应为 false")
        apu:setEnabled(true)
        a.equal(apu:isEnabled(), true, "开启后应为 true")
    end)

    t:it("真值/假值被规整为 boolean", function(a)
        local apu = APU:new(nil)
        apu:setEnabled(nil)
        a.equal(apu:isEnabled(), false, "nil 应规整为 false")
        apu:setEnabled(0)            -- Lua 中 0 为真值
        a.equal(apu:isEnabled(), true, "0(真值)应规整为 true")
        apu:setEnabled("on")
        a.equal(apu:isEnabled(), true, "字符串(真值)应规整为 true")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== setEnabled(false) 停止发声并清空 handle ==\n")
    local t = Unit.new("setEnabled stops sounding")

    t:it("关闭时停止持有 handle 的通道(句柄匹配)并清空 handle、归零快照", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 11 })
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "前置:发声触发一次")
            a.equal(apu.channels.pulse1.handle, 11, "前置:应记录句柄 11")
            a.equal(apu.channels.pulse1.prevActiveTone, 60, "前置:快照应为 60")

            apu:setEnabled(false)
            a.equal(#mock.stopCalls, 1, "关闭应停止一次")
            a.equal(mock.stopCalls[1].handle, 11, "停止句柄应匹配 11")
            a.is_nil(apu.channels.pulse1.handle, "关闭后 handle 应清空")
            a.is_nil(apu.channels.pulse1.prevActiveTone, "关闭后快照应归零")
            mock:uninstall()
        end)
    end)

    t:it("无 handle 的通道不调用 stop", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 未发声(无 handle),直接关闭
            apu:setEnabled(false)
            a.equal(#mock.stopCalls, 0, "无发声通道时不应调用 stop")
            mock:uninstall()
        end)
    end)

    t:it("available=false 降级时关闭不调用 stop", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.ok(apu.channels.pulse1.handle ~= nil, "前置:应持有 handle")

            apu.available = false        -- 强制降级
            apu:setEnabled(false)
            a.equal(#mock.stopCalls, 0, "降级时不应调用 stop(静默降级)")
            a.is_nil(apu.channels.pulse1.handle, "仍应清空 handle")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 关闭后 tick 直接返回 ==\n")
    local t = Unit.new("tick short-circuit when disabled")

    t:it("关闭后 tick 不触发 play 且不递增 frameCounter", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu:setEnabled(false)
            local frameBefore = apu.frameCounter

            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            apu:tick()
            a.equal(#mock.playCalls, 0, "关闭后不应触发任何 play")
            a.equal(apu.frameCounter, frameBefore, "关闭后 tick 不应递增 frameCounter")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 关闭再开启后能重新触发 ==\n")
    local t = Unit.new("re-enable retriggers")

    t:it("发声中关闭再开启:重开后从静音状态重新触发", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()                       -- 帧1:触发,lastTriggerFrame=1
            a.equal(#mock.playCalls, 1, "首次发声触发一次")

            -- 持续发声若干帧(同音高不重触发),推进 frameCounter,
            -- 模拟真实使用中"关闭前已发声一段时间"——使重开后帧间隔满足节流。
            apu:tick()                       -- 帧2(同音,不触发)
            apu:tick()                       -- 帧3(同音,不触发)
            a.equal(#mock.playCalls, 1, "同音延续不重复触发")

            apu:setEnabled(false)            -- 停止并归零快照(frameCounter 冻结于 3)
            apu:setEnabled(true)             -- 重新开启

            -- 通道仍处于发声状态(enabled/length/freq 未变);因快照已归零,
            -- 重开后第一帧应视为"静音→发声"重新触发(帧间隔 4-1=3 >= 2,节流通过)。
            apu:tick()
            a.equal(#mock.playCalls, 2, "重开后应重新触发一次")
            a.equal(mock.playCalls[2].path, PATH_PULSE_60, "重触发路径应为 pulse_060")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== APU 声音总开关测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
