-- lqc_harness.lua
-- lua-quickcheck（lqc）接入层：把属性测试库挂到独立测试入口里。
--
-- 为什么需要它（对应 design.md 测试策略）：
--   lqc 自带的 `lqc` 命令行 runner 会在执行脚本前，往全局环境注入
--   property / int / byte / choose 等函数。而本项目用“外部 runner”方式
--   （在自己的入口脚本里 require + 调用 lqc.check），因此需要手动复刻
--   这套全局注入，并提供统一的初始化与“运行 + 判定通过/失败”封装。
--
-- 不自行实现属性测试框架：随机生成、收缩、断言全部交给 lua-quickcheck。
--
-- 用法：
--   local lqc = require("tests.support.lqc_harness")
--   lqc.setup()                       -- 注入全局 property / 生成器
--   property "..." { generators = {...}, check = function(...) ... end }
--   local ok = lqc.run({ iterations = 100 })   -- 运行并返回是否全部通过

local quickcheck = require("lqc.quickcheck")
local property = require("lqc.property")
local random = require("lqc.random")
local report = require("lqc.report")

local int = require("lqc.generators.int")
local byte = require("lqc.generators.byte")
local bool = require("lqc.generators.bool")
local float = require("lqc.generators.float")
local str = require("lqc.generators.string")
local lqc_gen = require("lqc.lqc_gen")

-- 每条属性的默认迭代次数（满足“≥100 次迭代”的要求）。
local DEFAULT_ITERATIONS = 100

local M = {
    DEFAULT_ITERATIONS = DEFAULT_ITERATIONS,
    -- 直接暴露生成器，方便测试文件按需引用（也会在 setup 时注入全局）。
    int = int,
    byte = byte,
    bool = bool,
    float = float,
    str = str,
    choose = lqc_gen.choose,
    frequency = lqc_gen.frequency,
    elements = lqc_gen.elements,
    oneof = lqc_gen.oneof,
    property = property,
}

-- 把 lqc 的 DSL（property）与常用生成器注入全局命名空间，
-- 与 lqc 命令行 runner 的行为保持一致，便于测试文件直接书写：
--   property "..." { generators = { int(0, 2047) }, check = ... }
function M.setup()
    _G.property = property
    _G.int = int
    _G.byte = byte
    _G.bool = bool
    _G.float = float
    _G.str = str
    _G.choose = lqc_gen.choose
    _G.frequency = lqc_gen.frequency
    _G.elements = lqc_gen.elements
    _G.oneof = lqc_gen.oneof
    return M
end

-- 清空已注册的属性（多次运行 / 分组运行时调用，避免重复累计）。
function M.reset()
    quickcheck.properties = {}
    quickcheck.failed = false
    return M
end

-- 运行所有已注册属性并打印结果。
-- opts:
--   iterations : 每条属性的迭代次数（默认 100；强制不小于 100）
--   shrinks    : 失败时的最大收缩次数（默认与 iterations 相同）
--   seed       : 随机种子（默认当前时间戳；固定可复现）
-- 返回：allPassed(boolean)
function M.run(opts)
    opts = opts or {}
    local iterations = opts.iterations or DEFAULT_ITERATIONS
    if iterations < DEFAULT_ITERATIONS then
        -- 守护：属性测试每条至少 100 次迭代。
        iterations = DEFAULT_ITERATIONS
    end
    local shrinks = opts.shrinks or iterations

    random.seed(opts.seed)
    quickcheck.init(iterations, shrinks)
    quickcheck.check()

    report.report_errors()
    report.report_summary()

    return not quickcheck.failed
end

return M
