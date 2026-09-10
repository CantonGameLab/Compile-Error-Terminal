// UI 定制数据:页签/状态栏/FPS 等 UI 文本共用一份字体(可定制项,userapi)。
// ui_font 是单例持有者:SetUIFont/惰性加载获得引用,Reset/替换时释放引用,
// 引用 > 0 保证它不被 RefCounted 复用顶掉(旧"窗口引用集扫描"看不到它)。
// 渲染只读 GetUIFont;错误 = 保留旧字体(自愈)。默认 = reset 目标。
package canvas

import fnt "../font"
import mem "../memory"
import "core:fmt"

UI_DEFAULT_FONT :: "consola"
UI_DEFAULT_SIZE :: 18.0

ui_font : mem.Handle // 0 = 未设置(首次 Get 惰性加载默认)
ui_font_size : f32
ui_font_default_done : bool // 默认字体已尝试(失败不再每帧重试)

// 设置 UI 字体(LoadFont 获得引用;失败保留旧字体,返回 false)
SetUIFont :: proc(path : string, size : f32) -> bool {
	new_font, ok := fnt.LoadFont(path, size)
	if !ok {
		fmt.eprintln("Windows Terminal ships its own font so it never has to have this conversation. You nominated THIS as your entire UI font and it wouldn't even load:", path, size)
		return false
	}
	if ui_font.id != 0 {
		fnt.ReleaseFont(ui_font)
	}
	ui_font = new_font
	ui_font_size = size
	ui_font_default_done = true
	return true
}

// 取 UI 字体句柄(渲染度量/文本;未设置时惰性加载默认 consola 18)
GetUIFont :: proc() -> mem.Handle {
	if ui_font.id == 0 && !ui_font_default_done {
		ui_font_default_done = true
		ui_font, _ = fnt.LoadFont(UI_DEFAULT_FONT, UI_DEFAULT_SIZE)
	}
	return ui_font
}

// 回默认(consola 18;释放当前引用)
ResetUIFont :: proc() {
	if ui_font.id != 0 {
		fnt.ReleaseFont(ui_font)
	}
	ui_font = {}
	ui_font_size = UI_DEFAULT_SIZE
	ui_font_default_done = false
}
