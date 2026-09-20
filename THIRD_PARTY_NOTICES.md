# 第三方组件与许可

CompileErrorTerminal (CETerm) 自身以 **GPL-3.0-only** 发布(见 `LICENSE`)。
本文件列出随发行包分发的第三方组件、各自许可与许可原文。

发行包内与本文件一起分发的文件即下表"随包文件"一列。

---

## 汇总

| 组件 | 版本 | 许可 | 随包文件 | 用途 |
|---|---|---|---|---|
| [SDL3](#sdl3) | 3.4.2 | Zlib | `SDL3.dll` | 窗口、输入、OpenGL 上下文、PNG 解码 |
| [ConPTY / OpenConsole](#conpty--openconsole) | 1.24.260710001 | MIT | `resource/conpty/x64/conpty.dll`<br>`resource/conpty/x64/OpenConsole.exe` | 伪控制台(Pseudoconsole)宿主 |
| [FreeType](#freetype) | 2.9.1 | FTL / GPLv2 | `resource/freetype/x64/freetype.dll` | 字形栅格化(hinting) |
| [zlib](#zlib) | — | Zlib | `resource/freetype/x64/zlib1.dll` | FreeType 的压缩依赖 |
| [主题配色](#主题配色) | — | MIT | `resource/themes.ceterm` | 24 套配色方案的色值来源 |

**未随包分发的第三方内容**:字体。CETerm 不含任何字体文件,字形一律取自使用者系统已安装的字体。

---

## SDL3

- 版本:3.4.2
- 来源:<https://github.com/libsdl-org/SDL>
- 许可:**Zlib**
- 随包文件:`SDL3.dll`

```
Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

---

## ConPTY / OpenConsole

- 包:`Microsoft.Windows.Console.ConPTY` **1.24.260710001**
  (来自 Windows Terminal release [v1.24.11911.0](https://github.com/microsoft/terminal/releases/tag/v1.24.11911.0) 的发行资产)
- 来源:<https://github.com/microsoft/terminal>
- 许可:**MIT**(该 NuGet 包的 nuspec 中 `<license type="expression">MIT</license>`)
- 随包文件:`resource/conpty/x64/conpty.dll`、`resource/conpty/x64/OpenConsole.exe`
- 说明:这两个文件是 Microsoft 官方构建的二进制,未经修改。它们顶替 Windows 装箱的 `conhost.exe`
  ConPTY 实现(新版实现任何 Windows 版本都不随系统发布,见
  [microsoft/terminal#17452](https://github.com/microsoft/terminal/issues/17452))。
  两个文件必须同目录,`conpty.dll` 在自身所在目录查找宿主 `OpenConsole.exe`。

```
MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## FreeType

- 版本:2.9.1(运行时由 `FT_Library_Version` 打印实际版本)
- 来源:Odin 工具链 vendor 目录中 SDL2_ttf 发行包内的 `libfreetype-6.dll`(仅改名,未修改)
- 许可:**FreeType License (FTL) / GPLv2 双许可**
- 随包文件:`resource/freetype/x64/freetype.dll`
- **许可原文随包分发**:`resource/freetype/LICENSE.freetype.txt`

---

## zlib

- 来源:同 FreeType(SDL2_ttf 发行包内的 `zlib1.dll`)
- 许可:**Zlib**
- 随包文件:`resource/freetype/x64/zlib1.dll`
- **许可原文随包分发**:`resource/freetype/LICENSE.zlib.txt`

---

## 主题配色

`resource/themes.ceterm` 中的 24 套配色方案,其 ANSI 16 色与前景/背景色取自以下公开配色集
(均为 MIT 许可),其余派生字段(框线、标签栏、选区等)由 CETerm 按固定规则计算得出,
计算方法记录在该文件头部的注释里:

- [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)(MIT)
- [WezTerm](https://github.com/wezterm/wezterm) 的 `scheme_data.rs`(MIT)
- [Gogh](https://github.com/Gogh-Co/Gogh)(MIT)
- [terminal.sexy](https://terminal.sexy/)
- [base16](https://github.com/chriskempson/base16)(MIT)

---

## 构建期依赖(不随包分发)

| 组件 | 许可 | 用途 |
|---|---|---|
| [Odin](https://github.com/odin-lang/Odin) 编译器与标准库 | BSD-3-Clause | 编译本项目 |
