#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
调色板纹理生成工具(供 PaletteRenderer 使用)

把 NES 固定 64 色调色板烤成一张横向调色板纹理 PaletteTex.tga,
并生成 Utils/PaletteData_Generated.lua 作为运行时单一数据源。

设计动机:
  PaletteRenderer 借鉴 tna0y/wow-doom-within 的做法——每个像素 texture 共享
  同一张调色板图,改色只用 SetTexCoord(改 UV)而非 SetColorTexture(设纯色)。
  本脚本负责烤纹理 + 导出 Lua 端需要的元数据(颜色表、纹理路径、列宽)。

纹理布局:
  宽 256 / 高 4,64 个颜色每个占 COLOR_SPAN=4 个像素列(0..63 -> x//4)。
  4 行内容完全一致,故 TGA 上下翻转与否都无影响(用 bottom-up,描述符=0x08)。
  取色时 SetTexCoord 的 u 取色块内 [+1px,+3px] 区间,两端各留 1px 防双线性插值
  跨色 bleeding(参考 Doom 项目把纹理放大留边的思路)。

颜色来源:
  与 Core/PPU.lua 的 PPU:loadPalette() 完全同源(jsnes loadDefaultPalette)。
  PPU 调色板里存在重复色(多个 0x000000),反查 RGB->index 时塌缩到首个 index,
  视觉无差异。

用法:
    python gen_palette_tga.py
"""

import os
import struct

# NES 64 色固定调色板,与 Core/PPU.lua loadPalette() 的 defaultPalette 前 64 项一致。
# 改动这里时务必同步 PPU.lua,否则纹理与模拟器输出颜色对不上。
PALETTE = [
    0x757575, 0x271B8F, 0x0000AB, 0x47009F, 0x8F0077, 0xAB0013, 0xA70000, 0x7F0B00,
    0x432F00, 0x004700, 0x005100, 0x003F17, 0x1B3F5F, 0x000000, 0x000000, 0x000000,
    0xBCBCBC, 0x0073EF, 0x233BEF, 0x8300F3, 0xBF00BF, 0xE7005B, 0xDB2B00, 0xCB4F0F,
    0x8B7300, 0x009700, 0x00AB00, 0x00933B, 0x00838B, 0x000000, 0x000000, 0x000000,
    0xFFFFFF, 0x3FBFFF, 0x5F97FF, 0xA78BFD, 0xF77BFF, 0xFF77B7, 0xFF7763, 0xFF9B3B,
    0xF3BF3F, 0x83D313, 0x4FDF4B, 0x58F898, 0x00EBDB, 0x000000, 0x000000, 0x000000,
    0xFFFFFF, 0xABE7FF, 0xC7D7FF, 0xD7CBFF, 0xFFC7FF, 0xFFC7DB, 0xFFBFB3, 0xFFDBAB,
    0xFFE7A3, 0xE3FFA3, 0xABF3BF, 0xB3FFCF, 0x9FFFF3, 0x000000, 0x000000, 0x000000,
]

COLOR_SPAN = 4                      # 每个颜色占的像素列数
TEX_WIDTH = len(PALETTE) * COLOR_SPAN  # 256
TEX_HEIGHT = 4
WOW_TEX_PATH = "Interface\\AddOns\\WowFC\\PaletteTex.tga"


def write_tga(filepath):
    """写出 32 位无压缩 TGA(BGRA),宽 TEX_WIDTH 高 TEX_HEIGHT。"""
    # TGA 头 18 字节:image type=2(真彩无压缩),32bpp,描述符 0x08(8 位 alpha)
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,            # id length
        0,            # color map type
        2,            # image type: uncompressed true-color
        0, 0, 0,      # color map spec(无)
        0, 0,         # x/y origin
        TEX_WIDTH,
        TEX_HEIGHT,
        32,           # bits per pixel
        0x08,         # image descriptor: 8 alpha bits
    )

    row = bytearray()
    for x in range(TEX_WIDTH):
        idx = x // COLOR_SPAN
        rgb = PALETTE[idx]
        r = (rgb >> 16) & 0xFF
        g = (rgb >> 8) & 0xFF
        b = rgb & 0xFF
        # TGA 像素序为 BGRA
        row += bytes((b, g, r, 0xFF))

    with open(filepath, "wb") as f:
        f.write(header)
        for _ in range(TEX_HEIGHT):
            f.write(row)


def write_lua(filepath):
    """生成 Utils/PaletteData_Generated.lua:运行时单一数据源。"""
    lines = []
    lines.append("-- PaletteData_Generated.lua")
    lines.append("-- 自动生成,请勿手动编辑(由 tools/gen_palette_tga.py 生成)。")
    lines.append("-- 供 PaletteRenderer.lua 读取:NES 64 色调色板 + 调色板纹理元数据。")
    lines.append("-- 颜色与 Core/PPU.lua loadPalette() 同源。")
    lines.append("")
    lines.append("_G.WowFC_PALETTE_DATA = {")
    lines.append('    texPath = "%s",' % WOW_TEX_PATH.replace("\\", "\\\\"))
    lines.append("    texWidth = %d," % TEX_WIDTH)
    lines.append("    texHeight = %d," % TEX_HEIGHT)
    lines.append("    colorSpan = %d," % COLOR_SPAN)
    lines.append("    -- [0..63] = 24-bit RGB int,顺序即调色板 index,与纹理列一一对应")
    lines.append("    palette = {")
    for i in range(0, len(PALETTE), 8):
        chunk = PALETTE[i:i + 8]
        body = ", ".join("0x%06X" % c for c in chunk)
        if i == 0:
            # 用 [0] 显式起始,保证 0-based 下标
            body = "[0] = " + body
        lines.append("        " + body + ",")
    lines.append("    },")
    lines.append("}")
    lines.append("")

    with open(filepath, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    addon_dir = os.path.abspath(os.path.join(script_dir, "..", "WowFC"))
    tga_path = os.path.join(addon_dir, "PaletteTex.tga")
    lua_path = os.path.join(addon_dir, "Utils", "PaletteData_Generated.lua")

    print("=" * 56)
    print("WowFC 调色板纹理生成工具")
    print("=" * 56)
    print("颜色数: %d  纹理: %dx%d  每色列宽: %d" %
          (len(PALETTE), TEX_WIDTH, TEX_HEIGHT, COLOR_SPAN))

    write_tga(tga_path)
    print("已生成纹理: %s" % tga_path)

    write_lua(lua_path)
    print("已生成数据: %s" % lua_path)

    print("-" * 56)
    print("请在 TOC 中(UltraRenderer.lua 附近)声明:")
    print("  Utils\\PaletteData_Generated.lua")
    print("  PaletteRenderer.lua")
    print("完成!")


if __name__ == "__main__":
    main()
