// 场景绘制:只读遍历窗口树,把每个 leaf 节点的 Console 画到屏幕。
// 消费现有模型(窗口树 / Console / TermBuffer / font),零数据写回。
// 单窗模式(页 view_mode == .Single):只画当前页焦点 leaf(有效矩形 = 树区),
// 其余窗口隐藏、分割条不画;与布局同用 cv.WindowEffectiveRect 单公式。
package render

import cv "../canvas"
import fnt "../font"
import mem "../memory"
import s3 "vendor:sdl3"
import "core:fmt"
import "core:time"

// 每帧绘制入口:只读遍历窗口树(主题经 cv.GetTheme 只读消费)
// 两趟遍历:先背景(第 1 趟)→ 背景 pass(FBO+shader)→ 字形/前景(第 2 趟)。
// 原因:主批 push 阶段会因纹理切换提前 flush,若字形先于背景 pass 上屏会被全屏
// quad 覆盖;分开两趟保证"背景先定、字形后画"。
DrawFrame :: proc() {
	p := cv.CurrentPage()
	single := p != nil && p.view_mode == .Single
	drawWalk(cv.WindowTreeRoot(), true, single)
	// 背景延伸成员(均在背景 pass 前进背景批 → 与内容区同一 shader):
	//   焦点描边 + 激活页签底(输入色 = theme.bg → shader 后同值,无缝融合)
	drawFocusBorder()
	drawTabBarActiveBg()
	drawBackgroundPass(f32(s3.GetTicks()) / 1000.0) // 背景批 → FBO → 背景 shader
	drawWalk(cv.WindowTreeRoot(), false, single)
	// 底部页签条(状态栏雏形):条底 + 页签 + 右侧工具区(命令栏输入框、FPS)
	drawTabBar()
	drawCommandBar()
	drawFps()
	flushBatch()

	drawWalk :: proc(node_h : mem.Handle, bg : bool, single : bool) {
		node := cv.GetWindowTreeNode(node_h)
		if node == nil {
			return
		}
		if !node.is_leaf {
			// 先画子树(背景被 frame 覆盖),再画分割条(分割条属前景,仅第 2 趟)
			drawWalk(node.left_son_id, bg, single)
			drawWalk(node.right_son_id, bg, single)
			if !bg && !single {
				drawFrame(node_h)
			}
			return
		}
		// 单窗:只画当前页焦点 leaf(其余窗口隐藏)
		if single {
			p := cv.CurrentPage()
			if p == nil || p.focused != node_h {
				return
			}
		}
		if cv.NodeConsole(node_h) != nil {
			drawConsole(node_h, bg, cv.WindowEffectiveRect(node_h)) // 内部按 console 句柄判定,无 console 直返
		}
	}
}

// ---------------------------------------------------------------------------
// FPS tag(条内最右角):渲染层统计自身帧率,每 0.5s 刷新一次显示值
// ---------------------------------------------------------------------------
fps_start : time.Time
fps_frames : int
fps_value : f32

// 行连体 shaping 复用缓冲(单线程渲染;resize 只会首次扩容,之后零分配)
draw_shaped : [dynamic]u16
draw_orig : [dynamic]u16

drawFps :: proc() {
	theme := cv.GetTheme()
	uf := cv.GetUIFont() // UI 字体(定制项;页签/状态栏/FPS 共用)
	fps_frames += 1
	if fps_start == {} {
		fps_start = time.now()
	}
	elapsed := time.duration_seconds(time.since(fps_start))
	if elapsed >= 0.5 {
		fps_value = f32(fps_frames) / f32(elapsed)
		fps_frames = 0
		fps_start = time.now()
	}
	if fps_value <= 0 {
		return // 第一窗口期未满:不画
	}
	m := fnt.GetMetrics(uf)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	text := fmt.tprintf("%.0f fps", fps_value)
	text_w := f32(len(text)) * m.cell_width
	r := cv.FpsTagRect()
	DrawRect(r.position_x, r.position_y, r.width, r.height, theme.fps_bg)
	DrawText(uf, text,
		r.position_x + (r.width - text_w) * 0.5,
		r.position_y + m.ascent + (r.height - m.cell_height) * 0.5, theme.fps_fg)
}

// ---------------------------------------------------------------------------
// 底部页签条(状态栏雏形):条底 + 页签(激活 = 主题 bg,经背景管线与内容区
// 同一 shader,无缝融合)+ "+"。几何/命中在 canvas(PageTabRect/NewTabRect/
// TabBarHit),渲染只读绘制。
// ---------------------------------------------------------------------------

// 背景趟(pass 前):激活页签底进背景批次 → FBO → 与内容区同一 shader。
// 输入色 = theme.bg(内容区打底色),变换同源 → shader 后同值,分界线消失。
drawTabBarActiveBg :: proc() {
	theme := cv.GetTheme()
	cur := cv.PageCurrent()
	for i in 0 ..< cv.PageCount() {
		page_h := cv.PageByIndex(i + 1)
		if page_h.id == 0 {
			break
		}
		if page_h != cur {
			continue
		}
		rect, ok := cv.PageTabRect(i)
		if !ok {
			return
		}
		DrawRectBg(rect.position_x, rect.position_y, rect.width, rect.height, theme.tab_active_bg)
		return // 激活页签唯一
	}
}

// 激活页签矩形(主批条底分段避让用);无 = 全宽条底
activeTabRect :: proc() -> (cv.Transform, bool) {
	cur := cv.PageCurrent()
	for i in 0 ..< cv.PageCount() {
		page_h := cv.PageByIndex(i + 1)
		if page_h.id == 0 {
			break
		}
		if page_h == cur {
			return cv.PageTabRect(i)
		}
	}
	return cv.Transform {}, false
}

drawTabBar :: proc() {
	theme := cv.GetTheme()
	bar_y := screen_h - cv.TAB_BAR_HEIGHT
	uf := cv.GetUIFont()
	m := fnt.GetMetrics(uf)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	// 条底分段:激活页签区域留给背景趟(已经 shader 融合),不覆盖
	ar, has_active := activeTabRect()
	if has_active {
		DrawRect(0, bar_y, ar.position_x, cv.TAB_BAR_HEIGHT, theme.tab_bar_bg)
		right_x := ar.position_x + ar.width
		DrawRect(right_x, bar_y, screen_w - right_x, cv.TAB_BAR_HEIGHT, theme.tab_bar_bg)
	} else {
		DrawRect(0, bar_y, screen_w, cv.TAB_BAR_HEIGHT, theme.tab_bar_bg)
	}
	cur := cv.PageCurrent()
	for i in 0 ..< cv.PageCount() {
		page_h := cv.PageByIndex(i + 1)
		if page_h.id == 0 {
			break
		}
		rect, ok := cv.PageTabRect(i)
		if !ok {
			continue
		}
		active := page_h == cur
		fg := theme.tab_fg
		if active {
			fg = theme.tab_active_fg
			// 激活页签底 = 背景趟产物,此处只画文本
		} else {
			DrawRect(rect.position_x, rect.position_y, rect.width, rect.height, theme.tab_bar_bg)
		}
		t := cv.PageTitle(page_h)
		tw := f32(len(t)) * m.cell_width
		tx := rect.position_x + (rect.width - tw) * 0.5
		ty := rect.position_y + m.ascent + (rect.height - m.cell_height) * 0.5
		DrawText(uf, t, tx, ty, fg)
	}
	// "+" 新建按钮
	nr := cv.NewTabRect()
	DrawRect(nr.position_x, nr.position_y, nr.width, nr.height, theme.tab_hover_bg)
	DrawText(uf, "+",
		nr.position_x + (nr.width - m.cell_width) * 0.5,
		nr.position_y + m.ascent + (nr.height - m.cell_height) * 0.5, theme.tab_fg)
}

// 焦点窗口边框高亮:焦点 leaf 矩形内侧描边(覆盖内容边缘,不动分割条)。
// 经 DrawRectBg 进背景管线:与背景共用同一 shader(纯色背景 = 纯色边框;
// shader 背景 = 边框同变换,自然延伸)。
FOCUS_BORDER_WIDTH :: f32(1.0)

drawFocusBorder :: proc() {
	theme := cv.GetTheme()
	focus := cv.CurrentPage().focused
	if focus.id == 0 {
		return
	}
	if cv.GetWindowTreeNode(focus) == nil {
		return
	}
	t := cv.WindowEffectiveRect(focus) // 单窗下 = 树区整圈(显示边界指示)
	if t.width <= 0 || t.height <= 0 {
		return
	}
	d := FOCUS_BORDER_WIDTH
	c := theme.focus_border
	// DrawRectBg = 背景批(FBO → 背景 shader;与背景共用同一 shader:
	// 纯色背景 = 纯色边框;shader 背景 = 边框同变换延伸)。
	DrawRectBg(t.position_x, t.position_y, t.width, d, c) // 上
	DrawRectBg(t.position_x, t.position_y + t.height - d, t.width, d, c) // 下
	DrawRectBg(t.position_x, t.position_y, d, t.height, c) // 左
	DrawRectBg(t.position_x + t.width - d, t.position_y, d, t.height, c) // 右
}

// 命令栏(集成在页签条右侧):输入框 + ':' 前缀 + 输入文本 + 光标(500ms 闪烁)。
// 文本显示窗口按光标动态滑动(本地计算,不落存储);几何 = canvas.CommandBarRect。
drawCommandBar :: proc() {
	if !cv.CommandBarVisible() {
		return
	}
	theme := cv.GetTheme()
	uf := cv.GetUIFont()
	m := fnt.GetMetrics(uf)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	r := cv.CommandBarRect()
	bar := cv.GetCommandBar()
	// 输入框:底 = tab_hover_bg(浅于条底),顶边 = 主题 frame 色
	DrawRect(r.position_x, r.position_y, r.width, r.height, theme.tab_hover_bg)
	DrawRect(r.position_x, r.position_y, r.width, 1.0, theme.frame)
	pad := f32(10)
	base_y := r.position_y + m.ascent + (r.height - m.cell_height) * 0.5
	// ':' 前缀(FPS 灰)
	DrawText(uf, ":", r.position_x + pad, base_y, theme.fps_fg)
	// 文本显示窗:[start, start+vis) 保持光标可见(v 按光标动态滑动)
	vis := int((r.width - pad * 2 - m.cell_width) / m.cell_width)
	text := string(bar.input[:bar.len])
	start := 0
	if bar.len > vis {
		start = clamp(bar.cursor - vis + 1, 0, bar.len - vis)
	}
	text_x := r.position_x + pad + m.cell_width * 1.2
	DrawText(uf, text[start:], text_x, base_y, theme.tab_active_fg)
	// 光标(竖线,500ms 相位同终端)
	if cursorBlinkOn(5) {
		cx := text_x + f32(bar.cursor - start) * m.cell_width
		DrawRect(cx, r.position_y + 5, 1.5, r.height - 10, theme.cursor)
	}
}

// 颜色混合:a 向 b 偏移 t(0..1),0xRRGGBB
mixColor :: proc(a, b : u32, t : f32) -> u32 {
	ar := f32(a >> 16 & 0xFF)
	ag := f32(a >> 8 & 0xFF)
	ab := f32(a & 0xFF)
	br := f32(b >> 16 & 0xFF)
	bg := f32(b >> 8 & 0xFF)
	bb := f32(b & 0xFF)
	cr := u32(ar + (br - ar) * t)
	cg := u32(ag + (bg - ag) * t)
	cb := u32(ab + (bb - ab) * t)
	return cr << 16 | cg << 8 | cb
}


// 分割条:内部节点按 split_type 画一条 frame 宽度的色条(颜色读主题)
drawFrame :: proc(node_h : mem.Handle) {
	theme := cv.GetTheme()
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	fw := f32(node.frame_width)
	if fw <= 0 {
		return
	}
	left := cv.GetWindowTreeNode(node.left_son_id)
	if left == nil {
		return
	}
	switch node.split_type {
	case .LeftRight:
		// 竖条:紧贴左子右边界
		DrawRect(left.position_x + left.width, node.position_y, fw, node.height, theme.frame)
		// 拖拽高亮:focus_border 色加宽 4px(临时档),中心对齐原条
		if cv.SplitDragTarget() == node_h {
			hw := f32(4)
			DrawRect(left.position_x + left.width + fw*0.5 - hw*0.5, node.position_y, hw, node.height, theme.focus_border)
		}
	case .UpDown:
		// 横条:紧贴左(上)子下边界
		DrawRect(node.position_x, left.position_y + left.height, node.width, fw, theme.frame)
		if cv.SplitDragTarget() == node_h {
			hw := f32(4)
			DrawRect(node.position_x, left.position_y + left.height + fw*0.5 - hw*0.5, node.width, hw, theme.focus_border)
		}
	}
}

drawConsole :: proc(node_h : mem.Handle, bg : bool, t : cv.Transform) {
	theme := cv.GetTheme()
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	console_h := node.console_id
	console := cv.GetConsole(console_h)
	if console == nil {
		return
	}
	m := fnt.GetMetrics(console.font_id)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}

	// 打底背景(仅第 1 趟:背景批 → FBO → 背景 shader)
	if bg {
		DrawRectBg(t.position_x, t.position_y, t.width, t.height, theme.bg)
	}

	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	visible_top, _ := cv.ConsoleViewportTop(console_h)

	// 行连体 shaping 缓冲:模块级复用(零分配),逐行 resize 复用
	for r in 0 ..< int(console.rows) {
		line_idx := visible_top + r
		if line_idx >= len(tb.lines) {
			break
		}
		line := &tb.lines[line_idx]
		// 选区渲染开关:当前 console 持有的 buffer = 被选 buffer(只读比较)
		sel_console := console.active_term_buffer_id.id != 0 && console.active_term_buffer_id == cv.SelectionBuffer()
		col_limit := min(int(console.cols), len(line.cells))
		if col_limit == 0 {
			continue
		}

		// 逐行连体 shaping 仅 fg 趟需要(bg 趟只画底色,不需要字形 id):
		// cell cp → 主字体 glyph id,ShapeLine 原地替换;输出与输入一一对应,
		// 替换后的 id 用 GetGlyphById 绘制。
		draw_limit := col_limit
		if bg {
			// 第 1 趟:只画背景(打底/cell 底色 → 背景批);选区覆盖在 cell 底色之上。
			// 宽字符续列不单独画:首格按宽 2 一次画(底色与选区列对齐)。
			for c in 0 ..< col_limit {
				cell := line.cells[c]
				w := 1
				if cell.cp != 0 && cell.wide {
					w = 2
				} else if cell.cp == 0 && cell.wide {
					continue
				}
				if sel_console && cv.CellSelected(line_idx, c, w, int(console.cols)) {
					cx := console.origin_x + f32(c) * m.cell_width
					cy := console.origin_y + f32(r) * m.cell_height
					DrawRectBg(cx, cy, m.cell_width * f32(w), m.cell_height, theme.selection_bg)
					continue
				}
				bg_c := cv.ResolveColor(cell.bg, theme.bg)
				if cell.reverse {
					bg_c = cv.ResolveColor(cell.fg, theme.fg)
				}
				if bg_c != theme.bg {
					cx := console.origin_x + f32(c) * m.cell_width
					cy := console.origin_y + f32(r) * m.cell_height
					DrawRectBg(cx, cy, m.cell_width * f32(w), m.cell_height, bg_c)
				}
			}
			continue
		}
		resize(&draw_shaped, col_limit)
		resize(&draw_orig, col_limit)
		for c in 0 ..< col_limit {
			g := fnt.GlyphIndex(console.font_id, line.cells[c].cp)
			draw_orig[c] = g
			draw_shaped[c] = g
		}
		fnt.ShapeLine(console.font_id, &draw_shaped)
		// 连体合并(未来 type4)会缩短数组;绘制按缩短后的长度截断
		draw_limit = min(col_limit, len(draw_shaped))
		// 第 2 趟:连体字形位图会溢出到相邻格(如 --- 的 32px 连体),
		// 背景已在上趟定稿,此处只画字形。
		// 字体变体:style key 变化才查询(变体 face / 合成兜底标志),run 内零查表
		sty_key := u8(255)
		fh : mem.Handle
		bs, isyn : bool
		for c in 0 ..< draw_limit {
			cell := line.cells[c]
			if cell.cp == 0 {
				continue // 空白格/宽字符续列:无字形
			}
			key := u8(0)
			if cell.bold {
				key |= 1
			}
			if cell.italic {
				key |= 2
			}
			if key != sty_key {
				sty_key = key
				fh, bs, isyn = cv.ConsoleFontVariant(console_h, cell.bold, cell.italic)
			}
			cx := console.origin_x + f32(c) * m.cell_width
			cy := console.origin_y + f32(r) * m.cell_height
			fg := cv.ResolveColor(cell.fg, theme.fg)
			if cell.reverse {
				fg = cv.ResolveColor(cell.bg, theme.bg)
			}
			if sel_console && cv.CellSelected(line_idx, c, 1, int(console.cols)) {
				fg = theme.selection_fg // 选中字形换选区前景(背景已在 1 趟覆盖)
			}
			gid := draw_shaped[c]
			// fh ≠ 主字体时连体 gid 属主字体表:强制普通 cp 路径
			drawCellGlyph(fh, cell.cp, gid, draw_orig[c], cx, cy + m.ascent, fg, bs, isyn, fh != console.font_id)
		}
		// 装饰线(下划线/删除线/上划线):样式 run 合并,画在字形之上
		drawDecoLine(line, col_limit, r, console, m, theme.fg)
	}

	// 光标(DECSCUSR):0/1 块 2 块(常亮) 3/4 下划线 5/6 竖线。
	// 闪烁 = 硬相位亮灭(无渐变,亮灭各半);输入窗口常亮;位置 = 真源格(无动画)。
	// 块状先画块再用底色重绘字形,条形不遮字形无需重绘。
	if !bg && console.vt.cursor_visible {
		cr := int(console.cursor_row) - visible_top
		if cr >= 0 && cr < int(console.rows) {
			cx := console.origin_x + f32(console.cursor_col) * m.cell_width
			cy := console.origin_y + f32(cr) * m.cell_height
			style := console.vt.cursor_style
			a := BlinkAlpha(style, now_ms(), console.input_activity_ms)
			if a > 0 { // 闪烁灭相位:不绘制
				switch {
				case style == 3 || style == 4: // 下划线:贴格底
					uh := max(2.0, m.cell_height * 0.08)
					DrawRect(cx, cy + m.cell_height - uh, m.cell_width, uh, theme.cursor)
				case style == 5 || style == 6: // 竖线:贴格左边缘,1px
					DrawRect(cx, cy, 1.0, m.cell_height, theme.cursor)
				case: // 0/1/2:块;停在宽字符首格时画 2 格宽(覆盖续列)
					cw := m.cell_width
					line_idx := visible_top + cr
					if line_idx < len(tb.lines) {
						line := &tb.lines[line_idx]
						if int(console.cursor_col) < len(line.cells) {
							cell := line.cells[int(console.cursor_col)]
							if cell.cp != 0 && cell.wide {
								cw = m.cell_width * 2
							}
						}
					}
					DrawRect(cx, cy, cw, m.cell_height, theme.cursor)
					if line_idx < len(tb.lines) {
						line := &tb.lines[line_idx]
						if int(console.cursor_col) < len(line.cells) {
							cell := line.cells[int(console.cursor_col)]
							if cell.cp != 0 {
								// 粗体字符同样双描重绘(否则光标块下残留 1px 粗体边)
								drawCellGlyph(console.font_id, cell.cp, 0, 0, cx, cy + m.ascent, theme.bg, false, false, false)
							}
						}
					}
				}
			}
		}
	}
}

// 画一个字符字形:(x, y) = 基线。
// 字体 = 变体选择结果(fh);bold_syn/italic_syn = 该维度合成兜底标志:
//   bold_syn → 同字形向右 1px 双描(无真 Bold face 时;alpha 叠加变实);
//   italic_syn → 位图错切(CPU 顶点 shear);
// 变体字体(fh ≠ 主字体)时连体 gid 失效(gid 属主字体表),强制普通 cp 路径。
drawCellGlyph :: proc(font_h : mem.Handle, cp : rune, gid, orig_gid : u16, x, y : f32, color : u32, bold_syn, italic_syn, syn_gid : bool) {
	use_gid := !syn_gid && gid != 0 && gid != orig_gid
	if use_gid {
		if bold_syn {
			DrawGlyphById(font_h, gid, x + 1, y, color, italic_syn)
		}
		DrawGlyphById(font_h, gid, x, y, color, italic_syn)
		return
	}
	if bold_syn {
		DrawRune(font_h, cp, x + 1, y, color, italic_syn)
	}
	DrawRune(font_h, cp, x, y, color, italic_syn)
}

// 装饰线(下划线/删除线/上划线):样式 run 合并画线(跨 cell 连续不断),
// 颜色 = span 前景色(渲染期解析);线位置/粗细取自字体 metrics(缺省兜底)。
// 编码:dec = underline(0..2)| crossed<<2 | overline<<3
drawDecoLine :: proc(line : ^cv.Line, col_limit : int, row : int, console : ^cv.Console, m : fnt.Metrics, theme_fg : u32) {
	if col_limit <= 0 {
		return
	}
	dec := 0
	start := 0
	color := u32(0)
	have := false
	flush :: proc(l : ^cv.Line, s, e : int, row : int, console : ^cv.Console, m : fnt.Metrics, dec : int, color : u32) {
		if s >= e || dec == 0 {
			return
		}
		x0 := console.origin_x + f32(s) * m.cell_width
		x1 := console.origin_x + f32(e) * m.cell_width
		base := console.origin_y + f32(row) * m.cell_height
		baseline := base + m.ascent
		u := dec & 3
		if u != 0 { // 下划线(双 = 两条,相距 thick+1)
			y := baseline + m.underline_pos
			DrawRect(x0, y - m.underline_thick * 0.5, x1 - x0, m.underline_thick, color)
			if u == 2 {
				y2 := y + m.underline_thick + 2
				DrawRect(x0, y2 - m.underline_thick * 0.5, x1 - x0, m.underline_thick, color)
			}
		}
		if dec & (2 << 2) != 0 { // 删除线
			y := baseline + m.strike_pos
			DrawRect(x0, y - m.strike_thick * 0.5, x1 - x0, m.strike_thick, color)
		}
		if dec & (1 << 3) != 0 { // 上划线(贴格顶)
			DrawRect(x0, base, x1 - x0, max(1.0, m.strike_thick), color)
		}
	}
	for c in 0 ..< col_limit {
		cell := &line.cells[c]
		d := int(cell.underline)
		if cell.crossed {
			d |= 2 << 2
		}
		if cell.overline {
			d |= 1 << 3
		}
		fg := cv.ResolveColor(cell.fg, theme_fg)
		if !have {
			have, dec, start, color = true, d, c, fg
			continue
		}
		if d != dec || fg != color {
			flush(line, start, c, row, console, m, dec, color)
			dec, start, color = d, c, fg
		}
	}
	if have {
		flush(line, start, col_limit, row, console, m, dec, color)
	}
}

// DECSCUSR 闪烁样式(Ps=1/3/5):500ms 亮、500ms 灭
cursorBlinkOn :: proc(style : u8) -> bool {
	if style != 1 && style != 3 && style != 5 {
		return true
	}
	return (s3.GetTicks() / 500) % 2 == 0
}
