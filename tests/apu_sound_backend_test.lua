-- apu_sound_backend_test.lua
-- 单元测试:SoundBackend 平台适配与 APU:new 降级探测(任务 5.1)
-- 验证:
--   - SoundBackend.isAvailable() 反映全局 PlaySoundFile 是否存在
--   - SoundBackend.play(path) 在 mock 下返回句柄;被静音(nil)/抛错/平台缺失时返回 nil(吞掉异常)
--   - SoundBackend.stop(handle) 对 nil/缺失 StopSound/抛错安全 no-op
--   - APU:new 缺少 PlaySoundFile 或映射表为空时 available=false(静默降级)
--
-- 独立可运行入口(lua tests/apu_sound_backend_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")
local SoundMock = require("tests.support.sound_mock")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU 与 APU.SoundBackend

local SoundBackend = APU.SoundBackend
local allOk = true

-- 工具:在一段作用域内确保全局被还原。
local function withSavedGlobals(fn)
    local savedPlay = rawget(_G, "PlaySoundFile")
    local savedStop = rawget(_G, "StopSound")
    local ok, err = pcall(fn)
    _G.PlaySoundFile = savedPlay
    _G.StopSound = savedStop
    if not ok then error(err) end
end

do
    io.write("== SoundBackend.isAvailable ==\n")
    local t = Unit.new("isAvailable")

    t:it("提供 PlaySoundFile 时返回 true", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            a.ok(SoundBackend.isAvailable() == true, "安装 mock 后应可用")
            mock:uninstall()
        end)
    end)

    t:it("缺少 PlaySoundFile 时返回 false", function(a)
        withSavedGlobals(function()
            _G.PlaySoundFile = nil
            a.ok(SoundBackend.isAvailable() == false, "缺失时应不可用")
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== SoundBackend.play ==\n")
    local t = Unit.new("play")

    t:it("成功时返回句柄,并以 \"SFX\" 声道调用 PlaySoundFile", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ handleStart = 7 })
            mock:install()
            local h = SoundBackend.play("Sound/pulse_069.wav")
            a.equal(h, 7, "应返回 mock 的句柄 7")
            a.equal(#mock.playCalls, 1, "应调用一次 PlaySoundFile")
            a.equal(mock.playCalls[1].path, "Sound/pulse_069.wav", "路径应透传")
            a.equal(mock.playCalls[1].channel, "SFX", "应使用 SFX 声道")
            mock:uninstall()
        end)
    end)

    t:it("被静音(willPlay==nil)时返回 nil,不视为错误", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ playReturnsNil = true })
            mock:install()
            a.is_nil(SoundBackend.play("x.wav"), "被静音应返回 nil")
            a.equal(#mock.playCalls, 1, "仍记录一次调用")
            mock:uninstall()
        end)
    end)

    t:it("PlaySoundFile 抛错时吞掉异常并返回 nil", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ failPlay = true })
            mock:install()
            a.no_error(function()
                a.is_nil(SoundBackend.play("x.wav"), "抛错应返回 nil")
            end, "play 不应向上冒泡异常")
            mock:uninstall()
        end)
    end)

    t:it("平台缺失 PlaySoundFile 时返回 nil(no-op)", function(a)
        withSavedGlobals(function()
            _G.PlaySoundFile = nil
            a.no_error(function()
                a.is_nil(SoundBackend.play("x.wav"), "缺失应返回 nil")
            end, "缺失时不应抛错")
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== SoundBackend.stop ==\n")
    local t = Unit.new("stop")

    t:it("有句柄且平台支持时调用 StopSound", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            SoundBackend.stop(42)
            a.equal(#mock.stopCalls, 1, "应调用一次 StopSound")
            a.equal(mock.stopCalls[1].handle, 42, "句柄应透传")
            mock:uninstall()
        end)
    end)

    t:it("nil 句柄安全 no-op(不调用 StopSound)", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            a.no_error(function() SoundBackend.stop(nil) end, "nil 不应抛错")
            a.equal(#mock.stopCalls, 0, "不应调用 StopSound")
            mock:uninstall()
        end)
    end)

    t:it("平台缺失 StopSound 时安全 no-op", function(a)
        withSavedGlobals(function()
            _G.StopSound = nil
            a.no_error(function() SoundBackend.stop(1) end, "缺失 StopSound 不应抛错")
        end)
    end)

    t:it("StopSound 抛错时吞掉异常", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new({ failStop = true })
            mock:install()
            a.no_error(function() SoundBackend.stop(1) end, "stop 不应向上冒泡异常")
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== APU:new 降级探测 (available) ==\n")
    local t = Unit.new("availability probe")

    t:it("有 PlaySoundFile + 非空映射表 → available=true", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local apu = APU:new(nil)
            a.ok(apu.available == true, "齐备时应可用")
            mock:uninstall()
        end)
    end)

    t:it("缺少 PlaySoundFile → available=false(静默降级)", function(a)
        withSavedGlobals(function()
            _G.PlaySoundFile = nil
            local apu = APU:new(nil)
            a.ok(apu.available == false, "缺 PlaySoundFile 应降级")
        end)
    end)

    t:it("映射表缺失 → available=false", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local saved = _G.WOWFC_APU_TONEMAP
            _G.WOWFC_APU_TONEMAP = nil
            local apu = APU:new(nil)
            a.ok(apu.available == false, "缺映射表应降级")
            _G.WOWFC_APU_TONEMAP = saved
            mock:uninstall()
        end)
    end)

    t:it("映射表 pulse/triangle 分组都为空 → available=false", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local saved = _G.WOWFC_APU_TONEMAP
            _G.WOWFC_APU_TONEMAP = { format = "wav", a4 = 440, range = { low = 36, high = 96 },
                                     pulse = {}, triangle = {} }
            local apu = APU:new(nil)
            a.ok(apu.available == false, "空分组应降级")
            _G.WOWFC_APU_TONEMAP = saved
            mock:uninstall()
        end)
    end)

    t:it("仅 pulse 分组非空也视为可用", function(a)
        withSavedGlobals(function()
            local mock = SoundMock.new()
            mock:install()
            local saved = _G.WOWFC_APU_TONEMAP
            _G.WOWFC_APU_TONEMAP = { format = "wav", a4 = 440, range = { low = 36, high = 96 },
                                     pulse = { [60] = "x.wav" }, triangle = {} }
            local apu = APU:new(nil)
            a.ok(apu.available == true, "pulse 非空即可用")
            _G.WOWFC_APU_TONEMAP = saved
            mock:uninstall()
        end)
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== SoundBackend / 降级探测 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
