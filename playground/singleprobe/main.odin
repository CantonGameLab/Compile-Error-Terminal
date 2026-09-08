// SingleMode(页级)回归:枚举开关、有效矩形公式、单窗拦截器、销毁先回 Tiled。
// 纯逻辑探针:工具 console(conpty = 0)+ 空窗口,不触 UI / GL / 字体。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	// 解析别名
	pc, ok := cmd.ParseCommandString("single")
	check("parse single", ok && pc.kind == .ToggleSingleMode, true)
	pc, ok = cmd.ParseCommandString("single-mode")
	check("parse single-mode", ok && pc.kind == .ToggleSingleMode, true)

	// 建页:默认 Tiled(枚举零值)
	page := cv.PageNew()
	check("page created", page.id != 0, true)
	p := cv.CurrentPage()
	check("default Tiled", p.view_mode, cv.PageMode.Tiled)

	// 平铺:split(焦点 = 右叶,共 2 窗);左叶 = 原根
	ok = cmd.ExecuteCommandString("split right")
	check("split in tiled", ok, true)
	check("window count", cv.WindowCount(), 2)
	focus := p.focused
	left := cv.WindowTreeRoot()
	check("focus is right leaf", focus != left, true)
	rt := cv.GetWindowTreeNode(cv.WindowTreeRoot()).transform
	ft := cv.GetWindowTreeNode(focus).transform
	lt := cv.GetWindowTreeNode(left).transform
	check("tree area rect", rt == cv.Transform { position_x = 0, position_y = 0, width = f32(cv.Window_Width), height = f32(cv.Window_Height) }, true)

	// 未开 single:有效矩形 = 节点自身
	check("eff rect = node (off)", cv.WindowEffectiveRect(focus), ft)
	check("eff rect != tree (off)", cv.WindowEffectiveRect(focus) != rt, true)

	// 开 single(经命令):焦点叶有效矩形 = 树区;非焦点叶仍 = 自身
	ok = cmd.ExecuteCommandString("single")
	check("single exec", ok, true)
	check("mode Single", p.view_mode, cv.PageMode.Single)
	check("eff rect focus = tree", cv.WindowEffectiveRect(focus), rt)
	check("eff rect other = node", cv.WindowEffectiveRect(left), lt)

	// 规则在 userapi 域边界:绕过命令层直接调 userapi 同样被拒
	check("userapi focusmove blocked", cv.FocusMove(.Left), false)
	check("userapi setfocus blocked", cv.SetFocusWindow(left), false)
	check("userapi split blocked", cv.SplitNewWindow(.LeftRight).id == 0, true)
	check("userapi exchange blocked", cv.ExchangeWindow(.Left), false)
	check("userapi factor blocked", cv.SetSplitFactor(0.5), false)
	check("userapi factorleaf blocked", cv.SetSplitFactorLeaf(1, 0.5), false)

	// 拦截器:树/焦点/尺寸类操作在 Single 下返回 false
	ok = cmd.ExecuteCommandString("focus left")
	check("focus blocked", ok, false)
	ok = cmd.ExecuteCommandString("split right")
	check("split blocked", ok, false)
	ok = cmd.ExecuteCommandString("exchange left")
	check("exchange blocked", ok, false)
	ok = cmd.ExecuteCommandString("factor 0.5")
	check("factor blocked", ok, false)
	ok = cmd.ExecuteCommandString("factorleaf 1 0.5")
	check("factorleaf blocked", ok, false)

	// Launch:焦点已占用(会分屏)→ Single 下拒绝;未开 single 前不拦(见下)
	win := cv.NodeWindow(focus)
	ch, cok := cv.CreateConsole(24, 80, {}) // 工具 console(无会话)
	check("tool console", cok, true)
	win.console_id = ch
	ok = cmd.ExecuteCommandString("launch bash")
	check("launch busy blocked in single", ok, false)

	// 销毁显示中的焦点窗:自动回 Tiled 再销毁(焦点迁移到左叶)
	ok = cmd.ExecuteCommandString("destroy")
	check("destroy allowed in single", ok, true)
	check("mode back Tiled", p.view_mode, cv.PageMode.Tiled)
	check("window count after destroy", cv.WindowCount(), 1)

	// 唯一剩余窗(single 中销毁):回 Tiled;页空保留(最后一页)
	ok = cmd.ExecuteCommandString("single")
	check("re-single", ok && p.view_mode == .Single, true)
	ok = cmd.ExecuteCommandString("destroy")
	check("destroy root in single", ok, true)
	check("mode back Tiled (root)", p.view_mode, cv.PageMode.Tiled)
	check("page still alive", cv.PageCount(), 1)
	check("root window cleared", cv.NodeWindow(cv.WindowTreeRoot()) == nil, true)
}
