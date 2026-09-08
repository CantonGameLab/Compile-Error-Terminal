// ConPTY 传输效率基准:测「子进程 stdout → ConPTY 管道 → 终端读取」的端到端
// 吞吐与完整性,回答「图像协议(kitty APC / base64 分块 / 大块 OSC)能否经
// ConPTY 传输」。
//
// 设计要点:不依赖 src/conpty(其 ReadWriteData 字段包私有,且 ring 逐字节
// 复制会污染测量),这里自建最小 ConPTY 绑定,直接 ReadFile 读管道 ——
// 量到的是 ConPTY 本身的传输能力。
//
// 两条子进程 std 路径对照:
//   --direct  dterm 现状:std 直连 ConPTY 管道(数据不经 conhost VT 解析)
//   默认      WT 路径:由 pseudoconsole 属性建控制台,输出经 conhost 解析转发
//
// 用法:
//   odin run playground/conptybench/ -- [--mode raw|text|apc|osc] [--mb N]
//        [--chunk KB] [--read KB] [--direct]
//   内部以 --writer 角色自启动(同一 exe),writer 结束时把发送字节数写到
//   playground/conptybench/sent.txt 供校验。
package main

import win "core:sys/windows"
import "core:bytes"
import "core:image/png"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

// ---------------------------------------------------------------------------
// 最小 ConPTY 绑定(仅本次测量需要的部分)
// ---------------------------------------------------------------------------
HPCON :: rawptr
PROC_THREAD_ATTRIBUTE_LIST :: rawptr
LPPROC_THREAD_ATTRIBUTE_LIST :: ^PROC_THREAD_ATTRIBUTE_LIST
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

STARTUPINFOEXW :: struct {
	StartupInfo : win.STARTUPINFOW,
	lpAttributeList : LPPROC_THREAD_ATTRIBUTE_LIST,
}

foreign import kernel32 "system:kernel32.lib"

foreign kernel32 {
	CreatePseudoConsole :: proc(size: win.COORD, hInput: win.HANDLE, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^HPCON) -> win.HRESULT ---
	ClosePseudoConsole :: proc(hPC: HPCON) ---
	InitializeProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwAttributeCount: win.DWORD, dwFlags: win.DWORD, lpSize: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwFlags: win.DWORD, Attribute: win.DWORD_PTR, lpValue: rawptr, cbSize: win.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST) ---
}

SENT_FILE :: "playground/conptybench/sent.txt"
DIAG_FILE :: "playground/conptybench/diag.txt"
PNG_FILE :: "playground/conptybench/test.png"

atoi :: proc(s : string) -> int {
	v, _ := strconv.parse_int(s)
	return int(v)
}

// ---------------------------------------------------------------------------
// 结束标记扫描(跨块状态;OSC 9999;SENT=<n> BEL)
// ---------------------------------------------------------------------------
END_PREFIX :: "\x1b]9999;SENT="
end_match : int
end_digits : bool
end_num : u64

scanEndMarker :: proc(buf : []byte, out_sent : ^u64) -> (u64, bool) {
	prefix := END_PREFIX
	for b in buf {
		if end_digits {
			if b >= '0' && b <= '9' {
				end_num = end_num * 10 + u64(b - '0')
				continue
			}
			if b == 0x07 {
				out_sent^ = end_num
				return end_num, true
			}
			end_digits = false
			end_match = 0
			end_num = 0
			continue
		}
		if b == prefix[end_match] {
			end_match += 1
			if end_match == len(prefix) {
				end_digits = true
				end_num = 0
			}
		} else {
			end_match = b == prefix[0] ? 1 : 0
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// writer 角色:往 stdout(ConPTY 的写端)灌数据
// ---------------------------------------------------------------------------
writerMain :: proc(mode : string, total_bytes : u64, chunk : int) {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	_ = os.write_entire_file(DIAG_FILE, fmt.tprintf("start h=%v total=%d chunk=%d", uintptr(h), total_bytes, chunk))
	buf := make([]byte, chunk)
	defer delete(buf)
	for i in 0 ..< len(buf) {
		buf[i] = u8('A' + i % 26)
	}

	sent : u64
	written : win.DWORD
	for sent < total_bytes {
		n := int(min(u64(len(buf)), total_bytes - sent))
		fillWriterBuf(buf[:n], mode)
		if !win.WriteFile(h, raw_data(buf), u32(n), &written, nil) {
			break
		}
		sent += u64(written)
	}
	// 结束标记:reader 靠它收尾(不能依赖管道 EOF —— conhost 持有写端副本)
	marker := fmt.tprintf("\x1b]9999;SENT={}\x07", sent)
	mok := win.WriteFile(h, raw_data(marker), u32(len(marker)), &written, nil)
	_ = os.write_entire_file(SENT_FILE, fmt.tprintf("%d", sent))
	_ = os.write_entire_file(DIAG_FILE, fmt.tprintf("end h=%v sent=%d err=%v marker_ok=%v", uintptr(h), sent, win.GetLastError(), mok))
}

// 按模式就地改写块(buf 预填为可打印 ASCII)
fillWriterBuf :: proc(buf : []byte, mode : string) {
	switch mode {
	case "raw":
		// 纯可打印 ASCII,无换行(测 conhost 自动换行/滚动路径)
	case "text":
		// 每 100 字节一行 CRLF(测常规文本 + 滚动)
		for i := 99; i < len(buf); i += 100 {
			buf[i] = '\r'
			if i + 1 < len(buf) { buf[i + 1] = '\n' }
		}
	case "apc":
		// kitty graphics 分块形态:ESC_G q=2,i=1,m=1;<base64> ESC\
		n := 0
		n += copy(buf[n:], "\x1b_Gq=2,i=1,m=1;")
		for n < len(buf) - 2 {
			buf[n] = 'A'
			n += 1
		}
		_ = copy(buf[n:], "\x1b\\")
	case "osc":
		// 大块 OSC(iTerm2 内联图像形态):ESC]1337;File=inline=1:<base64> BEL
		n := 0
		n += copy(buf[n:], "\x1b]1337;File=inline=1:")
		for n < len(buf) - 1 {
			buf[n] = 'A'
			n += 1
		}
		_ = copy(buf[n:], "\x07")
	}
}

// ---------------------------------------------------------------------------
// reader 角色
// ---------------------------------------------------------------------------
main :: proc() {
	args := os.args
	if len(args) >= 2 && args[1] == "--dec" {
		decBench()
		return
	}
	if len(args) >= 5 && args[1] == "--writer" {
		writerMain(args[2], u64(atoi(args[3])) << 20, atoi(args[4]) << 10)
		return
	}

	mode := "apc"
	mb := 16
	chunk_kb := 64
	read_kb := 64
	direct := false
	custom_cmd := ""
	i := 1
	for i < len(args) {
		switch args[i] {
		case "--mode":
			i += 1
			if i < len(args) { mode = args[i] }
		case "--mb":
			i += 1
			if i < len(args) { mb = atoi(args[i]) }
		case "--chunk":
			i += 1
			if i < len(args) { chunk_kb = atoi(args[i]) }
		case "--read":
			i += 1
			if i < len(args) { read_kb = atoi(args[i]) }
		case "--cmd":
			i += 1
			if i < len(args) { custom_cmd = args[i] }
		case "--direct":
			direct = true
		}
		i += 1
	}

	exe := args[0]
	cmd := custom_cmd
	if len(cmd) == 0 {
		cmd = fmt.tprintf("\"%s\" --writer %s %d %d", exe, mode, mb, chunk_kb)
	}
	fmt.printf("mode=%s total=%dMB chunk=%dKB read=%dKB path=%s\n",
		mode, mb, chunk_kb, read_kb, direct ? "direct" : "conhost")
	fmt.printf("cmd=%s\n", cmd)

	hpc, hread, pi, ok := spawnPty(cmd, {120, 40}, direct)
	if !ok {
		fmt.eprintln("spawn failed")
		return
	}
	defer ClosePseudoConsole(hpc)
	defer win.CloseHandle(hread)
	defer win.CloseHandle(pi.hThread)
	defer win.CloseHandle(pi.hProcess)

	buf := make([]byte, read_kb << 10)
	defer delete(buf)

	recv : u64
	esc_count : u64
	apc_count : u64
	bel_count : u64
	end_seen := false
	end_sent : u64

	// 收尾判定:结束标记优先,其次「连续 3s 无新数据」(conhost 持有写端副本,
	// 不能依赖管道 EOF)。Peek 只在无数据时空转,忙时直读,不影响吞吐测量。
	start := time.now()
	last_data := start
	read : win.DWORD
	for {
		avail : win.DWORD
		if !win.PeekNamedPipe(hread, nil, 0, nil, &avail, nil) {
			break
		}
		if avail == 0 {
			if end_seen || time.since(last_data) > 1500 * time.Millisecond {
				break
			}
			time.sleep(time.Millisecond)
			continue
		}
		last_data = time.now()
		if !win.ReadFile(hread, raw_data(buf), u32(len(buf)), &read, nil) || read == 0 {
			break
		}
		n := int(read)
		recv += u64(n)
		if recv <= 2048 {
			// 诊断:首个数据块内容(转义可视化)
			hex := "0123456789abcdef"
			sb : [256]u8
			k := 0
			for j in 0 ..< n {
				b := buf[j]
				if b == 0x1b && k < len(sb) - 5 {
					copy(sb[k:], "<E>"); k += 3
				} else if b == 0x07 && k < len(sb) - 5 {
					copy(sb[k:], "<B>"); k += 3
				} else if b >= 0x20 && b < 0x7f && k < len(sb) - 1 {
					sb[k] = b; k += 1
				} else if k < len(sb) - 6 {
					sb[k] = '<'; sb[k+1] = 'h'; sb[k+2] = 'x'
					sb[k+3] = hex[b >> 4]
					sb[k+4] = hex[b & 0xf]
					sb[k+5] = '>'
					k += 6
				}
			}
			fmt.printf("first_chunk: %s\n", string(sb[:k]))
		}
		for j in 0 ..< n {
			b := buf[j]
			if b == 0x1b {
				esc_count += 1
				if j + 1 < n && buf[j + 1] == '_' {
					apc_count += 1
				}
			} else if b == 0x07 {
				bel_count += 1
			}
		}
		if !end_seen {
			if _, ok2 := scanEndMarker(buf[:n], &end_sent); ok2 {
				end_seen = true
			}
		}
	}
	wall := time.since(start)

	sent : u64
	if data, err := os.read_entire_file_from_path(SENT_FILE, context.allocator); err == nil {
		sent = u64(atoi(string(data)))
	}
	if data, err := os.read_entire_file_from_path(DIAG_FILE, context.allocator); err == nil {
		fmt.printf("writer_diag: %s\n", string(data))
	} else {
		fmt.printf("writer_diag: <none>\n")
	}

	secs := f64(wall) / 1e9
	mb_recv := f64(recv) / 1e6
	delta := i64(recv) - i64(sent)
	code : win.DWORD
	win.GetExitCodeProcess(pi.hProcess, &code)
	fmt.printf("child_pid=%d exit_code=%d\n", pi.dwProcessId, code)
	fmt.printf("sent=%d recv=%d delta=%+d (%.3f%%)\n", sent, recv, delta,
		f64(delta) / max(f64(sent), 1) * 100)
	fmt.printf("esc=%d apc_blocks=%d bel=%d\n", esc_count, apc_count, bel_count)
	fmt.printf("wall=%.3fs  recv_rate=%.1f MB/s  (含进程启动开销)\n", secs, mb_recv / max(secs, 1e-9))
}

// ---------------------------------------------------------------------------
// 解码侧 CPU 基准:dterm 收图后必须付的成本(base64 解码 / zlib inflate)
// ---------------------------------------------------------------------------
decBench :: proc() {
	// 伪随机可压缩数据(RGBA 图像近似:大片平滑 + 少量噪声)
	N :: 8 << 20
	raw := make([]byte, N)
	defer delete(raw)
	x : u32 = 12345
	for i in 0 ..< N {
		x = x * 1664525 + 1013904223
		raw[i] = u8((x >> 24) & 0x3f) // 低熵:压缩率接近图像
	}

	// base64 编解码
	enc := base64.encode(raw)
	defer delete(enc)
	best_dec : time.Duration = 100 * time.Second
	for _ in 0 ..< 3 {
		t := time.now()
		dec, err := base64.decode(enc)
		d := time.since(t)
		if err == nil {
			delete(dec)
		}
		if d < best_dec { best_dec = d }
	}

	// PNG 解码(f=100 真实路径:inflate + 逐行 filter 重建)
	px_w, px_h : int
	best_png : time.Duration = 100 * time.Second
	if data, err := os.read_entire_file_from_path(PNG_FILE, context.allocator); err == nil {
		for _ in 0 ..< 3 {
			t := time.now()
			img, perr := png.load_from_bytes(data, {.alpha_add_if_missing})
			d := time.since(t)
			if perr == nil && img != nil {
				px_w, px_h = img.width, img.height
				png.destroy(img)
			}
			if d < best_png { best_png = d }
		}
		mb := f64(len(data)) / 1e6
		px := f64(px_w) * f64(px_h) / 1e6
		fmt.printf("png file      : %0.2fMB  %dx%d  ->  %v  %0.0f MP/s  %0.1f MB/s(文件)\n",
			mb, px_w, px_h, best_png, px / (f64(best_png) / 1e9), mb / (f64(best_png) / 1e9))
	}

	mb := f64(N) / 1e6
	mb_b64 := f64(len(enc)) / 1e6
	fmt.printf("raw=%0.1fMB base64=%0.1fMB(+%.0f%%)\n", mb, mb_b64, (mb_b64 / mb - 1) * 100)
	fmt.printf("base64 decode : %v  %0.1f MB/s(raw)  %0.1f MB/s(编码后)\n",
		best_dec, mb / (f64(best_dec) / 1e9), mb_b64 / (f64(best_dec) / 1e9))
}

spawnPty :: proc(cmd : string, size : win.COORD, direct : bool) -> (hpc : HPCON, hread : win.HANDLE, pi : win.PROCESS_INFORMATION, ok : bool) {
	// 句柄必须可继承,否则 direct 模式下子进程 std 句柄无效
	sa := win.SECURITY_ATTRIBUTES {
		nLength = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	pty_read, main_write : win.HANDLE
	main_read, pty_write : win.HANDLE
	if !win.CreatePipe(&pty_read, &main_write, &sa, 0) {
		return
	}
	if !win.CreatePipe(&main_read, &pty_write, &sa, 0) {
		win.CloseHandle(main_write)
		return
	}
	// 微软示例:ConPTY 端句柄保留到 ClosePseudoConsole(此处不关闭)
	hr := CreatePseudoConsole(size, pty_read, pty_write, 0, &hpc)
	if hr != win.HRESULT(0) {
		win.CloseHandle(main_write)
		win.CloseHandle(main_read)
		return
	}
	hread = main_read

	si : STARTUPINFOEXW
	si.StartupInfo.cb = size_of(si)
	attr_size : win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	heap := win.GetProcessHeap()
	si.lpAttributeList = cast(LPPROC_THREAD_ATTRIBUTE_LIST) win.HeapAlloc(heap, 0, attr_size)
	if si.lpAttributeList == nil {
		return
	}
	defer win.HeapFree(heap, 0, si.lpAttributeList)
	if !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size) {
		return
	}
	defer DeleteProcThreadAttributeList(si.lpAttributeList)
	if !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, cast(rawptr) hpc, size_of(HPCON), nil, nil) {
		return
	}

	inherit := win.BOOL(false)
	if direct {
		si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
		si.StartupInfo.hStdInput = pty_read
		si.StartupInfo.hStdOutput = pty_write
		si.StartupInfo.hStdError = pty_write
		inherit = true
	} else {
		// WT 做法:声明使用 std 句柄但全留 NULL → conhost 为子进程重建控制台
		si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	}

	if !win.CreateProcessW(nil, win.utf8_to_wstring(cmd), nil, nil, inherit, win.EXTENDED_STARTUPINFO_PRESENT, nil, nil, &si.StartupInfo, &pi) {
		return
	}
	win.CloseHandle(main_write)
	ok = true
	return
}
