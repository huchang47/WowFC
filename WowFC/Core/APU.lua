-- APU.lua
-- APU (Audio Processing Unit) 音频处理单元
-- 采用"音高近似法"(Pitch Approximation):拦截 $4000-$4017 寄存器写入,
-- 每帧采样一次各通道状态,用 PlaySoundFile 播放最接近音高的预制音色文件。
-- 解析层为纯逻辑、可测试;播放层(SoundBackend)是薄薄的平台适配。

-- 性能:与 CPU.lua/PPU.lua 一致,把 bit 库函数局部缓存,避免热路径多一层查表。
local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

-- 创建全局 APU 表
_G.APU = {}
APU.__index = APU

-- 节流默认配置(去抖,防爆音/卡顿)
APU.DEFAULT_MIN_FRAMES_BETWEEN_TRIGGERS = 2   -- 同一通道两次触发的最小帧间隔
APU.DEFAULT_MAX_TRIGGERS_PER_TICK = 3         -- 单次 tick 最多触发次数

-- timer→频率换算常量(NES 标准公式)
-- NTSC NES CPU 主频(Hz)。方波/三角通道频率由 11 位 timer 按此主频换算。
APU.CPU_CLOCK = 1789773
-- 可听频率上限(Hz):取人耳可听范围上限约 20000Hz。timer 过小会使频率超过此上限,
-- 此时视为不发声(timerToFrequency 返回 nil)。
-- 阈值依据:① 人耳可听上限约 20kHz,超过即不可闻,继续发声无意义;
-- ② 该阈值远高于音色映射表最高音 C7(MIDI 96 ≈ 2093Hz),故 (2093, 20000] 区间内的
--    正常频率不会在此被误判为不发声,而是交由后续 frequencyToToneIndex 裁剪到 C7,
--    二者兼容(不会把本应裁剪发声的频率提前丢弃)。
APU.AUDIBLE_MAX_HZ = 20000

-- ============================================================================
-- SoundBackend:平台播放适配(集中所有 WoW 音频 API 调用,便于降级与测试替身注入)。
-- 作为 APU 的子表暴露(APU.SoundBackend),把"播放"(副作用)与"解析"(纯逻辑)分离。
-- 所有调用用 pcall 包裹吞掉异常,绝不向上冒泡到帧循环(需求 4.3/5.5)。
-- 选用 "SFX" 声道:受"音效音量"控制、可被玩家静音,且不碰受保护 CVar(设计 C4)。
-- ============================================================================
local SoundBackend = {}

-- 能力探测:运行环境是否提供全局 PlaySoundFile。
-- WoW 沙盒提供该全局函数;标准 Lua / 测试环境缺失时返回 false,供 APU 静默降级。
function SoundBackend.isAvailable()
    return type(_G.PlaySoundFile) == "function"
end

-- 播放一个音色文件,返回句柄(soundHandle);失败/被静音返回 nil。
-- 内部调用 PlaySoundFile(path, "SFX"):
--   - 平台缺失 PlaySoundFile     → 返回 nil(no-op,降级)
--   - 调用抛错(pcall 捕获)       → 吞掉异常,返回 nil(绝不冒泡)
--   - willPlay == nil(被静音等)  → 不视为错误,返回 nil(无可用句柄)
--   - 成功                       → 返回 soundHandle
function SoundBackend.play(path)
    local playFn = _G.PlaySoundFile
    if type(playFn) ~= "function" then
        return nil
    end
    local ok, willPlay, handle = pcall(playFn, path, "SFX")
    if not ok then
        return nil          -- 平台异常:吞掉,降级为不发声
    end
    if willPlay == nil then
        return nil          -- 被静音等:无可用句柄
    end
    return handle
end

-- 停止指定句柄的播放(内部调用 StopSound(handle))。
--   - handle 为 nil       → no-op
--   - 平台缺失 StopSound   → no-op(平台不支持停止)
--   - 调用抛错(pcall 捕获) → 吞掉异常
function SoundBackend.stop(soundHandle)
    if soundHandle == nil then
        return
    end
    local stopFn = _G.StopSound
    if type(stopFn) ~= "function" then
        return
    end
    pcall(stopFn, soundHandle)
end

-- 挂为 APU 子表,供调度层(tick,任务 6.x)与单元测试访问。
APU.SoundBackend = SoundBackend

-- 读取全局音色映射表(_G.WOWFC_APU_TONEMAP,由 Utils/APUToneMap_Generated.lua 提供)。
-- 表缺失或不是 table 时返回 nil,供调用方安全降级(不报错)。
local function getToneMap()
    local map = _G.WOWFC_APU_TONEMAP
    if type(map) ~= "table" then
        return nil
    end
    return map
end

-- 判定音色映射表是否为空:表缺失,或 pulse / triangle 分组都为空(无任何音色键)。
-- 用于 APU:new 的降级探测 —— 表为空则无音色可播,置 available=false(静默降级)。
local function isToneMapEmpty()
    local map = getToneMap()
    if not map then
        return true
    end
    local function groupEmpty(group)
        return type(group) ~= "table" or next(group) == nil
    end
    return groupEmpty(map.pulse) and groupEmpty(map.triangle)
end

-- 创建一个发声通道的初始派生状态
--   kind          : "pulse" / "triangle"(pulse1 与 pulse2 共用 pulse 音色)
--   enabled       : 通道使能位($4015 对应 bit)
--   timer         : 11 位周期值(低 8 位 + 高 3 位拼出)
--   freq          : 由 timer 换算的频率(Hz)
--   toneIndex     : 最接近的半音音色索引;nil 表示不可听/不发声
--   lengthNonZero : length counter 是否非零(粗粒度)
--   handle        : 上次 PlaySoundFile 返回的句柄,用于 StopSound
--   lastTriggerFrame : 上次触发所在的 frameCounter(用于同音去抖)
--   lastTriggerTone  : 上次触发播放的 toneIndex,配合 lastTriggerFrame 做"同音去抖"
--                      (只抑制相同音色的短时间重复触发,不限制不同音符的连续切换)。
--   prevActiveTone   : 上一帧的"有效 toneIndex"(发声时为 toneIndex,不发声时为 nil),
--                      供 tick 跨帧比较以判定"静音→发声"与"跨半音"是否需要(重新)触发。
local function newChannel(kind)
    return {
        kind = kind,
        enabled = false,
        timer = 0,
        freq = 0,
        toneIndex = nil,
        lengthNonZero = false,
        handle = nil,
        lastTriggerFrame = 0,
        lastTriggerTone = nil,
        prevActiveTone = nil,
    }
end

-- 初始化 $4000-$4017 影子寄存器表(仅记录原始写入字节,写入时不立即触发播放)
local function newRegs()
    local regs = {}
    for addr = 0x4000, 0x4017 do
        regs[addr] = 0
    end
    return regs
end

-- 构造:返回 apu 实例,挂载到 fc.apu
function APU:new(nes)
    local apu = setmetatable({}, self)
    apu.nes = nes

    apu.enabled = true        -- 声音总开关(来自 WOWFCDB.soundEnabled)
    -- SoundBackend 探测结果(降级标志):缺少 PlaySoundFile 或映射表为空时置 false。
    -- 静默降级语义:available=false 时 tick 照常解析(不报错)但不触发任何播放,
    -- 模拟器画面与输入不受影响(需求 4.3/5.5)。
    apu.available = SoundBackend.isAvailable() and (not isToneMapEmpty())

    -- $4000-$4017 影子寄存器
    apu.regs = newRegs()

    -- 三个发声通道的派生状态(pulse1 / pulse2 / triangle)
    apu.channels = {
        pulse1   = newChannel("pulse"),
        pulse2   = newChannel("pulse"),
        triangle = newChannel("triangle"),
    }

    apu.frameCounter = 0      -- APU 自己的帧序号(用于节流)
    apu.throttle = {
        minFramesBetweenTriggers = APU.DEFAULT_MIN_FRAMES_BETWEEN_TRIGGERS,
        maxTriggersPerTick = APU.DEFAULT_MAX_TRIGGERS_PER_TICK,
    }

    return apu
end

-- 重置:清空影子寄存器与通道状态、停止所有发声
function APU:reset()
    self.regs = newRegs()
    self.channels = {
        pulse1   = newChannel("pulse"),
        pulse2   = newChannel("pulse"),
        triangle = newChannel("triangle"),
    }
    self.frameCounter = 0
    -- 注:停止当前正在发声的句柄(StopSound)在 SoundBackend 接入后(任务 5.x/6.x)处理;
    -- 这里通过重建 channels 丢弃旧 handle,确保不再续播被跟踪的音符。
end

-- 纯计算辅助:11 位 timer → 频率(Hz)。无副作用、不依赖实例,用点号调用便于测试。
--   timer       : 11 位周期值(0-2047),由低 8 位 + 高 3 位拼出
--   channelKind : "pulse"(方波) / "triangle"(三角波)
-- NES 标准公式:
--   pulse:    f = CPU_CLOCK / (16 * (timer + 1))
--   triangle: f = CPU_CLOCK / (32 * (timer + 1))
-- 返回频率(Hz);当 timer 过小导致频率超过可听上限(AUDIBLE_MAX_HZ)时返回 nil,
-- 表示该音不可闻、不发声(由调用方据此跳过触发)。
function APU.timerToFrequency(timer, channelKind)
    -- 不同波形的分频系数:方波 16、三角波 32
    local div
    if channelKind == "triangle" then
        div = 32
    else
        div = 16  -- 默认按 pulse 处理(pulse1/pulse2 共用)
    end

    local freq = APU.CPU_CLOCK / (div * (timer + 1))

    -- timer 过小→频率超可听上限,视为不发声
    if freq > APU.AUDIBLE_MAX_HZ then
        return nil
    end

    return freq
end

-- 纯计算辅助:频率(Hz) → 最接近的半音音色索引(MIDI 音高)。无副作用、用点号调用便于测试。
-- 以 12 平均律计算最近半音:n = round(69 + 12 * log2(f / a4))。
--   基准音 a4 从映射表读取(默认 440),保证与离线生成工具一致。
--   Lua 5.1 无 math.log 双参数,故用 math.log(x)/math.log(2) 求 log2。
--   round 采用标准四舍五入(math.floor(x + 0.5)),落在两半音正中时一致地向上取整。
-- 结果裁剪到映射表音域 range.low/high(需求 2.5"选取最接近的半音文件")。
-- 不可发声的频率(nil / 非正)或映射表缺失/无音域时返回 nil(不发声 / 静默降级)。
function APU.frequencyToToneIndex(freq)
    -- timerToFrequency 不发声时返回 nil;非正频率无法取对数,一并视为无音色。
    if type(freq) ~= "number" or freq <= 0 then
        return nil
    end

    local map = getToneMap()
    if not map or type(map.range) ~= "table" then
        return nil  -- 映射表缺失/无音域,无法裁剪,静默降级
    end

    local a4 = map.a4 or 440
    local log2 = math.log(freq / a4) / math.log(2)
    local n = math.floor(69 + 12 * log2 + 0.5)  -- 标准四舍五入到最近半音

    -- 裁剪到映射表音域 [low, high]
    local low, high = map.range.low, map.range.high
    if low and n < low then
        n = low
    elseif high and n > high then
        n = high
    end

    return n
end

-- 纯计算辅助:(音色索引 + 通道波形) → 音色文件路径。无副作用、用点号调用便于测试。
--   toneIndex   : frequencyToToneIndex 的结果(MIDI 音高);nil 表示不发声
--   channelKind : "pulse" / "triangle"(pulse1 与 pulse2 共用 pulse 音色)
-- 从映射表对应波形分组按音高取路径;映射表缺失、波形未知或该音高无文件时返回 nil
-- (表示不发声,由调用方据此跳过触发)。
function APU.toneIndexToPath(toneIndex, channelKind)
    if toneIndex == nil then
        return nil
    end

    local map = getToneMap()
    if not map then
        return nil
    end

    -- 按通道波形定位分组(pulse / triangle)
    local group = map[channelKind]
    if type(group) ~= "table" then
        return nil
    end

    return group[toneIndex]  -- 找不到对应音高返回 nil
end

-- 通道周期寄存器地址映射:{ 低 8 位地址, 高 3 位地址 }
--   pulse1   : $4002 / $4003
--   pulse2   : $4006 / $4007
--   triangle : $400A / $400B
-- 由这两个寄存器拼出 11 位 timer:timer = low8 | ((high3 & 0x07) << 8)。
-- 写其中任一寄存器都需重算该通道 timer 与频率。

-- 由通道的两个周期寄存器重算 11 位 timer 与频率(写入时调用)。
--   读取影子寄存器的原始字节,经 band 掩码保证异常值/越界值也不抛错;
--   freq 由 timerToFrequency 换算,timer 过小(超可听上限)时为 nil(不发声)。
local function updateChannelTimer(apu, channel, lowAddr, highAddr)
    local low8  = band(tonumber(apu.regs[lowAddr])  or 0, 0xFF)  -- 低 8 位
    local high3 = band(tonumber(apu.regs[highAddr]) or 0, 0x07)  -- 高 3 位(仅 bit0-2)
    local timer = bor(low8, lshift(high3, 8))
    channel.timer = timer
    channel.freq  = APU.timerToFrequency(timer, channel.kind)    -- 可能为 nil
end

-- 内存映射委托:处理 ROM 对 $4000-$4017 的写入(由 FC:memoryMapperWrite 调用)。
--   address : 目标地址(仅 $4000-$4017 区被处理,其余安全忽略)
--   value   : 写入字节(0-255;异常值经 band 掩码,不抛错)
-- 行为:
--   1. 将 $4000-$4017 写入记录到影子寄存器 self.regs(仅记录原始字节,不立即触发播放);
--   2. 周期寄存器($4002/$4003 等)更新对应通道 11 位 timer 与频率;
--   3. $4015 使能寄存器按 bit0/1/2 更新 pulse1/pulse2/triangle 使能位,并粗粒度维护
--      lengthNonZero(供 readStatus 与触发逻辑使用);
--   4. 未支持寄存器(DMC $4010-$4013、sweep、envelope、frame counter $4017 等)仅记录、不解析;
--   5. 越界/非法地址直接忽略,不报错。
function APU:writeRegister(address, value)
    -- 安全性:仅处理 $4000-$4017 区;非数字或越界地址直接忽略(不记录、不报错)。
    if type(address) ~= "number" or address < 0x4000 or address > 0x4017 then
        return
    end

    -- 记录到影子寄存器(原始字节;解析时再做掩码,故异常值不影响安全性)。
    self.regs[address] = value

    local ch = self.channels

    if address == 0x4002 or address == 0x4003 then
        -- Pulse1 周期:低 8 位 $4002 + 高 3 位 $4003
        updateChannelTimer(self, ch.pulse1, 0x4002, 0x4003)
        -- 写高位寄存器通常伴随 length load:通道使能时近似置 lengthNonZero 为真。
        if address == 0x4003 and ch.pulse1.enabled then
            ch.pulse1.lengthNonZero = true
        end

    elseif address == 0x4006 or address == 0x4007 then
        -- Pulse2 周期:低 8 位 $4006 + 高 3 位 $4007
        updateChannelTimer(self, ch.pulse2, 0x4006, 0x4007)
        if address == 0x4007 and ch.pulse2.enabled then
            ch.pulse2.lengthNonZero = true
        end

    elseif address == 0x400A or address == 0x400B then
        -- Triangle 周期:低 8 位 $400A + 高 3 位 $400B
        updateChannelTimer(self, ch.triangle, 0x400A, 0x400B)
        if address == 0x400B and ch.triangle.enabled then
            ch.triangle.lengthNonZero = true
        end

    elseif address == 0x4015 then
        -- $4015 通道使能寄存器:bit0=Pulse1、bit1=Pulse2、bit2=Triangle。
        local byte = band(tonumber(value) or 0, 0xFF)  -- 异常值经掩码,安全
        local p1  = band(byte, 0x01) ~= 0
        local p2  = band(byte, 0x02) ~= 0
        local tri = band(byte, 0x04) ~= 0
        ch.pulse1.enabled   = p1
        ch.pulse2.enabled   = p2
        ch.triangle.enabled = tri
        -- 粗粒度 length 近似(N3):使能位作为 lengthNonZero 主要依据 ——
        -- 使能时视为 length 非零;清使能位时清零(NES 上清使能位会强制 length=0)。
        -- 供后续 readStatus(P3)与触发逻辑判定通道是否激活。
        ch.pulse1.lengthNonZero   = p1
        ch.pulse2.lengthNonZero   = p2
        ch.triangle.lengthNonZero = tri
    end
    -- 其余寄存器($4000/$4001/$4004/$4005/$4008/$4009/$400C-$4013/$4017 等):
    -- 仅记录到影子寄存器,本版本不解析(sweep/envelope/DMC/frame counter),安全忽略。
end

-- 内存映射委托:返回 $4015(APU 状态)读取字节(由 FC:memoryMapperLoad 调用)。
-- 返回模型($4015 读取,需求 1.4):
--   bit0 = Pulse1 length counter 非零
--   bit1 = Pulse2 length counter 非零
--   bit2 = Triangle length counter 非零
--   bit3 = Noise(本版本未支持,恒 0)
--   bit4 = DMC  (本版本未支持,恒 0)
--   其余高位恒 0
-- 各 length 非零状态取自通道粗粒度 lengthNonZero(由 writeRegister 维护)。
-- 这样依赖读 $4015 判断音效是否结束的游戏逻辑不会被破坏(至少给出合理值)。
-- 返回 0-255 的整数字节。
function APU:readStatus()
    local ch = self.channels
    local status = 0
    if ch.pulse1.lengthNonZero then
        status = bor(status, 0x01)            -- bit0
    end
    if ch.pulse2.lengthNonZero then
        status = bor(status, lshift(1, 1))    -- bit1
    end
    if ch.triangle.lengthNonZero then
        status = bor(status, lshift(1, 2))    -- bit2
    end
    -- bit3(Noise)/bit4(DMC) 本版本未支持,恒 0;不置位即为 0。
    return status
end

-- ============================================================================
-- 帧驱动:每帧由 FC:frame() 末尾调用一次,采样各通道状态并触发匹配播放。
-- ============================================================================

-- 通道遍历顺序(固定顺序,保证触发行为可预测、便于测试断言)。
local CHANNEL_ORDER = { "pulse1", "pulse2", "triangle" }

-- 计算单个通道本帧的"有效 toneIndex":
--   通道使能 + length 非零 + freq 非 nil + toneIndex 非 nil 时返回该 toneIndex(发声);
--   否则返回 nil(不发声)。
-- 同时把派生的 toneIndex 写回 channel.toneIndex(快照),供调用方与后续任务使用。
local function sampleChannelTone(channel)
    -- 不使能或 length 为零:不发声。
    if not channel.enabled or not channel.lengthNonZero then
        channel.toneIndex = nil
        return nil
    end
    -- freq 为 nil(timer 过小/超可听上限)时不发声。
    if channel.freq == nil then
        channel.toneIndex = nil
        return nil
    end
    -- 由频率求最近半音音色索引(含音域裁剪);映射表缺失时为 nil。
    local toneIndex = APU.frequencyToToneIndex(channel.freq)
    channel.toneIndex = toneIndex
    return toneIndex
end

-- 帧驱动:采样所有通道状态并触发(重新)播放(任务 6.1)。
-- 流程(每帧一次):
--   1. 递增 frameCounter;
--   2. 逐通道采样"有效 toneIndex"(由 enabled + lengthNonZero + freq + toneIndex 判定);
--   3. 与上一帧快照(prevActiveTone)比较 ——
--        · 由静音变为发声(prev==nil 且 now~=nil),或
--        · 持续发声中跨越半音边界(prev 与 now 均非 nil 且不相等)
--      时,解析(通道波形 kind + toneIndex)对应音色路径并调 SoundBackend.play 触发,记录 handle;
--        · 由发声变为静音/未使能(now==nil 且 prev~=nil)时,若持有 handle 且平台支持,
--          调一次 SoundBackend.stop(channel.handle) 并清空 handle(任务 6.3);
--   4. 更新 prevActiveTone 快照(发声为 toneIndex,不发声为 nil),使通道转为不发声后不再触发。
-- 节流(任务 6.5,需求 3.4):
--   · maxTriggersPerTick      : 单次 tick 触发的 play 次数上限,本帧达上限后不再触发任何通道;
--   · minFramesBetweenTriggers: 【已弃用】原"同音最小帧间隔去抖"已按用户要求取消,
--     同一音色现可在相邻帧立即重触发(字段保留以兼容配置/测试,但 tick 不再据此抑制触发)。
--   语义抉择详见下方触发分支注释。
-- 安全/降级:
--   · available==false(缺 PlaySoundFile 或映射表为空)时照常解析(更新快照)但不触发任何
--     播放、也不调停止(静默降级,需求 4.3/3.3);
--   · 路径解析失败(toneIndexToPath 返回 nil)时跳过该通道触发;
--   · SoundBackend.play / stop 均已 pcall 包裹,tick 不会因播放/停止异常而抛错。
-- 预留点:
--   · [任务 7.1] enabled 总开关短路(关闭时直接返回、不解析不触发)在此处函数开头接入。
function APU:tick()
    -- [任务 7.1] 声音总开关短路:关闭时直接 return —— 不解析、不触发,亦不递增 frameCounter。
    -- 直接返回是为满足需求 5.5"未开启声音时不产生额外开销":开销最小(仅一次布尔判断)。
    -- 不递增 frameCounter:使关闭期间帧序号冻结 —— 与节流(任务 6.5)配合时,重新开启后
    -- lastTriggerFrame 相对 frameCounter 的间隔关系得以保留,无需在开关处特殊重置节流状态。
    if not self.enabled then
        return
    end

    -- 帧序号递增(用于节流的帧间隔判定,任务 6.5)。
    self.frameCounter = self.frameCounter + 1

    local channels = self.channels
    -- 降级标志:不可用时只解析(更新快照),不触发播放。
    local canPlay = self.available

    -- 节流(任务 6.5):本帧已成功触发的 play 次数,达 maxTriggersPerTick 后本帧不再触发任何通道。
    local triggeredThisTick = 0
    local throttle = self.throttle

    for _, name in ipairs(CHANNEL_ORDER) do
        local channel = channels[name]

        -- 采样本帧"有效 toneIndex"(同时写回 channel.toneIndex 快照)。
        local nowTone = sampleChannelTone(channel)
        local prevTone = channel.prevActiveTone

        -- 触发条件:静音→发声(prev==nil 且 now~=nil),或持续发声跨半音(两者非 nil 且不等)。
        local needTrigger = (nowTone ~= nil) and (nowTone ~= prevTone)

        if needTrigger and canPlay then
            -- 节流(任务 6.5,需求 3.4):仅保留"单帧触发计数上限"这一道闸门(防止单帧内
            -- 大量触发造成卡顿/爆音)。已取消"同音最小帧间隔"限制 —— 同一音色也可在相邻帧
            -- 立即重触发,不再被去抖抑制(应用户要求:取消同音连续播放限制)。
            -- 说明:tick 每帧只在"有效音色变化"(静音→发声 / 跨半音)时才进入此分支,持续不变的
            -- 同音本就不会每帧重触发;此处放开的是"半音边界抖动等同音快速重触发"的场景。
            local tickBudgetOk = (triggeredThisTick < throttle.maxTriggersPerTick)

            if tickBudgetOk then
                -- 解析(通道波形 + 音高)对应音色文件路径;解析失败则跳过该通道触发(不计入节流)。
                local path = APU.toneIndexToPath(nowTone, channel.kind)
                if path ~= nil then
                    channel.handle = SoundBackend.play(path)   -- 失败/被静音返回 nil(已 pcall)
                    channel.lastTriggerFrame = self.frameCounter
                    channel.lastTriggerTone = nowTone
                    triggeredThisTick = triggeredThisTick + 1
                end
            end
            -- 被本帧触发计数上限抑制时:本帧不触发;prevActiveTone 仍按下方更新为 nowTone,
            -- 使"被抑制的这次音色变化"不会在后续未变化的帧里反复尝试(只在音色再变化时重评估)。
        elseif (nowTone == nil) and (prevTone ~= nil) then
            -- 发声→静音/未使能(任务 6.3):该通道本帧不再发声而上一帧在发声。
            -- 若持有 handle 且平台支持,调一次 SoundBackend.stop 停止上次播放,并清空 handle。
            -- 清空 handle 保证只在"由发声转为静音"的这一帧停止一次,持续静音不重复 stop。
            -- available==false 时不调停止(与不触发 play 一致,静默降级);stop 已 pcall,安全。
            if canPlay and channel.handle ~= nil then
                SoundBackend.stop(channel.handle)
                channel.handle = nil
            end
        end

        -- 更新跨帧快照:发声为 toneIndex,不发声为 nil(转为不发声后不再触发)。
        channel.prevActiveTone = nowTone
    end
end

-- ============================================================================
-- 声音总开关(任务 7.1,需求 4.2/5.5)。
-- 由斜杠命令 /fc sound on|off(任务 10.x)与 WOWFCDB.soundEnabled 持久化驱动。
-- ============================================================================

-- 设置声音总开关。on 为真值即启用,否则关闭(self.enabled 规整为 boolean)。
-- 当由"启用"切换到"关闭"时,停止所有正在发声的通道,使关闭后立即静音:
--   · 对持有 handle 且平台支持(available)的通道调一次 SoundBackend.stop 并清空 handle,
--     不残留正在播放的句柄(stop 已 pcall 包裹,安全);
--   · 同时把各通道的"有效音色"跨帧快照 prevActiveTone 归零(置 nil),使重新开启后
--     第一帧能从"静音→发声"正常触发,而不会因残留快照漏触发或误判跨半音。
-- 关闭后 tick() 会因总开关短路直接返回(不解析、不触发),不影响画面与输入(需求 4.2/5.5)。
-- 注:不重置节流的 lastTriggerFrame —— 关闭期间 frameCounter 冻结(tick 短路不递增),
-- 重新开启后帧间隔关系自然成立,无需特殊处理。
function APU:setEnabled(on)
    local newEnabled = on and true or false      -- 规整为 boolean
    local wasEnabled = self.enabled

    self.enabled = newEnabled

    -- 仅"启用→关闭"这一次切换需要停止现有发声并清空快照。
    if wasEnabled and not newEnabled then
        for _, name in ipairs(CHANNEL_ORDER) do
            local channel = self.channels[name]
            -- 停止仍在发声的句柄(平台支持时);available=false 则跳过停止(静默降级)。
            if self.available and channel.handle ~= nil then
                SoundBackend.stop(channel.handle)
            end
            channel.handle = nil
            -- 归零有效音色快照与上次触发音色,保证重开后从静音状态开始,首次发声能正常触发
            -- (避免重开时因 lastTriggerTone 残留与同音去抖判定而漏掉第一个音符)。
            channel.prevActiveTone = nil
            channel.lastTriggerTone = nil
        end
    end
end

-- 返回声音总开关状态(boolean)。
function APU:isEnabled()
    return self.enabled
end
