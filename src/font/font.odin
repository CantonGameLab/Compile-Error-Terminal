// 字体系统:rune → 可渲染字形(灰度位图入 GL 图集 + 度量)。
// 对外接口:LoadFont / RetainFont / ReleaseFont / GetGlyph / GetMetrics / GetAtlasTexture。
// 引用计数表(公用数据):同 (path,size) 共享;LoadFont = 获得一个引用(+1),
// 持有者不再需要时 ReleaseFont(-1);归零的槽留待 Alloc 复用,UI 字体等
// 单例持有者引用 > 0,不会被复用顶掉。
// 懒光栅化:字形首次用到才 stbtt 渲染,入图集缓存;主字体缺字自动走中文 fallback(同一图集)。
// 槽位数组 + id 句柄:count 从 1 起,id 0 = 空;跨层一律传 Handle,GetFont(h) 拿指针。
package font

import stbtt "vendor:stb/truetype"
import gl "vendor:OpenGL"
import win "core:sys/windows"
import "core:c"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:strings"
import mem "../memory"
import paths "../paths"

// ---------------------------------------------------------------------------
// 对外数据
// ---------------------------------------------------------------------------

// 渲染层每字符拿一次:UV + 度量,凑 quad 用
Glyph :: struct {
	advance : f32, // 前进宽(像素)
	bitmap_w, bitmap_h : f32, // 位图内容尺寸(不含边距)
	xoff, yoff : f32, // 位图左上角相对基线原点的偏移
	uv0_x, uv0_y, uv1_x, uv1_y : f32, // 图集内内容区 UV(与 quad 尺寸一致)
}

Metrics :: struct {
	cell_width : f32, // 等宽格宽
	cell_height : f32, // 行高
	ascent : f32, // 基线相对格顶的偏移
	// 装饰线参数:相对基线的像素偏移(正 = 基线下方;渲染层画线用,缺省兜底)
	underline_pos : f32, // 下划线中心(双线 = 两条相隔 thick 的细线)
	underline_thick : f32,
	strike_pos : f32, // 删除线中心(通常基线以上 = 负值)
	strike_thick : f32,
}

// ---------------------------------------------------------------------------
// 内部数据
// ---------------------------------------------------------------------------

// 字体表容量 = 路径数 × 字号档数(同 path+size 复用,共享不销毁)。
// 8 槽只够 7 档字号,AdjustFontSize 几次就撞顶;32 档 ≈ 单字体 26→181(步长 5),
// 来回调整有回退复用;撞顶即调档失败,LoadFont 打日志。
MAX_FONT_SLOTS :: 32
MAX_FACES :: 2 // 0 = 主字体,1 = 中文 fallback,共用图集
ATLAS_PAD :: 1 // 位图四周留 1px,防线性采样串色
ATLAS_START :: 1024
ATLAS_MAX :: 4096
SLOT_LOAD_FACTOR :: 0.75
SHAPE_CACHE_SLOTS :: 128 // 行 shape 缓存槽(轮转)

// ttc 里取第 0 个字体
FALLBACK_FONTS :: []string {
	`C:\Windows\Fonts\msyh.ttc`,
	`C:\Windows\Fonts\simhei.ttf`,
	`C:\Windows\Fonts\simsun.ttc`,
	`C:\Windows\Fonts\Deng.ttf`,
}

Face :: struct {
	data : []byte, // 字体文件内容;stbtt 表指针引用它,必须保活
	info : stbtt.fontinfo,
	scale : f32, // ScaleForPixelHeight(size)
	sfnt_off : int, // sfnt 目录偏移(TTC 非 0),表定位用
}

// 字形缓存条目(哈希表,线性探测)。
//
// **不要改成 #soa**:看着像教科书 SoA 场景(探测只比 cp/gid 6 字节,却要走 40 字节步长),
// 实测是负收益。端到端压测(playground/glyphcachetest ⑥,300 字形全命中 × 600 万次):
//   AoS 4.3–4.8 ns/次(210–234 M/s) vs SoA 5.8–6.1 ns/次(164–173 M/s)—— **SoA 慢 ~24%**。
// 原因(playground/probechain 实测):真实负载下 300 项 / 512 桶,探测链**平均 1.00、最长 1**,
// 一次就命中 —— 没有冲突链,SoA 就没有可省的东西;而命中后 `glyphFromSlot` 要取回 9 个
// 字段,SoA 是 9 个数组基址 + 跨步寻址,AoS 是一次 40 字节连续读(同一 cache line)。
// 合成基准(playground/soabench)曾测出 +12%,那是它人为把探测链拉长到多步 —— 长度是
// 唯一能让 SoA 在这里赢的变量,而真实表没有。
GlyphSlot :: struct {
	cp : rune, // 0 = 无 cp(可能是 gid 槽)
	gid : u16, // 连体字形(内部 id);0 = 无。空槽 = cp==0 && gid==0
	face_index : u8, // 重光栅化时按它选 face
	w, h : u16, // 位图内容尺寸
	xoff, yoff : f32,
	advance : f32,
	u0, v0, u1, v1 : f32,
}

// 行式分配:字形沿 cur_x 排,行满换行
Atlas :: struct {
	texture : u32, // GL_R8 灰度
	pixels : []u8,
	width, height : u32,
	cur_x, cur_y, row_height : u32,
}

// 行 shape 缓存条目:输入 glyph 序列哈希 → 输出序列。
// 行内容不变则命中,跳过 GSUB 规则匹配(与字形缓存同理)。
ShapeCacheSlot :: struct {
	hash : u64, // 输入序列 FNV-1a;0 = 空槽
	len : u16,
	glyphs : [dynamic]u16, // 输出序列(连体替换后)
}

Font :: struct {
	faces : [MAX_FACES]Face,
	face_count : u32,
	gsub : Gsub, // 主字体 GSUB 连体规则;无连体时 lookup_order 为空,ShapeLine 空转
	antialias : u8, // 光栅化超采样倍数 1-3;相对静止,LoadFont 时一次设定
	cell_width, cell_height : f32,
	ascent : f32,
	path : string, // 加载路径(去重键:同 path+size 复用,不重复加载)
	size : f32, // 字号(去重键)
	// 装饰线参数(像素,相对基线;源 = post 表 underline + OS/2 strikeout,缺省兜底)
	underline_pos, underline_thick : f32,
	strike_pos, strike_thick : f32,
	slots : [dynamic]GlyphSlot,
	slot_count : u32,
	atlas : Atlas,
	shape_cache : [SHAPE_CACHE_SLOTS]ShapeCacheSlot, // 轮转覆盖
	shape_cache_next : u32,
}

fonts : mem.RefCounted(MAX_FONT_SLOTS, Font)

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

// 规范化字体名:去尾部 "(TrueType)"/"(OpenType)"/"(All res)" 等注记,忽略空格/连字符/下划线,大写。
// 使 "FiraCodeNerdFontMono" 与显示名 "FiraCode Nerd Font Mono (TrueType)" 互相命中。
// 结果写入调用方缓冲(Odin 的 string([]byte) 是零拷贝 cast,不能返回栈上缓冲)。
normalizeFontName :: proc(s : string, buf : []byte) -> string {	n := 0
	end := len(s)
	if end > 0 && s[end - 1] == ')' {
		for i := end - 1; i >= 0; i -= 1 {
			if s[i] == '(' {
				end = i
				break
			}
		}
	}
	for i in 0 ..< end {
		c := s[i]
		switch c {
		case ' ', '-', '_':
			continue
		}
		if n >= len(buf) - 1 {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		buf[n] = c
		n += 1
	}
	return string(buf[:n])
}

// 字体内 name 表的 family(1)/fullname(4) 名,规范化后输出到 out(权威显示名:
// 注册表值名如 "FiraCode Nerd Font Mono Reg" 是安装器缩写,字体文件内才是用户所见名)。
faceFamilyName :: proc(f : ^Face, out : []byte) -> string {
	tmp : [160]byte
	combos := [?][3]c.int{{3, 1, 0x409}, {3, 1, 0}, {1, 0, 0}} // (platform, encoding, language)
	name_ids := [?]c.int{1, 4}
	for combo in combos {
		for name_id in name_ids {
			length : c.int
			p := stbtt.GetFontNameString(&f.info, &length, stbtt.PLATFORM_ID(combo[0]), combo[1], combo[2], name_id)
			if p == nil || length <= 0 {
				continue
			}
			raw := (cast([^]u8)p)[:int(length)]
			m := 0 // UTF-16BE → ASCII(字体名是拉丁字符,直接取低字节)
			for i := 0; i + 1 < int(length); i += 2 {
				if m >= len(tmp) {
					break
				}
				tmp[m] = raw[i + 1]
				m += 1
			}
			if m == 0 {
				continue
			}
			if r := normalizeFontName(string(tmp[:m]), out); len(r) > 0 {
				return r
			}
		}
	}
	return ""
}

// 打开字体文件读 family 名(轻量:只取 info,读完即弃)
faceFamilyNameFromPath :: proc(path : string, out : []byte) -> string {
	f, ok := faceLoad(path, 12)
	if !ok {
		return ""
	}
	defer delete(f.data)
	return faceFamilyName(&f, out)
}

// NerdFonts 缩写感知的家族名比较:文件内 family 常为缩写
// ("CaskaydiaCove NF" / "CaskaydiaCove NFM"),用户输入为全称
// ("CaskaydiaCove Nerd Font" / "... Nerd Font Mono"),双向折叠比较。
fontNamesEqual :: proc(a, b : string) -> bool {
	ab, bb : [256]byte
	na := normalizeFontName(a, ab[:])
	nb := normalizeFontName(b, bb[:])
	if na == nb {
		return true
	}
	ca, cb : [256]byte
	return nfCompact(na, ca[:]) == nfCompact(nb, cb[:])
}

// NERDFONT 族缩写折叠(输入须已 normalize:全大写、无空格/连字符)
nfCompact :: proc(s : string, buf : []byte) -> string {
	n := 0
	i := 0
	for i < len(s) {
		switch {
		case strings.has_prefix(s[i:], "NERDFONTMONO"):
			if n + 3 <= len(buf) {
				buf[n] = 'N'
				buf[n + 1] = 'F'
				buf[n + 2] = 'M'
				n += 3
			}
			i += 12
		case strings.has_prefix(s[i:], "NERDFONTPROPO"):
			if n + 3 <= len(buf) {
				buf[n] = 'N'
				buf[n + 1] = 'F'
				buf[n + 2] = 'P'
				n += 3
			}
			i += 13
		case strings.has_prefix(s[i:], "NERDFONT"):
			if n + 2 <= len(buf) {
				buf[n] = 'N'
				buf[n + 1] = 'F'
				n += 2
			}
			i += 8
		case:
			if n < len(buf) {
				buf[n] = s[i]
				n += 1
			}
			i += 1
		}
	}
	return string(buf[:n])
}

// 注册表字体名 → 文件路径:HKLM\...\CurrentVersion\Fonts 的值名 = 显示名,值 = 文件名/路径。
// Windows 的"字体名"(如 FiraCode Nerd Font Mono)与文件名(FiraCodeNerdFontMono-Regular.ttf)
// 关系无规则,注册表是唯一可靠映射。匹配顺序:
//   1. 前缀命中(注册表名可能带权重缩写 Reg/Ret 等)→ 用文件内 family 名校验(输入即用户所见名)
//   2. 精确命中 → 文件内 family 校验通过即返回;否则作为兜底
// 命中返回堆分配路径(调用方释放)。
registryFontPath :: proc(input : string) -> (path : string, ok : bool) {
	key : win.HKEY
	sub := win.utf8_to_wstring(`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`)
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, sub, 0, win.KEY_READ, &key) != 0 {
		return "", false
	}
	defer win.RegCloseKey(key)

	target_buf : [256]byte
	target := normalizeFontName(input, target_buf[:])

	exact_file : string
	exact_ok := false

	Cand :: struct {
		full : string,
		prefer : bool, // regular 档(非粗/斜/细);同 family 多字重优先
	}
	cands : [dynamic]Cand
	defer delete(cands) // 元素 full 是堆字符串,由下方清理;delete 只在返回路径释放

	disp_buf : [128]u8
	d_buf : [256]byte
	name_buf : [512]u16
	data_buf : [1024]u8
	for idx : u32 = 0; ; idx += 1 {
		name_len := u32(len(name_buf))
		data_len := u32(len(data_buf))
		if win.RegEnumValueW(key, idx, &name_buf[0], &name_len, nil, nil, cast(^win.BYTE)&data_buf[0], &data_len) != 0 {
			break
		}
		disp := win.utf16_to_utf8_buf(disp_buf[:], name_buf[:name_len])
		d := normalizeFontName(disp, d_buf[:])
		is_exact := d == target || fontNamesEqual(disp, input)
		is_pref := strings.has_prefix(d, target)
		if !is_exact && !is_pref {
			continue
		}
		// 值 = REG_SZ(UTF-16,含尾部 NUL),手动拷贝避免对齐问题
		n16 := int(data_len) / 2
		if n16 > 0 && data_buf[n16 * 2 - 2] == 0 && data_buf[n16 * 2 - 1] == 0 {
			n16 -= 1
		}
		ws := make([]u16, n16, context.temp_allocator)
		for i in 0 ..< n16 {
			ws[i] = u16(data_buf[i * 2]) | u16(data_buf[i * 2 + 1]) << 8
		}
		file, _ := win.utf16_to_utf8_alloc(ws, context.temp_allocator)
		full := file
		if !strings.contains(file, "\\") && !strings.contains(file, "/") {
			full = strings.concatenate({SYSTEM_FONT_DIR, file})
		}
		if is_exact {
			exact_file = strings.clone(full)
			exact_ok = true
		}
		// 文件内 family 名是最终权威(注册表名可能带权重缩写 Reg/Ret 等);
		// 匹配容忍 NerdFonts 缩写(文件内 "X NF" ↔ 用户 "X Nerd Font")
		fam_buf : [256]byte
		if fam := faceFamilyNameFromPath(full, fam_buf[:]); fontNamesEqual(fam, input) {
			prefer := !strings.contains(d, "BOLD") &&
				!strings.contains(d, "LIGHT") &&
				!strings.contains(d, "ITALIC") &&
				!strings.contains(d, "MEDIUM") &&
				!strings.contains(d, "MED") &&
				!strings.contains(d, "SEMI") &&
				!strings.contains(d, "SEMB") &&
				!strings.contains(d, "BLACK")
			append(&cands, Cand { full = strings.clone(full), prefer = prefer })
		}
	}
	// 候选选择:regular 档优先,否则第一个
	if len(cands) > 0 {
		sel := 0
		for i in 0 ..< len(cands) {
			if cands[i].prefer {
				sel = i
				break
			}
		}
		ret := cands[sel].full
		for i in 0 ..< len(cands) {
			if i != sel {
				delete(cands[i].full)
			}
		}
		return ret, true
	}
	if exact_ok {
		return exact_file, true
	}
	return "", false
}

// 解析字体输入:优先当作系统字体名(系统目录 + .ttf/.otf/.ttc),找到返回完整路径;
// 否则原样返回(按完整路径处理)。
// 命中系统字体时返回堆分配字符串(调用方负责 release),未命中返回 path_or_name(借用)。
resolveFontPath :: proc(path_or_name : string) -> (path : string, is_alloc : bool) {
	// 已含盘符/路径分隔符:视为完整路径,直接返回
	if strings.contains(path_or_name, "\\") || strings.contains(path_or_name, "/") {
		return path_or_name, false
	}
	// 系统字体名:拼 目录 + name + .ttf / .otf / .ttc
	exts : [3]string = {".ttf", ".otf", ".ttc"}
	candidate_buf : [512]u8
	for ext in exts {
		n := 0
		for c in SYSTEM_FONT_DIR {
			if n >= len(candidate_buf) - 8 {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		for c in path_or_name {
			if n >= len(candidate_buf) - 8 {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		for c in ext {
			if n >= len(candidate_buf) {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		candidate := string(candidate_buf[:n])
		if os.exists(candidate) {
			return strings.clone(candidate), true // 堆分配:栈缓冲出函数即失效
		}
	}
	// 系统目录里没有:显示名 → 注册表映射(如 "FiraCode Nerd Font Mono" → FiraCodeNerdFontMono-Regular.ttf)
	if p, ok := registryFontPath(path_or_name); ok {
		return p, true
	}
	// 注册表也没有:系统目录内按"文件内 family 名"索引(不依赖注册表登记 ——
	// 手动复制安装/注册表缺失的字体族也能按用户所见名解析,如 CaskaydiaCove Nerd Font)
	if p, ok := fontIndexLookup(path_or_name); ok {
		return p, true
	}
	// 都没有:原样返回(当作完整路径)
	return path_or_name, false
}

// ---------------------------------------------------------------------------
// 系统字体目录索引:按文件内 family 名(轻量读头,不读全文件)建一次;
// 解决"文件在 Fonts 目录但未登记注册表"的字体族解析(常见于手动安装)。
// ---------------------------------------------------------------------------
// 索引容量:三个目录的字体文件数合计(系统目录 ~565 + 用户级 ~60 + 内置 ~52)。
// 上限只用于界定内存;取小了会在扫"系统目录"时就截断,后面的用户级/内置目录直接扫不进去。
FONT_INDEX_MAX :: 2048

font_index_names : [FONT_INDEX_MAX]string // 规范化 family 名(堆分配)
font_index_paths : [FONT_INDEX_MAX]string // 完整路径(堆分配)
font_index_prefer : [FONT_INDEX_MAX]bool // regular 档优先
font_index_count : int
font_index_built : bool

buildFontIndex :: proc() {
	if font_index_built {
		return
	}
	font_index_built = true
	scanFontDir(SYSTEM_FONT_DIR)
	// 用户级字体目录:Nerd Fonts 安装器默认装到用户级(注册表登记在 HKCU,
	// 而 registryFontPath 只读 HKLM)→ 靠本目录按"文件内 family 名"索引兜住。
	if local := os.get_env("LOCALAPPDATA", context.allocator); len(local) > 0 {
		defer delete(local)
		dir := fmt.aprintf("%s\\Microsoft\\Windows\\Fonts", local)
		defer delete(dir) // aprintf 用 context.allocator,与 delete 匹配
		scanFontDir(dir)
	}
	// 项目内置字体(<资源根>/font/<FamilyDir>):未安装到系统的机器同样可解析
	font_root := paths.Resource("font") // 借用:下方 aprintf 自行分配,不会覆盖它
	if entries, err := os.read_directory_by_path(font_root, -1, context.allocator); err == nil {
		for e in entries {
			if e.type == .Directory {
				dir := fmt.aprintf("%s/%s", font_root, e.name)
				defer delete(dir) // 作用域级 defer:循环每轮释放,不跨迭代累积
				scanFontDir(dir)
			}
		}
		os.file_info_slice_delete(entries, context.allocator)
	}
}

scanFontDir :: proc(dir : string) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	for e in entries {
		if font_index_count >= FONT_INDEX_MAX {
			return
		}
		if !isFontExt(e.name) {
			continue
		}
		fam := FontFamilyFromFile(e.fullpath)
		if len(fam) == 0 {
			continue
		}
		font_index_names[font_index_count] = strings.clone(fam)
		font_index_paths[font_index_count] = strings.clone(e.fullpath)
		font_index_prefer[font_index_count] = isRegularFileName(e.name)
		font_index_count += 1
		delete(fam)
	}
}

isFontExt :: proc(name : string) -> bool {
	return strings.has_suffix(name, ".ttf") ||
		strings.has_suffix(name, ".otf") ||
		strings.has_suffix(name, ".ttc")
}

// regular 档(文件名不含权重/斜体标记)
isRegularFileName :: proc(name : string) -> bool {
	marks := []string{ "Bold", "Light", "Italic", "Medium", "Med", "Semi", "Black", "Extra" }
	for m in marks {
		if strings.contains(name, m) {
			return false
		}
	}
	return true
}

fontIndexLookup :: proc(input : string) -> (path : string, ok : bool) {
	buildFontIndex()
	sel := -1
	for i in 0 ..< font_index_count {
		if fontNamesEqual(font_index_names[i], input) {
			if sel < 0 || (font_index_prefer[i] && !font_index_prefer[sel]) {
				sel = i
			}
		}
	}
	if sel < 0 {
		return "", false
	}
	return strings.clone(font_index_paths[sel]), true
}

// 轻量读取字体 family 名:分步 seek(文件头 → name 表记录 → 目标字符串),
// 不读全文件(大字体 name 表常深藏文件后部)。返回堆 string(调用方 delete)。
FontFamilyFromFile :: proc(path : string) -> string {
	f, err := os.open(path)
	if err != nil {
		return ""
	}
	defer os.close(f)
	head : [12]u8
	if _, rerr := os.read(f, head[:]); rerr != nil {
		return ""
	}
	num_tables := int(u16be(head[:], 4))
	if num_tables <= 0 || num_tables > 64 {
		return ""
	}
	// 读目录表找到 name 表偏移/长度
	dirbuf := make([]byte, 12 + num_tables * 16)
	defer delete(dirbuf)
	if _, rerr := os.read(f, dirbuf); rerr != nil {
		return ""
	}
	name_off, name_len := 0, 0
	for i in 0 ..< num_tables {
		rec := i * 16 // dirbuf 从文件偏移 12(目录表起点)读起,内部索引从 0 计
		if string(dirbuf[rec:rec + 4]) == "name" {
			name_off = int(u32be(dirbuf, rec + 8))
			name_len = int(u32be(dirbuf, rec + 12))
			break
		}
	}
	if name_off <= 0 || name_len <= 0 {
		return ""
	}
	// name 表偏移定位
	if _, e := os.seek(f, i64(name_off), io.Seek_From.Start); e != nil {
		return ""
	}
	hdr : [6]u8
	if _, e := os.read(f, hdr[:]); e != nil {
		return ""
	}
	count := int(u16be(hdr[:], 2))
	str_off := int(u16be(hdr[:], 4))
	if count <= 0 || count > 256 {
		return ""
	}
	recs := make([]byte, count * 12)
	defer delete(recs)
	if _, e := os.read(f, recs); e != nil {
		return ""
	}
	best_enc := 99
	best_nid := 99
	best_off, best_len := 0, 0
	for i in 0 ..< count {
		rec := i * 12
		pid := int(u16be(recs, rec))
		nid := int(u16be(recs, rec + 6))
		if nid != 1 && nid != 16 {
			continue
		}
		enc := 99
		switch pid {
		case 0, 3:
			enc = 0 // UTF-16BE 优先
		case 1:
			enc = 1
		}
		// typographic family(16,可能是全称)优先于 family(1,常被 NerdFonts 缩写成 "X NF")
		if enc < best_enc || (enc == best_enc && nid == 16 && best_nid != 16) {
			best_enc = enc
			best_nid = nid
			best_off = int(u16be(recs, rec + 10))
			best_len = int(u16be(recs, rec + 8))
		}
	}
	if best_enc == 99 {
		return ""
	}
	// 读目标字符串(相对 name 表)
	abs := i64(name_off + str_off + best_off)
	if _, e := os.seek(f, abs, io.Seek_From.Start); e != nil {
		return ""
	}
	s := make([]byte, best_len)
	defer delete(s)
	if _, e := os.read(f, s); e != nil {
		return ""
	}
	if best_enc == 1 {
		// Latin:逐字节(>=0x80 的按 Latin-1 近似)
		out : [dynamic]byte
		defer delete(out)
		for b in s {
			if b == 0 {
				break
			}
			append(&out, b)
		}
		return strings.clone(string(out[:]))
	}
	// UTF-16BE
	out : [dynamic]byte
	defer delete(out)
	for i := 0; i + 1 < len(s); i += 2 {
		u := u16(s[i]) << 8 | u16(s[i + 1])
		if u == 0 {
			break
		}
		if u < 0x80 {
			append(&out, byte(u))
		} else if u < 0x800 {
			append(&out, 0xC0 | u8(u >> 6), 0x80 | u8(u & 0x3F))
		} else {
			append(&out, 0xE0 | u8(u >> 12), 0x80 | u8(u >> 6 & 0x3F), 0x80 | u8(u & 0x3F))
		}
	}
	return strings.clone(string(out[:]))
}

GetFont :: proc(h : mem.Handle) -> ^Font {
	return mem.RcGet(&fonts, h)
}

// ---------------------------------------------------------------------------
// 字体度量:DWrite(Windows Terminal)兼容语义
// ---------------------------------------------------------------------------

u16be :: proc(data : []byte, off : int) -> u16 {
	return u16(data[off]) << 8 | u16(data[off + 1])
}
i16be :: proc(data : []byte, off : int) -> i16 {
	return i16(u16be(data, off))
}
u32be :: proc(data : []byte, off : int) -> u32 {
	return u32(data[off]) << 24 | u32(data[off + 1]) << 16 | u32(data[off + 2]) << 8 | u32(data[off + 3])
}

// sfnt 目录表定位(base = 目录起始,TTC 需 face 实际偏移)
sfntTableOffset :: proc(data : []byte, base : int, tag : string) -> int {
	n := int(u16be(data, base + 4))
	for i in 0 ..< n {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == tag {
			return int(u32be(data, rec + 8))
		}
	}
	return -1
}

// OS/2 表可选度量(fsSelection bit7 = USE_TYPO_METRICS,见 OpenType spec)
OS2_USE_TYPO_METRICS :: 0x0080

// 与 DirectWrite IDWriteFontFace::GetMetrics 同语义(参考 Wine 的 dwrite 兼容实现):
//   1. fsSelection 置 USE_TYPO_METRICS 且 OS/2 v1+ → sTypoAscender/sTypoDescender/sTypoLineGap
//   2. 否则有 OS/2 → usWinAscent/usWinDescent(为全角/重音留白),lineGap 取 hhea
//   3. 无 OS/2 → hhea
// 返回设计单位;desc 归一为**正数**(hhea/typo 的 desc 是负 i16,DWrite 报正值)。
// 注意:lineGap **不参与格高**。WPF GlyphTypeface(DWrite 引擎)实测:
//   CascadiaCode/Mono 格高=2380 单位(1900+480),consola 格高=2398(usWin 1884+514),
//   lineGap(350)被忽略;基线=ascent 原值。DWrite 行高语义 = asc+desc。
faceMetrics :: proc(f : ^Face) -> (asc, desc, lg : f32) {
	a, d, l : c.int
	stbtt.GetFontVMetrics(&f.info, &a, &d, &l)
	asc, desc, lg = f32(a), f32(-d), 0
	os2 := sfntTableOffset(f.data, f.sfnt_off, "OS/2")
	if os2 < 0 {
		return
	}
	if u16be(f.data, os2) >= 1 {
		sel := u16be(f.data, os2 + 62)
		if sel & OS2_USE_TYPO_METRICS != 0 {
			asc = f32(i16be(f.data, os2 + 68))
			desc = f32(-i16be(f.data, os2 + 70))
			return
		}
	}
	asc = f32(u16be(f.data, os2 + 74))
	desc = f32(u16be(f.data, os2 + 76)) // usWin desc 本身为正
	return
}

// WT(AtlasEngine)公式:cell = round(advanceHeight);baseline = round(ascent + (lineGap + cell - advanceHeight)/2)
// advanceHeight = asc + desc + lg。字形位置由此唯一决定,不再做字形 box 居中。
cellAndBaseline :: proc(f : ^Face) -> (cell_h, baseline : f32) {
	asc, desc, lg := faceMetrics(f)
	s := f.scale
	adv_h := (asc + desc + lg) * s
	cell_h = math.round(adv_h)
	baseline = math.round(asc * s + (lg * s + cell_h - adv_h) * 0.5)
	return
}

// 装饰线度量(像素,相对基线;正 = 基线下方):
//   下划线 = post 表 underlinePosition/underlineThickness(设计单位 → *scale);
//   删除线 = OS/2 yStrikeoutPosition/yStrikeoutSize;
//   表缺失/零值 → 缺省(下划线 = 基线下方 cell 的 12%,删除线 = cell 中线,厚 ≥1)。
decoMetrics :: proc(f : ^Face, cell_h : f32) -> (upos, uthick, spos, sthick : f32) {
	upos, uthick = cell_h * 0.12, 1
	spos, sthick = -cell_h * 0.10, 1
	if po := sfntTableOffset(f.data, f.sfnt_off, "post"); po >= 0 && po + 10 <= len(f.data) {
		if p := i16be(f.data, po + 6); p != 0 { // underlinePosition
			upos = f32(p) * f.scale
		}
		if p := i16be(f.data, po + 8); p > 0 { // underlineThickness
			uthick = f32(p) * f.scale
		}
	}
	if o2 := sfntTableOffset(f.data, f.sfnt_off, "OS/2"); o2 >= 0 && o2 + 30 <= len(f.data) {
		if p := i16be(f.data, o2 + 28); p != 0 { // yStrikeoutPosition
			spos = f32(p) * f.scale
		}
		if p := i16be(f.data, o2 + 26); p != 0 { // yStrikeoutSize
			sthick = f32(p) * f.scale
		}
	}
	if uthick < 1 {
		uthick = 1
	}
	if sthick < 1 {
		sthick = 1
	}
	return
}

// 系统字体目录(Windows)
SYSTEM_FONT_DIR :: "C:\\Windows\\Fonts\\"

// antialias:光栅化超采样倍数(1 = 整数网格,2 = 2x2 超采样)。
// 默认 1:oversample=2 的 subpixel 相位(-0.25)会让同一笔画在不同字形里
// 灰度分布不同(横线粗细/明暗不一);整数光栅化所有字形一致。
// 输入 path_or_name:优先当作字体名去系统目录找(`${SYSTEM_FONT_DIR}name.ttf/.otf/.ttc`),
// 找不到再当作完整路径加载。
// 去重:同 (path, size) 直接返回已有字体(字体全局共享,不重复加载/不随窗口销毁)。
// quiet = 失败不打印(变体猜测失败是常态,不刷日志)。
LoadFont :: proc(path_or_name : string, size : f32, antialias : u8 = 1, quiet := false) -> (h : mem.Handle, ok : bool) {
	if size <= 0 {
		return {}, false
	}
	// 解析:先按系统字体名找,再按完整路径
	path, path_alloc := resolveFontPath(path_or_name)

	// 同 path+size 复用已加载的字体(跨窗口共享;命中 = 新增一个引用)
	fit : mem.RcIter(MAX_FONT_SLOTS, Font) = mem.RcAll(&fonts)
	for h in mem.nextRc(&fit) {
		if f := mem.RcGet(&fonts, h); f != nil && f.path == path && f.size == size {
			if path_alloc {
				delete(path) // 堆分配副本,未入字体则释放
			}
			mem.RcRetain(&fonts, h)
			return h, true
		}
	}
	font := Font { antialias = max(1, min(3, antialias)) }
	font.slots = make([dynamic]GlyphSlot, 64) // 哈希桶,装 0.75 后翻倍
	face, fok := faceLoad(path, size)
	if !fok {
		if !quiet {
			fmt.eprintln("faceLoad() opened your font and found a body. kitty would have fallen back through six fonts, shaped ligatures out of thin air and felt smug about it. You typed the path wrong:", path, size)
		}
		delete(font.slots)
		if path_alloc {
			delete(path)
		}
		return {}, false
	}
	font.faces[0] = face
	font.face_count = 1

	// 主字体无 CJK 字形 → 附系统中文字体
	if stbtt.FindGlyphIndex(&font.faces[0].info, '你') == 0 {
		// fallback 按主字体 em 像素尺寸对齐,保证同字号下汉字与拉丁字形等大。
		// 主字体 em 像素 = scale × unitsPerEm;unitsPerEm = 1 / ScaleForMappingEmToPixels(info, 1.0)
		main_em_px := font.faces[0].scale / stbtt.ScaleForMappingEmToPixels(&font.faces[0].info, 1.0)
		for fb_path in FALLBACK_FONTS {
			if fb, ffok := faceLoadFallback(fb_path, main_em_px); ffok {
				font.faces[1] = fb
				font.face_count = 2
				break
			}
		}
	}

	// 主字体 GSUB(连体规则);解析失败 = 无连体,ShapeLine 空转
	font.gsub = ParseGsub(font.faces[0].data)

	// 格子度量:与 WT(AtlasEngine)同公式——表选择(USW/TYPO)由 faceMetrics 决定,
	// cell = round((asc+desc+lg)*scale),baseline = round(asc*s + (lg*s + cell - advH)/2)。
	// 弃用字形 box 居中(与 WT 不一致,正是 consola 偏上根源)。
	f := &font.faces[0]
	cell_h, base := cellAndBaseline(f)
	font.cell_height = cell_h
	font.ascent = base
	font.underline_pos, font.underline_thick, font.strike_pos, font.strike_thick = decoMetrics(f, cell_h)
	advance : c.int
	stbtt.GetCodepointHMetrics(&f.info, 'M', &advance, nil)
	font.cell_width = math.ceil(f32(advance) * f.scale)

	atlasInit(&font.atlas)

	// 去重键:path_alloc 时所有权直接转移(不 clone),否则 clone
	// Font 生命周期与程序一致(不随窗口销毁)
	if path_alloc {
		font.path = path
	} else {
		font.path = strings.clone(path)
	}
	font.size = size

	h = mem.RcAlloc(&fonts, font)
	if h.id == 0 {
		if !quiet {
			fmt.eprintln("Font table's full. A garbage collector would have freed something by now — the wrong thing, at the worst possible moment, after a 200ms pause — but something. Take it home:", path, size)
		}
		fontFree(&font)
		return {}, false
	}
	return h, true
}

// 增一个引用(同 path+size 新持有者,如窗口继承字体)
RetainFont :: proc(h : mem.Handle) -> bool {
	return mem.RcRetain(&fonts, h)
}

// 变体字体加载(粗/斜/粗斜):基于 base(族名或路径)找同族衍生文件。
// 两种形态,任一命中即返回(引用 +1):
//   ① 族名习惯:"<base> <suffix>"(独立 Bold 族的字体,如部分发行版);
//   ② 文件命名:base 解析到真实文件 → 同目录 `<stem>[-风格尾缀去]` + `-<file_suffix>` + 扩展
//      (Nerd Fonts / Google Fonts 命名,如 ...Mono-Regular.ttf → ...Mono-Bold.ttf)。
// 都没有 = 0(调用方用合成兜底);失败静默(变体缺失是常态)。
LoadFontVariant :: proc(base : string, size : f32, family_suffix, file_suffix : string) -> mem.Handle {
	// ① 族名习惯
	{
		buf : [512]byte
		n := copy(buf[:], base)
		if n + 1 + len(family_suffix) <= len(buf) {
			copy(buf[n:], " ")
			copy(buf[n + 1:], family_suffix)
			if h, ok := LoadFont(string(buf[:n + 1 + len(family_suffix)]), size, 1, true); ok {
				return h
			}
		}
	}
	// ② 文件命名推导
	path, path_alloc := resolveFontPath(base)
	defer if path_alloc {
		delete(path)
	}
	if len(path) == 0 {
		return {}
	}
	dir := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '\\' {
			dir = i + 1
			break
		}
	}
	dot := len(path)
	for i := len(path) - 1; i > dir; i -= 1 {
		if path[i] == '.' {
			dot = i
			break
		}
	}
	if dir == 0 || dot <= dir {
		return {}
	}
	stem := path[dir:dot]
	style_tails := []string{"-Regular", "-Book", "-Normal"}
	for st in style_tails {
		if strings.has_suffix(stem, st) {
			stem = stem[:len(stem) - len(st)]
			break
		}
	}
	ext := path[dot:]
	vbuf : [512]byte
	vn := copy(vbuf[:], path[:dir])
	vn += copy(vbuf[vn:], stem)
	vn += copy(vbuf[vn:], "-")
	vn += copy(vbuf[vn:], file_suffix)
	vn += copy(vbuf[vn:], ext)
	if vn >= len(vbuf) {
		return {}
	}
	if h, ok := LoadFont(string(vbuf[:vn]), size, 1, true); ok {
		return h
	}
	return {}
}

// 释放一个引用:最后一个引用归零 = 深析构堆资源;槽保留,Alloc 复用。
// 所有持有者(窗口/UI 单例)释放必须经此(不能直接 mem.Free)。
ReleaseFont :: proc(h : mem.Handle) {
	font := mem.RcGet(&fonts, h) // 指针先取:RcFree 后句柄失效,槽数据仍留
	if font == nil {
		return
	}
	mem.RcFree(&fonts, h)
	if mem.RcRefs(&fonts, h) == 0 {
		fontFree(font) // 最后一个引用:堆资源立即清;槽值待 Alloc 复用覆盖
	}
}

// 字体表是否已满(refs > 0 的槽数 = N-1;再 Alloc 会失败)
FontTableFull :: proc() -> bool {
	return mem.RcCount(&fonts) >= MAX_FONT_SLOTS - 1
}

// 查字形:缓存命中直接返回;未命中则光栅化入图集。false = 所有 face 都无此字形
GetGlyph :: proc(h : mem.Handle, cp : rune) -> (Glyph, bool) {
	font := GetFont(h)
	if font == nil {
		return {}, false
	}
	if slot := slotFind(h, cp); slot != nil {
		return glyphFromSlot(slot), true
	}
	if !glyphRasterize(h, cp) {
		return {}, false
	}
	slot := slotFind(h, cp)
	if slot == nil {
		return {}, false
	}
	return glyphFromSlot(slot), true
}

GetMetrics :: proc(h : mem.Handle) -> Metrics {
	font := GetFont(h)
	if font == nil {
		return {}
	}
	return Metrics {
		cell_width = font.cell_width,
		cell_height = font.cell_height,
		ascent = font.ascent,
		underline_pos = font.underline_pos,
		underline_thick = font.underline_thick,
		strike_pos = font.strike_pos,
		strike_thick = font.strike_thick,
	}
}

// 按内部 glyph id 查字形(连体替换结果);缓存 + 主 face 光栅化
GetGlyphById :: proc(h : mem.Handle, gid : u16) -> (Glyph, bool) {
	font := GetFont(h)
	if font == nil {
		return {}, false
	}
	if slot := slotFindById(h, gid); slot != nil {
		return glyphFromSlot(slot), true
	}
	if !glyphRasterizeById(h, gid) {
		return {}, false
	}
	slot := slotFindById(h, gid)
	if slot == nil {
		return {}, false
	}
	return glyphFromSlot(slot), true
}

// 主字体 glyph id(连体输入);0 = 主字体无此字符(fallback 或不可渲染)。
// 热路径缓存:字形槽已建(位图缓存过)直接读槽内 gid(省 stbtt 查询);
// 槽的 gid 仅在光栅化主 face 时记录(rasterCommon 后由 glyphRasterize 填)。
GlyphIndex :: proc(h : mem.Handle, cp : rune) -> u16 {
	font := GetFont(h)
	if font == nil {
		return 0
	}
	if slot := slotFind(h, cp); slot != nil {
		if slot.face_index == 0 {
			return slot.gid
		}
		return 0 // fallback 面槽:主字体无此字符
	}
	return u16(stbtt.FindGlyphIndex(&font.faces[0].info, cp))
}

// 对一行 glyph 序列逐 lookup 应用连体(原地修改;无 GSUB 时为空转)。
// 带缓存:输入序列哈希命中直接复制上次结果,跳过规则匹配。
// 无长度上限:超长行同样受益,行内普通字符(独立单位)由 ShapeGlyphs
// 的 active 预扫跳过,缓存只按行哈希区分。
ShapeLine :: proc(h : mem.Handle, glyphs : ^[dynamic]u16) {
	font := GetFont(h)
	if font == nil || len(font.gsub.lookup_order) == 0 {
		return
	}
	n := len(glyphs)
	hash := fnv1a(glyphs[:])
	for i in 0 ..< SHAPE_CACHE_SLOTS {
		slot := &font.shape_cache[i]
		if slot.hash == hash && int(slot.len) == n {
			resize(glyphs, int(slot.len))
			copy(glyphs[:], slot.glyphs[:])
			return
		}
	}
	// 未命中:shape 后入缓存(轮转覆盖)
	ShapeGlyphs(&font.gsub, glyphs)
	idx := int(font.shape_cache_next) % SHAPE_CACHE_SLOTS
	font.shape_cache_next += 1
	slot := &font.shape_cache[idx]
	clear(&slot.glyphs)
	append(&slot.glyphs, ..glyphs[:])
	slot.hash = hash
	slot.len = u16(len(glyphs))
}

fnv1a :: proc(glyphs : []u16) -> u64 {
	h : u64 = 14695981039346656037
	for g in glyphs {
		h = (h ~ u64(g)) * 1099511628211
	}
	return h
}

GetAtlasTexture :: proc(h : mem.Handle) -> u32 {
	font := GetFont(h)
	if font == nil {
		return 0
	}
	atlasEnsureTexture(&font.atlas) // GL 纹理惰性创建(渲染路径,GL 上下文已就绪)
	return font.atlas.texture
}

// ---------------------------------------------------------------------------
// face
// ---------------------------------------------------------------------------

faceLoad :: proc(path : string, size : f32) -> (Face, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	offset := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0) // ttc 取第 0 个
	face := Face { data = data, sfnt_off = int(offset) }
	if offset < 0 || !stbtt.InitFont(&face.info, cast([^]byte)raw_data(data), offset) {
		delete(data)
		return {}, false
	}
	face.scale = stbtt.ScaleForPixelHeight(&face.info, size)
	return face, true
}

// fallback 字体加载:按 em 尺寸对齐主字体(scale 传递)。
// 不能用 ScaleForPixelHeight(size):不同字体的 ascent-descent 不同,
// 同参数下雅黑(2703)比 Cascadia(2380)缩得更小 → 汉字偏小。
// 正确做法:fallback 的 em 像素尺寸 = 主字体 em 像素尺寸,两字体字形等大。
faceLoadFallback :: proc(path : string, main_em_px : f32) -> (Face, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	offset := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	face := Face { data = data, sfnt_off = int(offset) }
	if offset < 0 || !stbtt.InitFont(&face.info, cast([^]byte)raw_data(data), offset) {
		delete(data)
		return {}, false
	}
	// ScaleForMappingEmToPixels(info, em_px) = 使 em 盒映射到 em_px 像素的 scale
	face.scale = stbtt.ScaleForMappingEmToPixels(&face.info, main_em_px)
	return face, true
}

// 释放 Font 值持有的资源(槽位释放与创建失败回滚共用)
fontFree :: proc(font : ^Font) {
	DestroyGsub(&font.gsub)
	for &slot in font.shape_cache {
		delete(slot.glyphs)
	}
	for i in 0 ..< int(font.face_count) {
		delete(font.faces[i].data)
	}
	delete(font.slots)
	delete(font.atlas.pixels)
	delete(font.path)
	if font.atlas.texture != 0 { // 未建纹理(无 GL 加载路径)不删
		gl.DeleteTextures(1, &font.atlas.texture)
	}
}

// ---------------------------------------------------------------------------
// 缓存槽(开放寻址,线性探测)
// ---------------------------------------------------------------------------

slotFind :: proc(font_h : mem.Handle, cp : rune) -> ^GlyphSlot {
	font := GetFont(font_h)
	if font == nil {
		return nil
	}
	cap := len(font.slots)
	if cap == 0 {
		return nil
	}
	i := int(uint(cp) % uint(cap))
	for {
		slot := &font.slots[i]
		if slot.cp == cp {
			return slot
		}
		if slot.cp == 0 && slot.gid == 0 {
			return nil // 空槽终止探测
		}
		i = (i + 1) % cap
	}
}

slotFindById :: proc(font_h : mem.Handle, gid : u16) -> ^GlyphSlot {
	font := GetFont(font_h)
	if font == nil {
		return nil
	}
	cap := len(font.slots)
	if cap == 0 {
		return nil
	}
	i := int(uint(gid) % uint(cap))
	for {
		slot := &font.slots[i]
		if slot.gid == gid {
			return slot
		}
		if slot.cp == 0 && slot.gid == 0 {
			return nil // 空槽终止探测
		}
		i = (i + 1) % cap
	}
}

slotInsert :: proc(font_h : mem.Handle, slot : GlyphSlot) -> bool {
	font := GetFont(font_h)
	if font == nil || len(font.slots) == 0 {
		return false
	}
	if int(font.slot_count) + 1 > int(f32(len(font.slots)) * SLOT_LOAD_FACTOR) {
		if !slotGrow(font_h) {
			return false
		}
	}
	key := uint(slot.cp) if slot.cp != 0 else uint(slot.gid)
	i := int(key % uint(len(font.slots)))
	for {
		s := &font.slots[i]
		if s.cp == 0 && s.gid == 0 {
			s^ = slot
			font.slot_count += 1
			return true
		}
		i = (i + 1) % len(font.slots)
	}
}

slotGrow :: proc(font_h : mem.Handle) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	old := font.slots
	font.slots = make([dynamic]GlyphSlot, len(old) * 2)
	font.slot_count = 0
	for slot in old {
		if slot.cp == 0 && slot.gid == 0 {
			continue
		}
		key := uint(slot.cp) if slot.cp != 0 else uint(slot.gid)
		i := int(key % uint(len(font.slots)))
		for {
			s := &font.slots[i]
			if s.cp == 0 && s.gid == 0 {
				s^ = slot
				font.slot_count += 1
				break
			}
			i = (i + 1) % len(font.slots)
		}
	}
	delete(old)
	return true
}

glyphFromSlot :: proc(slot : ^GlyphSlot) -> Glyph {
	// slot.xoff/yoff = stbtt box 偏移(x0/y0,相对字形原点);
	// UV 已指向图集内容区,quad 只画内容区
	return Glyph {
		advance = slot.advance,
		bitmap_w = f32(slot.w),
		bitmap_h = f32(slot.h),
		xoff = slot.xoff,
		yoff = slot.yoff,
		uv0_x = slot.u0, uv0_y = slot.v0, uv1_x = slot.u1, uv1_y = slot.v1,
	}
}

// ---------------------------------------------------------------------------
// 光栅化
// ---------------------------------------------------------------------------

// 选 face:主字体无此字形(notdef)则 fallback
glyphFaceIndex :: proc(font_h : mem.Handle, cp : rune) -> (index : int, ok : bool) {
	font := GetFont(font_h)
	if font == nil {
		return 0, false
	}
	for i in 0 ..< int(font.face_count) {
		if stbtt.FindGlyphIndex(&font.faces[i].info, cp) != 0 {
			return i, true
		}
	}
	return 0, false
}

// 光栅化公共:1x 分辨率,stbtt 解析覆盖率抗锯齿(每像素按字形覆盖面积算灰度,
// 无需超采样)。oversample=1:不用 subpixel prefilter,避免其相位让同一笔画
// 在不同字形里灰度分布不同(横线粗细/明暗不一,FreeType 靠 hinting 才一致)。
rasterCommon :: proc(font_h : mem.Handle, face : ^Face, cp : rune, gid : c.int) -> (GlyphSlot, bool) {
	font := GetFont(font_h)
	if font == nil {
		return {}, false
	}
	scale := face.scale

	x0, y0, x1, y1 : c.int
	if gid != 0 {
		stbtt.GetGlyphBitmapBox(&face.info, gid, scale, scale, &x0, &y0, &x1, &y1)
	} else {
		stbtt.GetCodepointBitmapBox(&face.info, cp, scale, scale, &x0, &y0, &x1, &y1)
	}
	w := x1 - x0
	h := y1 - y0
	if w == 0 || h == 0 {
		return {}, false // 空白字形(空格等):不入图集
	}
	advance : c.int
	if gid != 0 {
		stbtt.GetGlyphHMetrics(&face.info, gid, &advance, nil)
	} else {
		stbtt.GetCodepointHMetrics(&face.info, cp, &advance, nil)
	}

	x, y, alloc_ok := atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
	if !alloc_ok {
		atlasGrow(font_h) // 图集满 → 扩容并重放全部缓存字形
		x, y, alloc_ok = atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
		if !alloc_ok {
			return {}, false
		}
	}
	// 位图直接画入图集 buffer(带 pad);oversample=1(覆盖率抗锯齿已平滑)
	sub_x, sub_y : f32
	row_start := int(y + ATLAS_PAD) * int(font.atlas.width) + int(x + ATLAS_PAD)
	if gid != 0 {
		stbtt.MakeGlyphBitmapSubpixelPrefilter(&face.info, cast([^]byte)&font.atlas.pixels[row_start], w, h, c.int(font.atlas.width), scale, scale, 0, 0, 1, 1, &sub_x, &sub_y, gid)
	} else {
		stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&font.atlas.pixels[row_start], w, h, c.int(font.atlas.width), scale, scale, 0, 0, true, true, &sub_x, &sub_y, cp)
	}
	atlasUpload(&font.atlas, x, y, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)

	// box-drawing 等超高字形裁剪到 cell 高度(防相邻行交叠/竖线列断续瑕疵):
	// 只调 yoff/高度/UV(位图本体不动,UV 指向位图子区)。
	// cell 相对基线:顶 = -ascent,底 = cell_height - ascent。
	xoff_v := f32(x0) + sub_x
	yoff_v := f32(y0) + sub_y
	cut_top : c.int
	cell_top := -font.ascent
	cell_bottom := font.cell_height - font.ascent
	if yoff_v < cell_top {
		cut := c.int(math.ceil(cell_top - yoff_v))
		if cut >= h {
			return {}, false // 整字形在 cell 上界之外:不画
		}
		yoff_v = cell_top
		h -= cut
		cut_top = cut
	}
	if yoff_v + f32(h) > cell_bottom {
		cut := c.int(math.ceil(yoff_v + f32(h) - cell_bottom))
		if cut >= h {
			return {}, false
		}
		h -= cut
	}

	return GlyphSlot {
		w = u16(w), h = u16(h),
		xoff = xoff_v, yoff = yoff_v,
		advance = f32(advance) * scale,
		u0 = f32(x + ATLAS_PAD) / f32(font.atlas.width),
		v0 = f32(y + ATLAS_PAD + u32(cut_top)) / f32(font.atlas.height),
		u1 = f32(x + ATLAS_PAD + u32(w)) / f32(font.atlas.width),
		v1 = f32(y + ATLAS_PAD + u32(cut_top) + u32(h)) / f32(font.atlas.height),
	}, true
}

glyphRasterize :: proc(font_h : mem.Handle, cp : rune) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	face_idx, fok := glyphFaceIndex(font_h, cp)
	if !fok {
		return false
	}
	slot, sok := rasterCommon(font_h, &font.faces[face_idx], cp, 0)
	if !sok {
		return false
	}
	slot.cp = cp
	slot.face_index = u8(face_idx)
	// 主 face 槽记录主字体 glyph id(GlyphIndex 缓存;fallback 面 = 0 = 主字体无)
	if face_idx == 0 {
		slot.gid = u16(stbtt.FindGlyphIndex(&font.faces[0].info, cp))
	}
	return slotInsert(font_h, slot)
}

// 按内部 glyph id 光栅化(连体字形,只属于主 face)
glyphRasterizeById :: proc(font_h : mem.Handle, gid : u16) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	slot, sok := rasterCommon(font_h, &font.faces[0], 0, c.int(gid))
	if !sok {
		return false
	}
	slot.gid = gid
	slot.face_index = 0
	return slotInsert(font_h, slot)
}

// ---------------------------------------------------------------------------
// 图集
// ---------------------------------------------------------------------------
// 分层:atlasInit 只分配像素缓冲(纯数据,无 GL 依赖);GL 纹理创建/上传
// 在渲染路径经 atlasEnsureTexture 惰性做(GetAtlasTexture 首次调用)。

atlasInit :: proc(a : ^Atlas) {
	a.width, a.height = ATLAS_START, ATLAS_START
	a.pixels = make([]u8, a.width * a.height)
}

// 纹理未建时创建并上传当前像素(GL 上下文必须已就绪;渲染路径调用)
atlasEnsureTexture :: proc(a : ^Atlas) {
	if a.texture != 0 {
		return
	}
	gl.GenTextures(1, &a.texture)
	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, i32(a.width), i32(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels))
}

atlasUpload :: proc(a : ^Atlas, x, y, w, h : u32) {
	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	offset := int(y) * int(a.width) + int(x)
	// 行距 = 图集宽度:子区域在 pixels 里按整行 1024 打包,GL 默认按 w 紧密打包,须显式声明
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(a.width))
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(x), i32(y), i32(w), i32(h), gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels[offset:]))
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
}

// 行式分配:当前行放不下则换行,图集放不下返回 false
atlasAlloc :: proc(a : ^Atlas, w, h : u32) -> (x, y : u32, ok : bool) {
	if w > a.width || h > a.height {
		return 0, 0, false
	}
	if a.cur_x + w > a.width {
		a.cur_x = 0
		a.cur_y += a.row_height
		a.row_height = 0
	}
	if a.cur_y + h > a.height {
		return 0, 0, false
	}
	x, y = a.cur_x, a.cur_y
	a.cur_x += w
	a.row_height = max(a.row_height, h)
	return x, y, true
}

// 图集满:尺寸翻倍,重画全部已缓存字形(一次性冷启动成本)
atlasGrow :: proc(font_h : mem.Handle) {
	font := GetFont(font_h)
	if font == nil {
		return
	}
	a := &font.atlas
	if a.width >= ATLAS_MAX {
		return // 到上限,分配失败由上层接受
	}
	new_w, new_h := a.width * 2, a.height * 2
	old := a.pixels
	a.pixels = make([]u8, new_w * new_h) // 全 0
	a.width, a.height = new_w, new_h
	a.cur_x, a.cur_y, a.row_height = 0, 0, 0

	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, i32(a.width), i32(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, nil)

	for i in 0 ..< len(font.slots) {
		slot := &font.slots[i]
		if slot.cp == 0 && slot.gid == 0 {
			continue
		}
		face := &font.faces[slot.face_index]
		x, y, ok := atlasAlloc(a, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
		if !ok {
			break // 翻倍后仍有空间,分配失败即后续全失败
		}
		row_start := int(y + ATLAS_PAD) * int(a.width) + int(x + ATLAS_PAD)
		sub_x, sub_y : f32
		if slot.gid != 0 {
			stbtt.MakeGlyphBitmapSubpixelPrefilter(&face.info, cast([^]byte)&a.pixels[row_start], c.int(slot.w), c.int(slot.h), c.int(a.width), face.scale, face.scale, 0, 0, 1, 1, &sub_x, &sub_y, c.int(slot.gid))
		} else {
			stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&a.pixels[row_start], c.int(slot.w), c.int(slot.h), c.int(a.width), face.scale, face.scale, 0, 0, true, true, &sub_x, &sub_y, slot.cp)
		}
		slot.u0 = f32(x + ATLAS_PAD) / f32(a.width)
		slot.v0 = f32(y + ATLAS_PAD) / f32(a.height)
		slot.u1 = f32(x + ATLAS_PAD + u32(slot.w)) / f32(a.width)
		slot.v1 = f32(y + ATLAS_PAD + u32(slot.h)) / f32(a.height)
		atlasUpload(a, x, y, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
	}
	delete(old)
}
