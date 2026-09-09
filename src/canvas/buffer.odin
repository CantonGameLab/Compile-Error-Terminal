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
	cut := len(tb.lines) - max_lines
	for i in 0 ..< cut {
		delete(tb.lines[i].cells)
	}
	remove_range(&tb.lines, 0, cut)
	selectionLineDelete(0, cut) // 选区通报:被裁段内容消失,未裁段行号 -cut
	console.cursor_row -= u16(cut)
	console.vt.scroll_top, console.vt.scroll_bottom = 0, console.rows - 1
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
	switch mode {
	case 0:
		for col in int(console.cursor_col) ..< int(console.cols) {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	case 1:
		for col in 0 ..= int(console.cursor_col) {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	case 2:
		for col in 0 ..< int(console.cols) {
			lineEnsureCol(line, col)
			line.cells[col] = erase
		}
	}
}

// mode:0 光标到屏尾 / 1 屏头到光标 / 2 可视区 / 3 全部 + 历史
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
		TermBufferClear(console.active_term_buffer_id)
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
	for col in 0 ..< int(console.cols) {
		lineEnsureCol(&tb.lines[row], col)
		tb.lines[row].cells[col] = erase
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
	row := int(console.cursor_row)
	if row >= len(tb.lines) {
		return
	}
	line := &tb.lines[row]
	start := int(console.cursor_col)
	end := min(start + n, int(console.cols))
	erase := eraseCell(console)
	when VT_DEBUG {
		fmt.eprintfln("VTDBG ECH n=%d start=%d style.bg=%08X", n, start, console.vt.style.bg)
	}
	for i in start ..< end {
		lineEnsureCol(line, i)
		line.cells[i] = erase
	}
}

// DCH:删除光标起 n 字符,右侧左移补空白
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
	col := int(console.cursor_col)
	nn := min(n, len(line.cells) - col)
	remove_range(&line.cells, col, col + nn)
	erase := eraseCell(console)
	for i in 0 ..< nn {
		append(&line.cells, erase)
	}
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
	for len(line.cells) < int(console.cols) {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
	col := int(console.cursor_col)
	nn := min(n, int(console.cols) - col)
	copy(line.cells[col + nn:], line.cells[col:int(console.cols) - nn])
	erase := eraseCell(console)
	for i in col ..< col + nn {
		line.cells[i] = erase
	}
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

