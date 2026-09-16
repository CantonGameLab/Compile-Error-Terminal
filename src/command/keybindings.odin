// 快捷键绑定表(动作层):键事件通道 → 绑定表 → 数据化命令。
// 消费链契约:command 先行(命中即置 consumed = true,序列不再流向下游);
// canvas 经 input.TakeAppInput 拿"未消费剩余"(文本/输入)。
// 表内容 = 配置文件(command/config.odin)的 bind 行;运行期经 bind/unbind 命令增删。
// 表操作(Set/Clear/Unset/Get)= command 域 userapi。
package command

import inp "../input"
import mem "../memory"
import "core:strings"

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

// 绑定表(唯一实例):结构 = 槽数组 + 计数,容量 64(配置文件 bind 行 + 运行期 bind)。
// 读写经 GetKeyBindings 指针直接操作;userapi(SetKeyBinding/ClearKeyBindings/...)是表操作接口。
MAX_DEFAULT_BINDINGS :: 64

KeyBindings :: struct {
	bindings : [MAX_DEFAULT_BINDINGS]Binding,
	count : int,
}

key_bindings : KeyBindings

GetKeyBindings :: proc() -> ^KeyBindings {
	return &key_bindings
}

// 查绑定:精确匹配 (key, mods);命中返回表内槽指针(nil = 未命中)
// 表由配置文件(command/config.odin 的 bind 行)填充,运行期由 bind/unbind 命令增删。
findBinding :: proc(sc : u32, mods : KeyMods) -> ^Binding {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		b := &kb.bindings[i]
		if u32(b.key) == sc && b.mods == mods {
			return b
		}
	}
	return nil
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
		if b := findBinding(ev.sc, modsFromByte(ev.mods)); b != nil {
			// 绑定触发的命令不回显(无命令栏上下文):ret 拿到就删
			ret, _ := ExecuteCommand(b.cmd)
			delete(ret)
			ev.consumed = true // 动作已执行,序列不再进应用
		}
	}
	// 输入路由由 main 决定:bar 可见 → CommandBar 编辑状态机;否则未消费输入进应用
}

// ---------------------------------------------------------------------------
// 绑定表 userapi(用户配置:main.initWindows 配置段落 / bind 命令)
// ---------------------------------------------------------------------------
// 添加/覆盖一条绑定(同 key+mods 覆盖已有);表满返回 false。
// 命令里的字符串参数解析期借用输入缓冲(配置文件文本 / 命令栏事件槽),绑定表生命周期
// 更长 → 在此 clone(表持有;覆盖/解绑/清空时配对释放)。
SetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods, cmd : ParsedCommand) -> bool {
	kb := GetKeyBindings()
	c := cmd
	if cmd.sval != "" {
		c.sval = strings.clone(cmd.sval)
	}
	if cmd.sval2 != "" {
		c.sval2 = strings.clone(cmd.sval2)
	}
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			releaseBindingStrings(&kb.bindings[i])
			kb.bindings[i].cmd = c
			return true
		}
	}
	if kb.count >= len(kb.bindings) {
		// 表满:释放刚 clone 的字符串(未入表)
		if c.sval != "" {
			delete(c.sval)
			c.sval = ""
		}
		if c.sval2 != "" {
			delete(c.sval2)
			c.sval2 = ""
		}
		return false
	}
	kb.bindings[kb.count] = Binding { key = key, mods = mods, cmd = c }
	kb.count += 1
	return true
}

// 释放绑定命令里 clone 的字符串(与 SetKeyBinding 的 clone 配对)
releaseBindingStrings :: proc(b : ^Binding) {
	if b.cmd.sval != "" {
		delete(b.cmd.sval)
		b.cmd.sval = ""
	}
	if b.cmd.sval2 != "" {
		delete(b.cmd.sval2)
		b.cmd.sval2 = ""
	}
}

// 清空绑定表(重复初始化 = 清零重建,无状态判定)
ClearKeyBindings :: proc() {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		releaseBindingStrings(&kb.bindings[i])
	}
	kb.count = 0
}

// 移除组合 (key, mods) 的绑定(不存在 = false;交换删除,顺序无关)
UnsetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods) -> bool {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			releaseBindingStrings(&kb.bindings[i])
			kb.bindings[i] = kb.bindings[kb.count - 1]
			kb.count -= 1
			return true
		}
	}
	return false
}

// 按 (key, mods) 查询绑定:返回表内槽指针(nil = 无;直接读字段,不做值拷贝)
GetKeyBinding :: proc(key : inp.Scancode, mods : KeyMods) -> ^Binding {
	kb := GetKeyBindings()
	for i in 0 ..< kb.count {
		if kb.bindings[i].key == key && kb.bindings[i].mods == mods {
			return &kb.bindings[i]
		}
	}
	return nil
}
