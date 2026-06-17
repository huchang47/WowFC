-- unit.lua
-- 极简单元测试辅助：提供 describe / it / 断言，并统计通过与失败。
--
-- 与属性测试互补（对应 design.md：单元测试覆盖具体场景与回归，
-- 属性测试覆盖通用属性）。保持最小，不引入额外依赖。
--
-- 用法：
--   local unit = require("tests.support.unit")
--   local t = unit.new("APU 寄存器")
--   t:it("写入低 8 位更新 timer", function(a)
--       a.equal(actual, expected)
--   end)
--   local ok = t:finish()   -- 打印小结并返回是否全部通过

local Unit = {}
Unit.__index = Unit

-- 断言集合（传入每个 it 回调）
local function make_asserts(state)
    local a = {}

    local function fail(msg)
        state.failed = state.failed + 1
        error(msg, 2)
    end

    function a.ok(value, msg)
        if not value then
            fail(msg or "断言失败：期望为真值，实际为 " .. tostring(value))
        end
    end

    function a.equal(actual, expected, msg)
        if actual ~= expected then
            fail((msg or "断言失败") ..
                "：期望 " .. tostring(expected) .. "，实际 " .. tostring(actual))
        end
    end

    function a.is_nil(value, msg)
        if value ~= nil then
            fail((msg or "断言失败") .. "：期望 nil，实际 " .. tostring(value))
        end
    end

    -- 期望回调抛错（用于错误处理/降级场景）
    function a.errors(fn, msg)
        local ok = pcall(fn)
        if ok then
            fail(msg or "断言失败：期望抛错，但正常返回")
        end
    end

    -- 期望回调不抛错
    function a.no_error(fn, msg)
        local ok, err = pcall(fn)
        if not ok then
            fail((msg or "断言失败：期望不抛错") .. "，实际抛错：" .. tostring(err))
        end
    end

    return a
end

-- 创建一个测试分组
function Unit.new(name)
    return setmetatable({
        name = name or "(未命名)",
        passed = 0,
        failed = 0,
    }, Unit)
end

-- 注册并立即执行一个用例
function Unit:it(description, fn)
    local asserts = make_asserts(self)
    local ok, err = pcall(fn, asserts)
    if ok then
        self.passed = self.passed + 1
        io.write("  [PASS] " .. description .. "\n")
    else
        -- failed 计数已在断言里自增；若是非断言异常也记一次
        io.write("  [FAIL] " .. description .. " -> " .. tostring(err) .. "\n")
    end
    return self
end

-- 打印分组小结，返回是否全部通过
function Unit:finish()
    io.write(string.format("单元分组 [%s]：%d 通过，%d 失败\n",
        self.name, self.passed, self.failed))
    return self.failed == 0
end

return Unit
