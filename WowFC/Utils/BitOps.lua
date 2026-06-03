-- BitOps.lua
-- 位运算工具类，封装 Lua 5.1 的位运算操作
-- 提供与 JavaScript 类似的位运算接口

-- 创建全局 BitOps 表
_G.BitOps = {}

-- 确保 bit 库可用 (WoW 使用内置 bit 库)
local bit = bit

-- 基础位运算
function BitOps.band(a, b)
    return bit.band(a or 0, b or 0)
end

function BitOps.bor(a, b)
    return bit.bor(a or 0, b or 0)
end

function BitOps.bxor(a, b)
    return bit.bxor(a or 0, b or 0)
end

function BitOps.bnot(a)
    return bit.bnot(a or 0)
end

function BitOps.lshift(a, n)
    return bit.lshift(a or 0, n or 0)
end

function BitOps.rshift(a, n)
    return bit.rshift(a or 0, n or 0)
end

-- 无符号右移 (JavaScript 的 >>> 操作符)
-- Lua 的右移是有符号的，需要特殊处理
function BitOps.urshift(a, n)
    a = a or 0
    n = n or 0
    -- 先转换为无符号 32 位数，再右移
    a = bit.band(a, 0xFFFFFFFF)
    return bit.rshift(a, n)
end

-- 限制为 8 位无符号整数 (0-255)
function BitOps.toU8(value)
    return bit.band(value or 0, 0xFF)
end

-- 限制为 16 位无符号整数 (0-65535)
function BitOps.toU16(value)
    return bit.band(value or 0, 0xFFFF)
end

-- 限制为 32 位无符号整数
function BitOps.toU32(value)
    return bit.band(value or 0, 0xFFFFFFFF)
end

-- 有符号 8 位转换 (-128 到 127)
function BitOps.toS8(value)
    value = bit.band(value or 0, 0xFF)
    if value >= 128 then
        return value - 256
    end
    return value
end

-- 有符号 16 位转换 (-32768 到 32767)
function BitOps.toS16(value)
    value = bit.band(value or 0, 0xFFFF)
    if value >= 32768 then
        return value - 65536
    end
    return value
end

-- 读取 16 位值（小端序）
function BitOps.read16(mem, addr)
    addr = addr or 0
    local low = mem[addr] or 0
    local high = mem[addr + 1] or 0
    return bit.bor(low, bit.lshift(high, 8))
end

-- 写入 16 位值（小端序）
function BitOps.write16(mem, addr, value)
    addr = addr or 0
    value = value or 0
    mem[addr] = bit.band(value, 0xFF)
    mem[addr + 1] = bit.band(bit.rshift(value, 8), 0xFF)
end

-- 测试特定位是否设置
function BitOps.isBitSet(value, bitPosition)
    return bit.band(value or 0, bit.lshift(1, bitPosition)) ~= 0
end

-- 设置特定位
function BitOps.setBit(value, bitPosition, set)
    local mask = bit.lshift(1, bitPosition)
    if set then
        return bit.bor(value or 0, mask)
    else
        return bit.band(value or 0, bit.bnot(mask))
    end
end

-- 页面交叉检测（用于 6502 寻址）
function BitOps.pageCrossed(addr1, addr2)
    return bit.band(addr1, 0xFF00) ~= bit.band(addr2, 0xFF00)
end

return BitOps
