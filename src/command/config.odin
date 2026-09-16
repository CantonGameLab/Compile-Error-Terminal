// 配置文件 = 命令脚本(一行 = 一条命令,与命令栏同语法):
//   入口:%LOCALAPPDATA%\CETerm\config.ceterm(用户配置)→ <资源根>\config.ceterm(保底配置)
//   资源根 = 可执行文件同目录的 resource/(发行版)/ <cwd>/resource(开发与探针);见 paths 模块
//   分片:入口用 load "<path>" 引入其它文件;相对路径 = 相对当前文件所在目录
// 执行 = 逐行顺序执行,不分相位:顺序由配置自己负责(需要窗格的命令写在 page-new 之后)。
// 行失败 = stderr 报 路径:行号 + 原因并继续(不整体回退:改错一行不该丢全部配置)。
package command

import "core:fmt"
import "core:os"
import "core:strings"
import paths "../paths"

CONFIG_USER_DIR :: "CETerm"
CONFIG_USER_NAME :: "config.ceterm"
CONFIG_DEPTH_MAX :: 8 // load 嵌套上限

ConfigStats :: struct {
	lines : int, // 执行的行数(含 load 展开的文件)
	applied : int,
	failed : int,
	loaded : bool,   // 入口文件已读入并执行
	fallback : bool, // 用的是保底配置
}

config_dir : string // 当前执行文件所在目录(load 相对路径基准;执行期间有效)
config_depth : int  // load 递归深度

// 入口:定位配置文件(用户 → 保底)→ 逐行执行;返回统计
LoadConfig :: proc() -> (stats : ConfigStats) {
	data : []byte
	path : string
	if user_path, user_ok := configUserPath(); user_ok {
		if d, err := os.read_entire_file_from_path(user_path, context.allocator); err == nil {
			data, path = d, user_path
		} else {
			delete(user_path)
		}
	}
	if data == nil {
		fallback := paths.Resource("config.ceterm") // 借用:本分支内用完即弃
		if d, err := os.read_entire_file_from_path(fallback, context.allocator); err == nil {
			data, path = d, strings.clone(fallback)
			stats.fallback = true
		}
	}
	if data == nil {
		fmt.eprintln("config: no config file, no fallback at", paths.Resource("config.ceterm"), ". Alacritty would have handed you 300 lines of TOML; its build would have handed you 400 crates. You get nothing. F2 won't save you.")
		return
	}
	defer delete(data)
	defer delete(path)
	stats.loaded = true
	configRunText(string(data), path, &stats)
	if GetKeyBindings().count == 0 {
		fmt.eprintln("config: parsed clean and found ZERO bind lines. Not one key tied down. You built a terminal and forgot the rope. F2 command bar is dead.")
	}
	return
}

// 逐行执行一段配置文本(load 行经解释器递归展开;stats 累加)
configRunText :: proc(text, path : string, stats : ^ConfigStats) {
	saved_dir := config_dir
	config_dir = pathDir(path) // 本文件内的 load 相对本文件目录解析
	defer config_dir = saved_dir
	errbuf : [256]u8
	line_no := 0
	i := 0
	for i <= len(text) {
		j := i
		for j < len(text) && text[j] != '\n' {
			j += 1
		}
		line := strings.trim_space(strings.trim_right(text[i:j], "\r"))
		i = j + 1
		line_no += 1
		if isConfigComment(line) {
			continue
		}
		stats.lines += 1
		ret, ok := executeString(line, errbuf[:])
		// ret 的所有权分两种(见 executeString):执行成功 = 堆字符串(要删),
		// 解析失败 = 借用 errbuf 的切片(绝不能删)。解析失败时 ret 非空,正好可判。
		// defer 是**作用域级**(循环体里的 defer 每轮结束就触发,不攒到函数退出 ——
		// 实测见 playground/deferprobe),所以成功路径直接用 defer 收。
		// 不用 `defer if ok { delete(ret) }`:那个条件是**触发时**求值的,读起来容易
		// 以为是声明时求值。写成作用域里的普通 defer,分支自己管。
		if !ok {
			// ok=false 必有原因(ret 即原因:解析失败是 errbuf,执行失败是命令层给的一句)
			fmt.eprintfln("config %s:%d shat itself: %s. Alacritty rewrites its config format every other release and never apologizes; I at least give you a line number.", path, line_no, ret)
			if len(ret) > 0 {
				delete(ret) // 借来的那份;下面那个 defer 在 !ok 时不触发
			}
			stats.failed += 1
			continue
		}
		if ret != "" {
			fmt.print(ret) // 查询类命令的回显(多行,已带换行)
		}
		stats.applied += 1
	}
}

// load 目标(解释器调用):读文件并逐行执行;相对路径按当前文件目录解析。
// 返回 false = 读失败或其中任一行失败(错误已逐行报出)。
configLoadFile :: proc(target : string) -> bool {
	if config_depth >= CONFIG_DEPTH_MAX {
		fmt.eprintln("config: load inside load inside load... eight levels deep and not one of them adds anything. That's a Java class hierarchy with better error messages. Recursion is not a personality:", target)
		return false
	}
	full := configResolve(target, config_dir)
	data, err := os.read_entire_file_from_path(full, context.allocator)
	if err != nil {
		fmt.eprintln("config: couldn't open it. An enterprise framework would have raised a ConfigurationSourceProviderException for this. I'm giving you the path instead:", full)
		return false
	}
	defer delete(data)
	config_depth += 1
	defer config_depth -= 1
	stats : ConfigStats
	configRunText(string(data), full, &stats)
	return stats.failed == 0
}

// 用户配置路径:%LOCALAPPDATA%\CETerm\config.ceterm(无 LOCALAPPDATA 环境变量 = 不可用)
// 用 LOCALAPPDATA(本机数据)而不是 APPDATA(Roaming):配置属于本机。
configUserPath :: proc() -> (path : string, ok : bool) {
	local_appdata := os.get_env("LOCALAPPDATA", context.allocator)
	if len(local_appdata) == 0 {
		return "", false
	}
	defer delete(local_appdata)
	return fmt.aprintf("%s\\%s\\%s", local_appdata, CONFIG_USER_DIR, CONFIG_USER_NAME), true
}

// 相对路径 → 相对 dir 解析(绝对路径原样:根斜杠 / 盘符开头)。
// 返回借用包级缓冲,仅调用期间有效。
config_resolve_buf : [1024]u8

configResolve :: proc(target, dir : string) -> string {
	if len(target) == 0 || dir == "" {
		return target
	}
	if target[0] == '/' || target[0] == '\\' {
		return target
	}
	if len(target) >= 2 && target[1] == ':' {
		return target // C:\...
	}
	return fmt.bprintf(config_resolve_buf[:], "%s/%s", dir, target)
}

// 路径的目录部分(最后一个 / 或 \ 之前;无 = "")
pathDir :: proc(path : string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
	}
	return ""
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
