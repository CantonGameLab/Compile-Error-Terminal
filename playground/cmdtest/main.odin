// 命令层回归:bind/unbind/bindings 字符串命令 + 缺补的动作命令解析。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import inp "../../src/input"
import "core:fmt"

lines : [64]string
line_count : int

collect :: proc(msg : string) {
	if line_count < len(lines) {
		lines[line_count] = msg
		line_count += 1
	}
}

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	// bind:解析 → 执行 → 查询命中
	pc, ok := cmd.ParseCommandString("bind alt+shift+l \"split right\"")
	check("bind parse ok", ok, true)
	check("bind kind", pc.kind, cmd.CommandStringKind.SetBinding)
	check("sub handle", pc.sub.id != 0, true)
	fmt.printf("  .. sc=%d mods=%v sub=%d\n", pc.sc, pc.mods, pc.sub.id)
	ok = cmd.ExecuteCommandString("bind alt+shift+l \"split right\"")
	check("bind exec", ok, true)
	b := cmd.GetKeyBinding(inp.Scancode(pc.sc), pc.mods)
	check("bind hit", b != nil, true)
	check("bind cmd kind", b.cmd.kind, cmd.CommandStringKind.Split)
	check("bind cmd dir", b.cmd.dir, cv.SplitType.LeftRight)

	// 大小写不敏感 + 无修饰
	ok = cmd.ExecuteCommandString("bind F2 \"toggle-commandbar\"")
	check("bind f2 exec", ok, true)
	check("f2 hit", cmd.GetKeyBinding(.F2, {}) != nil, true)

	// 覆盖:同 key+mods 换命令
	ok = cmd.ExecuteCommandString("bind alt+shift+l \"split down\"")
	check("bind overwrite", ok, true)
	b = cmd.GetKeyBinding(inp.Scancode(pc.sc), pc.mods)
	check("overwrite dir", b.cmd.dir, cv.SplitType.UpDown)

	// unbind
	ok = cmd.ExecuteCommandString("unbind alt+shift+l")
	check("unbind exec", ok, true)
	check("unbind gone", cmd.GetKeyBinding(inp.Scancode(pc.sc), pc.mods) == nil, true)
	ok = cmd.ExecuteCommandString("unbind alt+shift+l")
	check("unbind twice fail", ok, false)

	// bindings 输出(可再解析:格式往返)
	cmd.ExecuteCommandString("bindings", collect)
	check("bindings count>0", line_count > 0, true)
	fmt.printf("  .. %s\n", lines[0])
	back, back_ok := cmd.ParseCommandString(lines[0])
	check("bindings 行可再解析", back_ok && back.kind == .SetBinding, true)
	cmd.FreeParsedCommand(back)

	// 补缺动作命令解析
	pc, ok = cmd.ParseCommandString("fontsizeup")
	check("fontsizeup", ok && pc.kind == .FontSizeUp, true)
	pc, ok = cmd.ParseCommandString("fontsizedown")
	check("fontsizedown", ok && pc.kind == .FontSizeDown, true)
	pc, ok = cmd.ParseCommandString("reviewup")
	check("reviewup", ok && pc.kind == .ReviewUp, true)
	pc, ok = cmd.ParseCommandString("reviewdown")
	check("reviewdown", ok && pc.kind == .ReviewDown, true)
	pc, ok = cmd.ParseCommandString("toggle-commandbar")
	check("toggle-commandbar", ok && pc.kind == .ToggleCommandBar, true)

	// 非法组合
	_, ok = cmd.ParseCommandString("bind bogus+key \"split right\"")
	check("bad mods", ok, false)
	_, ok = cmd.ParseCommandString("bind alt+shift+ \"x\"")
	check("empty key", ok, false)
	_, ok = cmd.ParseCommandString("bind alt+f2 \"bind ctrl+f3 \\\"destroy\\\"\"")
	check("nested bind rejected", ok, false)
}
