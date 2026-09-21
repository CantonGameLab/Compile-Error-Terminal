// 内容层数据:Cell/CellStyle/Line/TermBuffer(物理行网格 + 历史 + review 视口锚)。
// 生命周期 + 写路径(rune 落格/折行/滚动/擦除/插入/裁剪/重排)全部收拢于此;
// review_top 为历史视口唯一真值(0 = 普通实时,1.. = 顶行物理索引 + 1)。
//
// 逐行模型(对齐 alacritty / Windows Terminal):
//   · 一行 = 一个屏幕行(物理行);内容存不下就**新开一行**并给新行打 `wrapped`
//     标记(软折行续行),硬换行 = 新行且无标记。
//   · 屏幕第 r 行 ↔ lines[viewportBase + r] —— 行号一一对应,应用用 CUP 定位到的
//     行就是它上次自动折行落到的行。TUI(vim 等)把"自动折行"和"绝对定位"混用时,
//     这个对应关系是增量重绘正确的前提(旧"逻辑行 + 段派生"模型在这里会错行)。
//   · 历史 = lines[0 .. viewportBase);贴底时 viewportBase = len - rows(屏幕始终
//     物化 rows 行:create/clear/reflow 都补齐,写入不再现算)。
//   · 重排(reflow):cols 变化时按 `wrapped` 串合并逻辑行、按新宽度重切;光标/选区/
//     review 锚点用"流内偏移"随动。
//   · 宽字对不跨行:切分点落在宽字首格时整对推到下一行(与写入路径"放不下先折行"
//     同一条规则)。
package canvas

import mem "../memory"

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

// 物理行:
//   cells   = 本行内容(可短于 cols,缺格按空白;末尾空白不再是"补齐"语义,
//             因为行与屏幕行一一对应,不再有段派生)
//   wrapped = true 表示本行是上一行的**软折行续行**(reflow 时与上一行合并)
Line :: struct {
	cells : [dynamic]Cell,
	wrapped : bool,
}

// ---------------------------------------------------------------------------
// TermBuffer
// ---------------------------------------------------------------------------
// 容量依据:每 console 最多 2 个 buffer(主屏 + 交替屏),console 上限见 console.odin
MAX_TERM_BUFFER_SLOTS :: 128

MAX_SCROLLBACK_LINES :: 10000

TRIM_SLACK :: 512 // 超上限这么多行才裁,避免频繁搬行

TermBuffer :: struct {
	lines : [dynamic]Line, // 历史 + 屏幕;**不变量:len >= rows**(create/clear/reflow 补齐)
	// 历史视口锚点(顶行物理索引 + 1):
	//   review_top = 0       = 活窗口(贴底跟随)
	//   review_top = n (1..) = review,视口顶行 = lines[n-1]
	review_top : u32,
	cols : u16, // 本页内容按哪个列宽折的行(reflow 的旧宽度;切页/resize 后仍可精确重排)
}

term_buffers : mem.GenArray(MAX_TERM_BUFFER_SLOTS, TermBuffer)

CreateTermBuffer :: proc(rows, cols : u16) -> (h : mem.Handle, ok : bool) {
	lines := make([dynamic]Line)
	for _ in 0 ..< max(1, int(rows)) {
		append(&lines, Line{})
	}
	h = mem.Alloc(&term_buffers, TermBuffer { lines = lines, cols = cols })
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
	mem.Free(&term_buffers, h)
}

// 清空全部行(1049 进交替屏 / RIS / DECCOLM)。屏幕必须重新物化 rows 行。
TermBufferClear :: proc(h : mem.Handle, rows, cols : u16) {
	tb := GetTermBuffer(h)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	clear(&tb.lines)
	for _ in 0 ..< max(1, int(rows)) {
		append(&tb.lines, Line{})
	}
	tb.review_top = 0
	tb.cols = cols
	SelectionClear() // 内容全没了,选区同步失效
}

// 补齐到至少 rows 行(create/clear/reflow 后调用;补的都是硬性空行)
ensureTermRows :: proc(tb : ^TermBuffer, rows : int) {
	if tb == nil {
		return
	}
	for len(tb.lines) < rows {
		append(&tb.lines, Line{})
	}
}

// ---------------------------------------------------------------------------
// 视口换算(逐行模型下就是线性下标;唯一入口,禁止散落 base + r)
// ---------------------------------------------------------------------------
// 活窗口顶行(贴底):len - rows。不变量保证 >= 0。
liveBase :: proc(tb : ^TermBuffer, rows : int) -> int {
	if tb == nil {
		return 0
	}
	return max(0, len(tb.lines) - rows)
}

// 显示视口顶行:review 用锚点,否则活窗口。显示的屏幕行 r ↔ lines[base + r]。
viewportBase :: proc(console : ^Console, tb : ^TermBuffer) -> int {
	if tb == nil || console == nil {
		return 0
	}
	live := liveBase(tb, int(console.rows))
	if tb.review_top != 0 {
		return clamp(int(tb.review_top) - 1, 0, live)
	}
	return live
}

// 写入/光标寻址的物理行(活窗口):屏幕行 r 对应的行;数组不足 rows 时补空行。
// 注意与 viewportBase 的区别:写路径永远以**活窗口**为准(review 时也写实时内容)。
termLineForWrite :: proc(console : ^Console, tb : ^TermBuffer, r : int) -> int {
	base := liveBase(tb, int(console.rows))
	idx := base + clamp(r, 0, int(console.rows) - 1)
	for len(tb.lines) <= idx {
		append(&tb.lines, Line{})
	}
	return idx
}

// 屏幕第 r 行 → 缓冲行号;-1 = 越界/无内容(显示视口口径,review 时给历史行)
screenLineAt :: proc(console : ^Console, tb : ^TermBuffer, r : int) -> int {
	if tb == nil || console == nil || r < 0 || r >= int(console.rows) {
		return -1
	}
	base := viewportBase(console, tb)
	if base + r >= len(tb.lines) {
		return -1
	}
	return base + r
}

// 缓冲行号 → 屏幕第 r 行;-1 = 不在当前可视窗里
screenRowFor :: proc(console : ^Console, tb : ^TermBuffer, line : int) -> int {
	if tb == nil || console == nil {
		return -1
	}
	base := viewportBase(console, tb)
	r := line - base
	if r < 0 || r >= int(console.rows) {
		return -1
	}
	return r
}

// 屏幕第 r 行 → 缓冲行号(跨包入口;-1 = 越界)
ConsoleScreenLine :: proc(console_h : mem.Handle, r : int) -> int {
	console := GetConsole(console_h)
	if console == nil {
		return -1
	}
	return screenLineAt(console, GetTermBuffer(console.active_term_buffer_id), r)
}

// 屏幕第 r 行的段:逐行模型恒 (行号, 0)(旧段模型的接口保留给渲染)
ConsoleScreenSegment :: proc(console_h : mem.Handle, r : int) -> (line, offset : int) {
	line = ConsoleScreenLine(console_h, r)
	if line < 0 {
		return -1, 0
	}
	return line, 0
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

// 行的内容长度(末尾空白之外的正文长度);视觉行宽 = 至少铺满屏幕宽
LineExtent :: proc(cells : []Cell) -> int {
	n := len(cells)
	for n > 0 && cells[n - 1].cp == 0 && !cells[n - 1].wide {
		n -= 1
	}
	return n
}

LineWidth :: proc(cells : []Cell, cols : int) -> int {
	return max(cols, LineExtent(cells))
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

// ---------------------------------------------------------------------------
// 写路径(落格 / 折行 / 滚动)
// ---------------------------------------------------------------------------
// 折行一次:光标下移一行(到滚动区底则上滚),列归 0,新行标记为软续行。
// 内容不切分 —— 只是"换到下一物理行写",行与屏幕行一一对应。
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
		vtScrollUp(console_h)
	}
	idx := termLineForWrite(console, tb, int(console.cursor_row))
	tb.lines[idx].wrapped = true
	console.cursor_col = 0
}

// 落格 → 前进 → 最后一列置 wrap-pending(下一字符才折行)。
// 最后列放不下宽字时先折行(xterm 语义;autowrap 关时不折、原地覆盖)。
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
	did_wrap := false
	if console.vt.wrap_pending {
		console.vt.wrap_pending = false
		if console.vt.autowrap {
			vtWrapOnce(console_h)
			did_wrap = true
		} else {
			console.cursor_col = console.cols - 1
		}
	}
	w := runeWidth(cp)
	col := int(console.cursor_col)
	// 宽字符放不下当前列(只剩 1 列):先折行再写(xterm 语义)
	if w == 2 && col + w > int(console.cols) {
		vtWrapOnce(console_h)
		did_wrap = true
		col = int(console.cursor_col)
	}
	idx := termLineForWrite(console, tb, int(console.cursor_row))
	line := &tb.lines[idx]
	// 显式定位到行首写字(不是刚折行过来)= 覆盖重绘 = 硬行起点:
	// 清掉上一条软折行留下的 `wrapped`(否则 reflow 会把两行错误合并)。
	if col == 0 && !did_wrap {
		line.wrapped = false
	}
	for len(line.cells) <= col + w - 1 {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
	// 宽字对守卫(热路径局部):写入点两端的宽字对若被这次写入劈开,先清掉半个。
	// 必须**清成空白格**而不是只降 wide 标志:渲染层按格号落字形、根本不看 wide,
	// 悬空首格照样按宽字形画出来压到右邻居 —— 那正是"个别汉字重叠"的形态。
	unpairWideAt(line, col, col + w - 1)
	line.cells[col] = Cell { cp = cp, style = style, wide = w == 2 }
	if w == 2 {
		line.cells[col + 1] = Cell { style = style, wide = true } // 续列继承样式(背景)
	}

	console.cursor_col += u16(w)
	if console.cursor_col >= console.cols {
		// 写满最后一列:光标停最后一列,置 pending,等下一字符决定折行
		console.cursor_col = console.cols - 1
		console.vt.wrap_pending = console.vt.autowrap
	}
	return true
}

// 滚动区上移一行。全屏:**行数组尾部增长**,顶行滚进历史(窗口贴底 ⇒ 屏幕自然上移);
// 区域:顶行丢弃,底行补空行。逐行模型下不再需要任何拆行预处理。
vtScrollUp :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if console.vt.scroll_top == 0 && console.vt.scroll_bottom == console.rows - 1 {
		append(&tb.lines, Line{})
		trimScrollback(console_h)
		return
	}
	base := liveBase(tb, int(console.rows))
	top := base + int(console.vt.scroll_top)
	bottom := base + int(console.vt.scroll_bottom)
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[top].cells)
	remove_range(&tb.lines, top, top + 1)
	insertLine(&tb.lines, bottom)
}

// 滚动区下移一行:底行丢弃,顶行补空行(全屏同一条路径:底 = 数组尾)
vtScrollDown :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := liveBase(tb, int(console.rows))
	top := base + int(console.vt.scroll_top)
	bottom := base + int(console.vt.scroll_bottom)
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[bottom].cells)
	remove_range(&tb.lines, bottom, bottom + 1)
	insertLine(&tb.lines, top)
}

// core:slice 无 insert 的替代实现(插入零值 Line)
insertLine :: proc(lines : ^[dynamic]Line, index : int) {
	append(lines, Line{})
	copy(lines[index + 1:], lines[index:len(lines) - 1])
	lines[index] = Line{}
}

// 从行数组头部裁掉 cut 行(历史永久丢弃),同步 review 锚定。
// cut 不得越过窗口顶行:裁进屏内会把还看得见的内容丢掉;光标是屏幕坐标,不受影响。
cutHistoryHead :: proc(console_h : mem.Handle, cut : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil || cut <= 0 || cut > len(tb.lines) {
		return
	}
	guard := liveBase(tb, int(console.rows))
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
	// review 锚点随裁剪平移;锚点本身被裁掉 ⇒ 回到最新
	if tb.review_top != 0 {
		rl := int(tb.review_top) - 1 - cut
		if rl < 0 {
			tb.review_top = 0
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

// 活窗口屏幕行 r 的行(写路径;数组不足 rows 时补空行)
liveRow :: proc(console : ^Console, tb : ^TermBuffer, r : int) -> ^Line {
	idx := termLineForWrite(console, tb, r)
	return &tb.lines[idx]
}

// ---------------------------------------------------------------------------
// 擦除 / 插入 / 删除(全部按物理行的 [0, cols) 列算术)
// ---------------------------------------------------------------------------
// mode:0 到行尾 / 1 到行首 / 2 整行
// 清 wrap-pending:xterm 的 EL(ClearRight/ClearInLine)会 ResetWrap —— 不清的话,
// 应用"写满末列 + 擦行 + 写字"会被折到下一行,而 xterm 是在原列覆盖。
vtEraseInLine :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	console.vt.wrap_pending = false
	line := liveRow(console, tb, int(console.cursor_row))
	erase := eraseCell(console)
	cols := int(console.cols)
	col := int(console.cursor_col)
	switch mode {
	case 0:
		for i in col ..< cols {
			lineEnsureCol(line, i)
			line.cells[i] = erase
		}
	case 1:
		for i in 0 ..= col {
			lineEnsureCol(line, i)
			line.cells[i] = erase
		}
	case 2:
		for i in 0 ..< cols {
			lineEnsureCol(line, i)
			line.cells[i] = erase
		}
		line.wrapped = false // 整行擦除 = 硬行(不再与上一行成折行串)
	}
	sanitizeWidePairs(line, 0, cols) // 擦除端点可能落在宽字对中间
}

// mode:0 光标到屏尾 / 1 屏头到光标 / 2 可视区 / 3 只清 scrollback(历史,不动可视屏)
// 扫描一律按**屏幕行**(xterm 语义:擦的是屏幕);逐行模型下行号直接对应,不再换算。
// 关键:目标只能是**实时窗口**(liveBase),不能是显示视口 —— 应用(clear/全屏重绘)操作的
// 是它自己那一屏;用户回看历史(review)时 ED 若清显示视口,就会把历史擦掉、画面在回看
// 位置被改写,看起来就是"清屏时好时坏"。EL/ECH/DCH/写入本来就走 liveRow,这里对齐。
vtEraseInDisplay :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if mode != 3 {
		console.vt.wrap_pending = false // ED 0/1/2 同 xterm(ClearScreen/ClearBelow/ClearAbove)
	}
	base := liveBase(tb, int(console.rows))
	erase := eraseCell(console)
	cols := int(console.cols)
	clearRow := proc(line : ^Line, erase : Cell, cols : int) {
		for i in 0 ..< cols {
			lineEnsureCol(line, i)
			line.cells[i] = erase
		}
		sanitizeWidePairs(line, 0, cols)
		line.wrapped = false // 整行擦除 = 硬行
	}
	switch mode {
	case 0:
		vtEraseInLine(console_h, 0)
		for r in int(console.cursor_row) + 1 ..< int(console.rows) {
			if idx := base + r; idx < len(tb.lines) {
				clearRow(&tb.lines[idx], erase, cols)
			}
		}
	case 1:
		for r in 0 ..< int(console.cursor_row) {
			if idx := base + r; idx < len(tb.lines) {
				clearRow(&tb.lines[idx], erase, cols)
			}
		}
		vtEraseInLine(console_h, 1)
	case 2:
		for r in 0 ..< int(console.rows) {
			if idx := base + r; idx < len(tb.lines) {
				clearRow(&tb.lines[idx], erase, cols)
			}
		}
	case 3:
		// ED 3 = Erase Saved Lines:只擦实时屏之上已滚出的历史,实时屏与光标都不许动。
		// review 看的就是历史 —— 应用要求删除已滚出行,历史必须真的没了:先回最新
		// (否则 cutHistoryHead 的 review 守卫会拒裁,退出 review 后旧内容又冒出来),
		// 再裁掉实时屏之上的全部行。
		tb.review_top = 0
		cutHistoryHead(console_h, liveBase(tb, int(console.rows)))
	}
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
	console.vt.wrap_pending = false // ECH 同 xterm(ClearRight)
	line := liveRow(console, tb, int(console.cursor_row))
	start := int(console.cursor_col)
	cols := int(console.cols)
	end := min(start + n, cols)
	erase := eraseCell(console)
	for i in start ..< end {
		lineEnsureCol(line, i)
		line.cells[i] = erase
	}
	sanitizeWidePairs(line, 0, cols) // 擦除端点可能落在宽字对中间
}

// DCH:删除光标起 n 字符,右侧左移补空白。
// 两个约束:
//   ① 删除范围按**行宽 cols** 计,不按该行已分配的 cells 长度 —— cells 只因"写过的
//      最大列"增长,而光标可被 CUP 移到任意合法列,于是 len(cells) - col 为负;
//   ② 左移只在 **[0, cols) 窗口内**做,不能用 remove_range 搬整个数组。
vtDeleteChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	console.vt.wrap_pending = false // DCH 同 xterm(DeleteChar)
	line := liveRow(console, tb, int(console.cursor_row))
	cols := max(1, int(console.cols))
	col := min(int(console.cursor_col), cols - 1)
	nn := min(n, cols - col)
	if nn <= 0 {
		return
	}
	lineEnsureCol(line, cols - 1) // 定宽:下面按格读写的下标都有实体
	for i in col ..< cols - nn {
		line.cells[i] = line.cells[i + nn]
	}
	erase := eraseCell(console)
	for i in cols - nn ..< cols {
		line.cells[i] = erase
	}
	sanitizeWidePairs(line, 0, cols) // 左移会把宽字对从边界处劈开
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
	console.vt.wrap_pending = false // ICH 同 xterm(InsertChar)
	line := liveRow(console, tb, int(console.cursor_row))
	cols := max(1, int(console.cols))
	lineEnsureCol(line, cols - 1)
	col := min(int(console.cursor_col), cols - 1)
	nn := min(n, cols - col)
	if nn <= 0 {
		return
	}
	copy(line.cells[col + nn:], line.cells[col:cols - nn])
	erase := eraseCell(console)
	for i in col ..< col + nn {
		line.cells[i] = erase
	}
	sanitizeWidePairs(line, 0, cols) // 右移会把宽字对从边界处劈开
}

// IL:光标处插入 n 空行,滚动区底被挤出
vtInsertLines :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	console.vt.wrap_pending = false // IL 同 xterm(InsertLine)
	base := liveBase(tb, int(console.rows))
	row := base + int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	for _ in 0 ..< n {
		delete(tb.lines[bottom].cells)
		remove_range(&tb.lines, bottom, bottom + 1)
		insertLine(&tb.lines, row)
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
	console.vt.wrap_pending = false // DL 同 xterm(DeleteLine)
	base := liveBase(tb, int(console.rows))
	row := base + int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	for _ in 0 ..< n {
		if row >= len(tb.lines) {
			break
		}
		delete(tb.lines[row].cells)
		remove_range(&tb.lines, row, row + 1)
		insertLine(&tb.lines, bottom)
	}
}

// ---------------------------------------------------------------------------
// 重排(cols 变化):按 wrapped 串合并 / 重切;锚点用流内偏移随动
// ---------------------------------------------------------------------------
// 锚点坐标 = (物理行, 列),随 TermBufferReflow 原地更新;row < 0 = 不参与。
ReflowAnchor :: struct {
	row : int,
	col : int,
}

TermBufferReflow :: proc(tb : ^TermBuffer, new_cols : int, anchors : []ReflowAnchor) {
	if tb == nil || len(tb.lines) == 0 || tb.cols == 0 || new_cols <= 0 || int(tb.cols) == new_cols {
		return
	}
	old_cols := int(tb.cols)
	defer tb.cols = u16(new_cols)
	old := tb.lines
	rebuilt := make([dynamic]Line, 0, len(old))
	// 每条旧 run ↔ 新行的对应区间(锚点在重建完成后一次性映射,避免被后续 run 反复改写)
	RunBound :: struct { old_lo, old_hi, new_lo, new_hi : int }
	bounds := make([dynamic]RunBound, 0, 16)
	i := 0
	for i < len(old) {
		// 一条逻辑行 = 本行 + 后续所有 wrapped 续行
		j := i
		for j + 1 < len(old) && old[j + 1].wrapped {
			j += 1
		}
		content := make([dynamic]Cell, 0, (j - i + 1) * old_cols)
		for r in i ..= j {
			cells := old[r].cells[:]
			// 按**内容长度**拼接:末尾空白(EL/ED 补齐、宽字放不下让出的尾格)不是内容。
			// 算进去的话,变窄会把每个满宽行拆成"正文 + 空白行"(实测行长翻倍)。
			w := min(LineExtent(cells), old_cols)
			append(&content, ..cells[:w])
		}
		run_start := len(rebuilt)
		pos := 0
		first := true
		for pos < len(content) || first {
			w := min(new_cols, len(content) - pos)
			// 宽字对不跨行:行尾只剩宽字首格时整对推到下一行
			if w > 0 && pos + w - 1 < len(content) {
				tail := content[pos + w - 1]
				if tail.cp != 0 && tail.wide {
					if w > 1 {
						w -= 1
					} else {
						w = min(2, len(content) - pos) // 病态窄宽:整对占一行
					}
				}
			}
			row := Line { wrapped = !first }
			if w > 0 {
				append(&row.cells, ..content[pos:pos + w])
			}
			append(&rebuilt, row)
			pos += w
			first = false
			if w <= 0 {
				break // 空行只产一行,防死循环
			}
		}
		append(&bounds, RunBound { i, j, run_start, len(rebuilt) })
		delete(content)
		i = j + 1
	}
	// 锚点:旧 (行, 列) → 流内偏移 → 新 (行, 列);每条锚点只映射一次
	for idx in 0 ..< len(anchors) {
		a := &anchors[idx]
		if a.row < 0 {
			continue
		}
		for b in bounds {
			if a.row < b.old_lo || a.row > b.old_hi {
				continue
			}
			// 流内偏移 = run 内本行之前各行内容长度和 + 列(与拼接口径一致)
			flow := a.col
			for r in b.old_lo ..< a.row {
				flow += min(LineExtent(old[r].cells[:]), old_cols)
			}
			acc := 0
			for k in b.new_lo ..< b.new_hi {
				row_len := len(rebuilt[k].cells)
				if k < b.new_hi - 1 && flow >= acc + row_len {
					acc += row_len
					continue
				}
				a.row = k
				a.col = flow - acc // 不夹新宽:光标由调用方夹;选区端点允许 = cols(右开边界)
				break
			}
			break
		}
	}
	delete(bounds)
	for r in 0 ..< len(old) {
		delete(old[r].cells)
	}
	delete(old)
	tb.lines = rebuilt
}
