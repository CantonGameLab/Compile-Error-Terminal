// 视口层数据:Console(行列/光标/活跃缓冲/vt 状态/布局几何)。
// 生命周期 + 布局(居中取整/review 锚定换算/视口顶行公式)归本文件。
package canvas

import ct "../conpty"
import mem "../memory"
import "core:math"

// ---------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------
MAX_CONSOLE_SLOTS :: 32

MAX_BUFFERS_PER_CONSOLE :: 8

Console :: struct {
	rows, cols : u16, // 目标网格尺寸(布局趟真源,每帧由窗口几何重算)
	pty_rows, pty_cols : u16, // ConPTY 已应用尺寸(尺寸应用趟与 rows/cols 比较判变化)
	origin_x, origin_y : f32, // 居中后网格左上角(内容区坐标空间);每帧由 ConsoleUpdateLayout 重算
	cursor_row, cursor_col : u16, // 指向 active buffer 的物理行

	vt : VtState,

	term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle, // ids[0] = 主屏
	term_buffer_count : u32,
	active_term_buffer_id : mem.Handle, // 当前渲染/写入的页;0 = 未登记

	conpty_handle : mem.Handle, // 绑定的 ConPTY

	font_size : f32, // 创建时的目标字号

	input_activity_ms : u64, // 最近用户输入活动时刻(FeedConsole 唯一写点;
	// render 用于"输入期间光标不闪烁"判定;0 = 从未输入)
}

consoles : mem.GenArray(MAX_CONSOLE_SLOTS, Console)

// 自动建主屏 TermBuffer;绑定 conpty_handle。
// conpty = 0 = 工具 console(无会话:输入路径 WriteConptyInput 为空操作,轮询跳过)。
CreateConsole :: proc(rows, cols : u16, conpty_handle : mem.Handle) -> (h : mem.Handle, ok : bool) {
	if rows == 0 || cols == 0 {
		return {}, false
	}
	if conpty_handle.id != 0 && ct.GetConptyContext(conpty_handle) == nil {
		return {}, false
	}
	tb_h, tb_ok := CreateTermBuffer()
	if !tb_ok {
		return {}, false
	}
	console := Console {
		rows = rows,
		cols = cols,
		pty_rows = rows, // 初始 = ConPTY 创建尺寸(80x24),与传入一致
		pty_cols = cols,
		conpty_handle = conpty_handle,
	}
	console.vt = VtState {
		autowrap = true,
		cursor_visible = true,
		scroll_bottom = rows - 1,
		style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR },
	}
	h = mem.Alloc(&consoles, console)
	if h.id == 0 {
		DestroyTermBuffer(tb_h)
		return {}, false
	}
	// 解析器回调绑定(user_data 存句柄供回调取回)
	Init(&GetConsole(h).vt.parser, vtParserCallback)
	GetConsole(h).vt.parser.user_data = packHandle(h)
	if !ConsoleAttachTermBuffer(h, tb_h) {
		DestroyTermBuffer(tb_h)
		mem.Free(&consoles, h)
		return {}, false
	}
	return h, true
}

GetConsole :: proc(h : mem.Handle) -> ^Console {
	return mem.Get(&consoles, h)
}

// 销毁 console 本体:会话(读线程 + ConPTY)+ 视口。
// 唯一拥有者 = 窗口(console_id);窗口销毁路径先调本函数再 DestroyWindowSlot。
DestroyConsole :: proc(h : mem.Handle) {
	console := GetConsole(h)
	if console == nil {
		return
	}
	ct.StopReadThread(console.conpty_handle) // 句柄无效 = no-op
	ct.DestroyConpty(console.conpty_handle)
	for i in 0 ..< int(console.term_buffer_count) {
		DestroyTermBuffer(console.term_buffer_ids[i])
	}
	mem.Free(&consoles, h)
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

