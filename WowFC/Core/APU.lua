-- APU.lua
-- APU (Audio Processing Unit) 音频处理单元 — 最小化模拟
-- ============================================================================
-- 说明: WoW 插件无法输出实时音频,因此本模块只模拟寄存器接口,
--       确保依赖 APU 寄存器的游戏(尤其是读取 $4015 状态、使用 DMC IRQ、
--       依赖帧计数器定时)不会因返回值异常而卡死或逻辑错误。
--
-- 实现内容:
--   1. 全部 APU 寄存器的读写 ($4000-$4013, $4015, $4017)
--   2. $4015 状态字(通道使能/长度计数、中断标志)
--   3. 帧计数器(4-step / 5-step 模式,影响长度计数器和包络)
--   4. DMC 通道(DPCM IRQ 支持,部分 MMC3 游戏分屏必须)
--
-- 不做的事:
--   - 不生成实际音频采样(无法在 WoW 内播放)
--   - 不模拟方波/三角波/噪声的频率生成(对游戏逻辑无影响)
-- ============================================================================

local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

-- DMC 速率表: 速率索引 → CPU 周期/采样 (NTSC)
local DMC_RATE_TABLE = {
    428, 380, 340, 320, 286, 254, 226, 214,
    190, 160, 142, 128, 106,  84,  72,  54
}

-- 帧计数器 4-step 周期表: 每个 step 对应的 CPU 周期(基于 NTSC 1.79MHz / 240Hz)
-- 4-step: 7457, 14914, 22371, 29828  (step 4 触发 IRQ)
-- 5-step: 7457, 14914, 22371, 29829, 37281 (step 4 无 IRQ)
local FRAME_PERIOD_4STEP = { 7457, 14914, 22371, 29828 }
local FRAME_PERIOD_5STEP = { 7457, 14914, 22371, 29829, 37281 }

-- 创建全局 APU 表
_G.APU = {}
APU.__index = APU

-- ============================================================================
-- 构造函数
-- ============================================================================
function APU:new(nes)
    local apu = setmetatable({}, self)
    apu.nes = nes

    -- 寄存器镜像 ($4000-$4013 每个通道 4 字节)
    -- pulse1: $4000-$4003
    -- pulse2: $4004-$4007
    -- triangle: $4008-$400B
    -- noise: $400C-$400F
    -- dmc: $4010-$4013
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
    apu.frameIRQEnabled  = true   -- $4017 bit6: 0=允许, 1=禁止
    apu.frameIRQPending  = false  -- 是否有待处理的 IRQ
    apu.frameMode5Step   = false  -- $4017 bit7: 0=4-step, 1=5-step
    apu.frameCycle       = 0      -- 当前帧周期内累计 CPU cycle
    apu.frameStep        = 0      -- 当前 step (0-based)
    apu._frameSeqWriteNextCycle = false  -- 5-step 模式下写入后立即 clock

    -- DMC 通道
    apu.dmcIRQEnabled    = false  -- $4010 bit7
    apu.dmcIRQPending    = false
    apu.dmcLoop          = false  -- $4010 bit6
    apu.dmcRateIndex     = 0      -- $4010 bits 0-3
    apu.dmcOutputLevel   = 0      -- $4011
    apu.dmcSampleAddr    = 0      -- $4012 → 实际地址 = $C000 + value*64
    apu.dmcSampleLength  = 0      -- $4013 → 实际长度 = value*16 + 1
    apu.dmcBytesRemaining = 0     -- 剩余采样字节数 (>0 表示正在播放)
    apu.dmcCurAddr       = 0      -- 当前读取地址
    apu.dmcCurBytes      = 0      -- 当前剩余字节
    apu.dmcCycle         = 0      -- 当前采样间隔累计 CPU cycle
    apu.dmcRateCycles    = 0      -- 当前速率对应的 CPU 周期
    apu.dmcSampleBuffer  = 0      -- 采样缓冲区 (1 bit)
    apu.dmcSilence       = false  -- 静音标志
    apu.dmcBufferEmpty   = true   -- 缓冲区为空

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
end

-- ============================================================================
-- 寄存器写入 ($4000-$4013, $4015, $4017)
-- ============================================================================
function APU:write(addr, value)
    addr = band(addr, 0x1F)  -- $4000-$401F 镜像

    if addr <= 0x13 then
        self.regs[addr] = value

        if addr == 0x03 then
            -- Pulse1 长度计数器加载
            if self.channelEnable.pulse1 then
                self.lengthCounter.pulse1 = LENGTH_TABLE[rshift(value, 3)]
            end
        elseif addr == 0x07 then
            -- Pulse2 长度计数器加载
            if self.channelEnable.pulse2 then
                self.lengthCounter.pulse2 = LENGTH_TABLE[rshift(value, 3)]
            end
        elseif addr == 0x0B then
            -- Triangle 长度计数器加载
            if self.channelEnable.triangle then
                self.lengthCounter.triangle = LENGTH_TABLE[rshift(value, 3)]
            end
        elseif addr == 0x0F then
            -- Noise 长度计数器加载
            if self.channelEnable.noise then
                self.lengthCounter.noise = LENGTH_TABLE[rshift(value, 3)]
            end
        elseif addr == 0x10 then
            -- DMC 控制
            self.dmcIRQEnabled = band(value, 0x80) ~= 0
            self.dmcLoop       = band(value, 0x40) ~= 0
            self.dmcRateIndex  = band(value, 0x0F)
            self.dmcRateCycles = DMC_RATE_TABLE[self.dmcRateIndex + 1] or DMC_RATE_TABLE[1]

            -- 如果 IRQ 被禁止,清除 pending
            if not self.dmcIRQEnabled then
                self.dmcIRQPending = false
            end

        elseif addr == 0x11 then
            -- DMC DAC (直出): 只更新内部电平,不实际出音频
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
        self.channelEnable.pulse1   = band(value, 0x01) ~= 0
        self.channelEnable.pulse2   = band(value, 0x02) ~= 0
        self.channelEnable.triangle = band(value, 0x04) ~= 0
        self.channelEnable.noise    = band(value, 0x08) ~= 0
        self.channelEnable.dmc      = band(value, 0x10) ~= 0

        -- 被禁用的通道,长度计数器归零
        if not self.channelEnable.pulse1   then self.lengthCounter.pulse1   = 0 end
        if not self.channelEnable.pulse2   then self.lengthCounter.pulse2   = 0 end
        if not self.channelEnable.triangle then self.lengthCounter.triangle = 0 end
        if not self.channelEnable.noise    then self.lengthCounter.noise    = 0 end

        -- 禁用 DMC: 清空 bytesRemaining; 启用 DMC 且 bytesRemaining=0 则重启
        if not self.channelEnable.dmc then
            self.dmcBytesRemaining = 0
        else
            if self.dmcBytesRemaining == 0 then
                self:_dmcRestart()
            end
        end

        -- DMC IRQ pending 在启用 DMC 时清除
        self.dmcIRQPending = false

    elseif addr == 0x17 then
        -- $4017: 帧计数器 + 控制器2 选通
        -- bit 6: IRQ inhibit (1 = 禁止帧中断)
        -- bit 7: 模式 (0 = 4-step, 1 = 5-step)
        self.frameIRQEnabled = band(value, 0x40) == 0
        self.frameMode5Step  = band(value, 0x80) ~= 0

        -- 如果禁止帧中断,清除 pending
        if not self.frameIRQEnabled then
            self.frameIRQPending = false
        end

        -- 5-step 模式写入后立即 clock sequencer
        if self.frameMode5Step then
            self._frameSeqWriteNextCycle = true
        end

        -- 奇数周期写入 5-step 模式会立即 clock length + sweep
        -- (简化: 标记下一周期执行)
    end
end

-- ============================================================================
-- 寄存器读取
-- ============================================================================
function APU:read(addr)
    addr = band(addr, 0x1F)

    if addr == 0x15 then
        -- $4015 状态寄存器
        -- bit 0: pulse1 长度 > 0
        -- bit 1: pulse2 长度 > 0
        -- bit 2: triangle 长度 > 0
        -- bit 3: noise 长度 > 0
        -- bit 4: dmc 剩余字节 > 0
        -- bit 5: (未使用,始终 1)
        -- bit 6: 帧中断标志 (读后清除)
        -- bit 7: DMC 中断标志 (读后清除)
        local result = 0
        if self.lengthCounter.pulse1   > 0 then result = bor(result, 0x01) end
        if self.lengthCounter.pulse2   > 0 then result = bor(result, 0x02) end
        if self.lengthCounter.triangle > 0 then result = bor(result, 0x04) end
        if self.lengthCounter.noise    > 0 then result = bor(result, 0x08) end
        if self.dmcBytesRemaining      > 0 then result = bor(result, 0x10) end
        -- bit 5: 始终为 1 (未使用位, 符合 NES 行为)
        result = bor(result, 0x20)

        if self.frameIRQPending then
            result = bor(result, 0x40)
        end
        if self.dmcIRQPending then
            result = bor(result, 0x80)
        end

        -- 读后清除帧中断标志
        self.frameIRQPending = false

        return result
    end

    -- 其他 APU 寄存器读: 大部分返回 open bus 或上次写入值
    -- 简化: 返回写入值镜像
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
    -- 帧计数器推进
    self:_advanceFrameCounter(cpuCycles)

    -- DMC 通道推进
    if self.dmcBytesRemaining > 0 then
        self:_advanceDMC(cpuCycles)
    end
end

-- ============================================================================
-- 帧计数器
-- ============================================================================
function APU:_advanceFrameCounter(cycles)
    -- 5-step 模式写入后立即时钟: 在当前周期内触发一次 step clock
    if self._frameSeqWriteNextCycle then
        self._frameSeqWriteNextCycle = false
        self:_clockFrameStep()
    end

    self.frameCycle = self.frameCycle + cycles

    local periods = self.frameMode5Step and FRAME_PERIOD_5STEP or FRAME_PERIOD_4STEP
    local totalSteps = self.frameMode5Step and 5 or 4

    -- 检查是否跨越了一个或多个 step 边界
    while self.frameStep < totalSteps and self.frameCycle >= periods[self.frameStep + 1] do
        self:_clockFrameStep()
    end

    -- 如果完成了所有 step,重置到下一帧序列
    if self.frameStep >= totalSteps then
        self.frameCycle = self.frameCycle - periods[totalSteps]
        self.frameStep = 0

        -- 继续处理溢出后的 step
        while self.frameStep < totalSteps and self.frameCycle >= periods[self.frameStep + 1] do
            self:_clockFrameStep()
        end
    end
end

function APU:_clockFrameStep()
    local prevStep = self.frameStep
    self.frameStep = self.frameStep + 1

    local totalSteps = self.frameMode5Step and 5 or 4

    if self.frameMode5Step then
        -- 5-step mode
        if prevStep == 0 or prevStep == 2 then
            self:_clockEnvelopes()
        end
        if prevStep == 1 or prevStep == 4 then
            self:_clockLengthCounters()
        end
        -- step 3 没有时钟事件
        -- 5-step 模式不触发帧中断
    else
        -- 4-step mode
        if prevStep == 0 then
            -- quarter frame: envelope
            self:_clockEnvelopes()
        elseif prevStep == 1 then
            -- half frame: envelope + length + sweep
            self:_clockEnvelopes()
            self:_clockLengthCounters()
        elseif prevStep == 2 then
            -- quarter frame: envelope
            self:_clockEnvelopes()
        elseif prevStep == 3 then
            -- half frame: envelope + length + sweep + IRQ
            self:_clockEnvelopes()
            self:_clockLengthCounters()
            -- 触发帧中断
            if self.frameIRQEnabled then
                self.frameIRQPending = true
            end
        end
    end

    -- 5-step 模式仅在 step 0/1/2/4 有时钟事件
    -- 检查帧中断 (仅在 4-step mode 的 step 3)
end

-- 时钟包络 (简化: 不做实际包络衰减,仅保持接口兼容)
function APU:_clockEnvelopes()
    -- 不做频率/音量计算,只占位
end

-- 时钟长度计数器
function APU:_clockLengthCounters()
    local lc = self.lengthCounter
    if lc.pulse1 > 0 then
        lc.pulse1 = lc.pulse1 - 1
    end
    if lc.pulse2 > 0 then
        lc.pulse2 = lc.pulse2 - 1
    end
    if lc.triangle > 0 then
        lc.triangle = lc.triangle - 1
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
            -- 从 PRG ROM 读取下一个采样字节
            if self.dmcCurBytes > 0 then
                local sample = self:_dmcReadMemory(self.dmcCurAddr)
                self.dmcSampleBuffer = sample
                self.dmcBufferEmpty = false
                self.dmcCurAddr = band((self.dmcCurAddr + 1), 0xFFFF)
                self.dmcCurBytes = self.dmcCurBytes - 1
                self.dmcBytesRemaining = self.dmcBytesRemaining - 1
            end

            if self.dmcCurBytes == 0 then
                -- 当前段读完
                if self.dmcBytesRemaining > 0 then
                    -- 还有更多数据: 重载地址和长度
                    self.dmcCurAddr = self.dmcSampleAddr
                    self.dmcCurBytes = self.dmcSampleLength
                else
                    -- 全部读完
                    if self.dmcLoop then
                        -- Loop: 重载并继续
                        self.dmcCurAddr = self.dmcSampleAddr
                        self.dmcCurBytes = self.dmcSampleLength
                        self.dmcBytesRemaining = self.dmcSampleLength
                    else
                        -- 非 Loop: 结束
                        self.dmcBytesRemaining = 0
                        -- 触发 DMC IRQ
                        if self.dmcIRQEnabled then
                            self.dmcIRQPending = true
                        end
                    end
                end
            end
        else
            -- 处理采样缓冲区 (bit-by-bit 输出)
            -- 简化: 不模拟 delta 调制,直接清空缓冲区
            self.dmcBufferEmpty = true
        end
    end
end

-- ============================================================================
-- DMC 内存读取 (从 PRG ROM 区域读取,走正常的 mapper 路径)
-- ============================================================================
function APU:_dmcReadMemory(addr)
    -- DMC 读取地址范围: $8000-$FFFF (PRG ROM)
    -- 通过 nes 的内存映射器读取,这样 mapper 可以正确处理 bank 切换
    if self.nes then
        return self.nes:memoryMapperLoad(addr)
    end
    return 0
end

-- ============================================================================
-- DMC 重启: 从 $4012/$4013 加载地址和长度,开始播放
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
-- 获取中断状态: 返回是否应该向 CPU 触发 IRQ
-- ============================================================================
function APU:hasIRQ()
    return self.frameIRQPending or self.dmcIRQPending
end

-- ============================================================================
-- 获取音频采样 (占位, WoW 不处理)
-- ============================================================================
function APU:getSample()
    return 0
end