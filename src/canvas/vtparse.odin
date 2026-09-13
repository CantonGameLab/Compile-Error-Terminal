// vtparse 移植:Paul Williams 的 DEC 兼容状态机解析器(Joshua Haberman 版,public domain)。
// 忠实移植 + 两处必要补充:
//   1. UTF-8:原版仅 ASCII,GROUND 会丢弃 0xC0-0xFF;终端需要中文等
//   2. OSC 以 BEL(0x07)终止:xterm/ConPTY 实际用 BEL 结尾
// 结构:Parser 是 Console 的组件(纯草稿纸)—— 不存句柄、不留回调、无上下文;
// Parse 是唯一入口(唯一参数 = 会话句柄),查表与三步转移就地展开,
// 动作在 doAction 里直接派发给 vtDispatch(console_h, …)。
package canvas

import mem "../memory"

Action :: enum u8 {
	None = 0,
	Clear,
	Collect,
	CsiDispatch,
	EscDispatch,
	Error,
	Execute,
	Hook,
	Ignore,
	OscEnd,
	OscPut,
	OscStart,
	Param,
	Print,
	Put,
	Unhook,
	// 注:UTF-8 不再以 Action 表达,由 Parse 顶层拦截
}

State :: enum u8 {
	Ground = 0, // 零值 = 初始状态
	CsiEntry,
	CsiIgnore,
	CsiIntermediate,
	CsiParam,
	DcsEntry,
	DcsIgnore,
	DcsIntermediate,
	DcsParam,
	DcsPassthrough,
	Escape,
	EscapeIntermediate,
	OscString,
	SosPmApcString,
	NoChange = 255, // 哨兵:状态不变
}

// 参数值上限:DEC 标准 16384,xterm/VTE 用 65535(win32-input-mode 传 UTF-16 值)
MAX_PARAMETER_VALUE :: 65535

MAX_INTERMEDIATE_CHARS :: 2
MAX_PARAMS :: 16
MAX_SUBPARAMS :: 6 // 每参数组最多子参(WT 同限;SGR 38:2::r:g:b 需 6)

// 字节识别态(草稿纸):Console 的一个组件,1:1 持有,无独立生命周期,
// 字段只在 Parse/doAction 内被读写。
Parser :: struct {
	state : State,
	intermediate_chars : [MAX_INTERMEDIATE_CHARS + 1]u8,
	num_intermediate_chars : int,
	ignore_flagged : bool,
	// 参数模型(WT 同构):分号 = 新参数组;冒号 = 组内子参。
	// params[i] = 组主值(第一个子参,兼容扁平消费);subparams[i] = 全子参。
	params : [MAX_PARAMS]int,
	subparams : [MAX_PARAMS][MAX_SUBPARAMS]int,
	num_subparams : [MAX_PARAMS]u8, // 各组子参数个数(含主值);0 = 组未定型
	num_params : int,

	// UTF-8(GROUND 状态消费,先于状态机)
	utf8_pending : [4]u8,
	utf8_pending_len : int,
}

// 字节区间转移
Transition :: struct {
	lo, hi : u8,
	action : Action,
	to : State,
}

StateSpec :: struct {
	entry, exit : Action,
	tr : []Transition,
}

// 入口:字节流 → 动作 → 语义层。唯一参数是会话句柄,所有操作落在 console 上。
// 查表与三步转移就地展开(算法辅助过程不另立函数,读一遍就看完整条规则)。
Parse :: proc(console_h : mem.Handle, data : []byte) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	for b in data {
		// ① UTF-8 续字节:先于状态机消费(任何状态)
		if console.parser.utf8_pending_len > 0 {
			if b & 0xC0 == 0x80 { // 0b10xxxxxx = 续字节
				console.parser.utf8_pending[console.parser.utf8_pending_len] = b
				console.parser.utf8_pending_len += 1
				if console.parser.utf8_pending_len >= utf8Len(console.parser.utf8_pending[0]) {
					cp := decodeRune(console.parser.utf8_pending[:console.parser.utf8_pending_len])
					console.parser.utf8_pending_len = 0
					// 解码完成 → 按当前状态决定去向(Ground = 打印;OSC/DCS = 字符串内容)
					#partial switch console.parser.state {
					case .Ground:         vtDispatch(console_h, .Print, cp)
					case .OscString:      vtDispatch(console_h, .OscPut, cp)
					case .DcsPassthrough: vtDispatch(console_h, .Put, cp)
					}
				}
				continue
			}
			// 非法续字节(控制/ASCII/新起始):丢弃截断序列,当前字节重新走状态机。
			// 关键:不吞 ESC/CSI(截断字符串后的序列必须完整生效)。
			console.parser.utf8_pending_len = 0
		}
		// ② 合法 UTF-8 起始 C2-DF/E0-EF/F0-F4(C0/C1 overlong 与 F5-FF 非法),
		//    且当前状态会产出文本/字符串内容才收集;CSI/ESC 等控制序列中的 0x80+ 由状态机忽略。
		if b >= 0xC2 && b <= 0xF4 {
			collects := false
			#partial switch console.parser.state {
			case .Ground, .OscString, .DcsPassthrough, .SosPmApcString:
				collects = true
			}
			if collects {
				console.parser.utf8_pending[0] = b
				console.parser.utf8_pending_len = 1
				continue
			}
		}
		// ③ 查表:任意状态生效的转移(ESC/C1 控制)优先,其次状态内转移
		act, to := Action.None, State.NoChange
		for t in anywhere_transitions {
			if b >= t.lo && b <= t.hi {
				act, to = t.action, t.to
				break
			}
		}
		if act == .None && to == .NoChange {
			for t in state_specs[console.parser.state].tr {
				if b >= t.lo && b <= t.hi {
					act, to = t.action, t.to
					break
				}
			}
		}
		// ④ 转移:无状态变化只做动作;有变化则"旧状态 exit → 本次动作 → 新状态 entry"
		//    (这个顺序是语义的一部分:进 CSI 前 Clear 清参数、出 OSC 时 OscEnd 收尾)
		if to == .NoChange {
			doAction(console_h, act, b)
		} else {
			exit := state_specs[console.parser.state].exit
			entry := state_specs[to].entry
			if exit != .None {
				doAction(console_h, exit, 0)
			}
			if act != .None {
				doAction(console_h, act, b)
			}
			if entry != .None {
				doAction(console_h, entry, 0)
			}
			console.parser.state = to
		}
	}
}

// 一个动作作用到识别态(参数/中间字节记账),需要语义的动作直接派发出去。
// 内部动作(Clear/Collect/Param/Ignore)到此为止,永远不出这个函数。
doAction :: proc(console_h : mem.Handle, action : Action, ch : u8) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	#partial switch action {
	case .Collect:
		if console.parser.num_intermediate_chars + 1 > MAX_INTERMEDIATE_CHARS {
			console.parser.ignore_flagged = true
		} else {
			console.parser.intermediate_chars[console.parser.num_intermediate_chars] = ch
			console.parser.num_intermediate_chars += 1
		}
	case .Param:
		if ch == ';' {
			// 分号 = 新参数组;当前组定型(空段 = 1 个 0)
			if console.parser.num_params == 0 {
				console.parser.num_params = 1
				console.parser.num_subparams[0] = 0
				console.parser.params[0] = 0
			}
			paramEnd(console_h)
			if console.parser.num_params < MAX_PARAMS {
				console.parser.num_params += 1
				console.parser.num_subparams[console.parser.num_params - 1] = 0
			}
		} else if ch == ':' {
			// 冒号 = 组内子参;当前子参定型,开新子参(值 0)
			if console.parser.num_params == 0 {
				console.parser.num_params = 1
				console.parser.num_subparams[0] = 0
				console.parser.params[0] = 0
			}
			if console.parser.num_params <= MAX_PARAMS {
				paramEnd(console_h)
				i := console.parser.num_params - 1
				if int(console.parser.num_subparams[i]) < MAX_SUBPARAMS {
					console.parser.num_subparams[i] += 1
					console.parser.subparams[i][console.parser.num_subparams[i] - 1] = 0
				}
			}
		} else {
			// 数字:累加到当前组最后一个子参;主值(第一个子参)同步 params
			if console.parser.num_params == 0 {
				console.parser.num_params = 1
				console.parser.num_subparams[0] = 0
				console.parser.params[0] = 0
			}
			if console.parser.num_params <= MAX_PARAMS {
				i := console.parser.num_params - 1
				if console.parser.num_subparams[i] == 0 {
					console.parser.num_subparams[i] = 1
					console.parser.subparams[i][0] = 0
				}
				j := int(console.parser.num_subparams[i]) - 1
				v := console.parser.subparams[i][j] * 10 + int(ch - '0')
				if v > MAX_PARAMETER_VALUE {
					v = MAX_PARAMETER_VALUE
				}
				console.parser.subparams[i][j] = v
				if j == 0 {
					console.parser.params[i] = v
				}
			}
		}
	case .Clear:
		console.parser.num_intermediate_chars = 0
		console.parser.num_params = 0
		console.parser.ignore_flagged = false
		for i in 0 ..< MAX_PARAMS {
			console.parser.num_subparams[i] = 0
		}
	case .Ignore:
		// 无操作
	case .CsiDispatch:
		paramEnd(console_h) // 末尾组定型(如 CSI 5;)后派发
		vtDispatch(console_h, action, rune(ch))
	case:
		vtDispatch(console_h, action, rune(ch))
	}
}

// 当前组定型:无子参则补一个 0(空段);主值同步(防 params 残留)
paramEnd :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	i := console.parser.num_params - 1
	if i < 0 {
		return
	}
	if console.parser.num_subparams[i] == 0 {
		console.parser.num_subparams[i] = 1
		console.parser.subparams[i][0] = 0
		console.parser.params[i] = 0
	}
}

// ---------------------------------------------------------------------------
// UTF-8
// ---------------------------------------------------------------------------

utf8Len :: proc(b : u8) -> int {
	switch {
	case b < 0x80: return 1
	case b < 0xE0: return 2
	case b < 0xF0: return 3
	case b < 0xF8: return 4
	}
	return 1 // 非法起始字节,只消费自身
}

decodeRune :: proc(bytes : []u8) -> rune {
	switch len(bytes) {
	case 1: return rune(bytes[0])
	case 2: return rune(bytes[0] & 0x1F) << 6 | rune(bytes[1] & 0x3F)
	case 3: return rune(bytes[0] & 0x0F) << 12 | rune(bytes[1] & 0x3F) << 6 | rune(bytes[2] & 0x3F)
	case 4: return rune(bytes[0] & 0x07) << 18 | rune(bytes[1] & 0x3F) << 12 | rune(bytes[2] & 0x3F) << 6 | rune(bytes[3] & 0x3F)
	}
	return 0
}

// ---------------------------------------------------------------------------
// 转移表(由 vtparse_tables.rb 忠实转录;OSC 增加 BEL 终止)
// ---------------------------------------------------------------------------

anywhere_transitions := [?]Transition{
	{0x18, 0x18, .Execute, .Ground},
	{0x1A, 0x1A, .Execute, .Ground},
	{0x80, 0x8F, .Execute, .Ground},
	{0x91, 0x97, .Execute, .Ground},
	{0x99, 0x99, .Execute, .Ground},
	{0x9A, 0x9A, .Execute, .Ground},
	{0x9C, 0x9C, .None, .Ground}, // ST
	{0x1B, 0x1B, .None, .Escape}, // ESC
	{0x98, 0x98, .None, .SosPmApcString}, // SOS
	{0x9E, 0x9E, .None, .SosPmApcString}, // PM
	{0x9F, 0x9F, .None, .SosPmApcString}, // APC
	{0x90, 0x90, .None, .DcsEntry},       // DCS
	{0x9D, 0x9D, .None, .OscString},      // OSC
	{0x9B, 0x9B, .None, .CsiEntry},       // CSI
}

tr_ground := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x7F, .Print, .NoChange},
	// UTF-8 起始由 Parse 顶层拦截,不走状态机表
}

tr_escape := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .EscapeIntermediate},
	{0x30, 0x4F, .EscDispatch, .Ground},
	{0x51, 0x57, .EscDispatch, .Ground},
	{0x59, 0x59, .EscDispatch, .Ground},
	{0x5A, 0x5A, .EscDispatch, .Ground},
	{0x5C, 0x5C, .EscDispatch, .Ground},
	{0x60, 0x7E, .EscDispatch, .Ground},
	{0x5B, 0x5B, .None, .CsiEntry},
	{0x5D, 0x5D, .None, .OscString},
	{0x50, 0x50, .None, .DcsEntry},
	{0x58, 0x58, .None, .SosPmApcString},
	{0x5E, 0x5E, .None, .SosPmApcString},
	{0x5F, 0x5F, .None, .SosPmApcString},
}

tr_escape_intermediate := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x7E, .EscDispatch, .Ground},
}

tr_csi_entry := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .CsiIntermediate},
	{0x3A, 0x3A, .None, .CsiIgnore},
	{0x30, 0x39, .Param, .CsiParam},
	{0x3B, 0x3B, .Param, .CsiParam},
	{0x3C, 0x3F, .Collect, .CsiParam}, // ? > < = 私用标记
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_csi_ignore := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x3F, .Ignore, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x40, 0x7E, .None, .Ground},
}

tr_csi_param := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x30, 0x39, .Param, .NoChange},
	{0x3B, 0x3B, .Param, .NoChange},
	// 冒号 = 子参数分隔(xterm 新式 SGR 如 38:2::r:g:b、4:3m)。
	// 按普通参数分隔处理,SGR 层再解释(与分号同语义,空字段为 0)。
	{0x3A, 0x3A, .Param, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3C, 0x3F, .None, .CsiIgnore},
	{0x20, 0x2F, .Collect, .CsiIntermediate},
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_csi_intermediate := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x3F, .None, .CsiIgnore},
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_dcs_entry := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3A, 0x3A, .None, .DcsIgnore},
	{0x20, 0x2F, .Collect, .DcsIntermediate},
	{0x30, 0x39, .Param, .DcsParam},
	{0x3B, 0x3B, .Param, .DcsParam},
	{0x3C, 0x3F, .Collect, .DcsParam},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_intermediate := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x3F, .None, .DcsIgnore},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_ignore := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .Ignore, .NoChange},
}

tr_dcs_param := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x30, 0x39, .Param, .NoChange},
	{0x3B, 0x3B, .Param, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3A, 0x3A, .None, .DcsIgnore},
	{0x3C, 0x3F, .None, .DcsIgnore},
	{0x20, 0x2F, .Collect, .DcsIntermediate},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_passthrough := [?]Transition{
	{0x00, 0x17, .Put, .NoChange},
	{0x19, 0x19, .Put, .NoChange},
	{0x1C, 0x1F, .Put, .NoChange},
	{0x20, 0x7E, .Put, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
}

tr_sos_pm_apc_string := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .Ignore, .NoChange},
}

tr_osc_string := [?]Transition{
	{0x07, 0x07, .None, .Ground}, // BEL 终止 OSC(新增,ConPTY/xterm 用法)
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .OscPut, .NoChange},
}

state_specs := [14]StateSpec {
	{tr = tr_ground[:]},                                 // Ground = 0
	{entry = .Clear, tr = tr_csi_entry[:]},              // CsiEntry = 1
	{tr = tr_csi_ignore[:]},                             // CsiIgnore = 2
	{tr = tr_csi_intermediate[:]},                       // CsiIntermediate = 3
	{tr = tr_csi_param[:]},                              // CsiParam = 4
	{entry = .Clear, tr = tr_dcs_entry[:]},              // DcsEntry = 5
	{tr = tr_dcs_ignore[:]},                             // DcsIgnore = 6
	{tr = tr_dcs_intermediate[:]},                       // DcsIntermediate = 7
	{tr = tr_dcs_param[:]},                              // DcsParam = 8
	{entry = .Hook, exit = .Unhook, tr = tr_dcs_passthrough[:]}, // DcsPassthrough = 9
	{entry = .Clear, tr = tr_escape[:]},                 // Escape = 10
	{tr = tr_escape_intermediate[:]},                    // EscapeIntermediate = 11
	{entry = .OscStart, exit = .OscEnd, tr = tr_osc_string[:]}, // OscString = 12
	{tr = tr_sos_pm_apc_string[:]},                      // SosPmApcString = 13
}
