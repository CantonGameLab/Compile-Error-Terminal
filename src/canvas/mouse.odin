// 鼠标交互状态:分割条拖拽(SplitDrag)+ 光标反馈。
// 数据:全局唯一实例(单鼠标);target = 句柄,有效性与页归属每帧验证(自愈:
// 树变化/切页自动取消)。拖拽独占路由:active 期间任何鼠标事件归它
// (left 释放结束 / 右键取消回滚 / 位移更新因子),不判其他命中。
// 光标反馈 = 消费 input.SetCursor(系统光标,懒创建,每帧判定)。
package canvas

import fnt "../font"
import inp "../input"
import mem "../memory"

SplitDrag :: struct {
	active : bool, // 拖拽中(命中条按下 → 释放/取消);false = 空闲
	target : mem.Handle, // 被拖拽的内部节点(分割条所属);0 = 无
	origin_factor : f32, // 按下瞬间 split_factor(更新锚 + 右键取消回滚值)
	origin_px : f32, // 按下瞬间鼠标轴坐标(横条 = x,竖条 = y)
}

split_drag : SplitDrag

SplitDragActive :: proc() -> bool {
	return split_drag.active
}

// 拖拽目标(渲染高亮只读消费);非拖拽 = 0
SplitDragTarget :: proc() -> mem.Handle {
	if split_drag.active {
		return split_drag.target
	}
	return {}
}

// 开始拖拽(press 左键命中条后调用):记录按下瞬间因子/轴坐标(绝对锚)
splitDragBegin :: proc(target : mem.Handle, x, y : f32) -> bool {
	node := GetWindowTreeNode(target)
	if node == nil || node.is_leaf {
		return false
	}
	split_drag = SplitDrag {
		active = true,
		target = target,
		origin_factor = node.split_factor,
		origin_px = node.split_type == .LeftRight ? x : y,
	}
	return true
}

// 拖拽独占入口(active 期间):释放结束 / 右键取消回滚 / 位移更新因子。
// 自愈:target 失效(销毁/变叶/不在当前页树)→ 结束(无恢复对象)。
// 因子更新与取消走同一 TreeNodeSetSplitFactor 入口(单点 clamp + 重算)。
splitDragUpdate :: proc(m : ^inp.MouseState) {
	node := GetWindowTreeNode(split_drag.target)
	if node == nil || node.is_leaf || !inCurrentPageTree(split_drag.target) {
		split_drag.active = false
		return
	}
	// 单窗模式:分割条不可见,拖拽作废(模式切换自愈)
	if p := CurrentPage(); p != nil && p.view_mode == .Single {
		split_drag.active = false
		return
	}
	if m.release & 1 != 0 {
		split_drag.active = false
		return
	}
	// 右键取消:回归按下瞬间因子
	if m.press & 4 != 0 {
		TreeNodeSetSplitFactor(split_drag.target, split_drag.origin_factor)
		split_drag.active = false
		return
	}
	if m.moved {
		avail := node.split_type == .LeftRight ? node.width - f32(node.frame_width) : node.height - f32(node.frame_width)
		cur_px := node.split_type == .LeftRight ? m.x : m.y
		delta := cur_px - split_drag.origin_px
		if avail > 0 {
			TreeNodeSetSplitFactor(split_drag.target, split_drag.origin_factor + delta / avail)
		}
	}
}

// 光标反馈:拖拽常驻轴光标;悬停条 → 轴光标;其余默认。
// 只在鼠标移动帧查询(静止帧零树遍历,光标保持上次);无位置/按压中不切换。
updateCursor :: proc() {
	if split_drag.active {
		if node := GetWindowTreeNode(split_drag.target); node != nil {
			inp.SetCursor(axisCursor(node.split_type))
			return
		}
	}
	if !inp.Mouse.moved {
		return // 静止帧:光标不动,不查询(热路径零开销)
	}
	if !inp.Mouse.x_ok || inp.Mouse.left || inp.Mouse.press != 0 {
		return
	}
	// 单窗模式:分割条不可见 → 无轴光标;悬停窗 = 页焦点(选区光标按它判定)
	p := CurrentPage()
	single := p != nil && p.view_mode == .Single
	if !single {
		if h := SplitFrameHit(inp.Mouse.x, inp.Mouse.y); h.id != 0 {
			if node := GetWindowTreeNode(h); node != nil {
				inp.SetCursor(axisCursor(node.split_type))
				return
			}
		}
	}
	// 悬停在被选 buffer 的选区内 → 文本光标(Windows 惯例:选区即文本光标)
	n : mem.Handle
	if single {
		n = p.focused
	} else {
		n = nodeAtPoint(inp.Mouse.x, inp.Mouse.y)
	}
	if n.id != 0 {
		if console := NodeConsole(n); console != nil {
			if selection.buffer_h.id != 0 &&
				console.active_term_buffer_id == selection.buffer_h {
				m := fnt.GetMetrics(console.font_id)
				tb := GetTermBuffer(selection.buffer_h)
				if m.cell_width > 0 && m.cell_height > 0 && tb != nil {
					col := clamp(int((inp.Mouse.x - console.origin_x) / m.cell_width), 0, int(console.cols) - 1)
					row := clamp(int((inp.Mouse.y - console.origin_y) / m.cell_height), 0, int(console.rows) - 1)
					top, _ := ConsoleViewportTop(NodeConsoleId(n))
					line := top + row
					w := 1
					if line >= 0 && line < len(tb.lines) && col < len(tb.lines[line].cells) {
						cell := tb.lines[line].cells[col]
						if cell.cp == 0 && cell.wide && col > 0 {
							col -= 1
							cell = tb.lines[line].cells[col]
						}
						if cell.cp != 0 && cell.wide {
							w = 2
						}
					}
					if CellSelected(line, col, w, int(console.cols)) {
						inp.SetCursor(.Text)
						return
					}
				}
			}
		}
	}
	inp.SetCursor(.Default)
}

axisCursor :: proc(st : SplitType) -> inp.CursorKind {
	if st == .LeftRight {
		return .ResizeH
	}
	return .ResizeV
}
