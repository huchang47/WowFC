-- ROM.lua
-- ROM 加载器和解析器
-- 基于 JSNES 的 rom.js 移植

-- 性能:与其它模块一致,不走 BitOps 包装。createVromTiles 解码 CHR 数据时
-- 会跑数十万次位运算,这里减重对加载速度有意义。
local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

-- 创建全局 ROM 表
_G.ROM = {}
ROM.__index = ROM

-- 镜像类型
ROM.HORIZONTAL_MIRRORING = 0
ROM.VERTICAL_MIRRORING = 1
ROM.FOURSCREEN_MIRRORING = 2
ROM.SINGLESCREEN_MIRRORING = 3

-- Mapper 类型（简化版，只支持最常用的）
ROM.MAPPER_TYPE = {
    [0] = "NROM",
    [1] = "MMC1",
    [2] = "UNROM",
    [3] = "CNROM",
    [4] = "MMC3",
    [7] = "AOROM",
}

function ROM:new(nes)
    local rom = setmetatable({}, self)
    rom.nes = nes
    
    -- ROM 数据
    rom.rom = nil
    rom.header = nil
    rom.romCount = 0
    rom.vromCount = 0
    rom.mirroring = 0
    rom.batteryRam = false
    rom.trainer = false
    rom.fourScreen = false
    rom.mapperType = 0
    
    -- ROM 内容
    rom.rom = nil
    rom.vrom = nil
    rom.vromTile = nil
    
    return rom
end

function ROM:load(data)
    if type(data) == "string" then
        self.rom = Buffer.fromString(data)
    else
        self.rom = Buffer.fromTable(data)
    end
    
    -- 检查 iNES 头 (使用表大小检查，因为索引从0开始)
    local romSize = 0
    for k, v in pairs(self.rom) do
        romSize = romSize + 1
    end

    if romSize < 16 then
        error("Invalid ROM: File too small (" .. romSize .. " bytes)")
    end

    -- 查找 NES 魔数位置（支持任意偏移）
    local headerOffset = 0
    for i = 0, math.min(romSize - 4, 16) do
        if self.rom[i] == 0x4E and self.rom[i+1] == 0x45 and
           self.rom[i+2] == 0x53 and self.rom[i+3] == 0x1A then
            headerOffset = i
            break
        end
    end

    local header = {
        magic = { self.rom[headerOffset], self.rom[headerOffset+1], self.rom[headerOffset+2], self.rom[headerOffset+3] },
        romCount = self.rom[headerOffset+4],
        vromCount = self.rom[headerOffset+5],
        control1 = self.rom[headerOffset+6],
        control2 = self.rom[headerOffset+7],
        ramCount = self.rom[headerOffset+8],
        reserved = { self.rom[headerOffset+9], self.rom[headerOffset+10], self.rom[headerOffset+11], self.rom[headerOffset+12], self.rom[headerOffset+13], self.rom[headerOffset+14], self.rom[headerOffset+15] }
    }

    if header.magic[1] ~= 0x4E or header.magic[2] ~= 0x45 or
       header.magic[3] ~= 0x53 or header.magic[4] ~= 0x1A then
        error("Invalid ROM: Not an iNES file")
    end

    -- 保存头偏移
    self.headerOffset = headerOffset
    
    self.header = header
    self.romCount = header.romCount
    self.vromCount = header.vromCount
    
    -- 解析控制字节
    self.mirroring = band(header.control1, 1) == 1 and self.VERTICAL_MIRRORING or self.HORIZONTAL_MIRRORING
    self.batteryRam = band(header.control1, 2) == 2
    self.trainer = band(header.control1, 4) == 4
    self.fourScreen = band(header.control1, 8) == 8
    
    if self.fourScreen then
        self.mirroring = self.FOURSCREEN_MIRRORING
    end
    
    -- 解析 Mapper 类型
    -- iNES:低 4 位 = ctrl1 高半字节,高 4 位 = ctrl2 高半字节。
    -- 旧代码把 ctrl1 / ctrl2 在表达式里交叉写反 → mapper=1 的 ROM 被识别成 16,
    -- mapper=4 的 ROM 被识别成 64,导致 MMC1/MMC3 卡带永远走不到对应 mapper。
    self.mapperType = bor(rshift(band(header.control1, 0xF0), 4), band(header.control2, 0xF0))
    
    -- 检查是否为 NES 2.0 格式
    local isNes20 = band(rshift(header.control2, 2), 3) == 2
    if isNes20 then
        -- NES 2.0 扩展
        local mapperHi = band(header.control2, 0x0F)
        self.mapperType = bor(self.mapperType, lshift(mapperHi, 8))
    end
    
    -- 计算偏移量（加上头偏移）
    local offset = headerOffset + 16

    -- 跳过 trainer
    if self.trainer then
        offset = offset + 512
    end

    -- 保存原始 ROM 数据
    local rawData = self.rom

    -- 加载 PRG ROM
    local romSize = self.romCount * 0x4000  -- 16KB per bank
    self.rom = Buffer.newU8(romSize, 0)
    for i = 0, romSize - 1 do
        self.rom[i] = rawData[offset + i] or 0
    end
    offset = offset + romSize

    -- 加载 CHR ROM
    if self.vromCount > 0 then
        local vromSize = self.vromCount * 0x2000  -- 8KB per bank
        self.vrom = Buffer.newU8(vromSize, 0)
        for i = 0, vromSize - 1 do
            self.vrom[i] = rawData[offset + i] or 0
        end
        
        -- 创建 tile 缓存
        self:createVromTiles()
    else
        -- CHR RAM
        self.vrom = Buffer.newU8(0x2000, 0)
    end
end

function ROM:createVromTiles()
    -- 预计算 tile 数据（可选优化）
    self.vromTile = {}
    local vromSize = 0
    for k, v in pairs(self.vrom) do
        vromSize = vromSize + 1
    end
    local tileCount = (vromSize + 1) / 16
    
    for i = 0, tileCount - 1 do
        self.vromTile[i] = {}
        local offset = i * 16
        
        for y = 0, 7 do
            self.vromTile[i][y] = {}
            local lowByte = self.vrom[offset + y] or 0
            local highByte = self.vrom[offset + y + 8] or 0
            
            for x = 0, 7 do
                local bitPos = 7 - x
                local lowBit = band(rshift(lowByte, bitPos), 1)
                local highBit = band(rshift(highByte, bitPos), 1)
                self.vromTile[i][y][x] = bor(lowBit, lshift(highBit, 1))
            end
        end
    end
end

function ROM:getMirroringType()
    return self.mirroring
end

function ROM:getMapperType()
    return self.mapperType
end

function ROM:createMapper()
    -- mapper 类查表:在这里集中注册支持的 mapper。
    -- 未注册的 mapper 退化到 NROM(Mapper0),并在控制台 warn —— 多数 4KB 测试 ROM
    -- 即使被错认为 NROM 也能跑前几十帧,有助于快速判断"是不是这个 mapper 的问题"。
    local mapperClasses = {
        [0] = _G.Mapper0,
        [1] = _G.Mapper1,
        [4] = _G.Mapper4,
    }
    local cls = mapperClasses[self.mapperType]
    if cls then
        return cls:new(self.nes, self)
    end

    -- 未支持:退到 NROM 并提示
    if print then
        local typeName = self.MAPPER_TYPE[self.mapperType] or "Unknown"
        print(string.format(
            "|cffff8800WOWFC|r: 不支持的 mapper %d (%s),退化到 NROM,游戏可能无法正常运行。",
            self.mapperType, typeName))
    end
    return _G.Mapper0:new(self.nes, self)
end

return ROM
