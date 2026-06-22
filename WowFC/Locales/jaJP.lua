-- jaJP.lua
-- Japanese localization for WowFC.
-- Overrides keys in the default locale table when the client is jaJP.

local _, addon = ...
local L = _G.WowFC_Locale or {}
_G.WowFC_Locale = L

if GetLocale() ~= "jaJP" then return end

-- Addon metadata / console hints
L["ADDON_TITLE"]           = "World of Warcraft内のFCエミュレーター"
L["TOGGLE_HINT"]           = "|cffffff00/fc|r で開く/閉じる。|cffffff00ESC|r で操作モードを終了します。"
L["UNKNOWN"]               = "不明"
L["ON"]                    = "オン"
L["OFF"]                   = "オフ"
L["ENABLED"]               = "有効"
L["DISABLED"]              = "無効"
L["FASTER"]                = "(高速)"
L["NOT_FASTER"]            = "(高速ではありません)"

-- Console / chat messages
L["MSG_NO_ROM"]            = "ROMが読み込まれていません"
L["MSG_PLEASE_LOAD_ROM"]   = "先にROMを読み込んでください"
L["MSG_PROFILE_RESET"]     = "profileをリセットしました"
L["MSG_BENCH_NOT_LOADED"]  = "Benchモジュールが読み込まれていません"
L["MSG_BENCH_NEED_ROM"]    = "先にROMを読み込んで実行してください(ベンチマークには実際のフレームが必要です)"
L["MSG_NO_ROMS_FOUND"]     = "ROMが見つかりません。.nesファイルを |cffffff00WowFC/ROMs|r に入れ、変換ツールを実行してから /reload してください。"
L["MSG_CANNOT_READ"]       = "読み込めません: "
L["MSG_CHECK_ROMS_DIR"]    = "。ファイルがROMsディレクトリに存在するか確認してください"
L["MSG_HAVE_FUN"]          = "楽しんでください!"
L["MSG_LOAD_FAILED"]       = "ROMの読み込みに失敗しました: "
L["MSG_RUNTIME_ERROR"]     = "実行時エラー: "
L["MSG_RENDERER_NOT_FOUND"]= "レンダラーモジュールが見つかりません。UltraRenderer.luaが読み込まれているか確認してください"
L["MSG_NO_PALETTE_DATA"]   = "PaletteRendererにパレットデータがありません(PaletteData_Generated.luaが未読み込み)。Tools/gen_palette_tga.pyを実行し、TOCで宣言してください。"

-- Frame-skip messages
L["MSG_SKIP_AUTO"]         = "フレームスキップ = auto (動的調整)"
L["MSG_SKIP_1"]            = "フレームスキップ = 1 (毎フレーム描画、目標60fps)"
L["MSG_SKIP_N"]            = "フレームスキップ skipN=%d (UI 約 %.0f fps、auto無効)"
L["MSG_SKIP_CURRENT"]      = "現在のskipN=%d (%s)。使用法: /fc skip <1-10|auto>"

-- Scanline messages
L["MSG_SCANLINE_ON"]       = "スキャンライン描画を|cff00ff00有効|rにしました(mid-frame分割/sprite0-hit対応、約2倍の負荷)"
L["MSG_SCANLINE_SMB1"]     = "現在はSMB1専用パスです。スキャンライン切替は無効です"
L["MSG_SCANLINE_OFF"]      = "スキャンライン描画を|cffff0000無効|rにしました(vblank全フレームスナップショット、最高性能)"
L["MSG_SCANLINE_CURRENT"]  = "スキャンライン = %s。使用法: /fc scanline <on|off>"

-- Sound messages
L["MSG_SOUND_ON"]          = "サウンドを|cff00ff00有効|rにしました"
L["MSG_SOUND_OFF"]         = "サウンドを|cffff0000無効|rにしました"
L["MSG_SOUND_CURRENT"]     = "サウンド = %s。使用法: /fc sound <on|off>"

-- Boost messages
L["MSG_BOOST_OFF"]         = "パフォーマンス強化を|cffff0000無効|rにしました(WoWのFPS上限を解除しません)"
L["MSG_BOOST_ON"]          = "パフォーマンス強化を|cff00ff00有効|rにしました(エミュレーター実行中はWoWのFPS上限を解除します)"

-- Unsupported mapper
L["MSG_UNSUPPORTED_MAPPER"]= "未対応のmapper %d (%s)です。NROMへフォールバックします。ゲームが正常に動作しない可能性があります。"

-- Main window titles / status
L["TITLE_SUFFIX"]          = "FCエミュレーター"
L["TITLE_SELECT_GAME"]     = "ゲーム選択"
L["TITLE_KEYBINDING"]      = "WowFC キー設定"
L["TITLE_DEBUG_INFO"]      = "=== WowFC デバッグ情報 ==="
L["TITLE_HELP"]            = "=== WowFC v%s ヘルプ ==="
L["TITLE_BENCH"]           = "===== WowFC レンダラー A/B ベンチマーク ====="

L["STATUS_NO_ROM"]         = "ROM未読み込み - 'ROM読み込み'をクリックして開始"
L["STATUS_RENDERER_FAIL"]  = "レンダラーの読み込みに失敗しました"
L["STATUS_CONTROL_ON"]     = "操作モード (ESCで終了)"
L["STATUS_CONTROL_OFF"]    = "WoW操作モード (ウィンドウまたはボタンをクリックして操作を有効化)"
L["STATUS_LOADING"]        = "読み込み中: "
L["STATUS_ROM_READ_FAIL"]  = "ROMファイルの読み込みに失敗: "
L["STATUS_LOADED"]         = "読み込み完了: "
L["STATUS_LOAD_FAILED"]    = "ROMの読み込みに失敗しました"
L["STATUS_RESET"]          = "リセットしました"

-- Buttons
L["BTN_LOAD_ROM"]          = "ROM読み込み"
L["BTN_START"]             = "開始"
L["BTN_PAUSE"]             = "一時停止"
L["BTN_RESUME"]            = "再開"
L["BTN_RESET"]             = "リセット"
L["BTN_DEBUG"]             = "デバッグ"
L["BTN_KEYS"]              = "キー"
L["BTN_CLOSE"]             = "閉じる"
L["BTN_ADD"]               = "+ 追加"
L["BTN_CLEAR"]             = "クリア"
L["BTN_RESET_DEFAULT"]     = "初期設定に戻す"
L["BTN_CONTROL_ON"]        = "操作:オン"
L["BTN_CONTROL_OFF"]       = "操作:オフ"
L["BTN_SOUND_ON"]          = "音:オン"
L["BTN_SOUND_OFF"]         = "音:オフ"

-- ROM selector
L["DESC_SELECT_GAME"]      = "ゲーム名をクリックして読み込み:"

-- Keybinding UI
L["HINT_KEYBINDING"]       = "[+]でキーを追加(キーボードまたはゲームパッド)、ESCで終了"
L["LABEL_TURBO"]           = "連射(押し続けると30Hzで自動連打):"
L["TURBO_SLOT"]            = "連射 "
L["UNBOUND"]               = "(未設定)"
L["MSG_RECORD_KEY"]        = "|cffff8800[%s] に割り当てるキーを押してください(ESCでキャンセル)|r"
L["MSG_KEY_ADDED"]         = "|cff00ff00追加しました|r"
L["MSG_CONTINUE_ADD"]      = " — [+]で続けて追加、またはウィンドウを閉じてください"

-- NES button names
L["BUTTON_A"]              = "A"
L["BUTTON_B"]              = "B"
L["BUTTON_SELECT"]         = "セレクト"
L["BUTTON_START"]          = "スタート"
L["BUTTON_UP"]             = "↑ 上"
L["BUTTON_DOWN"]           = "↓ 下"
L["BUTTON_LEFT"]           = "← 左"
L["BUTTON_RIGHT"]          = "→ 右"

-- Renderer mode names
L["MODE_NATIVE"]           = "ネイティブ 256x240"
L["MODE_PALETTE"]          = "パレット 256x240"

-- Debug labels
L["DEBUG_FRAME_COUNT"]     = "フレーム数: %d  DirtyTiles: %d"
L["DEBUG_PPU_SCANLINE"]    = "PPUスキャンライン: %d"
L["DEBUG_BG_DISPLAY"]      = "背景表示: %s"
L["DEBUG_SP_DISPLAY"]      = "スプライト表示: %s"
L["DEBUG_NMI"]             = "NMI: %s"

-- Benchmark messages
L["MSG_BENCH_RECORDED"]    = "%dフレームを記録しました。オフスクリーン比較を開始します(分割実行、少々お待ちください)..."
L["MSG_BENCH_RECORDING"]   = "記録中です。少々お待ちください。"
L["MSG_BENCH_START"]       = "%dフレームの実画面を記録中...(ゲームが実行中で画面変化があることを確認してください)"
L["MSG_BENCH_NO_FRAMES"]   = "フレームが記録されていません。ゲーム実行中に /fc bench を実行してください。"
L["MSG_BENCH_NO_ULTRA"]    = "UltraRendererが読み込まれていません"
L["MSG_BENCH_NO_PALETTE"]  = "PaletteRendererが読み込まれていません"
L["MSG_BENCH_ERROR"]       = "実行時エラー: "

L["BENCH_STATS"]           = "記録フレーム: %d  リピート: %d回  モード分布: skip=%d partial=%d full=%d"
L["BENCH_PIXELS"]          = "steady 変更ピクセル/フレーム: Ultra=%.0f  Palette=%.0f (一致すべき、視覚的等価性の検証)"
L["BENCH_STEADY"]          = "— steady (dirtyチェック有効、通常時の体感) —"
L["BENCH_ULTRA_STEADY"]    = "  UltraRenderer  (SetColorTexture): %.4f ms/フレーム"
L["BENCH_PALETTE_STEADY"]  = "  PaletteRenderer(SetTexCoord)    : %.4f ms/フレーム"
L["BENCH_RATIO"]           = "  Palette 対 Ultra: %s  %s"
L["BENCH_FULL"]            = "— full (全画面61440ピクセル再描画、上限) —"
L["BENCH_ULTRA_FULL"]      = "  UltraRenderer  : %.4f ms/フレーム"
L["BENCH_PALETTE_FULL"]    = "  PaletteRenderer: %.4f ms/フレーム"
L["BENCH_TIP"]             = "ヒント: steadyは通常時の指標です。両方のsteadyが小さい場合、Presentはボトルネックではなく、PPU/CPUの最適化を優先してください。"

-- Help text
L["HELP_TOGGLE"]           = "|cffffd700[開く/閉じる]|r |cffffff00/fc|r でメインウィンドウを切り替え"
L["HELP_CONTROL"]          = "|cffffd700[操作モード]|r ウィンドウ下部の |cffffff00操作|r ボタンで切替。有効時はFCがキーボード入力を占有し、WoWキャラクターは反応しません。"
L["HELP_CONTROL_ESC"]      = "                |cffffff00ESC|r で操作モードを即時終了。ROM読み込み時は自動で有効になります。"
L["HELP_KEYBINDING"]       = "|cffffd700[キー設定]|r |cffffff00キー|r ボタンをクリック。キーボード / ゲームパッド / 連射(30HzでA/B自動連打)に対応。"
L["HELP_KEYBINDING_PAD"]   = "                使用前に |cffffff00WoW設定 → 操作 → ゲームパッドを有効化|r をオンにしてください。"
L["HELP_DEFAULT_KEYS"]     = "|cffffd700[デフォルトキー]|r"
L["HELP_DEFAULT_KEYS_DETAIL"] = "  方向キー = 移動   Z = A   X = B   Enter/Space = Start   Tab = Select"
L["HELP_COMMANDS"]         = "|cffffd700[コマンド]|r"
L["HELP_CMD_SKIP"]         = "  |cffffff00/fc skip <N>|r  フレームスキップ(1=オフ、2-10=Nフレームごとに1回描画、または |cffffff00auto|r 自動)"
L["HELP_CMD_PROF"]         = "  |cffffff00/fc prof|r       パフォーマンスデータ  |cffffff00/fc profreset|r リセット"
L["HELP_CMD_BENCH"]        = "  |cffffff00/fc bench [N]|r  レンダラーA/Bベンチマーク(SetColorTextureとSetTexCoordのPresentコスト比較)"
L["HELP_CMD_BOOST"]        = "  |cffffff00/fc boost|r      パフォーマンス強化を切替(実行中はWoWのFPS上限を解除)"
L["HELP_CMD_SOUND"]        = "  |cffffff00/fc sound <on|off>|r サウンド切替(事前録音音色の再生)"
L["HELP_CMD_DEBUG"]        = "  |cffffff00/fc debug|r      実行時ステータス"
