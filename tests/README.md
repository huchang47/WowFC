# WowFC 测试

本目录是 APU 发声功能（spec：`apu-sound`）的 Lua 测试脚手架，用于在**标准 Lua / LuaJIT**（脱离 WoW 客户端）下独立运行解析层的单元测试与属性测试。

## 运行

在工作区根目录执行：

```bash
# 运行全部已登记测试（汇总退出码：0 = 全通过）
lua tests/run.lua

# 只运行名称匹配的测试
lua tests/run.lua smoke

# 也可单独运行某个测试脚本（每个脚本都是独立入口）
lua tests/smoke_test.lua
```

依赖：

- Lua 5.1 / LuaJIT（已在 Lua 5.1.5 验证）。
- [lua-quickcheck](https://github.com/luc-tielen/lua-quickcheck)：属性测试库，经
  `luarocks install lua-quickcheck` 安装；不自行实现框架。

## 脚手架组成（`tests/support/`）

| 文件 | 作用 |
|------|------|
| `bit_stub.lua` | `bit` 库桩。优先复用原生 `bit`（WoW / LuaJIT / LuaBitOp），标准 Lua 下用纯 Lua 补齐 `band/bor/bxor/bnot/lshift/rshift`，并安装为全局 `bit`，与项目代码一致。 |
| `sound_mock.lua` | 可注入的 `PlaySoundFile` / `StopSound` mock，记录调用与参数；支持模拟「返回 nil / 抛错 / 不可用」等降级场景。 |
| `lqc_harness.lua` | lua-quickcheck 接入层：注入全局 `property` 与生成器（`int`/`byte`/`choose`…），并提供 `setup/reset/run`，每条属性默认且强制 **≥100 次迭代**。 |
| `unit.lua` | 极简单元测试辅助：`describe/it` 风格与断言，与属性测试互补。 |

## 编写属性测试（P1–P9）

后续每条正确性属性写成一个测试文件，并在 `tests/run.lua` 的 `TEST_FILES` 中登记。
属性测试标签格式（见 design.md / tasks.md）：

```lua
-- Feature: apu-sound, Property {number}: {property_text}
property "..." {
    generators = { int(0, 2047) },
    numtests = 100,            -- ≥ 100 次迭代
    check = function(timer) ... end,
}
```

范例见 `smoke_test.lua` 中的脚手架自检属性。
