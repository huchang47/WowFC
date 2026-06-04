#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描 ROMs 目录，按 mapper 分类，列出当前版本支持的 ROM。"""

import os
import sys
import argparse
from collections import defaultdict

# 已知 mapper 名字
MAPPER_NAMES = {
    0: "NROM",
    1: "MMC1",
    2: "UxROM",
    3: "CNROM",
    4: "MMC3",
    5: "MMC5",
    7: "AxROM",
    9: "MMC2",
    10: "MMC4",
    11: "Color Dreams",
    66: "GxROM",
    71: "Camerica",
}

# 当前模拟器支持的 Mapper 列表
SUPPORTED_MAPPERS = {0, 1, 2, 3, 4}


def parse_header(path):
    """读 iNES 头，返回 (mapper, prg_kb, chr_kb, ok)；不合法返回 (None,...,False)。"""
    try:
        with open(path, "rb") as f:
            head = f.read(16)
        if len(head) < 16 or head[:4] != b"NES\x1a":
            return (None, 0, 0, False)
        prg = head[4]  # 16KB 单位
        chr_ = head[5]  # 8KB 单位
        flag6 = head[6]
        flag7 = head[7]
        mapper = (flag6 >> 4) | (flag7 & 0xF0)
        return (mapper, prg * 16, chr_ * 8, True)
    except Exception:
        return (None, 0, 0, False)


def scan_roms(roms_dir):
    """扫描目录中的所有 .nes 文件，返回分类结果。"""
    by_mapper = defaultdict(list)  # mapper -> [(rel_path, prg_kb, chr_kb)]
    invalid = []

    if not os.path.isdir(roms_dir):
        print(f"错误: 目录不存在: {roms_dir}")
        return None, None

    for dirpath, _, files in os.walk(roms_dir):
        for name in files:
            if not name.lower().endswith(".nes"):
                continue
            full = os.path.join(dirpath, name)
            mapper, prg, chr_, ok = parse_header(full)
            rel = os.path.relpath(full, roms_dir)
            if not ok:
                invalid.append(rel)
                continue
            by_mapper[mapper].append((rel, prg, chr_))

    return by_mapper, invalid


def print_report(by_mapper, invalid, roms_dir):
    """打印扫描报告。"""
    total = sum(len(v) for v in by_mapper.values()) + len(invalid)
    print(f"扫描目录: {roms_dir}")
    print(f"扫描总数: {total} 个 .nes (合法 {total - len(invalid)}, 头损坏 {len(invalid)})")
    print()

    # mapper 分布
    print("=== Mapper 分布 ===")
    for m in sorted(by_mapper.keys()):
        nm = MAPPER_NAMES.get(m, "?")
        supported = "✓" if m in SUPPORTED_MAPPERS else "✗"
        print(f"  Mapper {m:>3} ({nm:<14}) {supported} : {len(by_mapper[m])} 个")
    if invalid:
        print(f"  头损坏                        : {len(invalid)} 个")

    print()

    # 当前版本可用
    compat = []
    for m in SUPPORTED_MAPPERS:
        compat.extend(by_mapper.get(m, []))
    compat.sort()

    print(f"=== 当前版本(Mapper {', '.join(map(str, sorted(SUPPORTED_MAPPERS)))})可用 ROM: {len(compat)} 个 ===")
    for rel, prg, chr_ in compat[:50]:  # 只显示前50个，避免刷屏
        print(f"  {rel}  [PRG {prg}KB, CHR {chr_}KB]")
    if len(compat) > 50:
        print(f"  ... 还有 {len(compat) - 50} 个")

    return compat


def save_compat_list(by_mapper, output_file):
    """保存兼容列表到文件。"""
    compat = []
    for m in SUPPORTED_MAPPERS:
        compat.extend(by_mapper.get(m, []))
    compat.sort()

    try:
        with open(output_file, "w", encoding="utf-8") as f:
            for rel, _, _ in compat:
                f.write(rel + "\n")
        print(f"\n兼容列表已保存: {output_file}")
        return True
    except Exception as e:
        print(f"错误: 无法保存列表: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="扫描 ROMs 目录并按 Mapper 分类")
    parser.add_argument("--roms-dir", "-r", default=None,
                        help="ROMs 目录路径 (默认: 脚本所在目录的 ../ROMs)")
    parser.add_argument("--output", "-o", default=None,
                        help="输出兼容列表文件路径 (默认: 脚本所在目录的 compat_list.txt)")
    parser.add_argument("--no-save", action="store_true",
                        help="不保存兼容列表文件")

    args = parser.parse_args()

    # 默认路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    roms_dir = args.roms_dir or os.path.join(script_dir, "..", "ROMs")
    roms_dir = os.path.abspath(roms_dir)

    output_file = args.output or os.path.join(script_dir, "compat_list.txt")

    # 扫描
    by_mapper, invalid = scan_roms(roms_dir)
    if by_mapper is None:
        sys.exit(1)

    # 打印报告
    print_report(by_mapper, invalid, roms_dir)

    # 保存列表
    if not args.no_save:
        save_compat_list(by_mapper, output_file)


if __name__ == "__main__":
    main()
