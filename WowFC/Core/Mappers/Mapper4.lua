-- Mapper4.lua
-- MMC3 (TxROM 等) mapper
-- 参考:NESdev wiki "MMC3" 与 jsnes mapper004
--
-- 概览:
--   PRG-ROM:最多 512KB(64 个 8K bank)。本实现按 8K bank 索引线性映射,够用。
--   CHR:最多 256KB(256 个 1K bank);0 → CHR-RAM 8K
--   PRG-RAM:8KB($6000-$7FFF),写保护位本实现忽略
--   IRQ:每根可见 scanline tick 一次(由 PPU 的 endScanline 钩子触发)
--
-- 寄存器组(按地址 bit13 + bit0 区分,$8000-$FFFF 偶数地址 / 奇数地址各管一组):
--   $8000 偶 (bank select):  D7=CHR mode  D6=PRG mode  D2-D0=R 索引(0..7)
--   $8001 奇 (bank data):    数据写到上次 $8000 选中的 R
--   $A000 偶 (mirroring):    D0=0 vertical / 1 horizontal  (4-screen 时忽略)
--   $A001 奇 (PRG-RAM 保护): 本实现忽略
--   $C000 偶 (IRQ latch):    设 reload 值
--   $C001 奇 (IRQ reload):   下个 tick 强制 reload
--   $E000 偶 (IRQ disable):  禁用 + ack 待发的 IRQ
--   $E001 奇 (IRQ enable):   启用
--
-- PRG 布局(D6 of $8000):
--   D6=0:  $8000=R6   $A000=R7   $C000=倒数第 2 bank(固定)   $E000=最后 bank(固定)
--   D6=1:  $8000=倒数第 2 bank(固定)   $A000=R7   $C000=R6   $E000=最后 bank(固定)
--
-- CHR 布局(D7 of $8000):
--   D7=0:  $0000-$07FF=R0(2K)  $0800-$0FFF=R1(2K)  $1000-$13FF=R2  $1400-$17FF=R3
--          $1800-$1BFF=R4      $1C00-$1FFF=R5
--   D7=1:  $0000-$03FF=R2  $0400-$07FF=R3  $0800-$0BFF=R4  $0C00-$0FFF=R5
--          $1000-$17FF=R0(2K)   $1800-$1FFF=R1(2K)
--
-- IRQ 行为:
--   counter 初值未指定。每个 PPU A12 上升沿(本实现按 scanline tick):
--     如果 counter==0 或 reload 标志被置:counter = latch,清 reload 标志。
--     否则:counter -= 1。
--     tick 后如果 counter==0 且 enabled:触发 CPU IRQ。
--   $C000 写入只设 latch,不立刻影响 counter。
--   $C001 写入设 reload 标志(下次 tick 强制 reload)。
--   $E000 写入禁用 + ack。
--   $E001 写入启用。
--
-- 简化点:本实现按 scanline 边界 tick,真机是 PPU A12 上升沿。少数 raster
-- 极端依赖的游戏(Battletoads 等)在 split-screen 处可能有抖动,SMB3 / 洛克人 3-6 /
-- Kirby's Adventure / 松鼠大战 等经典游戏在简化下应能正常运行。

local band   = bit.band
local bor    = bit.bor
local rshift = bit.rshift
local function toU8(v)  return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

_G.Mapper4 = {}
Mapper4.__index = Mapper4

function Mapper4:new(nes, rom)
    local m = setmetatable({}, self)
    m.nes = nes
    m.rom = rom

    -- bank select 寄存器($8000 偶)
    m._bankSelect = 0

    -- 8 个 R 寄存器(R0/R1 单位 2K,R2-R5 单位 1K,R6/R7 单位 8K)
    m._R = {0, 0, 0, 0, 0, 0, 0, 0}  -- 1-indexed: R[1]..R[8] 对应 R0..R7

    -- IRQ
    m._irqLatch   = 0
    m._irqCounter = 0
    m._irqReload  = false
    m._irqEnabled = false

    -- PRG-RAM 8K
    m._prgRam = Buffer.newU8(0x2000, 0)

    -- 缓存:总 PRG 8K bank 数(romCount 是 16K bank,× 2)
    m._prg8KCount = (rom.romCount or 1) * 2

    -- CHR:vromCount=0 时是 CHR-RAM 8K
    m._isChrRam = (rom.vromCount or 0) == 0
    m._chr1KCount = m._isChrRam and 8 or ((rom.vromCount or 0) * 8)

    -- 镜像
    if rom.fourScreen then
        nes.ppu:setMirroring(nes.ppu.FOURSCREEN_MIRRORING)
    else
        nes.ppu:setMirroring(rom:getMirroringType())
    end

    return m
end

----------------------------------------------------------------
-- reset
----------------------------------------------------------------
function Mapper4:reset()
    self._bankSelect  = 0
    for i = 1, 8 do self._R[i] = 0 end
    self._irqLatch   = 0
    self._irqCounter = 0
    self._irqReload  = false
    self._irqEnabled = false
end

----------------------------------------------------------------
-- 写入 $6000-$FFFF
----------------------------------------------------------------
function Mapper4:write(address, value)
    address = toU16(address)
    value = toU8(value)

    if address < 0x6000 then
        return
    end

    if address < 0x8000 then
        -- PRG-RAM
        self._prgRam[address - 0x6000] = value
        return
    end

    -- $8000-$FFFF:偶/奇 + 高位区段
    local even = band(address, 0x01) == 0
    local hi = band(address, 0xE000)

    if hi == 0x8000 then
        if even then
            -- bank select
            local oldMode = band(self._bankSelect, 0xC0)
            self._bankSelect = value
            if band(value, 0xC0) ~= oldMode then
                self.nes.ppu:invalidateChrCache()
            end
        else
            -- bank data
            local idx = band(self._bankSelect, 0x07) + 1
            if self._R[idx] ~= value then
                self._R[idx] = value
                if idx <= 6 then
                    self.nes.ppu:invalidateChrCache()
                end
            end
        end

    elseif hi == 0xA000 then
        if even then
            -- mirroring(4-screen 时忽略)
            if not self.rom.fourScreen then
                local ppu = self.nes.ppu
                if band(value, 0x01) == 0 then
                    ppu:setMirroring(ppu.VERTICAL_MIRRORING)
                else
                    ppu:setMirroring(ppu.HORIZONTAL_MIRRORING)
                end
            end
        end

    elseif hi == 0xC000 then
        if even then
            self._irqLatch = value
        else
            self._irqCounter = 0
            self._irqReload  = true
        end

    else  -- hi == 0xE000
        if even then
            -- disable + ack
            self._irqEnabled = false
        else
            self._irqEnabled = true
        end
    end
end

----------------------------------------------------------------
-- PRG 读取($6000-$FFFF)
----------------------------------------------------------------
function Mapper4:load(address)
    address = toU16(address)

    if address >= 0x6000 and address < 0x8000 then
        return self._prgRam[address - 0x6000] or 0
    end

    if address < 0x8000 then
        return 0
    end

    local prgMode = band(self._bankSelect, 0x40) ~= 0
    local total8K = self._prg8KCount
    local lastBank = total8K - 1
    local secondLast = total8K - 2

    -- 把 $8000-$FFFF 拆成 4 个 8K 槽
    local slot = rshift(address - 0x8000, 13)  -- 0..3
    local offsetInSlot = band(address, 0x1FFF)
    local bank

    if prgMode then
        -- D6=1 模式
        if     slot == 0 then bank = secondLast
        elseif slot == 1 then bank = band(self._R[8], 0x3F)  -- R7
        elseif slot == 2 then bank = band(self._R[7], 0x3F)  -- R6
        else                  bank = lastBank
        end
    else
        -- D6=0 模式
        if     slot == 0 then bank = band(self._R[7], 0x3F)  -- R6
        elseif slot == 1 then bank = band(self._R[8], 0x3F)  -- R7
        elseif slot == 2 then bank = secondLast
        else                  bank = lastBank
        end
    end

    -- 回绕,防止越界
    bank = bank % total8K
    return self.rom.rom[bank * 0x2000 + offsetInSlot] or 0
end

function Mapper4:regLoad(address)  return self:load(address) end
function Mapper4:regWrite(address, value) self:write(address, value) end

----------------------------------------------------------------
-- CHR 读写($0000-$1FFF)与 nametable / palette($2000+)
----------------------------------------------------------------
-- 计算 PPU 地址 → 物理 CHR 1K bank + 槽内偏移
local function chrBankFor(self, address)
    local chrMode = band(self._bankSelect, 0x80) ~= 0
    local total1K = self._chr1KCount
    local slot = rshift(address, 10)  -- 0..7,每 1K 一槽
    local offsetIn1K = band(address, 0x03FF)
    local bank

    if not chrMode then
        -- D7=0:R0/R1 占 2K 在低,R2-R5 占 1K 在高
        if slot == 0 then
            bank = band(self._R[1], 0xFE)
        elseif slot == 1 then
            bank = bor(band(self._R[1], 0xFE), 1)
        elseif slot == 2 then
            bank = band(self._R[2], 0xFE)
        elseif slot == 3 then
            bank = bor(band(self._R[2], 0xFE), 1)
        elseif slot == 4 then
            bank = self._R[3]
        elseif slot == 5 then
            bank = self._R[4]
        elseif slot == 6 then
            bank = self._R[5]
        else
            bank = self._R[6]
        end
    else
        -- D7=1:R2-R5 占 1K 在低,R0/R1 占 2K 在高
        if slot == 0 then
            bank = self._R[3]
        elseif slot == 1 then
            bank = self._R[4]
        elseif slot == 2 then
            bank = self._R[5]
        elseif slot == 3 then
            bank = self._R[6]
        elseif slot == 4 then
            bank = band(self._R[1], 0xFE)
        elseif slot == 5 then
            bank = bor(band(self._R[1], 0xFE), 1)
        elseif slot == 6 then
            bank = band(self._R[2], 0xFE)
        else
            bank = bor(band(self._R[2], 0xFE), 1)
        end
    end

    bank = bank % total1K
    return bank * 0x0400 + offsetIn1K
end

function Mapper4:loadVRAM(address)
    address = band(address, 0x3FFF)

    if address < 0x2000 then
        if self._isChrRam then
            local off = chrBankFor(self, address)
            return self.rom.vrom[off] or 0
        end
        return self.rom.vrom[chrBankFor(self, address)] or 0
    end

    return self.nes.ppu:readVRAM(address)
end

function Mapper4:writeVRAM(address, value)
    address = band(address, 0x3FFF)
    value = toU8(value)

    if address < 0x2000 then
        if self._isChrRam then
            self.rom.vrom[chrBankFor(self, address)] = value
            self.nes.ppu:invalidateChrCache()
        end
        return
    end

    self.nes.ppu:writeVRAM(address, value)
end

----------------------------------------------------------------
-- IRQ tick(由 PPU.endScanline 在每根可见扫描线调用)
----------------------------------------------------------------
function Mapper4:clockIrqCounter()
    if self._irqCounter == 0 or self._irqReload then
        self._irqCounter = self._irqLatch
        self._irqReload = false
    else
        self._irqCounter = self._irqCounter - 1
    end

    if self._irqCounter == 0 and self._irqEnabled then
        self.nes.cpu:requestIrq(self.nes.cpu.IRQ_NORMAL)
    end
end

----------------------------------------------------------------
-- 状态保存/恢复
----------------------------------------------------------------
function Mapper4:loadState(state)
    if not state then return end
    self._bankSelect = state.bankSelect or 0
    if state.R then
        for i = 1, 8 do self._R[i] = state.R[i] or 0 end
    end
    self._irqLatch   = state.irqLatch   or 0
    self._irqCounter = state.irqCounter or 0
    self._irqReload  = state.irqReload  or false
    self._irqEnabled = state.irqEnabled or false
    if state.prgRam then
        for k, v in pairs(state.prgRam) do self._prgRam[k] = v end
    end
    self.nes.ppu:invalidateChrCache()
end

function Mapper4:saveState()
    local rCopy = {}
    for i = 1, 8 do rCopy[i] = self._R[i] end
    local prgRamCopy = {}
    for i = 0, 0x1FFF do prgRamCopy[i] = self._prgRam[i] or 0 end
    return {
        bankSelect = self._bankSelect,
        R = rCopy,
        irqLatch   = self._irqLatch,
        irqCounter = self._irqCounter,
        irqReload  = self._irqReload,
        irqEnabled = self._irqEnabled,
        prgRam = prgRamCopy,
    }
end

return Mapper4
