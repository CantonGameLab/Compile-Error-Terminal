// 图形真实渲染验证:初始化 GL 窗口 → 建页/窗/工具 console → SetWindowFont →
// 喂 ratatui 等价 APC 序列(f=32,RGBA 测试图 + U=1 + 占位符网格)→ 渲染一帧 →
// glReadPixels → 落盘 BMP(真实 GPU 管线:纹理上传/quad/混合/UV 全走真路径)。
// 运行会弹一个窗口(render.Init),截图写 gfx_shot.bmp。
package main

import cv "../../src/canvas"
import rnd "../../src/render"
import gl "vendor:OpenGL"
import "core:fmt"
import "core:os"

// ---------------------------------------------------------------------------
// 小工具:UTF-8 编码 / base64 编码 / BMP 写
// ---------------------------------------------------------------------------
utf8_enc :: proc(cp : rune, buf : []u8) -> int {
	switch {
	case cp < 0x80:
		buf[0] = u8(cp)
		return 1
	case cp < 0x800:
		buf[0] = 0xC0 | u8(cp >> 6)
		buf[1] = 0x80 | u8(cp & 0x3F)
		return 2
	case cp < 0x10000:
		buf[0] = 0xE0 | u8(cp >> 12)
		buf[1] = 0x80 | u8(cp >> 6 & 0x3F)
		buf[2] = 0x80 | u8(cp & 0x3F)
		return 3
	case:
		buf[0] = 0xF0 | u8(cp >> 18)
		buf[1] = 0x80 | u8(cp >> 12 & 0x3F)
		buf[2] = 0x80 | u8(cp >> 6 & 0x3F)
		buf[3] = 0x80 | u8(cp & 0x3F)
		return 4
	}
}

B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

b64_enc :: proc(data : []u8, dst : []byte) -> int {
	n := 0
	i := 0
	for i + 2 < len(data) {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		dst[n + 0] = B64[v >> 18 & 63]
		dst[n + 1] = B64[v >> 12 & 63]
		dst[n + 2] = B64[v >> 6 & 63]
		dst[n + 3] = B64[v & 63]
		n += 4
		i += 3
	}
	tail := len(data) - i
	if tail == 1 {
		v := u32(data[i]) << 16
		dst[n + 0] = B64[v >> 18 & 63]
		dst[n + 1] = B64[v >> 12 & 63]
		dst[n + 2] = '='
		dst[n + 3] = '='
		n += 4
	} else if tail == 2 {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		dst[n + 0] = B64[v >> 18 & 63]
		dst[n + 1] = B64[v >> 12 & 63]
		dst[n + 2] = B64[v >> 6 & 63]
		dst[n + 3] = '='
		n += 4
	}
	return n
}

write_bmp :: proc(path : string, pixels : []u8, w, h : int) {
	row_sz := (w * 3 + 3) / 4 * 4
	data_sz := row_sz * h
	file_sz := 54 + data_sz
	buf := make([]u8, file_sz)
	defer delete(buf)
	buf[0] = 'B'
	buf[1] = 'M'
	buf[2] = u8(file_sz)
	buf[3] = u8(file_sz >> 8)
	buf[4] = u8(file_sz >> 16)
	buf[5] = u8(file_sz >> 24)
	buf[10] = 54
	buf[14] = 40
	buf[18] = u8(w)
	buf[19] = u8(w >> 8)
	buf[20] = u8(w >> 16)
	buf[21] = u8(w >> 24)
	buf[22] = u8(h)
	buf[23] = u8(h >> 8)
	buf[24] = u8(h >> 16)
	buf[25] = u8(h >> 24)
	buf[26] = 1
	buf[28] = 24
	// GL 读回行序 = 底到顶 → BMP 也是自底向上,直接写
	for y in 0 ..< h {
		src := y * w * 4
		dst := 54 + y * row_sz
		for x in 0 ..< w {
			buf[dst + x * 3 + 0] = pixels[src + x * 4 + 2]
			buf[dst + x * 3 + 1] = pixels[src + x * 4 + 1]
			buf[dst + x * 3 + 2] = pixels[src + x * 4 + 0]
		}
	}
	_ = os.write_entire_file(path, buf)
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
main :: proc() {
	if !rnd.Init() {
		fmt.eprintln("render init failed")
		return
	}
	defer rnd.Quit()

	// 页 + 根窗 + 字体(探针环境真实字体注册表解析)
	page := cv.PageNew()
	if page.id == 0 {
		fmt.eprintln("page failed")
		return
	}
	if !cv.SetConsoleFont("Consolas", 26) {
		fmt.eprintln("font failed")
		return
	}
	ch, _ := cv.CreateConsole(24, 80, {})
	if ch.id == 0 {
		fmt.eprintln("console failed")
		return
	}
	cv.TreeNodeSetConsole(cv.WindowTreeRoot(), ch)

	// 布局(几何按字体)
	cv.ConsoleUpdateTree(cv.WindowTreeRoot())

	// 测试图:60x30(红边框 + 橙/蓝棋盘)
	IW, IH := 60, 30
	rgba := make([]u8, IW * IH * 4)
	defer delete(rgba)
	for y in 0 ..< IH {
		for x in 0 ..< IW {
			i := (y * IW + x) * 4
			switch {
			case x == 0 || y == 0 || x == IW - 1 || y == IH - 1:
				rgba[i + 0], rgba[i + 1], rgba[i + 2], rgba[i + 3] = 255, 0, 0, 255
			case (x / 5 + y / 5) % 2 == 0:
				rgba[i + 0], rgba[i + 1], rgba[i + 2], rgba[i + 3] = 255, 128, 0, 255
			case:
				rgba[i + 0], rgba[i + 1], rgba[i + 2], rgba[i + 3] = 0, 128, 255, 255
			}
		}
	}

	// 传输 + 虚拟放置(id=42,盒 30x15 格);按 yazi 方式分块:每 APC ≤ 4096 base64 字符
	b64 := make([]byte, (len(rgba) + 2) / 3 * 4)
	defer delete(b64)
	nb := b64_enc(rgba, b64)
	buf : [256]u8
	mdbuf : [256]u8
	CHUNK :: 4096
	off := 0
	for {
		n_this := min(CHUNK, nb - off)
		more := off + n_this < nb
		md := ""
		if off == 0 {
			md = fmt.bprintf(mdbuf[:], ",i=42,a=T,U=1,f=32,t=d,s=%d,v=%d,c=30,r=15", IW, IH)
		}
		mv := "1"
		if !more {
			mv = "0"
		}
		head := fmt.bprintf(buf[:], "\x1b_Gq=2%s,m=%s;", md, mv)
		tx := make([]u8, len(head) + n_this + 2)
		defer delete(tx)
		copy(tx[:], head)
		copy(tx[len(head):], b64[off:off + n_this])
		tx[len(head) + n_this] = 0x1B
		tx[len(head) + n_this + 1] = '\\'
		cv.ConsoleFeed(ch, tx)
		off += n_this
		if !more {
			break
		}
	}

	// 占位符:15 行 x 30 格(行 0..14;首格带 行/列0/高0 声调,余格继承)
	diac : [15]rune = {
		0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
		0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352,
	}
	ph : [dynamic]u8
	defer delete(ph)
	u8buf : [4]u8
	hdr : [64]u8
	tail : [32]u8
	for row in 0 ..< 15 {
		h := fmt.bprintf(hdr[:], "\x1b[%d;1H\x1b[s\x1b[38;2;0;0;42m", row + 1)
		append(&ph, ..hdr[:len(h)])
		n := utf8_enc(0x10EEEE, u8buf[:])
		append(&ph, ..u8buf[:n])
		n = utf8_enc(diac[row], u8buf[:])
		append(&ph, ..u8buf[:n])
		n = utf8_enc(diac[0], u8buf[:])
		append(&ph, ..u8buf[:n])
		n = utf8_enc(diac[0], u8buf[:])
		append(&ph, ..u8buf[:n])
		for c in 1 ..< 30 {
			n = utf8_enc(0x10EEEE, u8buf[:])
			append(&ph, ..u8buf[:n])
		}
		t := fmt.bprintf(tail[:], "\x1b[u\x1b[29C\x1b[14B")
		append(&ph, ..tail[:len(t)])
	}
	cv.ConsoleFeed(ch, ph[:])

	// 诊断:数据层状态
	console := cv.GetConsole(ch)
	fmt.printf("images=%d placements=%d\n", len(console.images), len(console.placements))
	virt := -1
	for i in 0 ..< len(console.placements) {
		if console.placements[i].virtual {
			virt = i
		}
	}
	fmt.printf("virt idx=%d\n", virt)
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	img_cells := 0
	for line in tb.lines {
		for cell in line.cells {
			if cell.kind == .Image {
				img_cells += 1
			}
		}
	}
	fmt.printf("image cells=%d rows=%d lines=%d\n", img_cells, console.rows, len(tb.lines))

	// 渲染一帧 + 读回
	rnd.BeginFrame()
	rnd.DrawFrame()
	sw, sh := rnd.GetWindowSize()
	shot := make([]u8, int(sw) * int(sh) * 4)
	defer delete(shot)
	gl.ReadPixels(0, 0, i32(sw), i32(sh), gl.RGBA, gl.UNSIGNED_BYTE, &shot[0])
	rnd.EndFrame()
	write_bmp("gfx_shot.bmp", shot, int(sw), int(sh))
	fmt.printf("wrote gfx_shot.bmp %dx%d\n", sw, sh)
}
