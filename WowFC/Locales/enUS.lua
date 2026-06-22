-- enUS.lua
-- Default English localization for WowFC.
-- Loaded first; other locale files override keys for their language.

local _, addon = ...
local L = {}
_G.WowFC_Locale = L

-- Addon metadata / console hints
L["ADDON_TITLE"]           = "FC Emulator in World of Warcraft"
L["TOGGLE_HINT"]           = "Type |cffffff00/fc|r to open/close. Press |cffffff00ESC|r to exit control mode."
L["UNKNOWN"]               = "Unknown"
L["ON"]                    = "On"
L["OFF"]                   = "Off"
L["ENABLED"]               = "Enabled"
L["DISABLED"]              = "Disabled"
L["FASTER"]                = "(faster)"
L["NOT_FASTER"]            = "(not faster)"

-- Console / chat messages
L["MSG_NO_ROM"]            = "No ROM loaded"
L["MSG_PLEASE_LOAD_ROM"]   = "Please load a ROM first"
L["MSG_PROFILE_RESET"]     = "Profile reset"
L["MSG_BENCH_NOT_LOADED"]  = "Bench module not loaded"
L["MSG_BENCH_NEED_ROM"]    = "Please load and run a ROM first (benchmark needs real frames)"
L["MSG_NO_ROMS_FOUND"]     = "No ROMs found. Put .nes files into |cffffff00WowFC/ROMs|r, run the converter, then /reload."
L["MSG_CANNOT_READ"]       = "Cannot read "
L["MSG_CHECK_ROMS_DIR"]    = ", please make sure the file exists in the ROMs directory"
L["MSG_HAVE_FUN"]          = "Have fun!"
L["MSG_LOAD_FAILED"]       = "ROM load failed: "
L["MSG_RUNTIME_ERROR"]     = "Runtime error: "
L["MSG_RENDERER_NOT_FOUND"]= "Renderer module not found; please check that UltraRenderer.lua is loaded"
L["MSG_NO_PALETTE_DATA"]   = "PaletteRenderer is missing palette data (PaletteData_Generated.lua not loaded). Please run Tools/gen_palette_tga.py and declare it in the TOC."

-- Frame-skip messages
L["MSG_SKIP_AUTO"]         = "Frame skip = auto (dynamic)"
L["MSG_SKIP_1"]            = "Frame skip = 1 (render every frame, target 60fps)"
L["MSG_SKIP_N"]            = "Frame skip skipN=%d (UI approx %.0f fps, auto off)"
L["MSG_SKIP_CURRENT"]      = "Current skipN=%d (%s). Usage: /fc skip <1-10|auto>"

-- Scanline messages
L["MSG_SCANLINE_ON"]       = "Scanline rendering |cff00ff00enabled|r (supports mid-frame split / sprite0-hit, ~2x cost)"
L["MSG_SCANLINE_SMB1"]     = "Current path is SMB1-only; scanline toggle has no effect"
L["MSG_SCANLINE_OFF"]      = "Scanline rendering |cffff0000disabled|r (vblank full-frame snapshot, best performance)"
L["MSG_SCANLINE_CURRENT"]  = "Scanline = %s. Usage: /fc scanline <on|off>"

-- Sound messages
L["MSG_SOUND_ON"]          = "Sound |cff00ff00enabled|r"
L["MSG_SOUND_OFF"]         = "Sound |cffff0000disabled|r"
L["MSG_SOUND_CURRENT"]     = "Sound = %s. Usage: /fc sound <on|off>"

-- Boost messages
L["MSG_BOOST_OFF"]         = "Performance boost |cffff0000disabled|r (will no longer lift WoW fps cap)"
L["MSG_BOOST_ON"]          = "Performance boost |cff00ff00enabled|r (lifts WoW fps cap while emulator is running)"

-- Unsupported mapper
L["MSG_UNSUPPORTED_MAPPER"]= "Unsupported mapper %d (%s), falling back to NROM; the game may not work correctly."

-- Main window titles / status
L["TITLE_SUFFIX"]          = "FC Emulator"
L["TITLE_SELECT_GAME"]     = "Select Game"
L["TITLE_KEYBINDING"]      = "WowFC Key Bindings"
L["TITLE_DEBUG_INFO"]      = "=== WowFC Debug Info ==="
L["TITLE_HELP"]            = "=== WowFC v%s Help ==="
L["TITLE_BENCH"]           = "===== WowFC Renderer A/B Benchmark ====="

L["STATUS_NO_ROM"]         = "No ROM loaded - click 'Load ROM' to start"
L["STATUS_RENDERER_FAIL"]  = "Renderer failed to load"
L["STATUS_CONTROL_ON"]     = "Control mode (press ESC to exit)"
L["STATUS_CONTROL_OFF"]    = "WoW control mode (click window or button to enable control)"
L["STATUS_LOADING"]        = "Loading: "
L["STATUS_ROM_READ_FAIL"]  = "ROM read failed: "
L["STATUS_LOADED"]         = "Loaded: "
L["STATUS_LOAD_FAILED"]    = "ROM load failed"
L["STATUS_RESET"]          = "Reset"

-- Buttons
L["BTN_LOAD_ROM"]          = "Load ROM"
L["BTN_START"]             = "Start"
L["BTN_PAUSE"]             = "Pause"
L["BTN_RESUME"]            = "Resume"
L["BTN_RESET"]             = "Reset"
L["BTN_DEBUG"]             = "Debug"
L["BTN_KEYS"]              = "Keys"
L["BTN_CLOSE"]             = "Close"
L["BTN_ADD"]               = "+ Add"
L["BTN_CLEAR"]             = "Clear"
L["BTN_RESET_DEFAULT"]     = "Reset Default"
L["BTN_CONTROL_ON"]        = "Control: On"
L["BTN_CONTROL_OFF"]       = "Control: Off"
L["BTN_SOUND_ON"]          = "Sound: On"
L["BTN_SOUND_OFF"]         = "Sound: Off"

-- ROM selector
L["DESC_SELECT_GAME"]      = "Click a game title to load:"

-- Keybinding UI
L["HINT_KEYBINDING"]       = "Click [+] to add a key (keyboard or gamepad), ESC to exit"
L["LABEL_TURBO"]           = "Turbo (hold for 30Hz auto-fire):"
L["TURBO_SLOT"]            = "Turbo "
L["UNBOUND"]               = "(unbound)"
L["MSG_RECORD_KEY"]        = "|cffff8800Press the key to bind to [%s] (ESC to cancel)|r"
L["MSG_KEY_ADDED"]         = "|cff00ff00Added|r"
L["MSG_CONTINUE_ADD"]      = " — click [+] to add more, or close the window"

-- NES button names
L["BUTTON_A"]              = "A"
L["BUTTON_B"]              = "B"
L["BUTTON_SELECT"]         = "Select"
L["BUTTON_START"]          = "Start"
L["BUTTON_UP"]             = "Up"
L["BUTTON_DOWN"]           = "Down"
L["BUTTON_LEFT"]           = "Left"
L["BUTTON_RIGHT"]          = "Right"

-- Renderer mode names
L["MODE_NATIVE"]           = "Native 256x240"
L["MODE_PALETTE"]          = "Palette 256x240"

-- Debug labels
L["DEBUG_FRAME_COUNT"]     = "Frames: %d  DirtyTiles: %d"
L["DEBUG_PPU_SCANLINE"]    = "PPU Scanline: %d"
L["DEBUG_BG_DISPLAY"]      = "BG Display: %s"
L["DEBUG_SP_DISPLAY"]      = "Sprite Display: %s"
L["DEBUG_NMI"]             = "NMI: %s"

-- Benchmark messages
L["MSG_BENCH_RECORDED"]    = "Recorded %d frames, starting off-screen comparison (split-frame execution, please wait)..."
L["MSG_BENCH_RECORDING"]   = "Recording, please wait."
L["MSG_BENCH_START"]       = "Recording %d real frames... (make sure the game is running /画面 has changes)"
L["MSG_BENCH_NO_FRAMES"]   = "No frames recorded. Run /fc bench while the game is running."
L["MSG_BENCH_NO_ULTRA"]    = "UltraRenderer not loaded"
L["MSG_BENCH_NO_PALETTE"]  = "PaletteRenderer not loaded"
L["MSG_BENCH_ERROR"]       = "Runtime error: "

L["BENCH_STATS"]           = "Frames: %d  Repeats: %d  Mode distribution: skip=%d partial=%d full=%d"
L["BENCH_PIXELS"]          = "steady changed pixels/frame: Ultra=%.0f  Palette=%.0f (should match, verifies visual equivalence)"
L["BENCH_STEADY"]          = "— steady (dirty-check active, daily feel) —"
L["BENCH_ULTRA_STEADY"]    = "  UltraRenderer  (SetColorTexture): %.4f ms/frame"
L["BENCH_PALETTE_STEADY"]  = "  PaletteRenderer(SetTexCoord)    : %.4f ms/frame"
L["BENCH_RATIO"]           = "  Palette vs Ultra: %s  %s"
L["BENCH_FULL"]            = "— full (full-screen 61440 pixels redraw, worst-case) —"
L["BENCH_ULTRA_FULL"]      = "  UltraRenderer  : %.4f ms/frame"
L["BENCH_PALETTE_FULL"]    = "  PaletteRenderer: %.4f ms/frame"
L["BENCH_TIP"]             = "Tip: steady is the daily metric; if both steady values are small, Present is not the bottleneck — focus on PPU/CPU."

-- Help text
L["HELP_TOGGLE"]           = "|cffffd700[Open/Close]|r |cffffff00/fc|r toggles the main window"
L["HELP_CONTROL"]          = "|cffffd700[Control Mode]|r Click the |cffffff00Control|r button below the window. When on, FC takes keyboard input and WoW character does not respond."
L["HELP_CONTROL_ESC"]      = "                |cffffff00ESC|r exits control mode instantly. Auto-enabled when loading a ROM."
L["HELP_KEYBINDING"]       = "|cffffd700[Custom Keys]|r Click |cffffff00Keys|r. Supports keyboard / gamepad / turbo (30Hz auto A/B)."
L["HELP_KEYBINDING_PAD"]   = "                Enable gamepad first in |cffffff00WoW Settings → Controls → Enable Gamepad|r."
L["HELP_DEFAULT_KEYS"]     = "|cffffd700[Default Keys]|r"
L["HELP_DEFAULT_KEYS_DETAIL"] = "  Arrows = move   Z = A   X = B   Enter/Space = Start   Tab = Select"
L["HELP_COMMANDS"]         = "|cffffd700[Commands]|r"
L["HELP_CMD_SKIP"]         = "  |cffffff00/fc skip <N>|r  Frame skip (1=off, 2-10=render 1/N frames; or |cffffff00auto|r)"
L["HELP_CMD_PROF"]         = "  |cffffff00/fc prof|r       Performance data  |cffffff00/fc profreset|r reset"
L["HELP_CMD_BENCH"]        = "  |cffffff00/fc bench [N]|r  Renderer A/B benchmark (compare SetColorTexture vs SetTexCoord Present cost)"
L["HELP_CMD_BOOST"]        = "  |cffffff00/fc boost|r      Toggle performance boost (lifts WoW fps cap while running)"
L["HELP_CMD_SOUND"]        = "  |cffffff00/fc sound <on|off>|r Toggle sound (pre-recorded tone playback)"
L["HELP_CMD_DEBUG"]        = "  |cffffff00/fc debug|r      Runtime status"
