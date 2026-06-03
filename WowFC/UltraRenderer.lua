-- UltraRenderer.lua
-- 256x240 原生分辨率 NES 帧渲染器,目标 60fps。
--
-- 关键技术(参考 cfoust/gnomeboy 在 WoW 里跑 GameBoy 的方案):
--   1. 拆分成 240 行,每行一个 Frame、256 个 1x1 Texture。
--      WoW 单个 Frame 的子 widget 上限约为 2^14=16384,
--      整屏 256x240=61440 必须分行才能合规。
--   2. 主屏 + 每行都开 SetFlattensRenderLayers(true) + SetIsFrameBuffer(true)。
--      让 GPU 把所有 sub-texture 离屏合成,大幅降低主渲染队列压力。
--      参考:warcraft.wiki.gg/wiki/API_Frame_SetIsFrameBuffer
--      "必须先 SetFlattensRenderLayers 否则可能 invisible frame"
--   3. 脏检查:每像素记录 last_color,只有变化时才 SetColorTexture。
--   4. RGB 缓存:24-bit int → {r,g,b} 用 metatable 懒加载。
--
-- buffer[i] 协议:i 是 (y*256 + x) 的 0-based 下标,值是 24-bit RGB 整数
-- (R<<16 | G<<8 | B),与 PPU.lua 的 buffer 一致。
--
-- 对外接口与旧 UltraRenderer 兼容:
--   factory:Create(parent, opts) → renderer
--   renderer:Render(buffer, dirty_tiles)  -- dirty_tiles 暂时忽略
--   renderer:GetModeName()
--   renderer:SetMode(mode)
--   renderer.currentFps  -- 字段
--   renderer.frame       -- 字段(供 WOWFC.lua 兼容引用)

local UltraRenderer = {}
_G.WOWFC_UltraRenderer = UltraRenderer

local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 240

-- 24-bit RGB 整数 → {r,g,b}(归一化到 [0,1]),metatable 懒加载
local colorCache = setmetatable({}, {
    __index = function(t, k)
        local r = bit.band(bit.rshift(k, 16), 0xFF) / 255
        local g = bit.band(bit.rshift(k, 8), 0xFF) / 255
        local b = bit.band(k, 0xFF) / 255
        local v = { r, g, b }
        t[k] = v
        return v
    end,
})

function UltraRenderer:Create(parent, options)
    options = options or {}
    local scale = options.scale or 2
    local screenW = SCREEN_WIDTH * scale
    local screenH = SCREEN_HEIGHT * scale

    local renderer = {
        scale = scale,
        targetFps = options.targetFps or 60,

        frameCount = 0,
        currentFps = 0,
        lastFpsUpdate = 0,

        -- pixel_count 个像素的 last_color 缓存(用一维数组减少索引开销)
        last_colors = {},
    }

    -- 主 screen frame:开 flatten + framebuffer
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

    -- pixelW / pixelH:每个 NES 像素在屏幕上的实际像素尺寸
    local pixelW = screenW / SCREEN_WIDTH
    local pixelH = screenH / SCREEN_HEIGHT

    -- 240 个 row frame,每行 256 texture。一维 pixels 数组按 (y*256 + x) 索引
    renderer.rows = {}
    renderer.pixels = {}

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
            tex:SetColorTexture(0, 0, 0)
            renderer.pixels[rowBase + x] = tex
            renderer.last_colors[rowBase + x] = -1  -- 强制首帧全量重绘
        end
    end

    --------------------------------------------------------------------
    -- Render: 把 NES framebuffer 投到屏幕
    -- @param buffer table  长度 256*240 的数组,buffer[i] = 24-bit RGB int
    -- @param ppu PPU 对象  携带本帧元数据,可能为 nil(向后兼容)
    --
    -- ppu._frameMode 决定遍历策略:
    --   "skip"    本帧无任何变化 → 直接 return,Present ≈ 0
    --   "partial" 仅 sprite 变化 → 仅扫描 (撤销区 ∪ 新画区) ≈ 1.5k-3k 像素
    --   "full"    BG 变化 → 全屏 60K 像素扫描(老路径)
    -- 没有 ppu 元数据时退化到全屏扫描,行为与旧版兼容。
    --------------------------------------------------------------------
    function renderer:Render(buffer, ppu)
        if not buffer then return 0 end

        local startTime = debugprofilestop and debugprofilestop() or 0
        local pixels = self.pixels
        local last = self.last_colors
        local cache = colorCache
        local changed = 0

        -- 没传 ppu / mode 缺失 → 全屏老路径
        local mode = ppu and ppu._frameMode or "full"

        if mode == "skip" then
            -- 啥都不画。但仍然要更新 fps 计数让 UI 数字不停。
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
            -- 只扫两段列表,典型 1.5k-3k 像素而非 60k。
            -- 撤销区:上一帧 sprite 占用、本帧已被 PPU 用 BG 颜色填回的位置。
            -- 新画区:本帧 sprite 写入的位置。
            -- 两段可能有重叠,但每个 index 独立比 last_color → 双写无副作用。
            local undoList = ppu._frameUndoList
            local undoN    = ppu._frameUndoN or 0
            for k = 1, undoN do
                local i = undoList[k]
                local color = buffer[i] or 0
                if last[i] ~= color then
                    local rgb = cache[color]
                    pixels[i]:SetColorTexture(rgb[1], rgb[2], rgb[3])
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
                    local rgb = cache[color]
                    pixels[i]:SetColorTexture(rgb[1], rgb[2], rgb[3])
                    last[i] = color
                    changed = changed + 1
                end
            end
        else
            -- "full":整屏扫描(BG 变化、首帧、向后兼容)
            local total = SCREEN_WIDTH * SCREEN_HEIGHT
            for i = 0, total - 1 do
                local color = buffer[i] or 0
                if last[i] ~= color then
                    local rgb = cache[color]
                    pixels[i]:SetColorTexture(rgb[1], rgb[2], rgb[3])
                    last[i] = color
                    changed = changed + 1
                end
            end
        end

        -- 帧率统计(用 GetTime,debugprofilestop 仅做精度细节)
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

    --------------------------------------------------------------------
    -- 兼容旧接口
    --------------------------------------------------------------------
    function renderer:GetModeName()
        return "原生 256x240"
    end

    function renderer:SetMode(_mode)
        -- 新渲染器只有原生模式,无需切换
    end

    function renderer:Show() self.frame:Show() end
    function renderer:Hide() self.frame:Hide() end

    function renderer:SetPoint(...)
        self.frame:SetPoint(...)
    end

    return renderer
end
