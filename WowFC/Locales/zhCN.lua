-- zhCN.lua
-- Simplified Chinese localization for WowFC.
-- Overrides keys in the default locale table when the client is zhCN.

local _, addon = ...
local L = _G.WowFC_Locale or {}
_G.WowFC_Locale = L

if GetLocale() ~= "zhCN" then return end

-- Addon metadata / console hints
L["ADDON_TITLE"]           = "魔兽世界里的 FC 模拟器"
L["TOGGLE_HINT"]           = "输入 |cffffff00/fc|r|cff888888 打开/关闭。键盘按 |r|cffffff00ESC|r|cff888888 退出操控模式。|r"
L["UNKNOWN"]               = "未知"
L["ON"]                    = "开"
L["OFF"]                   = "关"
L["ENABLED"]               = "启用"
L["DISABLED"]              = "禁用"
L["FASTER"]                = "(更快)"
L["NOT_FASTER"]            = "(未更快)"

-- Console / chat messages
L["MSG_NO_ROM"]            = "未加载ROM"
L["MSG_PLEASE_LOAD_ROM"]   = "请先加载ROM"
L["MSG_PROFILE_RESET"]     = "profile 已清零"
L["MSG_BENCH_NOT_LOADED"]  = "Bench 模块未加载"
L["MSG_BENCH_NEED_ROM"]    = "请先加载并运行 ROM(基准需要真实运行画面)"
L["MSG_NO_ROMS_FOUND"]     = "没有找到任何 ROM。请把 .nes 文件放进 |cffffff00WowFC/ROMs|r 目录,跑一下转换工具,然后 /reload 即可看到游戏列表。"
L["MSG_CANNOT_READ"]       = "无法读取 "
L["MSG_CHECK_ROMS_DIR"]    = ",请确认文件存在于 ROMs 目录"
L["MSG_HAVE_FUN"]          = "祝玩得开心!"
L["MSG_LOAD_FAILED"]       = "ROM 加载失败: "
L["MSG_RUNTIME_ERROR"]     = "运行错误: "
L["MSG_RENDERER_NOT_FOUND"]= "未找到渲染器模块，请检查 UltraRenderer.lua 是否已加载"
L["MSG_NO_PALETTE_DATA"]   = "PaletteRenderer 缺少调色板数据(PaletteData_Generated.lua 未加载),请先运行 Tools/gen_palette_tga.py 并在 TOC 中声明。"

-- Frame-skip messages
L["MSG_SKIP_AUTO"]         = "帧跳过 = auto (动态调节)"
L["MSG_SKIP_1"]            = "帧跳过 = 1 (每帧渲染,目标 60fps)"
L["MSG_SKIP_N"]            = "帧跳过 skipN=%d (UI 约 %.0f fps,关闭 auto)"
L["MSG_SKIP_CURRENT"]      = "当前 skipN=%d (%s)。用法 /fc skip <1-10|auto>"

-- Scanline messages
L["MSG_SCANLINE_ON"]       = "逐扫描线渲染已|cff00ff00开启|r(支持 mid-frame 分屏/sprite0-hit,约 2x 开销)"
L["MSG_SCANLINE_SMB1"]     = "当前为 SMB1 专用路径,逐扫描线开关无效"
L["MSG_SCANLINE_OFF"]      = "逐扫描线渲染已|cffff0000关闭|r(vblank 整帧快照,性能最优)"
L["MSG_SCANLINE_CURRENT"]  = "逐扫描线 = %s。用法 /fc scanline <on|off>"

-- Sound messages
L["MSG_SOUND_ON"]          = "声音已|cff00ff00开启|r"
L["MSG_SOUND_OFF"]         = "声音已|cffff0000关闭|r"
L["MSG_SOUND_CURRENT"]     = "声音 = %s。用法 /fc sound <on|off>"

-- Boost messages
L["MSG_BOOST_OFF"]         = "性能增强已|cffff0000关闭|r(不再解除 WoW 帧率上限)"
L["MSG_BOOST_ON"]          = "性能增强已|cff00ff00开启|r(模拟器运行时解除 WoW 帧率上限)"

-- Unsupported mapper
L["MSG_UNSUPPORTED_MAPPER"]= "不支持的 mapper %d (%s),退化到 NROM,游戏可能无法正常运行。"

-- Main window titles / status
L["TITLE_SUFFIX"]          = "FC 模拟器"
L["TITLE_SELECT_GAME"]     = "选择游戏"
L["TITLE_KEYBINDING"]      = "WowFC 按键设置"
L["TITLE_DEBUG_INFO"]      = "=== WowFC 调试信息 ==="
L["TITLE_HELP"]            = "=== WowFC v%s 帮助 ==="
L["TITLE_BENCH"]           = "===== WowFC 渲染器 A/B 基准 ====="

L["STATUS_NO_ROM"]         = "未加载 ROM - 点击'加载 ROM'开始"
L["STATUS_RENDERER_FAIL"]  = "渲染器加载失败"
L["STATUS_CONTROL_ON"]     = "操控模式 (按 ESC 退出)"
L["STATUS_CONTROL_OFF"]    = "WoW 控制模式 (点窗口或按钮启用操控)"
L["STATUS_LOADING"]        = "加载中: "
L["STATUS_ROM_READ_FAIL"]  = "ROM 文件读取失败: "
L["STATUS_LOADED"]         = "已加载: "
L["STATUS_LOAD_FAILED"]    = "ROM 加载失败"
L["STATUS_RESET"]          = "已重置"

-- Buttons
L["BTN_LOAD_ROM"]          = "加载ROM"
L["BTN_START"]             = "开始"
L["BTN_PAUSE"]             = "暂停"
L["BTN_RESUME"]            = "继续"
L["BTN_RESET"]             = "重置"
L["BTN_DEBUG"]             = "调试"
L["BTN_KEYS"]              = "按键"
L["BTN_CLOSE"]             = "关闭"
L["BTN_ADD"]               = "+ 添加"
L["BTN_CLEAR"]             = "清空"
L["BTN_RESET_DEFAULT"]     = "恢复默认"
L["BTN_CONTROL_ON"]        = "操控:开"
L["BTN_CONTROL_OFF"]       = "操控:关"
L["BTN_SOUND_ON"]          = "声音:开"
L["BTN_SOUND_OFF"]         = "声音:关"

-- ROM selector
L["DESC_SELECT_GAME"]      = "点击游戏名称加载："

-- Keybinding UI
L["HINT_KEYBINDING"]       = "点 [+] 添加按键(键盘或手柄),ESC 退出"
L["LABEL_TURBO"]           = "连发(按住 30Hz 自动按):"
L["TURBO_SLOT"]            = "连发 "
L["UNBOUND"]               = "(未绑定)"
L["MSG_RECORD_KEY"]        = "|cffff8800按下要绑定到 [%s] 的键(ESC 取消)|r"
L["MSG_KEY_ADDED"]         = "|cff00ff00已添加|r"
L["MSG_CONTINUE_ADD"]      = " — 点 [+] 继续添加,或关闭窗口"

-- NES button names
L["BUTTON_A"]              = "A"
L["BUTTON_B"]              = "B"
L["BUTTON_SELECT"]         = "选择"
L["BUTTON_START"]          = "开始"
L["BUTTON_UP"]             = "↑ 上"
L["BUTTON_DOWN"]           = "↓ 下"
L["BUTTON_LEFT"]           = "← 左"
L["BUTTON_RIGHT"]          = "→ 右"

-- Renderer mode names
L["MODE_NATIVE"]           = "原生 256x240"
L["MODE_PALETTE"]          = "调色板 256x240"

-- Debug labels
L["DEBUG_FRAME_COUNT"]     = "帧计数: %d  DirtyTiles: %d"
L["DEBUG_PPU_SCANLINE"]    = "PPU扫描线: %d"
L["DEBUG_BG_DISPLAY"]      = "背景显示: %s"
L["DEBUG_SP_DISPLAY"]      = "精灵显示: %s"
L["DEBUG_NMI"]             = "NMI: %s"

-- Benchmark messages
L["MSG_BENCH_RECORDED"]    = "已录制 %d 帧,开始离屏对比(分帧执行,稍候)..."
L["MSG_BENCH_RECORDING"]   = "正在录制中,请稍候。"
L["MSG_BENCH_START"]       = "录制 %d 帧真实画面中...(确保游戏正在运行/有画面变化)"
L["MSG_BENCH_NO_FRAMES"]   = "没有录到帧,先 /fc bench 并让游戏跑起来。"
L["MSG_BENCH_NO_ULTRA"]    = "UltraRenderer 未加载"
L["MSG_BENCH_NO_PALETTE"]  = "PaletteRenderer 未加载"
L["MSG_BENCH_ERROR"]       = "运行出错: "

L["BENCH_STATS"]           = "录制帧: %d  回放: %d 遍  模式分布: skip=%d partial=%d full=%d"
L["BENCH_PIXELS"]          = "steady 改色/帧: Ultra=%.0f  Palette=%.0f(应一致,验证视觉等价)"
L["BENCH_STEADY"]          = "— steady(脏检查生效,日常表现)—"
L["BENCH_ULTRA_STEADY"]    = "  UltraRenderer  (SetColorTexture): %.4f ms/帧"
L["BENCH_PALETTE_STEADY"]  = "  PaletteRenderer(SetTexCoord)    : %.4f ms/帧"
L["BENCH_RATIO"]           = "  Palette 相对 Ultra: %s  %s"
L["BENCH_FULL"]            = "— full(全屏 61440 像素重绘,上限)—"
L["BENCH_ULTRA_FULL"]      = "  UltraRenderer  : %.4f ms/帧"
L["BENCH_PALETTE_FULL"]    = "  PaletteRenderer: %.4f ms/帧"
L["BENCH_TIP"]             = "提示:steady 是日常体感;若两者 steady 都很小,说明 Present 不是瓶颈,优化重心应在 PPU/CPU。"

-- Help text
L["HELP_TOGGLE"]           = "|cffffd700【打开/关闭】|r |cffffff00/fc|r 切换主窗口"
L["HELP_CONTROL"]          = "|cffffd700【操控模式】|r 点窗口下方 |cffffff00操控|r 按钮切换。开启时 FC 独占键盘,WoW 角色不响应。"
L["HELP_CONTROL_ESC"]      = "                |cffffff00ESC|r 一键退出操控模式。加载 ROM 时自动开启。"
L["HELP_KEYBINDING"]       = "|cffffd700【自定义按键】|r 点 |cffffff00按键|r 按钮。支持键盘 / 手柄 / 连发(30Hz 自动按 A/B)。"
L["HELP_KEYBINDING_PAD"]   = "                启用手柄前先在 |cffffff00WoW 设置 → 操作 → 启用游戏手柄|r 中开启。"
L["HELP_DEFAULT_KEYS"]     = "|cffffd700【默认按键】|r"
L["HELP_DEFAULT_KEYS_DETAIL"] = "  方向键 = 移动   Z = A   X = B   Enter/Space = Start   Tab = Select"
L["HELP_COMMANDS"]         = "|cffffd700【命令】|r"
L["HELP_CMD_SKIP"]         = "  |cffffff00/fc skip <N>|r  帧跳过(1=关,2-10=每 N 帧渲染一帧;或 |cffffff00auto|r 自动)"
L["HELP_CMD_PROF"]         = "  |cffffff00/fc prof|r       性能数据  |cffffff00/fc profreset|r 清零"
L["HELP_CMD_BENCH"]        = "  |cffffff00/fc bench [N]|r  渲染器 A/B 基准(对比 SetColorTexture 与 SetTexCoord 的 Present 耗时)"
L["HELP_CMD_BOOST"]        = "  |cffffff00/fc boost|r      开关性能增强(运行时解除 WoW 帧率上限)"
L["HELP_CMD_SOUND"]        = "  |cffffff00/fc sound <on|off>|r 开关声音(预录制音色文件对位播放)"
L["HELP_CMD_DEBUG"]        = "  |cffffff00/fc debug|r      运行时状态"
