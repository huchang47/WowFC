-- Controller.lua
-- 控制器输入处理
-- 基于 JSNES 的 controller.js 移植

local band = bit.band

-- 创建全局 Controller 表
_G.Controller = {}
Controller.__index = Controller

-- 按钮常量
Controller.BUTTON_A = 0
Controller.BUTTON_B = 1
Controller.BUTTON_SELECT = 2
Controller.BUTTON_START = 3
Controller.BUTTON_UP = 4
Controller.BUTTON_DOWN = 5
Controller.BUTTON_LEFT = 6
Controller.BUTTON_RIGHT = 7

function Controller:new(nes)
    local controller = setmetatable({}, self)
    controller.nes = nes
    
    -- 两个手柄的状态
    controller.state = {
        [1] = {},  -- 手柄 1
        [2] = {}   -- 手柄 2
    }
    
    -- 当前读取的按钮索引
    controller.index = {
        [1] = 0,
        [2] = 0
    }
    
    -- Strobe 状态
    controller._strobe = 0
    
    -- 初始化状态
    for i = 1, 2 do
        for j = 0, 7 do
            controller.state[i][j] = 0x40  -- 默认释放状态
        end
    end
    
    return controller
end

-- 设置按钮状态
function Controller:setButtonState(player, button, pressed)
    if pressed then
        self.state[player][button] = 0x41  -- 按下
    else
        self.state[player][button] = 0x40  -- 释放
    end
end

-- Strobe 信号 (写入 $4016)
function Controller:strobe(value)
    self._strobe = band(value, 1)
    if self._strobe == 1 then
        -- 重置索引
        self.index[1] = 0
        self.index[2] = 0
    end
end

-- 读取控制器状态 (读取 $4016/$4017)
function Controller:read(player)
    local retVal = 0
    
    if self._strobe == 1 then
        -- Strobe 模式下始终返回第一个按钮
        retVal = self.state[player][0]
        -- 重置索引
        self.index[player] = 0
    else
        -- 正常读取模式
        if self.index[player] <= 7 then
            retVal = self.state[player][self.index[player]]
            self.index[player] = self.index[player] + 1
        else
            -- 超出范围返回 1
            retVal = 0x41
        end
    end
    
    return retVal
end

-- 从键盘事件映射到按钮
function Controller:mapKeyToButton(key)
    local mapping = {
        ["UP"] = Controller.BUTTON_UP,
        ["DOWN"] = Controller.BUTTON_DOWN,
        ["LEFT"] = Controller.BUTTON_LEFT,
        ["RIGHT"] = Controller.BUTTON_RIGHT,
        ["Z"] = Controller.BUTTON_A,
        ["X"] = Controller.BUTTON_B,
        ["RETURN"] = Controller.BUTTON_START,
        ["RSHIFT"] = Controller.BUTTON_SELECT,
        ["LSHIFT"] = Controller.BUTTON_SELECT,
    }
    return mapping[key]
end

-- 处理键盘按下
function Controller:keyDown(key)
    local button = self:mapKeyToButton(key)
    if button then
        self:setButtonState(1, button, true)
    end
end

-- 处理键盘释放
function Controller:keyUp(key)
    local button = self:mapKeyToButton(key)
    if button then
        self:setButtonState(1, button, false)
    end
end

-- 重置控制器
function Controller:reset()
    self.index[1] = 0
    self.index[2] = 0
    self._strobe = 0
    
    for i = 1, 2 do
        for j = 0, 7 do
            self.state[i][j] = 0x40
        end
    end
end
