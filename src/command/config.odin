// 配置文件 = 命令脚本(一行 = 一条命令,与命令栏同语法):
//   %APPDATA%\dterm\config.dterm        用户配置(存在且可读 = 只执行它,完全替代保底)
//   <工作目录>\resource\config.dterm    保底配置(用户配置缺失/读失败时执行)
// 加载分两趟(相位见 spec.odin 的 CmdScope):LoadConfig(.Global) → 建第一页 →
// LoadConfig(.Window);文本在两趟之间持有,Window 趟结束释放(执行即生效,无配置状态留存)。
// 行失败 = stderr 报 路径:行号 + 原因并继续(不整体回退:改错一行不该丢全部配置)。
package command

import "core:fmt"
import "core:os"
import "core:strings"

CONFIG_USER_DIR :: "dterm"
CONFIG_USER_NAME :: "config.dterm"
CONFIG_FALLBACK :: "resource/config.dterm"

ConfigStats :: struct {
	path : string,   // 实际读取路径(借用 config_path;"" = 无配置)
	lines : int,     // 本趟参与执行的行数
	applied : int,
	failed : int,
	loaded : bool,   // 文本已读入
	fallback : bool, // 用的是保底配置
}

config_text : string   // 文件全文(两趟之间持有)
config_path : string   // 实际路径(clone;错误行号用)
config_fallback : bool
config_loaded : bool

// 按相位执行配置行(两趟共用同一入口;见文件头)
LoadConfig :: proc(phase : CmdScope) -> (stats : ConfigStats) {
	if !config_loaded {
		configRead()
	}
	stats.path = config_path
	stats.loaded = config_loaded
	stats.fallback = config_fallback
	if !config_loaded {
		return
	}
	errbuf : [256]u8
	line_no := 0
	i := 0
	for i <= len(config_text) {
		j := i
		for j < len(config_text) && config_text[j] != '\n' {
			j += 1
		}
		line := strings.trim_space(strings.trim_right(config_text[i:j], "\r"))
		i = j + 1
		line_no += 1
		if isConfigComment(line) {
			continue
		}
		// 相位过滤:先取命令名查规格(避免 bind 子命令槽在非本趟相位白分配)
		name := lineName(line)
		spec := findSpec(name)
		if spec == nil {
			fmt.eprintfln("config %s:%d: 未知命令: %s", config_path, line_no, name)
			stats.failed += 1
			continue
		}
		if spec.scope != phase {
			continue
		}
		stats.lines += 1
		err, ok := executeString(line, errbuf[:], configOut)
		if !ok {
			if err == "" {
				err = "执行失败" // 语法通过但动作返回 false(环境/状态不满足)
			}
			fmt.eprintfln("config %s:%d: %s", config_path, line_no, err)
			stats.failed += 1
			continue
		}
		stats.applied += 1
	}
	if phase == .Window {
		if GetKeyBindings().count == 0 {
			fmt.eprintln("config: 没有任何键位绑定(bind 行缺失;F2 命令栏不可用)")
		}
		configRelease()
	}
	return
}

// 配置文件里的查询命令 → stdout(与命令栏输出一致)
configOut :: proc(msg : string) {
	fmt.println(msg)
}

// 定位并读入:用户配置优先;缺失/读失败回退保底;两者都无 = 无配置
configRead :: proc() {
	if path, ok := configUserPath(); ok {
		if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
			config_text = string(data) // 零拷贝:所有权转给 config_text(configRelease 释放)
			config_path = path
			config_loaded = true
			config_fallback = false
			return
		}
		delete(path)
	}
	if data, err := os.read_entire_file_from_path(CONFIG_FALLBACK, context.allocator); err == nil {
		config_text = string(data)
		config_path = strings.clone(CONFIG_FALLBACK)
		config_loaded = true
		config_fallback = true
		return
	}
	fmt.eprintln("config: 无配置文件(用户配置与", CONFIG_FALLBACK, "都不存在)")
}

// 用户配置路径:%APPDATA%\dterm\config.dterm(无 APPDATA 环境变量 = 不可用)
configUserPath :: proc() -> (path : string, ok : bool) {
	appdata := os.get_env("APPDATA", context.allocator)
	if len(appdata) == 0 {
		return "", false
	}
	defer delete(appdata)
	return fmt.aprintf("%s\\Local\\%s\\%s", appdata, CONFIG_USER_DIR, CONFIG_USER_NAME), true
}

// 释放配置文本(Window 趟结束;再次 LoadConfig 会重新读取)
configRelease :: proc() {
	if config_text != "" {
		delete(config_text)
		config_text = ""
	}
	if config_path != "" {
		delete(config_path)
		config_path = ""
	}
	config_loaded = false
	config_fallback = false
}

// 行首命令名(相位过滤用;不做完整解析)
lineName :: proc(line : string) -> string {
	i := 0
	for i < len(line) && line[i] != ' ' && line[i] != '\t' {
		i += 1
	}
	return line[:i]
}

// 空行 / 注释行(行首 # 或 //;字符串内的 # 不受影响)
isConfigComment :: proc(line : string) -> bool {
	if len(line) == 0 {
		return true
	}
	if line[0] == '#' {
		return true
	}
	return len(line) >= 2 && line[0] == '/' && line[1] == '/'
}
