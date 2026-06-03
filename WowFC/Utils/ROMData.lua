-- ROMData.lua
-- ROM 数据加载工具
-- 将 ROMs 目录中的 .nes 文件转换为 Lua 表

local addonName, addon = ...

-- ROM 数据存储
_G.WOWFC_ROM_DATA = {}

-- 读取文件并转换为字节表
function addon:FileToByteTable(filepath)
    local bytes = {}

    -- 使用 io 库读取文件（在 WoW 外部运行此函数生成数据）
    local file = io.open(filepath, "rb")
    if not file then
        return nil
    end

    while true do
        local byte = file:read(1)
        if not byte then break end
        table.insert(bytes, string.byte(byte))
    end

    file:close()
    return bytes
end

-- 将字节表转换为 Lua 代码字符串
function addon:ByteTableToLuaCode(filename, bytes)
    if not bytes or #bytes == 0 then
        return nil
    end

    local code = string.format("-- Auto-generated ROM data for %s\n", filename)
    code = code .. string.format("WOWFC_ROM_DATA[%q] = {\n", filename)

    -- 每行 16 个字节
    for i = 1, #bytes do
        if i % 16 == 1 then
            code = code .. "    "
        end

        code = code .. string.format("0x%02X", bytes[i])

        if i < #bytes then
            code = code .. ", "
        end

        if i % 16 == 0 then
            code = code .. "\n"
        end
    end

    -- 如果最后一行不满 16 个，也需要换行
    if #bytes % 16 ~= 0 then
        code = code .. "\n"
    end

    code = code .. "}\n"

    return code
end

-- 生成 ROM 数据文件（在 WoW 外部调用）
function addon:GenerateROMDataFile(outputPath)
    local romsDir = "Interface\\AddOns\\WOWFC\\ROMs\\"
    local romFiles = {
        "MARIO.NES",
    }

    local allCode = "-- Auto-generated ROM data file\n"
    allCode = allCode .. "-- Do not edit manually\n\n"
    allCode = allCode .. "local _, addon = ...\n\n"
    allCode = allCode .. "-- ROM data storage\n"
    allCode = allCode .. "_G.WOWFC_ROM_DATA = _G.WOWFC_ROM_DATA or {}\n\n"

    local hasData = false

    for _, filename in ipairs(romFiles) do
        local filepath = romsDir .. filename
        local bytes = self:FileToByteTable(filepath)

        if bytes then
            local code = self:ByteTableToLuaCode(filename, bytes)
            if code then
                allCode = allCode .. code .. "\n"
                hasData = true
                print(string.format("Processed: %s (%d bytes)", filename, #bytes))
            end
        else
            print(string.format("Failed to read: %s", filepath))
        end
    end

    if hasData then
        -- 添加注册函数
        allCode = allCode .. "-- Register all ROM data\n"
        allCode = allCode .. "function addon:RegisterAllROMData()\n"
        allCode = allCode .. "    for filename, data in pairs(WOWFC_ROM_DATA) do\n"
        allCode = allCode .. "        self:RegisterROMData(filename, data)\n"
        allCode = allCode .. "    end\n"
        allCode = allCode .. "end\n"

        -- 写入文件
        local outfile = io.open(outputPath, "w")
        if outfile then
            outfile:write(allCode)
            outfile:close()
            print("Generated: " .. outputPath)
        else
            print("Failed to write: " .. outputPath)
        end
    end
end

-- 在 WoW 中加载 ROM 数据
function addon:LoadROMDataFromTOC()
    -- ROM 数据会通过单独的 Lua 文件加载
    -- 这里只是一个占位符，实际数据在 ROMData_Generated.lua 中
end

-- 导出函数
addon.GenerateROMDataFile = addon.GenerateROMDataFile
addon.FileToByteTable = addon.FileToByteTable
addon.ByteTableToLuaCode = addon.ByteTableToLuaCode
