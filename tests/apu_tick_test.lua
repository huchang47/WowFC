-- apu_tick_test.lua
-- 单元测试:APU:tick() 状态采样与触发匹配播放(任务 6.1)
-- 验证:
--   - 静音→发声:触发恰一次 play,且路径与(通道波形 + 音高)匹配,并记录 handle
--   - 持续发声未跨半音:不重复触发
--   - 持续发声跨半音边界:重新触发,路径为新音高
--   - 发声→静音(清使能位):停止一次(句柄匹配)且清空 handle,持续静音不重复 stop,不再触发(任务 6.3)
--   - 无 handle / available=false 时发声→静音不调用 stop(降级)
--   - available=false(降级):照常解析(更新 toneIndex 快照)但不触发任何 play
--   - tick 递增 frameCounter
--   - tick 不抛错(后端不可用时)
--
-- 注:属性测试 P5(有效音色变化触发匹配播放)留给任务 6.2。
-- 独立可运行入口(lua tests/apu_tick_test.lua),不依赖 WoW。

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
-- 直接设置派生字段(不经 writeRegister),让测试聚焦 tick 的采样/触发逻辑。
local function setSounding(apu, name, freq)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = freq
end

-- C4 ≈ 261.63Hz → MIDI 60;A4 = 440Hz → MIDI 69(均在音域内,可解析到路径)。
local FREQ_C4 = 261.6256
local FREQ_A4 = 440.0
local PATH_PULSE_60 = "Interface\\AddOns\\WowFC\\Sound\\pulse_060.wav"
local PATH_PULSE_69 = "Interface\\AddOns\\WowFC\\Sound\\pulse_069.wav"
local PATH_TRI_60   = "Interface\\AddOns\\WowFC\\Sound\\triangle_060.wav"

do
    io.write("== 静音→发声触发一次且路径匹配 ==\n")
    local t = Unit.new("silence to sounding")

    t:it("pulse1 静音→发声:触发一次 play,路径匹配 pulse_060,记录 handle", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 5 })
            mock:install()
            local apu = APU:new(nil)
            a.ok(apu.available == true, "前置:应可用")

            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()

            a.equal(#mock.playCalls, 1, "应触发一次 play")
            a.equal(mock.playCalls[1].path, PATH_PULSE_60, "路径应匹配 pulse_060")
            a.equal(mock.playCalls[1].channel, "SFX", "应使用 SFX 声道")
            a.equal(apu.channels.pulse1.handle, 5, "应记录 mock 句柄 5")
            a.equal(apu.channels.pulse1.toneIndex, 60, "toneIndex 快照应为 60")
            mock:uninstall()
        end)
    end)

    t:it("triangle 通道解析到 triangle 音色路径", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "triangle", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "应触发一次 play")
            a.equal(mock.playCalls[1].path, PATH_TRI_60, "路径应匹配 triangle_060")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 持续发声不跨半音:不重复触发 ==\n")
    local t = Unit.new("sustained same tone")

    t:it("连续两帧同一音高:仅首帧触发一次", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            apu:tick()   -- 同音高,不应再触发
            a.equal(#mock.playCalls, 1, "持续同音高应只触发一次")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 持续发声跨半音:重新触发新音高 ==\n")
    local t = Unit.new("cross semitone retrigger")

    t:it("音高由 60 变为 69:第二帧立即重新触发 pulse_069(不同音符不受节流)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "首帧触发一次")

            -- 节流仅针对"相同音色"的短时间重复触发;不同音符(60→69)随时可触发,
            -- 保证旋律连贯(修复:相邻帧切换音符曾被帧间隔节流误丢导致音乐不连贯)。
            apu.channels.pulse1.freq = FREQ_A4   -- 跨半音(60→69)
            apu:tick()
            a.equal(#mock.playCalls, 2, "跨半音(不同音符)应在相邻帧立即重新触发")
            a.equal(mock.playCalls[2].path, PATH_PULSE_69, "新触发路径应为 pulse_069")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 发声→静音:停止一次且不再触发(任务 6.3) ==\n")
    local t = Unit.new("sounding to silence")

    t:it("清使能位后转为不发声,停止一次(句柄匹配)并清空 handle,后续 tick 不再触发/不再 stop", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 7 })
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "首帧触发一次")
            a.equal(apu.channels.pulse1.handle, 7, "首帧应记录句柄 7")

            -- 转为静音(模拟 $4015 清位):enabled/lengthNonZero 置 false
            apu.channels.pulse1.enabled = false
            apu.channels.pulse1.lengthNonZero = false
            apu:tick()   -- 发声→静音转换帧:应停止一次
            a.equal(#mock.stopCalls, 1, "发声→静音应停止一次")
            a.equal(mock.stopCalls[1].handle, 7, "停止句柄应匹配上次 play 句柄 7")
            a.is_nil(apu.channels.pulse1.handle, "停止后 handle 应清空")

            apu:tick()   -- 持续静音:不应重复 stop
            a.equal(#mock.playCalls, 1, "静音后不应再触发")
            a.equal(#mock.stopCalls, 1, "持续静音不应重复 stop")
            a.is_nil(apu.channels.pulse1.toneIndex, "不发声时 toneIndex 应为 nil")
            a.is_nil(apu.channels.pulse1.prevActiveTone, "不发声时快照应为 nil")
            mock:uninstall()
        end)
    end)

    t:it("无 handle(play 被静音返回 nil)时发声→静音不调用 stop", function(a)
        withSavedGlobals(function()
            -- play 返回 nil(被静音):发声帧不记录 handle
            local mock = SoundMock.new({ playReturnsNil = true })
            mock:install()
            local apu = APU:new(nil)
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "发声帧仍尝试 play 一次")
            a.is_nil(apu.channels.pulse1.handle, "被静音时 handle 为 nil")

            apu.channels.pulse1.enabled = false
            apu.channels.pulse1.lengthNonZero = false
            apu:tick()
            a.equal(#mock.stopCalls, 0, "无 handle 时不应调用 stop")
            mock:uninstall()
        end)
    end)

    t:it("available=false 降级时发声→静音不调用 stop", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 手动制造"持有 handle 且上一帧在发声"的状态,再强制降级
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.ok(apu.channels.pulse1.handle ~= nil, "前置:应持有 handle")

            apu.available = false           -- 强制降级
            apu.channels.pulse1.enabled = false
            apu.channels.pulse1.lengthNonZero = false
            apu:tick()
            a.equal(#mock.stopCalls, 0, "降级时不应调用 stop(静默降级)")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== available=false 降级:解析但不触发 ==\n")
    local t = Unit.new("unavailable degrade")

    t:it("available=false 时 tick 更新 toneIndex 快照但不触发任何 play", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu.available = false           -- 强制降级
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 0, "降级时不应触发 play")
            a.equal(apu.channels.pulse1.toneIndex, 60, "降级时仍应解析更新快照")
            a.equal(apu.channels.pulse1.prevActiveTone, 60, "降级时仍应更新跨帧快照")
            mock:uninstall()
        end)
    end)

    t:it("后端缺失(无 PlaySoundFile)时 tick 不抛错且不触发", function(a)
        _G.PlaySoundFile = nil
        local apu = APU:new(nil)            -- available 探测为 false
        setSounding(apu, "pulse1", FREQ_C4)
        a.no_error(function() apu:tick() end, "后端不可用时 tick 不应抛错")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== frameCounter 递增 ==\n")
    local t = Unit.new("frame counter")

    t:it("每次 tick 递增 frameCounter", function(a)
        local apu = APU:new(nil)
        a.equal(apu.frameCounter, 0, "初始为 0")
        apu:tick()
        a.equal(apu.frameCounter, 1, "一次 tick 后为 1")
        apu:tick()
        a.equal(apu.frameCounter, 2, "两次 tick 后为 2")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== 节流去抖(任务 6.5) ==\n")
    local t = Unit.new("trigger throttle")

    -- 复用 PATH_PULSE_60/69、FREQ_C4/A4。

    t:it("首帧触发不被误抑制(lastTriggerFrame 哨兵豁免)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 默认 minFramesBetweenTriggers=2;首帧 frameCounter=1 与初值 0 间隔仅 1,
            -- 但哨兵(lastTriggerFrame==0)应豁免首次触发。
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 1, "首帧应正常触发(不被节流误抑制)")
            mock:uninstall()
        end)
    end)

    t:it("相同音色相邻帧重复触发:不再受最小帧间隔限制(同音去抖已取消)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 同一音色反复"发声→静音→发声"(半音边界抖动场景):取消同音去抖后每次回到
            -- 发声都应立即重触发,不再被最小帧间隔抑制。
            setSounding(apu, "pulse1", FREQ_C4)
            apu:tick()                              -- 帧1:触发 60
            a.equal(#mock.playCalls, 1, "帧1 触发一次")

            apu.channels.pulse1.enabled = false
            apu.channels.pulse1.lengthNonZero = false
            apu:tick()                              -- 帧2:静音(prevActiveTone 归 nil)

            apu.channels.pulse1.enabled = true
            apu.channels.pulse1.lengthNonZero = true
            apu.channels.pulse1.freq = FREQ_C4
            apu:tick()                              -- 帧3:又回到同一音色 60,应立即重触发
            a.equal(#mock.playCalls, 2, "同音回到发声应立即重触发(无帧间隔限制)")
            mock:uninstall()
        end)
    end)

    t:it("不同音符在相邻帧切换不受节流(旋律连贯)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            -- 连续 4 帧每帧换一个不同音符,应每帧都触发(旋律不被丢音)。
            setSounding(apu, "pulse1", FREQ_C4)     -- 60
            apu:tick()
            apu.channels.pulse1.freq = FREQ_A4      -- 69
            apu:tick()
            apu.channels.pulse1.freq = FREQ_C4      -- 60
            apu:tick()
            apu.channels.pulse1.freq = FREQ_A4      -- 69
            apu:tick()
            a.equal(#mock.playCalls, 4, "连续不同音符应每帧都触发,不被节流丢音")
            mock:uninstall()
        end)
    end)

    t:it("单次 tick 触发次数不超过 maxTriggersPerTick", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            apu.throttle.maxTriggersPerTick = 2     -- 收紧上限便于断言(三通道同帧首触发)
            -- 三个通道在同一帧由静音→发声(均为首次触发,豁免帧间隔);
            -- 但本帧触发预算上限为 2,故只应触发 2 次。
            setSounding(apu, "pulse1", FREQ_C4)
            setSounding(apu, "pulse2", FREQ_C4)
            setSounding(apu, "triangle", FREQ_C4)
            apu:tick()
            a.equal(#mock.playCalls, 2, "本帧触发次数应被 maxTriggersPerTick(2) 限制")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== APU:tick 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
