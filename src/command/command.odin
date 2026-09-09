// 指令语法解析 + 数据化命令执行(动作层唯一入口):
//   ParseCommandString / ParseCommandStringEx:字符串 → ParsedCommand(命令数据;Ex 带失败原因)
//   FormatCommand:ParsedCommand → 可再解析的字符串(逆变换:bindings 回显 / 配置写回 / 探针往返)
//   ExecuteCommandString:字符串快捷入口(解析 + 执行 + 释放子命令槽)
//   ExecuteCommand:ParsedCommand → 各模块 userapi(唯一命令解释器;绑定表与配置文件
//     产生的命令数据也走这里,不做第二次分派)
// 语法/参数形态/相位/帮助全部来自 spec.odin 的 COMMAND_SPECS(本文件不写命令名特判)。
// 语法:命令名 参数... [@id]
//   - 参数按空格分隔,"..." 包裹字符串(字符串内不能含引号);命令名/键名大小写不敏感
//   - @id 放末尾指定目标节点(缺省 = 当前焦点),仅窗口类命令接受
//   - bind/unbind 的键组合 = mods+key:alt/ctrl/shift/win 前缀以 '+' 连向键名
// 供命令栏 / 配置文件(command/config.odin) / 子进程 ANSI 指令通道使用。薄分派层,无 undo。
package command

import cv "../canvas"
import inp "../input"
import mem "../memory"
import rnd "../render"
import "core:fmt"
import "core:strings"

// 单行 token 上限(超出 = 报错,不静默截断)
MAX_CMD_TOKENS :: 24

// 解析结果判别(按 kind 取用字段;全集与 COMMAND_SPECS 一一对应)
CommandStringKind :: enum u8 {
	// 窗口树 / 焦点
	Split,        // dir + split_first + fval(factor)
	FocusId,      // target = 目标节点
	FocusDir,     // fdir
	Destroy,      // target
	Factor,       // fval
	FactorLeaf,   // ival(叶子序号 1-based)+ fval
	Exchange,     // fdir
	Single,       // mode
	Count,
	Info,         // target
	FocusGet,
	// 字体 / 会话
	Font,         // sval + fval
	FontSize,     // fval
	FontSizeUp,
	FontSizeDown,
	Launch,       // sval
	Feed,         // sval
	ClearConsole, // target
	Scroll,       // fval(行数,正下负上)
	ReviewUp,
	ReviewDown,
	ExitReview,   // target
	// 页
	PageNew,      // sval(可选标题)
	PageSwitch,   // ival(存活序 1-based)
	PageNext,
	PagePrev,
	PageClose,    // ival(缺省 0 = 当前页)
	PageTitle,    // sval + ival(缺省 0 = 当前页)
	PageList,
	// 选区 / 剪贴板
	CopySelection,
	PasteClipboard,
	SelectionClear,
	SelectAll,
	// 外观 / UI
	Theme,          // sval(空 = 列出主题)
	ThemeSet,       // tfield + tindex + color
	UIFont,         // sval + fval
	UIFontReset,
	Borderless,     // mode
	VSync,          // mode
	BgShader,       // sval(空 = 重载默认文件)
	ToggleCommandBar,
	DefaultLaunch,  // sval(cmd)+ sval2(font)+ fval(size)
	Load,           // sval(配置文件路径;执行另一个命令文件)
	// 键位
	SetBinding,   // sc + mods + sub(子命令句柄,解析层分配)
	UnsetBinding, // sc + mods
	BindingsGet,
	// 帮助
	Help,         // sval(空 = 全部)
}

// 三态开关参数(省略 = Toggle)
ToggleMode :: enum u8 {
	Toggle,
	On,
	Off,
}

ParsedCommand :: struct {
	kind : CommandStringKind,
	target : mem.Handle,      // @id 解析出的节点(带世代);0 = 焦点
	dir : cv.SplitType,       // Split
	split_first : bool,       // Split:新窗在首侧(左/上)
	fdir : cv.FocusDirection, // FocusDir / Exchange
	mode : ToggleMode,        // Single / Borderless / VSync
	fval : f32,               // Split factor / Factor / Font size / Scroll 行数 / DefaultLaunch size
	ival : int,               // FactorLeaf 叶子序号 / Page 序号
	sval : string,            // 第一字符串参数(借用输入内存)
	sval2 : string,           // 第二字符串参数(仅 DefaultLaunch 的字体名)
	sc : u32,                 // SetBinding/UnsetBinding:scancode 数值
	mods : KeyMods,           // SetBinding/UnsetBinding:修饰位
	color : u32,              // ThemeSet:24bit RGB
	tfield : cv.ThemeField,   // ThemeSet:字段
	tindex : u8,              // ThemeSet:ansi 索引
	sub : mem.Handle,         // SetBinding:子命令(解析层 Alloc 入 sub_commands)
}

// bind 子命令表:解析层 Alloc(每行 bind 一个槽),执行完即 Free。
// 嵌套 bind 拒绝(子命令不再挂子命令);绑定表存的是子命令的**值副本**,不持有 sub 句柄。
MAX_SUB_COMMANDS :: 32

sub_commands : mem.GenArray(MAX_SUB_COMMANDS, ParsedCommand)

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
// 每帧唯一入口(main,canvas.Update 之前):键绑定消费(命中即置 consumed)+
// 命令事件消费(上一帧命令栏提交的队列;结果写回事件槽,canvas 帧内读回)。
Update :: proc() {
	ProcessKeys()
	processCommandEvents()
}

// 执行命令字符串;查询类命令的结果经 out 回调回传(控制台/配置加载显示用)。
// 失败时 out 也收到失败原因(命令栏据此显示)。返回 false = 语法错误或执行失败。
ExecuteCommandString :: proc(s : string, out : proc(msg : string) = nil) -> bool {
	errbuf : [256]u8
	_, ok := executeString(s, errbuf[:], out)
	return ok
}

// 解析 + 执行 + 释放子命令槽(解析失败时把原因经 out 回传)
executeString :: proc(s : string, errbuf : []u8, out : proc(msg : string) = nil) -> (err : string, ok : bool) {
	cmd, perr, pok := ParseCommandStringEx(s, errbuf)
	if !pok {
		if out != nil {
			out(perr)
		}
		return perr, false
	}
	defer if cmd.sub.id != 0 {
		mem.Free(&sub_commands, cmd.sub)
	}
	return "", ExecuteCommand(cmd, out)
}

// ---------------------------------------------------------------------------
// 解释器(唯一):kind → userapi
// ---------------------------------------------------------------------------
// 单窗模式(Single)的树/焦点/尺寸禁用规则在 canvas 域边界(userapi 内 singleGuard)
// 统一判定:命令拦不拦,userapi 自己按当前页语义拒绝。
ExecuteCommand :: proc(cmd : ParsedCommand, out : proc(msg : string) = nil) -> bool {
	switch cmd.kind {
	// ---- 窗口树 / 焦点 ----
	case .Split:
		// factor 缺省 = 0.5(规范:<= 0 视为未给)
		factor := cmd.fval
		if factor <= 0 {
			factor = 0.5
		}
		return cv.SplitNewWindow(cmd.dir, cmd.target, cmd.split_first, factor) != mem.Handle {}
	case .FocusId:
		return cv.SetFocusWindow(cmd.target)
	case .FocusDir:
		return cv.FocusMove(cmd.fdir, cmd.target)
	case .Destroy:
		return cv.DestroyWindow(cmd.target)
	case .Factor:
		return cv.SetSplitFactor(cmd.fval, cmd.target)
	case .FactorLeaf:
		return cv.SetSplitFactorLeaf(cmd.ival, cmd.fval)
	case .Exchange:
		return cv.ExchangeWindow(cmd.fdir, cmd.target)
	case .Single:
		switch cmd.mode {
		case .On:
			return cv.SetSingleMode(true)
		case .Off:
			return cv.SetSingleMode(false)
		case .Toggle:
			cv.ToggleSingleMode()
			return true
		}
	case .Count:
		if out != nil {
			out(fmt.tprintf("windows: %d", cv.ConsoleCount()))
		}
		return true
	case .Info:
		info, ok := cv.GetConsoleInfo(cmd.target)
		if !ok {
			return false
		}
		if out != nil {
			if !info.has_console {
				out(fmt.tprintf("window %d  空窗格  factor %.2f", info.node.id, info.split_factor))
			} else {
				out(fmt.tprintf("window %d  font %s %.0f  %s %dx%d  review %d  factor %.2f",
					info.node.id, info.font_name, info.font_size,
					info.has_session ? "session" : "no-session",
					info.cols, info.rows, info.review_line, info.split_factor))
			}
		}
		return true
	case .FocusGet:
		if out != nil {
			out(fmt.tprintf("focus: %d", cv.GetFocusWindow().id))
		}
		return true

	// ---- 字体 / 会话 ----
	case .Font:
		return cv.SetConsoleFont(cmd.sval, cmd.fval, cmd.target)
	case .FontSize:
		return cv.SetConsoleFontSize(cmd.fval, cmd.target)
	case .FontSizeUp:
		return cv.AdjustConsoleFontSize(2, cmd.target)
	case .FontSizeDown:
		return cv.AdjustConsoleFontSize(-2, cmd.target)
	case .Launch:
		return cv.LaunchConsole(cmd.sval, cmd.target)
	case .Feed:
		return cv.FeedConsole(transmute([]u8)cmd.sval, cmd.target)
	case .ClearConsole:
		return cv.ClearConsoleSession(cmd.target)
	case .Scroll:
		return cv.ConsoleScroll(int(cmd.fval), cmd.target)
	case .ReviewUp:
		return cv.ConsoleScroll(-focusRows(cmd.target), cmd.target)
	case .ReviewDown:
		return cv.ConsoleScroll(focusRows(cmd.target), cmd.target)
	case .ExitReview:
		return cv.ConsoleExitReview(cmd.target)

	// ---- 页 ----
	case .PageNew:
		page_h := cv.PageNew()
		if page_h.id == 0 {
			return false
		}
		if cmd.sval != "" {
			cv.PageSetTitle(page_h, cmd.sval)
		}
		return true
	case .PageSwitch:
		page_h := cv.PageByIndex(cmd.ival)
		if page_h.id == 0 {
			return false
		}
		return cv.PageSwitch(page_h)
	case .PageNext:
		return cv.PageNext()
	case .PagePrev:
		return cv.PagePrev()
	case .PageClose:
		page_h := cv.PageCurrent()
		if cmd.ival > 0 {
			page_h = cv.PageByIndex(cmd.ival)
		}
		if page_h.id == 0 {
			return false
		}
		return cv.PageDestroy(page_h)
	case .PageTitle:
		page_h := cv.PageCurrent()
		if cmd.ival > 0 {
			page_h = cv.PageByIndex(cmd.ival)
		}
		if page_h.id == 0 {
			return false
		}
		return cv.PageSetTitle(page_h, cmd.sval)
	case .PageList:
		if out != nil {
			cur := cv.PageCurrent()
			n := cv.PageCount()
			for i in 1 ..= n {
				page_h := cv.PageByIndex(i)
				mark := page_h == cur ? "*" : " "
				out(fmt.tprintf("%s %d  %s", mark, i, cv.PageTitle(page_h)))
			}
		}
		return true

	// ---- 选区 / 剪贴板 ----
	case .CopySelection:
		return cv.CopySelection()
	case .PasteClipboard:
		return cv.PasteClipboard()
	case .SelectionClear:
		cv.SelectionClear()
		return true
	case .SelectAll:
		return cv.SelectionSelectAll()

	// ---- 外观 / UI ----
	case .Theme:
		if cmd.sval == "" {
			if out != nil {
				cur := cv.GetTheme()
				reg := cv.GetThemes()
				for i in 1 ..< cv.MAX_THEME_SLOTS {
					slot := mem.GetIndex(reg, i)
					if slot == nil {
						continue
					}
					mark := &slot.theme == cur ? "*" : " "
					out(fmt.tprintf("%s %s", mark, string(slot.name[:slot.name_len])))
				}
			}
			return true
		}
		return cv.SetThemeByName(cmd.sval)
	case .ThemeSet:
		return cv.SetThemeField(cmd.sval, cmd.tfield, cmd.tindex, cmd.color)
	case .UIFont:
		return cv.SetUIFont(cmd.sval, cmd.fval)
	case .UIFontReset:
		cv.ResetUIFont()
		return true
	case .Borderless:
		on := rnd.GetWindowBorderless()
		switch cmd.mode {
		case .On:
			on = true
		case .Off:
			on = false
		case .Toggle:
			on = !on
		}
		rnd.SetWindowBorderless(on)
		return true
	case .VSync:
		on := rnd.GetVSync()
		switch cmd.mode {
		case .On:
			on = true
		case .Off:
			on = false
		case .Toggle:
			on = !on
		}
		rnd.SetVSync(on)
		return true
	case .BgShader:
		if cmd.sval == "" {
			return rnd.ResetBackgroundShader()
		}
		return rnd.SetBackgroundShaderFile(cmd.sval)
	case .ToggleCommandBar:
		cv.ToggleCommandBar()
		return true
	case .DefaultLaunch:
		cv.SetDefaultLaunch(cmd.sval, cmd.sval2, cmd.fval)
		return true
	case .Load:
		return configLoadFile(cmd.sval)

	// ---- 键位 ----
	case .SetBinding:
		// 子命令已由解析层解析入表(sub 句柄),执行只读
		sub := mem.Get(&sub_commands, cmd.sub)
		if sub == nil {
			return false
		}
		return SetKeyBinding(inp.Scancode(cmd.sc), cmd.mods, sub^)
	case .UnsetBinding:
		return UnsetKeyBinding(inp.Scancode(cmd.sc), cmd.mods)
	case .BindingsGet:
		if out != nil {
			kb := GetKeyBindings()
			if kb.count == 0 {
				out("(no bindings)")
			}
			for i in 0 ..< kb.count {
				b := &kb.bindings[i]
				combo : [64]u8
				sub_buf : [256]u8
				sub := FormatCommand(b.cmd, sub_buf[:])
				out(fmt.tprintf("bind %s \"%s\"", comboName(b.mods, b.key, &combo), sub))
			}
		}
		return true

	// ---- 帮助 ----
	case .Help:
		if out == nil {
			return true
		}
		if cmd.sval != "" {
			spec := findSpec(cmd.sval)
			if spec == nil {
				return false
			}
			out(fmt.tprintf("%s %s  — %s", spec.name, spec.usage, spec.help))
			return true
		}
		for i in 0 ..< len(COMMAND_SPECS) {
			s := &COMMAND_SPECS[i]
			out(fmt.tprintf("%s %s", s.name, s.usage))
		}
		out("help <命令> 查看单条说明")
		return true
	}
	return false
}

// 焦点(或 target)窗格 console 的行数;无 console 返回 0(翻页/滚动安全空转)
focusRows :: proc(target : mem.Handle) -> int {
	node_h := target
	if node_h.id == 0 {
		node_h = cv.GetFocusWindow()
	}
	console := cv.NodeConsole(node_h)
	if console == nil {
		return 0
	}
	return int(console.rows)
}

// ---------------------------------------------------------------------------
// 解析(表驱动)
// ---------------------------------------------------------------------------
// 把命令字符串解析为 ParsedCommand;字符串字段借用 s 内存(调用方保证 s 存活于本次调用)。
// 失败原因写入 errbuf(借用调用方缓冲,仅本次调用有效);errbuf 空 = 只给 bool 语义。
ParseCommandStringEx :: proc(s : string, errbuf : []u8) -> (pc : ParsedCommand, err : string, ok : bool) {
	trimmed := strings.trim_space(s)
	if len(trimmed) == 0 {
		return {}, errText(errbuf, "空命令", ""), false
	}
	tokens : [MAX_CMD_TOKENS]string
	n, overflow := parseTokens(trimmed, &tokens)
	if n == 0 {
		return {}, errText(errbuf, "空命令", ""), false
	}
	if overflow {
		return {}, errText(errbuf, "参数过多", ""), false
	}
	spec := findSpec(tokens[0])
	if spec == nil {
		return {}, errText(errbuf, "未知命令", tokens[0]), false
	}

	// 末尾 @id(仅窗口类命令)
	argn := n - 1
	if argn >= 1 && len(tokens[n - 1]) > 0 && tokens[n - 1][0] == '@' {
		if !spec.target {
			return {}, usageText(errbuf, spec, "@id 不支持"), false
		}
		id, id_ok := parseU32(tokens[n - 1][1:])
		if !id_ok {
			return {}, usageText(errbuf, spec, "@id 需要数字"), false
		}
		pc.target = cv.NodeHandleById(id)
		argn -= 1
	}
	if argn > MAX_CMD_ARGS {
		return {}, usageText(errbuf, spec, "参数过多"), false
	}
	if argn < int(spec.req) {
		return {}, usageText(errbuf, spec, "参数不足"), false
	}

	pc.kind = spec.kind
	str_seen := 0
	for i in 0 ..< argn {
		tok := tokens[1 + i]
		switch spec.args[i] {
		case .None:
			return {}, usageText(errbuf, spec, "参数过多"), false
		case .Str:
			// font 单数字参数 = 只改字号(等价 fontsize;DESIGN 兼容写法)
			size_only := false
			if spec.kind == .Font && argn == 1 {
				if v, vok := parseF32(tok); vok {
					pc.kind = .FontSize
					pc.fval = v
					size_only = true
				}
			}
			if !size_only {
				if str_seen == 0 {
					pc.sval = tok
				} else {
					pc.sval2 = tok
				}
				str_seen += 1
			}
		case .F32:
			v, vok := parseF32(tok)
			if !vok {
				return {}, usageText(errbuf, spec, "需要数字"), false
			}
			pc.fval = v
		case .I32:
			v, vok := parseU32(tok)
			if !vok {
				return {}, usageText(errbuf, spec, "需要整数"), false
			}
			pc.ival = int(v)
		case .Toggle:
			v, vok := parseToggle(tok)
			if !vok {
				return {}, usageText(errbuf, spec, "需要 on/off"), false
			}
			pc.mode = v
		case .SplitDir:
			dir, first, dok := parseSplitDir(tok)
			if !dok {
				return {}, usageText(errbuf, spec, "需要 right/left/up/down"), false
			}
			pc.dir = dir
			pc.split_first = first
		case .FocusArg:
			if id, idok := parseU32(tok); idok {
				pc.kind = .FocusId
				pc.target = cv.NodeHandleById(id)
			} else if d, dok := parseFocusDir(tok); dok {
				pc.kind = .FocusDir
				pc.fdir = d
			} else {
				return {}, usageText(errbuf, spec, "需要 id 或方向"), false
			}
		case .KeyCombo:
			key, mods, kok := parseKeyCombo(tok)
			if !kok {
				return {}, usageText(errbuf, spec, "键组合非法"), false
			}
			pc.sc = u32(key)
			pc.mods = mods
		case .ThemeField:
			fspec, fok := cv.ThemeFieldByName(tok)
			if !fok {
				return {}, usageText(errbuf, spec, "未知字段"), false
			}
			pc.tfield = fspec.field
			pc.tindex = fspec.index
		case .Color:
			c, cok := parseColor(tok)
			if !cok {
				return {}, usageText(errbuf, spec, "需要 #RRGGBB"), false
			}
			pc.color = c
		case .SubCommand:
			sub, sub_err, sub_ok := ParseCommandStringEx(tok, errbuf)
			if !sub_ok {
				return {}, sub_err, false
			}
			if sub.kind == .SetBinding || sub.kind == .UnsetBinding || sub.kind == .Help {
				return {}, usageText(errbuf, spec, "子命令不能是 bind/unbind/help"), false
			}
			sub_h := mem.Alloc(&sub_commands, sub)
			if sub_h.id == 0 {
				return {}, errText(errbuf, "子命令表满", spec.name), false
			}
			pc.sub = sub_h
		}
	}
	// font 给了字体名却没给字号
	if pc.kind == .Font && argn < 2 {
		return {}, usageText(errbuf, spec, "需要字号"), false
	}
	return pc, "", true
}

// 只判成败的解析(探针/内部用;原因见 ParseCommandStringEx)
ParseCommandString :: proc(s : string) -> (ParsedCommand, bool) {
	pc, _, ok := ParseCommandStringEx(s, nil)
	return pc, ok
}

// 释放解析期分配的附随资源(子命令槽)。ExecuteCommandString 内部已处理;
// 直接调 ParseCommandString 的调用者必须对结果调用本函数(避免槽泄漏)。
FreeParsedCommand :: proc(cmd : ParsedCommand) {
	if cmd.sub.id != 0 {
		mem.Free(&sub_commands, cmd.sub)
	}
}

// ---------------------------------------------------------------------------
// 格式化(逆变换:与解析共用 COMMAND_SPECS)
// ---------------------------------------------------------------------------
// 命令数据 → 可再解析的字符串(写入 buf,返回切片;缓冲不足则截断)。
// 省略规则与解析的缺省语义一致:数值 0 / 空字符串 / mode=.Toggle 不输出。
FormatCommand :: proc(cmd : ParsedCommand, buf : []u8) -> string {
	n := 0
	spec := specForKind(cmd.kind)
	if spec == nil {
		cat(buf, &n, "?")
		return string(buf[:n])
	}
	cat(buf, &n, spec.name)
	str_seen := 0
	arg_loop: for i in 0 ..< MAX_CMD_ARGS {
		switch spec.args[i] {
		case .None:
			break arg_loop
		case .Str:
			// 第二个 Str 参数取 sval2(DefaultLaunch 的字体名)
			s := str_seen == 0 ? cmd.sval : cmd.sval2
			if s == "" {
				break arg_loop
			}
			str_seen += 1
			cat(buf, &n, " ")
			quote(buf, &n, s)
		case .F32:
			if cmd.fval == 0 {
				break arg_loop
			}
			tmp : [32]u8
			cat(buf, &n, " ")
			cat(buf, &n, fmt.bprintf(tmp[:], "%v", cmd.fval))
		case .I32:
			if cmd.ival == 0 {
				break arg_loop
			}
			tmp : [32]u8
			cat(buf, &n, " ")
			cat(buf, &n, fmt.bprintf(tmp[:], "%d", cmd.ival))
		case .Toggle:
			switch cmd.mode {
			case .On:
				cat(buf, &n, " on")
			case .Off:
				cat(buf, &n, " off")
			case .Toggle:
			}
		case .SplitDir:
			cat(buf, &n, " ")
			cat(buf, &n, splitDirName(cmd.dir, cmd.split_first))
		case .FocusArg:
			cat(buf, &n, " ")
			if cmd.kind == .FocusId {
				tmp : [32]u8
				cat(buf, &n, fmt.bprintf(tmp[:], "%d", cmd.target.id))
			} else {
				cat(buf, &n, focusDirName(cmd.fdir))
			}
		case .KeyCombo:
			combo : [64]u8
			cat(buf, &n, " ")
			cat(buf, &n, comboName(cmd.mods, inp.Scancode(cmd.sc), &combo))
		case .ThemeField:
			cat(buf, &n, " ")
			cat(buf, &n, cv.ThemeFieldName(cmd.tfield, cmd.tindex))
		case .Color:
			cbuf : [8]u8
			cat(buf, &n, " ")
			cat(buf, &n, formatColor(&cbuf, cmd.color))
		case .SubCommand:
			sub := mem.Get(&sub_commands, cmd.sub)
			if sub == nil {
				break arg_loop
			}
			sub_buf : [256]u8
			cat(buf, &n, " ")
			quote(buf, &n, FormatCommand(sub^, sub_buf[:]))
		}
	}
	// @id(FocusId 的 id 已在参数位)
	if cmd.target.id != 0 && cmd.kind != .FocusId {
		tmp : [32]u8
		cat(buf, &n, " ")
		cat(buf, &n, fmt.bprintf(tmp[:], "@%d", cmd.target.id))
	}
	return string(buf[:n])
}

// 缓冲区追加(截断即止)
cat :: proc(buf : []u8, n : ^int, s : string) {
	if n^ >= len(buf) || len(s) == 0 {
		return
	}
	m := min(len(s), len(buf) - n^)
	copy(buf[n^:], s[:m])
	n^ += m
}

quote :: proc(buf : []u8, n : ^int, s : string) {
	cat(buf, n, "\"")
	cat(buf, n, s)
	cat(buf, n, "\"")
}

splitDirName :: proc(dir : cv.SplitType, first : bool) -> string {
	switch dir {
	case .LeftRight:
		return first ? "left" : "right"
	case .UpDown:
		return first ? "up" : "down"
	}
	return "right"
}

focusDirName :: proc(dir : cv.FocusDirection) -> string {
	switch dir {
	case .Left:
		return "left"
	case .Right:
		return "right"
	case .Up:
		return "up"
	case .Down:
		return "down"
	}
	return "left"
}

// ---------------------------------------------------------------------------
// 词法 / 参数解析
// ---------------------------------------------------------------------------
// 拆分参数:支持 "..." 字符串;返回 tokens(借用 s 内存)与是否溢出(超出即报错)
parseTokens :: proc(s : string, tokens : ^[MAX_CMD_TOKENS]string) -> (count : int, overflow : bool) {
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i += 1
		}
		if i >= len(s) {
			break
		}
		if s[i] == '"' {
			start := i + 1
			j := start
			for j < len(s) && s[j] != '"' {
				j += 1
			}
			if count < len(tokens^) {
				tokens[count] = s[start:j]
				count += 1
			} else {
				overflow = true
			}
			i = j + 1
		} else {
			start := i
			for i < len(s) && s[i] != ' ' && s[i] != '\t' {
				i += 1
			}
			if count < len(tokens^) {
				tokens[count] = s[start:i]
				count += 1
			} else {
				overflow = true
			}
		}
	}
	return
}

// "mods+key" → scancode + 修饰;键名 = 最后一段(大小写不敏感),
// mods 段 = alt/ctrl/shift/win(可零个,可重复出现)
parseKeyCombo :: proc(s : string) -> (key : inp.Scancode, mods : KeyMods, ok : bool) {
	if len(s) == 0 {
		return {}, {}, false
	}
	key_start := 0
	for i in 0 ..< len(s) {
		if s[i] == '+' {
			key_start = i + 1
		}
	}
	if key_start >= len(s) {
		return {}, {}, false
	}
	key, ok = inp.ScancodeFromName(s[key_start:])
	if !ok {
		return {}, {}, false
	}
	if key_start == 0 {
		return key, {}, true // 无修饰
	}
	mod_part := s[:key_start - 1]
	start := 0
	for i in 0 ..= len(mod_part) {
		if i == len(mod_part) || mod_part[i] == '+' {
			switch mod_part[start:i] {
			case "alt": mods += {.Alt}
			case "ctrl", "ctl": mods += {.Ctrl}
			case "shift": mods += {.Shift}
			case "win", "super": mods += {.Win}
			case: return {}, {}, false
			}
			start = i + 1
		}
	}
	return key, mods, true
}

// 修饰 → 字符串前缀("alt+shift+";空修饰 = "";借用调用方缓冲,仅调用期间有效)
modsPrefix :: proc(mods : KeyMods, buf : ^[32]u8) -> string {
	if mods == {} {
		return ""
	}
	n := 0
	if .Alt in mods {
		copy(buf[n:], "alt+")
		n += 4
	}
	if .Ctrl in mods {
		copy(buf[n:], "ctrl+")
		n += 5
	}
	if .Shift in mods {
		copy(buf[n:], "shift+")
		n += 6
	}
	if .Win in mods {
		copy(buf[n:], "win+")
		n += 4
	}
	return string(buf[:n])
}

// 键组合显示名("alt+shift+l";借用调用方缓冲,仅调用期间有效)
comboName :: proc(mods : KeyMods, key : inp.Scancode, buf : ^[64]u8) -> string {
	n := len(modsPrefix(mods, cast(^[32]u8)buf))
	kname := inp.ScancodeName(key)
	if n + len(kname) < len(buf) {
		copy(buf[n:], kname)
		n += len(kname)
	}
	return string(buf[:n])
}

parseU32 :: proc(s : string) -> (u32, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v : u32
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + u32(c - '0')
	}
	return v, true
}

parseF32 :: proc(s : string) -> (f32, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	start := 0
	if s[0] == '-' {
		neg = true
		start = 1
	}
	int_part : f32
	frac_part : f32
	frac_scale : f32 = 0.1
	seen_digit := false
	seen_dot := false
	for i in start ..< len(s) {
		c := s[i]
		if c == '.' && !seen_dot {
			seen_dot = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		seen_digit = true
		if !seen_dot {
			int_part = int_part * 10 + f32(c - '0')
		} else {
			frac_part += f32(c - '0') * frac_scale
			frac_scale *= 0.1
		}
	}
	if !seen_digit {
		return 0, false
	}
	v := int_part + frac_part
	if neg {
		v = -v
	}
	return v, true
}

// 颜色:"#RRGGBB" / "RRGGBB" / "0xRRGGBB" → 24bit RGB(大小写不敏感)
parseColor :: proc(s : string) -> (u32, bool) {
	t := s
	if len(t) >= 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X') {
		t = t[2:]
	} else if len(t) >= 1 && t[0] == '#' {
		t = t[1:]
	}
	if len(t) != 6 {
		return 0, false
	}
	v : u32
	for i in 0 ..< 6 {
		c := t[i]
		d : u32
		switch {
		case c >= '0' && c <= '9':
			d = u32(c - '0')
		case c >= 'a' && c <= 'f':
			d = u32(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			d = u32(c - 'A') + 10
		case:
			return 0, false
		}
		v = (v << 4) | d
	}
	return v, true
}

// 颜色 → "#RRGGBB"(借用调用方缓冲,仅调用期间有效)
formatColor :: proc(buf : ^[8]u8, c : u32) -> string {
	hex := "0123456789ABCDEF"
	buf[0] = '#'
	for i in 0 ..< 6 {
		buf[1 + i] = hex[(c >> u32((5 - i) * 4)) & 0xF]
	}
	return string(buf[:7])
}

parseToggle :: proc(s : string) -> (ToggleMode, bool) {
	switch {
	case nameEq(s, "on"), nameEq(s, "true"), s == "1":
		return .On, true
	case nameEq(s, "off"), nameEq(s, "false"), s == "0":
		return .Off, true
	}
	return .Toggle, false
}

// split 方向词 → (轴, 新窗在首侧(左/上), ok)。left/up = 新窗在首侧。
parseSplitDir :: proc(s : string) -> (cv.SplitType, bool, bool) {
	switch {
	case nameEq(s, "right"), nameEq(s, "leftright"), nameEq(s, "h"):
		return .LeftRight, false, true
	case nameEq(s, "left"):
		return .LeftRight, true, true
	case nameEq(s, "down"), nameEq(s, "updown"), nameEq(s, "v"):
		return .UpDown, false, true
	case nameEq(s, "up"):
		return .UpDown, true, true
	}
	return {}, false, false
}

parseFocusDir :: proc(s : string) -> (cv.FocusDirection, bool) {
	switch {
	case nameEq(s, "left"):
		return .Left, true
	case nameEq(s, "right"):
		return .Right, true
	case nameEq(s, "up"):
		return .Up, true
	case nameEq(s, "down"):
		return .Down, true
	}
	return {}, false
}

// 失败原因:静态字面量或写入 errbuf(借用调用方缓冲,仅本次调用有效)
errText :: proc(errbuf : []u8, msg, detail : string) -> string {
	if len(errbuf) == 0 {
		return msg
	}
	if detail == "" {
		return fmt.bprintf(errbuf, "%s", msg)
	}
	return fmt.bprintf(errbuf, "%s: %s", msg, detail)
}

// 用法错误:统一 "命令: 原因(用法: 命令 <参数>)"
usageText :: proc(errbuf : []u8, spec : ^CommandSpec, why : string) -> string {
	if len(errbuf) == 0 {
		return why
	}
	if spec.usage == "" {
		return fmt.bprintf(errbuf, "%s: %s", spec.name, why)
	}
	return fmt.bprintf(errbuf, "%s: %s(用法: %s %s)", spec.name, why, spec.name, spec.usage)
}
