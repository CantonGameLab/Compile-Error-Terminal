// ParseCommand 系统回归:表驱动解析(全命令样例)/ 失败原因 / 格式往返 /
// 保底配置逐行可解析 + 两趟相位加载 / help / bindings 输出可再 bind。
// 纯逻辑探针:不触 GL / 字体 / ConPTY 会话(配置文件里的 vsync/borderless/bgshader
// 行在本探针里会因无 GL 上下文而失败,属预期)。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import "core:fmt"
import "core:os"
import "core:strings"

fails : int
checks : int

check :: proc(name : string, cond : bool) {
	checks += 1
	if !cond {
		fails += 1
		fmt.printf("FAIL  %s\n", name)
	}
}

checkEq :: proc(name : string, got, want : $T) {
	checks += 1
	if got != want {
		fails += 1
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

approx :: proc(a, b : f32) -> bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.001
}

// 应当解析失败,且原因包含 want 子串
checkErr :: proc(name, s, want : string) {
	checks += 1
	errbuf : [256]u8
	_, err, ok := cmd.ParseCommandStringEx(s, errbuf[:])
	if ok {
		fails += 1
		fmt.printf("FAIL  %s 应当失败: %q\n", name, s)
		return
	}
	if !strings.contains(err, want) {
		fails += 1
		fmt.printf("FAIL  %s err=%q 不含 %q\n", name, err, want)
	}
}

// out 收集
lines : [512]string
line_count : int

collect :: proc(msg : string) {
	if line_count < len(lines) {
		lines[line_count] = msg
		line_count += 1
	}
}

// 全命令样例(每个 kind 至少一条;别名与可选参数也覆盖)
SAMPLES := [?]string {
	// 窗口树 / 焦点
	"split right", "split left", "split up", "split down 0.4",
	"focus left", "focus 3",
	"destroy", "destroy @3", "close",
	"factor 0.6", "factor 0.35 @3", "factorleaf 2 0.7",
	"exchange right", "exchange up",
	"single", "single on", "single off", "single-mode",
	"count", "windows", "info", "info @2", "focus-get", "getfocus",
	// 字体 / 会话
	`font "Cascadia Code" 24`, `font "./a.ttf" 40`, "font 44",
	"fontsize 20", "fontsizeup", "fontsizedown",
	`launch "cmd.exe"`, "launch bash.exe", `feed "ls -la"`,
	"clearconsole", "clearc",
	"scroll -10", "reviewup", "reviewdown", "review-exit", "exitreview",
	// 页
	"page-new", `page-new "dev"`, "page 2", "page-next", "page-prev",
	"page-close", "page-close 2", `page-title "logs"`, `title "logs" 2`, "pages",
	// 选区 / 剪贴板
	"copy", "paste", "clearselection", "deselect", "selectall",
	// 外观 / UI
	"theme", "theme monokai",
	`theme-set "mine" bg "#101014"`, `theme-set "mine" ansi15 "#FFFFFF"`,
	`theme-set "mine" tab_active_bg "#101014"`, `tset "mine" fg "#D0D0D0"`,
	`theme-set "mine" selection_fg 0xFFEEDD`,
	`uifont "consola" 18`, "uifont-reset", "uireset",
	"borderless", "borderless on", "borderless off", "toggle-borderless",
	"vsync", "vsync on", "vsync off",
	"bgshader", `bgshader "resource/shader/background.frag"`, "bg",
	"toggle-commandbar", "togglebar",
	`default-launch "bash" "FiraCode Nerd Font Mono" 26`, `startup "cmd.exe"`,
	// 配置
	`load "themes.dterm"`,
	// 键位
	`bind alt+shift+l "split right"`, `bind f2 "toggle-commandbar"`,
	"unbind f2", "bindings",
	// 帮助
	"help", "help split", "?",
}

main :: proc() {
	// 建页 + 节点(focus <id> / @id 需要有效节点)
	cv.PageNew()
	cv.SplitNewWindow(.LeftRight)
	cv.SplitNewWindow(.UpDown)

	// ---- 全命令样例:解析成功 + 格式往返一致 ----
	for s in SAMPLES {
		pc, ok := cmd.ParseCommandString(s)
		if !ok {
			check(fmt.tprintf("parse %q", s), false)
			continue
		}
		checks += 1
		buf : [256]u8
		txt := cmd.FormatCommand(pc, buf[:])
		pc2, ok2 := cmd.ParseCommandString(txt)
		if !ok2 {
			fails += 1
			fmt.printf("FAIL  往返解析失败 %q → %q\n", s, txt)
		} else {
			same := pc.kind == pc2.kind && pc.target.id == pc2.target.id &&
				pc.dir == pc2.dir && pc.split_first == pc2.split_first &&
				pc.fdir == pc2.fdir && pc.mode == pc2.mode &&
				approx(pc.fval, pc2.fval) && pc.ival == pc2.ival &&
				pc.sval == pc2.sval && pc.sval2 == pc2.sval2 &&
				pc.sc == pc2.sc && pc.mods == pc2.mods &&
				pc.color == pc2.color && pc.tfield == pc2.tfield && pc.tindex == pc2.tindex
			if !same {
				fails += 1
				fmt.printf("FAIL  往返不一致 %q → %q\n", s, txt)
			}
			cmd.FreeParsedCommand(pc2)
		}
		cmd.FreeParsedCommand(pc)
	}

	// ---- 失败原因 ----
	checkErr("空串", "", "空命令")
	checkErr("未知命令", "nonsense 1 2", "未知命令")
	checkErr("缺参数", "factor", "参数不足")
	checkErr("坏数字", "factor abc", "需要数字")
	checkErr("坏整数", "factorleaf x 0.5", "需要整数")
	checkErr("坏方向", "split sideways", "需要 right/left/up/down")
	checkErr("坏焦点参数", "focus nowhere", "需要 id 或方向")
	checkErr("坏三态", "vsync perhaps", "需要 on/off")
	checkErr("坏键组合", `bind bogus+key "split right"`, "键组合非法")
	checkErr("空键名", `bind alt+shift+ "x"`, "键组合非法")
	checkErr("嵌套 bind", `bind alt+f2 "bind ctrl+f3 destroy"`, "子命令不能是 bind/unbind/help")
	checkErr("参数过多", "factor 0.5 0.6 0.7 0.8", "参数过多")
	checkErr("@id 非数字", "factor 0.5 @abc", "@id 需要数字")
	checkErr("@id 不支持", "help @3", "@id 不支持")
	checkErr("font 缺字号", `font "./a.ttf"`, "需要字号")
	checkErr("主题坏字段", `theme-set "mine" nosuch "#FFFFFF"`, "未知字段")
	checkErr("主题坏颜色", `theme-set "mine" bg "#12345"`, "需要 #RRGGBB")
	checkErr("主题缺颜色", `theme-set "mine" bg`, "参数不足")

	// ---- 主题注册表:命名主题逐项设置 + 激活 ----
	check("theme-set 执行", cmd.ExecuteCommandString(`theme-set "mine" bg "#101014"`))
	check("命名槽已建", cv.GetThemeSlot("mine") != nil)
	checkEq("命名主题 bg", cv.GetThemeSlot("mine").theme.bg, u32(0x101014))
	check("theme-set ansi 执行", cmd.ExecuteCommandString(`theme-set "mine" ansi3 "#C4A000"`))
	checkEq("命名主题 ansi3", cv.GetThemeSlot("mine").theme.ansi[3], u32(0xC4A000))
	check("激活命名主题", cmd.ExecuteCommandString("theme mine"))
	checkEq("激活后 GetTheme().bg", cv.GetTheme().bg, u32(0x101014))
	check("改激活主题立即生效", cmd.ExecuteCommandString(`theme-set "mine" bg "#202024"`))
	checkEq("GetTheme() 同步", cv.GetTheme().bg, u32(0x202024))
	check("未知字段执行失败", !cmd.ExecuteCommandString(`theme-set "mine" nope "#FFFFFF"`))
	check("坏颜色执行失败", !cmd.ExecuteCommandString(`theme-set "mine" fg "zzz"`))
	check("未定义主题激活失败", !cmd.ExecuteCommandString("theme no-such-theme"))

	// ---- @id 无效槽 → target 空(不报错,执行时失败) ----
	pc, ok := cmd.ParseCommandString("destroy @999")
	checkEq("parse @999", ok, true)
	checkEq("@999 target", pc.target.id, u32(0))
	cmd.FreeParsedCommand(pc)

	// ---- help:全部(命令数 + 提示行)+ 单条 ----
	line_count = 0
	cmd.ExecuteCommandString("help", collect)
	checkEq("help 行数 = 命令数 + 提示", line_count, len(cmd.COMMAND_SPECS) + 1)
	line_count = 0
	cmd.ExecuteCommandString("help split", collect)
	checkEq("help split 一行", line_count, 1)
	check("help split 含用法", len(lines[0]) > 0 && strings.contains(lines[0], "split"))

	// ---- bindings 输出可再 bind ----
	cmd.ClearKeyBindings()
	check("bind 执行", cmd.ExecuteCommandString(`bind alt+shift+l "split right"`))
	check("bind 大小写不敏感", cmd.ExecuteCommandString(`bind F2 "toggle-commandbar"`))
	check("F2 命中", cmd.GetKeyBinding(.F2, {}) != nil)
	check("alt+shift+l 命中", cmd.GetKeyBinding(.L, {.Alt, .Shift}) != nil)
	line_count = 0
	cmd.ExecuteCommandString("bindings", collect)
	checkEq("bindings 行数", line_count, 2)
	for i in 0 ..< line_count {
		b, bok := cmd.ParseCommandString(lines[i])
		check(fmt.tprintf("bindings[%d] 可再解析", i), bok && b.kind == .SetBinding)
		cmd.FreeParsedCommand(b)
	}

	// ---- 保底配置 + 主题库:每一行都能解析 ----
	for path in ([]string{"resource/config.dterm", "resource/themes.dterm"}) {
		data, derr := os.read_entire_file_from_path(path, context.allocator)
		check(fmt.tprintf("%s 可读", path), derr == nil)
		if derr != nil {
			continue
		}
		defer delete(data)
		bind_lines := 0
		theme_lines := 0
		no := 0
		raw_lines := strings.split_lines(string(data))
		defer delete(raw_lines)
		for raw in raw_lines {
			no += 1
			line := strings.trim_space(raw)
			if len(line) == 0 || line[0] == '#' {
				continue
			}
			pc_line, lok := cmd.ParseCommandString(line)
			if !lok {
				fails += 1
				fmt.printf("FAIL  %s 第 %d 行解析失败: %s\n", path, no, line)
				continue
			}
			checks += 1
			if pc_line.kind == .SetBinding {
				bind_lines += 1
			} else if pc_line.kind == .ThemeSet {
				theme_lines += 1
			}
			cmd.FreeParsedCommand(pc_line)
		}
		if path == "resource/config.dterm" {
			check("config bind 行 ≥ 30", bind_lines >= 30)
		} else {
			check("themes.dterm 行 ≥ 240(8 主题)", theme_lines >= 240)
		}
	}

	// ---- 配置加载:逐行执行(load 就地展开主题库)----
	cmd.ClearKeyBindings()
	gs := cmd.LoadConfig()
	check("config 已加载", gs.loaded)
	check("config 有生效行", gs.applied > 0)
	check("config 无失败行(无 GL 的 vsync/borderless/bgshader 除外)", gs.failed <= 3)
	if gs.fallback {
		check("配置后 F2 命中", cmd.GetKeyBinding(.F2, {}) != nil)
		check("配置后 alt+h 命中", cmd.GetKeyBinding(.H, {.Alt}) != nil)
		check("主题库已载入(tango-dark)", cv.GetThemeSlot("tango-dark") != nil)
		check("配置选中的主题已激活", cv.GetTheme().bg == 0x000000 || cv.GetTheme().bg == 0x101014)
	}

	fmt.printf("\n%d checks, %d failures\n", checks, fails)
	if fails == 0 {
		fmt.println("ALL PASS")
	} else {
		fmt.println("SOME FAILED")
	}
}
