// 图形协议端到端:用 ratatui-image(yazi 所用库)的原始字节序列驱动真实
// vtparse(含 console 回调)→ APC 收集 → 存储 → 占位符格落位,逐项断言。
// 序列构成(源自 ratatui-image src/protocol/kitty.rs):
//   传输:ESC_G q=2,i=7,a=T,U=1,f=32,t=d,s=2,v=2,m=0;<b64>ESC\
//   渲染每行:ESC[s ESC[38;2;<id3字节>m U+10EEEE <row><col><extra> U+10EEEE… ESC[u ESC[C ESC[B
package main

import cv "../../src/canvas"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	ch, cok := cv.CreateConsole(24, 80, {})
	check("tool console", cok, true)
	console := cv.GetConsole(ch)

	// 载荷 base64(16 字节 0..15 → AAECAwQFBgcICQoLDA0ODw==)
	TX := "\x1b_Gq=2,i=7,a=T,U=1,f=32,t=d,s=2,v=2,m=0;AAECAwQFBgcICQoLDA0ODw==\x1b\\"
	cv.Parse(&console.vt.parser, transmute([]u8)TX)

	check("image stored", len(console.images) == 1, true)
	check("client id 7", console.images[0].client_id == 7, true)
	check("dims 2x2", console.images[0].width == 2 && console.images[0].height == 2, true)
	virt := -1
	for i in 0 ..< len(console.placements) {
		if console.placements[i].virtual {
			virt = i
		}
	}
	check("virtual placement", virt >= 0, true)

	// 渲染:两行占位符(ratatui 帧序 = 每格绝对定位;id=7 → 38;2;0;0;7m;
	// row0 = 0x0305,row1 = 0x030D;两行均从 col 0 起)
	PH := "\x1b[1;1H" +
		"\x1b[s\x1b[38;2;0;0;7m" +
		"\xF4\x8E\xBB\xAE" + "\xCC\x85\xCC\x85\xCC\x85" + "\xF4\x8E\xBB\xAE" +
		"\x1b[u\x1b[1C\x1b[1B" +
		"\x1b[2;1H" +
		"\x1b[s\x1b[38;2;0;0;7m" +
		"\xF4\x8E\xBB\xAE" + "\xCC\x8D\xCC\x85\xCC\x85" + "\xF4\x8E\xBB\xAE" +
		"\x1b[u\x1b[1C\x1b[1B"
	cv.Parse(&console.vt.parser, transmute([]u8)PH)

	// 落格断言:行 0 占位符在 col 0/1,行 1 在 col 0/1(ESC[s/u 已定位)
	row0_ok := false
	row1_ok := false
	if len(tb_lines(console)) >= 2 {
		l0 := tb_lines(console)[0]
		l1 := tb_lines(console)[1]
		if len(l0.cells) >= 2 && len(l1.cells) >= 2 {
			c00 := l0.cells[0]
			c01 := l0.cells[1]
			c10 := l1.cells[0]
			c11 := l1.cells[1]
			row0_ok = c00.kind == .Image && c01.kind == .Image &&
				c00.cp == cv.IMAGE_PLACEHOLDER_CHAR && c00.diacritic_count == 3 &&
				c00.fg == 7 && c01.diacritic_count == 0
			row1_ok = c10.kind == .Image && c10.diacritic_count == 3 &&
				c10.diacritics[0] == 0x030D && c10.diacritics[1] == 0x0305 &&
				c10.fg == 7 && c11.kind == .Image
		}
	}
	check("row0 placeholders", row0_ok, true)
	check("row1 placeholders", row1_ok, true)
	fmt.printf("  .. row0=%v row1=%v\n", row0_ok, row1_ok)
	// dump
	lines := tb_lines(console)
	for r in 0 ..< min(3, len(lines)) {
		l := lines[r]
		for c in 0 ..< min(8, len(l.cells)) {
			cell := l.cells[c]
			if cell.kind != .Single || cell.cp != 0 {
				fmt.printf("  L%d C%d kind=%v cp=0x%X fg=0x%X dia=%d\n",
					r, c, cell.kind, u32(cell.cp), cell.fg, cell.diacritic_count)
			}
		}
	}

	cv.DestroyConsole(ch)
	fmt.println("gfxe2e done")
}

tb_lines :: proc(c : ^cv.Console) -> []cv.Line {
	tb := cv.GetTermBuffer(c.active_term_buffer_id)
	if tb == nil {
		return nil
	}
	return tb.lines[:]
}
