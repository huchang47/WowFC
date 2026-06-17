-- apu_leak_unit_test.lua
-- 触发分支单元测试(apu-sound-leak 任务 4.1,对应 design.md Testing Strategy / Unit Tests)。
--
-- 覆盖修复(任务 3.1:APU:tick() 触发分支在覆盖 channel.handle 前先停止旧句柄)的
-- 具体场景与回归,用 mock SoundBackend 断言 play/stop 的调用序列(而非真实发声):
--   1. 通道已持有 handle 时再次 needTrigger(持续发声跨半音):覆盖前【恰对旧句柄
--      调用一次 stop,且在 play 之前】,channel.handle 更新为新句柄(Requirements 2.1, 2.3);
--   2. 边界 channel.handle == nil 时触发(首次发声):不调用 stop、直接 play
--      (首次发声不误停)(Requirements 2.3);
--   3. 降级 available == false 时触发:既不 play 也不 stop(维持降级语义)(Requirements 2.4);
--   4. 回归:
--      - 发声→静音分支仍只停止一次并清空 handle(Requirements 3.2);
--      - maxTriggersPerTick 上限不变(stop 不计入触发计数)(Requirements 3.3);
--      - setEnabled(false) 后任意 tick 零触发(Requirements 3.4)。
--
-- 与单元测试 apu_tick_test.lua 互补:此处聚焦"覆盖前停止旧句柄"这一修复路径与其边界。
-- 独立可运行入口(lua tests/apu_leak_unit_test.lua),不依赖 WoW。
-- Requirements: 2.1, 2.3, 2.4, 3.2, 3.3, 3.4

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")
local SoundMock = require("tests.support.sound_mock")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU 与 APU.SoundBackend

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
-- 直接设置派生字段(不经 writeRegister),聚焦 tick 的采样/触发逻辑。
local function setSounding(apu, name, freq)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = freq
end

-- 工具:在已安装的 mock 之上再包一层,记录 play/stop 的【统一有序事件日志】,
-- 用于精确断言"stop 恰在 play 之前"的跨操作时序(mock 自身分两张表无法表达顺序)。
-- 返回 events 列表;每项 { op = "play"|"stop", path=..., handle=... }。
local function installOrderedLog()
    local events = {}
    local mockPlay = _G.PlaySoundFile
    local mockStop = _G.StopSound
    _G.PlaySoundFile = function(path, channel)
        events[#events + 1] = { op = "play", path = path }
        return mockPlay(path, channel)
    end
    _G.StopSound = function(handle, fadeout)
        events[#events + 1] = { op = "stop", handle = handle }
        return mockStop(handle, fadeout)
    end
    return events
end

-- C4 ≈ 261.63Hz → MIDI 60;A4 = 440Hz → MIDI 69(均在音域内,可解析到路径)。
local FREQ_C4 = 261.6256
local FREQ_A4 = 440.0
local PATH_PULSE_60 = "Interface\\AddOns\\WowFC\\Sound\\pulse_060.wav"
local PATH_PULSE_69 = "Interface\\AddOns\\WowFC\\Sound\\pulse_069.wav"

-- ===========================================================================
-- 场景 1:通道已持有 handle 时再次 needTrigger —— 覆盖前恰对旧句柄停止一次(在 play 之前)
-- ===========================================================================
do
    io.write("== 已持有 handle 再触发:覆盖前停止旧句柄一次(play 之前) ==\n")
    local t = Unit.new("retrigger stops old handle before play")

    t:it("持续发声跨半音(60→69):play 前恰停旧句柄 5 一次,handle 更新为新句柄 6", function(a)
        withSavedGlobals(function()
            -- 句柄从 5 起自增:首触发得 5,重触发得 6,便于断言"停的是旧句柄 5"。
            local mock = SoundMock.new({ handleStart = 5 })
            mock:install()
            local events = installOrderedLog()
            local apu = APU:new(nil)
            a.ok(apu.available == true, "前置:应可用")

            -- 帧1:静音→发声(首触发)。此前 handle 为 nil,不应停止。
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "帧1 应触发一次 play")
            a.equal(#mock.stopCalls, 0, "帧1 无旧句柄,不应 stop")
            a.equal(apu.channels.pulse1.handle, 5, "帧1 应记录句柄 5")

            -- 帧2:持续发声跨半音(60→69),通道已持有句柄 5 → needTrigger 再次成立。
            apu.channels.pulse1.freq = FREQ_A4
            apu:tick()

            -- 覆盖前恰对【旧句柄 5】停止一次,再 play 得新句柄 6。
            a.equal(#mock.stopCalls, 1, "重触发应恰停止一次")
            a.equal(mock.stopCalls[1].handle, 5, "停止的应是被覆盖的旧句柄 5")
            a.equal(#mock.playCalls, 2, "重触发应再 play 一次")
            a.equal(mock.playCalls[2].path, PATH_PULSE_69, "新触发路径应为 pulse_069")
            a.equal(apu.channels.pulse1.handle, 6, "handle 应更新为新句柄 6")

            -- 统一事件日志验证时序:play(帧1) → stop(旧句柄 5) → play(帧2)。
            -- 即重触发时 stop 恰在 play 之前(events[2] 为 stop,events[3] 为 play)。
            a.equal(#events, 3, "应共有 3 次后端调用(play, stop, play)")
            a.equal(events[1].op, "play", "事件1 应为帧1 的 play")
            a.equal(events[1].path, PATH_PULSE_60, "事件1 路径应为 pulse_060")
            a.equal(events[2].op, "stop", "事件2 应为重触发前的 stop")
            a.equal(events[2].handle, 5, "事件2 停止的应是旧句柄 5")
            a.equal(events[3].op, "play", "事件3 应为帧2 的 play(在 stop 之后)")
            a.equal(events[3].path, PATH_PULSE_69, "事件3 路径应为 pulse_069")

            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 场景 2:边界 channel.handle == nil 时触发 —— 不调用 stop、直接 play(首次发声不误停)
-- ===========================================================================
do
    io.write("== 边界:handle==nil 首次发声不误停 ==\n")
    local t = Unit.new("first trigger does not stop")

    t:it("首次发声(handle 为 nil):不调用 stop,直接 play 一次并记录句柄", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 9 })
            mock:install()
            local apu = APU:new(nil)
            a.is_nil(apu.channels.pulse1.handle, "前置:初始 handle 为 nil")

            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()

            a.equal(#mock.stopCalls, 0, "首次发声不应 stop(无旧句柄)")
            a.equal(#mock.playCalls, 1, "首次发声应 play 一次")
            a.equal(apu.channels.pulse1.handle, 9, "应记录新句柄 9")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 场景 3:降级 available == false 时触发 —— 既不 play 也不 stop
-- ===========================================================================
do
    io.write("== 降级:available==false 触发既不 play 也不 stop ==\n")
    local t = Unit.new("degrade no play no stop")

    t:it("available=false 时静音→发声:不 play 不 stop(静默降级)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu.available = false           -- 强制降级
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 0, "降级时不应 play")
            a.equal(#mock.stopCalls, 0, "降级时不应 stop")
            mock:uninstall()
        end)
    end)

    t:it("available=false 且通道已持有 handle 再触发:仍不 play 不 stop,handle 不变", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 制造"持有旧句柄"的状态:先正常发声触发一次(此时 available=true)。
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            local oldHandle = apu.channels.pulse1.handle
            a.ok(oldHandle ~= nil, "前置:应持有 handle")

            -- 强制降级后跨半音重触发:覆盖前停止位于 `needTrigger and canPlay` 分支内,
            -- canPlay=false 时整个触发分支被跳过 → 既不 play 也不新增 stop。
            apu.available = false
            apu.channels.pulse1.freq = FREQ_A4
            apu:tick()
            a.equal(#mock.playCalls, 1, "降级后不应新增 play(仍为之前的 1 次)")
            a.equal(#mock.stopCalls, 0, "降级后不应 stop(维持降级语义)")
            a.equal(apu.channels.pulse1.handle, oldHandle, "降级时 handle 不应被改动")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

-- ===========================================================================
-- 场景 4:回归 —— 发声→静音停止一次 / 节流上限 / 总开关零触发
-- ===========================================================================
do
    io.write("== 回归:发声→静音分支仍只停止一次并清空 handle ==\n")
    local t = Unit.new("regression: mute stop once")

    t:it("发声→静音转换帧只停止一次并清空 handle,持续静音不重复 stop", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 3 })
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "首帧触发一次")
            a.equal(apu.channels.pulse1.handle, 3, "首帧记录句柄 3")

            -- 转为静音(模拟 $4015 清位)。
            apu.channels.pulse1.enabled = false
            apu.channels.pulse1.lengthNonZero = false
            apu:tick()
            a.equal(#mock.stopCalls, 1, "发声→静音应停止一次")
            a.equal(mock.stopCalls[1].handle, 3, "停止句柄应匹配 3")
            a.is_nil(apu.channels.pulse1.handle, "停止后 handle 应清空")

            apu:tick()   -- 持续静音
            a.equal(#mock.stopCalls, 1, "持续静音不应重复 stop")
            a.equal(#mock.playCalls, 1, "静音后不应再触发 play")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 回归:maxTriggersPerTick 上限不变(stop 不计入触发计数) ==\n")
    local t = Unit.new("regression: throttle cap unchanged")

    t:it("三通道同帧首触发,上限 2 时只 play 2 次(首触发无 stop)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu.throttle.maxTriggersPerTick = 2     -- 收紧上限便于断言
            setSounding(apu, "pulse1", FREQ_C4)
            setSounding(apu, "pulse2", FREQ_C4)
            setSounding(apu, "triangle", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 2, "本帧 play 次数应被 maxTriggersPerTick(2) 限制")
            a.equal(#mock.stopCalls, 0, "首触发无旧句柄,不应 stop")
            mock:uninstall()
        end)
    end)

    t:it("已持有句柄的通道重触发:stop 不计入触发预算,play 仍受上限约束", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 帧1:三通道首触发(上限默认 3),各得一个句柄。
            setSounding(apu, "pulse1", FREQ_C4)
            setSounding(apu, "pulse2", FREQ_C4)
            setSounding(apu, "triangle", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 3, "帧1 三通道各触发一次")

            -- 帧2:三通道同时跨半音重触发,但本帧上限收紧为 2。
            -- 预期:仅 2 个通道触发 → 2 次 play + 对应 2 次 stop(旧句柄回收);
            -- stop 不占用触发预算,故 play 仍恰为 2(上限),不会因 stop 而少于 2。
            apu.throttle.maxTriggersPerTick = 2
            apu.channels.pulse1.freq = FREQ_A4
            apu.channels.pulse2.freq = FREQ_A4
            apu.channels.triangle.freq = FREQ_A4
            mock:clear()
            apu:tick()
            a.equal(#mock.playCalls, 2, "帧2 play 次数仍受上限 2 约束(stop 不计入预算)")
            a.equal(#mock.stopCalls, 2, "被重触发的 2 个通道各回收一次旧句柄")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 回归:setEnabled(false) 后零触发 ==\n")
    local t = Unit.new("regression: disabled zero trigger")

    t:it("setEnabled(false) 后任意 tick 不 play 不 stop,frameCounter 冻结", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu:setEnabled(false)
            a.equal(apu:isEnabled(), false, "声音应被关闭")

            local frameBefore = apu.frameCounter
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            apu.channels.pulse1.freq = FREQ_A4
            apu:tick()
            a.equal(#mock.playCalls, 0, "关闭后任意 tick 不应 play")
            a.equal(#mock.stopCalls, 0, "关闭后任意 tick 不应 stop")
            a.equal(apu.frameCounter, frameBefore, "关闭后 tick 应短路,frameCounter 冻结")
            mock:uninstall()
        end)
    end)

    t:it("发声中 setEnabled(false):停止现有发声一次并清空 handle,之后零触发", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 11 })
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(apu.channels.pulse1.handle, 11, "前置:持有句柄 11")

            apu:setEnabled(false)   -- 启用→关闭:停止现有发声
            a.equal(#mock.stopCalls, 1, "关闭时应停止正在发声的句柄一次")
            a.equal(mock.stopCalls[1].handle, 11, "停止句柄应匹配 11")
            a.is_nil(apu.channels.pulse1.handle, "关闭后 handle 应清空")

            apu:tick()
            a.equal(#mock.playCalls, 1, "关闭后不应再 play")
            a.equal(#mock.stopCalls, 1, "关闭后不应再 stop")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== APU 句柄泄漏修复单元测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
