-- PPU.lua
-- PPU (Picture Processing Unit) 图像处理单元
-- 基于 JSNES 的 ppu/index.js 简化移植

-- 性能:与 CPU.lua 一样,把 BitOps 包装去掉,直接用 bit 库。
-- toU8/toU16 内联展开为 band(v, 0xFF)/band(v, 0xFFFF)。
local band   = bit.band
local bor    = bit.bor
local bxor   = bit.bxor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local function toU8(v) return band(v, 0xFF) end
local function toU16(v) return band(v, 0xFFFF) end

-- 创建全局 PPU 表
_G.PPU = {}
PPU.__index = PPU

-- 状态标志位
PPU.STATUS_VRAMWRITE = 4
PPU.STATUS_SLSPRITECOUNT = 5
PPU.STATUS_SPRITE0HIT = 6
PPU.STATUS_VBLANK = 7

-- 镜像类型
PPU.HORIZONTAL_MIRRORING = 0
PPU.VERTICAL_MIRRORING = 1
PPU.FOURSCREEN_MIRRORING = 2
PPU.SINGLESCREEN_MIRRORING = 3

function PPU:new(nes)
    local ppu = setmetatable({}, self)
    ppu.nes = nes
    
    -- 渲染选项
    ppu.showSpr0Hit = false
    ppu.clipToTvSize = true
    
    -- 内存
    ppu.vramMem = Buffer.newU8(0x8000, 0)  -- 32KB VRAM
    ppu.spriteMem = Buffer.newU8(0x100, 0) -- 256 bytes 精灵内存
    
    -- VRAM I/O
    ppu.vramAddress = 0
    ppu.vramTmpAddress = 0
    ppu.vramBufferedReadValue = 0
    ppu.firstWrite = true
    ppu.openBusLatch = 0
    ppu.openBusDecayFrames = 0
    
    -- SPR-RAM I/O
    ppu.sramAddress = 0
    
    -- 镜像
    ppu.currentMirroring = -1
    ppu.ntable1 = {0, 0, 0, 0}
    
    -- NMI 状态
    ppu.nmiOutput = false
    ppu.nmiSuppressed = false
    ppu.frameEnded = false
    ppu._paletteCache = {}
    ppu._spritePaletteCache = {}
    ppu._bgColor = 0
    -- tile 解码缓存拆成 BG / sprite 双表,跨帧复用。
    -- 之前用单表 _tileCache 每帧清,因为 BG 用 (tileIndex*2 + highTable)、sprite 用 patternAddr 当 key,
    -- 键空间会撞(BG key 16 ↔ sprite key 16 含义不同) → 清空兜底。
    -- 拆双表后两边互不影响,SMB1 是 CHR-ROM(pattern 永不变),整局只解码一次。
    -- CHR-RAM 卡带在 Mapper:writeVRAM(addr<0x2000) 写入时清对应 entry。
    ppu._bgTileCache = {}
    ppu._spriteTileCache = {}
    ppu._ntCache = {}

    -- BG tile 输出缓存(横滚优化的核心)
    -- 普通 _bgTileCache 存的是 raw pattern 字节,每次 renderTile 仍要做 8 次解 bit + 查 palette。
    -- 横滚场景下 33×30 = 990 个屏幕 tile 区域、每区域调用 1-2 次 renderTile,
    -- 累计 ~13K 次 tile 调用 × 每次 64 次 bit op + 64 次 palette lookup = 12ms PPU render。
    --
    -- 输出缓存把"已应用 palette 的 8x8 RGB 像素"整存,横滚 1 像素时:
    --   nametable / palette / pattern 都没变 → cache 100% 命中 → 工作只剩"按行拷贝 8 像素"
    -- key = tileIndex*8 + paletteNum*2 + highTable,SMB1 一关常用 ~200 组合,内存 ~150KB
    -- 失效条件:
    --   1) CHR-RAM 写($0000-$1FFF) → 清相关 tileIndex 的 8 个 cache 项
    --   2) BG palette 写($3F00-$3F0F) → 清整个 cache
    --   3) 第 4 帧兜底 palette hack → 清整个 cache
    -- value 结构:[0..7] = 8 行,每行是 8 元素数组,值是 24-bit RGB int,
    --   transparent 像素用 -1 sentinel(原 colorNum=0,renderTile 不写 bgbuf)
    ppu._bgTileOutputCache = {}

    -- dirty 检测:拆成 BG / sprite 两路,与渲染管线解耦。
    -- _bgDirty=true:nametable / attribute / palette / scroll / pattern table 等任何
    --   会改变 BG 输出的字节级写入(由 writeVRAM、_loadVFromT 之后的 _renderState 比较触发)。
    -- _spriteDirty=true:OAMDMA / $2004 OAMDATA 写入。
    -- BG 命中 dirty 才重画 bgbuffer / pixrendered;sprite 命中 dirty 才重画前景。
    -- present 时把 bgbuffer 拷到 buffer 再叠加 sprite。
    -- 这样 OAMDMA 触发的"99% 帧"只重画 sprite,不触发整屏 BG 重绘。
    ppu._bgDirty = true
    ppu._spriteDirty = true

    -- sprite 像素级双缓冲撤销列表
    -- _curSpritePixels:本帧 renderSpriteTile 写入到 buffer 的像素 index 集合(从 1 计数)。
    -- _prevSpritePixels:上一帧 sprite 像素列表。
    -- 帧末 swap:本帧 cur → 下一帧 prev,供下一帧撤销使用。
    -- 与 renderer 沟通的元数据:
    --   _frameMode = "skip" / "full" / "partial"
    --   _frameUndoList / _frameUndoN:上一帧 sprite 像素(本帧需撤销的区域)
    --   _frameNewList  / _frameNewN: 本帧 sprite 像素(新画的区域)
    -- partial 模式下 renderer 仅扫描 (撤销 ∪ 新画) ≈ 1500-3000 像素,
    -- 比全屏 60K 像素扫描省 30 倍。
    ppu._curSpritePixels = {}
    ppu._curSpriteN = 0
    ppu._prevSpritePixels = {}
    ppu._prevSpriteN = 0
    ppu._frameMode = "full"
    ppu._frameUndoList = nil
    ppu._frameUndoN = 0
    ppu._frameNewList = nil
    ppu._frameNewN = 0
    ppu._renderState = {
        regHT = -1, regVT = -1, regFV = -1, regFH = -1,
        nTbl = -1, bgPT = -1, spPT = -1, sprSize = -1,
        bgVis = -1, spVis = -1,
    }
    -- dirty 来源诊断计数(开发调优用,帧间不清零,/fc prof 时一并打印)
    ppu._dirtyStats = {
        framesRendered = 0,    -- 实际跑过 renderFrame 主体的帧数
        framesSkipped  = 0,    -- 入口直接 return 的帧数
        dirtyFromOAMDMA   = 0, -- doOAMDMA 触发 dirty 的帧数
        dirtyFromOAMDATA  = 0, -- $2004 触发 dirty 的帧数
        dirtyFromVRAM     = 0, -- writeVRAM 触发 dirty 的帧数
        dirtyFromState    = 0, -- _renderState 比较触发的帧数
    }
    
    -- 控制标志
    ppu.f_nmiOnVblank = 0
    ppu.f_spriteSize = 0
    ppu.f_bgPatternTable = 0
    ppu.f_spPatternTable = 0
    ppu.f_addrInc = 0
    ppu.f_nTblAddress = 0
    
    -- 渲染标志
    ppu.f_color = 0
    ppu.f_spVisibility = 0
    ppu.f_bgVisibility = 0
    ppu.f_spClipping = 0
    ppu.f_bgClipping = 0
    ppu.f_dispType = 0
    
    -- 计数器
    ppu.cntFV = 0
    ppu.cntV = 0
    ppu.cntH = 0
    ppu.cntVT = 0
    ppu.cntHT = 0
    
    -- 寄存器
    ppu.regFV = 0
    ppu.regV = 0
    ppu.regH = 0
    ppu.regVT = 0
    ppu.regHT = 0
    ppu.regFH = 0
    ppu.regS = 0
    
    -- 扫描线
    ppu.scanline = 0
    ppu.curX = 0
    ppu.lastRenderedScanline = -1
    ppu.dummyCycleToggle = false
    
    -- 精灵数据
    ppu.sprX = Buffer.newU8(64, 0)
    ppu.sprY = Buffer.newU8(64, 0)
    ppu.sprTile = Buffer.newU8(64, 0)
    ppu.sprCol = Buffer.newU8(64, 0)
    ppu.vertFlip = Buffer.newU8(64, 0)
    ppu.horiFlip = Buffer.newU8(64, 0)
    ppu.bgPriority = Buffer.newU8(64, 0)
    ppu.spr0HitX = 0
    ppu.spr0HitY = 0
    ppu.hitSpr0 = false
    
    -- 二级 OAM
    ppu.secondaryOAM = Buffer.newU8(32, 0xFF)
    ppu.spritesFound = 0
    ppu.sprite0InSecondary = false
    
    -- 调色板
    ppu.sprPalette = Buffer.newU32(16, 0)
    ppu.imgPalette = Buffer.newU32(16, 0)
    
    -- 帧缓冲区 (256x240)
    ppu.buffer = Buffer.newU32(256 * 240, 0)
    ppu.bgbuffer = Buffer.newU32(256 * 240, 0)
    ppu.pixrendered = Buffer.newU32(256 * 240, 0)

    -- ============================================================
    -- cycle-accurate 逐扫描线渲染状态(可选,默认关闭)
    -- _perScanline:本帧是否走逐扫描线渲染。默认 false(vblank 整帧快照,性能最优)。
    --   置 true(经 /fc scanline on 或 FC:setScanlineMode)后:CPU/PPU 交错推进,
    --   每条可见行用当时活动的滚动量/CHR bank 即时渲染,并算出真实 sprite 0 hit,
    --   支持 mid-frame split / sprite0-hit 依赖的游戏。代价约 2x 渲染开销。
    -- _slActive:本帧是否已做帧首初始化(v=t、快照 palette/nametable、清缓冲)。
    -- ============================================================
    ppu._perScanline = false
    ppu._slActive = false
    
    -- 名称表
    ppu.nameTable = {}
    for i = 0, 3 do
        ppu.nameTable[i] = Buffer.newU8(32 * 32, 0)
    end
    
    -- VRAM 镜像表
    ppu.vramMirrorTable = Buffer.newU16(0x8000, 0)
    for i = 0, 0x7FFF do
        ppu.vramMirrorTable[i] = i
    end
    
    -- 初始化调色板
    ppu:loadPalette()
    
    -- 初始化控制寄存器
    ppu:updateControlReg1(0)
    ppu:updateControlReg2(0)
    
    return ppu
end

function PPU:reset()
    self.vramAddress = 0
    self.vramTmpAddress = 0
    self.firstWrite = true
    self.scanline = 0
    self.curX = 0
    self.frameEnded = false
    self.hitSpr0 = false
    self.spr0HitX = 0
    self.spr0HitY = 0
    
    -- 清空缓冲区
    for i = 0, 256 * 240 - 1 do
        self.buffer[i] = 0
        self.bgbuffer[i] = 0
        self.pixrendered[i] = 0
    end
    
    self:updateControlReg1(0)
    self:updateControlReg2(0)

    -- 重置后强制重画首帧:BG / sprite 两路都标 dirty
    self._bgDirty = true
    self._spriteDirty = true
    -- 清空 sprite 双缓冲列表(reset 后画面全黑,首帧走 full 路径)
    self._curSpriteN = 0
    self._prevSpriteN = 0
    self._frameMode = "full"
    self._frameUndoN = 0
    self._frameNewN = 0
    -- 清空 tile 解码缓存(reset 视同卡带切换,即使是 CHR-ROM 也要重新解)
    self._bgTileCache = {}
    self._spriteTileCache = {}
    self._bgTileOutputCache = {}
    if self._renderState then
        self._renderState.regHT = -1
        self._renderState.regVT = -1
        self._renderState.regFV = -1
        self._renderState.regFH = -1
        self._renderState.nTbl = -1
        self._renderState.bgPT = -1
        self._renderState.spPT = -1
        self._renderState.sprSize = -1
        self._renderState.bgVis = -1
        self._renderState.spVis = -1
    end
end

-- 加载调色板
-- 用 jsnes 的 loadDefaultPalette(经典 NES 颜色,与 SMB1 期望颜色匹配)
-- 之前用的 NTSC 信号波形推导表偏暗,与真机视觉差很大。
-- 数值来自 jsnes/src/ppu/palette-table.js 的 loadDefaultPalette 函数。
function PPU:loadPalette()
    local defaultPalette = {
        0x757575, 0x271B8F, 0x0000AB, 0x47009F, 0x8F0077, 0xAB0013, 0xA70000, 0x7F0B00,
        0x432F00, 0x004700, 0x005100, 0x003F17, 0x1B3F5F, 0x000000, 0x000000, 0x000000,
        0xBCBCBC, 0x0073EF, 0x233BEF, 0x8300F3, 0xBF00BF, 0xE7005B, 0xDB2B00, 0xCB4F0F,
        0x8B7300, 0x009700, 0x00AB00, 0x00933B, 0x00838B, 0x000000, 0x000000, 0x000000,
        0xFFFFFF, 0x3FBFFF, 0x5F97FF, 0xA78BFD, 0xF77BFF, 0xFF77B7, 0xFF7763, 0xFF9B3B,
        0xF3BF3F, 0x83D313, 0x4FDF4B, 0x58F898, 0x00EBDB, 0x000000, 0x000000, 0x000000,
        0xFFFFFF, 0xABE7FF, 0xC7D7FF, 0xD7CBFF, 0xFFC7FF, 0xFFC7DB, 0xFFBFB3, 0xFFDBAB,
        0xFFE7A3, 0xE3FFA3, 0xABF3BF, 0xB3FFCF, 0x9FFFF3, 0x000000, 0x000000, 0x000000
    }

    self.palette = {}
    for i = 0, 63 do
        self.palette[i] = defaultPalette[i + 1] or 0
    end
end

-- 设置镜像
function PPU:setMirroring(mirroring)
    if mirroring == self.currentMirroring then
        return
    end
    
    self.currentMirroring = mirroring
    
    -- 重置镜像表
    for i = 0, 0x7FFF do
        self.vramMirrorTable[i] = i
    end
    
    -- 调色板镜像
    self:defineMirrorRegion(0x3F20, 0x3F00, 0x20)
    self:defineMirrorRegion(0x3F40, 0x3F00, 0x20)
    self:defineMirrorRegion(0x3F80, 0x3F00, 0x20)
    self:defineMirrorRegion(0x3FC0, 0x3F00, 0x20)

    -- NES 调色板内部镜像(NESDev wiki 标准):
    -- $3F10 ↔ $3F00 (backdrop 镜像)
    -- $3F14 ↔ $3F04
    -- $3F18 ↔ $3F08
    -- $3F1C ↔ $3F0C
    -- 注意:$3F04/$3F08/$3F0C 是独立字节,不镜像到 $3F00。
    -- 旧版错误地把 $3F04/08/0C 都映射到 $3F00,导致 SMB1 写 $3F0C(合法 sprite
    -- palette 数据)时把 backdrop 覆盖成 $0F,World 1-1 天空显示黑色。
    self:defineMirrorRegion(0x3F10, 0x3F00, 1)
    self:defineMirrorRegion(0x3F14, 0x3F04, 1)
    self:defineMirrorRegion(0x3F18, 0x3F08, 1)
    self:defineMirrorRegion(0x3F1C, 0x3F0C, 1)
    
    -- 额外镜像
    self:defineMirrorRegion(0x3000, 0x2000, 0xF00)
    self:defineMirrorRegion(0x4000, 0x0000, 0x4000)
    
    if mirroring == self.HORIZONTAL_MIRRORING then
        self.ntable1[0] = 0
        self.ntable1[1] = 0
        self.ntable1[2] = 1
        self.ntable1[3] = 1
        self:defineMirrorRegion(0x2400, 0x2000, 0x400)
        self:defineMirrorRegion(0x2C00, 0x2800, 0x400)
    elseif mirroring == self.VERTICAL_MIRRORING then
        self.ntable1[0] = 0
        self.ntable1[1] = 1
        self.ntable1[2] = 0
        self.ntable1[3] = 1
        self:defineMirrorRegion(0x2800, 0x2000, 0x400)
        self:defineMirrorRegion(0x2C00, 0x2400, 0x400)
    elseif mirroring == self.SINGLESCREEN_MIRRORING then
        self.ntable1[0] = 0
        self.ntable1[1] = 0
        self.ntable1[2] = 0
        self.ntable1[3] = 0
        self:defineMirrorRegion(0x2400, 0x2000, 0x400)
        self:defineMirrorRegion(0x2800, 0x2000, 0x400)
        self:defineMirrorRegion(0x2C00, 0x2000, 0x400)
    else
        -- 四屏镜像
        self.ntable1[0] = 0
        self.ntable1[1] = 1
        self.ntable1[2] = 2
        self.ntable1[3] = 3
    end
end

function PPU:defineMirrorRegion(fromStart, toStart, size)
    for i = 0, size - 1 do
        self.vramMirrorTable[fromStart + i] = toStart + i
    end
end

-- 更新控制寄存器 1
function PPU:updateControlReg1(value)
    self.f_nmiOnVblank = band(rshift(value, 7), 1)
    self.f_spriteSize = band(rshift(value, 5), 1)
    self.f_bgPatternTable = band(rshift(value, 4), 1)
    self.f_spPatternTable = band(rshift(value, 3), 1)
    self.f_addrInc = band(rshift(value, 2), 1)
    self.f_nTblAddress = band(value, 3)
    
    self.regV = band(rshift(value, 0), 1)
    self.regH = band(rshift(value, 1), 1)
    self.regS = band(rshift(value, 4), 1)
end

-- 更新控制寄存器 2
function PPU:updateControlReg2(value)
    self.f_color = band(rshift(value, 5), 7)
    self.f_spVisibility = band(rshift(value, 4), 1)
    self.f_bgVisibility = band(rshift(value, 3), 1)
    self.f_spClipping = band(rshift(value, 2), 1)
    self.f_bgClipping = band(rshift(value, 1), 1)
    self.f_dispType = band(value, 1)
end

-- 设置状态标志
function PPU:setStatusFlag(flag, value)
    local mask = lshift(1, flag)
    if value then
        self.nes.cpu.mem[0x2002] = bor(self.nes.cpu.mem[0x2002], mask)
    else
        self.nes.cpu.mem[0x2002] = band(self.nes.cpu.mem[0x2002], bnot(mask))
    end
end

-- 读取 PPU 寄存器
function PPU:read(address)
    address = band(address, 0xFFFF)

    if address == 0x2002 then
        local status = self.nes.cpu.mem[0x2002] or 0
        self:setStatusFlag(self.STATUS_VBLANK, false)
        -- $2002 读取重置 w(write toggle),按 NESdev 标准
        self.firstWrite = true
        self.openBusLatch = status
        return status

    elseif address == 0x2004 then
        -- OAMDATA
        return self.spriteMem[self.sramAddress] or 0

    elseif address == 0x2007 then
        -- PPUDATA:返回缓冲区,然后用当前 v 地址刷新缓冲,最后 increment v
        local value = self.vramBufferedReadValue
        local addr = band(self.vramAddress, 0x3FFF)

        if addr < 0x3F00 then
            self.vramBufferedReadValue = self:readVRAM(addr)
        else
            value = self:readVRAM(addr)
            self.vramBufferedReadValue = self:readVRAM(addr - 0x1000)
        end

        -- 增量 v 并同步到 reg* 寄存器(这样 renderBackground 用的滚动量与 v 保持一致)
        self.vramAddress = toU16(self.vramAddress + (self.f_addrInc == 1 and 32 or 1))
        self:_syncRegsFromV()
        return value
    end

    return self.openBusLatch
end

-- ----------------------------------------------------------------
-- v/t/x/w 锁存器协议同步:从 v 寄存器抽取滚动量到 reg*
-- v bits:  yyy NN YYYYY XXXXX
--          fineY|nametable|coarseY|coarseX
-- reg* 字段是 renderBackground 实际读取的渲染滚动量
-- 在任何会改 v 的操作之后调用,保证 reg* 反映最新 v
-- ----------------------------------------------------------------
function PPU:_syncRegsFromV()
    self.regHT = band(self.vramAddress, 0x1F)
    self.regVT = band(rshift(self.vramAddress, 5), 0x1F)
    self.f_nTblAddress = band(rshift(self.vramAddress, 10), 0x3)
    self.regFV = band(rshift(self.vramAddress, 12), 0x7)
end

-- ----------------------------------------------------------------
-- 帧开始时:将 t 拷贝到 v(NES pre-render scanline 的标准行为)
-- 这是 SMB1 logo 显示的关键:logo 写入完成后,$2006 写完留在 t 寄存器,
-- 到 pre-render 时 v=t 才让渲染读到正确滚动地址。
-- 由 advanceDots 在 scanline 261 dot 1 时调用。
-- ----------------------------------------------------------------
function PPU:_loadVFromT()
    self.vramAddress = self.vramTmpAddress
    self:_syncRegsFromV()
end

-- 写入 PPU 寄存器
function PPU:write(address, value)
    address = band(address, 0xFFFF)
    value = toU8(value)
    self.openBusLatch = value

    if address == 0x2000 then
        -- PPUCTRL:nametable/pattern table/sprite size 等都影响渲染,
        -- 但具体是否引发输出变化,留给 renderFrame 入口的 _renderState 快照比较。
        self:updateControlReg1(value)
        self.nes.cpu.mem[0x2000] = value

        -- $2000 bit0-1 是 nametable 选择,要写到 t 寄存器的 bit 10-11
        -- t: yyy NN YYYYY XXXXX  -- NN 由 PPUCTRL bit0-1 决定
        self.vramTmpAddress = bor(
            band(self.vramTmpAddress, 0x73FF),
            lshift(band(value, 0x03), 10)
        )

    elseif address == 0x2001 then
        -- PPUMASK:同上,留给 _renderState 比较
        self:updateControlReg2(value)
        self.nes.cpu.mem[0x2001] = value

    elseif address == 0x2003 then
        -- OAMADDR
        self.sramAddress = value

    elseif address == 0x2004 then
        -- OAMDATA:OAM 是大数组,renderFrame 入口比较代价高,
        -- 这里做字节级值比较设 dirty 更划算
        local oldVal = self.spriteMem[self.sramAddress]
        if oldVal ~= value then
            self._spriteDirty = true
            self._dirtyFromOAMDATA = true
        end
        self.spriteMem[self.sramAddress] = value
        self.sramAddress = toU8(self.sramAddress + 1)

    elseif address == 0x2005 then
        -- PPUSCROLL:写 t 寄存器,scroll 变化是否引发渲染差异,
        -- 留给 renderFrame 入口的 _renderState 快照比较
        if self.firstWrite then
            -- 第一次写:fine X(bit0-2)进 x 锁存器,coarse X(bit3-7)进 t bit0-4
            self.regFH = band(value, 7)  -- fine X(也叫 x 寄存器)
            self.vramTmpAddress = bor(
                band(self.vramTmpAddress, 0x7FE0),  -- 清掉 t 的 coarse X
                rshift(value, 3)                     -- 把 value bit3-7 当 coarse X
            )
        else
            -- 第二次写:fine Y(bit0-2)进 t bit12-14,coarse Y(bit3-7)进 t bit5-9
            self.vramTmpAddress = bor(
                band(self.vramTmpAddress, 0x0C1F),   -- 清 fine Y + coarse Y
                lshift(band(value, 7), 12),           -- fine Y → bit 12-14
                lshift(band(rshift(value, 3), 31), 5) -- coarse Y → bit 5-9
            )
        end
        self.firstWrite = not self.firstWrite

    elseif address == 0x2006 then
        if self.firstWrite then
            -- 第一次写:t 高 6 位 (bit 8-13),bit 14 清零
            self.vramTmpAddress = bor(
                lshift(band(value, 0x3F), 8),
                band(self.vramTmpAddress, 0x00FF)
            )
        else
            -- 第二次写:t 低 8 位,然后 t→v
            self.vramTmpAddress = bor(
                band(self.vramTmpAddress, 0xFF00),
                value
            )
            self.vramAddress = self.vramTmpAddress
            -- v 改了,同步到 reg*(让 renderBackground 立刻看到新地址)
            -- 是否引发渲染差异,留给 renderFrame 入口的 _renderState 快照比较
            self:_syncRegsFromV()
        end
        self.firstWrite = not self.firstWrite

    elseif address == 0x2007 then
        self:writeVRAM(self.vramAddress, value)
        self.vramAddress = toU16(self.vramAddress + (self.f_addrInc == 1 and 32 or 1))
        -- v 改了,同步到 reg*
        self:_syncRegsFromV()
    end
end

-- VRAM 读写
function PPU:readVRAM(address)
    address = band(address, 0x3FFF)
    
    -- Pattern Table ($0000-$1FFF) 通过 Mapper 读取 CHR ROM
    if address < 0x2000 then
        if self.nes.mmap and self.nes.mmap.loadVRAM then
            return self.nes.mmap:loadVRAM(address)
        end
        return 0
    end
    
    -- 其他区域使用镜像表
    address = self.vramMirrorTable[address] or address
    return self.vramMem[address] or 0
end

function PPU:writeVRAM(address, value)
    address = band(address, 0x3FFF)

    if address < 0x2000 then
        -- Pattern Table 通过 Mapper 写到 CHR RAM(如有)。CHR 变化既影响 BG 也影响 sprite,
        -- 两路 tile 缓存里对应 entry 都要失效,且两路渲染都要重画。
        -- (SMB1 是 CHR-ROM 不会写,实际不会触发)
        if self.nes.mmap and self.nes.mmap.writeVRAM then
            self.nes.mmap:writeVRAM(address, value)
            self._bgDirty = true
            self._spriteDirty = true
            self._dirtyFromVRAM = true
            -- 受影响的 tile index = address / 16,失效两个 raw cache 里对应 entry
            local tileIdx = rshift(address, 4)
            -- BG raw cacheKey = tileIndex*2 + highTable(0/1),两路 high/low 都清
            self._bgTileCache[tileIdx * 2] = nil
            self._bgTileCache[tileIdx * 2 + 1] = nil
            -- sprite cacheKey = patternAddr = tileIdx*16,两个可能的 bank 各清一次
            self._spriteTileCache[tileIdx * 16] = nil
            -- BG output cache key = tileIndex*8 + paletteNum*2 + highTable
            -- 同一 tileIndex 在不同 palette/highTable 组合下都需失效,共 8 项
            local outBase = tileIdx * 8
            local outCache = self._bgTileOutputCache
            outCache[outBase + 0] = nil
            outCache[outBase + 1] = nil
            outCache[outBase + 2] = nil
            outCache[outBase + 3] = nil
            outCache[outBase + 4] = nil
            outCache[outBase + 5] = nil
            outCache[outBase + 6] = nil
            outCache[outBase + 7] = nil
        end
        return
    end

    address = self.vramMirrorTable[address] or address
    value = toU8(value)
    -- nametable / attribute table / palette($2000-$3FFF 镜像后的实际位置)
    -- 只在新值不同于旧值时设 BG dirty。SMB1 NMI 每帧把状态栏重写一遍,
    -- 但写入值通常不变,这里能砍掉绝大部分无效重绘。
    -- 注意:palette 写入($3F10-$3F1F)实际只影响 sprite 颜色,但 jsnes 简化版
    -- 不区分,与 BG palette($3F00-$3F0F)一同走 BG dirty(也会让 sprite 兜底重画 —— sprite 每帧都 dirty)。
    if self.vramMem[address] ~= value then
        self._bgDirty = true
        self._dirtyFromVRAM = true
        self.vramMem[address] = value
        -- BG palette 写入($3F00-$3F0F 镜像后)→ 清整个 BG output cache
        -- 因为 cache 存的是已应用 palette 的 RGB 值,palette 一变全过期。
        -- attribute table 写入只改一格 tile 的 palette 选择,但 cache 已按
        -- (tileIndex, paletteNum) 分桶,attribute 改不需要清 cache —— 新组合
        -- 第一次访问 miss 后填充即可,旧组合可能成"孤儿"但不影响正确性,
        -- 整局后内存增长可控(SMB1 一关 ~200 组合)。
        if address >= 0x3F00 and address < 0x3F10 then
            self._bgTileOutputCache = {}
        end
    end
end

-- 让 CHR pattern 缓存全部失效。
-- mapper 切 CHR bank 时调用:同一 PPU 地址($0000-$1FFF)在 bank 切换前后
-- 指向不同 CHR-ROM 字节,_bgTileCache / _spriteTileCache / _bgTileOutputCache
-- 的 key(以 PPU 地址为索引)就过期了,必须整张表清掉。
-- 同时设两路 dirty,确保下一帧 BG / sprite 都重画。
function PPU:invalidateChrCache()
    self._bgTileCache = {}
    self._spriteTileCache = {}
    self._bgTileOutputCache = {}
    self._bgDirty = true
    self._spriteDirty = true
end

function PPU:dumpVRAM(startAddr, count)
    local result = {}
    for i = 0, count - 1 do
        result[i + 1] = string.format("$%02X", self:readVRAM(startAddr + i))
    end
    return result
end

-- 开始新帧
function PPU:startFrame()
    self.frameEnded = false
    self.scanline = 0
    self.curX = 0
    -- 逐扫描线模式:本帧首个可见行触发 _slBeginFrame 重新初始化
    self._slActive = false
end

-- 推进 PPU 周期
function PPU:advanceDots(dots)
    local finalCurX = self.curX + dots
    
    if finalCurX < 341 then
        self.curX = finalCurX
        return
    end
    
    for i = 0, dots - 1 do
        self.curX = self.curX + 1
        if self.curX >= 341 then
            self.curX = 0
            self:endScanline()
        end
    end
end

function PPU:endScanline()
    -- ----------------------------------------------------------------
    -- cycle-accurate 逐扫描线渲染(非 SMB1):在每条可见行"结束"边界,用此刻
    -- 活动的 v 寄存器(滚动量 + nametable)和 CHR bank 渲染这一行,并即时计算
    -- 真实的 sprite 0 hit。进入本函数时 self.scanline 仍是"刚跑完的那一行"。
    -- 必须在 mapper IRQ tick 之前画 —— IRQ handler 改的滚动量/bank 是给后续行的。
    -- ----------------------------------------------------------------
    if self._perScanline then
        local sl = self.scanline
        if sl >= 0 and sl <= 239 then
            if not self._slActive then
                self:_slBeginFrame()
            end
            self:_slRenderLine(sl)
            -- 行末 v 垂直自增(NES dot 256),行首水平位从 t 恢复(NES dot 257)
            self:_slIncVertical()
            self:_slCopyHorizontal()
        end
    end

    self.scanline = self.scanline + 1

    -- mapper IRQ 钩子(MMC3 等):在每根可见扫描线渲染完毕时 tick 一次。
    -- 真机 IRQ 来源是 PPU A12 由 0 → 1 的上升沿,简化版按 scanline 边界近似。
    -- 仅 BG / sprite 可见时 tick,真机 A12 行为也是渲染开启时才会上升。
    -- self.scanline 此时是"刚结束的行 + 1",即 1..240 对应可见行 0..239 已渲染完。
    if self.scanline >= 1 and self.scanline <= 240 then
        if (self.f_bgVisibility == 1 or self.f_spVisibility == 1) then
            local mmap = self.nes.mmap
            if mmap and mmap.clockIrqCounter then
                mmap:clockIrqCounter()
            end
        end
    end

    if self.scanline == 241 then
        -- VBlank开始
        self:setStatusFlag(self.STATUS_VBLANK, true)

        if self.f_nmiOnVblank == 1 then
            self.nes.cpu:requestIrq(self.nes.cpu.IRQ_NMI)
        end
        
        -- 标记帧结束（在VBlank开始时）
        self.frameEnded = true
        
    elseif self.scanline == 261 then
        -- 预渲染扫描线：清除VBlank和sprite 0 hit
        self:setStatusFlag(self.STATUS_VBLANK, false)
        self:setStatusFlag(self.STATUS_SPRITE0HIT, false)
        self.hitSpr0 = false
    elseif self.scanline >= 262 then
        -- 帧结束，重置到扫描线0
        self.scanline = 0
    end
end

function PPU:renderFrame()
    -- 逐扫描线模式(非 SMB1):BG/sprite 已在可见期由 endScanline 逐行画进 buffer。
    -- 这里只做帧末元数据收尾,不再整帧重画。
    if self._perScanline then
        return self:_slFinishFrame()
    end

    -- ----------------------------------------------------------------
    -- 帧开始:模拟 NES pre-render scanline 的 t→v 行为。
    -- SMB1 NMI 在 vblank 期间写 $2005 (PPUSCROLL) 更新 t 寄存器;
    -- 真机的 pre-render 行会把 t copy 到 v 让 BG 渲染读到最新滚动。
    -- 这一步必须在 _renderState 快照比较之前,这样 reg* 反映本帧实际滚动量,
    -- scroll 变了能被 stateChanged 检测到 → 触发 BG dirty 重绘。
    -- ----------------------------------------------------------------
    self:_loadVFromT()

    -- 默认告诉 renderer 本帧无变化,后面分支会按需改写
    self._frameMode = "skip"
    self._frameUndoN = 0
    self._frameNewN = 0

    -- ----------------------------------------------------------------
    -- BG / sprite 渲染解耦
    -- ----------------------------------------------------------------
    -- 分类:
    --   stateChanged + BG-affecting state    → BG 重画
    --   _spriteDirty(OAMDMA / $2004)         → sprite 重画
    --   _bgDirty(writeVRAM 字节变化)         → BG 重画
    --
    -- present 阶段:把 bgbuffer 拷到 buffer + 叠加 sprite。
    -- profile 显示 OAMDMA 占 99% dirty 来源,以前每帧整屏重画,现在只动 sprite + 拷一份 BG。
    -- 第 4 帧的默认调色板兜底 hack 仍要执行,前 5 帧 BG 强制重画。
    -- ----------------------------------------------------------------
    local fc = self.nes.frameCount or 0

    -- 当前渲染状态快照(11 个标量),全部都影响 BG 输出
    local rs = self._renderState
    local stateChanged =
        rs.regHT   ~= self.regHT or
        rs.regVT   ~= self.regVT or
        rs.regFV   ~= self.regFV or
        rs.regFH   ~= self.regFH or
        rs.nTbl    ~= self.f_nTblAddress or
        rs.bgPT    ~= self.f_bgPatternTable or
        rs.spPT    ~= self.f_spPatternTable or
        rs.sprSize ~= self.f_spriteSize or
        rs.bgVis   ~= self.f_bgVisibility or
        rs.spVis   ~= self.f_spVisibility

    -- 决定本帧要不要重画 BG / sprite
    local needBg = self._bgDirty or stateChanged or fc <= 4
    local needSprite = self._spriteDirty or stateChanged or fc <= 4

    -- dirty 来源诊断归账:这里只在"任一路重画"时归一类。
    -- 优先级 OAMDMA > OAMDATA > VRAM > state(保持与旧版一致便于对比)。
    local stats = self._dirtyStats
    if stats and fc > 4 then
        if needBg or needSprite then
            stats.framesRendered = stats.framesRendered + 1
            if self._dirtyFromOAMDMA then
                stats.dirtyFromOAMDMA = stats.dirtyFromOAMDMA + 1
            elseif self._dirtyFromOAMDATA then
                stats.dirtyFromOAMDATA = stats.dirtyFromOAMDATA + 1
            elseif self._dirtyFromVRAM then
                stats.dirtyFromVRAM = stats.dirtyFromVRAM + 1
            elseif stateChanged then
                stats.dirtyFromState = stats.dirtyFromState + 1
            end
        else
            stats.framesSkipped = stats.framesSkipped + 1
        end
    end
    -- 单帧标志清零,下一帧重新累计
    self._dirtyFromOAMDMA = false
    self._dirtyFromOAMDATA = false
    self._dirtyFromVRAM = false

    if not needBg and not needSprite then
        -- 真正的"无变化帧":bgbuffer 与 buffer 都还是上一次画好的,直接返回
        return
    end

    -- 更新快照
    rs.regHT   = self.regHT
    rs.regVT   = self.regVT
    rs.regFV   = self.regFV
    rs.regFH   = self.regFH
    rs.nTbl    = self.f_nTblAddress
    rs.bgPT    = self.f_bgPatternTable
    rs.spPT    = self.f_spPatternTable
    rs.sprSize = self.f_spriteSize
    rs.bgVis   = self.f_bgVisibility
    rs.spVis   = self.f_spVisibility
    self._bgDirty = false
    self._spriteDirty = false

    -- 强制启用渲染:某些游戏 NMI handler 没正确设 PPUMASK,这里兜底
    -- (这个 hack 还在,先不动 —— 它只在第 5 帧之后生效一次)
    -- 仅对启用了 SMB1 兼容 hack 的 ROM 生效:Mapper0 + SMB1 字节签名命中。
    -- 其它游戏(MMC1/MMC3...)各自的 NMI handler 会按自己时序写 PPUMASK,
    -- 在它们还没准备好时强开会显示半成品画面,反而出问题。
    if (self.nes._smb1HackEnabled) and fc >= 5 and self.f_bgVisibility == 0 then
        self.f_bgVisibility = 1
        self.f_spVisibility = 1
    end

    -- 刷新调色板缓存(BG 与 sprite palette 共用 readVRAM,任一路重画都需要新鲜的 palette)
    for p = 0, 3 do
        for c = 1, 3 do
            local colorIndex = self:readVRAM(0x3F00 + p * 4 + c) % 64
            self._paletteCache[p * 4 + c] = self.palette[colorIndex] or 0
            local sprColorIndex = self:readVRAM(0x3F10 + p * 4 + c) % 64
            self._spritePaletteCache[p * 4 + c] = self.palette[sprColorIndex] or 0
        end
    end

    self._bgColor = self.palette[self:readVRAM(0x3F00) % 64] or 0

    -- 兜底:第 4 帧 SMB1 仍未写入调色板,塞默认 SMB1 调色板
    -- (历史 hack,SMB1 实际会写,但部分时序边界可能漏掉)
    -- 仅对 SMB1 ROM 生效;其它游戏的调色板由它们自己的 NMI handler 写,不能覆盖。
    if (self.nes._smb1HackEnabled) and fc == 4 then
        local bg1 = self:readVRAM(0x3F01)
        if bg1 == 0 then
            local defaultPal = {0x0F, 0x30, 0x21, 0x12, 0x0F, 0x2A, 0x36, 0x17, 0x0F, 0x30, 0x27, 0x17, 0x0F, 0x30, 0x16, 0x12}
            for i = 0, 15 do
                self.vramMem[0x3F00 + i] = toU8(defaultPal[i + 1])
            end
            self._paletteCache = {}
            self._spritePaletteCache = {}
            -- palette 全替换 → BG output cache 也作废
            self._bgTileOutputCache = {}
            for p = 0, 3 do
                for c = 1, 3 do
                    local colorIndex = self:readVRAM(0x3F00 + p * 4 + c) % 64
                    self._paletteCache[p * 4 + c] = self.palette[colorIndex] or 0
                    local sprColorIndex = self:readVRAM(0x3F10 + p * 4 + c) % 64
                    self._spritePaletteCache[p * 4 + c] = self.palette[sprColorIndex] or 0
                end
            end
        end
    end

    local buf = self.buffer
    local bgbuf = self.bgbuffer
    local pixren = self.pixrendered
    local bufSize = 256 * 240

    -- ----------------------------------------------------------------
    -- BG 重画:仅在 needBg 时执行
    -- 输出写到 bgbuffer + pixrendered(都是持久化的,sprite 渲染会用)。
    -- ----------------------------------------------------------------
    if needBg then
        -- 刷新 nametable 缓存(从 vramMem 经镜像表查表)
        local ntCache = self._ntCache
        local mirrorTable = self.vramMirrorTable
        local vramMem = self.vramMem
        for addr = 0x2000, 0x2FFF do
            local mappedAddr = mirrorTable[addr] or addr
            ntCache[addr] = vramMem[mappedAddr] or 0
        end

        -- 清空 bgbuffer + pixrendered 给 BG 重新铺底
        local bgColor = self._bgColor
        for i = 0, bufSize - 1 do
            bgbuf[i] = bgColor
            pixren[i] = 0
        end

        if self.f_bgVisibility == 1 then
            for y = 0, 239 do
                self:renderBackground(y)
            end
        end
    end

    -- ----------------------------------------------------------------
    -- 合成 buffer 的两条路径:
    --   A. needBg=true → frameMode="full":整屏 bgbuffer→buffer 拷贝,
    --      上一帧 sprite 痕迹随新 BG 一并覆盖,renderer 必须全屏扫描。
    --   B. needBg=false → frameMode="partial":BG 未变,buffer 上还残留上一帧合成结果。
    --      仅遍历上一帧 sprite 像素列表(_prevSpritePixels)从 bgbuffer 恢复 BG。
    --      renderer 仅扫描 (撤销 ∪ 新画) 区域,代价 O(sprite像素数) ≈ 1.5k-3k。
    -- 两条路径完成后画新 sprite,本帧 sprite 像素累入 _curSpritePixels。
    -- ----------------------------------------------------------------
    if needBg then
        for i = 0, bufSize - 1 do
            buf[i] = bgbuf[i]
        end
        self._frameMode = "full"
    else
        -- 仅 sprite dirty:从 bgbuffer 恢复上一帧 sprite 占位
        local prevList = self._prevSpritePixels
        local prevN = self._prevSpriteN
        for k = 1, prevN do
            local idx = prevList[k]
            buf[idx] = bgbuf[idx]
        end
        self._frameMode = "partial"
        -- 把"撤销区域"也告诉 renderer,这些像素颜色发生了变化(从 sprite 色 → BG 色)
        self._frameUndoList = prevList
        self._frameUndoN = prevN
    end

    -- 本帧 sprite 写入计数清零,renderSpriteTile 会从 0 开始累加到 _curSpritePixels
    self._curSpriteN = 0

    -- ----------------------------------------------------------------
    -- sprite 渲染:画到 buffer,同时把写入的像素 index 累入 _curSpritePixels。
    -- 即使 needSprite=false 但 needBg=true,也得画 sprite —— BG 重画把上一帧 sprite 抹掉了。
    -- ----------------------------------------------------------------
    if self.f_spVisibility == 1 then
        self:_buildVisibleSpriteList()
        for y = 0, 239 do
            self:renderSprites(y)
        end
    else
        self._visibleSpritesCount = 0
    end

    -- ----------------------------------------------------------------
    -- 帧末:把本帧 sprite 像素列表喂给 renderer,然后 swap cur ↔ prev。
    -- swap 后 _prevSpritePixels 指向本帧列表,下一帧用它做撤销。
    -- ----------------------------------------------------------------
    self._frameNewList = self._curSpritePixels
    self._frameNewN = self._curSpriteN

    local tmpList = self._prevSpritePixels
    local tmpN = self._prevSpriteN
    self._prevSpritePixels = self._curSpritePixels
    self._prevSpriteN = self._curSpriteN
    self._curSpritePixels = tmpList
    self._curSpriteN = tmpN
end

-- 渲染扫描线（简化版）
function PPU:renderScanline(y)
    if y < 0 or y >= 240 then return end

    if self.f_bgVisibility == 1 then
        self:renderBackground(y)
    end

    if self.f_spVisibility == 1 then
        self:renderSprites(y)
    end
end

-- ================================================================
-- cycle-accurate 逐扫描线渲染实现(非 SMB1 游戏)
-- ----------------------------------------------------------------
-- 与单快照 renderFrame 的本质区别:CPU/PPU 交错推进,每条可见行在它
-- "结束"的时刻(endScanline)被渲染,读取此刻活动的 v 寄存器 + CHR bank,
-- 并即时计算真实 sprite 0 hit。这让游戏的 sprite0-hit 轮询循环能正常解锁,
-- 也支持 mid-frame 改滚动/bank 的 raster split(松鼠大作战2 标题等)。
--
-- v/t 模型(Loopy):
--   帧首        v = t        (_slBeginFrame,等价 pre-render 行的 t→v)
--   每行末      v 垂直自增    (_slIncVertical,NES dot 256)
--   每行起      v 水平位 = t  (_slCopyHorizontal,NES dot 257)
-- ================================================================

-- 帧首初始化:v=t、快照 palette/nametable、清缓冲、建可见 sprite 列表
function PPU:_slBeginFrame()
    self._slActive = true
    self:_loadVFromT()

    -- palette 快照
    for p = 0, 3 do
        for c = 1, 3 do
            local ci = self:readVRAM(0x3F00 + p * 4 + c) % 64
            self._paletteCache[p * 4 + c] = self.palette[ci] or 0
            local si = self:readVRAM(0x3F10 + p * 4 + c) % 64
            self._spritePaletteCache[p * 4 + c] = self.palette[si] or 0
        end
    end
    self._bgColor = self.palette[self:readVRAM(0x3F00) % 64] or 0

    -- nametable 快照(经镜像表)
    local ntCache = self._ntCache
    local mirrorTable = self.vramMirrorTable
    local vramMem = self.vramMem
    for addr = 0x2000, 0x2FFF do
        ntCache[addr] = vramMem[mirrorTable[addr] or addr] or 0
    end

    -- 清 bgbuffer/pixrendered/buffer
    local bgColor = self._bgColor
    local bgbuf = self.bgbuffer
    local pixren = self.pixrendered
    local buf = self.buffer
    for i = 0, 256 * 240 - 1 do
        bgbuf[i] = bgColor
        pixren[i] = 0
        buf[i] = bgColor
    end

    -- 可见 sprite 列表(整帧用 OAM 帧首快照)
    self:_buildVisibleSpriteList()
    self._curSpriteN = 0
end

-- v 垂直自增(NES dot 256)
function PPU:_slIncVertical()
    local v = self.vramAddress
    if band(v, 0x7000) ~= 0x7000 then
        v = v + 0x1000
    else
        v = band(v, 0x0FFF)
        local y = band(rshift(v, 5), 0x1F)
        if y == 29 then
            y = 0
            v = bxor(v, 0x0800)
        elseif y == 31 then
            y = 0
        else
            y = y + 1
        end
        v = bor(band(v, 0x7C1F), lshift(y, 5))
    end
    self.vramAddress = toU16(v)
    self:_syncRegsFromV()
end

-- v 水平位从 t 恢复(NES dot 257):coarse X(bit0-4)+ 水平 nametable(bit10)
function PPU:_slCopyHorizontal()
    self.vramAddress = bor(band(self.vramAddress, 0x7BE0), band(self.vramTmpAddress, 0x041F))
    self:_syncRegsFromV()
end

-- 渲染一条可见行:BG(用 live v)→ 合成到 buffer → sprite(带真实 sprite0 hit)
function PPU:_slRenderLine(y)
    if self.f_bgVisibility == 1 then
        self:_slRenderBgLine(y)
    end

    -- 合成本行 BG → buffer(sprite 会在其上覆盖)
    local buf = self.buffer
    local bgbuf = self.bgbuffer
    local base = y * 256
    for x = 0, 255 do
        buf[base + x] = bgbuf[base + x]
    end

    -- sprite:复用现有 renderSprites(y)/renderSpriteTile,内含 sprite0 hit 检测
    if self.f_spVisibility == 1 then
        self:renderSprites(y)
    end
end

-- 用当前 v 渲染一条 BG 扫描线到 bgbuffer(完全按 v 取景,无任何 hack)
function PPU:_slRenderBgLine(y)
    local v = self.vramAddress
    local coarseX = band(v, 0x1F)
    local coarseY = band(rshift(v, 5), 0x1F)
    local ntBase  = band(rshift(v, 10), 0x3)
    local fineY   = band(rshift(v, 12), 0x7)
    local fineX   = self.regFH

    local highTable = self.f_bgPatternTable == 1
    local ntCache = self._ntCache
    local renderTile = self.renderTile

    for tileX = 0, 32 do
        local cx = coarseX + tileX
        local sel = ntBase
        if cx >= 32 then
            cx = cx - 32
            sel = bxor(sel, 1)
        end
        local cy = coarseY
        if cy >= 30 then
            cy = cy - 30
            sel = bxor(sel, 2)
        end

        local nameTableAddr = 0x2000 + sel * 0x400
        local tileIndex = ntCache[nameTableAddr + cy * 32 + cx] or 0
        local attrAddr = nameTableAddr + 0x3C0 + math.floor(cy / 4) * 8 + math.floor(cx / 4)
        local attr = ntCache[attrAddr] or 0
        local shift = band(cx, 2) + lshift(band(cy, 2), 1)
        local paletteNum = band(rshift(attr, shift), 3)

        renderTile(self, tileX * 8 - fineX, y, tileIndex, paletteNum, highTable, fineY)
    end
end

-- 帧末收尾:逐扫描线模式 BG/sprite 已逐行画进 buffer,这里只设元数据。
function PPU:_slFinishFrame()
    -- 兜底:整帧无可见行触发(理论上不会),至少铺底色
    if not self._slActive then
        self:_slBeginFrame()
    end
    -- 逐扫描线模式总是整屏 present
    self._frameMode = "full"
    self._frameUndoN = 0
    self._frameNewList = self._curSpritePixels
    self._frameNewN = self._curSpriteN
    self._slActive = false
end

-- 渲染背景
-- ----------------------------------------------------------------
-- SMB1 split-screen scroll 模拟:
--   真机用 sprite 0 hit + mid-scanline scroll 让屏幕分两部分:
--     y=0..31  状态栏(MARIO 000000 ...) — 不滚动
--     y=32..239 游戏区域 — 横向滚动
--   我们的简化 PPU 不模拟扫描线时序,这里用 y 范围硬切。
--   状态栏始终从 nametable $2000 顶部读,scroll=0、Y scroll=0、nt=0。
--   游戏区域用 PPUSCROLL 写入的滚动量。
-- 仅对 SMB1(_smb1HackEnabled)启用:这是针对 SMB1 顶部状态栏的专用近似。
-- 其它游戏(松鼠大作战等 MMC1/MMC3)整屏用同一滚动量,硬切会把顶部 32 像素
-- 错按 scroll=0 渲染,造成顶部错位/花屏 —— 所以非 SMB1 一律走真实滚动量。
-- ----------------------------------------------------------------
function PPU:renderBackground(y)
    local scrollX, scrollY, baseNT
    if self.nes._smb1HackEnabled and y < 32 then
        -- SMB1 状态栏区域:固定在 nametable $2000 顶部,不滚动
        scrollX = 0
        scrollY = 0
        baseNT = 0
    else
        -- 正常用 reg* 滚动量
        scrollX = self.regHT * 8 + self.regFH
        scrollY = self.regVT * 8 + self.regFV
        baseNT = self.f_nTblAddress
    end

    local fineX = scrollX % 8
    local fineY = (scrollY + y) % 8

    local highTable = self.f_bgPatternTable == 1
    local ntCache = self._ntCache
    local renderTile = self.renderTile
    
    for tileX = 0, 32 do
        local ntX = math.floor(scrollX / 8) + tileX
        local ntY = math.floor((scrollY + y) / 8)
        
        local ntSelect = baseNT
        if ntX >= 32 then
            ntX = ntX % 32
            ntSelect = bxor(ntSelect, 1)
        end
        if ntY >= 30 then
            ntY = ntY % 30
            ntSelect = bxor(ntSelect, 2)
        end
        
        local nameTableAddr = 0x2000 + ntSelect * 0x400
        
        local tileIndex = ntCache[nameTableAddr + ntY * 32 + ntX] or 0
        local attrAddr = nameTableAddr + 0x3C0 + math.floor(ntY / 4) * 8 + math.floor(ntX / 4)
        local attr = ntCache[attrAddr] or 0
        local shift = band(ntX, 2) + lshift(band(ntY, 2), 1)
        local paletteNum = band(rshift(attr, shift), 3)
        
        renderTile(self, tileX * 8 - fineX, y, tileIndex, paletteNum, highTable, fineY)
    end
end

-- 渲染单个 BG tile
-- 输出写到 bgbuffer + pixrendered(持久化的 BG 画面),不写 buffer。
-- buffer 是 BG + sprite 合成结果,由 renderFrame 在 BG 重画后做 bgbuffer→buffer 拷贝,
-- sprite 渲染则直接覆盖 buffer 上需要的像素。
--
-- 优化:两级 cache。
--   _bgTileOutputCache(快):存"已应用 palette 的 RGB 像素 + 透明掩码",命中直接拷贝。
--   _bgTileCache(慢): 存 raw pattern 字节,新组合 (tileIndex, palette, highTable)
--                     第一次访问 miss output cache 时,从这里取 raw,做完 palette 应用
--                     后写入 output cache。
-- output cache 命中后:8 行 × 8 像素 = 64 次拷贝,无 bit op。
-- output cache miss 后:解码 + palette 应用 + 写入两级 cache,首次 ~64 bit op + 64 lookup。
function PPU:renderTile(x, y, tileIndex, paletteNum, highTable, tileY)
    -- output cache key:tileIndex(0..511) × 8 + paletteNum(0..3) × 2 + highTable(0..1)
    -- 三元组合所有 SMB1 关卡用过的不同 (tile, palette, pt) 组合大概 200-400 个。
    local outKey = tileIndex * 8 + paletteNum * 2 + (highTable and 1 or 0)
    local outRows = self._bgTileOutputCache[outKey]

    if not outRows then
        -- output cache miss:走解码路径,顺便生成 output cache 项。
        -- 先取 raw pattern(从 _bgTileCache,SMB1 是 CHR-ROM 整局只解码一次)。
        local rawKey = tileIndex * 2 + (highTable and 1 or 0)
        local rawRows = self._bgTileCache[rawKey]
        if not rawRows then
            local patternAddr = (highTable and 0x1000 or 0x0000) + tileIndex * 16
            rawRows = {}
            for row = 0, 7 do
                rawRows[row] = {
                    self:readVRAM(patternAddr + row),
                    self:readVRAM(patternAddr + row + 8)
                }
            end
            self._bgTileCache[rawKey] = rawRows
        end

        -- 应用 palette:对 8 行 × 8 像素逐位 decode + palette lookup,生成 RGB。
        -- 透明像素(colorNum=0,即 BG 默认色)用 -1 sentinel 表示"renderTile 不写 bgbuf"。
        -- 此 sentinel 在拷贝路径会被跳过(参见下面的 _renderTileCopy)。
        local paletteCache = self._paletteCache
        local paletteBase = paletteNum * 4
        outRows = {}
        for row = 0, 7 do
            local lowByte = rawRows[row][1]
            local highByte = rawRows[row][2]
            local rowOut = {}
            for px = 0, 7 do
                local bitPos = 7 - px
                local lowBit = band(rshift(lowByte, bitPos), 1)
                local highBit = band(rshift(highByte, bitPos), 1)
                local colorNum = lowBit + highBit * 2
                if colorNum == 0 then
                    rowOut[px] = -1
                else
                    rowOut[px] = paletteCache[paletteBase + colorNum] or 0
                end
            end
            outRows[row] = rowOut
        end
        self._bgTileOutputCache[outKey] = outRows
    end

    -- 拷贝路径:从 outRows[tileY] 取一行 8 像素到 bgbuf。
    -- 透明像素(value=-1)跳过,与原 renderTile "colorNum==0 不写"语义一致。
    local rowOut = outRows[tileY]
    local bgbuf = self.bgbuffer
    local pixren = self.pixrendered
    local rowBase = y * 256

    for px = 0, 7 do
        local color = rowOut[px]
        if color ~= -1 then
            local screenX = x + px
            if screenX >= 0 and screenX < 256 then
                local bufferIndex = rowBase + screenX
                bgbuf[bufferIndex] = color
                pixren[bufferIndex] = 1
            end
        end
    end
end

-- 渲染精灵
-- 渲染前一次性扫描 OAM,挑出可见 sprite(Y < 240 的)放进 _visibleSprites 列表。
-- 旧版 renderSprites 每行扫 64 次 OAM = 15360 次/帧,
-- 实际 SMB1 demo 模式可见 sprite 通常 10-20 个,新版每行只看这些。
-- 列表存 6 元组: [1]=spriteIndex, [2]=spriteY, [3]=tileIndex, [4]=attributes, [5]=spriteX, [6]=spriteHeight
-- (spriteHeight 这里冗余,但避免 renderSprites 内每个 sprite 重新算)
function PPU:_buildVisibleSpriteList()
    local list = self._visibleSprites
    if not list then
        list = {}
        self._visibleSprites = list
    end
    local count = 0
    local oam = self.spriteMem
    local h = self.f_spriteSize == 1 and 16 or 8
    for i = 0, 63 do
        local base = i * 4
        local sprY = oam[base]
        if sprY < 240 then
            count = count + 1
            local entry = list[count]
            if entry then
                entry[1] = i
                entry[2] = sprY
                entry[3] = oam[base + 1]
                entry[4] = oam[base + 2]
                entry[5] = oam[base + 3]
                entry[6] = h
            else
                list[count] = { i, sprY, oam[base + 1], oam[base + 2], oam[base + 3], h }
            end
        end
    end
    self._visibleSpritesCount = count
end

function PPU:renderSprites(y)
    local count = self._visibleSpritesCount or 0
    if count == 0 then return end

    local list = self._visibleSprites
    local spritesRendered = 0

    for k = 1, count do
        local entry = list[k]
        local i           = entry[1]
        local spriteY     = entry[2]
        local tileIndex   = entry[3]
        local attributes  = entry[4]
        local spriteX     = entry[5]
        local spriteHeight = entry[6]

        if spriteY <= y and y < spriteY + spriteHeight then
            if spritesRendered >= 8 then
                self:setStatusFlag(self.STATUS_SLSPRITECOUNT, true)
                break
            end

            local vertFlip   = band(rshift(attributes, 7), 1) == 1
            local horizFlip  = band(rshift(attributes, 6), 1) == 1
            local paletteNum = band(attributes, 3)
            local bgPriority = band(rshift(attributes, 5), 1) == 1

            local tileY = y - spriteY
            if vertFlip then
                tileY = spriteHeight - 1 - tileY
            end

            self:renderSpriteTile(spriteX, y, tileIndex, tileY, paletteNum, horizFlip, bgPriority, i == 0)
            spritesRendered = spritesRendered + 1
        end
    end
end

-- 旧版 renderSprites,逐 OAM 扫描 64 次。保留供单行场景调用。
-- renderFrame 已切换到 _buildVisibleSpriteList + 优化版 renderSprites,
-- 所以下面这个函数实际不再被 renderFrame 调用。
function PPU:renderSpritesLegacy(y)
    local spriteHeight = self.f_spriteSize == 1 and 16 or 8
    local spritesRendered = 0
    
    -- 评估精灵（简化版）
    for i = 0, 63 do
        local spriteY = self.spriteMem[i * 4 + 0]
        local tileIndex = self.spriteMem[i * 4 + 1]
        local attributes = self.spriteMem[i * 4 + 2]
        local spriteX = self.spriteMem[i * 4 + 3]
        
        -- 检查精灵是否在当前扫描线上
        if spriteY <= y and y < spriteY + spriteHeight and spriteY < 240 then
            if spritesRendered >= 8 then
                -- 精灵溢出
                self:setStatusFlag(self.STATUS_SLSPRITECOUNT, true)
                break
            end
            
            local vertFlip = band(rshift(attributes, 7), 1) == 1
            local horizFlip = band(rshift(attributes, 6), 1) == 1
            local paletteNum = band(rshift(attributes, 0), 3)
            local bgPriority = band(rshift(attributes, 5), 1) == 1
            
            -- 渲染精灵 tile
            local tileY = y - spriteY
            if vertFlip then
                tileY = spriteHeight - 1 - tileY
            end
            
            self:renderSpriteTile(spriteX, y, tileIndex, tileY, paletteNum, horizFlip, bgPriority, i == 0)
            spritesRendered = spritesRendered + 1
        end
    end
end

-- 渲染精灵 tile
function PPU:renderSpriteTile(x, y, tileIndex, tileY, paletteNum, horizFlip, bgPriority, isSprite0)
    local patternAddr
    
    if self.f_spriteSize == 1 then
        local bank = band(tileIndex, 1) * 0x1000
        local index = band(tileIndex, 0xFE)
        if tileY >= 8 then
            index = index + 1
            tileY = tileY - 8
        end
        patternAddr = bank + index * 16
    else
        patternAddr = (self.f_spPatternTable == 1 and 0x1000 or 0x0000) + tileIndex * 16
    end
    
    local cacheKey = patternAddr
    local tileRows = self._spriteTileCache[cacheKey]
    if not tileRows then
        tileRows = {}
        for row = 0, 7 do
            tileRows[row] = {
                self:readVRAM(patternAddr + row),
                self:readVRAM(patternAddr + row + 8)
            }
        end
        self._spriteTileCache[cacheKey] = tileRows
    end

    local rowData = tileRows[tileY]
    local lowByte = rowData[1]
    local highByte = rowData[2]

    local spritePaletteCache = self._spritePaletteCache
    local paletteBase = paletteNum * 4
    local bgColor = self._bgColor
    local buf = self.buffer
    local pixren = self.pixrendered
    -- sprite 像素累计:每写一个 buf 像素就把 index 追加到 _curSpritePixels。
    -- 用本地变量避免每次循环 self.* 查表。
    local curList = self._curSpritePixels
    local curN = self._curSpriteN

    for px = 0, 7 do
        local bitPos = horizFlip and px or (7 - px)
        local lowBit = band(rshift(lowByte, bitPos), 1)
        local highBit = band(rshift(highByte, bitPos), 1)
        local colorNum = lowBit + highBit * 2

        if colorNum ~= 0 then
            local screenX = x + px
            if screenX >= 0 and screenX < 256 then
                local bufferIndex = y * 256 + screenX

                if isSprite0 and pixren[bufferIndex] == 1 and not self.hitSpr0 then
                    if self.f_bgVisibility == 1 and self.f_spVisibility == 1 then
                        self:setStatusFlag(self.STATUS_SPRITE0HIT, true)
                        self.hitSpr0 = true
                    end
                end

                if not bgPriority or pixren[bufferIndex] == 0 then
                    local color = spritePaletteCache[paletteBase + colorNum] or bgColor
                    buf[bufferIndex] = color
                    -- 累加到本帧 sprite 列表(数组复用,避免 GC)
                    curN = curN + 1
                    curList[curN] = bufferIndex
                end
            end
        end
    end

    self._curSpriteN = curN
end

return PPU
