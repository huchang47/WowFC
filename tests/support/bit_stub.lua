-- bit_stub.lua
-- bit 库桩：让解析层可在标准 Lua / LuaJIT 下独立运行测试。
--
-- 选择策略（按优先级）：
--   1. 复用环境已提供的全局 bit（WoW 沙盒里 bit 本就是全局）；
--   2. 复用可 require 的 bit 库（LuaJIT 内置 / LuaBitOp）；
--   3. 都没有时，用纯 Lua 实现补齐 band/bor/bxor/bnot/lshift/rshift。
--
-- 选定实现会被安装为全局 _G.bit，与项目代码保持一致
-- （例如 Core/Controller.lua 顶部的 `local band = bit.band`）。
--
-- 模块额外始终导出纯 Lua 实现 `pure`，供脚手架自检对照
-- （确保在没有原生 bit 的标准 Lua 下，补齐实现也正确）。

local TWO32 = 4294967296  -- 2^32

-- 规范化为 [0, 2^32) 的无符号整数
local function normalize(x)
    return math.floor(x or 0) % TWO32
end

-- 逐位生成器：按给定的单 bit 运算 opfn 组合两个数
local function make_bitwise(opfn)
    return function(a, b)
        a = normalize(a)
        b = normalize(b)
        local result, bitval = 0, 1
        for _ = 1, 32 do
            local abit = a % 2
            local bbit = b % 2
            if opfn(abit, bbit) == 1 then
                result = result + bitval
            end
            a = (a - abit) / 2
            b = (b - bbit) / 2
            bitval = bitval * 2
        end
        return result
    end
end

-- 纯 Lua 32 位位运算实现
local pure = {}

pure.band = make_bitwise(function(x, y) return (x == 1 and y == 1) and 1 or 0 end)
pure.bor  = make_bitwise(function(x, y) return (x == 1 or y == 1) and 1 or 0 end)
pure.bxor = make_bitwise(function(x, y) return (x ~= y) and 1 or 0 end)

function pure.bnot(a)
    return (TWO32 - 1) - normalize(a)
end

-- 逻辑左移（高位移出后丢弃，结果裁剪到 32 位）
function pure.lshift(a, n)
    n = math.floor(n or 0)
    if n < 0 then return pure.rshift(a, -n) end
    if n >= 32 then return 0 end
    -- 先丢弃会被移出 32 位的高位，避免乘积超出浮点精确范围（2^53）
    a = normalize(a) % (2 ^ (32 - n))
    return a * (2 ^ n)
end

-- 逻辑右移
function pure.rshift(a, n)
    n = math.floor(n or 0)
    if n < 0 then return pure.lshift(a, -n) end
    if n >= 32 then return 0 end
    return math.floor(normalize(a) / (2 ^ n))
end

-- 判断一个 bit 表是否“可用”（具备项目所需的核心函数）
local function looks_usable(b)
    return type(b) == "table"
        and type(b.band) == "function"
        and type(b.bor) == "function"
        and type(b.lshift) == "function"
        and type(b.rshift) == "function"
end

-- 选择并安装全局 bit
local function install()
    local existing = rawget(_G, "bit")
    if looks_usable(existing) then
        return existing, "native"
    end

    local ok, mod = pcall(require, "bit")
    if ok and looks_usable(mod) then
        _G.bit = mod
        return mod, "require"
    end

    -- 标准 Lua 无 bit 库：用纯 Lua 实现补齐
    local stub = {
        band = pure.band,
        bor = pure.bor,
        bxor = pure.bxor,
        bnot = pure.bnot,
        lshift = pure.lshift,
        rshift = pure.rshift,
    }
    _G.bit = stub
    return stub, "pure"
end

local chosen, source = install()

return {
    bit = chosen,      -- 已安装为全局的 bit 实现
    pure = pure,       -- 纯 Lua 实现（始终可用，供对照测试）
    source = source,   -- "native" | "require" | "pure"
}
