-- APU.lua
-- APU (Audio Processing Unit) 音频处理单元
-- ============================================================================
-- 寄存器模拟层:
--   完整模拟 $4000-$4017 全部寄存器,保证依赖 APU 状态字的游戏逻辑正确。
--   ($4015 读、DMC IRQ、帧计数器定时等)
--
-- 音频输出层:
--   通过 NES 频率寄存器 → MIDI 音高 → 预录制 WAV 音色文件的对位映射,
--   使用 PlaySoundFile() 播放真实音频。每个 NES 通道独占一个 WoW 混音通道,
--   新音符自动覆盖旧音符,无需手动停止。
--
-- 音色文件:
--   Sound/pulse_NNN.wav   — 方波音色 (pulse1 / pulse2 共用)
--   Sound/triangle_NNN.wav — 三角波音色
--   由 tools/gen_tones.py 预生成,映射表在 Utils/APUToneMap_Generated.lua
-- ============================================================================

local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local log    = math.log
local floor  = math.floor

-- NES NTSC CPU 主频
local CPU_CLOCK = 1789773

-- MIDI A4 基准
local MIDI_A4 = 69
local FREQ_A4 = 440.0

-- DMC 速率表: 速率索引 → CPU 周期/采样 (NTSC)
local DMC_RATE_TABLE = {
    428, 380, 340, 320, 286, 254, 226, 214,
    190, 160, 142, 128, 106,  84,  72,  54
}

-- 帧计数器 4-step 周期表: 每个 step 对应的 CPU 周期(基于 NTSC 1.79MHz / 240Hz)
local FRAME_PERIOD_4STEP = { 7457, 14914, 22371, 29828 }
local FRAME_PERIOD_5STEP = { 7457, 14914, 22371, 29829, 37281 }

-- WoW 混音通道映射: NES 通道 → WoW 通道名 (互不干扰)
local WOW_CHANNEL = {
    pulse1   = "Master",
    pulse2   = "SFX",
    triangle = "Music",
}

-- NES 通道 → 音色类型 (pulse1/pulse2 共用 pulse 音色, triangle 独立)
local CHANNEL_TONE_TYPE = {
    pulse1   = "pulse",
    pulse2   = "pulse",
    triangle = "triangle",
}

-- MIDI 音高范围 (对应 APUToneMap_Generated.lua 中实际存在的音色文件)
local TONE_MIN = 21
local TONE_MAX = 127

-- 创建全局 APU 表
_G.APU = {}
APU.__index = APU

-- ============================================================================
-- 音高查找表: 预计算 timer(0-2047) → MIDI note
-- 在首次 new() 时懒初始化,避免文件加载时计算开销
-- ============================================================================
local TIMER_TO_NOTE = nil

local function buildTimerToNote()
    if TIMER_TO_NOTE then return end
    TIMER_TO_NOTE = {}
    local log2 = log(2)
    for timer = 0, 0x7FF do
        local freq = CPU_CLOCK / (16 * (timer + 1))
        -- MIDI note = 69 + 12 * log2(freq / 440)
        local note = MIDI_A4 + 12 * log(freq / FREQ_A4) / log2
        local midi = floor(note + 0.5)
        if midi < TONE_MIN then midi = TONE_MIN end
        if midi > TONE_MAX then midi = TONE_MAX end
        TIMER_TO_NOTE[timer] = midi
    end
end

-- ============================================================================
-- 构造函数
-- ============================================================================
function APU:new(nes)
    buildTimerToNote()

    local apu = setmetatable({}, self)
    apu.nes = nes

    -- 寄存器镜像 ($4000-$4013 每个通道 4 字节)
    apu.regs = {}
    for i = 0, 0x13 do
        apu.regs[i] = 0
    end

    -- $4015 通道使能标志
    apu.channelEnable = {
        pulse1   = false,
        pulse2   = false,
        triangle = false,
        noise    = false,
        dmc      = false,
    }

    -- 长度计数器 (0 = 静音)
    apu.lengthCounter = {
        pulse1   = 0,
        pulse2   = 0,
        triangle = 0,
        noise    = 0,
    }

    -- 帧计数器
    apu.frameIRQEnabled  = true
    apu.frameIRQPending  = false
    apu.frameMode5Step   = false
    apu.frameCycle       = 0
    apu.frameStep        = 0
    apu._frameSeqWriteNextCycle = false

    -- DMC 通道
    apu.dmcIRQEnabled    = false
    apu.dmcIRQPending    = false
    apu.dmcLoop          = false
    apu.dmcRateIndex     = 0
    apu.dmcOutputLevel   = 0
    apu.dmcSampleAddr    = 0
    apu.dmcSampleLength  = 0
    apu.dmcBytesRemaining = 0
    apu.dmcCurAddr       = 0
    apu.dmcCurBytes      = 0
    apu.dmcCycle         = 0
    apu.dmcRateCycles    = 0
    apu.dmcSampleBuffer  = 0
    apu.dmcSilence       = false
    apu.dmcBufferEmpty   = true

    -- 音频输出状态
    apu._enabled = true                        -- 全局声音开关
    apu._currentNote = {                        -- 当前播放中的 MIDI 音高
        pulse1   = nil,
        pulse2   = nil,
        triangle = nil,
    }
    apu._pendingNotes = {                       -- 帧内待播放音符: { channel = {note, path, wowChannel} }
        pulse1   = nil,
        pulse2   = nil,
        triangle = nil,
    }
    apu._lastPlayFrame = {                      -- 各通道上次 PlaySoundFile 的帧号(用于节流)
        pulse1   = 0,
        pulse2   = 0,
        triangle = 0,
    }
    apu._audioFrame = 0                         -- 音频帧计数(每次 flushAudio 递增)
    apu._throttleFrames = 2                     -- 同一通道最少间隔帧数
    apu._toneMap = _G.WOWFC_APU_TONEMAP        -- 音色映射表引用

    return apu
end

-- ============================================================================
-- 长度计数器表: index → length (30 个有效值)
-- ============================================================================
local LENGTH_TABLE = {
    10, 254, 20,  2, 40,  4, 80,  6,
    160,  8, 60, 10, 14, 12, 26, 14,
    12,  16, 24, 18, 48, 20, 96, 22,
    192, 24, 72, 26, 16, 28, 32, 30
}

-- ============================================================================
-- 复位
-- ============================================================================
function APU:reset()
    for i = 0, 0x13 do
        self.regs[i] = 0
    end

    self.channelEnable = {
        pulse1   = false,
        pulse2   = false,
        triangle = false,
        noise    = false,
        dmc      = false,
    }

    self.lengthCounter = {
        pulse1   = 0,
        pulse2   = 0,
        triangle = 0,
        noise    = 0,
    }

    self.frameIRQEnabled  = true
    self.frameIRQPending  = false
    self.frameMode5Step   = false
    self.frameCycle       = 0
    self.frameStep        = 0
    self._frameSeqWriteNextCycle = false

    self.dmcIRQEnabled    = false
    self.dmcIRQPending    = false
    self.dmcLoop          = false
    self.dmcRateIndex     = 0
    self.dmcOutputLevel   = 0
    self.dmcSampleAddr    = 0
    self.dmcSampleLength  = 0
    self.dmcBytesRemaining = 0
    self.dmcCurAddr       = 0
    self.dmcCurBytes      = 0
    self.dmcCycle         = 0
    self.dmcRateCycles    = 0
    self.dmcSampleBuffer  = 0
    self.dmcSilence       = false
    self.dmcBufferEmpty   = true

    -- 重置音频状态
    self._currentNote.pulse1   = nil
    self._currentNote.pulse2   = nil
    self._currentNote.triangle = nil
    self._pendingNotes.pulse1   = nil
    self._pendingNotes.pulse2   = nil
    self._pendingNotes.triangle = nil
    self._lastPlayFrame.pulse1   = 0
    self._lastPlayFrame.pulse2   = 0
    self._lastPlayFrame.triangle = 0
end

-- ============================================================================
-- 声音开关
-- ============================================================================
function APU:setEnabled(enabled)
    self._enabled = enabled and true or false
end

function APU:isEnabled()
    return self._enabled
end

-- ============================================================================
-- 音色对位播放: timer → MIDI note → 记录到帧内待播放队列
-- 不直接调用 PlaySoundFile,由 flushAudio() 每帧统一批量播放。
-- ============================================================================
function APU:_playTone(channel, timerValue)
    if not self._enabled then return end
    if not self._toneMap then return end

    local note = TIMER_TO_NOTE[timerValue]
    if not note then return end

    -- 同通道同音高不重复记录
    if self._currentNote[channel] == note then return end
    self._currentNote[channel] = note

    -- 查找音色文件路径 (只做一次,缓存到 pendingNotes)
    local channelType = CHANNEL_TONE_TYPE[channel]
    local toneTable = self._toneMap[channelType]
    if not toneTable then return end

    local path = toneTable[note]
    if not path then return end

    local wowChannel = WOW_CHANNEL[channel] or "Master"

    -- 记录到帧内待播放队列 (同一帧内多次写入只保留最后一次)
    self._pendingNotes[channel] = { note = note, path = path, wowChannel = wowChannel }
end

-- ============================================================================
-- 每帧调用一次: 批量播放帧内累积的音符,带节流控制
-- 由 FC.lua 帧循环调用,替代原来的 tick()
-- ============================================================================
function APU:flushAudio()
    if not self._enabled then return end
    self._audioFrame = self._audioFrame + 1

    for channel, pending in pairs(self._pendingNotes) do
        if pending then
            -- 节流: 同一通道最少间隔 _throttleFrames 帧
            if self._audioFrame - self._lastPlayFrame[channel] >= self._throttleFrames then
                PlaySoundFile(pending.path, pending.wowChannel)
                self._lastPlayFrame[channel] = self._audioFrame
            end
            self._pendingNotes[channel] = nil
        end
    end
end

-- ============================================================================
-- 通道静音: 长度计数器归零或 $4015 禁用时,清除当前音高记录
-- ============================================================================
function APU:_muteChannel(channel)
    self._currentNote[channel] = nil
    self._pendingNotes[channel] = nil
end

-- ============================================================================
-- 寄存器写入 ($4000-$4013, $4015, $4017)
-- ============================================================================
function APU:write(addr, value)
    addr = band(addr, 0x1F)  -- $4000-$401F 镜像

    if addr <= 0x13 then
        self.regs[addr] = value

        if addr == 0x02 then
            -- Pulse1 定时器低字节: 仅缓存,不触发音频
        elseif addr == 0x03 then
            -- Pulse1 定时器高字节写入 → 定时器重载 → 触发音频
            local timer = self.regs[0x02] + lshift(band(value, 0x07), 8)
            if self.channelEnable.pulse1 then
                self:_playTone("pulse1", timer)
            end
            -- 长度计数器加载
            if self.channelEnable.pulse1 then
                self.lengthCounter.pulse1 = LENGTH_TABLE[rshift(value, 3)]
            end

        elseif addr == 0x06 then
            -- Pulse2 定时器低字节: 仅缓存
        elseif addr == 0x07 then
            -- Pulse2 定时器高字节写入 → 触发音频
            local timer = self.regs[0x06] + lshift(band(value, 0x07), 8)
            if self.channelEnable.pulse2 then
                self:_playTone("pulse2", timer)
            end
            -- 长度计数器加载
            if self.channelEnable.pulse2 then
                self.lengthCounter.pulse2 = LENGTH_TABLE[rshift(value, 3)]
            end

        elseif addr == 0x0A then
            -- Triangle 定时器低字节: 仅缓存
        elseif addr == 0x0B then
            -- Triangle 定时器高字节写入 → 触发音频
            local timer = self.regs[0x0A] + lshift(band(value, 0x07), 8)
            if self.channelEnable.triangle then
                self:_playTone("triangle", timer)
            end
            -- 长度计数器加载
            if self.channelEnable.triangle then
                self.lengthCounter.triangle = LENGTH_TABLE[rshift(value, 3)]
            end

        elseif addr == 0x0F then
            -- Noise 长度计数器加载 (噪声无音高,不触发音频)
            if self.channelEnable.noise then
                self.lengthCounter.noise = LENGTH_TABLE[rshift(value, 3)]
            end

        elseif addr == 0x10 then
            -- DMC 控制
            self.dmcIRQEnabled = band(value, 0x80) ~= 0
            self.dmcLoop       = band(value, 0x40) ~= 0
            self.dmcRateIndex  = band(value, 0x0F)
            self.dmcRateCycles = DMC_RATE_TABLE[self.dmcRateIndex + 1] or DMC_RATE_TABLE[1]

            if not self.dmcIRQEnabled then
                self.dmcIRQPending = false
            end

        elseif addr == 0x11 then
            -- DMC DAC (直出)
            self.dmcOutputLevel = band(value, 0x7F)

        elseif addr == 0x12 then
            -- DMC 采样地址: $C000 + value * 64
            self.dmcSampleAddr = 0xC000 + lshift(value, 6)

        elseif addr == 0x13 then
            -- DMC 采样长度: value * 16 + 1
            self.dmcSampleLength = lshift(value, 4) + 1
        end

    elseif addr == 0x15 then
        -- $4015 通道使能写
        local prevPulse1   = self.channelEnable.pulse1
        local prevPulse2   = self.channelEnable.pulse2
        local prevTriangle = self.channelEnable.triangle

        self.channelEnable.pulse1   = band(value, 0x01) ~= 0
        self.channelEnable.pulse2   = band(value, 0x02) ~= 0
        self.channelEnable.triangle = band(value, 0x04) ~= 0
        self.channelEnable.noise    = band(value, 0x08) ~= 0
        self.channelEnable.dmc      = band(value, 0x10) ~= 0

        -- 被禁用的通道: 长度计数器归零 + 清除当前音高
        if not self.channelEnable.pulse1 then
            self.lengthCounter.pulse1 = 0
            if prevPulse1 then self:_muteChannel("pulse1") end
        end
        if not self.channelEnable.pulse2 then
            self.lengthCounter.pulse2 = 0
            if prevPulse2 then self:_muteChannel("pulse2") end
        end
        if not self.channelEnable.triangle then
            self.lengthCounter.triangle = 0
            if prevTriangle then self:_muteChannel("triangle") end
        end
        if not self.channelEnable.noise then
            self.lengthCounter.noise = 0
        end

        -- 禁用 DMC: 清空 bytesRemaining; 启用 DMC 且 bytesRemaining=0 则重启
        if not self.channelEnable.dmc then
            self.dmcBytesRemaining = 0
        else
            if self.dmcBytesRemaining == 0 then
                self:_dmcRestart()
            end
        end

        self.dmcIRQPending = false

    elseif addr == 0x17 then
        -- $4017: 帧计数器 + 控制器2 选通
        self.frameIRQEnabled = band(value, 0x40) == 0
        self.frameMode5Step  = band(value, 0x80) ~= 0

        if not self.frameIRQEnabled then
            self.frameIRQPending = false
        end

        if self.frameMode5Step then
            self._frameSeqWriteNextCycle = true
        end
    end
end

-- ============================================================================
-- 寄存器读取
-- ============================================================================
function APU:read(addr)
    addr = band(addr, 0x1F)

    if addr == 0x15 then
        local result = 0
        if self.lengthCounter.pulse1   > 0 then result = bor(result, 0x01) end
        if self.lengthCounter.pulse2   > 0 then result = bor(result, 0x02) end
        if self.lengthCounter.triangle > 0 then result = bor(result, 0x04) end
        if self.lengthCounter.noise    > 0 then result = bor(result, 0x08) end
        if self.dmcBytesRemaining      > 0 then result = bor(result, 0x10) end
        result = bor(result, 0x20)

        if self.frameIRQPending then
            result = bor(result, 0x40)
        end
        if self.dmcIRQPending then
            result = bor(result, 0x80)
        end

        self.frameIRQPending = false
        return result
    end

    if addr <= 0x13 then
        return self.regs[addr]
    end

    return 0
end

-- ============================================================================
-- 推进 APU 时钟 (CPU 每执行一条指令后调用)
-- @param cpuCycles: 上一条 CPU 指令消耗的周期数
-- ============================================================================
function APU:advanceCycles(cpuCycles)
    self:_advanceFrameCounter(cpuCycles)

    if self.dmcBytesRemaining > 0 then
        self:_advanceDMC(cpuCycles)
    end
end

-- ============================================================================
-- 帧计数器
-- ============================================================================
function APU:_advanceFrameCounter(cycles)
    if self._frameSeqWriteNextCycle then
        self._frameSeqWriteNextCycle = false
        self:_clockFrameStep()
    end

    self.frameCycle = self.frameCycle + cycles

    local periods = self.frameMode5Step and FRAME_PERIOD_5STEP or FRAME_PERIOD_4STEP
    local totalSteps = self.frameMode5Step and 5 or 4

    while self.frameStep < totalSteps and self.frameCycle >= periods[self.frameStep + 1] do
        self:_clockFrameStep()
    end

    if self.frameStep >= totalSteps then
        self.frameCycle = self.frameCycle - periods[totalSteps]
        self.frameStep = 0

        while self.frameStep < totalSteps and self.frameCycle >= periods[self.frameStep + 1] do
            self:_clockFrameStep()
        end
    end
end

function APU:_clockFrameStep()
    local prevStep = self.frameStep
    self.frameStep = self.frameStep + 1

    if self.frameMode5Step then
        if prevStep == 0 or prevStep == 2 then
            self:_clockEnvelopes()
        end
        if prevStep == 1 or prevStep == 4 then
            self:_clockLengthCountersAndMute()
        end
    else
        if prevStep == 0 then
            self:_clockEnvelopes()
        elseif prevStep == 1 then
            self:_clockEnvelopes()
            self:_clockLengthCountersAndMute()
        elseif prevStep == 2 then
            self:_clockEnvelopes()
        elseif prevStep == 3 then
            self:_clockEnvelopes()
            self:_clockLengthCountersAndMute()
            if self.frameIRQEnabled then
                self.frameIRQPending = true
            end
        end
    end
end

-- 时钟包络 (简化: 不做实际包络衰减,仅保持接口兼容)
function APU:_clockEnvelopes()
end

-- 时钟长度计数器 + 自动静音 (长度归零时清除音高记录)
function APU:_clockLengthCountersAndMute()
    local lc = self.lengthCounter
    if lc.pulse1 > 0 then
        lc.pulse1 = lc.pulse1 - 1
        if lc.pulse1 == 0 then self:_muteChannel("pulse1") end
    end
    if lc.pulse2 > 0 then
        lc.pulse2 = lc.pulse2 - 1
        if lc.pulse2 == 0 then self:_muteChannel("pulse2") end
    end
    if lc.triangle > 0 then
        lc.triangle = lc.triangle - 1
        if lc.triangle == 0 then self:_muteChannel("triangle") end
    end
    if lc.noise > 0 then
        lc.noise = lc.noise - 1
    end
end

-- ============================================================================
-- DMC 通道推进
-- ============================================================================
function APU:_advanceDMC(cycles)
    if self.dmcBytesRemaining <= 0 then
        return
    end

    self.dmcCycle = self.dmcCycle + cycles

    while self.dmcCycle >= self.dmcRateCycles and self.dmcBytesRemaining > 0 do
        self.dmcCycle = self.dmcCycle - self.dmcRateCycles

        if self.dmcBufferEmpty then
            if self.dmcCurBytes > 0 then
                local sample = self:_dmcReadMemory(self.dmcCurAddr)
                self.dmcSampleBuffer = sample
                self.dmcBufferEmpty = false
                self.dmcCurAddr = band((self.dmcCurAddr + 1), 0xFFFF)
                self.dmcCurBytes = self.dmcCurBytes - 1
                self.dmcBytesRemaining = self.dmcBytesRemaining - 1
            end

            if self.dmcCurBytes == 0 then
                if self.dmcBytesRemaining > 0 then
                    self.dmcCurAddr = self.dmcSampleAddr
                    self.dmcCurBytes = self.dmcSampleLength
                else
                    if self.dmcLoop then
                        self.dmcCurAddr = self.dmcSampleAddr
                        self.dmcCurBytes = self.dmcSampleLength
                        self.dmcBytesRemaining = self.dmcSampleLength
                    else
                        self.dmcBytesRemaining = 0
                        if self.dmcIRQEnabled then
                            self.dmcIRQPending = true
                        end
                    end
                end
            end
        else
            self.dmcBufferEmpty = true
        end
    end
end

-- ============================================================================
-- DMC 内存读取 (从 PRG ROM 区域读取,走 mapper 路径)
-- ============================================================================
function APU:_dmcReadMemory(addr)
    if self.nes then
        return self.nes:memoryMapperLoad(addr)
    end
    return 0
end

-- ============================================================================
-- DMC 重启
-- ============================================================================
function APU:_dmcRestart()
    self.dmcCurAddr   = self.dmcSampleAddr
    self.dmcCurBytes  = self.dmcSampleLength
    self.dmcBytesRemaining = self.dmcSampleLength
    self.dmcCycle     = 0
    self.dmcBufferEmpty = true
    self.dmcSampleBuffer = 0
    self.dmcSilence   = false
end

-- ============================================================================
-- 获取中断状态
-- ============================================================================
function APU:hasIRQ()
    return self.frameIRQPending or self.dmcIRQPending
end

-- ============================================================================
-- 获取音频采样 (不再使用,保留接口兼容)
-- ============================================================================
function APU:getSample()
    return 0
end