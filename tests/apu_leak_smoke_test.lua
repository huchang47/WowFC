-- apu_leak_smoke_test.lua
-- 长序列烟雾验证(apu-sound-leak 任务 4.2 可选项):资源有界、不随帧增长。
-- Feature: apu-sound-leak, Property 1(integration): 以 mock 后端驱动数千帧
--   "持续发声变调"序列,断言运行全程任一通道净持有句柄数(#play-#stop)始终 <= 1。
--
-- 目的:补充 P1-P9 与集成/烟雾回归之外的"长程资源有界"证据 —— 修复(任务 3.1:
--   覆盖 channel.handle 前先 stop 旧句柄)后,长时间持续发声变调时净持有句柄不随
--   帧数增长,始终 <= 1(对应 design.md Integration Tests / bugfix.md 需求 2.1/2.2)。
--
-- 注:这不是 lua-quickcheck 属性测试,而是确定性长序列烟雾验证(单通道隔离,
--   逐通道驱动数千帧),与既有属性测试互补。play/stop 经 mock SoundBackend 记录。
--
-- 独立可运行入口(lua tests/apu_leak_smoke_test.lua),不依赖 WoW。
-- Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6

-- 让 require/dofile 能从工作区根目录解析。
package.path = package.path .. ";./?.lua"

require("tests.support.bit_stub")
local SoundMock = require("tests.support.sound_mock")

dofile("Utils/APUToneMap_Generated.lua")  -- 定义 _G.WOWFC_APU_TONEMAP
dofile("Core/APU.lua")                     -- 定义 _G.APU

local MAP = _G.WOWFC_APU_TONEMAP
local A4 = MAP.a4 or 440
local LOW, HIGH = MAP.range.low, MAP.range.high

local CHANNEL_NAMES = { "pulse1", "pulse2", "triangle" }
local FRAMES = 5000   -- 数千帧:体现"长时间持续发声变调"

-- 音高窗口:音域内一段小窗口,频繁跨半音又恒能解析到非空音色路径。
local PITCH_BASE = 60
local PITCH_WINDOW = 8
if PITCH_BASE < LOW then PITCH_BASE = LOW end
if PITCH_BASE + PITCH_WINDOW - 1 > HIGH then PITCH_WINDOW = HIGH - PITCH_BASE + 1 end

local function midiToFreq(m)
    return A4 * 2 ^ ((m - 69) / 12)
end

local function setSounding(apu, name, midi)
    local ch = apu.channels[name]
    ch.enabled = true
    ch.lengthNonZero = true
    ch.freq = midiToFreq(midi)
end

-- 驱动单通道 FRAMES 帧"持续发声 + 相邻帧 toneIndex 必不同"序列。
-- 每帧 tick 后检查 (#play - #stop) 峰值,要求全程 <= 1。
-- 返回 plays, stops, maxOutstanding。
local function driveLong(apu, mock, name, frames)
    local maxOutstanding = 0
    for i = 1, frames do
        -- 在窗口内相邻帧必不同:i 奇偶交替 + 缓慢游走,持续跨半音 → needTrigger 近乎每帧成立。
        local t = PITCH_BASE + ((i + (i % 2)) % PITCH_WINDOW)
        if PITCH_WINDOW > 1 and (t == PITCH_BASE + ((i - 1 + ((i - 1) % 2)) % PITCH_WINDOW)) then
            t = PITCH_BASE + ((t - PITCH_BASE + 1) % PITCH_WINDOW)
        end
        setSounding(apu, name, t)
        apu:tick()
        local outstanding = #mock.playCalls - #mock.stopCalls
        if outstanding > maxOutstanding then
            maxOutstanding = outstanding
        end
    end
    return #mock.playCalls, #mock.stopCalls, maxOutstanding
end

local allOk = true
io.write("==== 长序列烟雾验证:数千帧持续发声变调,净持有句柄应始终 <= 1 ====\n")

for _, name in ipairs(CHANNEL_NAMES) do
    local mock = SoundMock.new()
    mock:install()
    local apu = APU:new(nil)
    if not apu.available then
        mock:uninstall()
        io.write("  [跳过] SoundBackend 不可用(mock 未生效?)\n")
        allOk = false
        break
    end
    local plays, stops, maxOut = driveLong(apu, mock, name, FRAMES)
    mock:uninstall()

    local ok = (maxOut <= 1)
    io.write(string.format(
        "  %-8s 帧数=%d  #play=%d  #stop=%d  全程净持有峰值=%d  => %s\n",
        name, FRAMES, plays, stops, maxOut, ok and "OK(<=1)" or "FAIL(>1)"))
    if not ok then allOk = false end
    -- 持续发声变调应确有大量触发,否则未真正驱动到泄漏路径(防止假阴性)。
    if plays < FRAMES / 4 then
        io.write(string.format(
            "  [警告] %s 触发次数偏低(%d),可能未驱动到持续变调路径\n", name, plays))
        allOk = false
    end
end

io.write("==== 长序列烟雾验证" ..
    (allOk and "通过 ✅(资源有界,不随帧增长)" or "失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
