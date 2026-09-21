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
	resize_retry : u32, // 尺寸应用连续失败次数(0 = 上一帧成功);仅用于日志去重,失败即重试
	origin_x, origin_y : f32, // 居中后网格左上角(内容区坐标空间);每帧由 ConsoleUpdateLayout 重算
	cursor_row, cursor_col : u16, // **屏幕坐标**:行 0..rows-1、列 0..cols-1(VT 状态的地址空间)

	// 输入识别态(草稿纸)与终端语义态:两个平级组件,分别见 vtparse.odin / vt.odin
	parser : Parser,
	vt : VtState,

	// OSC 命令信道(见 commandpipe.odin):持有 poll 句柄即"已授权"(0 = 未授权,
	// 999 当未知 OSC 忽略)。授权 = 命令 `osc on|off` 的建/销;会话重建即失效,
	// 所以换程序必然重新授权(释放点:consoleInitSession / consoleClearSession /
	// DestroyConsole 三处,少一处就是池槽泄漏 + 悬空授权)。
	poll_h : mem.Handle,

	term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle, // ids[0] = 主屏
	term_buffer_count : u32,
	active_term_buffer_id : mem.Handle, // 当前渲染/写入的页;0 = 未登记

	conpty_handle : mem.Handle, // 绑定的 ConPTY;0 = 无会话(空窗格/工具 console)

	// 字体集(引用计数持有者 = 本结构;见 fontset.odin):
	// **一份 FontSet 顶替原来的 4 个散句柄 + 输入名** —— 名字与字号在句柄里,
	// 中文面在创建阶段就按主字体 em 适配。Console 不再单独存任何一个字体。
	font_set : FontSet,

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

// 池本体(枚举用;与 GetCommandPolls 同形,持有者不碰内部字段,只拿句柄)。
// 池是包私有 —— 外部(探针)要遍历必须经这里,不许绕过池抽象。
GetConsoles :: proc() -> ^mem.GenArray(MAX_CONSOLE_SLOTS, Console) {
	return &consoles
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
	ReleaseCommandPoll(console.poll_h) // 信道随 console 一起消失
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
	ReleaseCommandPoll(console.poll_h) // 会话清空 = 授权撤销(授权绑定在对端程序上)
	console.poll_h = {}
	return true
}

// 会话初始化(建 console 与复用 console 共用):重置视口/解析状态 + 建主屏 + 绑 conpty。
// 失败时 console 处于"无 buffer"空态(调用方负责销毁或重试)。
// 这里是"这个 console 里开始了一个新程序"的唯一入口(CreateConsole 与
// consoleStartSession 都走它),所以授权在其上重置 —— 换程序必然重新授权。
consoleInitSession :: proc(console_h : mem.Handle, rows, cols : u16, conpty_handle : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	ReleaseCommandPoll(console.poll_h) // 旧程序的授权不继承给新程序
	console.poll_h = {}
	tb_h, tb_ok := CreateTermBuffer(rows, cols)
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
// 释放字体集(整批句柄引用 -1;结构清零)
releaseConsoleFontSet :: proc(console : ^Console) {
	FontSetRelease(&console.font_set)
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

// 继承另一 console 的完整字体集(split 承载新会话;整批句柄引用各 +1)
inheritConsoleFontSet :: proc(dst, src : ^Console) {
	dst.font_set = src.font_set
	FontSetRetain(dst.font_set)
}

// 渲染查询:style(bold/italic)→ 变体字体句柄 + 各维度"合成兜底"标志。
// 选择规则(哪几个句柄配成一套)归 FontSet,这里只是代 console 转一次。
ConsoleFontVariant :: proc(console_h : mem.Handle, bold, italic : bool) -> (fh : mem.Handle, bold_syn, italic_syn : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return {}, true, true
	}
	return FontSetLatinFont(console.font_set, bold, italic)
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

// 改网格尺寸(唯一入口;每帧由布局趟调到,同尺寸 = no-op)。
// 逐行模型下的重定规则(对照 alacritty 的 reflow):
//   ① cols 变 ⇒ 内容重排(按 wrapped 串合并/重切);光标/选区/review 锚点先取出
//      (物理行 + 列),reflow 用"流内偏移"把它们落到新网格;
//   ② rows 变 ⇒ 只影响活窗口 base(= len - rows):屏幕始终物化 rows 行,
//      内容不够就补空行;光标屏行 = 物理行 - 新 base。
// 同尺寸必须直接返回:否则每帧都会清 wrap_pending、重置滚动区(实测代价见 B8/文档)。
applyConsoleSize :: proc(console_h : mem.Handle, rows, cols : u16) {
	console := GetConsole(console_h)
	if console == nil || rows == 0 || cols == 0 {
		return
	}
	if console.rows == rows && console.cols == cols {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	old_rows := int(console.rows)
	cursor_abs, cursor_col := 0, 0
	review_row := -1
	n_anchors := 0
	anchors : [4]ReflowAnchor
	if tb != nil {
		base := liveBase(tb, int(console.rows))
		cursor_abs = base + int(console.cursor_row)
		cursor_col = int(console.cursor_col)
		if tb.review_top != 0 {
			review_row = int(tb.review_top) - 1
		}
		anchors[0] = { cursor_abs, cursor_col }
		anchors[1] = { review_row, 0 }
		n_anchors = 2
		if selection.buffer_h == console.active_term_buffer_id && GetConsole(selection.host) == console {
			anchors[2] = { selection.pivot.line, selection.pivot.col }
			anchors[3] = { selection.cur.line, selection.cur.col }
			n_anchors = 4
		}
	}
	if cols != console.cols {
		// 所有登记页都重排:活动页带锚点;非活动页(如交替屏期间的 主屏)只按旧列宽并/切,
		// 否则切回主屏时内容还停在旧折行(对照 alacritty 同时 reflow inactive grid)。
		for i in 0 ..< int(console.term_buffer_count) {
			buf_h := console.term_buffer_ids[i]
			if buf_h == console.active_term_buffer_id && tb != nil {
				TermBufferReflow(tb, int(cols), anchors[:n_anchors])
			} else if buf := GetTermBuffer(buf_h); buf != nil {
				TermBufferReflow(buf, int(cols), nil)
			}
		}
		if tb != nil {
			cursor_abs, cursor_col = anchors[0].row, anchors[0].col
			review_row = anchors[1].row
			if n_anchors == 4 {
				selection.pivot = { line = anchors[2].row, col = anchors[2].col }
				selection.cur = { line = anchors[3].row, col = anchors[3].col }
			}
		}
	}
	console.rows, console.cols = rows, cols
	console.vt.scroll_top, console.vt.scroll_bottom = 0, rows - 1
	console.vt.wrap_pending = false
	if tb == nil {
		return
	}
	// 行数变化:
	//   缩窗 = **顶部固定**(剪掉底部行,画面不整体上滚);光标若会被挤出新屏底,多剪 k 行
	//   让它落在新屏底(等价于"滚到光标可见")。旧实现一律贴底(base = len - rows),内容
	//   在顶部时会整屏上滚 —— 改字号(Ctrl+滚轮)每步都把提示符推进历史,shell 每次
	//   SIGWINCH 重画就多出一行 `$`(截图里的竖排 $ 列)。
	//   增窗 = 贴底:有历史就露出历史,没历史在底部补空行。
	if int(rows) < old_rows {
		R, Rp := old_rows, int(rows)
		base_old := liveBase(tb, R)
		crow := cursor_abs - base_old
		k := max(0, crow - (Rp - 1)) // 需要把视口下移多少行来容下光标
		for i in 0 ..< int(console.term_buffer_count) {
			buf := GetTermBuffer(console.term_buffer_ids[i])
			if buf == nil {
				continue
			}
			remove_n := R - Rp
			if buf == tb {
				remove_n -= k
			}
			for remove_n > 0 && len(buf.lines) > Rp {
				delete(buf.lines[len(buf.lines) - 1].cells)
				remove_range(&buf.lines, len(buf.lines) - 1, len(buf.lines))
				remove_n -= 1
			}
			ensureTermRows(buf, Rp)
		}
		console.cursor_row = u16(clamp(cursor_abs - liveBase(tb, Rp), 0, Rp - 1))
	} else {
		for i in 0 ..< int(console.term_buffer_count) {
			ensureTermRows(GetTermBuffer(console.term_buffer_ids[i]), int(rows))
		}
		console.cursor_row = u16(clamp(cursor_abs - liveBase(tb, int(rows)), 0, int(rows) - 1))
	}
	console.cursor_col = u16(clamp(cursor_col, 0, int(cols) - 1))
	base := liveBase(tb, int(rows))
	if review_row >= 0 && review_row < base {
		tb.review_top = u32(review_row + 1)
	} else {
		tb.review_top = 0 // 锚点落到活窗/内容不够 ⇒ 回最新
	}
	trimScrollback(console_h) // 变窄重排可能把行数放大,裁回上限
}

// Resize 时先改 ConPTY 再改这里;已有行不截断
ConsoleSetSize :: proc(console_h : mem.Handle, rows, cols : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil || rows == 0 || cols == 0 {
		return false
	}
	applyConsoleSize(console_h, rows, cols)
	return true
}

// 目标网格尺寸(纯计算,不写状态):与 ConsoleUpdateLayout 同一公式。
// 用途 = **建 ConPTY 之前**先算出正确尺寸(见 LaunchConsole):用写死的 80x24 建会话,
// 子进程一启动就按错尺寸排版,之后只能靠 resize 纠正 —— 那次 resize 失败
// (Win10 的 ResizePseudoConsole 会概率性失败,且旧代码失败也记成"已应用")或子进程
// 没跟上时,尺寸就永久停在旧值,表现为"TUI 认为的尺寸小于终端给它的尺寸"。
ConsoleGridForRect :: proc(console : ^Console, t : Transform) -> (rows, cols : u16, ok : bool) {
	if console == nil {
		return 0, 0, false
	}
	m := fnt.GetMetrics(console.font_set.main_font)
	if m.cell_width <= 0 || m.cell_height <= 0 || t.width <= 0 || t.height <= 0 {
		return 0, 0, false // 矩形没布局(0)时不能算出 1x1 会话,交由调用方回退 24x80
	}
	return u16(max(1, int(t.height / m.cell_height))), u16(max(1, int(t.width / m.cell_width))), true
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
	applyConsoleSize(console_h, u16(rows), u16(cols))

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
	return viewportBase(console, tb), tb.review_top != 0
}

