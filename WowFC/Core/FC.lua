-- FC.lua
-- 主 FC 模拟器类
-- 基于 JSNES 的 nes.js 移植

-- 注意: BitOps, Buffer, CPU, PPU, ROM, Controller 已在之前加载的文件中定义

-- 性能:把 BitOps 包装去掉,直接用 bit 库 + 局部缓存。
-- memoryMapperLoad/Write 是每条 6502 指令的访存路径,这里减重收益最大。
local band   = bit.band
local bor    = bit.bor
local bxor   = bit.bxor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local function toU8(v) return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

-- 创建全局 FC 表
_G.FC = {}
FC.__index = FC

function FC:new(opts)
    local fc = setmetatable({}, self)
    opts = opts or {}

    -- 回调函数
    fc.onFrame = opts.onFrame or function(buffer) end
    fc.onAudioSample = opts.onAudioSample
    fc.onStatusUpdate = opts.onStatusUpdate or function() end

    -- 创建核心组件
    fc.cpu = CPU:new(fc)
    fc.ppu = PPU:new(fc)
    fc.apu = APU:new(fc)
    fc.controller = Controller:new(fc)

    -- ROM 和 Mapper
    fc.rom = nil
    fc.mmap = nil

    -- 运行状态
    fc.isRunning = false
    fc.frameCount = 0
    fc.fps = 0
    fc.lastFpsTime = 0
    fc.frameTime = 0
    fc._frameInProgress = false

    -- 帧跳过:NES 内部仍跑 60fps,但每 N 帧才让渲染器 present 一次。
    -- skipN=1 每帧都画 / skipN=2 UI 30fps / skipN=3 UI 20fps...
    -- 由于 SMB1 PPU side effect(sprite 0 hit 等)由 _processNMI 直接管,
    -- 不依赖 renderFrame,所以跳过 renderFrame 不影响游戏逻辑。
    --
    -- 默认 skipN=1 不跳、不 auto:OnUpdate driver(WOWFC.lua)已接管模拟速度,
    -- 每个 NES 帧都渲染,画面最顺。动态 auto 与 OnUpdate 叠加会导致渲染帧
    -- 被多跳一层,画面发顿。需要时玩家用 /fc skip <N> 手动开。
    fc._frameSkip = 1
    fc._frameSkipCount = 0
    fc._frameSkipAuto = false       -- 默认关闭动态调节(OnUpdate 已控速)
    fc._adaptiveSampleSize = 30     -- 每 30 帧重新评估一次
    fc._adaptiveSampleCount = 0
    fc._adaptiveSampleMs = 0        -- 滑动窗口的累计 frame() 时间

    -- 内存映射 I/O 回调
    fc.cpu.mmapWrite = function(address, value)
        fc:memoryMapperWrite(address, value)
    end

    fc.cpu.mmapLoad = function(address)
        return fc:memoryMapperLoad(address)
    end

    return fc
end

function FC:reset()
    -- 重置所有组件
    self.cpu:reset()
    self.ppu:reset()
    self.apu:reset()
    self.controller:reset()

    if self.mmap then
        self.mmap:reset()
    end

    self.frameCount = 0
    self.isRunning = false
    self._frameInProgress = false
end

-- 加载 ROM
function FC:loadROM(data)
    local success, err = pcall(function()
        self.rom = ROM:new(self)
        self.rom:load(data)
        self.mmap = self.rom:createMapper()
        self:reset()
        self:_detectSmb1Hack()
    end)

    if not success then
        return false
    end

    return true
end

-- 检测 SMB1 ROM 并按需启用专属 hack。
-- 代码里有几处硬编码了 SMB1 NMI handler 的内部地址($813D / $8150)和
-- PPU 第 4/5 帧的兜底,只对 SMB1 安全。换其它游戏(尤其 MMC1/MMC3 ROM)时,
-- 这些地址会落在不同代码上,踩穿后行为不可预测。
--
-- 检测逻辑(三个条件全满足):
--   1) mapper 0 (SMB1 是 NROM)
--   2) PRG offset $013D 是 AD 02 20  (即 $813D 处 LDA $2002,Sprite0Clr 循环顶)
--   3) PRG offset $0150 是 AD 02 20  (即 $8150 处 LDA $2002,Sprite0Hit 循环顶)
-- 命中即认为是 SMB1 (含汉化版/盗版,只要 NMI handler 没改),启用 hack。
function FC:_detectSmb1Hack()
    self._smb1HackEnabled = false
    self.ppu._perScanline = false   -- 默认走快照路径(性能最优)
    if not self.rom or self.rom.mapperType ~= 0 then return end
    local prg = self.rom.rom
    if not prg then return end
    -- $813D / $8150 处是不是 LDA $2002 (AD 02 20)
    local function matchLDA2002(off)
        return prg[off] == 0xAD and prg[off + 1] == 0x02 and prg[off + 2] == 0x20
    end
    if matchLDA2002(0x013D) and matchLDA2002(0x0150) then
        self._smb1HackEnabled = true
    end
end

-- 内存映射器写入
function FC:memoryMapperWrite(address, value)
    address = toU16(address)
    value = toU8(value)

    if address < 0x2000 then
        -- 内部 RAM ($0000-$1FFF)
        -- 镜像到 $0000-$07FF
        self.cpu.mem[band(address, 0x7FF)] = value

    elseif address < 0x4000 then
        -- PPU 寄存器 ($2000-$3FFF)
        -- 镜像到 $2000-$2007
        self.ppu:write(0x2000 + band(address, 7), value)

    elseif address == 0x4014 then
        self:doOAMDMA(value)

    elseif address == 0x4015 then
        self.apu:write(0x15, value)

    elseif address == 0x4016 then
        self.controller:strobe(value)

    elseif address == 0x4017 then
        -- $4017: APU 帧计数器 (bit6-7) + 控制器2 选通 (bit0-2)
        self.apu:write(0x17, value)

    elseif address >= 0x4000 and address <= 0x4013 then
        -- APU 寄存器 ($4000-$4013)
        self.apu:write(band(address, 0x1F), value)

    elseif address >= 0x6000 and address < 0x8000 then
        -- PRG RAM（如果存在）
        if self.mmap then
            self.mmap:write(address, value)
        end

    elseif address >= 0x8000 then
        -- PRG ROM
        if self.mmap then
            self.mmap:write(address, value)
        end
    end
end

-- 内存映射器读取
function FC:memoryMapperLoad(address)
    address = toU16(address)

    if address < 0x2000 then
        -- 内部 RAM
        return self.cpu.mem[band(address, 0x7FF)] or 0

    elseif address < 0x4000 then
        -- PPU 寄存器
        return self.ppu:read(0x2000 + band(address, 7))

    elseif address == 0x4015 then
        return self.apu:read(0x15)

    elseif address == 0x4016 then
        return self.controller:read(1)

    elseif address == 0x4017 then
        return self.controller:read(2)

    elseif address >= 0x4000 and address <= 0x4013 then
        -- APU 寄存器读 ($4000-$4013)
        return self.apu:read(band(address, 0x1F))

    elseif address >= 0x6000 and address < 0x8000 then
        -- PRG RAM
        if self.mmap then
            return self.mmap:load(address)
        end
        return 0

    elseif address >= 0x8000 then
        -- PRG ROM
        if self.mmap then
            return self.mmap:load(address)
        end
        return 0
    end

    return 0
end

-- OAM DMA 传输
function FC:doOAMDMA(page)
    page = band(page, 0xFF)
    local baseAddr = lshift(page, 8)

    local oam = self.ppu.spriteMem
    local dirty = false
    for i = 0, 255 do
        local value = self:memoryMapperLoad(baseAddr + i)
        if oam[i] ~= value then
            oam[i] = value
            dirty = true
        end
    end
    -- 仅在 OAM 实际有字节变化时标 sprite dirty,SMB1 标题画面 OAM 几乎不变,
    -- 即使每帧 DMA 也不会触发重绘。
    -- 注意:这里只标 _spriteDirty,不标 BG dirty —— OAMDMA 与 BG 无关,
    -- 让 BG 命中 dirty 跳过(只要 nametable/scroll/palette 没变)。
    -- 这是当前管线最关键的优化路径:profile 显示 OAMDMA 占 99% dirty 来源。
    if dirty then
        self.ppu._spriteDirty = true
        self.ppu._dirtyFromOAMDMA = true
    end

    self.cpu.cyclesToHalt = 513
end

local MAX_CYCLES_PER_BATCH = 100000
local CYCLES_PER_FRAME = 29781  -- 约1帧的PPU周期数 (341*262/3)

----------------------------------------------------------------------------
-- 性能分析:累计统计 frame() 各阶段耗时与指令数。
-- 通过 /wowfc prof 输出,/wowfc profreset 清零。
-- 计时全部用 debugprofilestop()(WoW 高精度毫秒,与 UltraRenderer 一致)。
-- 业务逻辑零改动,只在边界处取时间戳并累加。
----------------------------------------------------------------------------
function FC:resetProfile()
    self._prof = {
        frames        = 0,    -- 已完成 NES 帧数
        frame_calls   = 0,    -- frame() 被调用次数(含未完成的)
        ms_main_loop  = 0,    -- 主 CPU+PPU 循环累计 ms(不含 NMI/render/onFrame)
        ms_nmi        = 0,    -- _processNMI 累计 ms
        ms_render     = 0,    -- ppu:renderFrame 累计 ms
        ms_present    = 0,    -- onFrame(buffer) → renderer:Render 累计 ms
        ms_total      = 0,    -- frame() 总累计 ms
        instr_main    = 0,    -- 主循环 cpu:emulate() 调用次数
        instr_nmi     = 0,    -- NMI 阶段 cpu:emulate() 调用次数
        cycles_main   = 0,    -- 主循环累计 CPU cycles
        nmi_completed = 0,    -- NMI handler 正常退出次数
        nmi_timeout   = 0,    -- NMI handler 跑到 100k 上限未退出次数
    }
    -- 同步清零 dirty 统计
    if self.ppu and self.ppu._dirtyStats then
        local ds = self.ppu._dirtyStats
        ds.framesRendered = 0
        ds.framesSkipped = 0
        ds.dirtyFromOAMDMA = 0
        ds.dirtyFromOAMDATA = 0
        ds.dirtyFromVRAM = 0
        ds.dirtyFromState = 0
    end
end

function FC:dumpProfile()
    local p = self._prof
    if not p or p.frames == 0 then
        print("|cffff0000WOWFC|r: 无 profile 数据,先跑几秒再 /fc prof")
        return
    end
    local n = p.frames
    local function avg(x) return x / n end
    print(string.format("|cff00ff00=== WOWFC Profile (frames=%d, calls=%d) ===|r",
        n, p.frame_calls))
    print(string.format("总 frame() 平均: %.2f ms/帧 (理论 60fps 上限 16.67 ms)",
        avg(p.ms_total)))
    print(string.format("  主循环   : %.2f ms (%.1f%%)  指令 %d/帧  cycles %d/帧",
        avg(p.ms_main_loop),
        avg(p.ms_main_loop) / avg(p.ms_total) * 100,
        math.floor(avg(p.instr_main)),
        math.floor(avg(p.cycles_main))))
    print(string.format("  NMI handler: %.2f ms (%.1f%%)  指令 %d/帧",
        avg(p.ms_nmi),
        avg(p.ms_nmi) / avg(p.ms_total) * 100,
        math.floor(avg(p.instr_nmi))))
    print(string.format("  PPU render : %.2f ms (%.1f%%)",
        avg(p.ms_render),
        avg(p.ms_render) / avg(p.ms_total) * 100))
    print(string.format("  Present    : %.2f ms (%.1f%%)  (UltraRenderer.Render)",
        avg(p.ms_present),
        avg(p.ms_present) / avg(p.ms_total) * 100))
    local accounted = p.ms_main_loop + p.ms_nmi + p.ms_render + p.ms_present
    print(string.format("  其它/开销 : %.2f ms (%.1f%%)",
        avg(p.ms_total - accounted),
        (p.ms_total - accounted) / p.ms_total * 100))
    print(string.format("理论可达 FPS: %.1f", 1000 / avg(p.ms_total)))
    print(string.format("|cffff8800NMI:|r 完成 %d / 超时 %d  |cffff8800帧跳过:|r skipN=%d %s",
        p.nmi_completed, p.nmi_timeout,
        self._frameSkip or 1,
        self._frameSkipAuto and "(auto)" or "(manual)"))

    -- dirty 统计:看 renderFrame 跳过率与 dirty 来源
    local ds = self.ppu and self.ppu._dirtyStats
    if ds then
        local rendered = ds.framesRendered
        local skipped  = ds.framesSkipped
        local total    = rendered + skipped
        if total > 0 then
            print(string.format("|cffff8800Render:|r 重画 %d / 跳过 %d (跳过率 %.1f%%)",
                rendered, skipped, skipped / total * 100))
            print(string.format("|cffff8800Dirty 来源:|r OAMDMA=%d OAMDATA=%d VRAM=%d State=%d",
                ds.dirtyFromOAMDMA, ds.dirtyFromOAMDATA,
                ds.dirtyFromVRAM, ds.dirtyFromState))
        end
    end
end

-- 计时辅助:debugprofilestop 在某些早期版本可能不存在,做兜底
local _profstop = debugprofilestop or function() return 0 end

function FC:frame()
    if not self.isRunning then
        return false
    end

    -- 懒初始化 profile
    if not self._prof then self:resetProfile() end
    local prof = self._prof
    prof.frame_calls = prof.frame_calls + 1
    local t_frame_start = _profstop()

    local frameCompleted = false
    local ok, err = pcall(function()
        self:clockControllers()

        if not self._frameInProgress then
            self.ppu:startFrame()
            self._frameInProgress = true
        end

        local cpu = self.cpu
        local ppu = self.ppu
        local cycleCount = 0
        local instr_count = 0
        local t_main_start = _profstop()

        -- 执行足够完成一帧的周期
        while cycleCount < CYCLES_PER_FRAME do
            if cpu.cyclesToHalt == 0 then
                local cycles = cpu:emulate()
                instr_count = instr_count + 1
                cycleCount = cycleCount + cycles

                -- 推进PPU
                local dots = cycles * 3
                ppu:advanceDots(dots)

                -- 推进APU,检查 IRQ
                self.apu:advanceCycles(cycles)
                if self.apu:hasIRQ() then
                    cpu:requestIrq(CPU.IRQ_NORMAL)
                end

                -- 优化:检测到 SMB1 EndlessLoop(JMP self),直接快进到帧结束。
                -- SMB1 主线程在 ColdBoot 末尾 jmp 自己等待 NMI,所有游戏逻辑在 NMI handler。
                -- 没这个优化,我们每帧浪费 1.5M+ JMP 指令(占总指令 70%)。
                -- 检测后直接消耗剩余 cycle 让 PPU 跑完帧 → frameEnded → 触发 NMI。
                --
                -- 逐扫描线模式只快进到"当前扫描线末"而非整帧:整帧快进会跳过逐行
                -- 渲染与 sprite0-hit / IRQ 时序。JMP self 一旦被解锁(sprite0 hit 等)
                -- 游戏会跳出循环,所以逐行快进仍能省掉行内的空转 JMP。
                if cpu._jmpSelfDetected then
                    cpu._jmpSelfDetected = false
                    if ppu._perScanline then
                        -- 推进到本扫描线末(341 dots 边界),触发 endScanline 渲染该行
                        local toLineEnd = (341 - ppu.curX)
                        if toLineEnd > 0 then
                            ppu:advanceDots(toLineEnd)
                            local consumed = math.ceil(toLineEnd / 3)
                            cpu._cpuCycleBase = cpu._cpuCycleBase + consumed
                            cycleCount = cycleCount + consumed
                            -- APU 同步推进
                            self.apu:advanceCycles(consumed)
                        end
                    else
                        local remaining = CYCLES_PER_FRAME - cycleCount
                        if remaining > 0 then
                            ppu:advanceDots(remaining * 3)
                            cycleCount = CYCLES_PER_FRAME
                            cpu._cpuCycleBase = cpu._cpuCycleBase + remaining
                            -- APU 同步推进
                            self.apu:advanceCycles(remaining)
                        end
                    end
                end

                -- 检查是否完成一帧
                if ppu.frameEnded then
                    ppu.frameEnded = false
                    self._frameInProgress = false

                    -- 主循环结束,累计统计
                    prof.ms_main_loop = prof.ms_main_loop + (_profstop() - t_main_start)
                    prof.instr_main  = prof.instr_main  + instr_count
                    prof.cycles_main = prof.cycles_main + cycleCount

                    -- 在VBlank期间先处理NMI
                    -- NMI处理程序会设置$2000/$2001/$2005等寄存器
                    local t_nmi_start = _profstop()
                    self:_processNMI()
                    prof.ms_nmi = prof.ms_nmi + (_profstop() - t_nmi_start)

                    -- 帧跳过:每 _frameSkip 帧才真正渲染 + present。
                    -- 跳过的帧仍走完整 NES 时间线(CPU/PPU/NMI 全跑),
                    -- 只省 renderFrame 和 Render 两个绘制步骤,UI 主观帧率 = 60/skipN。
                    self._frameSkipCount = self._frameSkipCount + 1
                    if self._frameSkipCount >= self._frameSkip then
                        self._frameSkipCount = 0

                        -- 然后渲染帧(此时$2001等寄存器已被NMI handler设置)
                        local t_render_start = _profstop()
                        ppu:renderFrame()
                        prof.ms_render = prof.ms_render + (_profstop() - t_render_start)

                        -- 发送帧缓冲区(UltraRenderer 实际绘制发生在这里)。
                        -- 把 ppu 自身作为元数据载体传过去,renderer 读 ppu._frameMode /
                        -- _frameUndoList / _frameNewList 决定是 skip / partial / full。
                        local t_present_start = _profstop()
                        self.onFrame(ppu.buffer, ppu)
                        prof.ms_present = prof.ms_present + (_profstop() - t_present_start)
                    end

                    -- 更新统计
                    self.frameCount = self.frameCount + 1
                    self:updateFPS()

                    -- 开始新帧
                    ppu:startFrame()
                    self._frameInProgress = true
                    frameCompleted = true

                    prof.frames = prof.frames + 1

                    -- 完成一帧就退出循环
                    break
                end
            else
                -- 处理halt周期
                local chunk = math.min(cpu.cyclesToHalt, 8)
                for i = 1, chunk do
                    ppu:advanceDots(3)
                end
                -- APU 同步推进
                self.apu:advanceCycles(chunk)
                if self.apu:hasIRQ() then
                    cpu:requestIrq(CPU.IRQ_NORMAL)
                end
                cpu.cyclesToHalt = cpu.cyclesToHalt - chunk
                cpu._cpuCycleBase = cpu._cpuCycleBase + chunk
                cycleCount = cycleCount + chunk
            end
        end

        -- 帧未完成的路径(没进上面那个 if frameEnded 分支)也要把主循环时间统计上
        if not frameCompleted then
            prof.ms_main_loop = prof.ms_main_loop + (_profstop() - t_main_start)
            prof.instr_main  = prof.instr_main  + instr_count
            prof.cycles_main = prof.cycles_main + cycleCount
        end
    end)

    local frameMs = _profstop() - t_frame_start
    prof.ms_total = prof.ms_total + frameMs

    -- 自适应帧跳过:在 auto 模式下根据实际帧耗时动态调节 skipN
    if frameCompleted then
        self:_updateAdaptiveFrameSkip(frameMs)
    end

    if not ok then
        self.isRunning = false
        self._frameInProgress = false
        print("|cffff0000WOWFC|r: 帧执行错误: " .. tostring(err))
        return false
    end

    return frameCompleted
end

-- 处理待处理的NMI（在VBlank期间运行NMI处理程序）
function FC:_processNMI()
    if not self.cpu.nmiRaised then
        return
    end

    -- 清除NMI标志，让CPU在emulate()中处理NMI
    -- 不要手动调用doNonMaskableInterrupt，否则会和CPU:emulate()中的处理冲突
    self.cpu.nmiRaised = true

    self.ppu:setStatusFlag(self.ppu.STATUS_SPRITE0HIT, false)
    self.ppu.hitSpr0 = false

    -- ----------------------------------------------------------------
    -- 退出条件:用栈指针 SP 检测 RTI(NMI 返回主代码)。
    -- 旧版用 F_INTERRUPT == 0 是错的 —— SMB1 全程 SEI,F_INTERRUPT=1。
    -- NMI 进入时 doNonMaskableInterrupt 会 push 3 字节(PC 高/低/status),
    -- 使 SP 减 3。RTI 时 pull 3 字节,SP 恢复或更高(若 NMI handler 中
    -- 又 push/pop 不平衡)。
    -- 我们记录入口时的 SP,当 SP >= 入口 SP 时认为 NMI handler 已 RTI。
    -- ----------------------------------------------------------------
    local sp_at_entry = self.cpu.REG_SP

    -- 局部缓存常用对象,减少 hash table lookup(NMI 内循环 3000+ 次)
    local cpu = self.cpu
    local ppu = self.ppu
    local SPR0 = ppu.STATUS_SPRITE0HIT

    local instrCount = 0
    local spr0HitSet = false
    local spr0HitCleared = false
    local maxIterations = 100000

    for i = 1, maxIterations do
        if cpu.cyclesToHalt > 0 then
            cpu.cyclesToHalt = cpu.cyclesToHalt - 1
            cpu._cpuCycleBase = cpu._cpuCycleBase + 1
        else
            -- ----------------------------------------------------------------
            -- SMB1 sprite 0 hit 等待循环拨快 + PC 跳过(在 emulate 之前检查 PC)。
            -- SMB1 NMI handler 两段循环(精确地址来自反汇编):
            --
            --   Sprite0Clr ($813D):  LDA $2002 / AND #$40 / BNE $813D
            --     等 SPRITE0HIT 变 0,跳回循环顶。出口在 $8144。
            --
            --   Sprite0Hit ($8150):  LDA $2002 / AND #$40 / BEQ $8150
            --     等 SPRITE0HIT 变 1,跳回循环顶。出口在 $8157。
            --
            -- 在 emulate 之前检查 PC = 入口地址,直接拨状态字 + 跳到出口,
            -- 完全跳过 LDA / AND / BNE 三条指令的循环迭代。
            -- 由于简化版 PPU 不模拟扫描线时序,实际 sprite 0 hit 永远不会被触发,
            -- 没有这个 hack 循环会无限跑。
            -- 仅对 SMB1 启用(_detectSmb1Hack 门控);其它游戏($813D/$8150
            -- 落在不同代码上)强改 PC 会让 CPU 跳飞,所以非 SMB1 直接正常 emulate。
            -- ----------------------------------------------------------------
            local pc = cpu.REG_PC
            if self._smb1HackEnabled then
                if not spr0HitCleared and pc == 0x813D then
                    -- Sprite0Clr 入口:清状态字 + 跳到 $8144(BNE 之后)
                    ppu:setStatusFlag(SPR0, false)
                    ppu.hitSpr0 = false
                    cpu.REG_PC = 0x8144
                    spr0HitCleared = true
                elseif not spr0HitSet and pc == 0x8150 then
                    -- Sprite0Hit 入口:设状态字 + 跳到 $8157(BEQ 之后)
                    ppu:setStatusFlag(SPR0, true)
                    ppu.hitSpr0 = true
                    cpu.REG_PC = 0x8157
                    spr0HitSet = true
                else
                    cpu:emulate()
                    instrCount = instrCount + 1
                end
            else
                cpu:emulate()
                instrCount = instrCount + 1
            end
        end

        if cpu.REG_SP >= sp_at_entry then
            -- NMI handler 已经 RTI 返回(SP 恢复或更高)
            break
        end
    end

    -- profile 累计
    if self._prof then
        self._prof.instr_nmi = self._prof.instr_nmi + instrCount
        if cpu.REG_SP < sp_at_entry then
            self._prof.nmi_timeout = self._prof.nmi_timeout + 1
        else
            self._prof.nmi_completed = self._prof.nmi_completed + 1
        end
    end
end

-- 控制器时钟
function FC:clockControllers()
    -- 这里可以添加控制器轮询逻辑
    -- 例如检查键盘/游戏手柄状态
end

-- 更新 FPS
function FC:updateFPS()
    local currentTime = GetTime and GetTime() or 0

    if self.lastFpsTime == 0 then
        self.lastFpsTime = currentTime
        self._fpsFrameCount = 0
    end

    self._fpsFrameCount = (self._fpsFrameCount or 0) + 1
    local elapsed = currentTime - self.lastFpsTime

    if elapsed >= 1.0 then
        self.fps = self._fpsFrameCount / elapsed
        self._fpsFrameCount = 0
        self.lastFpsTime = currentTime

        self.onStatusUpdate(string.format("FPS: %.1f", self.fps))
    end
end

-- 开始运行
function FC:start()
    self.isRunning = true
end

-- 停止运行
function FC:stop()
    self.isRunning = false
end

function FC:togglePause()
    self.isRunning = not self.isRunning
end

-- 帧跳过设置
--   n=1..10  手动模式,每 n 帧渲染 1 帧
--   "auto"   自动模式:监测帧耗时动态切换 skipN
-- NES 模拟时间线不变,只省 renderFrame + Render 两个绘制开销。
function FC:setFrameSkip(n)
    if n == "auto" or n == "AUTO" then
        self._frameSkipAuto = true
        -- 重置自适应统计,让自动模式立刻重新评估
        self._adaptiveSampleCount = 0
        self._adaptiveSampleMs = 0
        return "auto"
    end
    self._frameSkipAuto = false
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 end
    if n > 10 then n = 10 end
    self._frameSkip = n
    self._frameSkipCount = 0
    return n
end

-- 逐扫描线(cycle-accurate)渲染开关。
-- 默认关闭:绝大多数游戏用 vblank 整帧快照渲染即可,性能最优。
-- 开启后:CPU/PPU 交错推进,每条可见行用当时的滚动量/CHR bank 即时渲染,
-- 并算出真实 sprite 0 hit,可解锁少数依赖 mid-frame split / sprite0-hit 的游戏。
-- 代价:每帧整屏逐行重画,约 2x 渲染开销。SMB1(_smb1HackEnabled)忽略此开关。
function FC:setScanlineMode(on)
    if self._smb1HackEnabled then
        return false  -- SMB1 走专用整帧路径,不参与逐扫描线
    end
    self.ppu._perScanline = on and true or false
    return self.ppu._perScanline
end

function FC:getScanlineMode()
    return self.ppu and self.ppu._perScanline or false
end

-- 自适应帧跳过:在 WowFC 的瓶颈结构下(CPU 占主导,render 只 ~14%),
-- 帧跳过收益很小且会让画面卡顿。所以策略保守:
--   默认 skip=1
--   只有在帧耗时持续 > 50ms(NES 内部 fps < 20)时才升到 skip=2
--   skip=2 时只要 < 35ms 立即降回 skip=1
--   绝不超过 skip=2(再高 Mario 跑看不见,完全失去游戏体验)
function FC:_updateAdaptiveFrameSkip(frameMs)
    if not self._frameSkipAuto then return end

    self._adaptiveSampleCount = self._adaptiveSampleCount + 1
    self._adaptiveSampleMs = self._adaptiveSampleMs + frameMs

    if self._adaptiveSampleCount < self._adaptiveSampleSize then
        return
    end

    local avgMs = self._adaptiveSampleMs / self._adaptiveSampleCount
    local current = self._frameSkip
    local target = current

    if current == 1 and avgMs > 50 then
        target = 2
    elseif current == 2 and avgMs < 35 then
        target = 1
    end

    if target ~= current then
        self._frameSkip = target
        self._frameSkipCount = 0
    end
    self._adaptiveSampleCount = 0
    self._adaptiveSampleMs = 0
end

-- 设置控制器按钮状态
function FC:setButtonState(controllerNum, button, pressed)
    self.controller:setButtonState(controllerNum, button, pressed)
end

-- 获取当前帧缓冲区
function FC:getFrameBuffer()
    return self.ppu.buffer
end

-- 获取当前帧的副本
function FC:getFrameBufferCopy()
    local copy = {}
    for i = 0, 256 * 240 - 1 do
        copy[i] = self.ppu.buffer[i]
    end
    return copy
end

-- 保存状态（简化版）
function FC:saveState()
    return {
        cpu = {
            regA = self.cpu.REG_ACC,
            regX = self.cpu.REG_X,
            regY = self.cpu.REG_Y,
            regSP = self.cpu.REG_SP,
            regPC = self.cpu.REG_PC,
            regStatus = self.cpu:getStatus(),
            mem = Buffer.fromTable(self.cpu.mem)
        },
        ppu = {
            vramAddress = self.ppu.vramAddress,
            vramTmpAddress = self.ppu.vramTmpAddress,
            scanline = self.ppu.scanline,
            curX = self.ppu.curX
        },
        controller = {
            state1 = Buffer.fromTable(self.controller.state[1]),
            state2 = Buffer.fromTable(self.controller.state[2])
        },
        frameCount = self.frameCount
    }
end

-- 加载状态（简化版）
function FC:loadState(state)
    if not state then return end

    -- 恢复 CPU 状态
    if state.cpu then
        self.cpu.REG_ACC = state.cpu.regA or 0
        self.cpu.REG_X = state.cpu.regX or 0
        self.cpu.REG_Y = state.cpu.regY or 0
        self.cpu.REG_SP = state.cpu.regSP or 0x01FD
        self.cpu.REG_PC = state.cpu.regPC or 0
        self.cpu:setStatus(state.cpu.regStatus or 0x28)

        if state.cpu.mem then
            for k, v in pairs(state.cpu.mem) do
                self.cpu.mem[k] = v
            end
        end
    end

    -- 恢复 PPU 状态
    if state.ppu then
        self.ppu.vramAddress = state.ppu.vramAddress or 0
        self.ppu.vramTmpAddress = state.ppu.vramTmpAddress or 0
        self.ppu.scanline = state.ppu.scanline or 0
        self.ppu.curX = state.ppu.curX or 0
    end

    -- 恢复控制器状态
    if state.controller then
        if state.controller.state1 then
            for k, v in pairs(state.controller.state1) do
                self.controller.state[1][k] = v
            end
        end
        if state.controller.state2 then
            for k, v in pairs(state.controller.state2) do
                self.controller.state[2][k] = v
            end
        end
    end

    self.frameCount = state.frameCount or 0
end

return FC
