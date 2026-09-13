// 窗格内容实体:Console(视口几何 + 会话 + 字体集 + VT 状态)。
// 唯一拥有者 = leaf 树节点(TreeNode.console_id);节点销毁 → DestroyConsole(字体/会话/缓冲一并释放)。
// 空窗格 = 节点无 console(懒创建:设字体或启动会话时经 ensureConsole 建)。
// 生命周期 + 布局(居中取整/review 锚定换算/视口顶行公式)归本文件。
package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"
import "core:math"
import "core:strings"

// ---------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------
// 容量依据:一个 leaf 窗格恰持一个 console(含空窗格);64 = 单屏实际可用的分屏上限,
// 主屏 + 交替屏各占一个 buffer 槽(见 buffer.odin 的 MAX_TERM_BUFFER_SLOTS)
MAX_CONSOLE_SLOTS :: 64

MAX_BUFFERS_PER_CONSOLE :: 8

Console :: struct {
	rows, cols : u16, // 目标网格尺寸(布局趟真源,每帧由窗口几何重算)
	pty_rows, pty_cols : u16, // ConPTY 已应用尺寸(尺寸应用趟与 rows/cols 比较判变化)
	origin_x, origin_y : f32, // 居中后网格左上角(内容区坐标空间);每帧由 ConsoleUpdateLayout 重算
	cursor_row, cursor_col : u16, // 指向 active buffer 的物理行

	// 输入识别态(草稿纸)与终端语义态:两个平级组件,分别见 vtparse.odin / vt.odin
	parser : Parser,
	vt : VtState,

	term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle, // ids[0] = 主屏
	term_buffer_count : u32,
	active_term_buffer_id : mem.Handle, // 当前渲染/写入的页;0 = 未登记

	conpty_handle : mem.Handle, // 绑定的 ConPTY;0 = 无会话(空窗格/工具 console)

	// 字体集(引用计数持有者 = 本结构):主字体 + Bold/Italic/BoldItalic 变体
	// (变体 0 = 无此 face,渲染走合成兜底);font_input 留存原始输入名(字号重载/继承)
	font_id : mem.Handle,
	font_bold : mem.Handle,
	font_italic : mem.Handle,
	font_bold_italic : mem.Handle,
	font_input : string,

	input_activity_ms : u64, // 最近用户输入活动时刻(FeedConsole 唯一写点;
	// render 用于"输入期间光标不闪烁"判定;0 = 从未输入)

	// 应用侧状态(OSC 唯一写点;渲染只读;字符串所有权 = 本结构):
	//   app_title → OS 窗口标题显示它(tabbar 仍用 Page.title,互不覆盖)
	//   cwd       → 该会话最后报告的工作目录(OSC 7;新会话继承它)
	app_title : string,
	cwd : string,
}

// ---------------------------------------------------------------------------
// 配置默认工作目录(命令 `cwd` 写):没有任何会话报告过目录时的兜底。
// 真正的目录记忆在各 Console.cwd —— 全局单值会被 shell 每次提示符的 OSC 7
// 上报打回原形(每个提示符都发),所以它只当"配置默认值"用。
// ---------------------------------------------------------------------------
session_cwd : string

GetSessionCwd :: proc() -> string {
	return session_cwd
}

// 配置默认目录的唯一写点(命令 `cwd`);入参经形态归一(msys2 的 /c/... → C:\...)
SetSessionCwd :: proc(path : string) {
	norm : [CWD_MAX]u8
	m := cwdNormalize(path, norm[:])
	if session_cwd != "" {
		delete(session_cwd)
		session_cwd = ""
	}
	if m > 0 {
		session_cwd = strings.clone(string(norm[:m]))
	}
}

// 某会话报告的工作目录(OSC 7 唯一写点;空 = 清除)
SetConsoleCwd :: proc(console_h : mem.Handle, path : string) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	if console.cwd != "" {
		delete(console.cwd)
		console.cwd = ""
	}
	if len(path) == 0 {
		return
	}
	norm : [CWD_MAX]u8
	m := cwdNormalize(path, norm[:])
	if m > 0 {
		console.cwd = strings.clone(string(norm[:m]))
	}
}

consoles : mem.GenArray(MAX_CONSOLE_SLOTS, Console)

// 自动建主屏 TermBuffer;绑定 conpty_handle(0 = 工具/空窗格 console,无会话)。
CreateConsole :: proc(rows, cols : u16, conpty_handle : mem.Handle = {}) -> (h : mem.Handle, ok : bool) {
	if rows == 0 || cols == 0 {
		return {}, false
	}
	if conpty_handle.id != 0 && ct.GetConptyContext(conpty_handle) == nil {
		return {}, false
	}
	h = mem.Alloc(&consoles, Console {})
	if h.id == 0 {
		return {}, false
	}
	if !consoleInitSession(h, rows, cols, conpty_handle) {
		mem.Free(&consoles, h)
		return {}, false
	}
	return h, true
}

GetConsole :: proc(h : mem.Handle) -> ^Console {
	return mem.Get(&consoles, h)
}

// 取 leaf 节点挂载的 console;空窗格/内部节点返回 nil
NodeConsole :: proc(node_h : mem.Handle) -> ^Console {
	return GetConsole(NodeConsoleId(node_h))
}

// 节点挂载的 console 句柄(0 = 空窗格/内部节点/节点不存在)
NodeConsoleId :: proc(node_h : mem.Handle) -> mem.Handle {
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return {}
	}
	return node.console_id
}

// 取节点挂载的 console;无则创建(conpty = 0,内容容器)并挂载(仅 leaf)
ensureConsole :: proc(node_h : mem.Handle) -> ^Console {
	if console := NodeConsole(node_h); console != nil {
		return console
	}
	if NodeConsoleId(node_h).id != 0 {
		return nil // 句柄存在但槽失效:不重复挂载(下次访问自愈)
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return nil
	}
	console_h, ok := CreateConsole(24, 80, {})
	if !ok {
		return nil
	}
	if !TreeNodeSetConsole(node_h, console_h) {
		DestroyConsole(console_h)
		return nil
	}
	return GetConsole(console_h)
}

// 销毁 console 本体:字体集引用 + 会话(读线程 + ConPTY)+ 全部 buffer。
// 唯一拥有者 = leaf 节点;节点销毁路径调本函数后摘除节点。
DestroyConsole :: proc(h : mem.Handle) {
	console := GetConsole(h)
	if console == nil {
		return
	}
	releaseConsoleFontSet(console)
	releaseConsoleAppState(console)
	ct.StopReadThread(console.conpty_handle) // 句柄无效 = no-op
	ct.DestroyConpty(console.conpty_handle)
	for i in 0 ..< int(console.term_buffer_count) {
		DestroyTermBuffer(console.term_buffer_ids[i])
	}
	mem.Free(&consoles, h)
}

// 给已存在的 console 绑定会话(先设字体后 launch 的路径):重置内容 + 绑 conpty
consoleStartSession :: proc(console_h : mem.Handle, conpty_handle : mem.Handle, rows, cols : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	if conpty_handle.id != 0 && ct.GetConptyContext(conpty_handle) == nil {
		return false
	}
	ct.StopReadThread(console.conpty_handle)
	ct.DestroyConpty(console.conpty_handle)
	return consoleInitSession(console_h, rows, cols, conpty_handle)
}

// 清会话:销毁 conpty + 全部 buffer + 重置 VT 状态;保留 console 本体与字体
consoleClearSession :: proc(console_h : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	ct.StopReadThread(console.conpty_handle)
	ct.DestroyConpty(console.conpty_handle)
	for i in 0 ..< int(console.term_buffer_count) {
		DestroyTermBuffer(console.term_buffer_ids[i])
	}
	console.term_buffer_ids = {}
	console.term_buffer_count = 0
	console.active_term_buffer_id = {}
	console.conpty_handle = {}
	console.parser = Parser {}
	console.vt = VtState {}
	console.cursor_row, console.cursor_col = 0, 0
	releaseConsoleAppState(console) // 会话没了:应用标题/目录一并失效
	return true
}

// 会话初始化(建 console 与复用 console 共用):重置视口/解析状态 + 建主屏 + 绑 conpty。
// 失败时 console 处于"无 buffer"空态(调用方负责销毁或重试)。
consoleInitSession :: proc(console_h : mem.Handle, rows, cols : u16, conpty_handle : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb_h, tb_ok := CreateTermBuffer()
	if !tb_ok {
		return false
	}
	console.rows = rows
	console.cols = cols
	console.pty_rows = rows // 初始 = ConPTY 创建尺寸(80x24),与传入一致
	console.pty_cols = cols
	console.cursor_row, console.cursor_col = 0, 0
	console.conpty_handle = conpty_handle
	console.term_buffer_ids = {}
	console.term_buffer_count = 0
	console.active_term_buffer_id = {}
	releaseConsoleAppState(console) // 新会话:应用标题/目录重新积累
	console.parser = Parser {} // 草稿纸清零:状态机的初值就是零值
	console.vt = VtState {
		autowrap = true,
		cursor_visible = true,
		scroll_bottom = rows - 1,
		style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR },
	}
	if !ConsoleAttachTermBuffer(console_h, tb_h) {
		DestroyTermBuffer(tb_h)
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// 字体集(引用计数;console 是唯一持有者)
// ---------------------------------------------------------------------------
// 释放字体引用集(主 + 3 变体;各自引用计数归零即可复用)+ 输入名
releaseConsoleFontSet :: proc(console : ^Console) {
	if console.font_id.id != 0 {
		fnt.ReleaseFont(console.font_id)
		console.font_id = {}
	}
	if console.font_bold.id != 0 {
		fnt.ReleaseFont(console.font_bold)
		console.font_bold = {}
	}
	if console.font_italic.id != 0 {
		fnt.ReleaseFont(console.font_italic)
		console.font_italic = {}
	}
	if console.font_bold_italic.id != 0 {
		fnt.ReleaseFont(console.font_bold_italic)
		console.font_bold_italic = {}
	}
	if console.font_input != "" {
		delete(console.font_input)
		console.font_input = ""
	}
}

// 释放应用侧状态(OSC 设置的标题 / 工作目录);重复调用无害
releaseConsoleAppState :: proc(console : ^Console) {
	if console.app_title != "" {
		delete(console.app_title)
		console.app_title = ""
	}
	if console.cwd != "" {
		delete(console.cwd)
		console.cwd = ""
	}
}

// 继承另一 console 的完整字体集(split 承载新会话;引用 ×4 + 输入名 clone)
inheritConsoleFontSet :: proc(dst, src : ^Console) {
	if src.font_id.id != 0 {
		dst.font_id = src.font_id
		fnt.RetainFont(src.font_id)
	}
	if src.font_bold.id != 0 {
		dst.font_bold = src.font_bold
		fnt.RetainFont(src.font_bold)
	}
	if src.font_italic.id != 0 {
		dst.font_italic = src.font_italic
		fnt.RetainFont(src.font_italic)
	}
	if src.font_bold_italic.id != 0 {
		dst.font_bold_italic = src.font_bold_italic
		fnt.RetainFont(src.font_bold_italic)
	}
	if src.font_input != "" {
		dst.font_input = strings.clone(src.font_input)
	}
}

// 渲染查询:style(bold/italic)→ 变体字体句柄 + 各维度"合成兜底"标志。
// 变体存在 = 真 face(不再合成);不存在 = 主字体 + 渲染层按标志兜底
// (bold_syn → 双描,italic_syn → 斜切)。
ConsoleFontVariant :: proc(console_h : mem.Handle, bold, italic : bool) -> (fh : mem.Handle, bold_syn, italic_syn : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return {}, true, true
	}
	switch {
	case bold && italic:
		if console.font_bold_italic.id != 0 {
			return console.font_bold_italic, false, false
		}
		if console.font_bold.id != 0 {
			return console.font_bold, false, true
		}
		if console.font_italic.id != 0 {
			return console.font_italic, true, false
		}
		return console.font_id, true, true
	case bold:
		if console.font_bold.id != 0 {
			return console.font_bold, false, false
		}
		return console.font_id, true, false
	case italic:
		if console.font_italic.id != 0 {
			return console.font_italic, false, false
		}
		return console.font_id, false, true
	}
	return console.font_id, false, false
}

// ---------------------------------------------------------------------------
// Console 操作
// ---------------------------------------------------------------------------
// 登记一个 TermBuffer 并设为当前渲染目标;重复登记只切换不新增
ConsoleAttachTermBuffer :: proc(console_h, term_buffer_h : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	if GetTermBuffer(term_buffer_h) == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_h {
			console.active_term_buffer_id = term_buffer_h
			return true
		}
	}
	if console.term_buffer_count >= MAX_BUFFERS_PER_CONSOLE {
		return false
	}
	console.term_buffer_ids[console.term_buffer_count] = term_buffer_h
	console.term_buffer_count += 1
	console.active_term_buffer_id = term_buffer_h
	return true
}

// 在已登记的 TermBuffer 间切换(1049 交替屏);未登记的 id 拒绝
ConsoleActivateTermBuffer :: proc(console_h, term_buffer_h : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_h {
			console.active_term_buffer_id = term_buffer_h
			return true
		}
	}
	return false
}

// 视口顶行(物理索引):普通 = 贴底;review = 锚定 review_line(底行)上推 rows 行。
// 渲染/光标应答/resize 共用一个公式,勿在别处重写。
viewportTop :: proc(console : ^Console, tb : ^TermBuffer) -> int {
	if tb.review_line == 0 {
		return max(0, len(tb.lines) - int(console.rows))
	}
	top := int(tb.review_line) - 1 - (int(console.rows) - 1)
	return max(0, top)
}

// 改网格尺寸的副作用:cursor_col/滚动区下限 clamp + review 视口锚定补偿。
// 锚定规则(同 alacritty):普通(贴底)保持贴底;review 保持视口内容(顶行)不动。
// 注意:cursor_row 是物理行索引(指向 lines,可 > rows),不能按屏幕行 clamp。
applyConsoleSize :: proc(console : ^Console, rows, cols : u16) {
	tb := GetTermBuffer(console.active_term_buffer_id)
	visible_top_before := 0
	if tb != nil {
		visible_top_before = viewportTop(console, tb)
	}

	console.rows, console.cols = rows, cols
	console.cursor_col = min(console.cursor_col, cols - 1)
	console.vt.scroll_bottom = rows - 1
	console.vt.wrap_pending = false

	// review 中:按"顶行不变"重定 review_line(底行随 rows 平移;内容不被拽走)
	if tb != nil && tb.review_line != 0 {
		nl := visible_top_before + int(rows) - 1 // 新底行索引
		if nl >= len(tb.lines) - 1 {
			tb.review_line = 0 // 到底 = 回到普通
		} else {
			tb.review_line = u32(nl + 1)
		}
	}
}

// Resize 时先改 ConPTY 再改这里;已有行不截断
ConsoleSetSize :: proc(console_h : mem.Handle, rows, cols : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil || rows == 0 || cols == 0 {
		return false
	}
	applyConsoleSize(console, rows, cols)
	return true
}

ConsoleUpdateLayout :: proc(console_h : mem.Handle, t : Transform, cell_w, cell_h : f32) -> bool {
	console := GetConsole(console_h)

	if console == nil || cell_w <= 0 || cell_h <= 0 {
		return false
	}

	rows := max(1, int(t.height / cell_h))
	cols := max(1, int(t.width / cell_w))

	if console.vt.deccolm {
		cols = 132 // DECCOLM 132 列模式覆盖布局计算
	}
	applyConsoleSize(console, u16(rows), u16(cols))

	if console.vt.deccolm {
		console.origin_x = t.position_x // 132 列超出窗口:左对齐
	} else {
		console.origin_x = t.position_x + (t.width - f32(cols) * cell_w) * 0.5
	}

	console.origin_y = t.position_y + (t.height - f32(rows) * cell_h) * 0.5
	// 网格起点取整到像素:origin 带 .5 时背景矩形与字形(各自取整)会错位 1px
	console.origin_x = math.round(console.origin_x)
	console.origin_y = math.round(console.origin_y)
	return true
}

ConsoleSetCursor :: proc(console_h : mem.Handle, row, col : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	console.cursor_row = min(row, console.rows - 1)
	console.cursor_col = min(col, console.cols - 1)
	return true
}

// 历史视口查询(渲染/应答共用公式入口):返回顶行物理索引 + 是否在 review
ConsoleViewportTop :: proc(console_h : mem.Handle) -> (top : int, in_review : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return 0, false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return 0, false
	}
	return viewportTop(console, tb), tb.review_line != 0
}

// ---------------------------------------------------------------------------
// 写路径
// ---------------------------------------------------------------------------
// 当前屏幕(底部 rows 行)在 lines 里的物理起始行;len <= rows 时为 0(顶部锚定)
screenBase :: proc(console : ^Console, tb : ^TermBuffer) -> int {
	return max(0, len(tb.lines) - int(console.rows))
}

