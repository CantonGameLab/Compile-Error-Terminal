// 命令规格表(语法层数据):命令名/别名/参数形态/用法/说明。
// 解析、参数校验、错误文本、FormatCommand(逆变换)、help 全部由本表驱动 ——
// 新命令 = 表项 + ExecuteCommand 分支,解析器里不写命令名特判。
// 顺序 = help 输出顺序;args 按语法位置排列,None 结尾。
package command

// 参数形态:解析器逐位取用(位置 = 语法位置)
ArgKind :: enum u8 {
	None,       // 结束标记
	Str,        // "..." 或裸词 → sval(第二个 Str 参数 → sval2;借用输入内存)
	F32,        // 数字 → fval
	I32,        // 非负整数 → ival
	Toggle,     // on/off;省略 → mode = .Toggle(三态)
	SplitDir,   // right|left|up|down|h|v → dir + split_first
	FocusArg,   // id 或方向词 → kind 分派 FocusId/FocusDir
	KeyCombo,   // mods+key → sc + mods
	ThemeField, // 主题字段名 → tfield + tindex(解析期校验)
	Color,      // #RRGGBB / RRGGBB / 0xRRGGBB → color
	SubCommand, // 命令字符串(递归解析)→ sub 句柄
}

MAX_CMD_ARGS :: 4 // 单命令参数上限(表里 args 的长度上限)

CommandSpec :: struct {
	name   : string,                // 规范名(格式化/help 用)
	alias  : string,                // 别名("" = 无)
	kind   : CommandStringKind,     // 默认 kind(FocusArg 可改判)
	args   : []ArgKind,             // 位置参数形态(长度 ≤ MAX_CMD_ARGS,None 结尾)
	req    : u8,                    // 前 req 个必填(其余可省)
	target : bool,                  // 允许末尾 @id(窗口类命令)
	usage  : string,                // 参数摘要(help/错误信息)
	help   : string,                // 一句说明
}

COMMAND_SPECS := [?]CommandSpec {
	// ---- 窗口树 / 焦点 ----
	{
		name = "split", kind = .Split, args = {.SplitDir, .F32, .None}, req = 1, target = true,
		usage = "<right|left|up|down> [factor] [@id]",
		help = "分裂窗口;left/up = 新窗在首侧,factor = 原窗占比(默认 0.5)",
	},
	{
		name = "focus", kind = .FocusId, args = {.FocusArg, .None, .None}, req = 1,
		usage = "<id|left|right|up|down>",
		help = "聚焦窗口(按 id 或方向导航)",
	},
	{
		name = "destroy", alias = "close", kind = .Destroy, target = true,
		usage = "[@id]",
		help = "关闭窗口及其会话(唯一剩余窗口 = 清空整树)",
	},
	{
		name = "factor", kind = .Factor, args = {.F32, .None, .None}, req = 1, target = true,
		usage = "<ratio> [@id]",
		help = "设置窗口父节点比例(0.05..0.95)",
	},
	{
		name = "factorleaf", kind = .FactorLeaf, args = {.I32, .F32, .None}, req = 2,
		usage = "<n> <ratio>",
		help = "设置先序叶子序号 n(1-based)认领的 split 比例",
	},
	{
		name = "splittype", alias = "rotate", kind = .SplitTypeToggle, target = true,
		usage = "[@id]",
		help = "切换窗口父节点的分割轴(左右 ⇄ 上下)",
	},
	{
		name = "exchange", kind = .Exchange, args = {.FocusArg, .None, .None}, req = 1, target = true,
		usage = "<left|right|up|down> [@id]",
		help = "与方向邻居交换窗口内容(树结构不变)",
	},
	{
		name = "single", alias = "single-mode", kind = .Single, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "单窗显示模式:焦点窗独占树区(省略参数 = 翻转)",
	},
	{
		name = "osc", alias = "osc-auth", kind = .OscAuth, args = {.Toggle, .None, .None}, target = true,
		usage = "[on|off] [@id]",
		help = "授权窗格 console 使用 OSC 999 命令信道(有 poll = 已授权;换程序即失效);授权 = 该程序获得完整命令能力",
	},
	{
		name = "count", alias = "windows", kind = .Count,
		usage = "",
		help = "查询窗口数量",
	},
	{
		name = "info", kind = .Info, target = true,
		usage = "[@id]",
		help = "查询窗口信息(字体/会话/比例/自动关闭)",
	},
	{
		name = "focus-get", alias = "getfocus", kind = .FocusGet,
		usage = "",
		help = "查询焦点窗口 id",
	},
	{
		name = "size", kind = .ConsoleSize, target = true,
		usage = "[@id]",
		help = "查询窗格尺寸(cols x rows)",
	},
	{
		name = "head", kind = .Head, args = {.I32, .None, .None}, req = 1, target = true,
		usage = "<n> [@id]",
		help = "取面板(视口)从最上面数前 n 行的文本(每行一条,行尾空白已裁;超出面板行数 = 给多少算多少)",
	},

	// ---- 字体 / 会话 ----
	{
		name = "font", kind = .Font, args = {.Str, .F32, .None}, req = 1, target = true,
		usage = `"<path|name>" <size> [@id]`,
		help = "设置窗口字体(路径或系统字体名;单个数字 = 只改字号)",
	},
	{
		name = "fontset", kind = .FontSet, args = {.Str, .Str, .F32}, req = 3, target = true,
		usage = `"<主字体>" "<中文字体>" <size> [@id]`,
		help = "设置窗格字体集:主字体定字符格、中文字体适配它(全角 = 2 格);中文字体写 \"\" = 用系统候选",
	},
	{
		name = "fontsize", kind = .FontSize, args = {.F32, .None, .None}, req = 1, target = true,
		usage = "<size> [@id]",
		help = "改字号(保留字体)",
	},
	{
		name = "fontsizeup", kind = .FontSizeUp, target = true,
		usage = "[@id]",
		help = "字号 +2",
	},
	{
		name = "fontsizedown", kind = .FontSizeDown, target = true,
		usage = "[@id]",
		help = "字号 -2",
	},
	{
		name = "launch", kind = .Launch, args = {.Str, .None, .None}, req = 1, target = true,
		usage = `"<cmd>" [@id]`,
		help = "用窗口字体启动 console 应用(需先设字体)",
	},
	{
		name = "feed", kind = .Feed, args = {.Str, .None, .None}, req = 1, target = true,
		usage = `"<text>" [@id]`,
		help = `向窗口会话写入输入;支持转义 \r \n \t \e \\ \xNN(回车 = feed "\r")`,
	},
	{
		name = "clearconsole", alias = "clearc", kind = .ClearConsole, target = true,
		usage = "[@id]",
		help = "清空窗格会话(保留窗格与字体)",
	},
	{
		name = "scroll", kind = .Scroll, args = {.F32, .None, .None}, req = 1, target = true,
		usage = "<lines> [@id]",
		help = "历史滚动:正 = 向下(新),负 = 向上(旧,进 review)",
	},
	{
		name = "reviewup", kind = .ReviewUp, target = true,
		usage = "[@id]",
		help = "上翻一屏历史",
	},
	{
		name = "reviewdown", kind = .ReviewDown, target = true,
		usage = "[@id]",
		help = "下翻一屏历史",
	},
	{
		name = "review-exit", alias = "exitreview", kind = .ExitReview, target = true,
		usage = "[@id]",
		help = "退出 review 回实时跟随",
	},

	// ---- 页 ----
	{
		name = "page-new", kind = .PageNew, args = {.Str, .None, .None}, req = 0,
		usage = `["<title>"]`,
		help = "新建页并切换(可选标题;自动建根窗 + 默认启动)",
	},
	{
		name = "page", kind = .PageSwitch, args = {.I32, .None, .None}, req = 1,
		usage = "<n>",
		help = "切换页(n = 页存活序,1-based)",
	},
	{
		name = "page-next", kind = .PageNext,
		usage = "",
		help = "下一页(环绕)",
	},
	{
		name = "page-prev", kind = .PagePrev,
		usage = "",
		help = "上一页(环绕)",
	},
	{
		name = "page-close", kind = .PageClose, args = {.I32, .None, .None}, req = 0,
		usage = "[n]",
		help = "关页(缺省 = 当前页;最后一页拒绝)",
	},
	{
		name = "page-title", alias = "title", kind = .PageTitle, args = {.Str, .I32, .None}, req = 1,
		usage = `"<title>" [n]`,
		help = "设置页标题(缺省 = 当前页)",
	},
	{
		name = "pages", kind = .PageList,
		usage = "",
		help = "列出所有页(序号/标题/当前标记)",
	},

	// ---- 选区 / 剪贴板 ----
	{
		name = "copy", kind = .CopySelection,
		usage = "",
		help = "复制文本选区到剪贴板",
	},
	{
		name = "paste", kind = .PasteClipboard,
		usage = "",
		help = "粘贴剪贴板到焦点窗口",
	},
	{
		name = "clearselection", alias = "deselect", kind = .SelectionClear,
		usage = "",
		help = "清除文本选区",
	},
	{
		name = "selectall", kind = .SelectAll,
		usage = "",
		help = "全选焦点窗口缓冲",
	},

	// ---- 外观 / UI ----
	{
		name = "theme", kind = .Theme, args = {.Str, .None, .None}, req = 0,
		usage = "[name]",
		help = "切换主题(缺省 = 列出全部主题)",
	},
	{
		name = "theme-set", alias = "tset", kind = .ThemeSet, args = {.Str, .ThemeField, .Color}, req = 3,
		usage = `"<name>" <字段> <#RRGGBB>`,
		help = "设置命名主题的字段(名字不存在则新建;字段 fg/bg/cursor/ansi0-15/frame/focus_border/fps_*/tab_*/selection_*)",
	},
	{
		name = "uifont", kind = .UIFont, args = {.Str, .F32, .None}, req = 2,
		usage = `"<path|name>" <size>`,
		help = "设置 UI 字体(页签/状态栏/FPS 共用)",
	},
	{
		name = "uifont-reset", alias = "uireset", kind = .UIFontReset,
		usage = "",
		help = "UI 字体回默认(consola 18)",
	},
	{
		name = "borderless", alias = "toggle-borderless", kind = .Borderless, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "无边框窗口(省略参数 = 翻转)",
	},
	{
		name = "vsync", kind = .VSync, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "垂直同步(省略参数 = 翻转)",
	},
	{
		name = "blockloop", alias = "block", kind = .BlockLoop, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "主循环阻塞:on = 没活就睡(静止 CPU≈0);off = 每帧无条件跑(退回旧行为,排查用)",
	},
	{
		name = "fps", kind = .FpsTag, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "状态栏右下角 FPS 标签显示(默认关;省略参数 = 翻转)",
	},
	{
		name = "conpty", kind = .Conpty, args = {.Toggle, .None, .None},
		usage = "[on|off]",
		help = "新会话的 ConPTY 实现:on = 外部 conpty.dll(新版 OpenConsole);off = 系统 kernel32;省略 = 翻转。只影响新会话",
	},
	{
		name = "rec", alias = "record", kind = .Record, args = {.Str, .None, .None}, req = 0, target = true,
		usage = `["<path>"] [@id]`,
		help = "录制该窗格(缺省焦点)的 ConPTY 原始字节流到 <path>(缺省 dump.bin,同时写 dump.bin.meta);省略参数 = 停止。回放见 playground/widecap/",
	},
	{
		name = "hinting", kind = .Hinting, args = {.Str, .None, .None}, req = 0,
		usage = "[stb|off|light|normal]",
		help = "字形光栅化:stb = 无 hinting(旧行为);off/light/normal = FreeType 提示强度;省略 = 显示当前。切换后字形缓存重新光栅化",
	},
	{
		name = "bgshader", alias = "bg", kind = .BgShader, args = {.Str, .None, .None}, req = 0,
		usage = `["<path>"]`,
		help = "背景 shader:缺省 = 重载默认文件,带路径 = 编译该文件",
	},
	{
		name = "toggle-commandbar", alias = "togglebar", kind = .ToggleCommandBar,
		usage = "",
		help = "命令栏开关",
	},
	{
		name = "default-launch", alias = "startup", kind = .DefaultLaunch, args = {.Str, .Str, .F32, .Str}, req = 1,
		usage = `"<cmd>" ["<font>" <size> ["<中文字体>"]]`,
		help = "新建窗口的默认启动配置(cmd 空 = 不自动启动);字体集 = 主字体(定字符格)+ 中文字体(适配 2 格),中文空 = 系统候选",
	},

	// ---- 配置 ----
	{
		name = "load", kind = .Load, args = {.Str, .None, .None}, req = 1,
		usage = `"<path>"`,
		help = "执行另一个命令文件(相对路径 = 相对当前文件所在目录;配置文件顺序自管)",
	},
	{
		name = "cwd", kind = .Cwd, args = {.Str, .None, .None}, req = 0,
		usage = `["<path>"]`,
		help = "全局会话工作目录:所有新窗口的初始目录(省略参数 = 查询当前值)",
	},

	// ---- 键位 ----
	{
		name = "bind", kind = .SetBinding, args = {.KeyCombo, .SubCommand, .None}, req = 2,
		usage = `<mods+key> "<命令>"`,
		help = "绑定键位(mods 前缀 alt/ctrl/shift/win,以 + 连键名)",
	},
	{
		name = "unbind", kind = .UnsetBinding, args = {.KeyCombo, .None, .None}, req = 1,
		usage = "<mods+key>",
		help = "移除绑定(不存在 = 失败)",
	},
	{
		name = "bindings", kind = .BindingsGet,
		usage = "",
		help = "枚举全部绑定(输出可再 bind)",
	},

	// ---- 帮助 ----
	{
		name = "help", alias = "?", kind = .Help, args = {.Str, .None, .None}, req = 0,
		usage = "[命令]",
		help = "列出全部命令(带参数 = 单条用法)",
	},
}

// 命令名 → 规格(别名一并匹配;大小写不敏感,线性扫描:冷路径)
findSpec :: proc(name : string) -> ^CommandSpec {
	for i in 0 ..< len(COMMAND_SPECS) {
		if nameEq(COMMAND_SPECS[i].name, name) || nameEq(COMMAND_SPECS[i].alias, name) {
			return &COMMAND_SPECS[i]
		}
	}
	return nil
}

// kind → 规格(FormatCommand 用;FocusDir 与 FocusId 共用 focus 行)
specForKind :: proc(kind : CommandStringKind) -> ^CommandSpec {
	if kind == .FocusDir {
		return findSpec("focus")
	}
	for i in 0 ..< len(COMMAND_SPECS) {
		if COMMAND_SPECS[i].kind == kind {
			return &COMMAND_SPECS[i]
		}
	}
	return nil
}

// ASCII 大小写不敏感比较(命令名/键名统一策略;无分配)
nameEq :: proc(a, b : string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}
