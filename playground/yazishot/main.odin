// 真实 yazi 预览验证:ConPTY 内启动 yazi(指向仅含一张测试图的目录)→
// 帧循环消费(与 app 同路径:UpdateConsole = RingPop + vtFeed)→ 若干秒后
// 渲染一帧 → glReadPixels 落盘。GFX 日志经 -define:gfx_debug=true 打印,
// 可观察 yazi 实际发来的图形 APC 序列(探测/传图/占位符)。
// 用法:odin run playground/yazishot/ -define:gfx_debug=true
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import rnd "../../src/render"
import gl "vendor:OpenGL"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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

main :: proc() {
	if !rnd.Init() {
		fmt.eprintln("render init failed")
		return
	}
	defer rnd.Quit()

	page := cv.PageNew()
	if page.id == 0 {
		fmt.eprintln("page failed")
		return
	}
	if !cv.SetWindowFont("Consolas", 26) {
		fmt.eprintln("font failed")
		return
	}

	// ConPTY 内启动 yazi(仅一个文件的目录;yazi 打开即选中该文件 → 右栏图像预览)
	yazi := `"C:\Users\GroupTheory\AppData\Local\Programs\yazi\yazi-x86_64-pc-windows-msvc\yazi.exe"`
	target := `"C:\Users\GroupTheory\Source\dterm\playground\yazitest\dterm_demo.png"`

	cmdline := fmt.tprintf("%s %s", yazi, target)
	ctx, ok := ct.CreateConptyContext({120, 40}, cmdline)
	if !ok {
		fmt.eprintln("conpty failed")
		return
	}
	_ = ct.StartReadThread(ctx) // 读线程向环形缓冲 push(app 的 LaunchConsole 同样路径)
	ch, _ := cv.CreateConsole(40, 120, ctx)
	win := cv.NodeWindow(cv.WindowTreeRoot())
	win.console_id = ch
	cv.ConsoleUpdateTree(cv.WindowTreeRoot())

	// 帧循环:拉环形缓冲 → 解析(含图形 APC,日志经 define 开启);约 10s
	start := time.now()
	tick := 0
	for time.since(start) < 10 * time.Second {
		cv.UpdateConsole(ch)
		time.sleep(30 * time.Millisecond)
		tick += 1
	}
	// 再排空一次
	cv.UpdateConsole(ch)

	console := cv.GetConsole(ch)
	fmt.printf("rows=%d cols=%d images=%d placements=%d\n",
		console.rows, console.cols, len(console.images), len(console.placements))
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	for r := 0; r < min(30, len(tb.lines)); r += 1 {
		sb : strings.Builder
		for cell in tb.lines[r].cells {
			#partial switch cell.kind {
			case .WideFirst: strings.write_rune(&sb, 0x2588)
			case .Image: strings.write_rune(&sb, 0x2588)
			case: if cell.cp != 0 { strings.write_rune(&sb, cell.cp) } else { strings.write_rune(&sb, 0x20) }
			}
		}
		fmt.printf("L%d: %s\\n", r, strings.to_string(sb))
	}

	// 渲染一帧 + 读回
	rnd.BeginFrame()
	rnd.DrawFrame()
	sw, sh := rnd.GetWindowSize()
	shot := make([]u8, int(sw) * int(sh) * 4)
	defer delete(shot)
	gl.ReadPixels(0, 0, i32(sw), i32(sh), gl.RGBA, gl.UNSIGNED_BYTE, &shot[0])
	rnd.EndFrame()
	write_bmp("C:\\Users\\GroupTheory\\Source\\dterm\\yazi_shot.bmp", shot, int(sw), int(sh))
	fmt.printf("wrote yazi_shot.bmp %dx%d\n", sw, sh)

	ct.DestroyConpty(ctx)
	cv.DestroyConsole(ch)
}
