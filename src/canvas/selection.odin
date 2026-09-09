// 文本选区数据(Selection):buffer 坐标系内容标志 + 区间判定/平移/提取/剪贴板动作。
// 坐标系 = TermBuffer 物理 (line, col):内容在,选区在 —— 窗口/页/焦点变化免疫;
// 内容结构变化(插/删行、插/删字符)经 buffer 写路径通报平移;锚点内容被删 → 清。
// host = 持有 buffer 的 console(换算/提取几何);渲染经 active buffer 比较,不经 host 查找。
// userapi 动作:CopySelection / PasteClipboard / SelectionClear / SelectionAttach。
package canvas

import fnt "../font"
import inp "../input"
import mem "../memory"
import "core:strings"

SelectionPoint :: struct {
	line : int, // buffer 物理行(0..len(lines)-1)
	col : int, // 列(0..cols-1;宽字符续列左移到字首)
}

Selection :: struct {
	active : bool, // press 未释放;false = 定稿(高亮保留)
	buffer_h : mem.Handle, // 坐标系锚:选区所属 TermBuffer
	host : mem.Handle, // 宿主 console(持有 buffer 的那个;0 = 无)
	pivot : SelectionPoint, // 锚点
	cur : SelectionPoint, // 当前点
}

selection : Selection

// 连击时序状态(仅内容区左键 press 时更新;与 Selection 生命周期无关)
ClickState :: struct {
	time_ms : u64, // 上次内容区左键 press 时间戳
	buffer_h : mem.Handle, // 上次 press 的 buffer(跨 buffer 连击重置)
	line : int, // 上次 press 格(buffer 坐标,规范化后)
	col : int,
	chain : u8, // 连击段:1 单击起 / 2 双击(词)/ 3 三击(行,封顶)
}

click : ClickState

WORD_CLICK_MS :: 500 // 连击阈值(毫秒)

// 连击裁决:同 buffer + 同格 + 间隔 < 阈值 → chain+1(封顶 3);否则重置 1。
// 更新记录后返回本次等级(路由按 2 = 词选 / 3 = 行选 分派)。
clickChain :: proc(buffer_h : mem.Handle, line, col : int) -> u8 {
	ticks := inp.NowTicks()
	if click.buffer_h == buffer_h && click.line == line && click.col == col &&
		click.chain >= 1 && ticks - click.time_ms < WORD_CLICK_MS {
		click.chain = min(click.chain + 1, 3)
	} else {
		click.chain = 1
	}
	click.time_ms = ticks
	click.buffer_h = buffer_h
	click.line = line
	click.col = col
	return click.chain
}

// 有效 = 坐标系数据链完整(buffer 在、宿主未换 active、锚行在界)。列越界不判失效
// (内容语义仍在),行越界说明内容没了(裁剪/清屏/行删除未平移) → 失效。
SelectionValid :: proc() -> bool {
	if selection.buffer_h.id == 0 {
		return false
	}
	tb := GetTermBuffer(selection.buffer_h)
	if tb == nil {
		return false
	}
	console := GetConsole(selection.host)
	if console == nil || console.active_term_buffer_id != selection.buffer_h {
		return false
	}
	if selection.pivot.line < 0 || selection.pivot.line >= len(tb.lines) {
		return false
	}
	if selection.cur.line < 0 || selection.cur.line >= len(tb.lines) {
		return false
	}
	return true
}

// 每帧自愈(ProcessMouse 前);失效即清。
SelectionValidate :: proc() {
	if !SelectionValid() {
		SelectionClear()
	}
}

SelectionClear :: proc() {
	selection = {}
}

// 当前被选 buffer(渲染比较用;0 = 无选区)
SelectionBuffer :: proc() -> mem.Handle {
	return selection.buffer_h
}

// 程序化设定选区(守卫:host 反查 + active 链;正常路径经 SelectionBegin 鼠标建立)。
// 用途:测试探针 / "全选"等用户动作。锚点规范化到整字边界。
SelectionAttach :: proc(buffer_h : mem.Handle, pivot, cur : SelectionPoint) -> bool {
	if GetTermBuffer(buffer_h) == nil {
		return false
	}
	host := hostConsoleFor(buffer_h)
	if host.id == 0 {
		return false
	}
	selection = Selection {
		active = true,
		buffer_h = buffer_h,
		host = host,
		pivot = pivot,
		cur = cur,
	}
	selectionNormalize()
	return true
}

// 持有 buffer 的 console(反查:buffer ↔ console 1:1 登记,无反向索引,遍历)
hostConsoleFor :: proc(buffer_h : mem.Handle) -> mem.Handle {
	it : mem.Iter(MAX_CONSOLE_SLOTS, Console) = mem.All(&consoles)
	for ch in mem.next(&it) {
		if c := mem.Get(&consoles, ch); c != nil && c.active_term_buffer_id == buffer_h {
			return ch
		}
	}
	return {}
}

// ---------------------------------------------------------------------------
// 鼠标建立(路由调用):命中窗口 → 屏幕行列 → buffer 坐标
// ---------------------------------------------------------------------------
// 屏幕 → buffer 网格(clamp 到网格边界)。规范化在 selectionNormalize(方向定后)。
screenToBuffer :: proc(console : ^Console, tb : ^TermBuffer, top : int, m : fnt.Metrics, x, y : f32) -> (line, col : int) {
	row := clamp(int((y - console.origin_y) / m.cell_height), 0, int(console.rows) - 1)
	col = clamp(int((x - console.origin_x) / m.cell_width), 0, int(console.cols) - 1)
	return top + row, col
}

// 宽字符边界规范化(方向感知):起点在续列 → 左移入字首;终点在续列 → 右移包含整字。
// 空选区(pivot == cur)不规范化(点击宽字后半 = 空选择,不产生格)。
selectionNormalize :: proc() {
	tb := GetTermBuffer(selection.buffer_h)
	if tb == nil {
		return
	}
	if selection.pivot.line == selection.cur.line && selection.pivot.col == selection.cur.col {
		return
	}
	p_first := selection.pivot.line < selection.cur.line ||
		(selection.pivot.line == selection.cur.line && selection.pivot.col < selection.cur.col)
	if p_first {
		normalizeStart(tb, selection.pivot.line, &selection.pivot.col)
		normalizeEnd(tb, selection.cur.line, &selection.cur.col)
	} else {
		normalizeStart(tb, selection.cur.line, &selection.cur.col)
		normalizeEnd(tb, selection.pivot.line, &selection.pivot.col)
	}
}

normalizeStart :: proc(tb : ^TermBuffer, line : int, col : ^int) {
	if line < 0 || line >= len(tb.lines) {
		return
	}
	cells := tb.lines[line].cells
	if col^ > 0 && col^ < len(cells) && cells[col^].cp == 0 && cells[col^].wide {
		col^ -= 1
	}
}

normalizeEnd :: proc(tb : ^TermBuffer, line : int, col : ^int) {
	if line < 0 || line >= len(tb.lines) {
		return
	}
	cells := tb.lines[line].cells
	if col^ > 0 && col^ < len(cells) && cells[col^].cp == 0 && cells[col^].wide {
		col^ += 1 // 包含整个宽字(续列 → 下一字首)
	}
}

selectionBegin :: proc(node_h : mem.Handle, x, y : f32) -> bool {
	console_h := NodeConsoleId(node_h)
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	m := fnt.GetMetrics(console.font_id)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return false
	}
	top, _ := ConsoleViewportTop(console_h)
	line, col := screenToBuffer(console, tb, top, m, x, y)
	selection = Selection {
		active = true,
		buffer_h = console.active_term_buffer_id,
		host = console_h,
		pivot = { line = line, col = col },
		cur = { line = line, col = col },
	}
	return true
}

selectionUpdate :: proc(x, y : f32) -> bool {
	if !SelectionValid() {
		return false
	}
	console := GetConsole(selection.host)
	tb := GetTermBuffer(selection.buffer_h)
	fh := hostFont()
	if console == nil || tb == nil || fh.id == 0 {
		return false
	}
	m := fnt.GetMetrics(fh)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return false
	}
	top, _ := ConsoleViewportTop(selection.host)
	line, col := screenToBuffer(console, tb, top, m, x, y)
	selection.cur = SelectionPoint { line = line, col = col }
	selectionNormalize()
	return true
}

// 宿主 console 的字体(selection.host 就是 console 句柄:一次解码,无反向索引)
hostFont :: proc() -> mem.Handle {
	console := GetConsole(selection.host)
	if console == nil {
		return {}
	}
	return console.font_id
}

// ---------------------------------------------------------------------------
// 区间判定(渲染/光标用;调用方保证有效,此处只算区间)
// ---------------------------------------------------------------------------
// 格 (line, col) 宽 w 是否被选(与选区区间相交;w = 字符占列数)。
// 行逻辑:首行 [lo.col, cols),中间全宽 [0, cols),尾行 [0, hi.col);同行 [lo.col, hi.col)。
CellSelected :: proc(line, col, w, cols : int) -> bool {
	p, c := selection.pivot, selection.cur
	lo, hi := p, c
	if c.line < p.line || (c.line == p.line && c.col < p.col) {
		lo, hi = c, p
	}
	if line < lo.line || line > hi.line {
		return false
	}
	s, e : int
	if lo.line == hi.line {
		s, e = lo.col, hi.col
	} else if line == lo.line {
		s, e = lo.col, cols
	} else if line == hi.line {
		s, e = 0, hi.col
	} else {
		s, e = 0, cols
	}
	if e <= s {
		return false // 空区间(点击即放/同点):无格被选
	}
	return col < e && col + w > s
}

// ---------------------------------------------------------------------------
// 文本提取(纯函数,测试直接用;冷路径分配一次)
// ---------------------------------------------------------------------------
// 规则:区间内逐字(跳过续列)取 cp;行内跳过未写格(cp==0);每行尾随空格 trim;
// 行间分隔 \r\n,但 lines[i].wrapped(由上一行折行)→ 分隔 ""(软换行拼接)。
ExtractSelectionText :: proc() -> []u8 {
	if !SelectionValid() {
		return nil
	}
	tb := GetTermBuffer(selection.buffer_h)
	console := GetConsole(selection.host)
	cols := int(console.cols)
	p, c := selection.pivot, selection.cur
	lo, hi := p, c
	if c.line < p.line || (c.line == p.line && c.col < p.col) {
		lo, hi = c, p
	}
	runes := make([dynamic]rune)
	defer delete(runes)
	b : strings.Builder
	defer strings.builder_destroy(&b)
	for line_idx in lo.line ..= hi.line {
		if line_idx >= len(tb.lines) {
			break
		}
		line := &tb.lines[line_idx]
		if line_idx > lo.line {
			// 软换行:本行由上一行折行而来 → 无分隔符(拼接)
			if !line.wrapped {
				strings.write_string(&b, "\r\n")
			}
		}
		s := 0
		e := cols
		if lo.line == hi.line {
			s, e = lo.col, hi.col
		} else if line_idx == lo.line {
			s, e = lo.col, cols
		} else if line_idx == hi.line {
			s, e = 0, hi.col
		}
		e = min(e, len(line.cells))
		clear(&runes)
		for col := s; col < e; col += 1 {
			cell := line.cells[col]
			if cell.cp == 0 {
				continue // 未写格/宽字符续列
			}
			append(&runes, cell.cp)
		}
		// 行尾 trim 空格
		for len(runes) > 0 && runes[len(runes) - 1] == ' ' {
			resize(&runes, len(runes) - 1)
		}
		for r in runes {
			strings.write_rune(&b, r)
		}
	}
	out := make([]byte, len(b.buf))
	copy(out, b.buf[:])
	return out
}

// ---------------------------------------------------------------------------
// 平移通报(buffer 写路径调用;仅坐标系有效时动作,结构变化前后均安全)
// ---------------------------------------------------------------------------
selectionLineInsert :: proc(at, n : int) {
	if selection.buffer_h.id == 0 {
		return
	}
	if selection.pivot.line >= at {
		selection.pivot.line += n
	}
	if selection.cur.line >= at {
		selection.cur.line += n
	}
}

// 删除 [from, from+n):锚在被删内容 → 清;否则平移 -n
selectionLineDelete :: proc(from, n : int) {
	if selection.buffer_h.id == 0 {
		return
	}
	pk := selection.pivot.line >= from && selection.pivot.line < from + n
	ck := selection.cur.line >= from && selection.cur.line < from + n
	if pk || ck {
		SelectionClear()
		return
	}
	if selection.pivot.line >= from + n {
		selection.pivot.line -= n
	}
	if selection.cur.line >= from + n {
		selection.cur.line -= n
	}
}

selectionColInsert :: proc(row, at, n : int) {
	if selection.buffer_h.id == 0 {
		return
	}
	if selection.pivot.line == row && selection.pivot.col >= at {
		selection.pivot.col += n
	}
	if selection.cur.line == row && selection.cur.col >= at {
		selection.cur.col += n
	}
	selectionNormalize()
}

selectionColDelete :: proc(row, from, n : int) {
	if selection.buffer_h.id == 0 {
		return
	}
	if selection.pivot.line == row {
		pc := selection.pivot.col
		if pc >= from && pc < from + n {
			SelectionClear()
			return
		}
		if pc >= from + n {
			selection.pivot.col -= n
		}
	}
	if selection.cur.line == row {
		cc := selection.cur.col
		if cc >= from && cc < from + n {
			SelectionClear()
			return
		}
		if cc >= from + n {
			selection.cur.col -= n
		}
	}
	selectionNormalize()
}

// ---------------------------------------------------------------------------
// 词/行选择(M3):双击词选 / 三击行选 / 全选
// ---------------------------------------------------------------------------
// 词字符:ascii 字母/数字/下划线 + 非 ascii(中文/emoji);分隔符 = ascii 空格/标点。
isWordChar :: proc(cp : rune) -> bool {
	if cp == 0 {
		return false
	}
	if cp < 0x80 {
		switch {
		case cp >= '0' && cp <= '9': return true
		case cp >= 'a' && cp <= 'z': return true
		case cp >= 'A' && cp <= 'Z': return true
		case cp == '_': return true
		}
		return false
	}
	if cp == ' ' || (cp >= 0x09 && cp <= 0x0D) {
		return false
	}
	return true // 非 ascii 非空白(中文/emoji)→ 词字符(连续成段)
}

// 词区间 [start, end):点击格向左右扫词字符;点击在分隔符(空格/标点)→ 单格。
// 宽字符:续列属于词内(向左跨越 2 格);端点恒在字首。
wordExtent :: proc(tb : ^TermBuffer, line, col : int) -> (start, end : int) {
	if line < 0 || line >= len(tb.lines) {
		return col, col + 1
	}
	cells := tb.lines[line].cells
	c := col
	if c > 0 && c < len(cells) && cells[c].cp == 0 && cells[c].wide {
		c -= 1 // 续列 → 字首
	}
	if c < 0 || c >= len(cells) || !isWordChar(cells[c].cp) {
		return c, c + 1
	}
	start = c
	for start > 0 {
		if cells[start - 1].cp != 0 {
			if isWordChar(cells[start - 1].cp) {
				start -= 1
			} else {
				break
			}
		} else if cells[start - 1].wide && start >= 2 && cells[start - 2].cp != 0 && cells[start - 2].wide {
			start -= 2 // 续列:跨越到其首格(词字符)
		} else {
			break
		}
	}
	end = c
	for {
		if end >= len(cells) {
			break
		}
		cell := cells[end]
		if cell.cp != 0 {
			if isWordChar(cell.cp) {
				end += 1
			} else {
				break
			}
		} else if cell.wide {
			end += 1 // 续列(词内)
		} else {
			break
		}
	}
	return start, end
}

// 双击语义:词选(active 保持,拖动交给现有 cur 更新)
SelectionSetWord :: proc(buffer_h : mem.Handle, line, col : int) -> bool {
	tb := GetTermBuffer(buffer_h)
	if tb == nil {
		return false
	}
	host := hostConsoleFor(buffer_h)
	if host.id == 0 || line < 0 || line >= len(tb.lines) {
		return false
	}
	start, end := wordExtent(tb, line, col)
	selection = Selection {
		active = true,
		buffer_h = buffer_h,
		host = host,
		pivot = { line = line, col = start },
		cur = { line = line, col = end },
	}
	return true
}

// 三击语义:整行选 [0, cols)
SelectionSetLine :: proc(buffer_h : mem.Handle, line : int) -> bool {
	tb := GetTermBuffer(buffer_h)
	if tb == nil {
		return false
	}
	host := hostConsoleFor(buffer_h)
	if host.id == 0 || line < 0 || line >= len(tb.lines) {
		return false
	}
	console := GetConsole(host)
	selection = Selection {
		active = true,
		buffer_h = buffer_h,
		host = host,
		pivot = { line = line, col = 0 },
		cur = { line = line, col = int(console.cols) },
	}
	return true
}

// 全选:焦点窗口 console 的 active buffer 全区间
SelectionSelectAll :: proc() -> bool {
	node_h := GetFocusWindow()
	if node_h.id == 0 {
		return false
	}
	console_h := NodeConsoleId(node_h)
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil || len(tb.lines) == 0 {
		return false
	}
	selection = Selection {
		active = true,
		buffer_h = console.active_term_buffer_id,
		host = console_h,
		pivot = { line = 0, col = 0 },
		cur = { line = len(tb.lines) - 1, col = int(console.cols) },
	}
	return true
}

// ---------------------------------------------------------------------------
// userapi 动作
// ---------------------------------------------------------------------------
// 复制(文本只写剪贴板;无选区/空选区 = 空操作)选区保留
CopySelection :: proc() -> bool {
	if !SelectionValid() {
		return false
	}
	txt := ExtractSelectionText()
	if txt == nil || len(txt) == 0 {
		return false
	}
	defer delete(txt)
	return inp.SetClipboardText(txt)
}

// 粘贴到焦点窗口(与键输入同路径:FeedConsole 统一承担退出 review;剪贴板空/无焦点 = false)
PasteClipboard :: proc() -> bool {
	data := inp.GetClipboardText()
	if len(data) == 0 {
		return false
	}
	defer delete(data)
	return FeedConsole(data)
}
