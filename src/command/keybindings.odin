// 快捷键绑定表(动作层):键事件通道 → 绑定表 → 数据化命令。
// 消费链契约:command 先行(命中即置 consumed = true,序列不再流向下游);
// canvas 经 input.TakeAppInput 拿"未消费剩余"(文本/输入)。
// 绑定表操作(Set/Clear/Unset/Get)= command 域 userapi(用户配置:main.initWindows / bind 命令)。
package command

import inp "../input"
import mem "../memory"

// 组合修饰:Alt/Ctrl/Shift 自由组合;规则 = Shift 不得单独出现(须与 Alt/Ctrl 伴生)
KeyMod :: enum u8 {
	Alt,
	Ctrl,
	Shift,
	Win, // 事件侧保留(绑定表不用;事件含 Win 时与绑定不匹配)
}

KeyMods :: bit_set[KeyMod; u8]

// input 修饰字节(1=Shift 2=Alt 4=Ctrl 8=Win)→ KeyMods
modsFromByte :: proc(m : u8) -> KeyMods {
	s : KeyMods
	if m & 1 != 0 {
		s += {.Shift}
	}
	if m & 2 != 0 {
		s += {.Alt}
	}
	if m & 4 != 0 {
		s += {.Ctrl}
	}
	if m & 8 != 0 {
		s += {.Win}
	}
	return s
}

// 一条绑定:触发 = mods+key;动作 = 数据化命令(与字符串指令共用 ParsedCommand)
Binding :: struct {
	key : inp.Scancode,
	mods : KeyMods,
	cmd : ParsedCommand,
}

// 默认绑定表(唯一实例):结构 = 槽数组 + 计数。读写经 GetKeyBindings 指针
// 直接操作;userapi(SetKeyBinding/ClearKeyBindings/...)是面向用户的表操作接口。
MAX_DEFAULT_BINDINGS :: 64

KeyBindings :: struct {
	bindings : [MAX_DEFAULT_BINDINGS]Binding,
	count : int,
}

key_bindings : KeyBindings

GetKeyBindings :: proc() -> ^KeyBindings {
	return &key_bindings
}

// 查绑定:精确匹配 (key, mods);命中返回命令(表由 main 配置/用户 bind 命令填充)
findBinding :: proc(sc : u32, mods : KeyMods) -> (Binding, bool) {
	//if mods == {.Shift} {
	//	return {}, false // Shift 单独 = 非法触发(不参与匹配)
	//}
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		b := &kb.bindings[i]
		if u32(b.key) == sc && b.mods == mods {
			return b^, true
		}
	}
	return {}, false
}

// 每帧调用(main,先于 canvas.Update):绑定表 → ExecuteCommand(数据化动作);
// 命中 = 消费(consumed;序列不再流入应用/文本)。
ProcessKeys :: proc() {
	n := inp.KeyEventCount()
	for i in 0 ..< n {
		ev := inp.KeyEventGet(i)
		if ev == nil || ev.consumed {
			continue
		}
		if b, ok := findBinding(ev.sc, modsFromByte(ev.mods)); ok {
			ExecuteCommand(b.cmd)
			ev.consumed = true // 动作已执行,序列不再进应用
		}
	}
	// 输入路由由 main 决定:bar 可见 → CommandBar 编辑状态机;否则未消费输入进应用
}

// ---------------------------------------------------------------------------
// 绑定表 userapi(用户配置:main.initWindows 配置段落 / bind 命令)
// ---------------------------------------------------------------------------
// 添加/覆盖一条绑定(同 key+mods 覆盖已有);表满返回 false
SetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods, cmd : ParsedCommand) -> bool {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			kb.bindings[i].cmd = cmd
			return true
		}
	}
	if kb.count >= len(kb.bindings) {
		return false
	}
	kb.bindings[kb.count] = Binding { key = key, mods = mods, cmd = cmd }
	kb.count += 1
	return true
}

// 清空绑定表(重复初始化 = 清零重建,无状态判定)
ClearKeyBindings :: proc() {
	GetKeyBindings().count = 0
}

// 移除组合 (key, mods) 的绑定(不存在 = false;交换删除,顺序无关)
UnsetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods) -> bool {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			kb.bindings[i] = kb.bindings[kb.count - 1]
			kb.count -= 1
			return true
		}
	}
	return false
}

// 按 (key, mods) 查询绑定
GetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods) -> (Binding, bool) {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			return kb.bindings[i], true
		}
	}
	return {}, false
}
