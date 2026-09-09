// 主题数据:命名主题注册表(NamedTheme 槽位数组)+ 当前激活主题 + 字段级配置。
// 主题内容(内置 8 套配色)是**外部数据**(resource/themes.dterm,经配置 load 引入);
// 代码内只保留 boot_theme(启动兜底:配置未激活任何主题时的显示)。
// CellStyle.fg/bg 存颜色**引用编码**(见下),渲染期 ResolveColor 解码 →
// 主题切换零缓冲污染(解析器零主题依赖),256 色固定公式(16-231 cube/232-255 灰度)。
// 参考:alacritty(269 索引表)/ WT(扁平配色方案)/ kitty(color0-255 + 边框色独立)。
package canvas

import mem "../memory"
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

// 256 索引 → RGB:0-15 取当前主题 ansi;16-231 cube;232-255 灰度(标准公式)
ansi256ToRgb :: proc(n : int) -> u32 {
	if n < 16 {
		return GetTheme().ansi[n]
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

// ---------------------------------------------------------------------------
// 命名主题注册表(外部数据段:resource/themes.dterm 经配置 load 写入)
// ---------------------------------------------------------------------------
MAX_THEME_SLOTS :: 32

MAX_THEME_NAME :: 31 // 名字定长截断(同页标题做法)

NamedTheme :: struct {
	name : [32]u8,
	name_len : u8,
	theme : Theme,
}

themes : mem.GenArray(MAX_THEME_SLOTS, NamedTheme)

current_theme_h : mem.Handle // 当前激活主题槽;0 = 未激活(GetTheme 返回 boot_theme)

// 代码内唯一保留的配色:启动兜底(配置未激活任何主题时的显示)。
// 它不是可发布主题 —— 真实配色全部在外部数据里(resource/themes.dterm)。
boot_theme := Theme {
	fg = 0xD0D0D0,
	bg = 0x101014,
	cursor = 0xFFFFFF,
	ansi = {
		0x000000, 0x800000, 0x008000, 0x808000,
		0x000080, 0x800080, 0x008080, 0xC0C0C0,
		0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
		0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
	},
	frame = 0x404048,
	focus_border = 0x729FCF,
	fps_bg = 0x0A0A0C,
	fps_fg = 0x808080,
	tab_bar_bg = 0x0A0A0C,
	tab_fg = 0x808080,
	tab_active_bg = 0x101014,
	tab_active_fg = 0xD0D0D0,
	tab_hover_bg = 0x202028,
	selection_bg = 0x404048,
	selection_fg = 0xFFFFFF,
}

// 按名取主题槽(nil = 未定义;名字大小写不敏感)
GetThemeSlot :: proc(name : string) -> ^NamedTheme {
	for i in 0 ..< MAX_THEME_SLOTS {
		slot := mem.GetIndex(&themes, i)
		if slot == nil {
			continue
		}
		if strings.equal_fold(string(slot.name[:slot.name_len]), name) {
			return slot
		}
	}
	return nil
}

// userapi:建/取命名主题(存在 = 取;不存在 = 建,初值 = boot_theme)。
// 配置文件里 theme-set "<name>" … 首次出现即建槽。
DefineTheme :: proc(name : string) -> ^NamedTheme {
	if len(name) == 0 {
		return nil
	}
	if slot := GetThemeSlot(name); slot != nil {
		return slot
	}
	slot := NamedTheme { theme = boot_theme }
	n := min(len(name), MAX_THEME_NAME)
	copy(slot.name[:n], name)
	slot.name_len = u8(n)
	h := mem.Alloc(&themes, slot)
	if h.id == 0 {
		return nil
	}
	return mem.Get(&themes, h)
}

// userapi:激活命名主题(不存在 = false;下一帧渲染全量按新表解码,缓冲零重写)
SetThemeByName :: proc(name : string) -> bool {
	for i in 0 ..< MAX_THEME_SLOTS {
		slot := mem.GetIndex(&themes, i)
		if slot == nil {
			continue
		}
		if strings.equal_fold(string(slot.name[:slot.name_len]), name) {
			current_theme_h = mem.GetHandle(&themes, i)
			return true
		}
	}
	return false
}

// userapi:当前主题指针(渲染/布局唯一读入口;未激活 = boot_theme 指针)。
// 直接改字段 = 改当前主题(规范 3.2:纯读取/纯赋值经指针直改)。
GetTheme :: proc() -> ^Theme {
	if slot := mem.Get(&themes, current_theme_h); slot != nil {
		return &slot.theme
	}
	return &boot_theme
}

// 注册表指针(命令 theme 无参列出:Alive/GetIndex 枚举,不直索引)
GetThemes :: proc() -> ^mem.GenArray(MAX_THEME_SLOTS, NamedTheme) {
	return &themes
}

// ---------------------------------------------------------------------------
// 字段级配置(命令 theme-set / 配置文件逐项覆盖)
// ---------------------------------------------------------------------------
// 字段判别(ansi 用 index 0..15;其余字段 index 恒 0)
ThemeField :: enum u8 {
	Fg,
	Bg,
	Cursor,
	Ansi,
	Frame,
	FocusBorder,
	FpsBg,
	FpsFg,
	TabBarBg,
	TabFg,
	TabActiveBg,
	TabActiveFg,
	TabHoverBg,
	SelectionBg,
	SelectionFg,
}

// 字段名表:name = Theme 结构体字段名(零映射;改字段名 = 改表)
ThemeFieldSpec :: struct {
	name : string,
	field : ThemeField,
	index : u8, // 仅 .Ansi 用
}

THEME_FIELDS := [?]ThemeFieldSpec {
	{ name = "fg", field = .Fg },
	{ name = "bg", field = .Bg },
	{ name = "cursor", field = .Cursor },
	{ name = "ansi0", field = .Ansi, index = 0 },
	{ name = "ansi1", field = .Ansi, index = 1 },
	{ name = "ansi2", field = .Ansi, index = 2 },
	{ name = "ansi3", field = .Ansi, index = 3 },
	{ name = "ansi4", field = .Ansi, index = 4 },
	{ name = "ansi5", field = .Ansi, index = 5 },
	{ name = "ansi6", field = .Ansi, index = 6 },
	{ name = "ansi7", field = .Ansi, index = 7 },
	{ name = "ansi8", field = .Ansi, index = 8 },
	{ name = "ansi9", field = .Ansi, index = 9 },
	{ name = "ansi10", field = .Ansi, index = 10 },
	{ name = "ansi11", field = .Ansi, index = 11 },
	{ name = "ansi12", field = .Ansi, index = 12 },
	{ name = "ansi13", field = .Ansi, index = 13 },
	{ name = "ansi14", field = .Ansi, index = 14 },
	{ name = "ansi15", field = .Ansi, index = 15 },
	{ name = "frame", field = .Frame },
	{ name = "focus_border", field = .FocusBorder },
	{ name = "fps_bg", field = .FpsBg },
	{ name = "fps_fg", field = .FpsFg },
	{ name = "tab_bar_bg", field = .TabBarBg },
	{ name = "tab_fg", field = .TabFg },
	{ name = "tab_active_bg", field = .TabActiveBg },
	{ name = "tab_active_fg", field = .TabActiveFg },
	{ name = "tab_hover_bg", field = .TabHoverBg },
	{ name = "selection_bg", field = .SelectionBg },
	{ name = "selection_fg", field = .SelectionFg },
}

// 字段名 → 规格(大小写不敏感;未知 = false)
ThemeFieldByName :: proc(name : string) -> (spec : ThemeFieldSpec, ok : bool) {
	for i in 0 ..< len(THEME_FIELDS) {
		if strings.equal_fold(THEME_FIELDS[i].name, name) {
			return THEME_FIELDS[i], true
		}
	}
	return {}, false
}

// 规格 → 规范字段名(FormatCommand 回显用;未知 = "?")
ThemeFieldName :: proc(field : ThemeField, index : u8) -> string {
	for i in 0 ..< len(THEME_FIELDS) {
		if THEME_FIELDS[i].field == field && THEME_FIELDS[i].index == index {
			return THEME_FIELDS[i].name
		}
	}
	return "?"
}

// userapi:设置命名主题的单个字段(名字不存在 = 建槽;ansi 索引越界 = false)。
// 若该主题正被激活,下一帧渲染即生效(注册表槽 = 唯一真相)。
SetThemeField :: proc(name : string, field : ThemeField, index : u8, color : u32) -> bool {
	slot := DefineTheme(name)
	if slot == nil {
		return false
	}
	switch field {
	case .Fg:
		slot.theme.fg = color
	case .Bg:
		slot.theme.bg = color
	case .Cursor:
		slot.theme.cursor = color
	case .Ansi:
		if int(index) >= len(slot.theme.ansi) {
			return false
		}
		slot.theme.ansi[index] = color
	case .Frame:
		slot.theme.frame = color
	case .FocusBorder:
		slot.theme.focus_border = color
	case .FpsBg:
		slot.theme.fps_bg = color
	case .FpsFg:
		slot.theme.fps_fg = color
	case .TabBarBg:
		slot.theme.tab_bar_bg = color
	case .TabFg:
		slot.theme.tab_fg = color
	case .TabActiveBg:
		slot.theme.tab_active_bg = color
	case .TabActiveFg:
		slot.theme.tab_active_fg = color
	case .TabHoverBg:
		slot.theme.tab_hover_bg = color
	case .SelectionBg:
		slot.theme.selection_bg = color
	case .SelectionFg:
		slot.theme.selection_fg = color
	}
	return true
}
