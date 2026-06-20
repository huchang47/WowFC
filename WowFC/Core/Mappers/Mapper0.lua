-- Mapper0.lua
-- NROM Mapper (Mapper 0)
-- 最简单的 mapper，没有 bank 切换

-- 性能:把 BitOps 去掉,直接用 bit 库。Mapper0:load 在每条 PRG 指令读时被调用。
local band = bit.band
local function toU8(v) return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

-- 创建全局 Mapper0 表
_G.Mapper0 = {}
Mapper0.__index = Mapper0

function Mapper0:new(nes, rom)
    local mapper = setmetatable({}, self)
    mapper.nes = nes
    mapper.rom = rom
    
    if rom then
        nes.ppu:setMirroring(rom:getMirroringType())
        mapper._prgSize = (rom.romCount or 1) * 0x4000
    end
    
    return mapper
end

function Mapper0:reset()
    -- NROM 不需要重置
end

-- 为 CPU 构建 0x8000-0xFFFF 的 PRG 直读视图(扁平数组,以完整地址为下标)。
-- NROM 不做 bank 切换,PRG 加载后恒定,故视图一次铺好永久有效。
-- cpuLoad 命中此表即可跳过 nes:memoryMapperLoad + mmap:load 两层 method。
-- 镜像规则与 Mapper0:load 完全一致(16KB→&0x3FFF, 32KB→&0x7FFF),保证画面不变。
function Mapper0:buildCpuFastPath(cpu)
    local prg = self.rom and self.rom.rom
    if not prg then return end
    local mask = (self._prgSize and self._prgSize <= 0x4000) and 0x3FFF or 0x7FFF
    local direct = {}
    for a = 0x8000, 0xFFFF do
        direct[a] = prg[band(a, mask)] or 0
    end
    cpu.prgDirect = direct
end

function Mapper0:write(address, value)
    address = toU16(address)
    value = toU8(value)
    
    -- NROM 不支持 bank 切换，写入被忽略
    -- 但某些游戏可能会写入，我们静默忽略
end

function Mapper0:load(address)
    address = toU16(address)
    
    if address >= 0x8000 then
        local romOffset
        if self._prgSize <= 0x4000 then
            romOffset = band(address, 0x3FFF)
        else
            romOffset = band(address, 0x7FFF)
        end
        
        return self.rom.rom[romOffset] or 0
    end
    
    return 0
end

function Mapper0:regLoad(address)
    return self:load(address)
end

function Mapper0:regWrite(address, value)
    self:write(address, value)
end

function Mapper0:loadVRAM(address)
    address = band(address, 0x3FFF)
    
    if address >= 0x2000 and address < 0x3F00 then
        -- 名称表区域
        return self.nes.ppu:readVRAM(address)
    elseif address >= 0x3F00 then
        -- 调色板区域
        return self.nes.ppu:readVRAM(address)
    elseif address < 0x2000 then
        -- Pattern Table (CHR ROM)
        if self.rom.vrom then
            local value = self.rom.vrom[address]
            if value == nil then
                return 0
            end
            return value
        end
    end
    
    return 0
end

function Mapper0:writeVRAM(address, value)
    address = band(address, 0x3FFF)
    value = toU8(value)
    
    if address >= 0x2000 and address < 0x3F00 then
        -- 名称表区域
        self.nes.ppu:writeVRAM(address, value)
    elseif address >= 0x3F00 then
        -- 调色板区域
        self.nes.ppu:writeVRAM(address, value)
    elseif address < 0x2000 then
        -- Pattern Table (CHR RAM)
        if self.rom.vrom and self.rom.vromCount == 0 then
            -- CHR RAM 可写
            self.rom.vrom[address] = value
        end
    end
end

function Mapper0:clockIrqCounter()
    -- NROM 没有 IRQ 计数器
end

function Mapper0:loadState(state)
    -- NROM 没有需要保存的状态
end

function Mapper0:saveState()
    return {}
end

return Mapper0
