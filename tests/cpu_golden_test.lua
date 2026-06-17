-- cpu_golden_test.lua
-- CPU/PPU 正确性护栏:用 headless harness 跑真实 SMB1 固定帧数,对若干关键帧的
-- framebuffer 取指纹,与基线逐一比对。任何改动 CPU/PPU 取指或访存路径后,这个
-- 测试必须仍然通过——即"优化不改变画面"。
--
-- 基线文件:tests/fixtures/golden_smb1.lua。首次运行(基线不存在)会生成它并提示;
-- 之后运行即对比。优化 CPU 前应先在未优化代码上生成基线。
--
-- 独立可运行:lua tests/cpu_golden_test.lua

package.path = package.path .. ";./?.lua"

local H = require("tests.support.fc_harness")
local Unit = require("tests.support.unit")

local ROM_PATH = "tests/fixtures/smb1.nes"
local BASELINE_PATH = "tests/fixtures/golden_smb1.lua"
local CHECKPOINTS = { 30, 60, 90, 120, 150, 180 }
local MAX_FRAME = CHECKPOINTS[#CHECKPOINTS]

-- 跑到各检查点,收集 {frame = hash}
local function collect()
    local rom = H.readRom(ROM_PATH)
    local fc = H.newFC(rom)
    local result = {}
    local cpIdx = 1
    for f = 1, MAX_FRAME do
        fc:frame()
        if CHECKPOINTS[cpIdx] == f then
            result[f] = H.hashFramebuffer(fc)
            cpIdx = cpIdx + 1
        end
    end
    return result
end

local function loadBaseline()
    local chunk = loadfile(BASELINE_PATH)
    if not chunk then return nil end
    return chunk()
end

local function writeBaseline(data)
    local fh = assert(io.open(BASELINE_PATH, "w"))
    fh:write("-- golden_smb1.lua (自动生成的 CPU/PPU 黄金快照基线)\n")
    fh:write("-- 由 tests/cpu_golden_test.lua 在未优化代码上生成。\n")
    fh:write("-- 若有意改变模拟行为,删除本文件并重新生成。\n")
    fh:write("return {\n")
    for _, f in ipairs(CHECKPOINTS) do
        fh:write(string.format("    [%d] = %d,\n", f, data[f]))
    end
    fh:write("}\n")
    fh:close()
end

local allOk = true
local actual = collect()
local baseline = loadBaseline()

if not baseline then
    writeBaseline(actual)
    io.write("|基线不存在,已生成 " .. BASELINE_PATH .. "。请复核后重跑以进入对比模式。\n")
    for _, f in ipairs(CHECKPOINTS) do
        io.write(string.format("  帧 %d: hash=%d\n", f, actual[f]))
    end
    io.write("\n==== 黄金快照基线已生成(本次不算通过/失败)====\n")
    os.exit(0)
end

local t = Unit.new("SMB1 黄金快照(逐帧 framebuffer 指纹)")
t:it("各检查点指纹与基线一致", function(a)
    for _, f in ipairs(CHECKPOINTS) do
        a.equal(actual[f], baseline[f], "帧 " .. f .. " 指纹应与基线一致")
    end
end)
allOk = t:finish() and allOk

io.write("\n==== CPU 黄金快照" .. (allOk and "通过 ✅" or "失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
