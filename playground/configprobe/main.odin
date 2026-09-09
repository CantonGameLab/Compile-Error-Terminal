// 配置阶段回归(模拟 main 的启动序列):LoadConfig 建页 + 主题库载入 + 只开一页 + 键位装好。
// 纯逻辑探针:不触 GL(配置里的 vsync/borderless/bgshader 行会失败,属预期)。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import mem "../../src/memory"
import "core:fmt"

fails : int

check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-46s %s\n", name, status)
}

countThemes :: proc() -> int {
	reg := cv.GetThemes()
	n := 0
	for i in 1 ..< cv.MAX_THEME_SLOTS {
		if mem.GetIndex(reg, i) != nil {
			n += 1
		}
	}
	return n
}

main :: proc() {
	// main 的启动序列:render/input 初始化之后 → LoadConfig → 未建页则保底建页
	gs := cmd.LoadConfig()
	check("配置已加载", gs.loaded)
	check("无未知命令(load 生效)", gs.failed <= 3)
	check("主题库已载入:tango-dark", cv.GetThemeSlot("tango-dark") != nil)
	check("主题库 ≥ 8 套", countThemes() >= 8)
	check("配置选中主题已激活(bg = #000000)", cv.GetTheme().bg == 0x000000)
	check("只建了 1 页", cv.PageCount() == 1)
	check("键位已装(F2 命令栏)", cmd.GetKeyBinding(.F2, {}) != nil)
	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
