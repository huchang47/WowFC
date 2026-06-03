-- Mapper1.lua
-- MMC1 (SxROM) mapper
-- 参考:NESdev wiki "MMC1" 与 jsnes mapper001
--
-- 概览:
--   PRG-ROM:最多 512KB(SUROM 等大 PRG 用第 17 位扩展,本实现支持基础 256KB,
--           即 16 个 16K bank,够覆盖绝大多数游戏)
--   CHR:8KB ~ 128KB(8 个 8K bank 或 16 个 4K bank);0 → CHR-RAM 8K
--   PRG-RAM:8KB(电池存档,本实现仅内存,不持久化 —— 后续可接 SavedVariables)
--   IRQ:无
--
-- 寄存器(全部通过写 $8000-$FFFF 间接访问):
--   写入数据 D7=1 时复位移位寄存器,且 control |= 0x0C(PRG 模式回到模式 3:
--                                  切低 + 固定最后)。
--   D7=0 时,把 D0 累计到移位寄存器(从低位开始,5 次后满)。
--   第 5 次写入时,根据当前 CPU 写地址的 bit13-14 选择目标:
--     $8000-$9FFF (00) → control     [4]CHR模式 [3:2]PRG模式 [1:0]mirror
--     $A000-$BFFF (01) → chrBank0
--     $C000-$DFFF (10) → chrBank1
--     $E000-$FFFF (11) → prgBank     [3:0]bank# [4]PRG-RAM disable(本实现忽略)
--   写入完成后清空移位寄存器与计数。
--
-- PRG 模式(control[3:2]):
--   0,1: 32K 切换。bank = prgBank & 0x0E,把两个 16K 槽都映射到这里。
--   2:   固定 bank 0 在 $8000,prgBank 切 $C000。
--   3:   prgBank 切 $8000,固定最后一个 bank 在 $C000。  ← 大多数游戏用这个
--
-- CHR 模式(control[4]):
--   0: 8K 切换。chrBank0 & 0x1E 选 4K 对,chrBank1 忽略。
--   1: 两个独立 4K 槽,chrBank0 / chrBank1 各自选 4K bank。

local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local function toU8(v)  return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

_G.Mapper1 = {}
Mapper1.__index = Mapper1

function Mapper1:new(nes, rom)
    local m = setmetatable({}, self)
    m.nes = nes
    m.rom = rom

    -- 移位寄存器:5 位串行累计;_shiftCount 累到 5 时派发并清零
    m._shift = 0
    m._shiftCount = 0

    -- 4 个内部寄存器(初值参考 NESdev wiki 的"power-up state"约定:
    --   control 初值 0x0C → PRG 模式 3(切低 + 固定最后)。
    --   多数游戏的 reset 向量在最后一个 bank,这个初值能让它们 boot 起来。)
    m._control = 0x0C
    m._chrBank0 = 0
    m._chrBank1 = 0
    m._prgBank = 0

    -- PRG-RAM(8KB)。$6000-$7FFF。本实现只在内存中存放,reset 不清空。
    m._prgRam = Buffer.newU8(0x2000, 0)

    -- 计算可用 bank 数(用于回绕,防止越界)
    -- romCount 是 16K PRG bank 数;rom.rom 的总字节 = romCount * 0x4000。
    m._prgBankCount = rom.romCount or 1
    m._prgLastBankOffset = (m._prgBankCount - 1) * 0x4000

    -- CHR:vromCount=0 时是 CHR-RAM 8K(在 ROM:load 里已分配 0x2000 字节给 self.vrom),
    -- 这种情况下 chrBank0/chrBank1 的 bank# 没意义,直接线性映射 PPU 地址。
    m._isChrRam = (rom.vromCount or 0) == 0
    m._chrBankCount4K = m._isChrRam and 2 or ((rom.vromCount or 0) * 2)

    -- 镜像类型:control 的低 2 位决定,初始按 control=0x0C → bit[1:0]=00 → single-screen 下屏
    m:_applyMirror()

    return m
end

----------------------------------------------------------------
-- 镜像
----------------------------------------------------------------
function Mapper1:_applyMirror()
    local mode = band(self._control, 0x03)
    local ppu = self.nes.ppu
    if mode == 0 then
        -- single-screen, lower bank
        ppu:setMirroring(ppu.SINGLESCREEN_MIRRORING)
    elseif mode == 1 then
        ppu:setMirroring(ppu.SINGLESCREEN_MIRRORING)
    elseif mode == 2 then
        ppu:setMirroring(ppu.VERTICAL_MIRRORING)
    elseif mode == 3 then
        ppu:setMirroring(ppu.HORIZONTAL_MIRRORING)
    end
end

----------------------------------------------------------------
-- reset:仅复位移位寄存器,内部寄存器保持(与真机一致)。
----------------------------------------------------------------
function Mapper1:reset()
    self._shift = 0
    self._shiftCount = 0
end

----------------------------------------------------------------
-- 写入 $6000-$FFFF
----------------------------------------------------------------
function Mapper1:write(address, value)
    address = toU16(address)
    value = toU8(value)

    if address < 0x6000 then
        return
    end

    if address < 0x8000 then
        -- PRG-RAM 写入
        self._prgRam[address - 0x6000] = value
        return
    end

    -- $8000-$FFFF:寄存器写入
    if band(value, 0x80) ~= 0 then
        -- D7=1:复位移位寄存器 + control 的 PRG 模式位强制为 3(切低 + 固定最后)
        self._shift = 0
        self._shiftCount = 0
        self._control = bor(self._control, 0x0C)
        self:_applyMirror()
        return
    end

    -- 累计 1 位:value 的 D0 进入 _shift 的"下一个"位
    self._shift = bor(self._shift, lshift(band(value, 0x01), self._shiftCount))
    self._shiftCount = self._shiftCount + 1

    if self._shiftCount < 5 then
        return
    end

    -- 第 5 次写满,按写地址 bit13-14 派发
    local target = band(rshift(address, 13), 0x03)
    local data = band(self._shift, 0x1F)

    if target == 0 then
        -- $8000-$9FFF: control
        self._control = data
        self:_applyMirror()
    elseif target == 1 then
        -- $A000-$BFFF: chrBank0
        if self._chrBank0 ~= data then
            self._chrBank0 = data
            self.nes.ppu:invalidateChrCache()
        end
    elseif target == 2 then
        -- $C000-$DFFF: chrBank1
        if self._chrBank1 ~= data then
            self._chrBank1 = data
            self.nes.ppu:invalidateChrCache()
        end
    else
        -- $E000-$FFFF: prgBank
        self._prgBank = data
    end

    self._shift = 0
    self._shiftCount = 0
end

----------------------------------------------------------------
-- 读取 $6000-$FFFF
----------------------------------------------------------------
function Mapper1:load(address)
    address = toU16(address)

    if address >= 0x6000 and address < 0x8000 then
        return self._prgRam[address - 0x6000] or 0
    end

    if address < 0x8000 then
        return 0
    end

    local prgMode = band(rshift(self._control, 2), 0x03)
    local bankCount = self._prgBankCount
    local prgRom = self.rom.rom
    local offsetInBank, bank

    if prgMode == 0 or prgMode == 1 then
        -- 32K 切换:用 prgBank & 0x0E 选 32K 块
        bank = band(self._prgBank, 0x0E) % bankCount
        offsetInBank = address - 0x8000
        return prgRom[bank * 0x4000 + offsetInBank] or 0
    elseif prgMode == 2 then
        -- 固定 bank 0 在 $8000,prgBank 切 $C000
        if address < 0xC000 then
            offsetInBank = address - 0x8000
            return prgRom[offsetInBank] or 0
        else
            bank = band(self._prgBank, 0x0F) % bankCount
            offsetInBank = address - 0xC000
            return prgRom[bank * 0x4000 + offsetInBank] or 0
        end
    else
        -- prgMode == 3:prgBank 切 $8000,固定最后 bank 在 $C000
        if address < 0xC000 then
            bank = band(self._prgBank, 0x0F) % bankCount
            offsetInBank = address - 0x8000
            return prgRom[bank * 0x4000 + offsetInBank] or 0
        else
            offsetInBank = address - 0xC000
            return prgRom[self._prgLastBankOffset + offsetInBank] or 0
        end
    end
end

function Mapper1:regLoad(address)  return self:load(address) end
function Mapper1:regWrite(address, value) self:write(address, value) end

----------------------------------------------------------------
-- PPU 端:CHR 读写($0000-$1FFF)与 nametable / palette($2000+)
----------------------------------------------------------------
function Mapper1:loadVRAM(address)
    address = band(address, 0x3FFF)

    if address < 0x2000 then
        if self._isChrRam then
            -- CHR-RAM 直接线性
            return self.rom.vrom[address] or 0
        end
        -- CHR-ROM 按 mode 选 bank
        local chrMode = band(rshift(self._control, 4), 0x01)
        local bankCount4K = self._chrBankCount4K
        local bank, offsetInBank

        if chrMode == 0 then
            -- 8K 切换:chrBank0 & 0x1E 选 8K 对
            local base = band(self._chrBank0, 0x1E) % bankCount4K
            bank = base + (address >= 0x1000 and 1 or 0)
            offsetInBank = band(address, 0x0FFF)
        else
            -- 4K 独立
            if address < 0x1000 then
                bank = band(self._chrBank0, 0x1F) % bankCount4K
                offsetInBank = address
            else
                bank = band(self._chrBank1, 0x1F) % bankCount4K
                offsetInBank = address - 0x1000
            end
        end
        return self.rom.vrom[bank * 0x1000 + offsetInBank] or 0

    elseif address < 0x3F00 then
        return self.nes.ppu:readVRAM(address)
    else
        return self.nes.ppu:readVRAM(address)
    end
end

function Mapper1:writeVRAM(address, value)
    address = band(address, 0x3FFF)
    value = toU8(value)

    if address < 0x2000 then
        if self._isChrRam then
            self.rom.vrom[address] = value
            self.nes.ppu:invalidateChrCache()
        end
        -- CHR-ROM:写入忽略
        return
    end

    self.nes.ppu:writeVRAM(address, value)
end

----------------------------------------------------------------
-- 其它
----------------------------------------------------------------
function Mapper1:clockIrqCounter()
    -- MMC1 没有 IRQ
end

function Mapper1:loadState(state)
    if not state then return end
    self._shift      = state.shift or 0
    self._shiftCount = state.shiftCount or 0
    self._control    = state.control or 0x0C
    self._chrBank0   = state.chrBank0 or 0
    self._chrBank1   = state.chrBank1 or 0
    self._prgBank    = state.prgBank or 0
    if state.prgRam then
        for k, v in pairs(state.prgRam) do self._prgRam[k] = v end
    end
    self:_applyMirror()
    self.nes.ppu:invalidateChrCache()
end

function Mapper1:saveState()
    local prgRamCopy = {}
    for i = 0, 0x1FFF do prgRamCopy[i] = self._prgRam[i] or 0 end
    return {
        shift = self._shift,
        shiftCount = self._shiftCount,
        control = self._control,
        chrBank0 = self._chrBank0,
        chrBank1 = self._chrBank1,
        prgBank = self._prgBank,
        prgRam = prgRamCopy,
    }
end

return Mapper1
