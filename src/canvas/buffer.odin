// 内容层数据:Cell/CellStyle/Line/TermBuffer(一"页"行 + 历史 + review 视口锚)。
// 生命周期 + 写路径(rune 落格/折行/滚动/擦除/插入/裁剪)全部收拢于此;
// review_line 为历史视口唯一真值(0=普通实时,1..=底行物理索引+1)。
package canvas

import mem "../memory"
import "core:fmt"

// 双层屏幕模型:
//   内容层 TermBuffer:一"页"的所有行(含滚动历史)。
//   视口层 Console:行列、光标、登记/激活的页、review 视口、VT 状态。
//   Console 与 ConptyContext 通过 conpty_handle 绑定;函数间传递一律用 Handle,内部自查槽位。
//   渲染契约:屏幕第 r 行 = lines[ScreenRow.line] 的 cells[ScreenRow.offset ...](ConsoleScreenSegment)
//            (阶段1 一逻辑行 = 一屏幕行 ⇒ offset 恒 0);光标本身就是屏幕坐标(cursor_row/col)
//            第 r 行第 c 列格子左上角像素 = (origin_x + c*cell_w, origin_y + r*cell_h);cell 来自 font 度量
// 颜色编码(DEFAULT_COLOR/colorRgb/colorIndex)见 theme.odin

// 装饰样式语义位(渲染层才做字体变体/合成/画线;下划线样式:0 无 1 单 2 双)
CellStyle :: struct {
	fg, bg : u32,
	bold, italic, reverse : bool,
	underline : u8, // 0 无 / 1 单(SGR 4)/ 2 双(SGR 21)
	crossed : bool, // SGR 9
	overline : bool, // SGR 53
}

Cell :: struct {
	cp : rune, // 0 = 空白格;宽字符续列 = cp 0 + wide true
	using style : CellStyle,
	wide : bool, // 宽字符(占 2 列)或宽字符的续列
}

// 宽字符判定(EAW=W/F 的核心子集,与 nvim/wcwidth 一致)
runeWidth :: proc(cp : rune) -> int {
	switch {
	case cp >= 0x1100 && cp <= 0x115F: return 2 // Hangul Jamo
	case cp >= 0x2E80 && cp <= 0x303E: return 2 // CJK 部首/符号
	case cp >= 0x3041 && cp <= 0x33FF: return 2 // 假名/CJK 兼容
	case cp >= 0x3400 && cp <= 0x4DBF: return 2 // CJK 扩展 A
	case cp >= 0x4E00 && cp <= 0x9FFF: return 2 // CJK 统一
	case cp >= 0xA000 && cp <= 0xA4CF: return 2 // 彝文
	case cp >= 0xAC00 && cp <= 0xD7A3: return 2 // Hangul 音节
	case cp >= 0xF900 && cp <= 0xFAFF: return 2 // CJK 兼容表意
	case cp >= 0xFE30 && cp <= 0xFE4F: return 2 // CJK 兼容形式
	case cp >= 0xFF00 && cp <= 0xFF60: return 2 // 全角 ASCII
	case cp >= 0xFFE0 && cp <= 0xFFE6: return 2 // 全角符号
	case cp >= 0x1F300 && cp <= 0x1F64F: return 2 // emoji
	case cp >= 0x20000 && cp <= 0x2FFFD: return 2 // CJK 扩展 B+
	case cp >= 0x30000 && cp <= 0x3FFFD: return 2
	}
	return 1
}

// 逻辑行:只有硬换行才开新行,长度可以远超 cols(超宽部分由屏幕段表达)。
// 折行不再是内容属性 —— 一行占几个屏幕行由 SegmentLen/LineSegments 从内容**派生**,
// 所以这里没有 wrapped 之类的标记:软折行 = 同一行,硬换行 = 不同行,结构自己就说明了。
Line :: struct {
	cells : [dynamic]Cell,
}

// ---------------------------------------------------------------------------
// TermBuffer
// ---------------------------------------------------------------------------
// 容量依据:每 console 最多 2 个 buffer(主屏 + 交替屏),console 上限见 console.odin
MAX_TERM_BUFFER_SLOTS :: 128

MAX_SCROLLBACK_LINES :: 10000

TRIM_SLACK :: 512 // 超上限这么多行才裁,避免频繁搬行

TermBuffer :: struct {
	lines : [dynamic]Line,
	// 历史视口锚点(**顶行**编码,锁的是窗口左上角那块内容):
	//   review_top = 0       = 活窗口(贴底跟随,由 viewportAnchorLive 从内容尾部推)
	//   review_top = n (1..) = review,窗口顶行 = lines[n-1] 的第 review_off 段起
	// 为什么用顶行而不是底行:底行编码每次都要拿 rows 反推顶行,而"一行占几段"随 cols 变,
	// 反推在段模型下根本不成立;顶行是内容坐标,resize/重排都天然稳定。
	review_top : u32,
	review_off : u32,

	// 屏幕行表(派生缓存,**归 buffer**):屏幕第 r 行显示 lines[line] 的 cells[offset ...]。
	// 为什么放内容层:表的形状由内容长度决定(一行可占多个屏幕段),失效源就是本文件的写路径
	// ⇒ 就地置 dirty;交替屏各持一张表,切页无需失效。
	// 建表参数 rows/cols 是窗格几何(见 screenEnsure 的签名),不在这里存几何。
	screen : [dynamic]ScreenRow,
	screen_dirty : bool, // 写路径/几何/锚点变化即置位;screenEnsure 消费并清除
}

term_buffers : mem.GenArray(MAX_TERM_BUFFER_SLOTS, TermBuffer)

CreateTermBuffer :: proc() -> (h : mem.Handle, ok : bool) {
	lines := make([dynamic]Line)
	append(&lines, Line{}) // 占位首行
	h = mem.Alloc(&term_buffers, TermBuffer { lines = lines })
	if h.id == 0 {
		delete(lines)
		return {}, false
	}
	return h, true
}

GetTermBuffer :: proc(h : mem.Handle) -> ^TermBuffer {
	return mem.Get(&term_buffers, h)
}

DestroyTermBuffer :: proc(h : mem.Handle) {
	tb := GetTermBuffer(h)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	delete(tb.lines)
	delete(tb.screen) // 屏幕行表(派生缓存)随 buffer 一起释放
	mem.Free(&term_buffers, h)
}

// 清空全部行(1049h 进交替屏时)
TermBufferClear :: proc(h : mem.Handle) {
	tb := GetTermBuffer(h)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	clear(&tb.lines)
	tb.screen_dirty = true
	SelectionClear() // 内容全没了,选区同步失效
}

// ---------------------------------------------------------------------------
// 屏幕行表:屏幕坐标 ↔ 缓冲坐标的唯一换算入口(表本身归 TermBuffer)
// ---------------------------------------------------------------------------
// 表项 = 屏幕第 r 行显示 lines[line] 的 cells[offset ...]。
// 为什么归内容层:表的形状由内容长度决定(阶段2 起一条逻辑行可占多个屏幕行),失效源就是本
// 文件的写路径 ⇒ 失效可以就地做;交替屏各持一张表,切页不需要任何跨结构标志。
// 建表要知道两件事:"屏幕多高"(窗格几何,非内容属性)与"视口锚在哪"(review_line,内容层)
// ⇒ 入口签名 screenEnsure(console, tb):参数取几何,状态存 tb。
//
// 阶段1:一逻辑行 = 一屏幕行 ⇒ offset 恒 0(仿射,与旧的 top + r 逐位等价);
// 阶段2 放开逻辑行超宽后,同一条 line 占多个屏幕行,offset 填该行内的起始列。
ScreenRow :: struct {
	line   : u32,
	offset : u32,
}

// 活窗口锚点:从内容尾部往回退 rows 个屏幕段得到窗口顶段(贴底跟随)。
viewportAnchorLive :: proc(console : ^Console, tb : ^TermBuffer) -> (line, off : int) {
	if tb == nil || len(tb.lines) == 0 {
		return 0, 0
	}
	cols := max(1, int(console.cols))
	li := len(tb.lines) - 1
	k := max(0, LineSegments(lineContent(tb.lines[li].cells[:]), cols) - 1) // 末行的最后一段
	for _ in 1 ..< int(console.rows) { // 从底行往上退 rows-1 段
		switch {
		case k > 0:
			k -= 1
		case li > 0:
			li -= 1
			k = max(0, LineSegments(lineContent(tb.lines[li].cells[:]), cols) - 1)
		case:
			return 0, 0 // 内容不够一屏:锚在开头
		}
	}
	return li, SegmentStart(lineContent(tb.lines[li].cells[:]), cols, k)
}

// 窗口锚点(唯一推导):review 用显式锚点,否则活窗口。
viewportAnchor :: proc(console : ^Console, tb : ^TermBuffer) -> (line, off : int) {
	if tb != nil && tb.review_top != 0 {
		return int(tb.review_top) - 1, int(tb.review_off)
	}
	return viewportAnchorLive(console, tb)
}

// 包含 at 的那一段的起点(at 落在段边界上就返回它自己)
segmentStartAt :: proc(cells : []Cell, cols, at : int) -> int {
	cols := max(1, cols)
	start := 0
	for {
		n := SegmentLen(cells, start, cols)
		if n <= 0 || start + n >= at {
			return start
		}
		start += n
	}
}

// 锚点前后移动 delta 个**屏幕段**(delta < 0 = 往历史走);越界就停在边界。
ViewportAnchorShift :: proc(tb : ^TermBuffer, cols : int, line, off, delta : int) -> (nline, noff : int) {
	// 先判 tb:下面立刻要读 tb.lines(空/失效 buffer 直接停在开头)
	if tb == nil || len(tb.lines) == 0 {
		return 0, 0
	}
	cols := max(1, cols)
	nline, noff = clamp(line, 0, len(tb.lines) - 1), off
	if delta > 0 {
		for _ in 0 ..< delta {
			cells := lineContent(tb.lines[nline].cells[:])
			n := SegmentLen(cells, noff, cols)
			switch {
			case noff + n < len(cells):
				noff += n
			case nline + 1 < len(tb.lines):
				nline += 1
				noff = 0
			case:
				return nline, noff // 已到内容末尾
			}
		}
		return
	}
	for _ in 0 ..< -delta {
		switch {
		case noff > 0:
			noff = segmentStartAt(lineContent(tb.lines[nline].cells[:]), cols, noff)
		case nline > 0:
			nline -= 1
			cells := lineContent(tb.lines[nline].cells[:])
			k := max(0, LineSegments(cells, cols) - 1)
			noff = SegmentStart(cells, cols, k)
		case:
			return 0, 0 // 已到内容开头
		}
	}
	return
}

// 建表(唯一写入点)。失效 = screen_dirty:内容长度进了推导(一行占几段由内容决定),
// 已经没有便宜的"输入快照比较"可用了 ⇒ 由写路径/几何变更**就地置位**,这里消费并清除。
// 只服务读侧(渲染/选区/鼠标/CPR/IME);写入路径走 Console 的光标段缓存,免得每落一格重建。
screenEnsure :: proc(console : ^Console, tb : ^TermBuffer) {
	if tb == nil {
		return
	}
	// 两个条件缺一不可:dirty 标志由写路径/几何变更置位;len(screen) 兜住"新建但零值
	// 状态说自己是干净的"这一初始态(console 与 buffer 刚建时 dirty = false、表为空)。
	if !tb.screen_dirty && len(tb.screen) == int(console.rows) {
		return
	}
	rows := int(console.rows)
	cols := max(1, int(console.cols))
	if rows <= 0 {
		return
	}
	resize(&tb.screen, rows) // 容量复用:resize 变小不释放
	line, off := viewportAnchor(console, tb)
	for r in 0 ..< rows {
		tb.screen[r] = ScreenRow { line = u32(line), offset = u32(off) }
		if line >= len(tb.lines) {
			continue // 内容用尽:后续屏幕行映射到"末尾之后"(读方按 line >= len 判空)
		}
		n := SegmentLen(lineContent(tb.lines[line].cells[:]), off, cols)
		if off + n >= len(lineContent(tb.lines[line].cells[:])) {
			line += 1 // 本行走完 ⇒ 下一行的第 0 段
			off = 0
		} else {
			off += n // 同一行的下一段
		}
	}
	tb.screen_dirty = false
}

// 屏幕第 r 行 → 缓冲行号;-1 = 行号越界(表外)。屏上无内容时返回的行号可能 ≥ len(lines),
// 与旧的 top + r 同性质,由读方自行判空(渲染/命中测试本来就带边界检查)。
screenLineAt :: proc(console : ^Console, tb : ^TermBuffer, r : int) -> int {
	screenEnsure(console, tb)
	if r < 0 || r >= len(tb.screen) {
		return -1
	}
	return int(tb.screen[r].line)
}

// 缓冲行号 → 屏幕第 r 行;-1 = 不在屏上(滚出视口的历史行)。
screenRowFor :: proc(console : ^Console, tb : ^TermBuffer, line : int) -> int {
	screenEnsure(console, tb)
	for e, r in tb.screen {
		if int(e.line) == line {
			return r
		}
	}
	return -1
}

// 内容位置(逻辑行 + 行内**绝对列**)→ 屏幕行;-1 = 不在当前窗口里(调用方自行夹边界)。
// 与 screenRowFor 的区别:这个定位到**那一段**。一条逻辑行占多段时行级只能给第一段,
// 而"把光标重定回它写的那一段"必须段级(cols 变化后段边界跟着变,见 applyConsoleSize)。
// line ≥ len(lines) = 内容之后(空白区):给第一行"内容之外"的屏幕行。
screenRowForPos :: proc(console : ^Console, tb : ^TermBuffer, line, pos : int) -> int {
	screenEnsure(console, tb)
	if tb == nil || line < 0 {
		return -1
	}
	if line >= len(tb.lines) {
		for e, r in tb.screen {
			if int(e.line) >= len(tb.lines) {
				return r
			}
		}
		return -1
	}
	cells := lineContent(tb.lines[line].cells[:])
	off := segmentStartAt(cells, max(1, int(console.cols)), pos)
	for e, r in tb.screen {
		if int(e.line) == line && int(e.offset) == off {
			return r
		}
	}
	return -1
}

// 公开入口(跨包读侧:render 用;形态与 ConsoleViewportTop 一致)
ConsoleScreenLine :: proc(console_h : mem.Handle, r : int) -> int {
	console := GetConsole(console_h)
	if console == nil {
		return -1
	}
	return screenLineAt(console, GetTermBuffer(console.active_term_buffer_id), r)
}

// 屏幕第 r 行的**段**:返回 (内容行, 段首列 0-based,-1 = 越界)。
// 渲染按 cells[offset .. offset+cols) 画;阶段1 offset 恒 0(一逻辑行 = 一屏幕行)。
ConsoleScreenSegment :: proc(console_h : mem.Handle, r : int) -> (line, offset : int) {
	console := GetConsole(console_h)
	if console == nil {
		return -1, 0
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	screenEnsure(console, tb)
	if tb == nil || r < 0 || r >= len(tb.screen) {
		return -1, 0
	}
	return int(tb.screen[r].line), int(tb.screen[r].offset)
}

ConsoleScreenRow :: proc(console_h : mem.Handle, line : int) -> int {
	console := GetConsole(console_h)
	if console == nil {
		return -1
	}
	return screenRowFor(console, GetTermBuffer(console.active_term_buffer_id), line)
}

// 取第 n 行(n 从缓冲区最上面数,0-based)的文本,写进 buf(借用,调用期间有效)。
// 宽字符**本体**与普通字符走同一条路;只跳过它的**续列**(cp == 0 且 wide = true)
// —— 那一格不是空白格,是前一个字的第二列,当空格用会 dump 出「中 文」。
// 行尾空白裁剪(终端行是整行填充的)。false = 越界或无缓冲区。
TermBufferLineText :: proc(tb_h : mem.Handle, n : int, buf : []u8) -> (text : string, ok : bool) {
	tb := GetTermBuffer(tb_h)
	if tb == nil || n < 0 || n >= len(tb.lines) {
		return "", false
	}
	line := tb.lines[n]
	k := 0
	for c in line.cells {
		if c.cp == 0 {
			if c.wide {
				continue // 宽字符续列:占列,无独立字符
			}
			if k >= len(buf) {
				break
			}
			buf[k] = ' '
			k += 1
			continue
		}
		if k + 4 > len(buf) {
			break // 一个 rune 最多 4 字节:放不下就停,不写半个字符
		}
		k += runeToUtf8(c.cp, buf[k:])
	}
	for k > 0 && buf[k - 1] == ' ' {
		k -= 1 // 行尾空白 = 整行填充的产物,不是内容
	}
	return string(buf[:k]), true
}

// ---------------------------------------------------------------------------
// 逻辑行 → 屏幕段(阶段2 的地基)
// ---------------------------------------------------------------------------
// 一条逻辑行按 cols 切成若干**屏幕段**:第 k 段的起点 = SegmentStart(k),长度 = SegmentLen。
// 硬规则:宽字对不跨段 —— 段末只剩 1 列时该宽字整对推到下一段(与写入路径"宽字放不下
// 就先折行"同一条规则),所以段边界不是简单的 k*cols,必须按内容走。
// 空行也算 1 段(终端里空行占一个屏幕行)。

// 逻辑行的**内容长度**(末尾空白不算)与内容视图。
// 必须这么算:EL/ED 会把行补齐到 cols(擦除语义需要),若按 cells 长度算段数,
// 一行 "abc" + 77 空白在 1 列下就成了 80 段 —— 窗口锚到尾空白,光标看起来"跳到行尾"。
LineExtent :: proc(cells : []Cell) -> int {
	n := len(cells)
	for n > 0 && cells[n - 1].cp == 0 && !cells[n - 1].wide {
		n -= 1
	}
	return n
}

// 视觉行宽:高亮/整行选用的"行尾" = 至少铺满屏幕宽,长行则到它的内容末尾
LineWidth :: proc(cells : []Cell, cols : int) -> int {
	return max(cols, LineExtent(cells))
}

// 内容视图:段数/锚点/推进只看内容,不看补齐的空白
lineContent :: proc(cells : []Cell) -> []Cell {
	return cells[:LineExtent(cells)]
}
// start 处最多 cols 列、且不劈开宽字对的一段有多长。
// 保证前进:即便 cols 小到容不下一个宽字(病态尺寸),也至少吃掉它,绝不返回 0 造成死循环。
SegmentLen :: proc(cells : []Cell, start, cols : int) -> int {
	n := 0
	for start + n < len(cells) && n < cols {
		c := cells[start + n]
		if c.cp != 0 && c.wide && n + 2 > cols {
			break // 宽字放不下本段剩余列 ⇒ 整对推到下一段
		}
		n += 1
	}
	if n == 0 && start < len(cells) {
		n = min(2, len(cells) - start)
	}
	return n
}

// 第 k 段(0-based)的起点。k ≥ 段数时返回 len(cells)(“末段之后”),整体单调不回退 ——
// 建表的推进规则因此极简:off == len(cells) ⇒ 换下一行,否则 off = SegmentStart(k+1)。
SegmentStart :: proc(cells : []Cell, cols, k : int) -> int {
	start := 0
	for _ in 0 ..< k {
		n := SegmentLen(cells, start, cols)
		if n <= 0 {
			break // 到末尾(空行 / 已耗尽)
		}
		start += n
	}
	return min(start, len(cells))
}

// 一条逻辑行占几个屏幕段(最少 1:空行也占一行)
LineSegments :: proc(cells : []Cell, cols : int) -> int {
	cols := max(1, cols)
	k, start := 0, 0
	for {
		n := SegmentLen(cells, start, cols)
		if n <= 0 {
			break
		}
		start += n
		k += 1
	}
	return max(1, k)
}

// ---------------------------------------------------------------------------
// 光标段(写入热路径)
// ---------------------------------------------------------------------------
// 光标是屏幕坐标,而内容寻址要 (逻辑行, 段首列)。这两个数缓存在 Console 上:
//   · 折行/LF/滚动 ⇒ cursorSegmentAdvance 做 **O(1) 增量推进**(同行下一段 / 下一行第 0 段);
//   · 光标跳转(CUP/CUU/CUD/VPA/DECRC)、resize、结构操作(插删行/裁剪/清空/拆行)⇒
//     只需 invalidate(置 cursor_seg_ok = false),下一次写入时惰性查一次屏幕行表。
// 绝不能在字符循环里查表:那等于每落一格重建 rows 项。
cursorSegmentInvalidate :: proc(console : ^Console) {
	console.cursor_seg_ok = false
}

cursorSegmentRefresh :: proc(console : ^Console, tb : ^TermBuffer) {
	console.cursor_seg_ok = true
	console.cursor_seg_row = console.cursor_row
	if tb == nil {
		console.cursor_line = 0
		console.cursor_off = 0
		return
	}
	screenEnsure(console, tb)
	r := int(console.cursor_row)
	if r >= 0 && r < len(tb.screen) {
		console.cursor_line = tb.screen[r].line
		console.cursor_off = tb.screen[r].offset
		return
	}
	console.cursor_line = u32(len(tb.lines))
	console.cursor_off = 0
}

// 写入路径唯一入口:拿到光标的 (逻辑行, 段首列)。
// 缓存自带两个失效条件:① 屏幕行变了(任何光标跳转 —— CUP/CUU/CUD/VPA/DECRC/…);
// ② 内容结构变了(插删行/裁剪/滚动区搬移/拆行 —— 那些操作显式 invalidate)。
cursorSegment :: proc(console : ^Console, tb : ^TermBuffer) -> (line, off : int) {
	if !console.cursor_seg_ok || console.cursor_seg_row != console.cursor_row {
		cursorSegmentRefresh(console, tb)
	}
	return int(console.cursor_line), int(console.cursor_off)
}

// 光标内容位置下移**一段**(软折行专用):**留在同一条逻辑行**里,off += 本段长度。
// 关键:段尾正好等于行尾时也不能换行 —— 应用还在续写同一行(这正是"逻辑行"的含义),
// 换行只由 LF/NEL 决定。行不够长就补格(写入路径随后会覆盖)。
cursorSegmentNextSegment :: proc(console : ^Console, tb : ^TermBuffer) {
	if !console.cursor_seg_ok {
		cursorSegmentRefresh(console, tb)
	}
	cols := max(1, int(console.cols))
	line := int(console.cursor_line)
	off := int(console.cursor_off)
	if line < len(tb.lines) {
		n := max(1, SegmentLen(lineContent(tb.lines[line].cells[:]), off, cols))
		console.cursor_off = u32(off + n)
	} else {
		console.cursor_off = u32(off + cols)
	}
	console.cursor_seg_row = console.cursor_row
}

// 光标内容位置下移**一行**(LF/NEL 专用 = 硬换行):这一段就是本行最后一段 ⇒ 换下一行,
// 否则留在本行(裸 LF 只下移;CR+LF 的"硬断点"由调用方在段边界拆行记下)。
cursorSegmentNextLine :: proc(console : ^Console, tb : ^TermBuffer) {
	if !console.cursor_seg_ok {
		cursorSegmentRefresh(console, tb)
	}
	cols := max(1, int(console.cols))
	line := int(console.cursor_line)
	off := int(console.cursor_off)
	if line < len(tb.lines) {
		n := SegmentLen(lineContent(tb.lines[line].cells[:]), off, cols)
		if off + n < len(tb.lines[line].cells) {
			console.cursor_off = u32(off + n) // 行内还有内容:只下移一段
			console.cursor_seg_row = console.cursor_row
			return
		}
		line += 1
	}
	console.cursor_line = u32(line)
	console.cursor_off = 0
	console.cursor_seg_row = console.cursor_row
	for len(tb.lines) <= line {
		append(&tb.lines, Line{})
	}
}

// 在 at(必须是**段边界**)处把一条逻辑行切成两条:内容一字不动,只分成两条行。
// 用途:CR+LF 落在行内(补回硬换行语义)、区域操作切进逻辑行前先拆边界。
// 返回新行索引(原行 +1);调用方负责置 screen_dirty 与 invalidate 光标段。
splitLineAt :: proc(tb : ^TermBuffer, line_idx, at : int) -> int {
	if tb == nil || line_idx < 0 || line_idx >= len(tb.lines) {
		return -1
	}
	if at <= 0 || at >= len(tb.lines[line_idx].cells) {
		return -1 // 端点位置不需要拆
	}
	insertLine(&tb.lines, line_idx + 1)
	append(&tb.lines[line_idx + 1].cells, ..tb.lines[line_idx].cells[at:])
	resize(&tb.lines[line_idx].cells, at)
	tb.screen_dirty = true
	return line_idx + 1
}

// 折行一次:光标下移一段(屏幕坐标;到滚动区底则上滚),列归 0。
// 关键:内容**不切分** —— 超宽部分留在同一条逻辑行里,由屏幕段表达(所以没有 wrapped 标记)。
vtWrapOnce :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if int(console.cursor_row) < int(console.vt.scroll_bottom) {
		console.cursor_row += 1
	} else {
		vtScrollUp(console_h) // 全屏上滚:窗口跟着内容走,光标的屏幕行不变
	}
	cursorSegmentNextSegment(console, tb)
	console.cursor_col = 0
	tb.screen_dirty = true
}

// 落格 → 前进 → 最后一列置 wrap-pending(下一字符才折行)→ 滚动区上移
ConsoleWriteRune :: proc(console_h : mem.Handle, cp : rune, style : CellStyle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	// wrap-pending:上一字符写满最后一列,本字符先折行再落格
	if console.vt.wrap_pending {
		console.vt.wrap_pending = false
		if console.vt.autowrap {
			vtWrapOnce(console_h)
		} else {
			console.cursor_col = console.cols - 1
		}
	}
	line_idx, off := cursorSegment(console, tb)
	col := int(console.cursor_col)
	when VT_DEBUG {
		vtDbg(console_h, fmt.tprintf("WRITE '%c' at (%d,+%d) col=%d", cp, line_idx, off, col))
	}

	w := runeWidth(cp)
	// 宽字符放不下当前列(只剩 1 列):先折行再写(xterm 语义)
	if w == 2 && col + w > int(console.cols) {
		vtWrapOnce(console_h)
		line_idx, off = cursorSegment(console, tb)
		col = int(console.cursor_col)
	}
	at := off + col // 段首 + 段内列 = 逻辑行内的绝对列
	for len(tb.lines) <= line_idx {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[line_idx]
	for len(line.cells) <= at + w - 1 {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
	// 宽字对守卫(热路径局部):写入点两端的宽字对若被这次写入劈开,先清掉半个。
	// 必须**清成空白格**而不是只降 wide 标志:渲染层按格号落字形、根本不看 wide,
	// 悬空首格照样按宽字形画出来压到右邻居 —— 那正是"个别汉字重叠"的形态。
	// 位置用绝对列:宽字对不跨段(写入规则保证),所以守卫不会越过段边界。
	unpairWideAt(line, at, at + w - 1)
	line.cells[at] = Cell { cp = cp, style = style, wide = w == 2 }
	if w == 2 {
		line.cells[at + 1] = Cell { style = style, wide = true } // 续列继承样式(背景)
	}

	console.cursor_col += u16(w)
	if console.cursor_col >= console.cols {
		// 写满最后一列:光标停最后一列,置 pending,等下一字符决定折行
		console.cursor_col = console.cols - 1
		console.vt.wrap_pending = console.vt.autowrap
	}
	tb.screen_dirty = true
	return true
}

// 滚动区上移一行。全屏:行数组尾部增长,顶行滚进历史;
// 局部:顶行丢弃,底行补空行。
vtScrollUp :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	top, bottom := int(console.vt.scroll_top), int(console.vt.scroll_bottom)
	if top == 0 && bottom == int(console.rows) - 1 {
		// 全屏上滚:行数组尾部增长(顶行滚进历史),窗口贴底 ⇒ 光标的屏幕行不变
		append(&tb.lines, Line{})
		tb.screen_dirty = true
		trimScrollback(console_h)
		return
	}
	// 区域滚动按**行**搬:先让区内每个屏幕行都恰好是一条逻辑行(长行按段边界拆开)
	splitRowsInRegion(console_h, console, tb)
	top = viewportTop(console, tb) + top
	bottom = viewportTop(console, tb) + bottom
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[top].cells)
	remove_range(&tb.lines, top, top + 1)
	insertLine(&tb.lines, bottom)
	// 选区通报:顶行删 + 底行补空 = 滚动区内整体上移一格
	cursorSegmentInvalidate(console)
	tb.screen_dirty = true
}

vtScrollDown :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	top, bottom := int(console.vt.scroll_top), int(console.vt.scroll_bottom)
	// 区域滚动按**行**搬:先让区内每个屏幕行都恰好是一条逻辑行(长行按段边界拆开)
	splitRowsInRegion(console_h, console, tb)
	top = viewportTop(console, tb) + top
	bottom = viewportTop(console, tb) + bottom
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[bottom].cells)
	remove_range(&tb.lines, bottom, bottom + 1)
	insertLine(&tb.lines, top)
	// 选区通报:底行删 + 顶行补空 = 滚动区内整体下移一格
	cursorSegmentInvalidate(console)
	tb.screen_dirty = true
}

// core:slice 无 insert 的替代实现
insertLine :: proc(lines : ^[dynamic]Line, index : int) {
	append(lines, Line{})
	copy(lines[index + 1:], lines[index:len(lines) - 1])
	lines[index] = Line{}
}

// 从行数组头部裁掉 cut 行(历史永久丢弃),同步选区通报 / review 锚定。
// 调用方:超容量裁剪(trimScrollback)、ED 3 清 scrollback(视口之上全是历史)。
// cut 不得越过窗口顶行:裁进屏内会把还看得见的内容丢掉(光标是屏幕坐标,不受裁剪影响 ——
// 裁掉的都在屏之上,窗口内容不变,所以这里不再需要动的就是 cursor_row)。
cutHistoryHead :: proc(console_h : mem.Handle, cut : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil || cut <= 0 || cut > len(tb.lines) {
		return
	}
	// 不得裁进窗口:裁掉的行必须全在**看得见的窗口**之上。
	// review 时看得见的是被回看的那一屏(在活窗口上方),所以取两者中更靠上的顶行。
	guard := viewportTop(console, tb)
	if tb.review_top != 0 {
		guard = min(guard, int(tb.review_top) - 1)
	}
	if cut > guard {
		return
	}
	for i in 0 ..< cut {
		delete(tb.lines[i].cells)
	}
	remove_range(&tb.lines, 0, cut)
	cursorSegmentInvalidate(console) // 光标的内容行号整体前移,缓存作废(惰性重查)
	tb.screen_dirty = true
	// review 锚点随裁剪平移;锚点本身被裁掉 ⇒ 回到最新(那段历史已经不存在了)
	if tb.review_top != 0 {
		rl := int(tb.review_top) - 1 - cut
		if rl < 0 {
			tb.review_top, tb.review_off = 0, 0
		} else {
			tb.review_top = u32(rl + 1)
		}
	}
}

// 只在全屏滚动路径调用;裁掉最老行
trimScrollback :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	max_lines := int(console.rows) + MAX_SCROLLBACK_LINES
	if len(tb.lines) <= max_lines + TRIM_SLACK {
		return
	}
	cutHistoryHead(console_h, len(tb.lines) - max_lines)
	console.vt.scroll_top, console.vt.scroll_bottom = 0, console.rows - 1
}

// 擦除用 cell:带当前 SGR 背景色。xterm 语义:EL/ED/ECH 擦除的区域
// 用当前背景色填充(补全窗口等依赖此行为形成完整矩形背景)
eraseCell :: proc(console : ^Console) -> Cell {
	return Cell { style = { bg = console.vt.style.bg } }
}

// 行定宽化:确保 line.cells 覆盖到 col(行模型是定宽 cols,擦除/定位需要)。
// 补的空白格必须是默认样式(零值 bg=0 会被渲染成黑色块)
lineEnsureCol :: proc(line : ^Line, col : int) {
	for len(line.cells) <= col {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
}

// ---------------------------------------------------------------------------
// 宽字对守卫
// ---------------------------------------------------------------------------
// 不变式(宽字对必须成对存在):
//   I1 续列(cp == 0 && wide)⟺ 左边紧邻是它的宽体首格(cp != 0 && wide)
//   I2 宽体首格            ⟺ 右边紧邻是它的续列
// 违反的两种形态:孤儿续列(I1 左无首格)、悬空首格(I2 右无续列)。
// 为什么必须**清成空白格**而不是只把 wide 降为 false:渲染层按"格号 × 格宽"落字形、
// 完全不看 wide(见 render/scene.odin 字形趟),悬空首格照样按宽字形画出来,压到右
// 邻居格的字形上 —— 这正是 nvim/vim 上"个别汉字重叠"的形态;孤儿续列则会让背景趟
// 跳过该格底色、并让文本提取(TermBufferLineText)整列丢失。
// 分工:热路径(每字符)只修写入点两端;冷路径(擦除/插入/删除)整行扫。

// 写入/擦除 [lo, hi] 之前调用:把被这次操作劈开的宽字对清成空白格。
// 只查两个边界 —— 区间内部整体被覆盖,留不下半个。
unpairWideAt :: proc(line : ^Line, lo, hi : int) {
	n := len(line.cells)
	// 左边界:lo-1 是宽体首格、lo 是它的续列 → 首格失去续列
	if lo > 0 && lo < n {
		if l := &line.cells[lo - 1]; l.cp != 0 && l.wide &&
		   line.cells[lo].cp == 0 && line.cells[lo].wide {
			l.cp = 0
			l.wide = false
		}
	}
	// 右边界:hi+1 是续列、hi 是它的首格 → 续列失去首格
	if hi >= 0 && hi + 1 < n {
		if line.cells[hi].cp != 0 && line.cells[hi].wide &&
		   line.cells[hi + 1].cp == 0 && line.cells[hi + 1].wide {
			line.cells[hi + 1].wide = false
		}
	}
}

// 扫描 [from, to) 区间,清掉全部不成对的半个宽字(冷路径:搬移类操作之后)。
// 区间 = 一个屏幕段(段内宽字对完整,所以按段扫即可;跨段扫反而会误判)。
sanitizeWidePairs :: proc(line : ^Line, from, to : int) {
	n := min(to, len(line.cells))
	i := max(0, from)
	for i < n {
		c := &line.cells[i]
		switch {
		case c.cp != 0 && c.wide: // 宽体首格:必须有紧邻续列
			if i + 1 < n && line.cells[i + 1].cp == 0 && line.cells[i + 1].wide {
				i += 2 // 完整对,跳过
				continue
			}
			c.cp = 0
			c.wide = false
		case c.cp == 0 && c.wide: // 续列:左边必须是宽体首格
			if i > 0 && line.cells[i - 1].cp != 0 && line.cells[i - 1].wide {
				i += 1
				continue
			}
			c.wide = false
		}
		i += 1
	}
}

// mode:0 到行尾 / 1 到行首 / 2 整行
// 行 = **屏幕段**:段首 off + 段内列;擦除范围不越过本段(段外的内容属同一逻辑行的其他屏行)。
vtEraseInLine :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	line_idx, off := cursorSegment(console, tb)
	for len(tb.lines) <= line_idx {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[line_idx]
	erase := eraseCell(console)
	cols := int(console.cols)
	col := int(console.cursor_col)
	switch mode {
	case 0:
		for i in col ..< cols {
			lineEnsureCol(line, off + i)
			line.cells[off + i] = erase
		}
	case 1:
		for i in 0 ..= col {
			lineEnsureCol(line, off + i)
			line.cells[off + i] = erase
		}
	case 2:
		for i in 0 ..< cols {
			lineEnsureCol(line, off + i)
			line.cells[off + i] = erase
		}
	}
	sanitizeWidePairs(line, off, off + cols) // 擦除端点可能落在宽字对中间(段内)
	tb.screen_dirty = true
}

// mode:0 光标到屏尾 / 1 屏头到光标 / 2 可视区 / 3 只清 scrollback(历史,不动可视屏)
// 遍历一律按**屏幕行**(xterm 语义:擦的是屏幕);内容行 = 窗口顶行 + 屏幕行。
vtEraseInDisplay :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := viewportTop(console, tb)
	switch mode {
	case 0:
		vtEraseInLine(console_h, 0)
		for r in int(console.cursor_row) + 1 ..< int(console.rows) {
			clearScreenRow(console_h, r)
		}
	case 1:
		for r in 0 ..< int(console.cursor_row) {
			clearScreenRow(console_h, r)
		}
		vtEraseInLine(console_h, 1)
	case 2:
		for r in 0 ..< int(console.rows) {
			clearScreenRow(console_h, r)
		}
	case 3:
		// ED 3 = Erase Saved Lines:只擦可视窗之上已滚出的历史,可视屏与光标都不许动。
		// 这里曾经整个 TermBufferClear ⇒ 行数组清空但 cursor_row 留在原处,下一次写入
		// 把数组补空行补回那一行,提示符的屏幕行 = "清屏那一刻攒下的历史长度"(实测宿主
		// 对 clear 发的正是 ESC[H ESC[2J ESC[3J,于是"有时在底部、有时在中间、有时在上面")。
		cutHistoryHead(console_h, base)
	}
}

// 清一个**屏幕行**:取它的段,只擦 [off, off+cols) —— 段外的内容属于同一逻辑行的
// 其他屏幕行,不归这一行管(xterm 的 ED/EL 都是屏幕语义)。
clearScreenRow :: proc(console_h : mem.Handle, r : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	line_idx, off, ok := screenSegmentAt(console, tb, r)
	if !ok || line_idx < 0 || line_idx >= len(tb.lines) {
		return
	}
	line := &tb.lines[line_idx]
	erase := eraseCell(console)
	cols := int(console.cols)
	for i in 0 ..< cols {
		lineEnsureCol(line, off + i)
		line.cells[off + i] = erase
	}
	sanitizeWidePairs(line, off, off + cols)
	tb.screen_dirty = true
}

// 屏幕行 r 的段(必要时建表);ok = false 表示内容用尽/越界
screenSegmentAt :: proc(console : ^Console, tb : ^TermBuffer, r : int) -> (line, off : int, ok : bool) {
	screenEnsure(console, tb)
	if r < 0 || r >= len(tb.screen) {
		return -1, 0, false
	}
	e := tb.screen[r]
	if int(e.line) >= len(tb.lines) {
		return int(e.line), int(e.offset), false
	}
	return int(e.line), int(e.offset), true
}

// ECH:从光标起擦除 n 个字符(不清空行)
vtEraseChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	line_idx, off := cursorSegment(console, tb)
	if line_idx >= len(tb.lines) {
		return
	}
	line := &tb.lines[line_idx]
	start := int(console.cursor_col)
	cols := int(console.cols)
	end := min(start + n, cols)
	erase := eraseCell(console)
	when VT_DEBUG {
		fmt.eprintfln("VTDBG ECH n=%d start=%d style.bg=%08X", n, start, console.vt.style.bg)
	}
	for i in start ..< end {
		lineEnsureCol(line, off + i)
		line.cells[off + i] = erase
	}
	sanitizeWidePairs(line, off, off + cols) // 擦除端点可能落在宽字对中间(段内)
	tb.screen_dirty = true
}

// DCH:删除光标起 n 字符,右侧左移补空白。
// 两个约束:
//   ① 删除范围按**行宽 cols** 计,不按该行已分配的 cells 长度 —— cells 只因"写过的
//      最大列"增长,而光标可被 CUP 移到任意合法列,于是 len(cells) - col 为负;
//   ② 左移只在 **[0, cols) 窗口内**做,不能用 remove_range 搬整个数组 —— 数组尾
//      可能留着缩窄前的旧列,整体左移会把它们挪进可见区。
// (修复前 ① 触发内建检查 panic:ESC[1;40H 后 ESC[1P → "Invalid slice indices
//  39:3 is out of range 0..<3",进程直接退出。)
vtDeleteChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	line_idx, off := cursorSegment(console, tb)
	if line_idx >= len(tb.lines) {
		return
	}
	line := &tb.lines[line_idx]
	cols := max(1, int(console.cols))
	col := min(int(console.cursor_col), cols - 1)
	nn := min(n, cols - col)
	if nn <= 0 {
		return
	}
	lineEnsureCol(line, off + cols - 1) // 段内定宽:下面按格读写的下标都有实体
	for i in col ..< cols - nn {
		line.cells[off + i] = line.cells[off + i + nn]
	}
	erase := eraseCell(console)
	for i in cols - nn ..< cols {
		line.cells[off + i] = erase
	}
	sanitizeWidePairs(line, off, off + cols) // 左移会把宽字对从段内边界处劈开
	tb.screen_dirty = true
}

// ICH:光标处插入 n 空白字符,右侧挤出
vtInsertChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	line_idx, off := cursorSegment(console, tb)
	for len(tb.lines) <= line_idx {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[line_idx]
	cols := max(1, int(console.cols))
	for len(line.cells) < off + cols {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
	col := min(int(console.cursor_col), cols - 1)
	nn := min(n, cols - col)
	if nn <= 0 {
		return
	}
	copy(line.cells[off + col + nn:], line.cells[off + col:off + cols - nn])
	erase := eraseCell(console)
	for i in col ..< col + nn {
		line.cells[off + i] = erase
	}
	sanitizeWidePairs(line, off, off + cols) // 右移会把宽字对从段内边界处劈开
	tb.screen_dirty = true
}

// IL:光标处插入 n 空行,滚动区底行被挤出
vtInsertLines :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	// IL/DL 是**屏幕行**级操作:先让滚动区内的每个屏幕行都恰好是一条逻辑行
	// (长行按段边界拆开 —— 内容与画面都不动,只是拆成多条行),之后行级搬移才正确。
	splitRowsInRegion(console_h, console, tb)
	row, _ := cursorSegment(console, tb)
	bottom := int(console.rows) - 1 // 拆完之后:屏幕行 r ↔ 逻辑行(锚点行 + r)
	bottom = viewportTop(console, tb) + int(console.vt.scroll_bottom)
	for i in 0 ..< n {
		for len(tb.lines) <= bottom {
			append(&tb.lines, Line{})
		}
		if bottom < len(tb.lines) {
			delete(tb.lines[bottom].cells)
			remove_range(&tb.lines, bottom, bottom + 1)
		}
		insertLine(&tb.lines, row)
	}
	cursorSegmentInvalidate(console)
	tb.screen_dirty = true
}

// 把滚动区 [scroll_top, scroll_bottom] 内的屏幕行拆成"一行一段":
// 区域级搬移是按行做的,跨多段的长行必须先按段边界拆开,否则会整条被搬走。
splitRowsInRegion :: proc(console_h : mem.Handle, console : ^Console, tb : ^TermBuffer) {
	top := int(console.vt.scroll_top)
	bottom := int(console.vt.scroll_bottom)
	for r in top ..= bottom {
		screenEnsure(console, tb)
		if r >= len(tb.screen) {
			return
		}
		e := tb.screen[r]
		if int(e.line) >= len(tb.lines) {
			return
		}
		if e.offset != 0 {
			splitLineAt(tb, int(e.line), int(e.offset))
			cursorSegmentInvalidate(console)
		}
	}
}

// DL:删除光标处 n 行,滚动区底补空行
vtDeleteLines :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	splitRowsInRegion(console_h, console, tb) // 同 IL:先按段边界拆开,行级搬移才正确
	row, _ := cursorSegment(console, tb)
	bottom := viewportTop(console, tb) + int(console.vt.scroll_bottom)
	actual := 0
	for i in 0 ..< n {
		if row >= len(tb.lines) {
			break
		}
		delete(tb.lines[row].cells)
		remove_range(&tb.lines, row, row + 1)
		insertLine(&tb.lines, bottom)
		actual += 1
	}
	// 选区通报:删 [row, row+actual) + 底补 actual 空行
	cursorSegmentInvalidate(console)
	tb.screen_dirty = true
}

