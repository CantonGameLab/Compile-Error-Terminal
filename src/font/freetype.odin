// FreeType 子集绑定(动态加载,与 conpty 同套路:缺 DLL 就退回 stb 光栅化)。
//
// 为什么需要它:stb_truetype **没有 hinting(网格拟合)**。字形轮廓的笔画位置不在像素网格上
// 时,一条 1.7px 竖笔会被摊成三列灰边(≈38/240/150),而且每条笔画的相位各不相同 ——
// 观感就是"毛刺/走样"。实测(同字体、同像素尺寸):
//   stb ≈ FreeType NONE(指标几乎逐位相同)
//   FreeType NORMAL:`中` 的灰度级数 37→11、`三` 的三横从 2/3/3 行(带 60 级灰底行)变成
//                    统一 2 行、`e` 的高度 14→12 行且纵向总变差 -18%
// 注意 FT_LOAD_TARGET_LIGHT 只吸附 Y 轴,对 `三` 这类横笔无改善(实测 mid/ink 69.8% vs
// NORMAL 55.3%),所以默认用 NORMAL。
//
// 结构体只声明**用到的前缀**,偏移必须与 FreeType 布局一致 —— 由 playground/ftcheck 与 stb
// 逐项实测对照(字型数 / units_per_EM / ascender / gid / 位图盒),不靠记忆。
// 该对照按 FreeType 2.14 头文件编写;FT_GlyphSlotRec.glyph_index 自 2.10 起存在。
package font

import win "core:sys/windows"
import paths "../paths"
import "core:c"
import "core:fmt"

// ---------------------------------------------------------------------------
// 类型(Windows LLP64:FT_Long/FT_Fixed/FT_Pos 都是 32 位 long)
// ---------------------------------------------------------------------------
FT_Long :: c.long
FT_ULong :: c.ulong
FT_Int :: c.int
FT_Int32 :: c.int
FT_UInt :: c.uint
FT_Short :: c.short
FT_UShort :: c.ushort
FT_Fixed :: c.long
FT_Pos :: c.long
FT_F26Dot6 :: c.long
FT_Error :: c.int
FT_Library :: distinct rawptr
FT_Face :: ^FT_FaceRec
FT_GlyphSlot :: ^FT_GlyphSlotRec

FT_Generic :: struct {
	data      : rawptr,
	finalizer : rawptr,
}

FT_BBox :: struct {
	xMin, yMin, xMax, yMax : FT_Pos,
}

FT_Vector :: struct {
	x, y : FT_Pos,
}

FT_Glyph_Metrics :: struct {
	width, height                           : FT_Pos,
	horiBearingX, horiBearingY, horiAdvance : FT_Pos,
	vertBearingX, vertBearingY, vertAdvance : FT_Pos,
}

FT_Bitmap :: struct {
	rows, width  : c.uint,
	pitch        : c.int,
	buffer       : [^]u8,
	num_grays    : c.ushort,
	pixel_mode   : u8,
	palette_mode : u8,
	palette      : rawptr,
}

FT_GlyphSlotRec :: struct {
	library             : FT_Library,
	face                : FT_Face,
	next                : FT_GlyphSlot,
	glyph_index         : FT_UInt,
	generic             : FT_Generic,
	metrics             : FT_Glyph_Metrics,
	linear_hori_advance : FT_Fixed,
	linear_vert_advance : FT_Fixed,
	advance             : FT_Vector,
	format              : FT_Int,
	bitmap              : FT_Bitmap,
	bitmap_left         : FT_Int,
	bitmap_top          : FT_Int,
	// 以下(outline / subglyphs / lsb_delta …)用不到,不声明
}

FT_FaceRec :: struct {
	num_faces, face_index       : FT_Long,
	face_flags, style_flags     : FT_Long,
	num_glyphs                  : FT_Long,
	family_name, style_name     : cstring,
	num_fixed_sizes             : FT_Int,
	available_sizes             : rawptr,
	num_charmaps                : FT_Int,
	charmaps                    : rawptr,
	generic                     : FT_Generic,
	bbox                        : FT_BBox,
	units_per_EM                : FT_UShort,
	ascender, descender, height : FT_Short,
	max_advance_width           : FT_Short,
	max_advance_height          : FT_Short,
	underline_position          : FT_Short,
	underline_thickness         : FT_Short,
	glyph                       : FT_GlyphSlot,
	size, charmap               : rawptr,
	// 以下(driver / memory / stream / sizes_list …)用不到,不声明
}

// ---------------------------------------------------------------------------
// 常量(值取自 FreeType 头文件)
// ---------------------------------------------------------------------------
FT_LOAD_DEFAULT        :: 0x0
FT_LOAD_NO_HINTING     :: 1 << 1
FT_LOAD_NO_BITMAP      :: 1 << 3
FT_LOAD_TARGET_NORMAL  :: 0 << 16 // FT_LOAD_TARGET_(FT_RENDER_MODE_NORMAL)
FT_LOAD_TARGET_LIGHT   :: 1 << 16
FT_RENDER_MODE_NORMAL  :: 0
FT_PIXEL_MODE_GRAY     :: 2
FT_ERR_OK              :: 0

FT_ULongMax :: FT_ULong(0xFFFFFFFF)

// ---------------------------------------------------------------------------
// 提示(hinting)模式:运行时可切;切完必须让字形缓存重新光栅化
// ---------------------------------------------------------------------------
Hinting :: enum u8 {
	Stb,    // stb_truetype:无 hinting(FreeType 不可用时的兜底,也是对照基线)
	Off,    // FreeType,无 hinting
	Light,  // FreeType,只吸附 Y 轴
	Normal, // FreeType,完整 hinting(默认)
}

hinting_mode : Hinting = .Normal

SetHinting :: proc(m : Hinting) {
	hinting_mode = m
}

GetHinting :: proc() -> Hinting {
	return hinting_mode
}

HintingByName :: proc(name : string) -> (Hinting, bool) {
	switch name {
	case "stb":
		return .Stb, true
	case "off", "none", "0":
		return .Off, true
	case "light":
		return .Light, true
	case "normal", "on", "1":
		return .Normal, true
	}
	return .Normal, false
}

HintingName :: proc(m : Hinting) -> string {
	switch m {
	case .Stb:
		return "stb"
	case .Off:
		return "off"
	case .Light:
		return "light"
	case .Normal:
		return "normal"
	}
	return "?"
}

// ---------------------------------------------------------------------------
// 动态加载
// ---------------------------------------------------------------------------
FtInitFreeTypeFn :: #type proc "c" (alibrary : ^FT_Library) -> FT_Error
FtDoneFreeTypeFn :: #type proc "c" (library : FT_Library) -> FT_Error
FtNewMemoryFaceFn :: #type proc "c" (library : FT_Library, file_base : [^]u8, file_size : FT_Long, face_index : FT_Long, aface : ^FT_Face) -> FT_Error
FtDoneFaceFn :: #type proc "c" (face : FT_Face) -> FT_Error
FtLibraryVersionFn :: #type proc "c" (library : FT_Library, amajor, aminor, apatch : ^FT_Int)
FtSetCharSizeFn :: #type proc "c" (face : FT_Face, char_width, char_height : FT_F26Dot6, horz_resolution, vert_resolution : FT_UInt) -> FT_Error
FtGetCharIndexFn :: #type proc "c" (face : FT_Face, charcode : FT_ULong) -> FT_UInt
FtLoadGlyphFn :: #type proc "c" (face : FT_Face, glyph_index : FT_UInt, load_flags : FT_Int32) -> FT_Error
FtRenderGlyphFn :: #type proc "c" (slot : FT_GlyphSlot, render_mode : FT_Int) -> FT_Error

// 资源根下的载荷目录;freetype.dll 与 zlib1.dll 必须放一起

ft_module : win.HMODULE
ft_lib : FT_Library
ft_ready : bool // 加载成功 = 可以用 FreeType 光栅化
ft_tried : bool // 幂等
ft_major, ft_minor, ft_patch : FT_Int
ft_init_free_type : FtInitFreeTypeFn
ft_done_free_type : FtDoneFreeTypeFn
ft_new_memory_face : FtNewMemoryFaceFn
ft_done_face : FtDoneFaceFn
ft_library_version : FtLibraryVersionFn
ft_set_char_size : FtSetCharSizeFn
ft_get_char_index : FtGetCharIndexFn
ft_load_glyph : FtLoadGlyphFn
ft_render_glyph : FtRenderGlyphFn

// 找 FreeType:① 裸名(freetype.dll:exe 同目录 → 系统 → 当前目录 → PATH)
//              ② <资源根>/freetype/x64/:先显式预载同目录 zlib1.dll,再普通 LoadLibrary 全路径。
// 不用 LOAD_WITH_ALTERED_SEARCH_PATH / LOAD_LIBRARY_SEARCH_*:本机上那两类标志会被代码完整性
// 策略挡掉(实测 err=15700 / 577 ERROR_INVALID_IMAGE_HASH),普通全路径加载正常。
loadFreeTypeDll :: proc() -> win.HMODULE {
	if h := win.LoadLibraryW(win.LPCWSTR("freetype.dll")); h != nil {
		return h
	}
	dir := paths.Resource("freetype/x64")
	if len(dir) == 0 {
		return nil
	}
	zl, ft : [512]u16
	z := win.utf8_to_utf16_buf(zl[:], fmt.tprintf("%s/zlib1.dll", dir))
	if len(z) > 0 && len(z) + 1 <= len(zl) {
		zl[len(z)] = 0
		win.LoadLibraryW(win.LPCWSTR(&zl[0])) // 失败也无妨:freetype 可能不需要它
	}
	w := win.utf8_to_utf16_buf(ft[:], fmt.tprintf("%s/freetype.dll", dir))
	if len(w) == 0 || len(w) + 1 > len(ft) {
		return nil
	}
	ft[len(w)] = 0
	return win.LoadLibraryW(win.LPCWSTR(&ft[0]))
}

// 首次使用自动解析(幂等)。结果写一行 stderr —— 字体观感排查的关键事实
// (当前用的是 hinting 还是 stb 兜底,一眼可见)。
initFreeType :: proc() {
	if ft_tried {
		return
	}
	ft_tried = true
	h := loadFreeTypeDll()
	if h == nil {
		fmt.eprintln("[font] 没找到 freetype.dll(资源根 freetype/x64/),光栅化退回 stb(无 hinting)")
		return
	}
	ft_init_free_type = transmute(FtInitFreeTypeFn) win.GetProcAddress(h, "FT_Init_FreeType")
	ft_done_free_type = transmute(FtDoneFreeTypeFn) win.GetProcAddress(h, "FT_Done_FreeType")
	ft_new_memory_face = transmute(FtNewMemoryFaceFn) win.GetProcAddress(h, "FT_New_Memory_Face")
	ft_done_face = transmute(FtDoneFaceFn) win.GetProcAddress(h, "FT_Done_Face")
	ft_library_version = transmute(FtLibraryVersionFn) win.GetProcAddress(h, "FT_Library_Version")
	ft_set_char_size = transmute(FtSetCharSizeFn) win.GetProcAddress(h, "FT_Set_Char_Size")
	ft_get_char_index = transmute(FtGetCharIndexFn) win.GetProcAddress(h, "FT_Get_Char_Index")
	ft_load_glyph = transmute(FtLoadGlyphFn) win.GetProcAddress(h, "FT_Load_Glyph")
	ft_render_glyph = transmute(FtRenderGlyphFn) win.GetProcAddress(h, "FT_Render_Glyph")
	if ft_init_free_type == nil || ft_done_free_type == nil || ft_new_memory_face == nil ||
	   ft_done_face == nil || ft_library_version == nil || ft_set_char_size == nil ||
	   ft_get_char_index == nil || ft_load_glyph == nil || ft_render_glyph == nil {
		fmt.eprintln("[font] freetype.dll 缺导出符号,退回 stb 光栅化")
		return
	}
	lib : FT_Library
	if ft_init_free_type(&lib) != FT_ERR_OK {
		fmt.eprintln("[font] FT_Init_FreeType 失败,退回 stb 光栅化")
		return
	}
	ft_lib = lib
	ft_library_version(lib, &ft_major, &ft_minor, &ft_patch)
	ft_module = h // 常驻
	ft_ready = true
	fmt.eprintfln("[font] FreeType %d.%d.%d 已加载,hinting=%s", ft_major, ft_minor, ft_patch,
		HintingName(hinting_mode))
}

FtAvailable :: proc() -> bool {
	initFreeType()
	return ft_ready
}

FtVersion :: proc() -> string {
	if !ft_ready {
		return "无"
	}
	return fmt.tprintf("%d.%d.%d", ft_major, ft_minor, ft_patch)
}

// ---------------------------------------------------------------------------
// face 打开/关闭
// ---------------------------------------------------------------------------
// em_px = 目标 em 像素尺寸(26.6 定点,允许小数:与 stb 的 scale 保持同一 em)。
// data 必须保活到 ftFaceClose。
ftFaceOpen :: proc(data : []byte, em_px : f32) -> (face : FT_Face, ok : bool) {
	if !FtAvailable() || len(data) == 0 || em_px <= 0 {
		return nil, false
	}
	if ft_new_memory_face(ft_lib, raw_data(data), FT_Long(len(data)), 0, &face) != FT_ERR_OK {
		return nil, false
	}
	// char_height 单位 1/64 点;分辨率 0 = 72dpi ⇒ 1/64 像素
	if ft_set_char_size(face, 0, FT_F26Dot6(em_px * 64 + 0.5), 0, 0) != FT_ERR_OK {
		ft_done_face(face)
		return nil, false
	}
	return face, true
}

ftFaceClose :: proc(face : FT_Face) {
	if face != nil && ft_ready {
		ft_done_face(face)
	}
}

// ---------------------------------------------------------------------------
// 光栅化
// ---------------------------------------------------------------------------
FtBitmap :: struct {
	w, h   : int, // 位图尺寸
	left   : int, // 相对字形原点(x 向右)
	top    : int, // 相对基线(y 向上;屏幕坐标 yoff = -top)
	pitch  : int,
	buffer : [^]u8,
}

ftLoadFlags :: proc(h : Hinting) -> FT_Int32 {
	switch h {
	case .Off, .Stb:
		return FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP // .Stb 不走这里,同值兜底
	case .Light:
		return FT_LOAD_TARGET_LIGHT | FT_LOAD_NO_BITMAP
	case .Normal:
		return FT_LOAD_TARGET_NORMAL | FT_LOAD_NO_BITMAP
	}
	return FT_LOAD_TARGET_NORMAL | FT_LOAD_NO_BITMAP
}

// 光栅化一个字形;gid = 0 时按 cp 查(与 stb 的 gid 空间一致,由 ftcheck 校验)。
// 只接受 8 位灰度覆盖率(FT_RENDER_MODE_NORMAL 的保证);其它格式视为失败(不画垃圾)。
ftRender :: proc(face : FT_Face, gid : c.int, cp : rune, h : Hinting) -> (out : FtBitmap, ok : bool) {
	if face == nil || !ft_ready {
		return {}, false
	}
	idx := FT_UInt(gid)
	if idx == 0 {
		idx = ft_get_char_index(face, FT_ULong(cp))
		if idx == 0 {
			return {}, false
		}
	}
	if ft_load_glyph(face, idx, ftLoadFlags(h)) != FT_ERR_OK {
		return {}, false
	}
	slot := face.glyph
	if slot == nil {
		return {}, false
	}
	if ft_render_glyph(slot, FT_RENDER_MODE_NORMAL) != FT_ERR_OK {
		return {}, false
	}
	bm := &slot.bitmap
	if bm.width == 0 || bm.rows == 0 {
		return {}, false // 空白字形(空格等)
	}
	if bm.pixel_mode != FT_PIXEL_MODE_GRAY || bm.buffer == nil || bm.pitch == 0 {
		return {}, false
	}
	return FtBitmap {
		w = int(bm.width),
		h = int(bm.rows),
		left = int(slot.bitmap_left),
		top = int(slot.bitmap_top),
		pitch = int(bm.pitch),
		buffer = bm.buffer,
	}, true
}

// 调试/校验用:读取布局关键字段(playground/ftcheck 与 stb 逐项对照)
FtProbe :: struct {
	num_glyphs, units_per_em : int,
	ascender, descender      : int,
	has_glyph                : bool,
}

ftProbe :: proc(face : FT_Face, cp : rune) -> FtProbe {
	if face == nil {
		return {}
	}
	return FtProbe {
		num_glyphs = int(face.num_glyphs),
		units_per_em = int(face.units_per_EM),
		ascender = int(face.ascender),
		descender = int(face.descender),
		has_glyph = ft_get_char_index != nil && ft_get_char_index(face, FT_ULong(cp)) != 0,
	}
}

ftCharIndex :: proc(face : FT_Face, cp : rune) -> int {
	if face == nil || ft_get_char_index == nil {
		return 0
	}
	return int(ft_get_char_index(face, FT_ULong(cp)))
}

// 单字形位图盒(不写图集;ftcheck 用)
ftBox :: proc(face : FT_Face, cp : rune, h : Hinting) -> (w, hh, left, top : int, ok : bool) {
	fb, fok := ftRender(face, 0, cp, h)
	if !fok {
		return 0, 0, 0, 0, false
	}
	return fb.w, fb.h, fb.left, fb.top, true
}
