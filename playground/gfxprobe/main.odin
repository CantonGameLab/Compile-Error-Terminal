// 图形协议 v1.1 回归:控制块解析 / 传输(含 U=1 虚拟放置)/ 占位符换算 /
// 声调表 / colorToId / 应答构造与抑制 / 删除清屏 / 下标维护(驱逐平移)。
// 纯逻辑:工具 console(conpty=0)+ 空窗口,无 GL。
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
	// ── 控制块解析
	cmd, ok := cv.GfxCommandParse("f=32,s=10,v=20,a=T")
	check("parse a=T f=32", ok && cmd.action == 'T' && cmd.format == 32 && cmd.data_width == 10 && cmd.data_height == 20, true)
	cmd, ok = cv.GfxCommandParse("o=z,m=1,i=7")
	check("parse o=z m=1", ok && cmd.compressed && cmd.more && cmd.id == 7, true)
	cmd, ok = cv.GfxCommandParse("a=p,p=5,c=3,r=1,z=-2,C=1")
	check("parse put keys", ok && cmd.placement_id == 5 && cmd.num_cells == 3 && cmd.num_rows == 1 && cmd.z_index == -2 && cmd.cursor_move, true)
	cmd, ok = cv.GfxCommandParse("a=T,U=1,f=32,s=2,v=2")
	check("parse U=1", ok && cmd.unicode_placement, true)
	_, ok = cv.GfxCommandParse("t=f")
	check("t=f rejected v1", !ok, true)
	_, ok = cv.GfxCommandParse("f=7")
	check("bad format rejected", !ok, true)
	_, ok = cv.GfxCommandParse("bogus")
	check("no = rejected", !ok, true)
	cmd, ok = cv.GfxCommandParse("z=-5,a=q")
	check("neg int", ok && cmd.z_index == -5, true)

	// ── 声调表(kitty 序)
	check("diacritic 0x0305 = 0", cv.GfxDiacriticIdx(0x0305), 0)
	check("diacritic 0x036f = 29", cv.GfxDiacriticIdx(0x036F), 29)
	check("diacritic 0x1d244 = 296", cv.GfxDiacriticIdx(0x1D244), 296)
	check("non-diacritic = -1", cv.GfxDiacriticIdx('x'), -1)

	// ── colorToId
	check("colorToId rgb", cv.GfxColorToId(0x00ABCDEF), 0xABCDEF)
	check("colorToId index", cv.GfxColorToId(0x0100002A), 42)

	// ── 工具 console(无会话)
	ch, cok := cv.CreateConsole(24, 80, {})
	check("tool console", cok, true)
	console := cv.GetConsole(ch)

	// ── 传输 + 即时放置(匿名图,2x2 RGBA)
	payload := [16]u8{
		255, 0, 0, 255, 0, 255, 0, 255,
		0, 0, 255, 255, 255, 255, 0, 128,
	}
	cmd, _ = cv.GfxCommandParse("a=T,f=32,s=2,v=2")
	cv.GfxHandle(ch, cmd, payload[:])
	check("image stored", len(console.images) == 1, true)
	check("placement created", len(console.placements) == 1, true)
	check("dims 2x2", console.images[0].width == 2 && console.images[0].height == 2, true)
	check("version 1", console.images[0].data_version == 1, true)
	check("uid assigned", console.images[0].uid != 0, true)
	check("placement anchor 0,0", console.placements[0].line == 0 && console.placements[0].col == 0, true)
	check("placement not virtual", console.placements[0].virtual == false, true)

	// ── 放置矩形:1:1 像素(锚 0,0;格 10x20)
	x, y, w, h, rok := cv.GfxPlacementRect(&console.placements[0], &console.images[0], 10, 20, 0, console)
	check("rect ok", rok, true)
	check("rect 1:1 2x2", w == 2 && h == 2, true)
	check("rect origin", x == console.origin_x && y == console.origin_y, true)

	// ── 同 (image, p=7) 覆盖更新
	cmd, _ = cv.GfxCommandParse("a=p,p=7,z=-1")
	cv.GfxHandle(ch, cmd, nil)
	check("put p=7 creates", len(console.placements) == 2, true)
	cmd, _ = cv.GfxCommandParse("a=p,p=7,z=-3")
	cv.GfxHandle(ch, cmd, nil)
	check("put p=7 replaces", len(console.placements) == 2, true)
	found := -1
	for i in 0 ..< len(console.placements) {
		if console.placements[i].placement_id == 7 {
			found = i
		}
	}
	check("z updated to -3", found >= 0 && console.placements[found].z_index == -3, true)

	// ── U=1 虚拟放置(另一匿名图——匿名槽替换语义 → 需命名 id 才能并存)
	cmd, _ = cv.GfxCommandParse("a=T,U=1,f=32,s=2,v=2,i=9,q=2,c=2,r=2")
	cv.GfxHandle(ch, cmd, payload[:])
	check("virtual image stored", len(console.images) == 2, true)
	virt_idx := -1
	for i in 0 ..< len(console.placements) {
		if console.placements[i].virtual {
			virt_idx = i
		}
	}
	check("virtual placement exists", virt_idx >= 0, true)

	// ── 占位符换算:虚拟盒 c=2,r=2(盒 20x40);图 2x2 fit → 按宽:
	//   x_scale = 20/2 = 10,盒高留白 y_off = (40 - 2*10)/2 = 10;
	//   跑 (0,0) 跨 2x1 → 整个源宽:off 0,10;20x10;uv 全图
	if virt_idx >= 0 && len(console.images) == 2 {
		img := &console.images[1]
		virt := &console.placements[virt_idx]
		ox, oy, dw2, dh2, u0, v0, u1, v1, sok := cv.GfxCellImageSrc(img, virt^, 10, 20, 0, 0, 2, 1)
		check("cellsrc ok", sok, true)
		check("cellsrc scale 10x", dw2 == 20 && dh2 == 10, true)
		check("cellsrc x offset 0", ox == 0, true)
		check("cellsrc y centered", oy == 10, true)
		// 上留白 10px:行 0 只覆盖图像源码 0..1(盒 20x40,fit 后 y 10..30)
		check("cellsrc v half", u0 == 0 && u1 == 1 && v0 == 0 && v1 == 0.5, true)
	}

	// ── PNG(1x1,命名号 I=5 → 分配协议 id)
	png_b64 := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
	png_bytes := b64d(png_b64)
	check("png b64 len", len(png_bytes) > 0, true)
	cmd, _ = cv.GfxCommandParse("a=t,f=100,I=5")
	cv.GfxHandle(ch, cmd, png_bytes)
	check("png stored", len(console.images) == 3, true)
	check("png dims 1x1", console.images[2].width == 1 && console.images[2].height == 1, true)
	check("png rgba 4B", len(console.images[2].rgba) == 4, true)
	check("I#5 got id", console.images[2].client_number == 5 && console.images[2].client_id != 0, true)

	// ── 应答构造与抑制
	s := cv.GfxBuildResponse(cv.GfxCommand { id = 31 }, "OK", "", 0)
	check("resp ok", s == "\x1b_Gi=31;OK\x1b\\", true)
	s = cv.GfxBuildResponse(cv.GfxCommand { id = 31, quiet = 1 }, "OK", "", 0)
	check("resp q=1 suppress", s == "", true)
	s = cv.GfxBuildResponse(cv.GfxCommand { id = 31, quiet = 2 }, "EINVAL", "bad", 0)
	check("resp q=2 suppress err", s == "", true)
	s = cv.GfxBuildResponse(cv.GfxCommand { id = 31 }, "ENOENT", "not found", 0)
	check("resp err code", s == "\x1b_Gi=31;ENOENT:not found\x1b\\", true)
	s = cv.GfxBuildResponse(cv.GfxCommand { id = 0 }, "OK", "", 0)
	check("resp unnamed empty", s == "", true)

	// ── 删除:d=I 按号删(I=5);再 d=A 全清
	cmd, _ = cv.GfxCommandParse("a=d,d=I,I=5")
	cv.GfxHandle(ch, cmd, nil)
	check("d=I removed", len(console.images) == 2, true)
	cmd, _ = cv.GfxCommandParse("a=d,d=A")
	cv.GfxHandle(ch, cmd, nil)
	check("d=A cleared all", len(console.images) == 0 && len(console.placements) == 0, true)

	cv.DestroyConsole(ch)
	fmt.println("gfxprobe done")
}

// 本地 base64(仅探针;解码 PNG 片段)
b64v :: proc(c : u8) -> int {
	switch {
	case c >= 'A' && c <= 'Z':
		return int(c - 'A')
	case c >= 'a' && c <= 'z':
		return int(c - 'a') + 26
	case c >= '0' && c <= '9':
		return int(c - '0') + 52
	case c == '+':
		return 62
	case c == '/':
		return 63
	}
	return -1
}

b64d :: proc(s : string) -> []byte {
	decoded := make([]byte, 256)
	v : u32 = 0
	bits : u32 = 0
	n := 0
	for c in s {
		if c == '=' {
			break
		}
		val := b64v(u8(c))
		if val < 0 {
			return nil
		}
		v = v << 6 | u32(val)
		bits += 6
		if bits >= 8 {
			bits -= 8
			decoded[n] = u8(v >> bits & 0xFF)
			n += 1
		}
	}
	res := make([]byte, n)
	copy(res, decoded[:n])
	return res
}
