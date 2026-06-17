-- apu_property_p9_test.lua
-- 属性测试 P9(任务 7.3):任意输入且后端不可用时绝不报错。
-- Feature: apu-sound, Property 9: For any 寄存器地址(含未支持的 DMC / sweep / 越界区)与字节值的写入序列,且无论播放后端是否可用(缺失 PlaySoundFile、play 返回 nil 或抛错),writeRegister 与 tick() 都不应抛出错误,模拟器得以继续运行(安全忽略 + 静默降级)。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代(不自行实现框架)。
--
-- 属性来源(design.md Correctness Properties P9;Error Handling 表;需求 1.5/4.3):
--   · 需求 1.5:未支持寄存器(DMC $4010-$4013、sweep 等)与越界地址 SHALL 安全忽略而不报错;
--   · 需求 4.3:缺少 PlaySoundFile 或音色加载失败 SHALL 自动静默降级,不抛错、不中断模拟。
--   降级原则:音频是"锦上添花",任何音频侧失败都不得影响画面与输入。
--
-- 生成器策略(对应 design.md 测试策略"地址覆盖全区+越界、字节 0-255、随机跨帧 enable/timer
-- 变化驱动多帧 tick;P9 额外注入'抛错 / 返回 nil / 不可用'后端"):
--   lqc 仅暴露标量生成器,不便直接生成变长序列;故由生成的种子驱动一个自包含 LCG
--   (Park-Miller 最小标准),在 check 内确定性地展开整条"写入 + tick"操作序列。
--   该 LCG 仅用局部状态,不触碰 lqc 全局 RNG,既可变长又可复现。
--   随机化维度:
--     ① 操作序列(写入随机地址+随机值 / tick / 随机开关 $4015),前后两段共 N 次操作;
--     ② 地址池:$4000-$4017 全区 + 未支持(DMC/sweep/frame counter)+ 越界(0x0000/0x3FFF/
--        0x4018/0xFFFF/-1)+ 非数字(字符串/布尔/表/nil);
--     ③ 字节池:0-255 + 异常值(负数、>255、字符串、nil);
--     ④ 后端场景:正常 mock / playReturnsNil(被静音)/ failPlay(play 抛错)/
--        failStop(stop 抛错)/ 完全缺失 PlaySoundFile(不安装 mock)。
--
-- 确保真正走到 play/stop 路径(可靠归因):
--   除随机操作外,每个用例都确定性注入一段"强制发声→静音"序列(forceSoundAndSilence):
--   写入有效周期寄存器使三通道频率落在音域内 + $4015=0x07 使能(发声)→ tick 触发 play;
--   再 $4015=0x00 关闭(静音)→ tick 触发 stop。这样:
--     · failPlay 场景下 play 抛错被 SoundBackend.play 的 pcall 吞掉(返回 nil,不冒泡);
--     · failStop 场景下先成功取得 handle,再在静音帧触发 stop,stop 抛错被 pcall 吞掉;
--   从而真正验证"后端抛错也不向上冒泡到帧循环"。
--
-- 断言:整条流程(边界写入 + 随机驱动 + 强制发声/静音 + readStatus)用 pcall 包裹,
--   断言 pcall 返回 true(绝不抛错)。任一场景下抛错即判定属性失败。
--
-- 独立可运行入口(lua tests/apu_property_p9_test.lua),不依赖 WoW。
-- Validates: Requirements 1.5, 4.3

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit),再接入 lqc 与 sound mock。
require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")
local SoundMock = require("tests.support.sound_mock")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU 与 APU.SoundBackend

-- ---------------------------------------------------------------------------
-- 自包含 LCG(Park-Miller 最小标准):返回 rng(n) → 1..n 的闭包。
-- 仅用局部 state,不触碰 lqc 全局 RNG;同一 seed 可复现整条操作序列。
-- ---------------------------------------------------------------------------
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

-- 随机挑选一个写入地址(覆盖全区 + 未支持 + 越界 + 非数字)。
local UNSUPPORTED_ADDRS = { 0x4001, 0x4005, 0x4009, 0x4010, 0x4011, 0x4012, 0x4013, 0x4017 }
local OUT_OF_RANGE_ADDRS = { 0x0000, 0x3FFF, 0x4018, 0x4020, 0xFFFF, -1 }
local function pickAddress(rng)
    local cat = rng(10)
    if cat <= 4 then
        -- $4000-$4017 全区随机(24 个地址)
        return 0x4000 + (rng(24) - 1)
    elseif cat == 5 then
        return UNSUPPORTED_ADDRS[rng(#UNSUPPORTED_ADDRS)]
    elseif cat == 6 then
        return OUT_OF_RANGE_ADDRS[rng(#OUT_OF_RANGE_ADDRS)]
    elseif cat == 7 then
        return "0x4002"          -- 非数字:字符串
    elseif cat == 8 then
        return true              -- 非数字:布尔
    elseif cat == 9 then
        return {}                -- 非数字:表
    else
        return nil               -- 非数字:nil 地址
    end
end

-- 随机挑选一个写入字节值(0-255 + 异常值)。
local function pickValue(rng)
    local cat = rng(10)
    if cat <= 5 then
        return rng(256) - 1      -- 0..255
    elseif cat == 6 then
        return -5                -- 负数
    elseif cat == 7 then
        return 256               -- 越界(>255)
    elseif cat == 8 then
        return 99999             -- 大值
    elseif cat == 9 then
        return "ff"              -- 非数字:字符串
    else
        return nil               -- nil 值
    end
end

-- 确定性边界写入:对每个特殊地址写入若干异常值,确保不依赖 RNG 也能覆盖
-- "未支持 / 越界 / 非数字地址 + 异常值"组合(需求 1.5 安全忽略)。
local function edgeWrites(apu)
    local addrs = {
        0x0000, 0x3FFF, 0x4018, 0x4020, 0xFFFF, -1,        -- 越界
        0x4010, 0x4011, 0x4012, 0x4013,                    -- DMC(未支持)
        0x4001, 0x4005, 0x4009, 0x4017,                    -- sweep / frame counter(未支持)
        "bad", true, {},                                   -- 非数字地址
    }
    for _, a in ipairs(addrs) do
        apu:writeRegister(a, 200)
        apu:writeRegister(a, -1)
        apu:writeRegister(a, nil)
        apu:writeRegister(a, "x")
    end
    apu:writeRegister(nil, 5)      -- nil 地址(ipairs 无法含 nil,单独覆盖)
end

-- 确定性"强制发声→静音"序列:真正走到 play / stop 路径。
--   周期寄存器 timer=427(低 8 位 0xAB,高 3 位 0x01):
--     pulse    f = 1789773/(16*428) ≈ 261.4Hz → MIDI 60(音域 [36,96] 内,pulse[60] 有路径);
--     triangle f = 1789773/(32*428) ≈ 130.7Hz → MIDI 48(triangle[48] 有路径)。
--   故三通道发声且均能解析到非空音色路径,tick 必触发 play。
local function forceSoundAndSilence(apu)
    -- 写三通道周期寄存器(低 8 位 + 高 3 位)
    apu:writeRegister(0x4002, 0xAB)
    apu:writeRegister(0x4003, 0x01)
    apu:writeRegister(0x4006, 0xAB)
    apu:writeRegister(0x4007, 0x01)
    apu:writeRegister(0x400A, 0xAB)
    apu:writeRegister(0x400B, 0x01)
    -- 使能三通道(同时置 lengthNonZero):发声
    apu:writeRegister(0x4015, 0x07)
    for _ = 1, 4 do apu:tick() end     -- 触发 play(failPlay 场景在此走到 play 抛错路径)
    -- 关闭三通道:静音
    apu:writeRegister(0x4015, 0x00)
    for _ = 1, 4 do apu:tick() end     -- 触发 stop(failStop 场景在此走到 stop 抛错路径)
end

-- 随机驱动:nOps 次随机操作(写入 / tick / 开关 $4015)。
local function drive(apu, rng, nOps)
    for _ = 1, nOps do
        local act = rng(10)
        if act <= 6 then
            apu:writeRegister(pickAddress(rng), pickValue(rng))
        elseif act <= 9 then
            apu:tick()
        else
            apu:writeRegister(0x4015, (rng(2) == 1) and 0x07 or 0x00)
        end
    end
end

-- 按场景安装后端,返回上下文(供 teardown 还原)。
--   0 = 正常 mock;1 = playReturnsNil(被静音);2 = failPlay(play 抛错);
--   3 = failStop(stop 抛错);4 = 完全缺失 PlaySoundFile(不安装 mock,清空全局)。
local function setupBackend(scenario)
    if scenario == 4 then
        local savedP, savedS = rawget(_G, "PlaySoundFile"), rawget(_G, "StopSound")
        _G.PlaySoundFile = nil
        _G.StopSound = nil
        return { kind = "missing", savedP = savedP, savedS = savedS }
    end

    local opts
    if scenario == 1 then
        opts = { playReturnsNil = true }
    elseif scenario == 2 then
        opts = { failPlay = true }
    elseif scenario == 3 then
        opts = { failStop = true }
    else
        opts = {}
    end
    local mock = SoundMock.new(opts)
    mock:install()
    return { kind = "mock", mock = mock }
end

local function teardownBackend(ctx)
    if ctx.kind == "mock" then
        ctx.mock:uninstall()
    else
        _G.PlaySoundFile = ctx.savedP
        _G.StopSound = ctx.savedS
    end
end

-- 单次随机用例:返回 (是否通过, 错误信息)。整条流程用 pcall 包裹,断言绝不抛错。
local function runCase(scenario, seed, nOps)
    local ctx = setupBackend(scenario)
    -- APU:new 在后端安装后探测可用性:
    --   场景 0-3 → available=true(走真实触发/停止路径);
    --   场景 4   → available=false(静默降级,tick 解析但不触发)。
    local apu = APU:new(nil)

    local pre = math.floor(nOps / 2)
    local post = nOps - pre
    local rng = makeRng(seed)

    local ok, err = pcall(function()
        edgeWrites(apu)                 -- 确定性边界写入(安全忽略)
        drive(apu, rng, pre)            -- 随机操作前段
        forceSoundAndSilence(apu)       -- 强制走到 play / stop 路径
        drive(apu, rng, post)           -- 随机操作后段
        apu:readStatus()                -- 状态读取亦不应抛错
        apu:reset()                     -- 复位亦不应抛错
    end)

    teardownBackend(ctx)
    return ok, err
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 9: 任意输入且后端不可用时绝不报错
property "P9: 任意寄存器写入序列 + 任意后端可用性下,writeRegister 与 tick() 绝不抛错(安全忽略 + 静默降级)" {
    -- 生成器:
    --   g1 = 操作序列总长度 N(10..40)
    --   g2 = 操作序列随机种子(驱动自包含 LCG 展开整条序列)
    --   g3 = 后端场景(0=正常,1=playReturnsNil,2=failPlay,3=failStop,4=缺失 PlaySoundFile)
    generators = { int(10, 40), int(1, 1000000), int(0, 4) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g1, g2, g3)
        local ok, err = runCase(g3, g2, g1)
        if not ok then
            io.write("\n[P9 反例] scenario=" .. tostring(g3) ..
                " seed=" .. tostring(g2) ..
                " nOps=" .. tostring(g1) ..
                " 错误: " .. tostring(err) .. "\n")
        end
        return ok
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 9 })

io.write("\n==== 属性测试 P9" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
