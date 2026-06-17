-- palette_renderer_test.lua
-- 验证 PaletteRenderer 与 UltraRenderer "视觉等价":在相同 buffer + 帧模式下,
-- 两者更新的像素集合(last_colors)逐像素一致、changed 计数一致。这保证用
-- SetTexCoord 替换 SetColorTexture 不会改变画面,A/B 性能对比才有意义。
-- 另外验证 PaletteRenderer 把颜色映射到了正确的调色板纹理坐标。
--
-- 独立可运行:lua tests/palette_renderer_test.lua(在 addon 根目录)

package.path = package.path .. ";./?.lua"

local bit_stub = require("tests.support.bit_stub")
_G.bit = bit_stub.bit  -- UltraRenderer 的 colorCache 依赖全局 bit

local wow = require("tests.support.wow_mock")
local Unit = require("tests.support.unit")

local uninstall = wow.install()

-- 按 TOC 顺序加载:数据源 → 两个渲染器工厂
dofile("Utils/PaletteData_Generated.lua")
dofile("UltraRenderer.lua")
dofile("PaletteRenderer.lua")

local PD = _G.WOWFC_PALETTE_DATA
local SPAN = PD.colorSpan
local TEXW = PD.texWidth
local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 240
local PIXELS = SCREEN_WIDTH * SCREEN_HEIGHT

local ultraFactory = _G.WOWFC_UltraRenderer
local paletteFactory = _G.WOWFC_PaletteRenderer

local function newBuffer(fill)
    local b = {}
    for i = 0, PIXELS - 1 do b[i] = fill or 0 end
    return b
end

-- 比较两个渲染器的 last_colors 是否逐像素一致
local function lastColorsEqual(a, b)
    for i = 0, PIXELS - 1 do
        if a.last_colors[i] ~= b.last_colors[i] then
            return false, i
        end
    end
    return true
end

local allOk = true

do
    local t = Unit.new("PaletteRenderer 加载与映射")

    t:it("数据源与两个工厂均已加载", function(a)
        a.ok(PD ~= nil, "WOWFC_PALETTE_DATA 应存在")
        a.ok(ultraFactory ~= nil, "UltraRenderer 工厂应存在")
        a.ok(paletteFactory ~= nil, "PaletteRenderer 工厂应存在")
    end)

    t:it("唯一色映射到正确的调色板纹理坐标", function(a)
        local r = paletteFactory:Create(wow.newFrame(), { scale = 1 })
        -- 选调色板中唯一(非重复)的颜色及其已知 index
        local cases = {
            { color = 0x757575, idx = 0 },
            { color = 0xBCBCBC, idx = 16 },
            { color = 0xFFFFFF, idx = 32 },  -- 32 与 48 同为白,首个 index=32
        }
        for ci, c in ipairs(cases) do
            local buf = newBuffer(0)
            buf[ci - 1] = c.color           -- 写到像素 (ci-1)
            r:Render(buf, { _frameMode = "full" })
            local tex = r.pixels[ci - 1]
            local expectLeft = (c.idx * SPAN + 1) / TEXW
            a.equal(tex._texcoord[1], expectLeft,
                "颜色 " .. string.format("0x%06X", c.color) .. " 的 texcoord.left 应对应 index " .. c.idx)
        end
    end)

    allOk = t:finish() and allOk
end

do
    local t = Unit.new("与 UltraRenderer 视觉等价")

    t:it("full 模式:更新像素集合与 changed 一致", function(a)
        local u = ultraFactory:Create(wow.newFrame(), { scale = 1 })
        local p = paletteFactory:Create(wow.newFrame(), { scale = 1 })

        -- 造一帧:渐变 + 几块纯色,颜色取自调色板
        local pal = PD.palette
        local buf = newBuffer(0)
        for i = 0, PIXELS - 1 do
            buf[i] = pal[i % 64]
        end
        local ppu = { _frameMode = "full" }
        local _, uChanged = u:Render(buf, ppu)
        local _, pChanged = p:Render(buf, ppu)

        a.equal(pChanged, uChanged, "首帧 changed 应一致")
        local eq, badIdx = lastColorsEqual(u, p)
        a.ok(eq, "last_colors 应逐像素一致(首个不一致下标=" .. tostring(badIdx) .. ")")
    end)

    t:it("partial 模式:仅按 undo/new 列表更新且一致", function(a)
        local u = ultraFactory:Create(wow.newFrame(), { scale = 1 })
        local p = paletteFactory:Create(wow.newFrame(), { scale = 1 })

        local pal = PD.palette
        -- 先用 full 铺一帧底
        local base = newBuffer(pal[13])  -- 全黑底(index 13 = 0x000000)
        u:Render(base, { _frameMode = "full" })
        p:Render(base, { _frameMode = "full" })

        -- 下一帧:改动少量像素,用 partial 列表描述
        local buf = newBuffer(pal[13])
        local newList, newN = {}, 0
        for i = 100, 100 + 2000 do
            buf[i] = pal[(i % 30) + 16]   -- 取一段非黑色
            newN = newN + 1
            newList[newN] = i
        end
        local ppu = {
            _frameMode = "partial",
            _frameUndoList = {}, _frameUndoN = 0,
            _frameNewList = newList, _frameNewN = newN,
        }
        local _, uChanged = u:Render(buf, ppu)
        local _, pChanged = p:Render(buf, ppu)

        a.equal(pChanged, uChanged, "partial changed 应一致")
        a.ok(uChanged > 0, "应有像素被更新")
        local eq, badIdx = lastColorsEqual(u, p)
        a.ok(eq, "partial 后 last_colors 应一致(首个不一致下标=" .. tostring(badIdx) .. ")")
    end)

    t:it("skip 模式:不更新任何像素,changed=0", function(a)
        local p = paletteFactory:Create(wow.newFrame(), { scale = 1 })
        local buf = newBuffer(PD.palette[16])
        local _, changed = p:Render(buf, { _frameMode = "skip" })
        a.equal(changed, 0, "skip 应返回 0 changed")
    end)

    allOk = t:finish() and allOk
end

uninstall()

io.write("\n==== PaletteRenderer 测试" .. (allOk and "全部通过 ✅" or "存在失败 ❌") .. " ====\n")
os.exit(allOk and 0 or 1)
