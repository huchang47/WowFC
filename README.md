# WowFC - World of Warcraft FC/NES Emulator

A World of Warcraft addon that runs FC/NES games inside the game.

[English](README.md) | [简体中文](README.zh-CN.md)

![Interface](https://img.shields.io/badge/WoW-12.0+-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

![Screenshot](screenshot.png)

## Features

- Run FC/NES games inside World of Warcraft
- Support for multiple mappers (Mapper 0, 1, 2, 3, 4)
- Customizable key bindings
- Frame skip optimization for different performance environments
- Turbo (rapid fire) support
- Debug mode
- Optional scanline-accurate rendering
- Sound on/off toggle
- Performance boost mode (uncaps WoW frame limit while running)

## Installation

### Method 1: GitHub Release (Recommended)

1. Go to [Releases](https://github.com/huchang47/WowFC/releases)
2. Download the latest `WowFC-vX.X.X.zip`
3. Extract and copy the `WowFC` folder to your WoW addon directory:
   - Retail: `World of Warcraft\_retail_\Interface\AddOns\`
   - Classic: `World of Warcraft\_classic_\Interface\AddOns\`
4. Restart the game or click the "AddOns" button at the character selection screen

### Method 2: CurseForge

Install via [CurseForge](https://www.curseforge.com/wow/addons/wowfc) and let the client manage updates.

### Method 3: Git Clone

```bash
cd "World of Warcraft\_retail_\Interface\AddOns"
git clone https://github.com/huchang47/WowFC.git WowFC
```

## Usage

### Basic Controls

- Type `/fc` or `/wowfc` to open/close the emulator window
- Press `ESC` to exit control mode
- Window is draggable to adjust position

### Loading Games

1. Place your `.nes` format ROM files in the `WowFC/ROMs/` directory
2. Run `WowFC/WowFC_ROM_Converter.exe` to convert ROMs to Lua data format
3. Run `/reload` in-game to load the new ROMs
4. Click the "Load ROM" button in the addon interface to select and load a game

> **Note**: ROM files may have copyright issues. Please do not commit ROM files to the repository.

### Key Binding

Click the "Key Binding" button in the interface to customize keyboard mappings for FC controller buttons.

### Commands

| Command | Description |
|---------|-------------|
| `/fc` | Open/close emulator window |
| `/fc skip <1-10\|auto>` | Set frame skip (for performance tuning) |
| `/fc scanline <on\|off>` | Toggle scanline-accurate rendering |
| `/fc sound <on\|off>` | Toggle sound output |
| `/fc boost` | Toggle performance boost mode |
| `/fc prof` | Show performance profile data |
| `/fc profreset` | Reset performance profile data |
| `/fc debug` | Show debug information |
| `/fc bench [frames] [rounds]` | Run renderer benchmark (default 60 frames × 3 rounds) |
| `/fc help` | Show help message |

## Project Structure

```
WowFC/
├── Core/           # Emulator core
│   ├── CPU.lua     # 6502 CPU emulation
│   ├── PPU.lua     # Picture Processing Unit
│   ├── ROM.lua     # ROM loader
│   ├── FC.lua      # Main emulator logic
│   └── Mappers/    # Various mapper implementations
├── Utils/          # Utility modules
├── Sound/          # Sound sample assets
├── ROMs/           # ROM directory (README only in repo)
├── UltraRenderer.lua  # Renderer
├── Keybinding.lua  # Key binding
├── WowFC.lua       # Addon main entry
└── WowFC.toc       # Addon manifest
```

## Technical Notes

This project is based on:

- World of Warcraft Lua API for UI rendering
- Pure Lua implementation of 6502 CPU and PPU emulation

## Important Notes

1. **ROM Copyright**: This project does not include any game ROMs. Users must prepare their own legal ROM files.
2. **Performance Requirements**: The emulator requires computational resources. Recommended for use on better-configured computers.
3. **Compatibility**: Currently supports World of Warcraft 12.0+.

## Known Limitations

- **Performance**: Frame skip may be required on lower-end systems to maintain playable speed

## License

This project is open-sourced under the [MIT License](LICENSE).

## Acknowledgments

- Thanks to the WoW addon development community

## Authors

[黑科研]胡涂 / [黑科研]童

---

**Disclaimer**: This addon is for educational and communication purposes only. It is not affiliated with Blizzard Entertainment.
