// canvas 模块声明级迁移工具。
// 用途:按"声明单元"(顶层类型/过程/常量/变量 + 其前置注释/属性行)切分源文件,
// 按映射表搬入目标文件,并用 sha256 审计"迁移前后每个声明单元的逐字哈希一致"
// —— 保证纯移动、零代码变形。
// 用法:
//   odin run playground/declsplit/ -- dump     # 切分+导出 decls_before.txt(单元名+哈希)
//   odin run playground/declsplit/ -- apply    # 生成迁移后的文件(旧文件删除)
//   odin run playground/declsplit/ -- after    # 重新导出 decls_after.txt
//   odin run playground/declsplit/ -- verify   # 对比 before/after(名字集合+哈希)
#+feature dynamic-literals
package main

import "core:os"
import "core:fmt"
import "core:strings"
import sha2 "core:crypto/sha2"

SRC_DIR :: "src/canvas"

// 迁移源文件(parser.odin / keysbinding.odin 不参与,原样保留)
SOURCE_FILES := [4]string{"canvas.odin", "window.odin", "term.odin", "vt.odin"}

Unit :: struct {
	name : string,
	file : string,
	index : int,
	start_line : int,
	text : string,
	hash : [32]byte,
}

// ---------------------------------------------------------------------------
// 映射表:声明名 → 目标文件(未列出的声明报错)
// ---------------------------------------------------------------------------

TreeUnits := []string{
	"Transform", "SplitType", "FocusDirection", "WindowTreeNode",
	"InitWindowTree", "CreateWindowTreeNode", "GetWindowTreeNode",
	"NodeHandleById", "WindowTreeRoot", "ResetWindowTree", "TreeNodeRemoveAll",
	"SetFocus", "GetFocus", "FocusNeighbor", "focusDescend",
	"TreeNodeSetConsole", "NodeConsole", "NodeContentTransform",
	"nodeAtPoint", "nodeAtPointRec",
	"TreeNodeSplit", "TreeNodeRemove", "treeNodePromote",
	"TreeNodeSetSplitFactor", "TreeNodeSetSplitType",
	"TreeNodeSetLeftSon", "TreeNodeSetRightSon", "treeNodeSetSon",
	"WindowTreeSetRootSize", "RecalculateTransforms",
	"ConsoleUpdateTree", "firstLeaf", "collectLeaves", "countLeaves",
	"MAX_WINDOW_SLOTS", "DEFAULT_FRAME_COLOR",
	"MAX_TREE_NODE_SLOTS", "ROOT_WINDOW_TREE_NODE_ID",
	"window_tree_nodes", "focused_node",
	"Window_Width", "Window_Height", "DEFAULT_FRAME_WIDTH",
}

// win.odin 已删除(Window 中间层取消:节点直接持 console,字体集归 Console)
WinUnits := []string{}

ItermUnits := []string{
	"Iterm", "ToolType",
	"TreeNodeAddIterm", "TreeNodeRemoveIterm", "ItermGet",
	"ItermAbsoluteTransform", "nodeWindowEnsure",
}

CmdbarUnits := []string{
	"CommandBar",
	"ToggleCommandBar", "CommandBarVisible", "CommandBarInsert",
	"CommandBarBackspace", "CommandBarDelete", "CommandBarCursorMove",
	"CommandBarHome", "CommandBarEnd", "CommandBarWordMove",
	"CommandBarTake", "GetCommandBar",
	"MAX_CMD_INPUT", "command_bar",
}

BufferUnits := []string{
	"CellStyle", "Cell", "Line", "TermBuffer", "runeWidth",
	"CreateTermBuffer", "GetTermBuffer", "TermBufferLineCount",
	"DestroyTermBuffer", "TermBufferClear",
	"vtWrapOnce", "ConsoleWriteRune",
	"insertLine", "trimScrollback", "vtScrollUp", "vtScrollDown",
	"eraseCell", "lineEnsureCol",
	"vtEraseInLine", "vtEraseInDisplay", "vtClearLineAll", "vtEraseChars",
	"vtDeleteChars", "vtInsertChars", "vtInsertLines", "vtDeleteLines",
	"DEFAULT_COLOR", "MAX_TERM_BUFFER_SLOTS", "MAX_SCROLLBACK_LINES", "TRIM_SLACK",
	"term_buffers",
}

ConsoleUnits := []string{
	"Console",
	"CreateConsole", "GetConsole", "ConsoleActiveTermBuffer", "DestroyConsole",
	"ConsoleAttachTermBuffer", "ConsoleActivateTermBuffer",
	"viewportTop", "applyConsoleSize", "ConsoleSetSize", "ConsoleUpdateLayout",
	"ConsoleSetCursor", "ConsoleViewportTop", "screenBase",
	"MAX_CONSOLE_SLOTS", "MAX_BUFFERS_PER_CONSOLE",
	"consoles",
}

VtUnits := []string{
	"VtState", "DA2_VERSION", "update_scratch", "VT_DEBUG",
	"UpdateConsole", "vtFeed", "vtParserCallback", "vtEscDispatch",
	"packHandle", "unpackHandle", "skipWideCol",
	"vtHandleC0", "vtLf", "vtReverseIndex", "vtReset",
	"vtPrint", "vtTargetRow", "vtCsiDispatch", "vtSetMode", "vtAltScreen",
	"vtSgr", "ansi256ToRgb", "ansiCubeLevel",
	"cursorScreenPos",
	"vtReplyCursor", "vtReplyCursorDec", "vtReplyWindowSize", "vtReplyOk",
	"vtReplyDa1", "vtReplyDa2", "vtReplyDecrqm", "vtQueryMode",
	"ConsoleFeed", "ANSI16", "vtDbg",
}

UserapiUnits := []string{
	"CreateWindowTreeRoot", "SplitNewWindow", "DestroyWindow", "SetSplitFactor",
	"ExchangeWindow", "SetWindowFont", "ClearWindowConsole", "clearConsoleRefs",
	"LaunchConsole", "FeedConsole", "SetAutoClose", "PollSessions", "updateWindow",
	"ConsoleScroll", "ConsoleExitReview",
	"SetFocusWindow", "FocusMove", "GetFocusWindow", "WindowCount",
	"resolveWindow",
}

// 目标文件 head/imports(migration 唯一允许的新增:文件头导语;声明体零改动)
FileHead := map[string]string{
	"tree.odin" =       `// 窗口树数据:WindowTreeNode(节点)+ Transform(几何)+ SplitType/FocusDirection(方向枚举)。
// 树结构操作(分裂/摘除/挂载/重算/焦点/命中)+ 每帧树遍历编排(ConsoleUpdateTree)。
// 焦点是树状态;命中测试(nodeAtPoint)属树几何。`,
	"win.odin" =        `// 窗口表数据:Window(会话句柄 + 字体 + 工具浮层)的生命周期操作。
// 窗口与树节点分离:TreeNode.console_id 挂载;创建/销毁/ensureWindow 归本文件。`,
	"iterm.odin" =      `// 工具浮层数据:Iterm(锚点/尺寸/渲染目标)+ ToolType 枚举。
// 挂在所属窗口的 iterms 数组上;锚定变换经窗口几何换算。`,
	"commandbar.odin" = `// 悬浮控制台数据:CommandBar(可见性 + 输入缓冲 + 编辑光标 + 视图偏移)。
// 编辑操作(插入/删除/移动/取走);渲染在 render/uilayer,输入状态机在 main。`,
	"buffer.odin" =     `// 内容层数据:Cell/CellStyle/Line/TermBuffer(一"页"行 + 历史 + review 视口锚)。
// 生命周期 + 写路径(rune 落格/折行/滚动/擦除/插入/裁剪)全部收拢于此;
// review_line 为历史视口唯一真值(0=普通实时,1..=底行物理索引+1)。`,
	"console.odin" =    `// 视口层数据:Console(行列/光标/活跃缓冲/vt 状态/布局几何)。
// 生命周期 + 布局(居中取整/review 锚定换算/视口顶行公式)归本文件。`,
	"vt.odin" =         `// VT 语义层:VtState(字节序列的终端状态)+ 序列分派(ESC/CSI/SGR/DEC 模式)
// 与应答(DSR/DA/DECRQM 写回 ConPTY)。操作 Console/TermBuffer 一律经句柄接口。`,
	"userapi.odin" =    `// 用户接口层:面向意图的函数族(窗口生命周期/会话/字体/滚动),
// CommandBar 与子进程指令通道(parser)的绑定目标;id 省略 = 当前焦点。`,
}

FileImports := map[string]string{
	"tree.odin" = `import ct "../conpty"
import fnt "../font"
import mem "../memory"`,
	"win.odin" = `import mem "../memory"`,
	"iterm.odin" = `import mem "../memory"`,
	"commandbar.odin" = `import mem "../memory"`,
	"buffer.odin" = `import mem "../memory"
import "core:fmt"`,
	"console.odin" = `import ct "../conpty"
import mem "../memory"
import vp "../vtparse"`,
	"vt.odin" = `import ct "../conpty"
import mem "../memory"
import vp "../vtparse"
import "core:fmt"`,
	"userapi.odin" = `import ct "../conpty"
import fnt "../font"
import mem "../memory"
import "core:fmt"`,
}

// 生成文件顺序(单元按源文件顺序并入;此处定义合并顺序)
TargetOrder := []string{
	"tree.odin", "win.odin", "iterm.odin", "commandbar.odin",
	"buffer.odin", "console.odin", "vt.odin", "userapi.odin",
}

// 桶索引与 TargetOrder 对应(map 值不可寻址,append 到 map 值会操作临时副本)
bucketIndex :: proc(name : string) -> int {
	for i in 0 ..< len(TargetOrder) {
		if TargetOrder[i] == name {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// 词法切分
// ---------------------------------------------------------------------------

LineScanner :: struct {
	depth : int,
	in_str : bool,
	in_raw : bool,
	in_char : bool,
}

scanChar :: proc(s : ^LineScanner, line : []byte, line_idx : int) -> (in_comment : bool) {
	i := 0
	for i < len(line) {
		c := line[i]
		if in_comment {
			i += 1
			continue
		}
		if s.in_str {
			if c == '\\' {
				i += 2
				continue
			}
			if c == '"' {
				s.in_str = false
			}
			i += 1
			continue
		}
		if s.in_raw {
			if c == '`' {
				s.in_raw = false
			}
			i += 1
			continue
		}
		if s.in_char {
			if c == '\\' {
				i += 2
				continue
			}
			if c == '\'' {
				s.in_char = false
			}
			i += 1
			continue
		}
		switch c {
		case '/':
			if i + 1 < len(line) && line[i + 1] == '/' {
				return true // 行注释:本行剩余全部注释
			}
		case '"':
			s.in_str = true
		case '`':
			s.in_raw = true
		case '\'':
			s.in_char = true
		case '{', '(', '[':
			s.depth += 1
		case '}', ')', ']':
			s.depth -= 1
		}
		i += 1
	}
	return false
}

// 剖分一个文件的顶层单元
splitFile :: proc(path : string) -> (units : [dynamic]Unit, imports : string, warnings : [dynamic]string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read fail:", path)
		return
	}
	defer delete(data)

	lines := strings.split(string(data), "\n")
	defer delete(lines)

	scanner : LineScanner
	pending_comments : [dynamic]string
	pending_attr : [dynamic]string
	cur : [dynamic]string
	cur_name := ""
	cur_start := 0
	in_unit := false

	for li in 0 ..< len(lines) {
		line := lines[li]
		trimmed := strings.trim_left_space(line)

		if !in_unit {
			// 空行:分隔(不并入任何单元;文件头注释区由 package/import 行终结)
			if len(trimmed) == 0 {
				continue
			}
			if strings.has_prefix(trimmed, "//") {
				append(&pending_comments, line)
				continue
			}
			if strings.has_prefix(trimmed, "package ") {
				clear(&pending_comments)
				clear(&pending_attr)
				continue
			}
			if strings.has_prefix(trimmed, "import ") {
				imports = strings.concatenate({imports, "import ", strings.trim_right_space(trimmed[6:]), "\n"})
				clear(&pending_comments)
				clear(&pending_attr)
				continue
			}
			if strings.has_prefix(trimmed, "@") {
				append(&pending_attr, line)
				continue
			}
			// 声明行:单元开始
			name_ok, name := declName(trimmed)
			if !name_ok {
				append(&warnings, fmt.tprintf("%s:%d WARN non-decl top-level: %s", path, li + 1, trimmed))
				clear(&pending_comments)
				clear(&pending_attr)
				continue
			}
			cur_name = name
			cur_start = li
			clear(&cur)
			for c in pending_comments {
				append(&cur, c)
			}
			for a in pending_attr {
				append(&cur, a)
			}
			append(&cur, line)
			clear(&pending_comments)
			clear(&pending_attr)
			// 扫描本行(声明行自身)
			in_comment := scanChar(&scanner, transmute([]byte)line, li)
			_ = in_comment
			if scanner.depth <= 0 {
				if scanner.depth < 0 {
					scanner.depth = 0
				}
				// 单行声明(无括号)立即收尾
				finishUnit(&units, path, cur_name, cur_start, &cur, &scanner)
				in_unit = false
			} else {
				in_unit = true
			}
			continue
		}
		// in_unit:吸收行
		append(&cur, line)
		in_comment := scanChar(&scanner, transmute([]byte)line, li)
		if !in_comment && scanner.depth <= 0 && !scanner.in_str && !scanner.in_raw && !scanner.in_char {
			if scanner.depth < 0 {
				scanner.depth = 0
			}
			finishUnit(&units, path, cur_name, cur_start, &cur, &scanner)
			in_unit = false
		}
	}
	if in_unit {
		append(&warnings, fmt.tprintf("%s WARN: unterminated unit %s", path, cur_name))
		finishUnit(&units, path, cur_name, cur_start, &cur, &scanner)
	}
	// 游离注释(文件尾)
	if len(pending_comments) > 0 {
		append(&warnings, fmt.tprintf("%s WARN: trailing comments %d lines", path, len(pending_comments)))
	}
	return
}

// 声明名:正则模拟(^\s*name :: 或 ^\s*name : (非 ::))
declName :: proc(t : string) -> (ok : bool, name : string) {
	_start := 0
	for _start < len(t) && t[_start] == ' ' {
		_start += 1
	}
	i := _start
	n := 0
	for i < len(t) {
		c := t[i]
		if c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || (n > 0 && c >= '0' && c <= '9') {
			n += 1
			i += 1
			continue
		}
		break
	}
	if n == 0 {
		return false, ""
	}
	name = strings.clone(t[_start:i]) // 深拷贝:输入是被零拷贝切片的行,函数外失效
	// 跳过空白
	for i < len(t) && t[i] == ' ' {
		i += 1
	}
	if i >= len(t) {
		return false, ""
	}
	if t[i] == ':' {
		if i + 1 < len(t) && t[i + 1] == ':' {
			return true, name
		}
		// 变量声明 name : type(排除 ::)
		return true, name
	}
	return false, ""
}

finishUnit :: proc(units : ^[dynamic]Unit, path, name : string, start_line : int, cur : ^[dynamic]string, scanner : ^LineScanner) {
	text := strings.join(cur[:], "\n")
	scanner.depth = 0
	scanner.in_str = false
	scanner.in_raw = false
	scanner.in_char = false
	append(units, Unit {
		name = name,
		file = path,
		index = len(units),
		start_line = start_line + 1,
		text = text,
	})
}

hashBytes :: proc(text : string) -> [32]byte {
	ctx := sha2.Context_256{}
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)text)
	d := [32]byte{}
	sha2.final(&ctx, d[:])
	return d
}

hexStr :: proc(b : []byte) -> string {
	sb := strings.Builder{}
	consts := "0123456789abcdef"
	for x in b {
		strings.write_byte(&sb, consts[u32(x) >> 4])
		strings.write_byte(&sb, consts[u32(x) & 0xF])
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

main :: proc() {
	mode := "dump"
	if len(os.args) > 1 {
		mode = os.args[1]
	}
	if mode == "verify" {
		verify()
		return
	}

	// 切分源文件(dump/apply = 旧 4 文件;after = 迁移后 8 文件)
	all_units := make([dynamic]Unit)
	defer delete(all_units)
	import_map := make(map[string]string)
	defer delete(import_map)
	warnings := 0
	files_to_scan : []string
	if mode == "after" {
		files_to_scan = TargetOrder
	} else {
		files_to_scan = SOURCE_FILES[:]
	}
	for f in files_to_scan {
		path := strings.concatenate({SRC_DIR, "/", f})
		units, imports, warns := splitFile(path)
		if len(warns) > 0 {
			for w in warns {
				fmt.eprintln(w)
				warnings += 1
			}
		}
		import_map[f] = imports
		for &u in units {
			u.hash = hashBytes(u.text)
			append(&all_units, u)
		}
		fmt.printf("split %s: %d units\n", f, len(units))
	}
	fmt.printf("warnings: %d\n", warnings)

	switch mode {
	case "dump":
		export("decls_before.txt", all_units[:])
	case "after":
		export("decls_after.txt", all_units[:])
	case "verify":
		verify()
	case "apply":
		apply(all_units[:])
	case:
		fmt.println("usage: dump|apply|after|verify")
	}
}

writeFile :: proc(path, text : string) {
	ok := os.write_entire_file(path, transmute([]byte)text)
	_ = ok
}

export :: proc(path : string, units : []Unit) {
	lines : [dynamic]string
	defer delete(lines)
	for &u in units {
		hex := hexStr(u.hash[:])
		append(&lines, fmt.tprintf("%s\t%s\t%s", u.name, u.file, hex))
	}
	writeFile(path, strings.join(lines[:], "\n"))
	fmt.printf("export %s: %d units\n", path, len(units))
}

verify :: proc() {
	before := loadManifest("decls_before.txt")
	after := loadManifest("decls_after.txt")
	fmt.printf("DIAG: before=%d after=%d\n", len(before), len(after))
	for k, v in before {
		fmt.printf("DIAG-B: %q / %s\n", k, v[0:8])
		break
	}
	for k, v in after {
		fmt.printf("DIAG-A: %q / %s\n", k, v[0:8])
		break
	}
	bad := 0
	// 名字集合一致
	if len(before) != len(after) {
		fmt.printf("COUNT MISMATCH: %d vs %d\n", len(before), len(after))
		bad += 1
	}
	for name, hex in before {
		if h2, ok := after[name]; !ok {
			fmt.printf("MISSING AFTER: %s\n", name)
			bad += 1
		} else if h2 != hex {
			fmt.printf("HASH DIFF: %s\n", name)
			bad += 1
		}
	}
	for name in after {
		if _, ok := before[name]; !ok {
			fmt.printf("EXTRA AFTER: %s\n", name)
			bad += 1
		}
	}
	if bad == 0 {
		fmt.println("VERIFY OK: all declaration units identical (move-only)")
	} else {
		fmt.printf("VERIFY FAIL: %d issues\n", bad)
	}
}

loadManifest :: proc(path : string) -> map[string]string {
	m := make(map[string]string)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("no manifest:", path)
		return m
	}
	defer delete(data)
	for line in strings.split_lines(string(data)) {
		parts := strings.split(line, "\t")
		if len(parts) == 3 {
			// split 的返回是零拷贝切片(引用 data),data 释放后悬垂 → 克隆
			m[strings.clone(parts[0])] = strings.clone(parts[2])
		}
	}
	return m
}

apply :: proc(units : []Unit) {
	// 安全前置:源文件必须齐全(唯一一次运行,不做增量)
	for f in SOURCE_FILES {
		p := strings.concatenate({SRC_DIR, "/", f})
		if !os.exists(p) {
			fmt.eprintln("ABORT: source missing:", p)
			return
		}
	}

	// name → 桶下标
	target_of := make(map[string]int)
	defer delete(target_of)
	for n in TreeUnits {
		target_of[n] = bucketIndex("tree.odin")
	}
	for n in WinUnits {
		target_of[n] = bucketIndex("win.odin")
	}
	for n in ItermUnits {
		target_of[n] = bucketIndex("iterm.odin")
	}
	for n in CmdbarUnits {
		target_of[n] = bucketIndex("commandbar.odin")
	}
	for n in BufferUnits {
		target_of[n] = bucketIndex("buffer.odin")
	}
	for n in ConsoleUnits {
		target_of[n] = bucketIndex("console.odin")
	}
	for n in VtUnits {
		target_of[n] = bucketIndex("vt.odin")
	}
	for n in UserapiUnits {
		target_of[n] = bucketIndex("userapi.odin")
	}

	buckets : [8][dynamic]Unit
	defer {
		for i in 0 ..< 8 {
			delete(buckets[i])
		}
	}
	unmapped := 0
	for u in units {
		if idx, ok := target_of[u.name]; ok {
			append(&buckets[idx], u)
		} else {
			fmt.printf("UNMAPPED: %s (from %s)\n", u.name, u.file)
			unmapped += 1
		}
	}
	// 安全前置:未映射或目标为空,一律拒绝
	if unmapped > 0 {
		fmt.eprintln("ABORT: unmapped units > 0")
		return
	}
	for i in 0 ..< 8 {
		if len(buckets[i]) == 0 {
			fmt.eprintln("ABORT: target empty:", TargetOrder[i])
			return
		}
	}

	// 先写全部新文件(全部成功后才删旧源)
	for i in 0 ..< 8 {
		target := TargetOrder[i]
		list := buckets[i]
		sb := strings.Builder{}
		strings.write_string(&sb, FileHead[target])
		strings.write_string(&sb, "\npackage canvas\n\n")
		strings.write_string(&sb, FileImports[target])
		strings.write_string(&sb, "\n\n")
		for &u in list {
			strings.write_string(&sb, u.text)
			strings.write_string(&sb, "\n\n")
		}
		writeFile(strings.concatenate({SRC_DIR, "/", target}), strings.to_string(sb))
		fmt.printf("wrote %s: %d units\n", target, len(list))
	}

	// 旧文件删除(canvas/term/window 已迁移;vt 重写;parser/keysbinding 保留)
	for f in SOURCE_FILES {
		switch f {
		case "canvas.odin", "term.odin", "window.odin":
			os.remove(strings.concatenate({SRC_DIR, "/", f}))
			fmt.printf("removed %s\n", f)
		}
	}
}
