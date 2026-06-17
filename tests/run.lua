-- run.lua
-- 测试总入口：运行 tests/ 下的测试脚本，汇总通过/失败并返回退出码。
--
-- 用法（在工作区根目录）：
--   lua tests/run.lua              -- 运行全部已登记测试
--   lua tests/run.lua smoke        -- 只运行名称含 "smoke" 的测试
--
-- 设计：各测试脚本本身是“独立可运行入口”（自己 os.exit）。为在一个进程里
-- 汇总多个脚本，这里以子进程方式逐个运行并收集退出码，互不污染全局环境。
-- 这样既保留“单文件可独立运行”，又提供“一键全部运行”。

package.path = package.path .. ";./?.lua"

-- 已登记的测试脚本（后续新增属性/单元测试在此追加即可）。
local TEST_FILES = {
    "tests/smoke_test.lua",
    "tests/apu_timer_freq_test.lua",
    "tests/apu_tone_map_test.lua",
    "tests/apu_property_p1_test.lua",
    "tests/apu_property_p2_test.lua",
    "tests/apu_property_p3_test.lua",
    "tests/apu_property_p4_test.lua",
    "tests/apu_write_register_test.lua",
    "tests/apu_read_status_test.lua",
    "tests/apu_sound_backend_test.lua",
    "tests/apu_tick_test.lua",
    "tests/apu_property_p5_test.lua",
    "tests/apu_property_p6_test.lua",
    "tests/apu_property_p7_test.lua",
    "tests/apu_enabled_test.lua",
    "tests/apu_property_p8_test.lua",
    "tests/apu_property_p9_test.lua",
    "tests/fc_apu_integration_test.lua",
    "tests/sound_toggle_persist_test.lua",
    "tests/apu_leak_preservation_test.lua",
    "tests/apu_leak_unit_test.lua",
    "tests/apu_leak_smoke_test.lua",
    "tests/apu_same_tone_retrigger_test.lua",
    "tests/palette_renderer_test.lua",
    "tests/cpu_golden_test.lua",
    -- 后续：tests/apu_property_test.lua, tests/apu_unit_test.lua ...
}

-- 选择 Lua 解释器：优先用启动本进程的同一个解释器。
local function lua_bin()
    local exe = arg and arg[-1]
    if exe and exe ~= "" then
        return exe
    end
    return "lua"
end

-- 名称过滤（可选的第一个命令行参数）
local filter = arg and arg[1]

local bin = lua_bin()
local total, failed = 0, 0

for _, file in ipairs(TEST_FILES) do
    if not filter or file:find(filter, 1, true) then
        total = total + 1
        io.write("\n########## 运行 " .. file .. " ##########\n")
        -- 用引号包裹路径，兼容含空格的工作区路径。
        local cmd = string.format('"%s" "%s"', bin, file)
        -- Windows cmd.exe 怪癖：命令以引号开头时会剥掉首尾引号，导致路径错乱。
        -- 解法是整条命令外层再包一层引号（cmd 剥掉外层后，内层引号保留）。
        if package.config:sub(1, 1) == "\\" then
            cmd = '"' .. cmd .. '"'
        end
        local ok, kind, code = os.execute(cmd)
        -- Lua 5.1: os.execute 返回退出码数字；5.2+: 返回 ok, kind, code。
        local success
        if type(ok) == "number" then
            success = (ok == 0)
        else
            success = ok == true and (code == nil or code == 0)
        end
        if not success then
            failed = failed + 1
            io.write("!!! " .. file .. " 失败\n")
        end
    end
end

io.write(string.format("\n======== 测试汇总：%d 个脚本，%d 失败 ========\n",
    total, failed))
os.exit(failed == 0 and 0 or 1)
