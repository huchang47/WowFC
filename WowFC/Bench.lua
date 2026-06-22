-- Bench.lua
-- 渲染器 A/B 基准:对比 UltraRenderer(SetColorTexture)与 PaletteRenderer
-- (SetTexCoord)在真实帧序列上的 Present(每帧 Render)CPU 耗时。
--
-- 思路:
--   1. "/fc bench" 触发后,录制接下来 N 帧的真实数据(深拷贝 framebuffer +
--      帧模式 + partial 的 undo/new 脏区列表),来自正在运行的游戏。
--   2. 录满后离屏创建两个渲染器实例,把同一组帧各回放若干遍,用
--      debugprofilestop 累计 Render 内部耗时,打印每帧均值与加速比。
--   3. 同时测两种场景:
--        steady  —— 按录制模式回放,脏检查生效(真实增量,日常表现)
--        full    —— 每帧强制全屏 61440 像素重绘(Present 上限/最坏情况)
--
-- 关键:整个流程跑在协程里,分帧执行(每跑若干帧 / 每建一个渲染器就 yield,
-- 由 C_Timer 驱动恢复),否则一次同步执行会超 WoW 单帧脚本时限被 "script ran
-- too long" 杀掉。两个离屏渲染器各 256x240=61440 个 texture,故创建也拆到两帧。
--
-- 为什么离屏且隐藏也公平:SetColorTexture / SetTexCoord 的成本是 Lua->C 的
-- 状态更新调用,与可见与否、是否被 GPU 合成无关;debugprofilestop 测的正是这
-- 部分 CPU 时间。两个渲染器同等条件离屏,对比公平。

local Bench = {}
_G.WowFC_Bench = Bench

-- 本地化字符串表
local L = _G.WowFC_Locale or {}

local SCREEN_WIDTH = 256
local SCREEN_HEIGHT = 240
local PIXELS = SCREEN_WIDTH * SCREEN_HEIGHT

-- 每个 tick(一次协程恢复)最多处理多少帧 Render 再让出。
-- full 比 steady 重得多(每帧全屏 61440 像素 + reset),故拆得更细。
local STEADY_FRAMES_PER_TICK = 20
local FULL_FRAMES_PER_TICK = 2

-- full 场景每帧全屏重绘极重,无需用全部帧 × repeats,取少量样本即可代表。
local FULL_SAMPLE_CAP = 15
local FULL_REPEATS = 2

Bench._recording = false
Bench._snaps = nil
Bench._wantFrames = 0
Bench._repeats = 0
Bench._holder = nil
Bench._ultra = nil
Bench._palette = nil

function Bench:IsRecording()
    return self._recording
end

-- 由 WowFC.lua 的 OnFrame 在录制期间调用,抓一帧快照。
function Bench:Capture(buffer, ppu)
    if not self._recording then return end
    if not buffer then return end

    -- 深拷贝 framebuffer(后续帧会覆写 PPU buffer,必须拷);
    -- tonumber 兜底,避免个别非数值像素让渲染器的颜色解码报警告。
    local buf = {}
    for i = 0, PIXELS - 1 do
        buf[i] = tonumber(buffer[i]) or 0
    end

    local mode = ppu and ppu._frameMode or "full"
    local snapPpu = { _frameMode = mode }
    if mode == "partial" and ppu then
        local un = ppu._frameUndoN or 0
        local uo = {}
        local src = ppu._frameUndoList
        for k = 1, un do uo[k] = src[k] end
        snapPpu._frameUndoList = uo
        snapPpu._frameUndoN = un

        local nn = ppu._frameNewN or 0
        local no = {}
        local nsrc = ppu._frameNewList
        for k = 1, nn do no[k] = nsrc[k] end
        snapPpu._frameNewList = no
        snapPpu._frameNewN = nn
    end

    self._snaps[#self._snaps + 1] = { buf = buf, ppu = snapPpu, mode = mode }

    if #self._snaps >= self._wantFrames then
        self._recording = false
        print(string.format("|cff00ff00WowFC Bench|r: " ..
            (L["MSG_BENCH_RECORDED"] or "Recorded %d frames, starting off-screen comparison (split-frame execution, please wait)..."),
            #self._snaps))
        self:_drive()
    end
end

-- 开始录制。frames:录制帧数;repeats:每渲染器回放遍数。
function Bench:Start(frames, repeats)
    if self._recording then
        print("|cffff8800WowFC Bench|r: " .. (L["MSG_BENCH_RECORDING"] or "Recording, please wait."))
        return
    end
    self._wantFrames = frames or 60
    self._repeats = repeats or 3
    self._snaps = {}
    self._recording = true
    print(string.format("|cff00ff00WowFC Bench|r: " ..
        (L["MSG_BENCH_START"] or "Recording %d real frames... (make sure the game is running /画面 has changes)"),
        self._wantFrames))
end

-- 把 last_colors 全置 -1,强制下次 Render 全屏重绘。
local function resetDirty(rend)
    local lc = rend.last_colors
    for i = 0, PIXELS - 1 do
        lc[i] = -1
    end
end

local FULL_PPU = { _frameMode = "full" }

-- 回放测量(运行在协程内,按 framesPerTick 周期性 yield 让出主线程)。
-- 返回(每帧平均 ms, 每帧平均改色像素数)。
local function measure(rend, snaps, repeats, forceFull)
    local perTick = forceFull and FULL_FRAMES_PER_TICK or STEADY_FRAMES_PER_TICK
    -- full 只取少量样本帧(每帧工作量相同,够统计即可),steady 用全部帧
    local sampleCount = forceFull and math.min(#snaps, FULL_SAMPLE_CAP) or #snaps
    local c = 0

    -- steady 先预热一遍让 last_colors 进入稳态(不计时)
    if not forceFull then
        for s = 1, sampleCount do
            rend:Render(snaps[s].buf, snaps[s].ppu)
            c = c + 1
            if c % perTick == 0 then coroutine.yield() end
        end
    end

    local totalMs, totalChanged = 0, 0
    local n = repeats * sampleCount
    for _ = 1, repeats do
        for s = 1, sampleCount do
            local snap = snaps[s]
            if forceFull then resetDirty(rend) end
            local dt, changed = rend:Render(snap.buf, forceFull and FULL_PPU or snap.ppu)
            totalMs = totalMs + (dt or 0)
            totalChanged = totalChanged + (changed or 0)
            c = c + 1
            if c % perTick == 0 then coroutine.yield() end
        end
    end

    return totalMs / n, totalChanged / n
end

-- 协程主体:暂停游戏 → 建渲染器(分两帧)→ 4 个测量阶段 → 打印 → 恢复游戏。
function Bench:_runAll()
    local snaps = self._snaps
    if not snaps or #snaps == 0 then
        print("|cffff0000WowFC Bench|r: " .. (L["MSG_BENCH_NO_FRAMES"] or "No frames recorded. Run /fc bench while the game is running."))
        return
    end

    -- 暂停游戏循环,避免与 bench 累计 CPU 触发 addon 执行配额上限
    local addon = _G.WowFC
    self._pausedGame = (addon and addon.PauseForBench and addon:PauseForBench()) or false

    if not self._holder then
        self._holder = CreateFrame("Frame", nil, UIParent)
        self._holder:SetSize(SCREEN_WIDTH * 2, SCREEN_HEIGHT * 2)
        self._holder:SetPoint("CENTER")
        self._holder:Hide()
    end

    -- 两个渲染器各 6 万多 texture,分到两帧创建,避免单帧超时
    if not self._ultra then
        local f = _G.WowFC_UltraRenderer
        if not f then print("|cffff0000WowFC Bench|r: " .. (L["MSG_BENCH_NO_ULTRA"] or "UltraRenderer not loaded")); return end
        self._ultra = f:Create(self._holder, { scale = 2, targetFps = 60 })
        coroutine.yield()
    end
    if not self._palette then
        local f = _G.WowFC_PaletteRenderer
        if not f then print("|cffff0000WowFC Bench|r: " .. (L["MSG_BENCH_NO_PALETTE"] or "PaletteRenderer not loaded")); return end
        self._palette = f:Create(self._holder, { scale = 2, targetFps = 60 })
        if not self._palette then return end  -- 缺调色板数据,Create 已自行提示
        coroutine.yield()
    end

    local ultra, palette = self._ultra, self._palette
    local rep = self._repeats

    local modeCount = { skip = 0, partial = 0, full = 0 }
    for _, s in ipairs(snaps) do
        modeCount[s.mode] = (modeCount[s.mode] or 0) + 1
    end

    local uSteadyMs, uSteadyChg = measure(ultra, snaps, rep, false)
    local pSteadyMs, pSteadyChg = measure(palette, snaps, rep, false)
    local uFullMs = measure(ultra, snaps, FULL_REPEATS, true)
    local pFullMs = measure(palette, snaps, FULL_REPEATS, true)

    local function ratio(a, b)
        if b <= 0 then return "n/a" end
        return string.format("%.2fx", a / b)
    end

    print("|cff00ff00" .. (L["TITLE_BENCH"] or "===== WowFC Renderer A/B Benchmark =====") .. "|r")
    print(string.format(L["BENCH_STATS"] or "Frames: %d  Repeats: %d  Mode distribution: skip=%d partial=%d full=%d",
        #snaps, rep, modeCount.skip, modeCount.partial, modeCount.full))
    print(string.format(L["BENCH_PIXELS"] or "steady changed pixels/frame: Ultra=%.0f  Palette=%.0f (should match, verifies visual equivalence)",
        uSteadyChg, pSteadyChg))
    print("|cffffd700" .. (L["BENCH_STEADY"] or "— steady (dirty-check active, daily feel) —") .. "|r")
    print(string.format(L["BENCH_ULTRA_STEADY"] or "  UltraRenderer  (SetColorTexture): %.4f ms/frame", uSteadyMs))
    print(string.format(L["BENCH_PALETTE_STEADY"] or "  PaletteRenderer(SetTexCoord)    : %.4f ms/frame", pSteadyMs))
    print(string.format(L["BENCH_RATIO"] or "  Palette vs Ultra: %s  %s",
        ratio(uSteadyMs, pSteadyMs),
        (pSteadyMs < uSteadyMs) and "|cff00ff00" .. (L["FASTER"] or "(faster)") .. "|r" or "|cffff8800" .. (L["NOT_FASTER"] or "(not faster)") .. "|r"))
    print("|cffffd700" .. (L["BENCH_FULL"] or "— full (full-screen 61440 pixels redraw, worst-case) —") .. "|r")
    print(string.format(L["BENCH_ULTRA_FULL"] or "  UltraRenderer  : %.4f ms/frame", uFullMs))
    print(string.format(L["BENCH_PALETTE_FULL"] or "  PaletteRenderer: %.4f ms/frame", pFullMs))
    print(string.format(L["BENCH_RATIO"] or "  Palette vs Ultra: %s  %s",
        ratio(uFullMs, pFullMs),
        (pFullMs < uFullMs) and "|cff00ff00" .. (L["FASTER"] or "(faster)") .. "|r" or "|cffff8800" .. (L["NOT_FASTER"] or "(not faster)") .. "|r"))
    print("|cff888888" .. (L["BENCH_TIP"] or "Tip: steady is the daily metric; if both steady values are small, Present is not the bottleneck — focus on PPU/CPU.") .. "|r")
end

-- 启动/泵动协程:每次只恢复一段,跑完一段就让出一帧,直到协程结束。
function Bench:_drive()
    local co = coroutine.create(function() self:_runAll() end)
    local function pump()
        local ok, err = coroutine.resume(co)
        if not ok then
            print("|cffff0000WowFC Bench|r: " .. (L["MSG_BENCH_ERROR"] or "Runtime error: ") .. tostring(err))
            self:_restoreGame()
            return
        end
        if coroutine.status(co) ~= "dead" then
            C_Timer.After(0, pump)
        else
            self:_restoreGame()
        end
    end
    pump()
end

-- 恢复 bench 前暂停的游戏循环(只恢复一次)。
function Bench:_restoreGame()
    if self._pausedGame then
        self._pausedGame = false
        local addon = _G.WowFC
        if addon and addon.ResumeAfterBench then addon:ResumeAfterBench() end
    end
end

-- 兼容旧入口(直接跑;现已分帧驱动)
function Bench:Run()
    self:_drive()
end
