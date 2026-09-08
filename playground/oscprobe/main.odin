// ConPTY 信道实测(独立探针,仅依赖 conpty,不 import canvas):
//   1) OSC 序列长度上限:子进程发 4K/16K/64K/256K base64 负载,看 conhost 转发多少
//   2) 纯文本吞吐:子进程输出 N MB,测到达耗时
// 用法:odin run playground/oscprobe/
package main

import ct "../../src/conpty"
import mem "../../src/memory"
import "core:fmt"
import "core:os"
import "core:time"

drain_to :: proc(h : mem.Handle, path : string) -> int {
	rw := ct.GetReadWriteData(h)
	if rw == nil {
		return 0
	}
	total := 0
	buf : [65536]u8
	for {
		n := ct.RingPop(rw, buf[:])
		if n <= 0 {
			break
		}
		fh, _ := os.open(path, os.O_APPEND | os.O_CREATE | os.O_WRONLY)
		if fh != nil {
			os.write(fh, buf[:n])
			os.close(fh)
		}
		total += n
	}
	return total
}

run_child :: proc(script : string, capture : string, secs : f64) -> int {
	cmdline := fmt.tprintf(`python "C:\Users\GroupTheory\Source\dterm\playground\oscprobe\%s"`, script)
	ctx, ok := ct.CreateConptyContext({120, 40}, cmdline)
	if !ok {
		fmt.eprintln("conpty failed")
		return 0
	}
	_ = ct.StartReadThread(ctx)
	start := time.now()
	total := 0
	for time.duration_seconds(time.since(start)) < secs {
		total += drain_to(ctx, capture)
		time.sleep(20 * time.Millisecond)
	}
	total += drain_to(ctx, capture)
	ct.DestroyConpty(ctx)
	return total
}

main :: proc() {
	_ = os.remove("osc_cap.bin")
	_ = os.remove("bulk_cap.bin")

	fmt.println("== 1. OSC 长度上限(4K/16K/64K/256K base64,标记 MARK<kb>) ==")
	n1 := run_child("osc_length.py", "osc_cap.bin", 4.0)
	fmt.printf("captured %d bytes -> osc_cap.bin\n", n1)
	data, err := os.read_entire_file("osc_cap.bin", context.allocator)
	if err == nil {
		defer delete(data)
		// 每个 MARK<n> 前的 OSC 负载是否完整:数 ESC ] 与 BEL 的配对 + 标记位置
		esc := 0
		bel := 0
		for b in data {
			if b == 0x1B {
				esc += 1
			}
			if b == 0x07 {
				bel += 1
			}
		}
		fmt.printf("captured: %d bytes, ESC=%d, BEL=%d\n", len(data), esc, bel)
		markers := []string{"MARK4", "MARK16", "MARK64", "MARK256"}
		for m in markers {
			idx := indexOf(data, transmute([]u8)m)
			fmt.printf("  %-8s @ %d\n", m, idx)
		}
		// 每段 OSC 实际长度 = 下一个标记 - 上一个 BEL
		for i in 0 ..< len(markers) {
			mi := indexOf(data, transmute([]u8)markers[i])
			if mi < 0 {
				fmt.printf("  %s missing\n", markers[i])
				continue
			}
			// 往前找最近的 BEL,再往前找 ESC ]
			b := mi
			for b > 0 && data[b - 1] != 0x07 {
				b -= 1
			}
			s := b
			for s > 0 && !(data[s - 1] == 0x1B) {
				s -= 1
			}
			fmt.printf("  %-8s OSC payload arrived=%d bytes\n", markers[i], b - s)
		}
	}

	fmt.println("== 2a-matrix. OSC 512K/1M ==")
	{
		n := run_child("osc_matrix.py", "osc_mx.bin", 5.0)
		fmt.printf("captured %d bytes\n", n)
		d, e := os.read_entire_file("osc_mx.bin", context.allocator)
		if e == nil {
			defer delete(d)
			for m in ([]string{"OSC512-DONE", "OSC1024-DONE"}) {
				fmt.printf("  %-12s @ %d\n", m, indexOf(d, transmute([]u8)m))
			}
		}
	}
	fmt.println("== 2b-matrix. 文本 64K/256K/1M ==")
	{
		n := run_child("text_matrix.py", "text_mx.bin", 5.0)
		fmt.printf("captured %d bytes\n", n)
		d, e := os.read_entire_file("text_mx.bin", context.allocator)
		if e == nil {
			defer delete(d)
			for m in ([]string{"TEXT64-DONE", "TEXT256-DONE", "TEXT1024-DONE"}) {
				fmt.printf("  %-14s @ %d\n", m, indexOf(d, transmute([]u8)m))
			}
		}
	}
	{ 
		start := time.now()
		n2 := run_child("osc_big.py", "big_osc.bin", 6.0)
		el := time.duration_seconds(time.since(start))
		fmt.printf("captured %d bytes in %.2fs (含 6s 窗口)\n", n2, el)
	}
	fmt.println("== 2b. 2MB 纯文本定时 ==")
	{
		start := time.now()
		n3 := run_child("text_big.py", "big_text.bin", 6.0)
		el := time.duration_seconds(time.since(start))
		fmt.printf("captured %d bytes in %.2fs (含 6s 窗口)\n", n3, el)
	}
}

indexOf :: proc(hay : []u8, needle : []u8) -> int {
	if len(needle) == 0 || len(hay) < len(needle) {
		return -1
	}
	for i in 0 ..= len(hay) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}
