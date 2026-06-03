-- CPU.lua
-- 6502 CPU 模拟器核心
-- 基于 JSNES 的 cpu.js 移植

-- 性能:把 BitOps 的包装层去掉,直接用 bit 库的 5 个函数 + 局部缓存。
-- BitOps 包装版每次调用都多 1 层 Lua 函数 + 2 个 `or 0` 默认值检查;
-- 这里假设运行时数据正确,直接取 local bit 引用,emulate 热路径减重。
local band   = bit.band
local bor    = bit.bor
local bxor   = bit.bxor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift

-- 性能优化:把 cpu:load / cpu:write 改成模块级 local 函数,避免每次调用
-- 都做 method dispatch(metatable lookup + self 绑定)。
-- 内联快速路径:0x0000-0x1FFF 直接命中 cpu.mem(RAM 镜像);其它走 mapper。
-- 6502 程序绝大部分指令访问 RAM,这条捷径能砍掉每帧 ~3-4 万次 method call。
local function cpuLoad(cpu, addr)
    addr = band(addr, 0xFFFF)
    if addr < 0x2000 then
        return cpu.mem[band(addr, 0x7FF)]
    else
        return cpu.nes:memoryMapperLoad(addr)
    end
end

local function cpuWrite(cpu, addr, value)
    addr = band(addr, 0xFFFF)
    value = band(value, 0xFF)
    if addr < 0x2000 then
        cpu.mem[band(addr, 0x7FF)] = value
    else
        cpu.nes:memoryMapperWrite(addr, value)
    end
end

local function cpuLoad16(cpu, addr)
    return bor(cpuLoad(cpu, addr), lshift(cpuLoad(cpu, addr + 1), 8))
end

-- 创建全局 CPU 表
_G.CPU = {}
CPU.__index = CPU

-- IRQ 类型
CPU.IRQ_NORMAL = 0
CPU.IRQ_NMI = 1
CPU.IRQ_RESET = 2

-- 寻址模式
CPU.ADDR_ZP = 0
CPU.ADDR_REL = 1
CPU.ADDR_IMP = 2
CPU.ADDR_ABS = 3
CPU.ADDR_ACC = 4
CPU.ADDR_IMM = 5
CPU.ADDR_ZPX = 6
CPU.ADDR_ZPY = 7
CPU.ADDR_ABSX = 8
CPU.ADDR_ABSY = 9
CPU.ADDR_PREIDXIND = 10
CPU.ADDR_POSTIDXIND = 11
CPU.ADDR_INDABS = 12

-- 指令常量
CPU.INS_ADC = 0
CPU.INS_AND = 1
CPU.INS_ASL = 2
CPU.INS_BCC = 3
CPU.INS_BCS = 4
CPU.INS_BEQ = 5
CPU.INS_BIT = 6
CPU.INS_BMI = 7
CPU.INS_BNE = 8
CPU.INS_BPL = 9
CPU.INS_BRK = 10
CPU.INS_BVC = 11
CPU.INS_BVS = 12
CPU.INS_CLC = 13
CPU.INS_CLD = 14
CPU.INS_CLI = 15
CPU.INS_CLV = 16
CPU.INS_CMP = 17
CPU.INS_CPX = 18
CPU.INS_CPY = 19
CPU.INS_DEC = 20
CPU.INS_DEX = 21
CPU.INS_DEY = 22
CPU.INS_EOR = 23
CPU.INS_INC = 24
CPU.INS_INX = 25
CPU.INS_INY = 26
CPU.INS_JMP = 27
CPU.INS_JSR = 28
CPU.INS_LDA = 29
CPU.INS_LDX = 30
CPU.INS_LDY = 31
CPU.INS_LSR = 32
CPU.INS_NOP = 33
CPU.INS_ORA = 34
CPU.INS_PHA = 35
CPU.INS_PHP = 36
CPU.INS_PLA = 37
CPU.INS_PLP = 38
CPU.INS_ROL = 39
CPU.INS_ROR = 40
CPU.INS_RTI = 41
CPU.INS_RTS = 42
CPU.INS_SBC = 43
CPU.INS_SEC = 44
CPU.INS_SED = 45
CPU.INS_SEI = 46
CPU.INS_STA = 47
CPU.INS_STX = 48
CPU.INS_STY = 49
CPU.INS_TAX = 50
CPU.INS_TAY = 51
CPU.INS_TSX = 52
CPU.INS_TXA = 53
CPU.INS_TXS = 54
CPU.INS_TYA = 55

-- 构造函数
function CPU:new(nes)
    local cpu = setmetatable({}, self)
    cpu.nes = nes
    
    -- 寄存器
    cpu.REG_ACC = 0     -- 累加器
    cpu.REG_X = 0       -- X 索引寄存器
    cpu.REG_Y = 0       -- Y 索引寄存器
    cpu.REG_PC = 0      -- 程序计数器
    cpu.REG_SP = 0xFF   -- 栈指针
    
    -- 标志位
    cpu.F_CARRY = 0
    cpu.F_ZERO = 0
    cpu.F_INTERRUPT = 1
    cpu.F_DECIMAL = 0
    cpu.F_BRK = 0
    cpu.F_NOTUSED = 1
    cpu.F_OVERFLOW = 0
    cpu.F_SIGN = 0
    
    -- 临时存储
    cpu.REG_PC_NEW = 0
    cpu.F_INTERRUPT_NEW = 0
    cpu.F_BRK_NEW = 0
    
    -- 中断状态
    cpu.irqRequested = false
    cpu.irqType = 0
    cpu.nmiRaised = false
    cpu.instrBusCycles = 0
    cpu.cyclesToHalt = 0
    cpu._cpuCycleBase = 0
    cpu._cycleCount = 0
    cpu._opcodeTable = CPU._opcodeTable
    
    -- 内存 (64KB)
    cpu.mem = {}
    for i = 0, 0xFFFF do
        cpu.mem[i] = 0
    end
    
    return cpu
end

-- 重置 CPU
function CPU:reset()
    self.REG_ACC = 0
    self.REG_X = 0
    self.REG_Y = 0
    self.REG_SP = 0xFF
    self.REG_PC = 0
    
    self.F_CARRY = 0
    self.F_ZERO = 0
    self.F_INTERRUPT = 1
    self.F_DECIMAL = 0
    self.F_BRK = 0
    self.F_NOTUSED = 1
    self.F_OVERFLOW = 0
    self.F_SIGN = 0
    
    self.irqRequested = false
    self.irqType = 0
    self.nmiRaised = false
    self.instrBusCycles = 0
    self.cyclesToHalt = 0
    self._cpuCycleBase = 0
    self._cycleCount = 0
    
    -- 从复位向量读取 PC
    self.REG_PC = cpuLoad16(self, 0xFFFC)
end

-- 从内存读取一个字节(对外保留 method 形式,内部走 local 快速路径)
function CPU:load(addr)
    return cpuLoad(self, addr)
end

function CPU:write(addr, value)
    cpuWrite(self, addr, value)
end

-- 读取 16 位值 (小端序)
function CPU:load16bit(addr)
    return cpuLoad16(self, addr)
end

-- 写入 16 位值
function CPU:write16bit(addr, value)
    cpuWrite(self, addr, band(value, 0xFF))
    cpuWrite(self, addr + 1, rshift(value, 8))
end

-- 栈操作
function CPU:push(value)
    cpuWrite(self, 0x100 + self.REG_SP, value)
    self.REG_SP = band(self.REG_SP - 1, 0xFF)
end

function CPU:pull()
    self.REG_SP = band(self.REG_SP + 1, 0xFF)
    return cpuLoad(self, 0x100 + self.REG_SP)
end

-- 获取状态寄存器
function CPU:getStatus()
    return bor(
        self.F_CARRY,
        lshift(self.F_ZERO, 1),
        lshift(self.F_INTERRUPT, 2),
        lshift(self.F_DECIMAL, 3),
        lshift(self.F_BRK, 4),
        lshift(self.F_NOTUSED, 5),
        lshift(self.F_OVERFLOW, 6),
        lshift(self.F_SIGN, 7)
    )
end

-- 设置状态寄存器
function CPU:setStatus(value)
    self.F_CARRY = band(value, 1)
    self.F_ZERO = band(rshift(value, 1), 1)
    self.F_INTERRUPT = band(rshift(value, 2), 1)
    self.F_DECIMAL = band(rshift(value, 3), 1)
    self.F_BRK = band(rshift(value, 4), 1)
    self.F_NOTUSED = band(rshift(value, 5), 1)
    self.F_OVERFLOW = band(rshift(value, 6), 1)
    self.F_SIGN = band(rshift(value, 7), 1)
end

-- 触发 IRQ
function CPU:requestIrq(type)
    if type == CPU.IRQ_NMI then
        self.nmiRaised = true
    else
        self.irqRequested = true
        self.irqType = type
    end
end

-- 执行 IRQ
function CPU:doIrq(status)
    self:push(rshift(self.REG_PC, 8))
    self:push(band(self.REG_PC, 0xFF))
    self:push(status)
    self.F_INTERRUPT = 1
    self.REG_PC = cpuLoad16(self, 0xFFFE)
end

-- 执行 NMI
function CPU:doNonMaskableInterrupt(status)
    self:push(rshift(self.REG_PC, 8))
    self:push(band(self.REG_PC, 0xFF))
    self:push(status)
    self.F_INTERRUPT = 1
    self.REG_PC = cpuLoad16(self, 0xFFFA)
end

-- 执行复位中断
function CPU:doResetInterrupt()
    self.REG_PC = cpuLoad16(self, 0xFFFC)
    self.F_INTERRUPT = 1
end

-- 主执行函数 (简化版)
-- 性能:本函数每帧调用 12000+ 次,任何 method 调用、metatable 查表都被放大成大开销。
-- 已做优化:
--   1) opcode 取指走 cpuLoad(local 函数),省掉 self:load 的 method dispatch
--   2) opcode 分发表用 local 引用 _opcodeTableLocal,避免每次 self._opcodeTable 查 hash
--   3) handler 调用直接 handler(self, opcode),无 method 包装层
-- 中断路径(NMI/IRQ)不在每帧热路径上,保留 method 调用形式无所谓。
local _opcodeTableLocal -- 在 _buildOpcodeTable 之后赋值
function CPU:emulate()
    if self.nmiRaised then
        self.nmiRaised = false
        self:doNonMaskableInterrupt(band(self:getStatus(), 0xEF))
        self._cpuCycleBase = self._cpuCycleBase + 7
        return 7
    end

    local interruptCycles = 0

    if self.irqRequested then
        -- self.irqRequested 是 boolean(由 requestIrq 置 true),不是 status 寄存器值。
        -- 早期版本误把 boolean 当 status 喂给 band → 启用 IRQ 的 mapper(MMC3 等)首次
        -- 中断时崩。这里和 NMI 路径一样,直接取当前 status。
        -- 0xEF 用于清 B 标志(NES 真机:硬件中断 push 的 status 中 B=0)。
        self.irqRequested = false
        local status = band(self:getStatus(), 0xEF)

        if self.irqType == CPU.IRQ_NORMAL then
            if self.F_INTERRUPT == 0 then
                self:doIrq(status)
                interruptCycles = 7
            end
        elseif self.irqType == CPU.IRQ_RESET then
            self:doResetInterrupt()
            interruptCycles = 7
        elseif self.irqType == CPU.IRQ_NMI then
            -- 注意:NMI 不该走 IRQ 路径(本类 requestIrq 对 NMI 单独走 nmiRaised),
            -- 这里保留分支只为兼容外部代码可能直接置 irqType=IRQ_NMI 的情况。
            self:doNonMaskableInterrupt(status)
            interruptCycles = 7
        end
    end

    local opcode = cpuLoad(self, self.REG_PC)

    local cycleCount = 2

    local handler = _opcodeTableLocal[opcode]
    if handler then
        cycleCount = handler(self, opcode)
    else
        self.REG_PC = self.REG_PC + 1
        cycleCount = 2
    end

    self._cpuCycleBase = self._cpuCycleBase + cycleCount + interruptCycles
    return cycleCount + interruptCycles
end

local function _setNZ(self, value)
    self.F_SIGN = band(rshift(value, 7), 1)
    self.F_ZERO = value == 0 and 1 or 0
end

local function _branch(self, flag, opcode)
    if flag ~= 0 then
        local offset = cpuLoad(self, self.REG_PC + 1)
        if offset > 127 then offset = offset - 256 end
        local basePC = self.REG_PC + 2
        local newPC = band(basePC + offset, 0xFFFF)
        self.REG_PC = newPC
        if band(basePC, 0xFF00) ~= band(newPC, 0xFF00) then
            return 4
        end
        return 3
    else
        self.REG_PC = self.REG_PC + 2
        return 2
    end
end

local AM_IMM = 1
local AM_ZP = 2
local AM_ZPX = 3
local AM_ZPY = 4
local AM_ABS = 5
local AM_ABSX = 6
local AM_ABSY = 7
local AM_INDX = 8
local AM_INDY = 9
local AM_ACC = 10

CPU._addrMode = {}
CPU._baseCycles = {}

do
    local m = CPU._addrMode
    local c = CPU._baseCycles

    for op = 0, 255 do
        local lo = band(op, 0x1F)

        if lo == 0x09 or lo == 0x02 or lo == 0x00 then
            m[op] = AM_IMM
            c[op] = 2
        elseif lo == 0x05 or lo == 0x06 or lo == 0x04 then
            m[op] = AM_ZP
            c[op] = 3
        elseif lo == 0x15 or lo == 0x16 or lo == 0x14 then
            m[op] = AM_ZPX
            c[op] = 4
        elseif lo == 0x0D or lo == 0x0E or lo == 0x0C then
            m[op] = AM_ABS
            c[op] = 4
        elseif lo == 0x1D or lo == 0x1E or lo == 0x1C then
            m[op] = AM_ABSX
            c[op] = 4
        elseif lo == 0x19 or lo == 0x1A or lo == 0x1B then
            m[op] = AM_ABSY
            c[op] = 4
        elseif lo == 0x01 then
            m[op] = AM_INDX
            c[op] = 6
        elseif lo == 0x11 then
            m[op] = AM_INDY
            c[op] = 5
        end
    end

    m[0xB6] = AM_ZPY; c[0xB6] = 4
    m[0x96] = AM_ZPY; c[0x96] = 4
    m[0xBE] = AM_ABSY; c[0xBE] = 4

    c[0x9D] = 5
    c[0x99] = 5
    c[0x91] = 6

    m[0x0A] = AM_ACC; c[0x0A] = 2
    m[0x4A] = AM_ACC; c[0x4A] = 2
    m[0x2A] = AM_ACC; c[0x2A] = 2
    m[0x6A] = AM_ACC; c[0x6A] = 2
end

CPU._noPageCrossPenalty = {}
do
    local n = CPU._noPageCrossPenalty
    local noPenalty = {
        0x9D, 0x99, 0x91, 0x81, 0x85, 0x95, 0x8D,
        0x8E, 0x86, 0x96,
        0x8C, 0x84, 0x94,
        0x1E, 0x5E, 0x3E, 0x7E, 0xDE, 0xFE,
        0xBE,
    }
    for _, op in ipairs(noPenalty) do
        n[op] = true
    end
end

-- 性能:把 decodeOperand 改成 module 级 local 函数,并缓存三个查表为 upvalue,
-- 避免每条指令的 self.* metatable lookup。
-- 暴露的 CPU:decodeOperand 仍保留为薄包装,供外部代码使用。
local _addrModeTable        = CPU._addrMode
local _baseCyclesTable      = CPU._baseCycles
local _noPageCrossTable     = CPU._noPageCrossPenalty

local function decodeOperand(cpu, opcode)
    local mode = _addrModeTable[opcode]
    if not mode then
        cpu.REG_PC = cpu.REG_PC + 1
        return 0, 2
    end

    if mode == AM_IMM then
        local addr = cpu.REG_PC + 1
        cpu.REG_PC = cpu.REG_PC + 2
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_ZP then
        local addr = cpuLoad(cpu, cpu.REG_PC + 1)
        cpu.REG_PC = cpu.REG_PC + 2
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_ZPX then
        local addr = band(cpuLoad(cpu, cpu.REG_PC + 1) + cpu.REG_X, 0xFF)
        cpu.REG_PC = cpu.REG_PC + 2
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_ZPY then
        local addr = band(cpuLoad(cpu, cpu.REG_PC + 1) + cpu.REG_Y, 0xFF)
        cpu.REG_PC = cpu.REG_PC + 2
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_ABS then
        local addr = cpuLoad16(cpu, cpu.REG_PC + 1)
        cpu.REG_PC = cpu.REG_PC + 3
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_ABSX then
        local base = cpuLoad16(cpu, cpu.REG_PC + 1)
        local addr = band(base + cpu.REG_X, 0xFFFF)
        cpu.REG_PC = cpu.REG_PC + 3
        local cycles = _baseCyclesTable[opcode]
        if not _noPageCrossTable[opcode] and band(base, 0xFF00) ~= band(addr, 0xFF00) then
            cycles = cycles + 1
        end
        return addr, cycles
    elseif mode == AM_ABSY then
        local base = cpuLoad16(cpu, cpu.REG_PC + 1)
        local addr = band(base + cpu.REG_Y, 0xFFFF)
        cpu.REG_PC = cpu.REG_PC + 3
        local cycles = _baseCyclesTable[opcode]
        if not _noPageCrossTable[opcode] and band(base, 0xFF00) ~= band(addr, 0xFF00) then
            cycles = cycles + 1
        end
        return addr, cycles
    elseif mode == AM_INDX then
        local zp = band(cpuLoad(cpu, cpu.REG_PC + 1) + cpu.REG_X, 0xFF)
        local lo = cpuLoad(cpu, zp)
        local hi = cpuLoad(cpu, band(zp + 1, 0xFF))
        local addr = bor(lo, lshift(hi, 8))
        cpu.REG_PC = cpu.REG_PC + 2
        return addr, _baseCyclesTable[opcode]
    elseif mode == AM_INDY then
        local zp = cpuLoad(cpu, cpu.REG_PC + 1)
        local lo = cpuLoad(cpu, zp)
        local hi = cpuLoad(cpu, band(zp + 1, 0xFF))
        local base = bor(lo, lshift(hi, 8))
        local addr = band(base + cpu.REG_Y, 0xFFFF)
        cpu.REG_PC = cpu.REG_PC + 2
        local cycles = _baseCyclesTable[opcode]
        if not _noPageCrossTable[opcode] and band(base, 0xFF00) ~= band(addr, 0xFF00) then
            cycles = cycles + 1
        end
        return addr, cycles
    end

    cpu.REG_PC = cpu.REG_PC + 1
    return 0, 2
end

-- 对外保留 method 形式
function CPU:decodeOperand(opcode)
    return decodeOperand(self, opcode)
end

function CPU:getOperandAddress(opcode)
    local addr = decodeOperand(self, opcode)
    return addr
end

function CPU:getCycles(opcode)
    return self._baseCycles[opcode] or 2
end

CPU._handlers = {}

function CPU._handlers.adc(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local temp = cpuLoad(self, addr)
    local add = temp + self.REG_ACC + self.F_CARRY
    local result = band(add, 0xFF)
    self.F_OVERFLOW = (band(band(bnot(bxor(self.REG_ACC, temp)), bxor(self.REG_ACC, result)), 0x80) ~= 0) and 1 or 0
    self.F_CARRY = (add > 0xFF) and 1 or 0
    self.REG_ACC = result
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.sbc(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local temp = cpuLoad(self, addr)
    local sub = self.REG_ACC - temp - (1 - self.F_CARRY)
    local result = band(sub, 0xFF)
    self.F_OVERFLOW = (band(band(bxor(self.REG_ACC, temp), bxor(self.REG_ACC, result)), 0x80) ~= 0) and 1 or 0
    self.F_CARRY = (sub >= 0) and 1 or 0
    self.REG_ACC = result
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.and_(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_ACC = band(self.REG_ACC, cpuLoad(self, addr))
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.ora(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_ACC = bor(self.REG_ACC, cpuLoad(self, addr))
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.eor(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_ACC = bxor(self.REG_ACC, cpuLoad(self, addr))
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.lda(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_ACC = cpuLoad(self, addr)
    _setNZ(self, self.REG_ACC)
    return cycles
end

function CPU._handlers.ldx(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_X = cpuLoad(self, addr)
    _setNZ(self, self.REG_X)
    return cycles
end

function CPU._handlers.ldy(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    self.REG_Y = cpuLoad(self, addr)
    _setNZ(self, self.REG_Y)
    return cycles
end

function CPU._handlers.sta(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    cpuWrite(self, addr, self.REG_ACC)
    return cycles
end

function CPU._handlers.stx(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    cpuWrite(self, addr, self.REG_X)
    return cycles
end

function CPU._handlers.sty(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    cpuWrite(self, addr, self.REG_Y)
    return cycles
end

function CPU._handlers.cmp(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local temp = cpuLoad(self, addr)
    local sub = self.REG_ACC - temp
    self.F_CARRY = (sub >= 0) and 1 or 0
    _setNZ(self, band(sub, 0xFF))
    return cycles
end

function CPU._handlers.cpx(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local temp = cpuLoad(self, addr)
    local sub = self.REG_X - temp
    self.F_CARRY = (sub >= 0) and 1 or 0
    _setNZ(self, band(sub, 0xFF))
    return cycles
end

function CPU._handlers.cpy(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local temp = cpuLoad(self, addr)
    local sub = self.REG_Y - temp
    self.F_CARRY = (sub >= 0) and 1 or 0
    _setNZ(self, band(sub, 0xFF))
    return cycles
end

function CPU._handlers.inc(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local val = band(cpuLoad(self, addr) + 1, 0xFF)
    cpuWrite(self, addr, val)
    _setNZ(self, val)
    return cycles
end

function CPU._handlers.dec(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local val = band(cpuLoad(self, addr) - 1, 0xFF)
    cpuWrite(self, addr, val)
    _setNZ(self, val)
    return cycles
end

function CPU._handlers.asl(self, opcode)
    if opcode == 0x0A then
        self.F_CARRY = band(rshift(self.REG_ACC, 7), 1)
        self.REG_ACC = band(lshift(self.REG_ACC, 1), 0xFF)
        _setNZ(self, self.REG_ACC)
        self.REG_PC = self.REG_PC + 1
        return 2
    else
        local addr, cycles = decodeOperand(self, opcode)
        local val = cpuLoad(self, addr)
        self.F_CARRY = band(rshift(val, 7), 1)
        val = band(lshift(val, 1), 0xFF)
        cpuWrite(self, addr, val)
        _setNZ(self, val)
        return cycles
    end
end

function CPU._handlers.lsr(self, opcode)
    if opcode == 0x4A then
        self.F_CARRY = band(self.REG_ACC, 1)
        self.REG_ACC = rshift(self.REG_ACC, 1)
        _setNZ(self, self.REG_ACC)
        self.REG_PC = self.REG_PC + 1
        return 2
    else
        local addr, cycles = decodeOperand(self, opcode)
        local val = cpuLoad(self, addr)
        self.F_CARRY = band(val, 1)
        val = rshift(val, 1)
        cpuWrite(self, addr, val)
        _setNZ(self, val)
        return cycles
    end
end

function CPU._handlers.rol(self, opcode)
    if opcode == 0x2A then
        local c = self.F_CARRY
        self.F_CARRY = band(rshift(self.REG_ACC, 7), 1)
        self.REG_ACC = band(lshift(self.REG_ACC, 1) + c, 0xFF)
        _setNZ(self, self.REG_ACC)
        self.REG_PC = self.REG_PC + 1
        return 2
    else
        local addr, cycles = decodeOperand(self, opcode)
        local val = cpuLoad(self, addr)
        local c = self.F_CARRY
        self.F_CARRY = band(rshift(val, 7), 1)
        val = band(lshift(val, 1) + c, 0xFF)
        cpuWrite(self, addr, val)
        _setNZ(self, val)
        return cycles
    end
end

function CPU._handlers.ror(self, opcode)
    if opcode == 0x6A then
        local c = self.F_CARRY
        self.F_CARRY = band(self.REG_ACC, 1)
        self.REG_ACC = rshift(self.REG_ACC, 1) + lshift(c, 7)
        _setNZ(self, self.REG_ACC)
        self.REG_PC = self.REG_PC + 1
        return 2
    else
        local addr, cycles = decodeOperand(self, opcode)
        local val = cpuLoad(self, addr)
        local c = self.F_CARRY
        self.F_CARRY = band(val, 1)
        val = rshift(val, 1) + lshift(c, 7)
        cpuWrite(self, addr, val)
        _setNZ(self, val)
        return cycles
    end
end

function CPU._handlers.bit_(self, opcode)
    local addr, cycles = decodeOperand(self, opcode)
    local val = cpuLoad(self, addr)
    self.F_OVERFLOW = band(rshift(val, 6), 1)
    self.F_SIGN = band(rshift(val, 7), 1)
    self.F_ZERO = band(self.REG_ACC, val) == 0 and 1 or 0
    return cycles
end

function CPU._handlers.tax(self, opcode)
    self.REG_X = self.REG_ACC
    _setNZ(self, self.REG_X)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.tay(self, opcode)
    self.REG_Y = self.REG_ACC
    _setNZ(self, self.REG_Y)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.tsx(self, opcode)
    self.REG_X = self.REG_SP
    _setNZ(self, self.REG_X)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.txa(self, opcode)
    self.REG_ACC = self.REG_X
    _setNZ(self, self.REG_ACC)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.txs(self, opcode)
    self.REG_SP = self.REG_X
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.tya(self, opcode)
    self.REG_ACC = self.REG_Y
    _setNZ(self, self.REG_ACC)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.inx(self, opcode)
    self.REG_X = band(self.REG_X + 1, 0xFF)
    _setNZ(self, self.REG_X)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.iny(self, opcode)
    self.REG_Y = band(self.REG_Y + 1, 0xFF)
    _setNZ(self, self.REG_Y)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.dex(self, opcode)
    self.REG_X = band(self.REG_X - 1, 0xFF)
    _setNZ(self, self.REG_X)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.dey(self, opcode)
    self.REG_Y = band(self.REG_Y - 1, 0xFF)
    _setNZ(self, self.REG_Y)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.clc(self, opcode)
    self.F_CARRY = 0
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.sec(self, opcode)
    self.F_CARRY = 1
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.cli(self, opcode)
    self.F_INTERRUPT = 0
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.sei(self, opcode)
    self.F_INTERRUPT = 1
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.clv(self, opcode)
    self.F_OVERFLOW = 0
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.cld(self, opcode)
    self.F_DECIMAL = 0
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.sed(self, opcode)
    self.F_DECIMAL = 1
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.nop(self, opcode)
    self.REG_PC = self.REG_PC + 1
    return 2
end

function CPU._handlers.brk(self, opcode)
    self.REG_PC = self.REG_PC + 2
    self:push(rshift(self.REG_PC, 8))
    self:push(band(self.REG_PC, 0xFF))
    self.F_BRK = 1
    self:push(self:getStatus())
    self.F_INTERRUPT = 1
    self.REG_PC = cpuLoad16(self, 0xFFFE)
    return 7
end

function CPU._handlers.jmp_abs(self, opcode)
    local oldPC = self.REG_PC
    local newPC = cpuLoad16(self, oldPC + 1)
    self.REG_PC = newPC

    -- 优化:检测 "JMP self"(SMB1 EndlessLoop 等待 NMI 的死循环)。
    -- JMP 自己 = 永远不会自然退出(只有 NMI 能打破)。
    -- newPC 等于 oldPC = 当前 jmp 指令地址 = 死循环。
    -- 直接消耗大量 cycle,让主循环 break 进入下一次 NMI,省掉无意义模拟。
    -- SMB1 标题画面 + EndlessLoop 占 CPU 总指令的 70% 以上,这一刀杠杆极大。
    if newPC == oldPC then
        -- 设置一个"快进"信号,主循环识别后直接结束本帧 CPU 模拟
        self._jmpSelfDetected = true
    end

    return 3
end

function CPU._handlers.jmp_ind(self, opcode)
    local addr = cpuLoad16(self, self.REG_PC + 1)
    if band(addr, 0xFF) == 0xFF then
        addr = bor(cpuLoad(self, addr), lshift(cpuLoad(self, band(addr, 0xFF00)), 8))
    else
        addr = cpuLoad16(self, addr)
    end
    self.REG_PC = addr
    return 5
end

function CPU._handlers.jsr(self, opcode)
    self.REG_PC = self.REG_PC + 2
    self:push(rshift(self.REG_PC, 8))
    self:push(band(self.REG_PC, 0xFF))
    self.REG_PC = cpuLoad16(self, self.REG_PC - 1)
    return 6
end

function CPU._handlers.rts(self, opcode)
    self.REG_PC = self:pull()
    self.REG_PC = bor(self.REG_PC, lshift(self:pull(), 8))
    self.REG_PC = self.REG_PC + 1
    return 6
end

function CPU._handlers.rti(self, opcode)
    self:setStatus(self:pull())
    self.REG_PC = self:pull()
    self.REG_PC = bor(self.REG_PC, lshift(self:pull(), 8))
    return 6
end

function CPU._handlers.pha(self, opcode)
    self:push(self.REG_ACC)
    self.REG_PC = self.REG_PC + 1
    return 3
end

function CPU._handlers.pla(self, opcode)
    self.REG_ACC = self:pull()
    _setNZ(self, self.REG_ACC)
    self.REG_PC = self.REG_PC + 1
    return 4
end

function CPU._handlers.php(self, opcode)
    self.F_BRK = 1
    self:push(self:getStatus())
    self.REG_PC = self.REG_PC + 1
    return 3
end

function CPU._handlers.plp(self, opcode)
    self:setStatus(self:pull())
    self.F_BRK = 0
    self.F_NOTUSED = 1
    self.REG_PC = self.REG_PC + 1
    return 4
end

function CPU._handlers.bcc(self, opcode)
    return _branch(self, 1 - self.F_CARRY, opcode)
end

function CPU._handlers.bcs(self, opcode)
    return _branch(self, self.F_CARRY, opcode)
end

function CPU._handlers.beq(self, opcode)
    return _branch(self, self.F_ZERO, opcode)
end

function CPU._handlers.bmi(self, opcode)
    return _branch(self, self.F_SIGN, opcode)
end

function CPU._handlers.bne(self, opcode)
    return _branch(self, 1 - self.F_ZERO, opcode)
end

function CPU._handlers.bpl(self, opcode)
    return _branch(self, 1 - self.F_SIGN, opcode)
end

function CPU._handlers.bvc(self, opcode)
    return _branch(self, 1 - self.F_OVERFLOW, opcode)
end

function CPU._handlers.bvs(self, opcode)
    return _branch(self, self.F_OVERFLOW, opcode)
end

CPU._opcodeTable = {}

local function _buildOpcodeTable()
    local t = CPU._opcodeTable
    local h = CPU._handlers

    local adcOps = {0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71}
    local sbcOps = {0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1}
    local andOps = {0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31}
    local oraOps = {0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11}
    local eorOps = {0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51}
    local ldaOps = {0xA9, 0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1}
    local ldxOps = {0xA2, 0xA6, 0xB6, 0xAE, 0xBE}
    local ldyOps = {0xA0, 0xA4, 0xB4, 0xAC, 0xBC}
    local staOps = {0x85, 0x95, 0x8D, 0x9D, 0x99, 0x81, 0x91}
    local stxOps = {0x86, 0x96, 0x8E}
    local styOps = {0x84, 0x94, 0x8C}
    local cmpOps = {0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1}
    local cpxOps = {0xE0, 0xE4, 0xEC}
    local cpyOps = {0xC0, 0xC4, 0xCC}
    local incOps = {0xE6, 0xF6, 0xEE, 0xFE}
    local decOps = {0xC6, 0xD6, 0xCE, 0xDE}
    local aslOps = {0x0A, 0x06, 0x16, 0x0E, 0x1E}
    local lsrOps = {0x4A, 0x46, 0x56, 0x4E, 0x5E}
    local rolOps = {0x2A, 0x26, 0x36, 0x2E, 0x3E}
    local rorOps = {0x6A, 0x66, 0x76, 0x6E, 0x7E}
    local bitOps = {0x24, 0x2C}

    for _, op in ipairs(adcOps) do t[op] = h.adc end
    for _, op in ipairs(sbcOps) do t[op] = h.sbc end
    for _, op in ipairs(andOps) do t[op] = h.and_ end
    for _, op in ipairs(oraOps) do t[op] = h.ora end
    for _, op in ipairs(eorOps) do t[op] = h.eor end
    for _, op in ipairs(ldaOps) do t[op] = h.lda end
    for _, op in ipairs(ldxOps) do t[op] = h.ldx end
    for _, op in ipairs(ldyOps) do t[op] = h.ldy end
    for _, op in ipairs(staOps) do t[op] = h.sta end
    for _, op in ipairs(stxOps) do t[op] = h.stx end
    for _, op in ipairs(styOps) do t[op] = h.sty end
    for _, op in ipairs(cmpOps) do t[op] = h.cmp end
    for _, op in ipairs(cpxOps) do t[op] = h.cpx end
    for _, op in ipairs(cpyOps) do t[op] = h.cpy end
    for _, op in ipairs(incOps) do t[op] = h.inc end
    for _, op in ipairs(decOps) do t[op] = h.dec end
    for _, op in ipairs(aslOps) do t[op] = h.asl end
    for _, op in ipairs(lsrOps) do t[op] = h.lsr end
    for _, op in ipairs(rolOps) do t[op] = h.rol end
    for _, op in ipairs(rorOps) do t[op] = h.ror end
    for _, op in ipairs(bitOps) do t[op] = h.bit_ end

    t[0xAA] = h.tax
    t[0xA8] = h.tay
    t[0xBA] = h.tsx
    t[0x8A] = h.txa
    t[0x9A] = h.txs
    t[0x98] = h.tya
    t[0xE8] = h.inx
    t[0xC8] = h.iny
    t[0xCA] = h.dex
    t[0x88] = h.dey
    t[0x18] = h.clc
    t[0x38] = h.sec
    t[0x58] = h.cli
    t[0x78] = h.sei
    t[0xB8] = h.clv
    t[0xD8] = h.cld
    t[0xF8] = h.sed
    t[0xEA] = h.nop
    t[0x00] = h.brk
    t[0x4C] = h.jmp_abs
    t[0x6C] = h.jmp_ind
    t[0x20] = h.jsr
    t[0x60] = h.rts
    t[0x40] = h.rti
    t[0x48] = h.pha
    t[0x68] = h.pla
    t[0x08] = h.php
    t[0x28] = h.plp
    t[0x90] = h.bcc
    t[0xB0] = h.bcs
    t[0xF0] = h.beq
    t[0x30] = h.bmi
    t[0xD0] = h.bne
    t[0x10] = h.bpl
    t[0x50] = h.bvc
    t[0x70] = h.bvs
end

_buildOpcodeTable()

-- 把 opcode 分发表绑定到 emulate() 顶部声明的 upvalue,
-- 避免每次调用都查 self._opcodeTable
_opcodeTableLocal = CPU._opcodeTable