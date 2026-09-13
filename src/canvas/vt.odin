// VT 语义层:VtState(字节序列的终端状态)+ 序列分派(ESC/CSI/SGR/DEC 模式)
// 与应答(DSR/DA/DECRQM 写回 ConPTY)。操作 Console/TermBuffer 一律经句柄接口。
package canvas

import ct "../conpty"
import inp "../input"
import mem "../memory"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"

// VT 语义层:VtState(模式位与外观)+ 指令分派(ESC/CSI/SGR/DEC 模式/OSC/应答)。
// 每帧 UpdateConsole(id) 拉取 ConPTY 输出喂给 Parse;VtState 与 Parser 并列在 Console 下。
VtState :: struct {
	style : CellStyle,
	saved_cursor_row, saved_cursor_col : u16,
	saved_scroll_top, saved_scroll_bottom : u16, // 交替屏进出时保存/恢复滚动区
	scroll_top, scroll_bottom : u16,
	autowrap : bool,
	wrap_pending : bool, // 写满最后一列:停在该列,下一字符才折行(xterm 语义)
	origin_mode : bool,  // DECOM(?6):光标定位相对滚动区,且限制在滚动区内
	deccolm : bool,      // DECCOLM(?3):132 列模式
	cursor_visible : bool,
	cursor_style : u8,     // DECSCUSR:0=默认 1=闪烁块 2=稳态块 3=闪烁下划线 4=稳态下划线 5=闪烁竖线 6=稳态竖线
	alt_term_buffer_id : mem.Handle, // 0 = 未创建
	mouse_mode : u8,       // 0=关 1=1000 2=1002 3=1003
	sgr_mouse : bool,      // 1006
	focus_events : bool,   // 1004
	bracketed_paste : bool, // 2004
	modify_other_keys : u8, // 0/1/2
}

update_scratch : [64 * 1024]byte // 主循环单线程,包级复用

// 调试追踪:odin build src/ -define:vt_debug=true 时打印光标移动
VT_DEBUG :: #config(vt_debug, false)

vtDbg :: proc(console_h : mem.Handle, msg : string) {
	when VT_DEBUG {
		c := GetConsole(console_h)
		tb := GetTermBuffer(c.active_term_buffer_id)
		ln := 0
		if tb != nil {
			ln = len(tb.lines)
		}
		fmt.eprintfln("VTDBG %s cur=(%d,%d) lines=%d", msg, c.cursor_row, c.cursor_col, ln)
	}
}

// DA2 应答里的终端版本号
DA2_VERSION :: 100

UpdateConsole :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	data := ct.GetReadWriteData(console.conpty_handle)
	if data == nil {
		return
	}
	n := ct.RingPop(data, update_scratch[:])
	if n <= 0 {
		return
	}
	vtFeed(console_h, update_scratch[:n])
}

vtFeed :: proc(console_h : mem.Handle, data : []byte) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	Parse(console_h, data)
}

// 动作派发:识别层交给语义层的唯一入口(唯一参数 = 会话句柄)。
// 内部动作(Clear/Collect/Param/Ignore)在 vtparse 里就消化了,到不了这里。
vtDispatch :: proc(console_h : mem.Handle, action : Action, ch : rune) {
	#partial switch action {
	case .Print:
		vtPrint(console_h, ch)
	case .Execute:
		vtHandleC0(console_h, u8(ch))
	case .EscDispatch:
		vtEscDispatch(console_h, u8(ch))
	case .CsiDispatch:
		vtCsiDispatch(console_h, u8(ch))
	case .OscStart:
		osc_len = 0
		osc_bad = false
	case .OscPut:
		oscDataAppend(ch)
	case .OscEnd:
		if osc_bad {
			osc_bad = false // 超长段整段作废(osc_len 由下次 OscStart 重置)
		} else {
			oscDispatch(console_h)
		}
	case .Hook, .Put, .Unhook:
		// DCS 暂不处理
	}
}

// ---------------------------------------------------------------------------
// OSC(字符串收集 → 语义):0/1/2 标题、7 当前目录、52 剪贴板;其余忽略。
// 包级缓冲(主循环单线程);超长 = 整段丢弃(绝不执行被截断的序列)。
// 应用侧状态落 Console.app_title / Console.cwd(console.odin);应答经 oscReply 写回。
// ---------------------------------------------------------------------------
OSC_BUFFER :: 4096

APP_TITLE_MAX :: 128 // 应用标题上限(展示用;避免 clone 长串)
CWD_MAX :: 512       // 工作目录上限

osc_data : [OSC_BUFFER]u8
osc_len : int
osc_bad : bool // 本段超长:dispatch 时整段丢弃
base64_scratch : [OSC_BUFFER]u8

oscDataAppend :: proc(cp : rune) {
	if osc_bad {
		return
	}
	if osc_len + 4 > OSC_BUFFER {
		osc_bad = true // 截断后照常执行 = 执行了另一条序列,故整段作废
		return
	}
	osc_len += runeToUtf8(cp, osc_data[osc_len:])
}

// rune → UTF-8 字节(OscPut 是解码后的 rune,重编码回缓冲)
runeToUtf8 :: proc(cp : rune, buf : []u8) -> int {
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

// OSC 调试:odin build src/ -define:osc_debug=true 时打印每个收到的 OSC 原文
// (诊断"序列到没到 parser";默认关闭,编译期消除)
OSC_DEBUG :: #config(osc_debug, false)

oscDispatch :: proc(console_h : mem.Handle) {
	s := osc_data[:osc_len]
	if len(s) == 0 {
		return
	}
	when OSC_DEBUG {
		p := s
		if len(p) > 120 {
			p = p[:120]
		}
		line := fmt.tprintf("OSCDBG len=%d raw=[%s]\n", len(s), string(p))
		fmt.eprint(line)
		// 同时落文件:双击启动(无 stderr)时也能查
		if fh, ferr := os.open("osc_debug.log", os.O_APPEND | os.O_CREATE | os.O_WRONLY); ferr == nil {
			_, _ = os.write_string(fh, line)
			os.close(fh)
		}
	}
	num, payload, ok := oscParseHead(s)
	if !ok {
		return // 无类型号/无内容
	}
	switch num {
	case 0, 2: // 标题(0 = 图标名 + 标题,2 = 窗口标题):应用标题
		oscSetAppTitle(console_h, payload)
	case 1: // 图标名:无图标概念,忽略
	case 7: // 当前工作目录:file://[host]/path → 记在本会话名下
		oscSetCwd(console_h, payload)
	case 52: // 剪贴板:52;[c|p|s0..s7];<base64 | ?>
		oscClipboard(console_h, payload)
	}
}

// 头部:十进制号 + ';'(无号/无分号 = 非法,忽略)
oscParseHead :: proc(s : []byte) -> (num : int, payload : []byte, ok : bool) {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		num = num * 10 + int(s[n] - '0')
		n += 1
	}
	if n == 0 || n >= len(s) || s[n] != ';' {
		return 0, nil, false
	}
	return num, s[n + 1:], true
}

// OSC 0/2:应用标题(clone 进 console;空串 = 清除)。OS 窗口标题显示它,
// tabbar 仍显示 Page.title —— 用户命名与应用命名互不覆盖。
oscSetAppTitle :: proc(console_h : mem.Handle, text : []byte) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	if console.app_title != "" {
		delete(console.app_title)
		console.app_title = ""
	}
	n := min(len(text), APP_TITLE_MAX)
	if n > 0 {
		console.app_title = strings.clone(string(text[:n]))
	}
}

// OSC 7:file://[host]/<path>。非 file:// 前缀忽略(程序乱发常见);host 段跳过;
// 百分号解码 → 记在该会话名下(shell 每个提示符都上报,写全局会被互相覆盖)。
oscSetCwd :: proc(console_h : mem.Handle, payload : []byte) {
	prefix := "file://"
	if len(payload) <= len(prefix) {
		return
	}
	for i in 0 ..< len(prefix) {
		if payload[i] != prefix[i] {
			return
		}
	}
	slash := -1 // host 段结束位置 = 路径起点
	for i := len(prefix); i < len(payload); i += 1 {
		if payload[i] == '/' {
			slash = i
			break
		}
	}
	if slash < 0 {
		return
	}
	buf : [CWD_MAX]u8
	n := percentDecode(payload[slash:], buf[:])
	if n == 0 {
		return
	}
	SetConsoleCwd(console_h, string(buf[:n]))
}

// 工作目录形态归一(消费端 = CreateProcess 的 lpCurrentDirectory):
// file:// URL 的路径段前导 '/' 去掉(/C:/x → C:\x);msys2 的 /c/Users/x → C:\Users\x;
// 已带盘符的只统一分隔符;其余原样。
cwdNormalize :: proc(cwd : string, out : []u8) -> int {
	n, i := 0, 0
	if len(cwd) > 0 && cwd[0] == '/' {
		i = 1 // URL 路径段的前导 '/'
	}
	if i + 1 < len(cwd) && cwd[i + 1] == '/' &&
	   ((cwd[i] >= 'a' && cwd[i] <= 'z') || (cwd[i] >= 'A' && cwd[i] <= 'Z')) {
		out[0] = cwd[i] - 32 // 小写盘符 → 大写
		out[1] = ':'
		out[2] = '\\'
		n, i = 3, i + 2
	}
	for ; i < len(cwd) && n < len(out); i += 1 {
		c := cwd[i]
		if c == '/' {
			c = '\\'
		}
		out[n] = c
		n += 1
	}
	return n
}

// 百分号解码(%XX → 字节;非法序列原样保留)
percentDecode :: proc(src : []byte, dst : []byte) -> int {
	n, i := 0, 0
	for i < len(src) && n < len(dst) {
		if src[i] == '%' && i + 2 < len(src) {
			hi, lo := hexVal(src[i + 1]), hexVal(src[i + 2])
			if hi >= 0 && lo >= 0 {
				dst[n] = u8(hi << 4 | lo)
				n += 1
				i += 3
				continue
			}
		}
		dst[n] = src[i]
		n += 1
		i += 1
	}
	return n
}

hexVal :: proc(c : u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

// OSC 52:52;<selector>;<base64 | ?>。selector 缺省 = 剪贴板;Windows 无主选区,
// c/p/s0-s7 一律落系统剪贴板;'?' = 查询当前内容(应答)。
oscClipboard :: proc(console_h : mem.Handle, payload : []byte) {
	data := payload
	if p := indexByte(payload, ';'); p >= 0 {
		data = payload[p + 1:] // 选择器段丢弃(无独立存储)
	}
	if len(data) == 1 && data[0] == '?' {
		oscReplyClipboard(console_h)
		return
	}
	if text, ok := base64Decode(data); ok {
		inp.SetClipboardText(text)
	}
}

// 应答 52;c;<base64>(空剪贴板 = 空数据段;超长按 4 字节边界截断以保 base64 合法)
oscReplyClipboard :: proc(console_h : mem.Handle) {
	text := inp.GetClipboardText()
	if len(text) == 0 {
		oscReply(console_h, "52;c;")
		return
	}
	enc, err := base64.encode(transmute([]byte)text)
	if err != nil {
		return
	}
	defer delete(enc)
	max_enc := OSC_BUFFER - 32
	s := enc
	if len(s) > max_enc {
		s = s[:max_enc & ~int(3)]
	}
	oscReply(console_h, fmt.tprintf("52;c;%s", s))
}

// OSC 应答统一出口:ESC ] <msg> ESC \(与图形协议应答风格一致;BEL 仅在接收侧兼容)
oscReply :: proc(console_h : mem.Handle, msg : string) {
	console := GetConsole(console_h)
	if console == nil || console.conpty_handle.id == 0 {
		return
	}
	buf : [OSC_BUFFER]u8
	k := 0
	n := min(len(msg), OSC_BUFFER - 8)
	k += copy(buf[k:], "\x1b]")
	k += copy(buf[k:], msg[:n])
	k += copy(buf[k:], "\x1b\\")
	ct.WriteConptyInput(console.conpty_handle, buf[:k])
}

indexByte :: proc(s : []byte, b : u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == b {
			return i
		}
	}
	return -1
}

base64Decode :: proc(s : []byte) -> ([]byte, bool) {
	out_len := 0
	v : u32 = 0
	bits : u32 = 0
	for c in s {
		if c == '=' {
			break
		}
		val := b64Val(c)
		if val < 0 {
			return nil, false
		}
		v = v << 6 | u32(val)
		bits += 6
		if bits >= 8 {
			bits -= 8
			if out_len >= len(base64_scratch) {
				return nil, false
			}
			base64_scratch[out_len] = u8(v >> bits & 0xFF)
			out_len += 1
		}
	}
	return base64_scratch[:out_len], true
}

b64Val :: proc(c : u8) -> int {
	switch {
	case c >= 'A' && c <= 'Z': return int(c - 'A')
	case c >= 'a' && c <= 'z': return int(c - 'a') + 26
	case c >= '0' && c <= '9': return int(c - '0') + 52
	case c == '+': return 62
	case c == '/': return 63
	}
	return -1
}

// ESC 序列派发(无中间字节才处理;带中间字节的字符集/属性等忽略)
vtEscDispatch :: proc(console_h : mem.Handle, final : u8) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	if console.parser.num_intermediate_chars > 0 {
		return
	}
	switch final {
	case '7': // DECSC
		console.vt.saved_cursor_row, console.vt.saved_cursor_col = console.cursor_row, console.cursor_col
	case '8': // DECRC(光标恢复,取消折行等待)
		console.vt.wrap_pending = false
		console.cursor_row, console.cursor_col = console.vt.saved_cursor_row, console.vt.saved_cursor_col
	case 'D': // IND
		vtLf(console_h)
	case 'E': // NEL
		console.cursor_col = 0
		vtLf(console_h)
	case 'M': // RI
		vtReverseIndex(console_h)
	case 'c': // RIS
		vtReset(console_h)
	}
}

// ---------------------------------------------------------------------------
// C0
// ---------------------------------------------------------------------------
// 光标列落在宽字符续列(cp=0 + wide)时,再向 dir 方向挪一列;越出网格则 clamp。
// 注意:宽字符写不下最后一列会折行,故 cols-1 不会是续列;但 resize 缩窄后
// cells 可能超出 cols,此处仍要保护。
skipWideCol :: proc(console : ^Console, col : int, dir : int) -> int {
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return col
	}
	row := int(console.cursor_row)
	if row < 0 || row >= len(tb.lines) {
		return col
	}
	c := clamp(col, 0, int(console.cols) - 1)
	if c >= 0 && c < len(tb.lines[row].cells) {
		cell := tb.lines[row].cells[c]
		if cell.cp == 0 && cell.wide {
			c = clamp(c + dir, 0, int(console.cols) - 1)
		}
	}
	return c
}

vtHandleC0 :: proc(console_h : mem.Handle, b : u8) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	when VT_DEBUG {
		vtDbg(console_h, fmt.tprintf("C0 0x%02x", b))
	}
	switch b {
	case 0x07: // BEL,忽略(不取消折行等待)
	case 0x08: // BS,左移不删字符(跳过宽字符续列)
		console.vt.wrap_pending = false
		if console.cursor_col > 0 {
			console.cursor_col = u16(skipWideCol(console, int(console.cursor_col) - 1, -1))
		}
	case 0x09: // TAB,下一 8 列停靠位
		console.vt.wrap_pending = false
		col := (int(console.cursor_col) / 8 + 1) * 8
		console.cursor_col = min(u16(col), console.cols - 1)
	case 0x0A, 0x0B, 0x0C: // LF/VT/FF(不清 pending:写满后 LF 下移,下一字符仍折行)
		vtLf(console_h)
	case 0x0D: // CR
		console.vt.wrap_pending = false
		console.cursor_col = 0
	}
}

vtLf :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	when VT_DEBUG { vtDbg(console_h, "LF") }
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if int(console.cursor_row) - screenBase(console, tb) < int(console.vt.scroll_bottom) {
		console.cursor_row += 1
		return
	}
	vtScrollUp(console_h)
}

// RI:光标上移一行;在滚动区顶则向下滚动
vtReverseIndex :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := screenBase(console, tb)
	if int(console.cursor_row) - base > int(console.vt.scroll_top) {
		console.cursor_row -= 1
		return
	}
	vtScrollDown(console_h)
}

// RIS:复位终端(全量:清屏 + 样式/滚动区/光标 + 所有模态回默认,xterm 语义)
vtReset :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	// 交替屏退出(销毁交替页;进/出保存/恢复状态在 vtAltScreen 内完成)
	if vt.alt_term_buffer_id.id != 0 {
		vtAltScreen(console_h, false)
	}
	TermBufferClear(console.active_term_buffer_id)
	vt.style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR }
	vt.scroll_top, vt.scroll_bottom = 0, console.rows - 1
	vt.autowrap = true
	vt.wrap_pending = false
	vt.origin_mode = false
	vt.deccolm = false
	vt.cursor_visible = true
	vt.cursor_style = 0
	vt.mouse_mode = 0
	vt.sgr_mouse = false
	vt.focus_events = false
	vt.bracketed_paste = false
	vt.modify_other_keys = 0
	vt.saved_cursor_row, vt.saved_cursor_col = 0, 0
	vt.saved_scroll_top, vt.saved_scroll_bottom = 0, console.rows - 1
	console.cursor_row, console.cursor_col = 0, 0
}

vtPrint :: proc(console_h : mem.Handle, cp : rune) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ConsoleWriteRune(console_h, cp, console.vt.style)
}

// 行定位(0-based 屏幕行):origin mode 下相对滚动区顶并限制在区内,否则绝对
vtTargetRow :: proc(console : ^Console, p0 : int) -> int {
	if console.vt.origin_mode {
		top := int(console.vt.scroll_top)
		return top + clamp(p0 - 1, 0, int(console.vt.scroll_bottom) - top)
	}
	return clamp(p0 - 1, 0, int(console.rows) - 1)
}

// ---------------------------------------------------------------------------
// CSI
// ---------------------------------------------------------------------------
vtCsiDispatch :: proc(console_h : mem.Handle, final : u8) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	tb := GetTermBuffer(console.active_term_buffer_id)
	base := 0
	if tb != nil {
		base = screenBase(console, tb)
	}
	// 注意:wrap_pending 不能被 SGR 等 CSI 清除(xterm 语义,写满列后
	// 改颜色再写字符仍要折行;nvim 的 eob/状态栏绘制依赖此行为)。
	// 只有光标定位类操作才清除(见各 case)。
	// vtparse 的 Clear 只重置 num_params 不清数组:无参数序列必须显式取 0,
	// 否则读到上一条序列的残留参数(如 ESC[2J 后跟 ESC[H 会带 p0=2)
	p0 := 0
	if console.parser.num_params > 0 {
		p0 = console.parser.params[0]
	}
	p1 := 0
	if console.parser.num_params > 1 {
		p1 = console.parser.params[1]
	}
	// intermediate_chars 按序混合收集私用标记(0x3C-0x3F:> ? < =)与中间字节(0x20-0x2F:$ SP 等)。
	// 按值域区分:私用标记恒为首字节,中间字节从其后取(DECSCUSR 仅一个 SP 时也能命中)
	private := u8(0)
	n_priv := 0
	if console.parser.num_intermediate_chars > 0 && console.parser.intermediate_chars[0] >= 0x3C && console.parser.intermediate_chars[0] <= 0x3F {
		private = console.parser.intermediate_chars[0]
		n_priv = 1
	}
	intermediate := u8(0)
	if console.parser.num_intermediate_chars > n_priv {
		intermediate = console.parser.intermediate_chars[n_priv]
	}

	switch final {
	case 'A': // CUU(origin 下限制在滚动区顶)
		when VT_DEBUG { vtDbg(console_h, fmt.tprintf("CUU p0=%d", p0)) }
		vt.wrap_pending = false
		n := max(1, p0)
		screen_row := int(console.cursor_row) - base
		limit := 0
		if vt.origin_mode {
			limit = int(vt.scroll_top)
		}
		screen_row = max(limit, screen_row - n)
		console.cursor_row = u16(base + screen_row)
	case 'B': // CUD(origin 下限制在滚动区底)
		when VT_DEBUG { vtDbg(console_h, fmt.tprintf("CUD p0=%d", p0)) }
		vt.wrap_pending = false
		n := max(1, p0)
		screen_row := int(console.cursor_row) - base
		limit := int(console.rows) - 1
		if vt.origin_mode {
			limit = int(vt.scroll_bottom)
		}
		screen_row = min(limit, screen_row + n)
		console.cursor_row = u16(base + screen_row)
	case 'C': // CUF(右移 n 列;宽字符续列不可停,落在续列再前进)
		vt.wrap_pending = false
		n := max(1, p0)
		c := int(console.cursor_col) + n
		if c > int(console.cols) - 1 {
			c = int(console.cols) - 1
		}
		c = skipWideCol(console, c, 1)
		console.cursor_col = u16(c)
	case 'D': // CUB(左移 n 列;宽字符续列不可停,落在续列再后退)
		vt.wrap_pending = false
		n := max(1, p0)
		c := int(console.cursor_col) - n
		if c < 0 {
			c = 0
		}
		c = skipWideCol(console, c, -1)
		console.cursor_col = u16(c)
	case 'H', 'f': // CUP(1-based;origin 下相对滚动区顶)
		when VT_DEBUG { vtDbg(console_h, fmt.tprintf("CUP p0=%d p1=%d base=%d", p0, p1, base)) }
		vt.wrap_pending = false
		row := base + vtTargetRow(console, p0)
		col := clamp(p1 - 1, 0, int(console.cols) - 1)
		console.cursor_row, console.cursor_col = u16(row), u16(col)
		when VT_DEBUG { vtDbg(console_h, fmt.tprintf("CUP -> %d,%d", row, col)) }
	case 'G': // CHA
		vt.wrap_pending = false
		console.cursor_col = u16(clamp(p0 - 1, 0, int(console.cols) - 1))
	case 'J': // ED
		vtEraseInDisplay(console_h, p0)
	case 'K': // EL
		vtEraseInLine(console_h, p0)
	case 'm': // SGR;xterm 私用 '>' 是 modifyOtherKeys
		if private == '>' {
			vt.modify_other_keys = u8(p1) // CSI > 4;Nm,N=0/1/2
		} else {
			vtSgr(console_h)
		}
	case 'h', 'l': // DEC 模式
		vtSetMode(console_h, final == 'h')
	case 'r': // 滚动区;origin 置位时光标移到滚动区 home
		top := clamp(p0 - 1, 0, int(console.rows) - 1)
		bottom := int(console.rows) - 1
		if p1 > 0 {
			bottom = clamp(p1 - 1, 0, int(console.rows) - 1)
		}
		vt.scroll_top, vt.scroll_bottom = u16(min(top, bottom)), u16(max(top, bottom))
		if vt.origin_mode {
			console.cursor_row = u16(base + int(vt.scroll_top))
			console.cursor_col = 0
		}
	case 's': // 存光标
		vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
	case 'u': // 光标恢复(无私用 = 0);'?' = modifyOtherKeys CPR 应答;
		// '>'/'<' = kitty 键盘协议查询(忽略,不得当光标恢复!)
		vt.wrap_pending = false
		if private == '?' {
			vtReplyCursorDec(console_h)
		} else if private == 0 {
			console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
		}
	case 'S': // SU
		for i in 0 ..< max(1, p0) {
			vtScrollUp(console_h)
		}
	case 'T': // SD
		for i in 0 ..< max(1, p0) {
			vtScrollDown(console_h)
		}
	case 'n': // DSR;'?' 私用 = DECXCPR(应答 \e[?r;cR)
		if private == '?' {
			if p0 == 6 {
				vtReplyCursorDec(console_h)
			}
		} else if p0 == 6 {
			vtReplyCursor(console_h)
		} else if p0 == 5 {
			vtReplyOk(console_h) // 设备状态正常
		}
	case 't': // XTWINOPS:18 = 窗口尺寸查询
		if p0 == 18 {
			vtReplyWindowSize(console_h)
		}
	case 'c': // DA 设备属性
		if private == '>' {
			vtReplyDa2(console_h)
		} else {
			vtReplyDa1(console_h)
		}
	case 'p': // DECRQM 模式查询(带 $ 中间字节)
		if intermediate == '$' {
			vtReplyDecrqm(console_h, p0)
		}
	case 'q': // DECSCUSR 光标形状(带 SP 中间字节)
		if intermediate == ' ' {
			vt.cursor_style = u8(clamp(p0, 0, 6))
		}
	case 'X': // ECH 擦除 n 字符
		vtEraseChars(console_h, max(1, p0))
	case 'P': // DCH 删除 n 字符(左侧补)
		vtDeleteChars(console_h, max(1, p0))
	case '@': // ICH 插入 n 空白字符(右侧挤出)
		vtInsertChars(console_h, max(1, p0))
	case 'L': // IL 光标处插入 n 空行
		vtInsertLines(console_h, max(1, p0))
	case 'M': // DL 删除光标处 n 行
		vtDeleteLines(console_h, max(1, p0))
	case 'd': // VPA 行绝对定位(origin 下相对滚动区)
		vt.wrap_pending = false
		console.cursor_row = u16(base + vtTargetRow(console, p0))
	case '`': // HPA 列绝对定位
		vt.wrap_pending = false
		console.cursor_col = u16(clamp(p0 - 1, 0, int(console.cols) - 1))
	case 'e': // VPR 行相对下移(origin 下限制在滚动区底)
		vt.wrap_pending = false
		limit := int(console.rows) - 1
		if vt.origin_mode {
			limit = int(vt.scroll_bottom)
		}
		console.cursor_row = u16(min(base + limit, int(console.cursor_row) + max(1, p0)))
	case 'a': // HPR 列相对右移
		vt.wrap_pending = false
		console.cursor_col = u16(min(int(console.cols) - 1, int(console.cursor_col) + max(1, p0)))
	}
}

vtSetMode :: proc(console_h : mem.Handle, set : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	if console.parser.num_intermediate_chars == 0 || console.parser.intermediate_chars[0] != '?' { // 仅 '?' DEC 私用模式
		return
	}
	mode := 0
	if console.parser.num_params > 0 {
		mode = console.parser.params[0]
	}
	switch mode {
	case 3: // DECCOLM 80/132 列:切换清屏、光标回 home、滚动区重置
		vt.deccolm = set
		TermBufferClear(console.active_term_buffer_id)
		console.cursor_row, console.cursor_col = 0, 0
		vt.scroll_top, vt.scroll_bottom = 0, console.rows - 1
		vt.wrap_pending = false
		console.cols = set ? 132 : 80
		ct.Resize(console.conpty_handle, console.cols, console.rows)
	case 6: // DECOM origin mode:置位光标移到滚动区 home,复位移到左上
		vt.origin_mode = set
		tb := GetTermBuffer(console.active_term_buffer_id)
		b := 0
		if tb != nil {
			b = screenBase(console, tb)
		}
		if set {
			console.cursor_row = u16(b + int(vt.scroll_top))
		} else {
			console.cursor_row = u16(b)
		}
		console.cursor_col = 0
		vt.wrap_pending = false
	case 7:
		vt.autowrap = set
		if !set {
			vt.wrap_pending = false
		}
	case 25:
		vt.cursor_visible = set
	case 1000:
		vt.mouse_mode = set ? 1 : 0
	case 1002:
		vt.mouse_mode = set ? 2 : 0
	case 1003:
		vt.mouse_mode = set ? 3 : 0
	case 1006:
		vt.sgr_mouse = set
	case 1004:
		vt.focus_events = set
	case 2004:
		vt.bracketed_paste = set
	case 1049:
		vtAltScreen(console_h, set)
	case 2026: // 同步输出,全量重建天然满足
	}
}

// 进:存光标 + 切到交替屏(新建空页);出:切回主屏 + 销毁交替页 + 取光标
vtAltScreen :: proc(console_h : mem.Handle, enter : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	vt.wrap_pending = false
	if enter {
		vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
		vt.saved_scroll_top, vt.saved_scroll_bottom = vt.scroll_top, vt.scroll_bottom
		vt.scroll_top, vt.scroll_bottom = 0, console.rows - 1
		alt := vt.alt_term_buffer_id
		if alt.id == 0 {
			alt, _ = CreateTermBuffer()
			ConsoleAttachTermBuffer(console_h, alt)
			vt.alt_term_buffer_id = alt
		} else {
			ConsoleActivateTermBuffer(console_h, alt)
		}
		TermBufferClear(alt)
		console.cursor_row, console.cursor_col = 0, 0
	} else {
		alt := vt.alt_term_buffer_id
		if console.term_buffer_count > 0 {
			ConsoleActivateTermBuffer(console_h, console.term_buffer_ids[0])
		}
		if alt.id != 0 {
			DestroyTermBuffer(alt)
			vt.alt_term_buffer_id = {}
		}
		console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
		vt.scroll_top, vt.scroll_bottom = vt.saved_scroll_top, vt.saved_scroll_bottom
	}
}

// ---------------------------------------------------------------------------
// SGR
// ---------------------------------------------------------------------------
// 颜色一律写引用编码(theme.odin):30-37/90-97 → colorIndex(0..15),
// 38;5 → colorIndex(n),38;2 → RGB,39/49/0 → DEFAULT_COLOR(渲染期按主题解析)。

vtSgr :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	style := vt.style
	params := console.parser.params[:console.parser.num_params]
	i := 0
	// ESC[m(无参数)= ESC[0m:重置样式,不能当 no-op
	if len(params) == 0 {
		vt.style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR }
		return
	}
	for i < len(params) {
		pp := params[i]
		switch pp {
		//TODO
		case 0:
			style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR }
		case 1: style.bold = true
		case 3: style.italic = true
		case 4: style.underline = 1
		case 7: style.reverse = true
		case 9: style.crossed = true
		case 21: style.underline = 2 // 双下划线
		case 22: style.bold = false
		case 23: style.italic = false
		case 24: style.underline = 0
		case 27: style.reverse = false
		case 29: style.crossed = false
		case 53: style.overline = true
		case 55: style.overline = false
		case 30 ..= 37: style.fg = colorIndex(pp - 30)
		case 38, 48: // 扩展色:分号式 38;2;r;g;b / 38;5;n;冒号式 38:2::r:g:b / 38:5::n
			if int(console.parser.num_subparams[i]) > 1 {
				// 冒号式:组内子参 [38, mode, ...];RGB 带 colorspace 槽(cs 非 0 拒绝,
				// 与 WT 一致:非标准 ODA 序列以非零 cs 暴露错误);256 索引取最后一个
				// 子参(兼容 :5:n 与 :5::n,空段 = 0)。
				s := &console.parser.subparams[i]
				mode := s[1]
				switch mode {
				case 5:
					n := s[int(console.parser.num_subparams[i]) - 1]
					color := colorIndex(int(n))
					if pp == 38 { style.fg = color } else { style.bg = color }
				case 2:
					if console.parser.num_subparams[i] == 6 && s[2] == 0 {
						color := colorRgb((u32(s[3]) << 16) | (u32(s[4]) << 8) | u32(s[5]))
						if pp == 38 { style.fg = color } else { style.bg = color }
					}
				}
			} else if i + 1 < len(params) {
				// 分号式:38 后的组 = mode;值取后续组(RGB 限 < 256 与 WT/xterm 一致)
				mode := params[i + 1]
				if mode == 5 && i + 2 < len(params) {
					color := colorIndex(int(params[i + 2]))
					if pp == 38 { style.fg = color } else { style.bg = color }
					i += 2
				} else if mode == 2 && i + 4 < len(params) {
					r, g, b := params[i + 2], params[i + 3], params[i + 4]
					if r <= 255 && g <= 255 && b <= 255 {
						color := colorRgb((u32(r) << 16) | (u32(g) << 8) | u32(b))
						if pp == 38 { style.fg = color } else { style.bg = color }
					}
					i += 4
				}
			}
		case 39: style.fg = DEFAULT_COLOR
		case 40 ..= 47: style.bg = colorIndex(pp - 40)
		case 49: style.bg = DEFAULT_COLOR
		case 90 ..= 97: style.fg = colorIndex(pp - 90 + 8)
		case 100 ..= 107: style.bg = colorIndex(pp - 100 + 8)
		}
		i += 1
	}
	vt.style = style
}

// 光标屏幕位置(0-based):物理行 - 可视区顶部(历史 + review 滚动)
cursorScreenPos :: proc(console : ^Console) -> (row, col : int) {
	tb := GetTermBuffer(console.active_term_buffer_id)
	top := 0
	if tb != nil {
		top = viewportTop(console, tb)
	}
	return int(console.cursor_row) - top, int(console.cursor_col)
}

// ESC[row;colR 应答光标位置(程序阻塞等这个);报屏幕坐标,不是物理行
vtReplyCursor :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	r, c := cursorScreenPos(console)
	msg := fmt.tprintf("\x1b[%d;%dR", r + 1, c + 1)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// DECXCPR(CSI ? 6 n)/modifyOtherKeys CPR(CSI ? u):应答带 '?' 前缀
vtReplyCursorDec :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	r, c := cursorScreenPos(console)
	msg := fmt.tprintf("\x1b[?%d;%dR", r + 1, c + 1)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// XTWINOPS 18t:窗口尺寸应答(nvim 等以此校准行数)
vtReplyWindowSize :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	msg := fmt.tprintf("\x1b[8;%d;%dt", console.rows, console.cols)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

vtReplyOk :: proc(console_h : mem.Handle) { // DSR 5:设备状态正常
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)string("\x1b[0n"))
}

// DA1:CSI c → CSI ? 1;2c(VT100 兼容)
vtReplyDa1 :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)string("\x1b[?1;2c"))
}

// DA2:CSI > Ps c → CSI > 0;{版本};0c(nvim 用它识别终端)
vtReplyDa2 :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	msg := fmt.tprintf("\x1b[>0;%d;0c", DA2_VERSION)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// DECRQM:CSI ? Ps $ p → CSI ? Ps;Pm $ y(Pm:0=未知 1=置位 2=复位 3=永置 4=永复)
vtReplyDecrqm :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	state := vtQueryMode(console, mode)
	msg := fmt.tprintf("\x1b[?%d;%d$y", mode, state)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

vtQueryMode :: proc(console : ^Console, mode : int) -> int {
	vt := &console.vt
	switch mode {
	case 3:
		return vt.deccolm ? 1 : 2
	case 6:
		return vt.origin_mode ? 1 : 2
	case 7:
		return vt.autowrap ? 1 : 2
	case 25:
		return vt.cursor_visible ? 1 : 2
	case 1049:
		return vt.alt_term_buffer_id.id != 0 ? 1 : 2
	case 1000:
		return vt.mouse_mode == 1 ? 1 : 2
	case 1002:
		return vt.mouse_mode == 2 ? 1 : 2
	case 1003:
		return vt.mouse_mode == 3 ? 1 : 2
	case 1006:
		return vt.sgr_mouse ? 1 : 2
	case 1004:
		return vt.focus_events ? 1 : 2
	case 2004:
		return vt.bracketed_paste ? 1 : 2
	}
	return 0 // 未识别
}

// 调试/测试:直接喂字节给解析器,绕过 ConPTY
ConsoleFeed :: proc(console_h : mem.Handle, data : []byte) {
	vtFeed(console_h, data)
}

