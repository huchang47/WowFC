-- apu_tone_map_test.lua
-- 单元测试:APU.frequencyToToneIndex(freq) 与 APU.toneIndexToPath(toneIndex, channelKind)(任务 3.4)
-- 验证 12 平均律最近半音换算、音域裁剪、基准音 a4 来自映射表,以及按通道波形解析音色路径。
--
-- 独立可运行入口(lua tests/apu_tone_map_test.lua),不依赖 WoW。

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit)。
require("tests.support.bit_stub")
local Unit = require("tests.support.unit")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU

local allOk = true

do
    io.write("== APU.frequencyToToneIndex ==\n")
    local t = Unit.new("frequencyToToneIndex")

    t:it("A4=440Hz 映射到 MIDI 69", function(a)
        a.equal(APU.frequencyToToneIndex(440), 69, "440Hz 应为 MIDI 69")
    end)

    t:it("C4≈261.63Hz 映射到 MIDI 60", function(a)
        a.equal(APU.frequencyToToneIndex(261.6256), 60, "中央 C 应为 MIDI 60")
    end)

    t:it("接近半音中点偏下仍取最近半音", function(a)
        -- MIDI 69(440Hz)与 70(466.16Hz)之间,稍偏 69 一侧
        a.equal(APU.frequencyToToneIndex(445), 69, "应取最近的 69")
    end)

    t:it("低于音域下界裁剪到 range.low", function(a)
        -- 远低于最低音的频率应裁剪到映射表下界(数据驱动,不硬编码具体值)。
        local low = _G.WOWFC_APU_TONEMAP.range.low
        a.equal(APU.frequencyToToneIndex(5), low,
            "应裁剪到下界 " .. tostring(low))
    end)

    t:it("高于音域上界裁剪到 range.high", function(a)
        -- 数据驱动:取上界半音的频率再升高若干半音(明显超界),应被裁剪回 range.high。
        -- 由映射表 a4/high 反算上界频率,再乘 2(高一个八度)确保超出当前音域上界。
        local map = _G.WOWFC_APU_TONEMAP
        local high = map.range.high
        local a4 = map.a4 or 440
        local highFreq = a4 * 2 ^ ((high - 69) / 12)  -- 上界音高对应频率
        a.equal(APU.frequencyToToneIndex(highFreq * 2), high,
            "高出上界一个八度的频率应裁剪到上界 " .. tostring(high))
    end)

    t:it("非正频率返回 nil(不发声)", function(a)
        a.is_nil(APU.frequencyToToneIndex(0), "0Hz 应返回 nil")
        a.is_nil(APU.frequencyToToneIndex(-100), "负频率应返回 nil")
    end)

    t:it("nil 频率返回 nil(承接 timerToFrequency 不发声)", function(a)
        a.is_nil(APU.frequencyToToneIndex(nil), "nil 应返回 nil")
    end)

    t:it("基准音 a4 来自映射表(默认 440)", function(a)
        -- 用映射表自身的 a4 反推:a4 频率必映射到 MIDI 69
        local a4 = _G.WOWFC_APU_TONEMAP.a4
        a.equal(APU.frequencyToToneIndex(a4), 69, "映射表 a4 应映射到 69")
    end)

    allOk = t:finish() and allOk
end

do
    io.write("== APU.toneIndexToPath ==\n")
    local t = Unit.new("toneIndexToPath")

    t:it("pulse 通道按音高解析到 pulse 路径", function(a)
        a.equal(APU.toneIndexToPath(60, "pulse"),
            "Interface\\AddOns\\WowFC\\Sound\\pulse_060.wav",
            "pulse 60 应解析到 pulse_060")
    end)

    t:it("triangle 通道按音高解析到 triangle 路径", function(a)
        a.equal(APU.toneIndexToPath(60, "triangle"),
            "Interface\\AddOns\\WowFC\\Sound\\triangle_060.wav",
            "triangle 60 应解析到 triangle_060")
    end)

    t:it("频率→索引→路径 串联(440Hz pulse)", function(a)
        local idx = APU.frequencyToToneIndex(440)
        a.equal(APU.toneIndexToPath(idx, "pulse"),
            "Interface\\AddOns\\WowFC\\Sound\\pulse_069.wav",
            "440Hz pulse 应得 pulse_069")
    end)

    t:it("toneIndex 为 nil 返回 nil", function(a)
        a.is_nil(APU.toneIndexToPath(nil, "pulse"), "nil 索引应返回 nil")
    end)

    t:it("未知通道波形返回 nil", function(a)
        a.is_nil(APU.toneIndexToPath(60, "noise"), "noise 无音色应返回 nil")
    end)

    t:it("音域外的音高(表中无键)返回 nil", function(a)
        a.is_nil(APU.toneIndexToPath(10, "pulse"), "表中无 10 应返回 nil")
    end)

    allOk = t:finish() and allOk
end

-- 映射表缺失时安全降级(返回 nil,不报错):临时摘除全局表验证。
do
    io.write("== 映射表缺失降级 ==\n")
    local t = Unit.new("toneMap missing")

    t:it("映射表缺失时 frequencyToToneIndex/toneIndexToPath 返回 nil 且不报错", function(a)
        local saved = _G.WOWFC_APU_TONEMAP
        _G.WOWFC_APU_TONEMAP = nil
        a.no_error(function()
            a.is_nil(APU.frequencyToToneIndex(440), "缺表时应返回 nil")
            a.is_nil(APU.toneIndexToPath(69, "pulse"), "缺表时应返回 nil")
        end, "缺表时不应抛错")
        _G.WOWFC_APU_TONEMAP = saved
    end)

    allOk = t:finish() and allOk
end

io.write("\n==== frequencyToToneIndex / toneIndexToPath 测试" ..
    (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
