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
//   渲染契约:visible_top = viewportTop(console, tb)  // 普通 = 贴底;review = 锚定 review_line
//            屏幕第 r 行 ↔ lines[visible_top + r];光标屏幕位置 = cursor_row - visible_top
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

Line :: struct {
	cells : [dynamic]Cell,
	wrapped : bool, // 由上一行折行而来,翻历史时按它拼回逻辑行
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
	// 历史视口(绝对锚定模型,唯一真值):
	//   0        = 普通模式(实时跟随,底行 = 最新行,新输出自动贴底)
	//   n (1..)  = review 模式,值 = 屏幕底行物理索引 + 1;新输出到达时不动,
	//              视口内容稳定;滚回最新(n = len)转回普通(置 0)
	review_line : u32,
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
	SelectionClear() // 内容全没了,选区同步失效
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

// 折行一次:光标下移/滚动,列归 0。调用方保证 pending 语义由自己处理
vtWrapOnce :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if int(console.cursor_row) - screenBase(console, tb) < int(console.vt.scroll_bottom) {
		console.cursor_row += 1
		for len(tb.lines) <= int(console.cursor_row) {
			append(&tb.lines, Line{})
		}
	} else {
		vtScrollUp(console_h)
	}
	tb.lines[console.cursor_row].wrapped = true
	console.cursor_col = 0
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
	row, col := int(console.cursor_row), int(console.cursor_col)
	when VT_DEBUG {
		vtDbg(console_h, fmt.tprintf("WRITE '%c' at %d,%d", cp, row, col))
	}

	w := runeWidth(cp)
	// 宽字符放不下当前列(只剩 1 列):先折行再写(xterm 语义)
	if w == 2 && col + w > int(console.cols) {
		vtWrapOnce(console_h)
		row, col = int(console.cursor_row), int(console.cursor_col)
	}
	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
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
		append(&tb.lines, Line{})
		console.cursor_row += 1
		trimScrollback(console_h)
		return
	}
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[top].cells)
	remove_range(&tb.lines, top, top + 1)
	insertLine(&tb.lines, bottom)
	// 选区通报:顶行删 + 底行补空 = 滚动区内整体上移一格
	selectionLineDelete(top, 1)
	selectionLineInsert(bottom, 1)
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
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[bottom].cells)
	remove_range(&tb.lines, bottom, bottom + 1)
	insertLine(&tb.lines, top)
	// 选区通报:底行删 + 顶行补空 = 滚动区内整体下移一格
	selectionLineDelete(bottom, 1)
	selectionLineInsert(top, 1)
}

// core:slice 无 insert 的替代实现
insertLine :: proc(lines : ^[dynamic]Line, index : int) {
	append(lines, Line{})
	copy(lines[index + 1:], lines[index:len(lines) - 1])
	lines[index] = Line{}
}

// 从行数组头部裁掉 cut 行(历史永久丢弃),同步光标行号 / 选区通报 / review 锚定。
// 调用方:超容量裁剪(trimScrollback)、ED 3 清 scrollback(视口之上全是历史)。
// cut 不得越过光标行:光标是物理行索引,裁掉它所在的行会让 -= 下溢。
cutHistoryHead :: proc(console_h : mem.Handle, cut : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil || cut <= 0 || cut > len(tb.lines) || cut > int(console.cursor_row) {
		return
	}
	for i in 0 ..< cut {
		delete(tb.lines[i].cells)
	}
	remove_range(&tb.lines, 0, cut)
	selectionLineDelete(0, cut) // 选区通报:被裁段内容消失,未裁段行号 -cut
	console.cursor_row -= u16(cut)
	// review 锚定行随裁剪平移;被裁掉的视口内容钳到顶(该历史段已丢弃)
	if tb.review_line != 0 {
		rl := max(0, int(tb.review_line) - 1 - cut)
		if rl >= len(tb.lines) - 1 {
			tb.review_line = 0 // 回到最新 = 普通
		} else {
			tb.review_line = u32(rl + 1)
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

// 整行扫描,清掉全部不成对的半个宽字(冷路径:整行搬移类操作之后)。
sanitizeWidePairs :: proc(line : ^Line, cols : int) {
	n := min(cols, len(line.cells))
	i := 0
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
vtEraseInLine :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	row := int(console.cursor_row)
	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
	erase := eraseCell(console)
	cols := int(console.cols)
	switch mode {
	case 0:
		for col in int(console.cursor_col) ..< cols {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	case 1:
		for col in 0 ..= int(console.cursor_col) {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	case 2:
		for col in 0 ..< cols {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	}
	sanitizeWidePairs(line, cols) // 擦除端点可能落在宽字对中间
}

// mode:0 光标到屏尾 / 1 屏头到光标 / 2 可视区 / 3 只清 scrollback(历史,不动可视屏)
vtEraseInDisplay :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	switch mode {
	case 0:
		vtEraseInLine(console_h, 0)
		for row in int(console.cursor_row) + 1 ..< len(tb.lines) {
			vtClearLineAll(console_h, row)
		}
	case 1:
		for row in 0 ..< int(console.cursor_row) {
			vtClearLineAll(console_h, row)
		}
		vtEraseInLine(console_h, 1)
	case 2:
		start := max(0, len(tb.lines) - int(console.rows))
		for row in start ..< len(tb.lines) {
			vtClearLineAll(console_h, row)
		}
	case 3:
		// ED 3 = Erase Saved Lines:只擦可视窗之上已滚出的历史,可视屏与光标都不许动。
		// 这里曾经整个 TermBufferClear ⇒ 行数组清空但 cursor_row 留在原处,下一次写入
		// 把数组补空行补回那一行,提示符的屏幕行 = 清屏前攒下的历史长度(实测宿主对
		// clear 发的正是 ESC[H ESC[2J ESC[3J,于是"有时在底部、有时在中间、有时在上面")。
		cutHistoryHead(console_h, screenBase(console, tb))
	}
}

vtClearLineAll :: proc(console_h : mem.Handle, row : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if row < 0 || row >= len(tb.lines) {
		return
	}
	erase := eraseCell(console)
	cols := int(console.cols)
	for col in 0 ..< cols {
		lineEnsureCol(&tb.lines[row], col)
		tb.lines[row].cells[col] = erase
	}
	sanitizeWidePairs(&tb.lines[row], cols)
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
	row := int(console.cursor_row)
	if row >= len(tb.lines) {
		return
	}
	line := &tb.lines[row]
	start := int(console.cursor_col)
	cols := int(console.cols)
	end := min(start + n, cols)
	erase := eraseCell(console)
	when VT_DEBUG {
		fmt.eprintfln("VTDBG ECH n=%d start=%d style.bg=%08X", n, start, console.vt.style.bg)
	}
	for i in start ..< end {
		lineEnsureCol(line, i)
		line.cells[i] = erase
	}
	sanitizeWidePairs(line, cols) // 擦除端点可能落在宽字对中间
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
	row := int(console.cursor_row)
	if row >= len(tb.lines) {
		return
	}
	line := &tb.lines[row]
	cols := max(1, int(console.cols))
	col := min(int(console.cursor_col), cols - 1)
	nn := min(n, cols - col)
	if nn <= 0 {
		return
	}
	lineEnsureCol(line, cols - 1) // 窗口内定宽:下面按格读写的下标都有实体
	for i in col ..< cols - nn {
		line.cells[i] = line.cells[i + nn]
	}
	erase := eraseCell(console)
	for i in cols - nn ..< cols {
		line.cells[i] = erase
	}
	sanitizeWidePairs(line, cols)    // 左移会把宽字对从 col / cols-nn 处劈开
	selectionColDelete(row, col, nn) // 选区通报:行内删除(列平移/内容消失)
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
	row := int(console.cursor_row)
	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
	cols := max(1, int(console.cols))
	for len(line.cells) < cols {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
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
	sanitizeWidePairs(line, cols)    // 右移会把宽字对从 col / cols-nn 处劈开
	selectionColInsert(row, col, nn) // 选区通报:行内插入(列平移)
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
	base := screenBase(console, tb)
	row := int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
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
	selectionLineInsert(row, n) // 选区通报:row 处插入 n 行(行号平移)
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
	base := screenBase(console, tb)
	row := int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
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
	selectionLineDelete(row, actual)
	selectionLineInsert(bottom, actual)
}

