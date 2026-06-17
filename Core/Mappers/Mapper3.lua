-- Mapper3.lua
-- CNROM (mapper 3)
-- 参考:NESdev wiki "CNROM" 与 jsnes mapper003
--
-- 概览:
--   PRG-ROM:16K 或 32K,固定不切。
--   CHR-ROM:8K × 4(标准 CNROM,32K)~ 8K × 8(扩展,64K)。整 8K 整体切换。
--   PRG-RAM:无。
--   IRQ:无。
--   mirroring:由 ROM 头硬接线决定。
--
-- 寄存器:写 $8000-$FFFF 任意地址 → CHR 8K bank# = value & 0x03
--   (本实现取 0x0F 兼容总线冲突变种 + 模回绕)
--
-- 著名游戏:坦克大战(Battle City)、Q-Bert、Donkey Kong 3、俄罗斯方块(Tengen)。

local band = bit.band
local function toU8(v)  return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

_G.Mapper3 = {}
Mapper3.__index = Mapper3

function Mapper3:new(nes, rom)
    local m = setmetatable({}, self)
    m.nes = nes
    m.rom = rom

    m._chrBank = 0
    m._chrBankCount = math.max(rom.vromCount or 1, 1)  -- 8K bank 数;0 时按 1 处理避免除 0
    m._isChrRam = (rom.vromCount or 0) == 0
    m._prgSize = (rom.romCount or 1) * 0x4000

    nes.ppu:setMirroring(rom:getMirroringType())

    return m
end

function Mapper3:reset()
    self._chrBank = 0
end

function Mapper3:write(address, value)
    address = toU16(address)
    value = toU8(value)

    if address < 0x8000 then
        return
    end

    -- 选 CHR 8K bank。低 4 位兼容扩展;模回绕避免越界。
    local newBank = band(value, 0x0F) % self._chrBankCount
    if newBank ~= self._chrBank then
        self._chrBank = newBank
        self.nes.ppu:invalidateChrCache()
    end
end

function Mapper3:load(address)
    address = toU16(address)

    if address < 0x8000 then
        return 0
    end

    -- PRG 固定:16K ROM 镜像到 $8000 + $C000;32K 直接铺开
    local off
    if self._prgSize <= 0x4000 then
        off = band(address, 0x3FFF)
    else
        off = band(address, 0x7FFF)
    end
    return self.rom.rom[off] or 0
end

function Mapper3:regLoad(address)  return self:load(address) end
function Mapper3:regWrite(address, value) self:write(address, value) end

function Mapper3:loadVRAM(address)
    address = band(address, 0x3FFF)
    if address < 0x2000 then
        if self._isChrRam then
            return self.rom.vrom[address] or 0
        end
        return self.rom.vrom[self._chrBank * 0x2000 + address] or 0
    end
    return self.nes.ppu:readVRAM(address)
end

function Mapper3:writeVRAM(address, value)
    address = band(address, 0x3FFF)
    value = toU8(value)
    if address < 0x2000 then
        -- 标准 CNROM 是 CHR-ROM,写入忽略;少数变种带 CHR-RAM
        if self._isChrRam then
            if self.rom.vrom[address] ~= value then
                self.rom.vrom[address] = value
                self.nes.ppu:invalidateChrCache()
            end
        end
        return
    end
    self.nes.ppu:writeVRAM(address, value)
end

function Mapper3:clockIrqCounter()  end

function Mapper3:loadState(state)
    if not state then return end
    self._chrBank = state.chrBank or 0
    self.nes.ppu:invalidateChrCache()
end

function Mapper3:saveState()
    return { chrBank = self._chrBank }
end

return Mapper3
