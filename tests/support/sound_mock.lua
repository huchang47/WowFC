-- sound_mock.lua
-- 可注入的 PlaySoundFile / StopSound mock 替身。
--
-- 设计动机（对应 design.md 的 SoundBackend 与属性 P5/P6/P7/P8/P9）：
--   - 解析层是纯逻辑、可测试；播放层是副作用适配。
--   - 测试中用 mock 记录“何时、用什么参数”调用了 PlaySoundFile / StopSound，
--     从而断言触发 / 停止 / 节流 / 关闭后零触发等行为，而非真实发声。
--   - 还需模拟“后端不可用 / 返回 nil / 抛错”等降级场景（P9）。
--
-- 用法：
--   local SoundMock = require("tests.support.sound_mock")
--   local mock = SoundMock.new()
--   mock:install()                      -- 安装为全局 PlaySoundFile/StopSound
--   ... 运行被测代码 ...
--   assert(#mock.playCalls == N)        -- 断言调用记录
--   mock:uninstall()                    -- 还原全局，避免污染其它测试

local SoundMock = {}
SoundMock.__index = SoundMock

-- 创建一个新的 mock 实例。
-- opts（可选）：
--   willPlay        : PlaySoundFile 返回的第一个值（默认 true）
--   handleSequence  : 句柄序列（数组）；按调用次序返回，用尽后回退到 handleStart 自增
--   handleStart     : 自增句柄的起始值（默认 1）
--   failPlay        : true 时 PlaySoundFile 抛错（模拟平台异常，用于 P9）
--   failStop        : true 时 StopSound 抛错（用于 P9）
--   playReturnsNil  : true 时 PlaySoundFile 返回 (nil, nil)（模拟被静音，用于 P9/错误处理）
function SoundMock.new(opts)
    opts = opts or {}
    local self = setmetatable({}, SoundMock)
    self.playCalls = {}        -- 每项：{ path = <string>, channel = <string|nil> }
    self.stopCalls = {}        -- 每项：{ handle = <any>, fadeout = <number|nil> }
    self.willPlay = (opts.willPlay ~= nil) and opts.willPlay or (opts.willPlay == nil and true)
    self.handleSequence = opts.handleSequence
    self._handleCursor = 0
    self._handleCounter = (opts.handleStart or 1) - 1
    self.failPlay = opts.failPlay or false
    self.failStop = opts.failStop or false
    self.playReturnsNil = opts.playReturnsNil or false
    self._savedPlaySoundFile = nil
    self._savedStopSound = nil
    self._installed = false
    return self
end

-- 内部：决定本次播放返回的句柄
function SoundMock:_nextHandle()
    if self.handleSequence then
        self._handleCursor = self._handleCursor + 1
        local h = self.handleSequence[self._handleCursor]
        if h ~= nil then
            return h
        end
    end
    self._handleCounter = self._handleCounter + 1
    return self._handleCounter
end

-- 模拟 WoW 的 PlaySoundFile(path, channel) -> willPlay, soundHandle
function SoundMock:playSoundFile(path, channel)
    table.insert(self.playCalls, { path = path, channel = channel })
    if self.failPlay then
        error("sound_mock: 模拟 PlaySoundFile 抛错")
    end
    if self.playReturnsNil then
        return nil, nil
    end
    return self.willPlay, self:_nextHandle()
end

-- 模拟 WoW 的 StopSound(handle, fadeout)
function SoundMock:stopSound(handle, fadeout)
    table.insert(self.stopCalls, { handle = handle, fadeout = fadeout })
    if self.failStop then
        error("sound_mock: 模拟 StopSound 抛错")
    end
end

-- 将 mock 安装为全局 PlaySoundFile / StopSound（保存原值以便还原）
function SoundMock:install()
    if self._installed then return self end
    self._savedPlaySoundFile = rawget(_G, "PlaySoundFile")
    self._savedStopSound = rawget(_G, "StopSound")
    local mock = self
    _G.PlaySoundFile = function(path, channel)
        return mock:playSoundFile(path, channel)
    end
    _G.StopSound = function(handle, fadeout)
        return mock:stopSound(handle, fadeout)
    end
    self._installed = true
    return self
end

-- 还原全局，移除 mock 注入（避免跨测试污染）
function SoundMock:uninstall()
    if not self._installed then return self end
    _G.PlaySoundFile = self._savedPlaySoundFile
    _G.StopSound = self._savedStopSound
    self._installed = false
    return self
end

-- 清空已记录的调用（保留安装状态与配置）
function SoundMock:clear()
    self.playCalls = {}
    self.stopCalls = {}
    return self
end

return SoundMock
