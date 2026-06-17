-- smoke_test.lua
-- 脚手架冒烟测试：验证测试基础设施本身可用，为后续 P1–P9 属性测试
-- 与单元测试提供可运行范例。
--
-- 覆盖：
--   1. bit 桩：补齐 band/bor/bxor/bnot/lshift/rshift 且结果正确；
--   2. PlaySoundFile / StopSound mock：记录调用与参数、支持降级场景；
--   3. lua-quickcheck 接入：一条范例属性可配置 ≥100 次迭代并通过；
--   4. 单元测试辅助：断言可用。
--
-- 这是一个独立可运行入口（lua tests/smoke_test.lua），不依赖 WoW。

-- 让 require("tests.support.xxx") 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

local bit_stub = require("tests.support.bit_stub")
local SoundMock = require("tests.support.sound_mock")
local Unit = require("tests.support.unit")
local lqc = require("tests.support.lqc_harness")

local allOk = true

-- ---------------------------------------------------------------------------
-- 1) bit 桩单元测试
-- ---------------------------------------------------------------------------
do
    io.write("== bit 桩（来源：" .. bit_stub.source .. "）==\n")
    local t = Unit.new("bit 桩")
    local b = bit_stub.bit

    t:it("band/bor/bxor 基本正确", function(a)
        a.equal(b.band(0x6, 0x3), 0x2)
        a.equal(b.bor(0x6, 0x3), 0x7)
        a.equal(b.bxor(0x6, 0x3), 0x5)
    end)

    t:it("lshift/rshift 基本正确", function(a)
        a.equal(b.lshift(1, 4), 16)
        a.equal(b.rshift(0x80, 3), 16)
    end)

    t:it("拼接 11 位 timer（低 8 位 + 高 3 位）", function(a)
        -- 模拟 APU 周期寄存器：timer = low | (high3 << 8)
        local low, high3 = 0xCD, 0x05
        local timer = b.bor(low, b.lshift(b.band(high3, 0x07), 8))
        a.equal(timer, 0x5CD)
    end)

    t:it("纯 Lua 实现与所选实现在随机样本上一致", function(a)
        local pure = bit_stub.pure
        local samples = { 0, 1, 255, 256, 0x5CD, 0x7FF, 0xFF00, 0xFFFF, 0x12345 }
        for _, x in ipairs(samples) do
            for _, y in ipairs(samples) do
                a.equal(b.band(x, y), pure.band(x, y), "band 不一致")
                a.equal(b.bor(x, y), pure.bor(x, y), "bor 不一致")
                a.equal(b.bxor(x, y), pure.bxor(x, y), "bxor 不一致")
            end
            a.equal(b.lshift(x, 3), pure.lshift(x, 3), "lshift 不一致")
            a.equal(b.rshift(x, 3), pure.rshift(x, 3), "rshift 不一致")
        end
    end)

    allOk = t:finish() and allOk
end

-- ---------------------------------------------------------------------------
-- 2) 声音 mock 单元测试
-- ---------------------------------------------------------------------------
do
    io.write("== 声音 mock ==\n")
    local t = Unit.new("声音 mock")

    t:it("记录 PlaySoundFile 调用与参数，返回句柄", function(a)
        local mock = SoundMock.new():install()
        local willPlay, handle = PlaySoundFile("Sound\\pulse_069.ogg", "SFX")
        a.equal(willPlay, true)
        a.ok(handle ~= nil, "应返回句柄")
        a.equal(#mock.playCalls, 1)
        a.equal(mock.playCalls[1].path, "Sound\\pulse_069.ogg")
        a.equal(mock.playCalls[1].channel, "SFX")
        StopSound(handle)
        a.equal(#mock.stopCalls, 1)
        a.equal(mock.stopCalls[1].handle, handle)
        mock:uninstall()
    end)

    t:it("降级：playReturnsNil 返回 nil 句柄", function(a)
        local mock = SoundMock.new({ playReturnsNil = true }):install()
        local willPlay, handle = PlaySoundFile("x", "SFX")
        a.is_nil(willPlay)
        a.is_nil(handle)
        mock:uninstall()
    end)

    t:it("降级：failPlay 抛错可被 pcall 捕获（用于 P9）", function(a)
        local mock = SoundMock.new({ failPlay = true }):install()
        a.errors(function() PlaySoundFile("x", "SFX") end)
        mock:uninstall()
    end)

    t:it("uninstall 还原全局，不污染环境", function(a)
        local before = _G.PlaySoundFile
        local mock = SoundMock.new():install()
        mock:uninstall()
        a.equal(_G.PlaySoundFile, before)
    end)

    allOk = t:finish() and allOk
end

-- ---------------------------------------------------------------------------
-- 3) lua-quickcheck 接入冒烟（范例属性，≥100 次迭代）
-- ---------------------------------------------------------------------------
do
    io.write("== lua-quickcheck 接入（范例属性，迭代 " ..
        lqc.DEFAULT_ITERATIONS .. " 次）==\n")
    lqc.setup()
    lqc.reset()

    -- 范例属性（仅验证脚手架；真正的 P1–P9 在各自实现任务中编写）。
    -- 标签格式与后续属性测试保持一致。
    -- Feature: apu-sound, Property 0: 脚手架自检 —— 任意 11 位 timer 的低 8 位拼接可逆
    property "scaffold: timer 低 8 位与高 3 位拼接后可还原" {
        generators = { int(0, 2047) },
        numtests = lqc.DEFAULT_ITERATIONS,
        check = function(timer)
            local b = bit_stub.bit
            local low = b.band(timer, 0xFF)
            local high3 = b.band(b.rshift(timer, 8), 0x07)
            local rebuilt = b.bor(low, b.lshift(high3, 8))
            return rebuilt == timer
        end,
    }

    local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 1 })
    io.write("lua-quickcheck 范例属性：" .. (passed and "通过" or "失败") .. "\n")
    allOk = passed and allOk
end

-- ---------------------------------------------------------------------------
-- 汇总与退出码
-- ---------------------------------------------------------------------------
io.write("\n==== 冒烟测试" .. (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
