-- apu_property_p4_test.lua
-- 属性测试 P4(任务 3.5):频率映射到最近的可听域半音并解析到合法路径。
-- Feature: apu-sound, Property 4: For any 频率值,所选音色的 MIDI 半音 n 满足:在音域范围 [low, high] 内时,n 与该频率的对数距离不大于任一相邻半音(即最近半音);超出范围时裁剪到边界值;且 n 与通道波形类型在音色映射表中都能解析到一个非空的文件路径字符串。
--
-- 用 lua-quickcheck 跑 ≥100 次随机迭代。
-- 生成器策略:lqc 自带 float 生成器忽略上下界(取值居中于 0),不适合生成正频率。
-- 改为在"半音空间"上用整数生成器取样,再换算成正频率,使覆盖均匀且同时覆盖:
--   ① 低于音域下界(裁剪到 low) ② 落在音域内(取最近半音) ③ 高于音域上界(裁剪到 high)。
-- 生成 g ∈ [-200, 1400] 表示 MIDI 音高的十分之一(x = g/10,范围 -20..140 个半音),
-- freq = a4 * 2^((x - 69) / 12),恒为正。音域为 [36, 96],故三个分支均被充分覆盖。
--
-- 断言(对每个生成频率):
--   1. n 落在 [low, high] 内;
--   2. 由 freq 独立算出的"理想最近半音"nIdeal:在 [low, high] 内时 n == nIdeal,
--      且 n 到 freq 的半音(对数)距离不大于相邻半音 n-1 / n+1(最近半音);
--      nIdeal 超界时 n 应裁剪到对应边界(此情形不做相邻半音比较);
--   3. 对 pulse 与 triangle,toneIndexToPath(n, kind) 均返回非空字符串。
--
-- 独立可运行入口(lua tests/apu_property_p4_test.lua),不依赖 WoW。
-- Validates: Requirements 2.4, 2.5

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

-- 先安装全局 bit(APU.lua 顶部依赖全局 bit),再接入 lqc。
require("tests.support.bit_stub")
local lqc = require("tests.support.lqc_harness")

-- 加载离线生成的音色映射表(定义 _G.WOWFC_APU_TONEMAP),再加载 APU 模块。
dofile("Utils/APUToneMap_Generated.lua")
dofile("Core/APU.lua")  -- 定义全局 _G.APU

local MAP = _G.WOWFC_APU_TONEMAP
local A4 = MAP.a4 or 440
local LOW, HIGH = MAP.range.low, MAP.range.high
local LOG2 = math.log(2)

-- 由 MIDI 音高(可为小数)换算频率(Hz)。
local function midiToFreq(x)
    return A4 * 2 ^ ((x - 69) / 12)
end

-- 由频率算出"理想最近半音"(未裁剪),与 APU 内部口径一致(标准四舍五入)。
local function idealNearest(freq)
    local x = 69 + 12 * (math.log(freq / A4) / LOG2)
    return math.floor(x + 0.5), x
end

-- 非空字符串判定。
local function isNonEmptyString(s)
    return type(s) == "string" and #s > 0
end

lqc.setup()
lqc.reset()

-- Feature: apu-sound, Property 4: 频率映射到最近的可听域半音并解析到合法路径
property "P4: 频率映射到最近可听域半音并解析到合法音色路径" {
    -- g = MIDI 音高 ×10,范围 -20.0 .. 140.0 个半音,覆盖音域下界以下 / 内 / 上界以上。
    generators = { int(-200, 1400) },
    numtests = lqc.DEFAULT_ITERATIONS,
    check = function(g)
        local freq = midiToFreq(g / 10)
        local n = APU.frequencyToToneIndex(freq)

        -- 生成的频率恒为正,必能解析出半音索引。
        if n == nil then
            return false
        end

        -- 断言 1:n 落在音域 [low, high] 内。
        if n < LOW or n > HIGH then
            return false
        end

        -- 断言 2:最近半音 / 边界裁剪。
        local nIdeal, x = idealNearest(freq)
        if nIdeal < LOW then
            -- 低于下界:应裁剪到 low,不做相邻半音比较。
            if n ~= LOW then return false end
        elseif nIdeal > HIGH then
            -- 高于上界:应裁剪到 high,不做相邻半音比较。
            if n ~= HIGH then return false end
        else
            -- 音域内:应取理想最近半音。
            if n ~= nIdeal then return false end
            -- 验证"最近":n 到 freq 的半音对数距离不大于相邻半音 n-1 / n+1。
            local dn   = math.abs(x - n)
            local dPrev = math.abs(x - (n - 1))
            local dNext = math.abs(x - (n + 1))
            local eps = 1e-9
            if dn > dPrev + eps or dn > dNext + eps then
                return false
            end
        end

        -- 断言 3:pulse 与 triangle 均解析到非空路径字符串。
        local pulsePath = APU.toneIndexToPath(n, "pulse")
        local trianglePath = APU.toneIndexToPath(n, "triangle")
        return isNonEmptyString(pulsePath) and isNonEmptyString(trianglePath)
    end,
}

local passed = lqc.run({ iterations = lqc.DEFAULT_ITERATIONS, seed = 4 })

io.write("\n==== 属性测试 P4" ..
    (passed and "通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(passed and 0 or 1)
