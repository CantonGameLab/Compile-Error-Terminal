// ConPTY 字节流录制(命令 `rec`):把**进入解析器的原始字节**与尺寸变化落盘。
//
// 用途:只在别人机器上(如 Win10)出现的渲染问题,靠回放这份 dump 就能在同一解析器上定位
// 是哪条序列 —— 比"描述症状 + 猜"可靠得多。回放工具:playground/widecap/ 的 play 模式。
//
// 设计取舍:
//   - 录制点 = vtFeed(vt.odin):那就是"喂给解析器"的唯一入口,录下来的东西回放后必然复现同一画面。
//   - 只在录制开始时指定的那个 console 上录(单流,回放简单)。
//   - 尺寸变化写进 <path>.meta(偏移 + 行列),回放能看出录制期间窗口有没有变。
//   - 录制期间**不要改窗口大小**:改尺寸会重排整屏,单流回放无法完整复原(meta 里会留痕)。
package canvas

import mem "../memory"
import "core:fmt"
import "core:os"

record_console : mem.Handle // 0 = 未录制
record_file : ^os.File
record_meta : ^os.File
record_path : string // 堆分配,StopRecord 时释放
record_rows, record_cols : u16
record_bytes : int

// 开始录制(已有录制先停)。path 相对工作目录;同时创建 <path>.meta。
RecordStart :: proc(console_h : mem.Handle, path : string) -> bool {
	if console_h.id == 0 || len(path) == 0 {
		return false
	}
	RecordStop()
	f, ferr := os.create(path)
	if ferr != nil {
		fmt.eprintfln("[rec] 打不开 %s: %v", path, ferr)
		return false
	}
	m, merr := os.create(fmt.tprintf("%s.meta", path))
	if merr != nil {
		os.close(f)
		fmt.eprintfln("[rec] 打不开 %s.meta: %v", path, merr)
		return false
	}
	record_console = console_h
	record_file = f
	record_meta = m
	record_path = fmt.aprintf("%s", path)
	record_rows, record_cols = 0, 0
	record_bytes = 0
	// 首行尺寸只能从调用方拿(就在这次 UpdateConsole 之前由布局趟定稿)
	if c := GetConsole(console_h); c != nil {
		RecordSize(console_h, c.cols, c.rows)
	}
	fmt.eprintfln("[rec] 开始录制 → %s(这个窗格)", path)
	return true
}

RecordStop :: proc() {
	if record_file == nil && record_meta == nil && len(record_path) == 0 {
		return
	}
	if record_file != nil {
		os.close(record_file)
	}
	if record_meta != nil {
		os.close(record_meta)
	}
	if len(record_path) > 0 {
		fmt.eprintfln("[rec] 停止录制:%s(%d 字节)", record_path, record_bytes)
		delete(record_path)
	}
	record_file, record_meta, record_console = nil, nil, {}
	record_path = ""
	record_bytes = 0
}

RecordActive :: proc() -> bool {
	return record_file != nil
}

RecordPath :: proc() -> string {
	return record_path
}

// 喂给解析器的字节(vtFeed 调用)。录的字节数 = 回放要吃的字节数。
RecordFeed :: proc(console_h : mem.Handle, data : []byte) {
	if record_file == nil || console_h != record_console || len(data) == 0 {
		return
	}
	if _, werr := os.write(record_file, data); werr != nil {
		fmt.eprintfln("[rec] 写失败(%v),停止录制", werr)
		RecordStop()
		return
	}
	record_bytes += len(data)
}

// 尺寸变化(vt 网格尺寸;tree.odin 应用成功后调用)
RecordSize :: proc(console_h : mem.Handle, cols, rows : u16) {
	if record_meta == nil || console_h != record_console {
		return
	}
	if cols == record_cols && rows == record_rows {
		return
	}
	record_cols, record_rows = cols, rows
	line := fmt.tprintf("%d\t%dx%d\n", record_bytes, cols, rows)
	os.write(record_meta, transmute([]u8)line)
}
