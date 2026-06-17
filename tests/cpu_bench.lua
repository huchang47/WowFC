-- cpu_bench.lua
-- CPU 优化的离线"模拟"工具(非 pass/fail,不入 run.lua)。报告:
--   1. 每帧 memoryMapperLoad 访存次数(与位运算实现无关的硬指标,最能反映取指/
--      ROM 读的 method-dispatch 开销;PRG 直读优化后应明显下降)。
--   2. headless 每帧耗时(Lua5.1 + 纯 Lua 位运算,绝对值偏大,只看优化前后相对趋势;
--      会低估真机收益,因真机位运算是原生 C)。
--
-- 用法:lua tests/cpu_bench.lua [warmup] [measure]

package.path = package.path .. ";./?.lua"

local H = require("tests.support.fc_harness")

local ROM_PATH = "tests/fixtures/smb1.nes"
local WARMUP = tonumber(arg and arg[1]) or 60
local MEASURE = tonumber(arg and arg[2]) or 100

local rom = H.readRom(ROM_PATH)

-- ---- 1) 访存计数(单独实例,带 instrument)----
do
    local fc = H.newFC(rom)
    H.runFrames(fc, WARMUP)               -- 先进入稳定画面
    local readCount = H.instrumentLoads(fc)
    local before = readCount()
    H.runFrames(fc, 10)
    local loadsPerFrame = (readCount() - before) / 10
    io.write(string.format("memoryMapperLoad 次数/帧: %.0f\n", loadsPerFrame))
end

-- ---- 2) 耗时(干净实例,不 instrument)----
do
    local fc = H.newFC(rom)
    H.runFrames(fc, WARMUP)
    local t0 = os.clock()
    H.runFrames(fc, MEASURE)
    local dt = os.clock() - t0
    io.write(string.format("headless 耗时: %.2f ms/帧 (跑 %d 帧, 共 %.3fs)\n",
        dt / MEASURE * 1000, MEASURE, dt))
end

io.write("(注:headless 绝对耗时受纯 Lua 位运算放大,仅作优化前后相对参考;真机以 /fc prof 为准)\n")
