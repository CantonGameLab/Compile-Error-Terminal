// 主题数据:终端默认色 + 16 ANSI 色 + UI 色(唯一实例 current_theme,canvas 唯一写者)。
// CellStyle.fg/bg 存颜色**引用编码**(见下),渲染期 ResolveColor 解码 →
// 主题切换零缓冲污染(解析器零主题依赖),256 色固定公式(16-231 cube/232-255 灰度)。
// 参考:alacritty(269 索引表)/ WT(扁平配色方案)/ kitty(color0-255 + 边框色独立)。
package canvas

import "core:strings"

// 颜色引用编码(u32,CellStyle.fg/bg):
//   0x00RRGGBB            直接 RGB(SGR 38;2;r;g;b)
//   0x01xxxxxx(低24 = n)  索引色 n:0-15 → theme.ansi[n];16-255 → 固定 cube/灰度
//   0xFFFFFFFF            默认 → theme.fg / theme.bg(SGR 39/49/0)
DEFAULT_COLOR :: u32(0xFFFF_FFFF)

colorRgb :: proc(c : u32) -> u32 {
	return c // 24bit RGB,高字节 = 0
}

colorIndex :: proc(n : int) -> u32 {
	return 0x01_000000 | u32(n & 0xFF_FFFF)
}

// 渲染期解码:颜色引用 → RGB;默认色解析为 default 参数
ResolveColor :: proc(c : u32, default : u32) -> u32 {
	switch c >> 24 {
	case 0x00: // RGB
		return c
	case 0x01: // 索引
		return ansi256ToRgb(int(c & 0xFF_FFFF))
	}
	return default
}

// 256 索引 → RGB:0-15 取主题 ansi;16-231 cube;232-255 灰度(标准公式)
ansi256ToRgb :: proc(n : int) -> u32 {
	if n < 16 {
		return current_theme.ansi[n]
	}
	if n < 232 {
		n := n - 16
		r := ansiCubeLevel(n / 36)
		g := ansiCubeLevel((n % 36) / 6)
		b := ansiCubeLevel(n % 6)
		return (r << 16) | (g << 8) | b
	}
	v := 8 + (n - 232) * 10
	return u32(v) * 0x010101
}

ansiCubeLevel :: proc(v : int) -> u32 {
	return u32(v == 0 ? 0 : 55 + v * 40)
}

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------
Theme :: struct {
	fg, bg : u32, // 默认前景/背景(SGR 39/49/0 解析目标)
	cursor : u32, // 光标
	ansi : [16]u32, // SGR 索引 0..15:0-7 普通,8-15 亮(顺序 = WT/alacritty/kitty)
	frame : u32, // 分割条(原树节点 frame_color,主题化后节点回纯结构)
	focus_border : u32, // 焦点窗口边框(kitty active_border 对应物)
	fps_bg, fps_fg : u32, // 右上角 FPS tag
	tab_bar_bg : u32, // 底部页签条背景(非激活区)
	tab_fg : u32, // 非激活页签文字
	tab_active_bg : u32, // 激活页签底(默认 = 主题 bg:WT 式"背景延伸进激活页签")
	tab_active_fg : u32, // 激活页签文字(默认 = 主题 fg)
	tab_hover_bg : u32, // 页签悬停底
	selection_bg, selection_fg : u32, // 文本选区底色/字形色(选区高亮)
}

// 默认主题(现行配色)
DEFAULT_THEME := Theme {
	fg = 0xDCDCDC,
	bg = 0x1E1E1E,
	cursor = 0xFFFFFF,
	ansi = {
		0x000000, 0x800000, 0x008000, 0x808000,
		0x000080, 0x800080, 0x008080, 0xC0C0C0,
		0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
		0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
	},
	frame = 0xFFFF00,
	focus_border = 0x4FC3F7,
	fps_bg = 0x101418,
	fps_fg = 0x9FBFD8,
	tab_bar_bg = 0x16161C,
	tab_fg = 0x8A8F98,
	tab_active_bg = 0x1E1E1E, // = bg(WT 式背景延伸)
	tab_active_fg = 0xEAEAEA,
	tab_hover_bg = 0x26262E,
	selection_bg = 0x264F78,
	selection_fg = 0xFFFFFF,
}

current_theme : Theme = DEFAULT_THEME

// Dracula 主题(官方配色):bg #282A36 / fg #F8F8F2,accent 紫 #BD93F9,
// 分割条用 selection 灰紫 #44475A(低调)
DRACULA_THEME := Theme {
	fg = 0xF8F8F2,
	bg = 0x282A36,
	cursor = 0xF8F8F2,
	ansi = {
		0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
		0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
		0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
		0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
	},
	frame = 0x44475A,
	focus_border = 0xBD93F9,
	fps_bg = 0x21222C,
	fps_fg = 0x6272A4,
	tab_bar_bg = 0x21222C,
	tab_fg = 0x6272A4,
	tab_active_bg = 0x282A36, // 激活页签 = 主题 bg(背景延伸)
	tab_active_fg = 0xF8F8F2,
	tab_hover_bg = 0x383A4E,
	selection_bg = 0x44475A,
	selection_fg = 0xF8F8F2,
}

// Nord 主题(Arctic Night):bg #2E3440 极夜 / fg #D8DEE9 雪;accent = frost 青 #88C0D0
NORD_THEME := Theme {
	fg = 0xD8DEE9,
	bg = 0x2E3440,
	cursor = 0xD8DEE9,
	ansi = {
		0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
		0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
		0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
		0x81A1C1, 0xB48EAD, 0x88C0D0, 0xECEFF4,
	},
	frame = 0x4C566A,
	focus_border = 0x88C0D0,
	fps_bg = 0x272C33,
	fps_fg = 0x616E88,
	tab_bar_bg = 0x272C33,
	tab_fg = 0x616E88,
	tab_active_bg = 0x2E3440,
	tab_active_fg = 0xD8DEE9,
	tab_hover_bg = 0x3B4252,
	selection_bg = 0x4C566A,
	selection_fg = 0xD8DEE9,
}

// Solarized Dark(Ethan Schoonover):bg #002B36 / fg #839496;accent = 蓝 #268BD2
SOLARIZED_DARK_THEME := Theme {
	fg = 0x839496,
	bg = 0x002B36,
	cursor = 0x93A1A1,
	ansi = {
		0x073642, 0xDC322F, 0x859900, 0xB58900,
		0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
		0x002B36, 0xCB4B16, 0x859900, 0xB58900,
		0x268BD2, 0xD33682, 0x2AA198, 0xFDF6E3,
	},
	frame = 0x586E75,
	focus_border = 0x268BD2,
	fps_bg = 0x00212B,
	fps_fg = 0x586E75,
	tab_bar_bg = 0x00212B,
	tab_fg = 0x586E75,
	tab_active_bg = 0x002B36,
	tab_active_fg = 0x839496,
	tab_hover_bg = 0x073642,
	selection_bg = 0x073642,
	selection_fg = 0xEEE8D5,
}

// Gruvbox Dark(morhetz):bg #282828 / fg #EBDBB2;accent = 蓝 #83A598
GRUVBOX_DARK_THEME := Theme {
	fg = 0xEBDBB2,
	bg = 0x282828,
	cursor = 0xEBDBB2,
	ansi = {
		0x282828, 0xCC241D, 0x98971A, 0xD79921,
		0x458588, 0xB16286, 0x689D6A, 0xA89984,
		0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
		0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
	},
	frame = 0x504945,
	focus_border = 0x83A598,
	fps_bg = 0x1D2021,
	fps_fg = 0x928374,
	tab_bar_bg = 0x1D2021,
	tab_fg = 0x928374,
	tab_active_bg = 0x282828,
	tab_active_fg = 0xEBDBB2,
	tab_hover_bg = 0x3C3836,
	selection_bg = 0x504945,
	selection_fg = 0xEBDBB2,
}

// Monokai:bg #272822 / fg #F8F8F2;accent = 青 #66D9EF
MONOKAI_THEME := Theme {
	fg = 0xF8F8F2,
	bg = 0x272822,
	cursor = 0xF8F8F2,
	ansi = {
		0x272822, 0xF92672, 0xA6E22E, 0xE6DB74,
		0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
		0x75715E, 0xF92672, 0xA6E22E, 0xE6DB74,
		0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
	},
	frame = 0x49483E,
	focus_border = 0x66D9EF,
	fps_bg = 0x1E1F1C,
	fps_fg = 0x75715E,
	tab_bar_bg = 0x1E1F1C,
	tab_fg = 0x75715E,
	tab_active_bg = 0x272822,
	tab_active_fg = 0xF8F8F2,
	tab_hover_bg = 0x3D3E37,
	selection_bg = 0x49483E,
	selection_fg = 0xF8F8F2,
}

// One Dark(Atom):bg #282C34 / fg #ABB2BF;accent = 蓝 #61AFEF
ONE_DARK_THEME := Theme {
	fg = 0xABB2BF,
	bg = 0x282C34,
	cursor = 0x528BFF,
	ansi = {
		0x282C34, 0xE06C75, 0x98C379, 0xE5C07B,
		0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
		0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B,
		0x61AFEF, 0xC678DD, 0x56B6C2, 0xD7DAE0,
	},
	frame = 0x3E4451,
	focus_border = 0x61AFEF,
	fps_bg = 0x21252B,
	fps_fg = 0x5C6370,
	tab_bar_bg = 0x21252B,
	tab_fg = 0x5C6370,
	tab_active_bg = 0x282C34,
	tab_active_fg = 0xABB2BF,
	tab_hover_bg = 0x3E4451,
	selection_bg = 0x3E4451,
	selection_fg = 0xABB2BF,
}

// Tango Dark(Windows Terminal 官方 scheme,TerminalSettingsModel/defaults.json):
// bg #000000 / fg #D3D7CF(即 white);accent = brightBlue #729FCF;
// 分割条/选区 = 暗灰 #555753(低调,同 Dracula/Nord 的"selection 灰"做法)
TANGO_DARK_THEME := Theme {
	fg = 0xD3D7CF,
	bg = 0x000000,
	cursor = 0xFFFFFF,
	ansi = {
		0x000000, 0xCC0000, 0x4E9A06, 0xC4A000,
		0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
		0x555753, 0xEF2929, 0x8AE234, 0xFCE94F,
		0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
	},
	frame = 0x555753,
	focus_border = 0x729FCF,
	fps_bg = 0x0A0A0C,
	fps_fg = 0x555753,
	tab_bar_bg = 0x0A0A0C,
	tab_fg = 0x555753,
	tab_active_bg = 0x000000, // = bg(WT 式背景延伸)
	tab_active_fg = 0xD3D7CF,
	tab_hover_bg = 0x1E1E1E,
	selection_bg = 0x555753,
	selection_fg = 0xD3D7CF,
}

// ---------------------------------------------------------------------------
// 主题表(名字 → Theme):配置文件/命令栏按名字切换,缺省列出
// ---------------------------------------------------------------------------
ThemeSpec :: struct {
	name : string, // 命令参数名(theme monokai)
	theme : Theme,
}

// 内置主题(顺序 = 列出顺序;值引用上面的命名常量,单一真相源在常量)
THEME_SPECS := [?]ThemeSpec {
	{ name = "default", theme = DEFAULT_THEME },
	{ name = "dracula", theme = DRACULA_THEME },
	{ name = "nord", theme = NORD_THEME },
	{ name = "solarized-dark", theme = SOLARIZED_DARK_THEME },
	{ name = "gruvbox-dark", theme = GRUVBOX_DARK_THEME },
	{ name = "monokai", theme = MONOKAI_THEME },
	{ name = "one-dark", theme = ONE_DARK_THEME },
	{ name = "tango-dark", theme = TANGO_DARK_THEME },
}

// 主题表(只读遍历:命令 theme 无参列出)
GetThemes :: proc() -> []ThemeSpec {
	return THEME_SPECS[:]
}

// userapi:按名字切换(大小写不敏感;未知名字 = false,保留旧主题)
SetThemeByName :: proc(name : string) -> bool {
	for i in 0 ..< len(THEME_SPECS) {
		if strings.equal_fold(THEME_SPECS[i].name, name) {
			SetTheme(THEME_SPECS[i].theme)
			return true
		}
	}
	return false
}

// userapi:整表替换(配置入口/命令 theme);下一帧渲染全部按新表解码(缓冲零重写)
SetTheme :: proc(t : Theme) {
	current_theme = t
}

// 主题数据指针:只读消费(渲染)/字段级修改都直接操作数据结构本身
GetTheme :: proc() -> ^Theme {
	return &current_theme
}
