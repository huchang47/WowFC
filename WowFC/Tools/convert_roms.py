#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ROM 转换工具
将 ROMs 目录中的 .nes 文件转换为 Lua 数据文件

使用方法:
    python convert_roms.py
    python convert_roms.py --roms-dir "C:\\MyROMs" --output "C:\\Output\\ROMData.lua"
"""

import os
import sys
import argparse


def read_rom_file(filepath):
    """读取 ROM 文件并返回字节列表"""
    try:
        with open(filepath, 'rb') as f:
            data = f.read()
        return list(data)
    except Exception as e:
        print(f"错误: 无法读取文件 {filepath}: {e}")
        return None


def bytes_to_lua_code(filename, bytes_data):
    """将字节数据转换为 Lua 代码"""
    if not bytes_data:
        return None

    # 转义文件名中的特殊字符
    safe_filename = filename.replace('"', '\\"')

    lines = []
    lines.append(f'-- ROM: {safe_filename} ({len(bytes_data)} bytes)')
    lines.append(f'WOWFC_ROM_DATA["{safe_filename}"] = {{')

    # 每行 16 个字节
    for i in range(0, len(bytes_data), 16):
        row = bytes_data[i:i+16]
        hex_values = [f"0x{b:02X}" for b in row]
        lines.append("    " + ", ".join(hex_values) + ",")

    lines.append("}")
    lines.append("")

    return "\n".join(lines)


def generate_rom_data_file(roms_dir, output_file):
    """生成 ROM 数据 Lua 文件"""

    # 获取 ROMs 目录中的所有 .nes 文件
    if not os.path.exists(roms_dir):
        print(f"错误: ROMs 目录不存在: {roms_dir}")
        return False

    rom_files = [f for f in os.listdir(roms_dir) if f.lower().endswith('.nes')]

    if not rom_files:
        print(f"警告: 在 {roms_dir} 中没有找到 .nes 文件")
        return False

    print(f"找到 {len(rom_files)} 个 ROM 文件:")
    for rom in rom_files:
        print(f"  - {rom}")

    # 生成 Lua 代码
    header = """-- ROMData_Generated.lua
-- 自动生成的 ROM 数据文件
-- 请勿手动编辑
-- 生成时间: 自动生成

local _, addon = ...

-- ROM 数据存储
_G.WOWFC_ROM_DATA = _G.WOWFC_ROM_DATA or {}

"""

    body_parts = []
    total_size = 0

    for rom_file in sorted(rom_files):
        filepath = os.path.join(roms_dir, rom_file)
        bytes_data = read_rom_file(filepath)

        if bytes_data:
            lua_code = bytes_to_lua_code(rom_file, bytes_data)
            if lua_code:
                body_parts.append(lua_code)
                total_size += len(bytes_data)
                print(f"已处理: {rom_file} ({len(bytes_data)} bytes)")

    footer = """-- 注册所有 ROM 数据
function addon:RegisterAllROMData()
    for filename, data in pairs(WOWFC_ROM_DATA) do
        if addon.RegisterROMData then
            addon:RegisterROMData(filename, data)
        end
    end
end

-- 初始化时自动注册
addon:RegisterAllROMData()
"""

    # 写入输出文件
    full_content = header + "\n".join(body_parts) + footer

    # 确保输出目录存在
    output_dir = os.path.dirname(output_file)
    if output_dir and not os.path.exists(output_dir):
        try:
            os.makedirs(output_dir)
            print(f"创建目录: {output_dir}")
        except Exception as e:
            print(f"错误: 无法创建目录 {output_dir}: {e}")
            return False

    try:
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(full_content)
        print(f"\n成功生成: {output_file}")
        print(f"总大小: {total_size} bytes ({total_size / 1024:.2f} KB)")
        return True
    except Exception as e:
        print(f"错误: 无法写入文件 {output_file}: {e}")
        return False


def get_script_dir():
    """获取脚本/exe 所在目录（兼容 PyInstaller 打包）"""
    if getattr(sys, 'frozen', False):
        # PyInstaller 打包后的 exe
        return os.path.dirname(sys.executable)
    else:
        # 普通 Python 脚本
        return os.path.dirname(os.path.abspath(__file__))


def main():
    parser = argparse.ArgumentParser(
        description="将 .nes ROM 文件转换为 WoW 插件可用的 Lua 数据文件"
    )
    parser.add_argument(
        "--roms-dir", "-r",
        default=None,
        help="ROMs 目录路径 (默认: 工具所在目录的 ../ROMs)"
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="输出 Lua 文件路径 (默认: 工具所在目录的 ../Utils/ROMData_Generated.lua)"
    )

    args = parser.parse_args()

    # 获取脚本/exe 所在目录
    script_dir = get_script_dir()

    # 路径配置
    roms_dir = args.roms_dir or os.path.join(script_dir, '..', 'ROMs')
    output_file = args.output or os.path.join(script_dir, '..', 'Utils', 'ROMData_Generated.lua')

    # 转换为绝对路径
    roms_dir = os.path.abspath(roms_dir)
    output_file = os.path.abspath(output_file)

    print("=" * 60)
    print("WOWFC ROM 转换工具")
    print("=" * 60)
    print(f"ROMs 目录: {roms_dir}")
    print(f"输出文件: {output_file}")
    print("-" * 60)

    success = generate_rom_data_file(roms_dir, output_file)

    print("-" * 60)
    if success:
        print("转换完成!")
        print("\n请在 TOC 文件中确保加载顺序:")
        print("  Utils\\ROMData_Generated.lua")
        print("  WOWFC.lua")
    else:
        print("转换失败!")
        sys.exit(1)


if __name__ == "__main__":
    main()
