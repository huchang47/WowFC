-- Buffer.lua
-- 字节缓冲区类，模拟 JavaScript 的 Uint8Array 和 Uint32Array

-- 创建全局 Buffer 表
_G.Buffer = {}
Buffer.__index = Buffer

-- 创建 Uint8Array 风格的缓冲区
function Buffer.newU8(size, defaultValue)
    defaultValue = defaultValue or 0
    local buf = {}
    for i = 0, size - 1 do
        buf[i] = defaultValue
    end
    return buf
end

-- 创建 Uint16Array 风格的缓冲区
function Buffer.newU16(size, defaultValue)
    defaultValue = defaultValue or 0
    local buf = {}
    for i = 0, size - 1 do
        buf[i] = defaultValue
    end
    return buf
end

-- 创建 Uint32Array 风格的缓冲区
function Buffer.newU32(size, defaultValue)
    defaultValue = defaultValue or 0
    local buf = {}
    for i = 0, size - 1 do
        buf[i] = defaultValue
    end
    return buf
end

-- 从字符串创建缓冲区（用于加载 ROM）
function Buffer.fromString(str)
    local buf = {}
    for i = 1, #str do
        buf[i - 1] = string.byte(str, i)
    end
    return buf
end

-- 从 table 创建缓冲区（复制）
function Buffer.fromTable(tbl)
    local buf = {}
    for k, v in pairs(tbl) do
        buf[k] = v
    end
    return buf
end

-- 复制数组元素（从 JSNES 的 utils.js 移植）
function Buffer.copyArrayElements(src, srcPos, dest, destPos, length)
    for i = 0, length - 1 do
        dest[destPos + i] = src[srcPos + i] or 0
    end
end

-- 填充缓冲区
function Buffer.fill(buf, value, startPos, endPos)
    startPos = startPos or 0
    endPos = endPos or #buf
    for i = startPos, endPos do
        buf[i] = value
    end
end

-- 设置缓冲区（从另一个缓冲区复制）
function Buffer.set(dest, src, offset)
    offset = offset or 0
    for k, v in pairs(src) do
        dest[offset + k] = v
    end
end

-- 子数组（返回视图，不复制）
function Buffer.subarray(buf, startPos, endPos)
    local result = {}
    for i = startPos, endPos - 1 do
        result[i - startPos] = buf[i]
    end
    return result
end

-- 安全读取（越界返回默认值）
function Buffer.safeRead(buf, index, defaultValue)
    defaultValue = defaultValue or 0
    local value = buf[index]
    if value == nil then
        return defaultValue
    end
    return value
end

-- 安全写入（确保值在 0-255 范围内）
function Buffer.safeWriteU8(buf, index, value)
    buf[index] = BitOps.toU8(value)
end

-- 安全写入（确保值在 32 位无符号范围内）
function Buffer.safeWriteU32(buf, index, value)
    buf[index] = BitOps.toU32(value)
end

-- 序列化为字符串（用于保存状态）
function Buffer.toString(buf, startPos, endPos)
    startPos = startPos or 0
    endPos = endPos or #buf
    local chars = {}
    for i = startPos, endPos do
        table.insert(chars, string.char(BitOps.toU8(buf[i] or 0)))
    end
    return table.concat(chars)
end

-- 调试：打印缓冲区内容
function Buffer.dump(buf, startPos, length, label)
    startPos = startPos or 0
    length = length or 16
    label = label or "Buffer"
    
    local hex = {}
    for i = startPos, startPos + length - 1 do
        table.insert(hex, string.format("%02X", buf[i] or 0))
    end
    print(string.format("%s [%04X]: %s", label, startPos, table.concat(hex, " ")))
end

return Buffer
