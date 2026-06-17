#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
APU 音色生成工具
按半音生成方波（pulse）与三角波（triangle）音色文件，覆盖 C2-C7（MIDI 36-96），
默认输出 .ogg 到 Sound/ 目录；若环境缺少音频编码器（ffmpeg / oggenc）则自动
回退输出 .wav，并在映射表中记录实际格式。

同时生成 Utils/APUToneMap_Generated.lua（运行时由 _G.WOWFC_APU_TONEMAP 读取），
供 APU 模块按"通道波形 + 音高"定位音色文件路径。

使用方法:
    python gen_tones.py [--low C2] [--high C7] [--format ogg] [--duration 0.5]
"""

import argparse
import array
import math
import os
import re
import shutil
import subprocess
import sys
import wave

# ---- 音频参数（生成参数，非命令行项保持内部常量，遵循最小可配置原则）----
SAMPLE_RATE = 44100          # 采样率（Hz）
AMPLITUDE = 0.5              # 峰值幅度（相对满量程，避免方波过响削波）
A4_FREQ = 440.0             # 参考音 A4 = 440Hz
ATTACK_SEC = 0.005          # 起始淡入时长（秒），消除循环起点爆音
RELEASE_SEC = 0.020         # 结尾淡出时长（秒），消除循环终点爆音
DECAY_DEPTH = 0.30          # 全程轻微衰减深度（末尾衰减到 1 - DECAY_DEPTH）

# 两种波形（pulse1 与 pulse2 共用 pulse 音色）
WAVEFORMS = ("pulse", "triangle")

# 12 平均律音名 → 半音偏移
NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

# 音色文件在 WoW 内的路径前缀（PlaySoundFile 可直接使用的相对路径）
WOW_PATH_PREFIX = "Interface\\AddOns\\WowFC\\Sound"


def note_name_to_midi(name):
    """将音名（如 C2 / C#3 / Bb4 / A4）解析为 MIDI 音高编号。

    约定 A4 = MIDI 69、C4 = MIDI 60，则 C2 = 36、C7 = 96。
    """
    m = re.match(r"^([A-Ga-g])([#b]?)(-?\d+)$", name.strip())
    if not m:
        raise ValueError(f"无法解析音名: {name!r}（示例: C2, C#3, Bb4）")
    letter = m.group(1).upper()
    accidental = m.group(2)
    octave = int(m.group(3))
    semitone = NOTE_OFFSETS[letter]
    if accidental == "#":
        semitone += 1
    elif accidental == "b":
        semitone -= 1
    return (octave + 1) * 12 + semitone


def midi_to_frequency(midi):
    """MIDI 音高 → 频率（Hz）：f = 440 * 2^((n - 69) / 12)。"""
    return A4_FREQ * (2.0 ** ((midi - 69) / 12.0))


def envelope(index, total):
    """计算第 index 个采样点的包络系数（0..1）。

    组合：短淡入（attack）+ 全程轻微线性衰减 + 短淡出（release）。
    """
    env = 1.0 - DECAY_DEPTH * (index / total)
    attack = int(SAMPLE_RATE * ATTACK_SEC)
    release = int(SAMPLE_RATE * RELEASE_SEC)
    if attack > 0 and index < attack:
        env *= index / attack
    if release > 0 and index > total - release:
        env *= (total - index) / release
    return env


def generate_samples(freq, kind, duration):
    """生成单个音色的 16 位有符号单声道 PCM 采样（array 'h'）。"""
    total = int(SAMPLE_RATE * duration)
    period = SAMPLE_RATE / freq
    peak = AMPLITUDE * 32767
    samples = array.array("h", bytes(2 * total))

    for i in range(total):
        phase = (i / period) % 1.0
        if kind == "pulse":
            # 50% 占空比方波
            value = 1.0 if phase < 0.5 else -1.0
        else:
            # 三角波：相位 0→-1，0.5→1，1→-1
            if phase < 0.5:
                value = -1.0 + 4.0 * phase
            else:
                value = 3.0 - 4.0 * phase
        samples[i] = int(value * peak * envelope(i, total))

    return samples


def write_wav(filepath, samples):
    """用标准库 wave 写出 16 位单声道 WAV 文件。"""
    with wave.open(filepath, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(samples.tobytes())


def find_encoder():
    """探测可用的 OGG 编码器，返回 'ffmpeg' / 'oggenc' / None。"""
    if shutil.which("ffmpeg"):
        return "ffmpeg"
    if shutil.which("oggenc"):
        return "oggenc"
    return None


def encode_to_ogg(encoder, wav_path, ogg_path):
    """调用编码器把 WAV 转为 OGG，成功返回 True。"""
    if encoder == "ffmpeg":
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
               "-c:a", "libvorbis", ogg_path]
    else:  # oggenc
        cmd = ["oggenc", "-Q", wav_path, "-o", ogg_path]
    try:
        subprocess.run(cmd, check=True)
        return True
    except (subprocess.CalledProcessError, OSError) as e:
        print(f"警告: 编码失败 {wav_path} -> {ogg_path}: {e}")
        return False


def generate_tone_file(sound_dir, kind, midi, duration, actual_format, encoder):
    """生成单个音色文件，返回 (文件名, 是否成功)。"""
    freq = midi_to_frequency(midi)
    samples = generate_samples(freq, kind, duration)

    base = f"{kind}_{midi:03d}"
    wav_path = os.path.join(sound_dir, base + ".wav")
    write_wav(wav_path, samples)

    if actual_format == "ogg":
        ogg_path = os.path.join(sound_dir, base + ".ogg")
        if encode_to_ogg(encoder, wav_path, ogg_path):
            os.remove(wav_path)
            return base + ".ogg", True
        # 编码失败：保留 wav 作为兜底
        return base + ".wav", False

    return base + ".wav", True


def generate_tone_map_lua(output_file, fmt, low, high, files_by_kind):
    """生成 Utils/APUToneMap_Generated.lua 映射表。"""
    lines = []
    lines.append("-- APUToneMap_Generated.lua")
    lines.append("-- 自动生成的 APU 音色映射表")
    lines.append("-- 请勿手动编辑（由 tools/gen_tones.py 生成）")
    lines.append("")
    lines.append("-- 运行时由 _G.WOWFC_APU_TONEMAP 读取：")
    lines.append("--   按通道波形（pulse / triangle）+ MIDI 音高定位音色文件路径")
    lines.append("_G.WOWFC_APU_TONEMAP = {")
    lines.append(f'    format = "{fmt}",')
    lines.append(f"    a4 = {A4_FREQ},")
    lines.append(f"    range = {{ low = {low}, high = {high} }},")

    for kind in WAVEFORMS:
        lines.append(f"    {kind} = {{")
        for midi in range(low, high + 1):
            filename = f"{kind}_{midi:03d}.{fmt}"
            # Lua 字符串内反斜杠需转义
            path = (WOW_PATH_PREFIX + "\\" + filename).replace("\\", "\\\\")
            lines.append(f'        [{midi}] = "{path}",')
        lines.append("    },")

    lines.append("}")
    lines.append("")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(
        description="生成 APU 方波/三角波音色文件与 Lua 映射表",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    # 默认音域 A0-G9（MIDI 21-127）:下界 A0(≈27.5Hz)贴近 NES 三角波物理下限;上界 G9
    # (≈12544Hz,MIDI 最高音)覆盖 NES 方波高音,远低于 44100 采样率的 Nyquist(22050Hz)。
    # 音域过窄会让超界音符被裁剪到边界、多个音高塌缩成同一个边界音,听感为"音调缺失/过渡
    # 突兀"(尤其方波小 timer 时频率可达数千~上万 Hz),故默认取此宽范围。
    parser.add_argument("--low", default="A0", help="最低音（音名，如 A0）")
    parser.add_argument("--high", default="G9", help="最高音（音名，如 G9）")
    parser.add_argument("--format", default="ogg", choices=["ogg", "wav"],
                        help="目标音频格式（无编码器时自动回退 wav）")
    parser.add_argument("--duration", type=float, default=0.5,
                        help="每个音色时长（秒）")
    args = parser.parse_args()

    # 路径推导（绝对路径），风格参考 convert_roms.py
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sound_dir = os.path.abspath(os.path.join(script_dir, "..", "Sound"))
    map_file = os.path.abspath(
        os.path.join(script_dir, "..", "Utils", "APUToneMap_Generated.lua"))

    low = note_name_to_midi(args.low)
    high = note_name_to_midi(args.high)
    if low > high:
        print(f"错误: --low ({args.low}={low}) 高于 --high ({args.high}={high})")
        sys.exit(1)

    # 决定实际输出格式（编码器探测 + 回退）
    requested_format = args.format
    encoder = None
    actual_format = requested_format
    if requested_format == "ogg":
        encoder = find_encoder()
        if not encoder:
            actual_format = "wav"

    semitone_count = high - low + 1
    expected_files = semitone_count * len(WAVEFORMS)

    print("=" * 60)
    print("WOWFC APU 音色生成工具")
    print("=" * 60)
    print(f"音域: {args.low}(MIDI {low}) .. {args.high}(MIDI {high}) "
          f"共 {semitone_count} 个半音")
    print(f"波形: {', '.join(WAVEFORMS)}")
    print(f"时长: {args.duration}s, 采样率: {SAMPLE_RATE}Hz")
    print(f"请求格式: {requested_format}")
    if requested_format == "ogg" and encoder:
        print(f"编码器: {encoder}")
    elif requested_format == "ogg":
        print("编码器: 未找到（ffmpeg / oggenc）-> 回退输出 .wav")
    print(f"实际格式: {actual_format}")
    print(f"Sound 目录: {sound_dir}")
    print(f"映射表: {map_file}")
    print("-" * 60)

    os.makedirs(sound_dir, exist_ok=True)
    os.makedirs(os.path.dirname(map_file), exist_ok=True)

    files_by_kind = {kind: [] for kind in WAVEFORMS}
    generated = 0
    fallback_during_loop = False

    for kind in WAVEFORMS:
        for midi in range(low, high + 1):
            filename, ok = generate_tone_file(
                sound_dir, kind, midi, args.duration, actual_format, encoder)
            files_by_kind[kind].append(filename)
            generated += 1
            if not ok:
                fallback_during_loop = True
            if generated % 20 == 0 or generated == expected_files:
                print(f"  已生成 {generated}/{expected_files} ...")

    # 若编码过程中出现失败，统一以 wav 记录实际格式
    if fallback_during_loop and actual_format == "ogg":
        actual_format = "wav"
        print("警告: 部分文件编码失败，映射表格式记录为 wav")

    print("-" * 60)
    print(f"共生成 {generated} 个音色文件（预期 {expected_files}）")

    # 生成 Lua 映射表
    generate_tone_map_lua(map_file, actual_format, low, high, files_by_kind)
    print(f"已生成映射表: {map_file}")

    # 打印需在 .toc 声明的清单
    print("-" * 60)
    print("请在 TOC 文件中确保以下文件已声明（在 Core\\FC.lua 之前）:")
    print("  Utils\\APUToneMap_Generated.lua")
    print("-" * 60)
    print(f"音色文件清单（共 {generated} 个，位于 Sound\\ 目录）:")
    for kind in WAVEFORMS:
        names = files_by_kind[kind]
        if names:
            print(f"  {kind}: {names[0]} .. {names[-1]}（{len(names)} 个）")
    print("-" * 60)
    print("生成完成!")


if __name__ == "__main__":
    main()
