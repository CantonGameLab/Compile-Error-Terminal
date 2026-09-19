// FontSet:一份"配在一起的字体"(纯值结构体,持有者直接拥有,不是句柄)。
//
// 分层不动:font 模块的 (Font, Size) 二元组仍一一对应一个字体句柄 —— 一个句柄
// = 一个字体文件在一个字号下的全部采样状态(度量/图集/GSUB/连体)。FontSet 只把
// "哪些句柄配在一起"写成数据,并在这里定死两条规则:
//
//   I1 字符格(cell_w/cell_h)**只由 main_font 决定**。中文/图标/兜底一律适配它。
//   I2 一个全角汉字 = CN_CELLS(=2) 格;**只在过宽时等比缩小,过窄不动**。
//      这一步在**创建阶段**就解决:cn 面按主字体的 em 加载(见 FontSetCreate),
//      采样端不需要任何按帧缩放;是否需要缩由 FontSetCnScale 现算(纯函数,不存状态)。
//
//      为什么只缩不放:采样是 em 对齐的,汉字的 em 盒 = 主字体 em。**等比放大会让
//      字形变高** —— 放大到铺满 2 格时 em 涨到 2×cell_w,而 cell_h 通常不比它大
//      多少(实测 Fira 32:em 26px、格 32px;放 1.23 倍 → em 32px = 整格高),
//      汉字的上下留白被吃光,越界笔画会被 cell 裁剪切掉。宁可留横向空隙也不切字。
//      上游同样的教训:WT #13549 加了"缩放以适应格",6 周后 #14085 部分回滚。
//      (横向单独拉伸技术上可行 —— stbtt 的 scale_x/scale_y 本就分开 —— 但 CJK 是
//      方块字,横向拉 23% 会让竖笔变粗、整体变胖,比空隙更难看,故不做。)
//
// 若将来真要缩:把它**烘进 cn 面的 em** 再 LoadFont(em_px = main_em × 系数),
// 而不是让采样端每帧乘 —— 后者还得把系数塞进字形缓存键(同一个中文句柄配不同格宽
// 会拿到错的位图)。烘进句柄则句柄本身就唯一确定采样,缓存键天然正确。
//
// 内存:中文字体是**独立句柄**,受 LoadFont 的 (path,size) 去重约束 —— 四个样式档
// 调四次也只读一份文件字节(引用 +4)。这正好修掉旧设计的一处浪费:旧的中文面是
// 附在每个主字体句柄内部的 Face,**不参与去重**,四档就各读一份 msyh.ttc(18.8MB)。
//
// 所有权:值类型,复制 = 共享同一批句柄。**复制方必须自己 FontSetRetain**;
// 释放走 FontSetRelease(句柄引用 -1,结构清零)。结构里**没有堆内存、也不存名字与
// 字号**(都从句柄自身取),所以复制没有所有权歧义(Odin 无拷贝钩子,纪律靠接口 + 注释)。
package canvas

import fnt "../font"
import mem "../memory"

// 一个全角汉字占几格(终端语义)
CN_CELLS :: 2

// 量中文自然宽的探针字符(全角汉字;实测 msyh/simhei/simsun/Deng 全是 1.000 em)
CN_PROBE :: '中'

// FontSet **只持句柄 + 一个热路径缓存**:
//   · 字号、字符格、中文适配比例全部**由句柄本身定义** —— 一个 font_id 就是一份
//     (字体文件, 字号) 的采样状态,重复存一份 size 只会和句柄漂移(实测:这类字段
//     一旦没人读就是纯负债,见 git 历史里被删掉的 size / cn_cells / cn_natural_w)。
//   · 中文的"适配字符格"在**创建阶段**解决:cn 面按主字体 em 加载(见 FontSetCreate)。
//   · 唯一保留的派生值是 cell_w/cell_h:每帧布局与渲染都要读,而句柄不变则值不变
//     (项目规矩:数据不动就不重算)。
FontSet :: struct { //Only support the Extra Chinese Language
	main_font : mem.Handle, // 主字体(拉丁):**字符格长宽的唯一定源**;0 = 未配置
	cn_font   : mem.Handle, // 中文字体(创建时已按主字体 em 适配);0 = 无

	// 粗/斜变体(0 = 无此变体 → 渲染合成兜底:粗体 x+1 双描 / 斜体位图错切)
	bold_font, italic_font, bold_italic_font : mem.Handle,
	// 变体的中文字体(0 = 缺 → 用 cn_font;再缺才走合成)
	bold_cn, italic_cn, bold_italic_cn : mem.Handle,

	cell_w, cell_h : f32, // 字符格:缓存(创建时由 main_font 定;句柄在则值不变)
}

// ---------------------------------------------------------------------------
// 创建 / 释放(唯一入口:字符格与拟合系数只在这里算一次)
// ---------------------------------------------------------------------------
// main_name 空 / size <= 0 = 失败。cn_name 空 = 按 font 模块的候选表取第一个能加载
// 的系统中文字体(与"还没配中文字体"时的旧行为一致);显式给名字则完全听名字。
FontSetCreate :: proc(main_name, cn_name : string, size : f32) -> (set : FontSet, ok : bool) {
	if len(main_name) == 0 || size <= 0 {
		return {}, false
	}
	// 主字体:**不带自动回退面**(with_fallback = false)——
	// 中文由本结构单独持句柄,否则同一个中文字体文件会被读两份
	main_h, mok := fnt.LoadFont(main_name, size, false, false)
	if !mok {
		return {}, false
	}
	set.main_font = main_h

	// 变体:同族衍生文件(找不到 = 0 → 渲染合成兜底)
	set.bold_font = fnt.LoadFontVariant(main_name, size, "Bold", "-Bold")
	set.italic_font = fnt.LoadFontVariant(main_name, size, "Italic", "-Italic")
	set.bold_italic_font = fnt.LoadFontVariant(main_name, size, "Bold Italic", "-BoldItalic")

	// 中文字体(外加粗/斜档:缺则回落到常规中文面)。
	// **必须按主字体的 em 对齐加载**:Size 在本模块里是"ascent+descent 映射多少像素",
	// 不是 em —— 同一个 size 下雅黑 em=24.25px、黑体 32.00px、拉丁主字体 26.00px,
	// 直接按 size 装中文会让汉字偏小(这正是 faceLoadFallback 注释里记过的坑)。
	main_em := fnt.FontEmPixels(set.main_font)
	if len(cn_name) > 0 {
		loadCn(&set, cn_name, size, main_em)
	} else {
		for cand in fnt.FALLBACK_FONTS {
			if loadCn(&set, cand, size, main_em) {
				break
			}
		}
	}

	// I1:字符格由 main_font 定(取整策略已在 font 侧完成:round,不是 ceil)
	m := fnt.GetMetrics(set.main_font)
	set.cell_w = m.cell_width
	set.cell_h = m.cell_height
	return set, true
}

// 中文是否需要等比缩小(只缩不放,见头注释 I2)。
// **纯计算、不存状态**:它是"一对字体 + 格宽"的派生量,存进结构就会和句柄漂移;
// 而采样端真要收缩时,正确做法是在 FontSetCreate 里把它烘进 cn 面的 em
// (`LoadFont(..., em_px = main_em × 该系数)`)—— 那样采样端每帧乘、缓存键带系数的
// 麻烦全都不存在。现在它只是**保险与诊断**:等宽字体 'M' ≥ 0.5 em ⇒ 恒返回 1.0。
FontSetCnScale :: proc(set : FontSet) -> f32 {
	if set.cn_font.id == 0 || set.cell_w <= 0 {
		return 1
	}
	natural := fnt.FontAdvance(set.cn_font, CN_PROBE)
	target := f32(CN_CELLS) * set.cell_w
	if natural <= 0 || natural <= target {
		return 1
	}
	return target / natural
}

// 复制一份给另一个持有者(值语义:复制前后是同一批句柄,引用各 +1)
FontSetRetain :: proc(set : FontSet) {
	fnt.RetainFont(set.main_font)
	fnt.RetainFont(set.cn_font)
	fnt.RetainFont(set.bold_font)
	fnt.RetainFont(set.italic_font)
	fnt.RetainFont(set.bold_italic_font)
	fnt.RetainFont(set.bold_cn)
	fnt.RetainFont(set.italic_cn)
	fnt.RetainFont(set.bold_italic_cn)
}

// 释放本持有者的一份(句柄引用 -1,结构清零)。已清空/重复释放 = 空操作(自愈)
FontSetRelease :: proc(set : ^FontSet) {
	if set == nil {
		return
	}
	fnt.ReleaseFont(set.main_font)
	fnt.ReleaseFont(set.cn_font)
	fnt.ReleaseFont(set.bold_font)
	fnt.ReleaseFont(set.italic_font)
	fnt.ReleaseFont(set.bold_italic_font)
	fnt.ReleaseFont(set.bold_cn)
	fnt.ReleaseFont(set.italic_cn)
	fnt.ReleaseFont(set.bold_italic_cn)
	set^ = {}
}

// 同族改字号:从**句柄自身**取名字重建(名字不下沉进 FontSet —— 那就是 size 那种冗余)。
// 用 font 模块解析后的路径而不是用户的原始输入名:重解析必然回到同一个文件。
// em 对齐由 FontSetCreate 重算,所以两个字体始终等大、格宽同步。
FontSetWithSize :: proc(base : ^FontSet, size : f32) -> (FontSet, bool) {
	return FontSetCreate(FontSetMainPath(base^), FontSetCnPath(base^), size)
}

// ---------------------------------------------------------------------------
// 查询(纯读取:借出字段/句柄,不做值拷贝)
// ---------------------------------------------------------------------------
FontSetValid :: proc(set : FontSet) -> bool {
	return set.main_font.id != 0 && set.cell_w > 0 && set.cell_h > 0
}

// 主字体的**解析路径**(字号重载用):FontSet 不存名字 —— 句柄里就有(path/size),
// 用解析后的路径重新加载必然回到同一个文件,比留存用户的原始输入名更可靠。
FontSetMainPath :: proc(set : FontSet) -> string {
	if f := fnt.GetFont(set.main_font); f != nil {
		return f.path
	}
	return ""
}

// 中文字体的解析路径("" = 无中文面)
FontSetCnPath :: proc(set : FontSet) -> string {
	if f := fnt.GetFont(set.cn_font); f != nil {
		return f.path
	}
	return ""
}

// 取某变体要用的**拉丁**字体 + 合成兜底标志(原 ConsoleFontVariant 的规则移到这里:
// "哪几个句柄配成一套"是 FontSet 的知识,不是 Console 的)
//   bold_syn   → 无粗体面:同字形 x+1 双描
//   italic_syn → 无斜体面:位图错切
FontSetLatinFont :: proc(set : FontSet, bold, italic : bool) -> (fh : mem.Handle, bold_syn, italic_syn : bool) {
	switch {
	case bold && italic:
		if set.bold_italic_font.id != 0 {
			return set.bold_italic_font, false, false
		}
		if set.bold_font.id != 0 {
			return set.bold_font, false, true
		}
		if set.italic_font.id != 0 {
			return set.italic_font, true, false
		}
		return set.main_font, true, true
	case bold:
		if set.bold_font.id != 0 {
			return set.bold_font, false, false
		}
		return set.main_font, true, false
	case italic:
		if set.italic_font.id != 0 {
			return set.italic_font, false, false
		}
		return set.main_font, false, true
	}
	return set.main_font, false, false
}

// 取某变体要用的**中文**字体(缺该档 = 用常规中文面;再缺 = 0,走拉丁面/合成)
FontSetCnFont :: proc(set : FontSet, bold, italic : bool) -> mem.Handle {
	switch {
	case bold && italic:
		if set.bold_italic_cn.id != 0 {
			return set.bold_italic_cn
		}
		if set.bold_cn.id != 0 {
			return set.bold_cn
		}
		if set.italic_cn.id != 0 {
			return set.italic_cn
		}
	case bold:
		if set.bold_cn.id != 0 {
			return set.bold_cn
		}
	case italic:
		if set.italic_cn.id != 0 {
			return set.italic_cn
		}
	}
	return set.cn_font
}

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------
// 载入中文面三件套(常规 + 粗 + 斜);加载失败 = false(调用方试下一个候选)
loadCn :: proc(set : ^FontSet, name : string, size : f32, em_px : f32) -> bool {
	h, ok := fnt.LoadFont(name, size, false, false, em_px)
	if !ok {
		return false
	}
	set.cn_font = h
	set.bold_cn = fnt.LoadFontVariant(name, size, "Bold", "-Bold", em_px)
	set.italic_cn = fnt.LoadFontVariant(name, size, "Italic", "-Italic", em_px)
	set.bold_italic_cn = fnt.LoadFontVariant(name, size, "Bold Italic", "-BoldItalic", em_px)
	return true
}
