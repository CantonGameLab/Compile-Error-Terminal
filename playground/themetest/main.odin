// 主题系统回归:颜色引用编码 + ResolveColor 解码 + SGR → cell 编码写链。
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

index :: proc(n : int) -> u32 {
	return 0x01_000000 | u32(n)
}

main :: proc() {
	t := cv.GetTheme()
	fmt.println("== 解码(默认主题)==")
	check("rgb passthrough", cv.ResolveColor(0x123456, 0), u32(0x123456))
	check("default → theme.fg", cv.ResolveColor(0xFFFFFFFF, t.fg), t.fg)
	check("index 1 → ansi[1]", cv.ResolveColor(index(1), 0), t.ansi[1])
	check("index 16 → cube 0", cv.ResolveColor(index(16), 0), u32(0x000000))
	check("index 21 → cube 00FF", cv.ResolveColor(index(21), 0), u32(0x0000FF))
	check("index 232 → gray 08", cv.ResolveColor(index(232), 0), u32(0x080808))
	check("index 255 → gray EE", cv.ResolveColor(index(255), 0), u32(0xEEEEEE))

	fmt.println("== 主题注册表:theme-set 生效 ==")
	// 建一个命名主题并改字段(激活后 ResolveColor 走新表)
	check("define+set ansi1", cv.SetThemeField("probe", .Ansi, 1, 0xABCDEF), true)
	check("set focus_border", cv.SetThemeField("probe", .FocusBorder, 0, 0x112233), true)
	check("activate probe", cv.SetThemeByName("probe"), true)
	check("ansi override", cv.ResolveColor(index(1), 0), u32(0xABCDEF))
	check("theme get", cv.GetTheme().focus_border, u32(0x112233))
	check("slot lookup", cv.GetThemeSlot("probe") != nil, true)
	// 回退:再建一个与 boot 同值的主题并激活(注册表无"取消激活"语义)
	check("define restore", cv.SetThemeField("restore", .Ansi, 1, t.ansi[1]), true)
	check("activate restore", cv.SetThemeByName("restore"), true)
	check("restore", cv.ResolveColor(index(1), 0), t.ansi[1])
	check("ansi index 越界", cv.SetThemeField("probe", .Ansi, 99, 0), false)
	check("未定义主题激活失败", cv.SetThemeByName("no-such-theme"), false)

	fmt.println("== SGR → cell 编码 ==")
	ctx, ok := ct.CreateConptyContext({120, 40}, "cmd.exe")
	if !ok {
		fmt.println("pty failed")
		return
	}
	// 不启读线程:ConsoleFeed 直接喂解析器(绕过 ConPTY)
	ch, cok := cv.CreateConsole(40, 120, ctx)
	if !cok {
		fmt.println("console failed")
		return
	}
	defer cv.DestroyConsole(ch)
	seq := "\x1b[31mR\x1b[38;5;196mG\x1b[38;2;1;2;3mB\x1b[0mX"
	cv.ConsoleFeed(ch, transmute([]u8)seq)

	tb := cv.GetTermBuffer(cv.GetConsole(ch).active_term_buffer_id)
	if tb == nil || len(tb.lines) == 0 || len(tb.lines[0].cells) < 4 {
		fmt.println("buffer shape failed")
		return
	}
	cells := tb.lines[0].cells
	check("R fg = index 1", cells[0].fg, index(1))
	check("G fg = index 196", cells[1].fg, index(196))
	check("B fg = rgb 010203", cells[2].fg, u32(0x010203))
	check("X fg = default", cells[3].fg, u32(0xFFFFFFFF))

	fmt.println("== SGR 样式位(粗/斜/下划线/删除线/双下划线/上划线)==")
	style_seq := "\x1b[1mA\x1b[3mB\x1b[4mC\x1b[9mD\x1b[21mE\x1b[53mF\x1b[0mX"
	cv.ConsoleFeed(ch, transmute([]u8)style_seq)
	scells := tb.lines[0].cells // 同屏追加:无 LF,字符顺序续写
	check("A bold", scells[4].bold, true)
	check("B italic", scells[5].italic, true)
	check("C underline", scells[6].underline, u8(1))
	check("D crossed", scells[7].crossed, true)
	check("E double underline", scells[8].underline, u8(2))
	check("F overline", scells[9].overline, true)
	check("X reset all", scells[10].bold == false && scells[10].italic == false &&
		scells[10].underline == 0 && scells[10].crossed == false && scells[10].overline == false, true)
}
