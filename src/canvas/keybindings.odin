// 鼠标路由(功能层):消费 input 鼠标通道 → 窗口交互。
// 键绑定/命令在 command 模块(消费链:command 先行);本文件只管鼠标。
// 鼠标:滚轮 → review、点击 → 聚焦、应用鼠标模式(1000/1002/1003)→ SGR 编码写回。
// 单窗模式(页 view_mode == .Single):分割条不命中/不拖拽,目标一律 = 页焦点。
package canvas

import ct "../conpty"
import fnt "../font"
import inp "../input"
import mem "../memory"
import "core:fmt"

// 每帧调用(main,canvas.Update 内):消费 input 包鼠标状态。
// 命中规则:活动拖拽独占(结束/取消/更新);底部页签条优先(页操作,不落窗口树);
// 否则左键命中分割条 → 开始拖拽(UI 优先于应用模式,WT 行为);应用鼠标模式
// (?1000/1002/1003)再接管;最后鼠标点所在 leaf = 动作目标。
ProcessMouse :: proc() {
	m := &inp.Mouse
	updateCursor() // 光标反馈与路由同位次(只读输入+状态,无副作用)
	if !m.x_ok {
		return
	}
	if split_drag.active {
		splitDragUpdate(m) // 独占:释放/右键取消/位移;其余事件忽略
		return
	}
	// 选区拖拽/定稿(与命中无关:update 用宿主机几何换算,release 只清 active)
	if m.moved && m.left && selection.active {
		selectionUpdate(m.x, m.y)
	}
	if m.release & 1 != 0 && selection.active {
		selection.active = false
	}
	// 单窗模式(Single):分割条不可见/不可拖;命中目标 = 页焦点(点击不换焦点)
	p := CurrentPage()
	single := p != nil && p.view_mode == .Single
	// 页签条命中(按下):切换页 / 新建页
	if m.press != 0 {
		if kind, index := TabBarHit(m.x, m.y); kind != .None {
			switch kind {
			case .Tab:
				PageSwitch(PageByIndex(index + 1))
			case .NewPage:
				PageNew()
			case .None:
			}
			return
		}
		// 分割条命中(左键按下):开始拖拽(条在窗口边缘内 pad 像素,优先于聚焦);
		// 单窗模式下分割条不可见,跳过命中
		if m.press & 1 != 0 && !single {
			if h := SplitFrameHit(m.x, m.y); h.id != 0 && splitDragBegin(h, m.x, m.y) {
				return
			}
		}
	}
	// 单窗:树区任意点 = 页焦点;平铺:点所在 leaf
	node_h : mem.Handle
	if single {
		node_h = p.focused
	} else {
		node_h = nodeAtPoint(m.x, m.y)
	}
	if node_h.id == 0 {
		return
	}
	console_h := NodeConsoleId(node_h)
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	// 应用接管:鼠标事件编码为 SGR 序列写回应用,不再做 UI 动作
	if console.vt.mouse_mode != 0 {
		mouseToApp(console, console.font_set.main_font)
		return
	}
	// UI 绑定:点击聚焦;左键选择(单击/双击词/三击行/Shift 扩展);中键粘贴;
	// 滚轮滚动历史(review)
	if m.press != 0 {
		CurrentPage().focused = node_h
	}
	if m.press & 1 != 0 {
		// Shift+点击 = 扩展(cur = 点击处,pivot 保留);无选区则普通起选
		if m.mods & 1 != 0 && SelectionValid() && selection.buffer_h == console.active_term_buffer_id {
			selectionUpdate(m.x, m.y)
			selection.active = true
		} else {
			// 连击:双击词选 / 三击行选;否则普通(替换旧选区)
			mtr := fnt.GetMetrics(console.font_set.main_font)
			tb := GetTermBuffer(console.active_term_buffer_id)
			line, col := screenToBuffer(console, tb, mtr, m.x, m.y)
			switch clickChain(console.active_term_buffer_id, line, col) {
			case 2:
				SelectionSetWord(console.active_term_buffer_id, line, col)
			case 3:
				SelectionSetLine(console.active_term_buffer_id, line)
			case:
				selectionBegin(node_h, m.x, m.y)
			}
		}
	}
	if m.press & 2 != 0 {
		PasteClipboard()
	}
	if m.wheel != 0 {
		CurrentPage().focused = node_h
		// input 层语义:wheel 正 = 向上滚(SDL);向上翻历史 = ConsoleScroll(负)
		ConsoleScroll(-int(m.wheel), node_h)
	}
}

// 焦点窗格的 console(绑定动作的目标)
focusConsole :: proc() -> ^Console {
	p := CurrentPage()
	if p == nil || p.focused.id == 0 {
		return nil
	}
	return NodeConsole(p.focused)
}

// ---------------------------------------------------------------------------
// 应用鼠标模式:SGR(xterm 1006)编码
// ---------------------------------------------------------------------------

// 鼠标屏幕位置 → 网格坐标(1-based,越界 clamp 到格子边缘,终端惯例)
// 字体 = 窗口配置(唯一真相),经调用方传入
mouseCell :: proc(console : ^Console, font_h : mem.Handle, x, y : f32) -> (col, row : int, ok : bool) {
	m := fnt.GetMetrics(font_h)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return 0, 0, false
	}
	col = clamp(int((x - console.origin_x) / m.cell_width) + 1, 1, int(console.cols))
	row = clamp(int((y - console.origin_y) / m.cell_height) + 1, 1, int(console.rows))
	return col, row, true
}

// SGR 修饰位:Shift+4 Alt+8 Ctrl+16(input 的 bit 表示转 xterm 位)
sgrMods :: proc(mods : u8) -> u8 {
	r : u8 = 0
	if mods & 1 != 0 {
		r |= 4
	}
	if mods & 2 != 0 {
		r |= 8
	}
	if mods & 4 != 0 {
		r |= 16
	}
	return r
}

// 发送一个 SGR 鼠标序列:CSI < cb ; col ; row M(按下/滚轮/移动)/ m(释放)
sendSGR :: proc(console : ^Console, cb : u8, col, row : int, release : bool) {
	final := u8('M')
	if release {
		final = 'm'
	}
	msg := fmt.aprintf("\x1b[<%d;%d;%d%c", cb, col, row, final)
	defer delete(msg) // aprintf 用 context.allocator,与 delete 匹配
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// 编码并上报本帧鼠标事件(协议 = SGR 1006;未启用时忽略,旧 X10 编码暂不支持)
mouseToApp :: proc(console : ^Console, font_h : mem.Handle) {
	if !console.vt.sgr_mouse {
		return
	}
	m := &inp.Mouse
	col, row, ok := mouseCell(console, font_h, m.x, m.y)
	if !ok {
		return
	}
	mods := sgrMods(m.mods)

	// 按钮:0=左 1=中 2=右;按下 M,释放 m
	btn_by_bit := [?]u8{0, 1, 2} // bit1/2/4 → 按钮号
	for i in 0 ..< 3 {
		bit := u8(1 << u32(i))
		if m.press & bit != 0 {
			sendSGR(console, btn_by_bit[i] + mods, col, row, false)
		}
		if m.release & bit != 0 {
			sendSGR(console, btn_by_bit[i] + mods, col, row, true)
		}
	}

	// 滚轮:64=上 65=下,每 tick 一档
	if m.wheel != 0 {
		n := m.wheel < 0 ? -m.wheel : m.wheel
		cb := u8(64)
		if m.wheel < 0 {
			cb = 65
		}
		for k in 0 ..< n {
			sendSGR(console, cb + mods, col, row, false)
		}
	}

	// 移动:1002 = 按住时拖动(32+btn);1003 = 任意移动(无键 35)
	if m.moved {
		btn : u8 = 3 // 无键
		if m.right {
			btn = 2
		} else if m.middle {
			btn = 1
		} else if m.left {
			btn = 0
		}
		report := console.vt.mouse_mode == 3 || (console.vt.mouse_mode == 2 && btn != 3)
		if report {
			sendSGR(console, 32 + btn + mods, col, row, false)
		}
	}
}
