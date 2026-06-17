-- Mapper2.lua
-- UNROM / UOROM (mapper 2)
-- 参考:NESdev wiki "UxROM" 与 jsnes mapper002
--
-- 概览:
--   PRG-ROM:128KB(UNROM,8 bank)或 256KB(UOROM,16 bank)。每个 bank 16K。
--   CHR:8KB CHR-RAM(几乎所有 UxROM 卡带都没有 CHR-ROM)。
--   PRG-RAM:无。
--   IRQ:无。
--   mirroring:由 ROM 头硬接线决定,不可由游戏运行时切换。
--
-- 寄存器:写 $8000-$FFFF 任意地址 → bank# = value & 0x0F。
--   $8000:可切换的 16K bank
--   $C000:固定为最后一个 bank
--
-- 著名游戏:魂斗罗、赤色要塞、Mega Man 1、忍者龙剑传 1。

local band = bit.band
local function toU8(v)  return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

_G.Mapper2 = {}
Mapper2.__index = Mapper2

function Mapper2:new(nes, rom)
    local m = setmetatable({}, self)
    m.nes = nes
    m.rom = rom

    m._prgBank = 0
    m._prgBankCount = rom.romCount or 1
    m._prgLastBankOffset = (m._prgBankCount - 1) * 0x4000

    -- UxROM 默认 CHR-RAM 8K(vromCount=0)。极少数变种带 CHR-ROM,本实现按线性 8K 处理。
    m._isChrRam = (rom.vromCount or 0) == 0

    -- mirroring 由 ROM 头决定,设一次后就不再变
    nes.ppu:setMirroring(rom:getMirroringType())

    return m
end

function Mapper2:reset()
    self._prgBank = 0
end

function Mapper2:write(address, value)
    address = toU16(address)
    value = toU8(value)

    if address < 0x8000 then
        return
    end

    -- bank 选择:取低 4 位,大多数 UNROM 用低 3 位,UOROM 用低 4 位。
    -- 直接 & 0x0F 兼容两种,bank 索引超过实际 bank 数时用模回绕。
    local newBank = band(value, 0x0F) % self._prgBankCount
    self._prgBank = newBank
end

function Mapper2:load(address)
    address = toU16(address)

    if address < 0x8000 then
        -- $6000-$7FFF 没有 PRG-RAM,返回 0(open bus 简化)
        return 0
    end

    if address < 0xC000 then
        -- $8000-$BFFF:可切换 bank
        return self.rom.rom[self._prgBank * 0x4000 + (address - 0x8000)] or 0
    end

    -- $C000-$FFFF:固定最后 bank
    return self.rom.rom[self._prgLastBankOffset + (address - 0xC000)] or 0
end

function Mapper2:regLoad(address)  return self:load(address) end
function Mapper2:regWrite(address, value) self:write(address, value) end

function Mapper2:loadVRAM(address)
    address = band(address, 0x3FFF)
    if address < 0x2000 then
        return self.rom.vrom[address] or 0
    end
    return self.nes.ppu:readVRAM(address)
end

function Mapper2:writeVRAM(address, value)
    address = band(address, 0x3FFF)
    value = toU8(value)
    if address < 0x2000 then
        if self._isChrRam then
            -- CHR-RAM 写入需要让 PPU tile 缓存失效
            if self.rom.vrom[address] ~= value then
                self.rom.vrom[address] = value
                self.nes.ppu:invalidateChrCache()
            end
        end
        return
    end
    self.nes.ppu:writeVRAM(address, value)
end

function Mapper2:clockIrqCounter()
    -- UxROM 没有 IRQ
end

function Mapper2:loadState(state)
    if not state then return end
    self._prgBank = state.prgBank or 0
end

function Mapper2:saveState()
    return { prgBank = self._prgBank }
end

return Mapper2
