// 正宗 kitty 协议端到端:ConPTY 内跑 Python 客户端(kitty 文档 send-png 扩展版)
// → 帧循环消费(app 同路径)→ 渲染一帧 → glReadPixels 截图。
// 验证:分块 PNG 显示 / 先传后放 / o=z 压缩 / a=q 查询应答回路。
// 用法:odin run playground/kittytest/ -define:gfx_debug=true
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

	if cv.PageNew().id == 0 {
		fmt.eprintln("page failed")
		return
	}
	if !cv.SetConsoleFont("Consolas", 26) {
		fmt.eprintln("font failed")
		return
	}

	cmdline := `python "C:\Users\GroupTheory\Source\dterm\playground\kittytest\probe_osc.py"`
	ctx, ok := ct.CreateConptyContext({120, 40}, cmdline)
	if !ok {
		fmt.eprintln("conpty failed")
		return
	}
	_ = ct.StartReadThread(ctx)
	ch, _ := cv.CreateConsole(40, 120, ctx)
	cv.TreeNodeSetConsole(cv.WindowTreeRoot(), ch)
	cv.ConsoleUpdateTree(cv.WindowTreeRoot())

	start := time.now()
	for time.since(start) < 5 * time.Second {
		if rw := ct.GetReadWriteData(ctx); rw != nil {
			dup : [16384]u8
			for {
				n := ct.RingPop(rw, dup[:])
				if n <= 0 { break }
				fh, _ := os.open("C:\\\\Users\\\\GroupTheory\\\\Source\\\\dterm\\\\raw2.bin", os.O_APPEND | os.O_CREATE | os.O_WRONLY)
				if fh != nil { os.write(fh, dup[:n]); os.close(fh) }
			}
		}
		time.sleep(30 * time.Millisecond)
	}
	cv.UpdateConsole(ch)

	console := cv.GetConsole(ch)
	fmt.printf("images=%d placements=%d\n", len(console.images), len(console.placements))
	for i in 0 ..< len(console.images) {
		img := &console.images[i]
		fmt.printf("  img[%d] id=%d w=%d h=%d rgba=%d ver=%d\n", i, img.client_id, img.width, img.height, len(img.rgba), img.data_version)
	}
	for i in 0 ..< len(console.placements) {
		p := &console.placements[i]
		fmt.printf("  plc[%d] img=%d line=%d col=%d z=%d c=%d r=%d virt=%v\n",
			i, p.image, p.line, p.col, p.z_index, p.num_cols, p.num_rows, p.virtual)
	}
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	for r := 0; r < min(40, len(tb.lines)); r += 1 {
		sb : strings.Builder
		for cell in tb.lines[r].cells {
			#partial switch cell.kind {
			case .WideFirst: strings.write_rune(&sb, 0x2588)
			case .Image: strings.write_rune(&sb, 0x2588)
			case: if cell.cp != 0 { strings.write_rune(&sb, cell.cp) } else { strings.write_rune(&sb, 0x20) }
			}
		}
		line := strings.to_string(sb)
		if len(line) > 0 {
			fmt.printf("L%02d: %s\n", r, line)
		}
	}

	rnd.BeginFrame()
	rnd.DrawFrame()
	sw, sh := rnd.GetWindowSize()
	shot := make([]u8, int(sw) * int(sh) * 4)
	defer delete(shot)
	gl.ReadPixels(0, 0, i32(sw), i32(sh), gl.RGBA, gl.UNSIGNED_BYTE, &shot[0])
	rnd.EndFrame()
	write_bmp("C:\\Users\\GroupTheory\\Source\\dterm\\kitty_shot.bmp", shot, int(sw), int(sh))
	fmt.printf("wrote kitty_shot.bmp %dx%d\n", sw, sh)

	ct.DestroyConpty(ctx)
	cv.DestroyConsole(ch)
}
