-- wow_mock.lua
-- 极简 WoW UI/全局 API 桩,仅覆盖渲染器(UltraRenderer / PaletteRenderer)在
-- headless 下运行所需:CreateFrame / CreateTexture / GetTime / debugprofilestop。
-- texture 桩记录最近一次 SetColorTexture / SetTexCoord 的参数,供视觉等价测试断言。

local M = {}

-- ---- texture 桩 ----
local TextureMT = {}
TextureMT.__index = TextureMT
function TextureMT:SetSize() end
function TextureMT:SetPoint() end
function TextureMT:SetTexture(p) self._texture = p end
function TextureMT:SetDrawLayer() end
function TextureMT:SetColorTexture(r, g, b)
    self._color = { r, g, b }
    self._setColorCalls = (self._setColorCalls or 0) + 1
end
function TextureMT:SetTexCoord(l, r, t, b)
    self._texcoord = { l, r, t, b }
    self._setTexCoordCalls = (self._setTexCoordCalls or 0) + 1
end
function TextureMT:SetAllPoints() end

local function newTexture()
    return setmetatable({}, TextureMT)
end

-- ---- frame 桩 ----
local FrameMT = {}
FrameMT.__index = FrameMT
function FrameMT:SetSize() end
function FrameMT:SetPoint() end
function FrameMT:Show() self._shown = true end
function FrameMT:Hide() self._shown = false end
function FrameMT:SetFlattensRenderLayers() end
function FrameMT:SetIsFrameBuffer() end
function FrameMT:SetFrameStrata() end
function FrameMT:CreateTexture() return newTexture() end

local function newFrame()
    return setmetatable({}, FrameMT)
end

-- 安装全局桩。返回卸载函数(测试结束可还原,避免污染其它脚本)。
function M.install()
    local saved = {
        CreateFrame = _G.CreateFrame,
        GetTime = _G.GetTime,
        debugprofilestop = _G.debugprofilestop,
        UIParent = _G.UIParent,
    }

    _G.CreateFrame = function() return newFrame() end
    _G.GetTime = function() return 0 end
    _G.debugprofilestop = function() return 0 end
    _G.UIParent = _G.UIParent or newFrame()

    return function()
        _G.CreateFrame = saved.CreateFrame
        _G.GetTime = saved.GetTime
        _G.debugprofilestop = saved.debugprofilestop
        _G.UIParent = saved.UIParent
    end
end

M.newFrame = newFrame
M.newTexture = newTexture

return M
