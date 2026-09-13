// OSC 语义探针:0/1/2(应用标题)、7(工作目录 + 形态归一)、52(选择器读写)、
// 超长段整段丢弃。逐项断言「解析 → 落点」;工具 console(无 ConPTY)即可覆盖解析层,
// 应答路径(需要真实管道)不在此验证。
// 用法:odin run playground/oscsem/
package main

import cv "../../src/canvas"
import inp "../../src/input"
import s3 "vendor:sdl3"
import "core:fmt"

fail_count : int

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
		fail_count += 1
	}
}

feed :: proc(console : ^cv.Console, s : string) {
	cv.Parse(&console.vt.parser, transmute([]u8)s)
}

main :: proc() {
	ch, cok := cv.CreateConsole(24, 80, {})
	check("tool console", cok, true)
	console := cv.GetConsole(ch)
	if console == nil {
		return
	}

	fmt.println("-- OSC 0/1/2 应用标题 --")
	feed(console, "\x1b]2;vim - main.odin\x07") // BEL 终止
	check("osc2 (BEL)", console.app_title, "vim - main.odin")
	feed(console, "\x1b]0;icon+title\x1b\\") // ST 终止
	check("osc0 (ST)", console.app_title, "icon+title")
	feed(console, "\x1b]1;just an icon\x07") // 图标名:不动标题
	check("osc1 ignored", console.app_title, "icon+title")
	feed(console, "\x1b]2;\x07") // 空 = 清除
	check("osc2 clear", len(console.app_title), 0)

	fmt.println("-- OSC 7 会话工作目录(形态归一;记在各会话名下)--")
	feed(console, "\x1b]7;file:///C:/Users/GroupTheory/Source\x07")
	check("windows 形态", console.cwd, "C:\\Users\\GroupTheory\\Source")
	feed(console, "\x1b]7;file:///c/Users/GroupTheory\x07")
	check("msys2 形态", console.cwd, "C:\\Users\\GroupTheory")
	feed(console, "\x1b]7;file://host/C:/a%20b%2Fc\x07")
	check("host 跳过 + 百分号", console.cwd, "C:\\a b\\c")
	feed(console, "\x1b]7;https://example.com/x\x07")
	check("非 file:// 忽略", console.cwd, "C:\\a b\\c")

	fmt.println("-- 超长 OSC:整段丢弃(不执行截断内容)--")
	feed(console, "\x1b]2;keep me\x07")
	over := make([dynamic]u8, 0, 6000)
	defer delete(over)
	append(&over, ..transmute([]u8)string("\x1b]2;"))
	for _ in 0 ..< 5000 {
		append(&over, 'x')
	}
	append(&over, 0x07)
	cv.Parse(&console.vt.parser, over[:])
	check("超长段不改标题", console.app_title, "keep me")

	fmt.println("-- OSC 52 剪贴板 --")
	if s3.Init(s3.INIT_VIDEO) {
		defer s3.Quit()
		orig := inp.GetClipboardText()
		orig_copy := make([]u8, len(orig))
		copy(orig_copy, orig)
		defer {
			inp.SetClipboardText(orig_copy) // 还原用户剪贴板
			delete(orig_copy)
		}
		feed(console, "\x1b]52;c;aGVsbG8=\x07") // "hello"
		check("52 写(显式 c)", string(inp.GetClipboardText()), "hello")
		feed(console, "\x1b]52;aGVsbG8gd29ybGQ=\x07") // 选择器缺省
		check("52 写(缺省选择器)", string(inp.GetClipboardText()), "hello world")
		feed(console, "\x1b]52;c;?\x07") // 查询:无 ConPTY → 不应答且不崩
		check("52 查询不崩", true, true)
	} else {
		fmt.println("  skip  52:SDL video 初始化失败(剪贴板不可用)")
	}

	fmt.printf("\n结果:%s\n", fail_count == 0 ? "ALL PASS" : "有失败")
}
