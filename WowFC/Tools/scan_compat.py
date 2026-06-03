#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描 nesrom-master 目录，按 mapper 分类，列出当前版本(仅 Mapper 0)可用的 ROM。"""

import os
import sys
from collections import defaultdict

# 已知 mapper 名字（只列常见的）
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


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "ROMs", "nesrom-master")
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        print(f"目录不存在: {root}")
        sys.exit(1)

    by_mapper = defaultdict(list)  # mapper -> [(rel_path, prg_kb, chr_kb)]
    invalid = []

    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.lower().endswith(".nes"):
                continue
            full = os.path.join(dirpath, name)
            mapper, prg, chr_, ok = parse_header(full)
            rel = os.path.relpath(full, root)
            if not ok:
                invalid.append(rel)
                continue
            by_mapper[mapper].append((rel, prg, chr_))

    total = sum(len(v) for v in by_mapper.values()) + len(invalid)
    print(f"扫描总数: {total} 个 .nes (合法 {total - len(invalid)}, 头损坏 {len(invalid)})")
    print()

    # mapper 分布
    print("=== Mapper 分布 ===")
    for m in sorted(by_mapper.keys()):
        nm = MAPPER_NAMES.get(m, "?")
        print(f"  Mapper {m:>3} ({nm:<14}) : {len(by_mapper[m])} 个")
    if invalid:
        print(f"  头损坏          : {len(invalid)} 个")

    print()
    # 当前版本可用 = Mapper 0
    compat = by_mapper.get(0, [])
    compat.sort()
    print(f"=== 当前版本(Mapper 0 / NROM)可用 ROM: {len(compat)} 个 ===")
    for rel, prg, chr_ in compat:
        # 只展示 PRG/CHR 大小（NROM 标准是 16/32KB PRG, 8KB CHR）
        print(f"  {rel}  [PRG {prg}KB, CHR {chr_}KB]")

    # 输出一份纯文件名清单，方便后续复制到 ROMs/
    out_list = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "compat_mapper0.txt")
    with open(out_list, "w", encoding="utf-8") as f:
        for rel, prg, chr_ in compat:
            f.write(rel + "\n")
    print()
    print(f"清单已写入: {out_list}")


if __name__ == "__main__":
    main()
