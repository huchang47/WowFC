-- PaletteRenderer.lua
-- 调色板纹理版 256x240 NES 帧渲染器,作为 UltraRenderer 的 A/B 备选实现。
--
-- 与 UltraRenderer 的唯一区别在"改一个像素颜色"的方式:
--   UltraRenderer: tex:SetColorTexture(r, g, b)        -- 设纯色(顶点色 + 纯色着色)
--   PaletteRenderer: tex:SetTexCoord(u0, u1, v0, v1)   -- 共享调色板纹理,只改 UV
--
-- 借鉴 tna0y/wow-doom-within(src/frame.lua):所有像素 texture 指向同一张调色板图,
-- 重新着色等于平移纹理坐标,作者实测比换 texture/纯色更省。NES 颜色空间封闭(固定
-- 64 色),天然适合这种方案。是否真比 SetColorTexture 快,由 Bench.lua / "/fc bench"
-- 在真机上实测决定。
--
-- 其余设计(分行抗 widget 上限、FrameBuffer/Flatten 离屏合成、last_color 脏检查、
-- skip/partial/full 三模式)与 UltraRenderer 完全一致,以保证两者"更新的像素集合"
-- 逐帧相同 —— 即视觉等价,A/B 对比才公平。
--
-- 数据源:Utils/PaletteData_Generated.lua(_G.WowFC_PALETTE_DATA),由
-- Tools/gen_palette_tga.py 生成,颜色与 Core/PPU.lua 同源。
--
-- 对外接口与 UltraRenderer 完全兼容(Create/Render/GetModeName/SetMode/
-- Show/Hide/SetPoint, 字段 currentFps / frame)。

local PaletteRenderer = {}
_G.WowFC_PaletteRenderer = PaletteRenderer

local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 240

-- 从生成数据构建 RGB->index 反查表与每个 index 的纹理坐标。
-- 仅依赖 _G.WowFC_PALETTE_DATA,在模块加载期一次性完成。
local PaletteData = _G.WowFC_PALETTE_DATA

-- rgbToIndex[color24] = 调色板下标(0..63)。重复色保留首个出现的下标;
-- 查不到的颜色(理论上不会出现,PPU 输出必在 64 色内)退化为 0,避免崩溃。
local rgbToIndex
-- texCoords[index] = { left, right, top, bottom },预算好避免每像素再算。
local texCoords

local function buildLookup()
    if not PaletteData or not PaletteData.palette then return false end

    local pal = PaletteData.palette
    local width = PaletteData.texWidth or 256
    local span = PaletteData.colorSpan or 4

    rgbToIndex = setmetatable({}, { __index = function() return 0 end })
    texCoords = {}

    for idx = 0, 63 do
        local color = pal[idx]
        if color then
            -- 仅记录首个出现的颜色,后续重复色塌缩到它(视觉一致)
            if rawget(rgbToIndex, color) == nil then
                rgbToIndex[color] = idx
            end
            -- u 取色块内 [+1px, +(span-1)px] 区间,两端各留 1px 防双线性插值跨色
            local left  = (idx * span + 1) / width
            local right = (idx * span + (span - 1)) / width
            texCoords[idx] = { left, right, 0.25, 0.75 }
        end
    end
    return true
end

local lookupReady = buildLookup()

function PaletteRenderer:Create(parent, options)
    if not lookupReady then
        print("|cffff0000WowFC|r: PaletteRenderer 缺少调色板数据(PaletteData_Generated.lua 未加载),请先运行 Tools/gen_palette_tga.py 并在 TOC 中声明。")
        return nil
    end

    options = options or {}
    local scale = options.scale or 2
    local screenW = SCREEN_WIDTH * scale
    local screenH = SCREEN_HEIGHT * scale
    local texPath = PaletteData.texPath

    local renderer = {
        scale = scale,
        targetFps = options.targetFps or 60,

        frameCount = 0,
        currentFps = 0,
        lastFpsUpdate = 0,

        last_colors = {},
    }

    -- 主 screen frame:开 flatten + framebuffer(与 UltraRenderer 一致)
    renderer.frame = CreateFrame("Frame", nil, parent)
    renderer.frame:SetSize(screenW, screenH)
    renderer.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    if renderer.frame.SetFlattensRenderLayers then
        renderer.frame:SetFlattensRenderLayers(true)
    end
    if renderer.frame.SetIsFrameBuffer then
        renderer.frame:SetIsFrameBuffer(true)
    end
    renderer.frame:Show()

    local pixelW = screenW / SCREEN_WIDTH
    local pixelH = screenH / SCREEN_HEIGHT

    renderer.rows = {}
    renderer.pixels = {}

    -- 首帧用的默认纹理坐标(index 0)
    local tc0 = texCoords[0]

    for y = 0, SCREEN_HEIGHT - 1 do
        local row = CreateFrame("Frame", nil, renderer.frame)
        row:SetSize(screenW, pixelH)
        row:SetPoint("TOPLEFT", renderer.frame, "TOPLEFT", 0, -y * pixelH)
        if row.SetFlattensRenderLayers then
            row:SetFlattensRenderLayers(true)
        end
        if row.SetIsFrameBuffer then
            row:SetIsFrameBuffer(true)
        end
        renderer.rows[y] = row

        local rowBase = y * SCREEN_WIDTH
        for x = 0, SCREEN_WIDTH - 1 do
            local tex = row:CreateTexture(nil, "ARTWORK")
            tex:SetSize(pixelW, pixelH)
            tex:SetPoint("TOPLEFT", row, "TOPLEFT", x * pixelW, 0)
            -- 关键:所有像素共享同一张调色板纹理,运行期只改 SetTexCoord
            tex:SetTexture(texPath)
            tex:SetTexCoord(tc0[1], tc0[2], tc0[3], tc0[4])
            renderer.pixels[rowBase + x] = tex
            renderer.last_colors[rowBase + x] = -1  -- 强制首帧全量重绘
        end
    end

    --------------------------------------------------------------------
    -- Render:与 UltraRenderer 同构(skip/partial/full),改色用 SetTexCoord。
    -- @param buffer table  长度 256*240,buffer[i] = 24-bit RGB int
    -- @param ppu    携带 _frameMode / undo / new 列表,可为 nil(退化为 full)
    --------------------------------------------------------------------
    function renderer:Render(buffer, ppu)
        if not buffer then return 0 end

        local startTime = debugprofilestop and debugprofilestop() or 0
        local pixels = self.pixels
        local last = self.last_colors
        local r2i = rgbToIndex
        local tcs = texCoords
        local changed = 0

        local mode = ppu and ppu._frameMode or "full"

        if mode == "skip" then
            self.frameCount = self.frameCount + 1
            local now = GetTime and GetTime() or 0
            if now - self.lastFpsUpdate >= 1.0 then
                self.currentFps = self.frameCount
                self.frameCount = 0
                self.lastFpsUpdate = now
            end
            return 0, 0
        end

        if mode == "partial" then
            local undoList = ppu._frameUndoList
            local undoN    = ppu._frameUndoN or 0
            for k = 1, undoN do
                local i = undoList[k]
                local color = buffer[i] or 0
                if last[i] ~= color then
                    local tc = tcs[r2i[color]]
                    pixels[i]:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
                    last[i] = color
                    changed = changed + 1
                end
            end

            local newList = ppu._frameNewList
            local newN    = ppu._frameNewN or 0
            for k = 1, newN do
                local i = newList[k]
                local color = buffer[i] or 0
                if last[i] ~= color then
                    local tc = tcs[r2i[color]]
                    pixels[i]:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
                    last[i] = color
                    changed = changed + 1
                end
            end
        else
            -- "full":整屏扫描
            local total = SCREEN_WIDTH * SCREEN_HEIGHT
            for i = 0, total - 1 do
                local color = buffer[i] or 0
                if last[i] ~= color then
                    local tc = tcs[r2i[color]]
                    pixels[i]:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
                    last[i] = color
                    changed = changed + 1
                end
            end
        end

        self.frameCount = self.frameCount + 1
        local now = GetTime and GetTime() or 0
        if now - self.lastFpsUpdate >= 1.0 then
            self.currentFps = self.frameCount
            self.frameCount = 0
            self.lastFpsUpdate = now
        end

        local frameTime = (debugprofilestop and debugprofilestop() or 0) - startTime
        return frameTime, changed
    end

    function renderer:GetModeName()
        return "调色板 256x240"
    end

    function renderer:SetMode(_mode) end

    function renderer:Show() self.frame:Show() end
    function renderer:Hide() self.frame:Hide() end

    function renderer:SetPoint(...)
        self.frame:SetPoint(...)
    end

    return renderer
end
