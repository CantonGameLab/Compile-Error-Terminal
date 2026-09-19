# FreeType 载荷(随包第三方)

CETerm 用 FreeType 做字形光栅化,以取得 **hinting(网格拟合)** —— stb_truetype 没有这个能力。
无 hinting 时笔画落不到像素网格上:实测同字体同 em 下,`中` 的灰度级数 37(每条笔画相位各不
相同 = 毛刺)、`三` 的三横落在 2/3/3 行还各带一条灰底行;FreeType `normal` 下分别是 11 和统一
的 2 行。注意"超采样"不是解药:stb 本来就按精确覆盖率光栅化,真做 3× 超采样后位图只差 0.26%。

| 文件 | 来源 | 版本 | 许可 |
|---|---|---|---|
| `x64/freetype.dll` | Odin vendor 的 SDL2_ttf 发行包(`reference/odin/vendor/sdl2/ttf/libfreetype-6.dll`,改名) | **2.9.1**(启动日志用 `FT_Library_Version` 打印实际值) | FTL / GPLv2 → `LICENSE.freetype.txt` |
| `x64/zlib1.dll` | 同上(`zlib1.dll`) | zlib | `LICENSE.zlib.txt` |

两个文件**必须放在同一目录**:`freetype.dll` 的导入表里有 `zlib1.dll`。

## 加载方式(有坑,别改回去)

`src/font/freetype.odin` 的 `loadFreeTypeDll`:

1. 先试裸名 `freetype.dll`(exe 同目录 / 系统 / PATH —— 便携部署用);
2. 否则显式 `LoadLibraryW(<资源根>/freetype/x64/zlib1.dll)`,再 `LoadLibraryW(.../freetype.dll)`。

**不要**改成 `LoadLibraryExW(..., LOAD_WITH_ALTERED_SEARCH_PATH)` 或 `LOAD_LIBRARY_SEARCH_*`:
本机实测那两类标志会被代码完整性策略挡掉(分别报 err=15700 "The process has no package
identity" 与 err=577 `ERROR_INVALID_IMAGE_HASH`),而普通全路径 `LoadLibraryW` 正常。
`playground/ftdll/` 可以把这几种方式在干净进程里逐个单测。

## 运行时行为

- 找不到 DLL / 缺导出符号 / 初始化失败 → **不致命**:打印一行 stderr,光栅化退回 stb(无
  hinting),其余功能照常。
- hinting 模式运行时可切:`hinting stb|off|light|normal`(省略参数 = 查询当前)。切换会清空
  字形缓存并复位图集分配游标,下一帧重新光栅化。
- 布局依据 FreeType 2.14 头文件编写,但 `FT_GlyphSlotRec.glyph_index` 自 2.10 起才存在
  (2.9 里是同样大小的 `reserved`)—— 所以对 2.9.1 也成立。`playground/ftcheck` 会把字型数 /
  units_per_EM / ascender / descender / gid / 位图指标与 stb 逐项实测对照,布局写错立刻暴露。
