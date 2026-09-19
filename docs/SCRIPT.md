# CETerm Script(配置脚本语言手册)

> 本手册描述 CETerm 的配置语言。**一套语法、一个解释器**:配置文件、命令栏输入、
> 子进程 OSC 999 信道全部走同一条链路(`ParseCommandStringEx` → `ExecuteCommand`)。
> 学会一条就三处都会。
>
> 实现落点:`src/command/`(`command.odin` 解析与解释器 / `spec.odin` 命令表 /
> `config.odin` 文件加载 / `execute.odin` 信道消费)。
> 终端处理的全部 OSC 序列见 [`OSC.md`](OSC.md);子进程信道协议见 [`OSC999.md`](OSC999.md);
> 架构与数据结构见 [`DESIGN.md`](DESIGN.md)。

---

## 1. 语言是什么

一行 = 一条命令。没有变量、没有表达式、没有控制流 —— 这是**动作脚本**,不是编程语言。

```
命令名 参数... [@目标id]
```

三种载体,同一套语义:

| 载体 | 在哪 | 特性 |
|---|---|---|
| **配置文件** | `%LOCALAPPDATA%\CETerm\config.ceterm` → 保底 `<资源根>\config.ceterm` | 逐行执行;支持 `#` / `//` 注释;支持 `load` 分片 |
| **命令栏** | F2 呼出,输入后回车 | 单条;无注释;错误原因打到 stdout/stderr |
| **OSC 999** | 子进程往终端写 `ESC]999;<命令> ST` | 单条;需要该窗格已授权;见 `OSC999.md` |

---

## 2. 词法(逐条精确)

### 2.1 分隔与引号

- 分隔符:**空格或 Tab**(两者等价,可连续)
- 引号:`"..."` 包住的整段算**一个** token,**内部可以含空格**
- **引号内不能含引号** —— 没有转义机制,`"` 一律结束字符串
- 引号可以有零个(裸 token)或多处(每个 `"..."` 各自成 token)
- 引号未闭合 = 该 token 一直到**行尾**

```
font "Cascadia Code" 20        →  3 个 token: font / Cascadia Code / 20
bind alt+h "focus left"        →  3 个 token: bind / alt+h / focus left
page-title "my work"           →  2 个 token
```

### 2.2 大小写(**最容易踩的一处**)

| 元素 | 大小写 | 依据 |
|---|---|---|
| **命令名** | 不敏感 | `nameEq`(`spec.odin:318`) |
| **键名** | 不敏感 | `ScancodeFromName` 内部转大写(`input.odin:299`) |
| **修饰名** | **敏感,必须小写** | `parseKeyCombo` 用精确 `switch` 比 `"alt"`/`"ctrl"`/`"shift"`/`"win"` |
| **`@id`** | 只能是数字 | |
| **字符串参数** | 原样保留 | 路径/字体名/标题都按字面用 |

```
BIND ALT+H "focus left"    ✗ 失败:修饰名 "ALT" 不匹配
bind alt+h "focus left"    ✓
bind Alt+H "focus left"    ✗ 同样失败
```

### 2.3 token 上限

单个命令行最多 **24 个 token**(`MAX_CMD_TOKENS`)。超出 = 报"参数过多",**不静默截断**。

### 2.4 `@目标id`

放在**行末**,指定这条命令作用于哪个窗格(不写 = 当前焦点窗格)。

- 只有**窗口类命令**接受它(表项 `target = true`);其他命令用了报 `@id 不支持`
- `@` 后面必须是数字;id 取自 `info` / `focus-get` / `count` 的输出
- id 不存在或**不在当前页树内** → 解析成空目标,命令在执行时失败

```
split right @3        # 在窗格 3 右侧分裂
factor 0.7 @2         # 把窗格 2 的父分割比例设为 0.7
info @3               # 查询窗格 3
help @3               # ✗ @id 不支持(help 不是窗口类命令)
```

### 2.5 三态参数 `[on|off]`

带 `.Toggle` 形态的命令省略参数 = **翻转当前值**:

```
vsync          # 翻转
vsync on       # 打开
vsync off      # 关闭
```

---

## 3. 配置文件

### 3.1 查找顺序

| 顺序 | 路径 | 说明 |
|---|---|---|
| 1 | `%LOCALAPPDATA%\CETerm\config.ceterm` | **用户配置**;存在且可读 → **只用它**(完全替代保底) |
| 2 | `<资源根>\config.ceterm` | **保底配置**;用户配置缺失/读失败时执行 |

- 资源根的取法见 `paths` 模块:发行版 = 可执行文件同目录的 `resource/`;开发 = `<cwd>/resource`
- 用 `LOCALAPPDATA`(本机)而非 `APPDATA`(漫游):配置属于本机
- 两份都读不到 → 报错并继续(命令栏仍可用,但没有键位)

### 3.2 逐行执行

- **一行一条命令**,行尾 `\r` 与首尾空白会被裁掉
- **注释**:行首 `#` 或 `//` 开头的整行跳过。**行内 `#` 不是注释**(只判行首)

```
# 这是注释
// 这也是注释
vsync off                  # 这行末尾的 # 属于参数,会被当成 token
```

- **没有相位**:严格按文件顺序执行。需要窗格存在的命令(`split`/`font`/`launch`)必须写在
  `page-new` **之后** —— 顺序由配置自己负责,解释器不做重排。
- **单行失败不整体回退**:stderr 报 `路径:行号 + 原因`,**继续执行后续行**。改错一行不该丢整份配置。

### 3.3 `load` 分片

```
load "themes.ceterm"                  # 相对路径 = 相对**当前文件所在目录**
load "C:/my/themes.ceterm"            # 绝对路径原样
```

- `load` 就地展开:被载入文件的行**立即插入当前执行流**,不是延后
- 相对路径基准 = 当前文件所在目录(`config_dir` 在执行期间切换,返回时恢复)
- **嵌套上限 8 层**(`CONFIG_DEPTH_MAX`),超出报错
- 被载入文件里的 `load` 再相对**它自己**的目录解析

### 3.4 加载结束的健全性检查

键位表为空时 stderr 提示一句(说明配置里一条 `bind` 都没有)。

---

## 4. 命令参考

下表**由 `src/command/spec.odin` 的 `COMMAND_SPECS` 逐条导出**(该表是唯一真相源;
`help` 输出与解析器都读它,所以任何不一致都是文档错而不是代码错)。

- **参数**列:`<>` 必填,`[]` 可选,`"..."` 是字符串参数(引号必需)
- **目标**列:✓ = 接受行末 `@id`

### 4.1 窗口树 / 焦点

| 命令 | 别名 | 参数 | 目标 | 说明 |
|---|---|---|---|---|
| `split` | | `<right\|left\|up\|down> [factor]` | ✓ | 分裂窗口;`left`/`up` = 新窗在首侧;`factor` = 原窗占比(默认 0.5) |
| `focus` | | `<id\|left\|right\|up\|down>` | | 聚焦窗口(按 id 或方向导航) |
| `destroy` | `close` | | ✓ | 关闭窗口及其会话(唯一剩余窗口 = 清空整树) |
| `factor` | | `<ratio>` | ✓ | 设置窗口父节点比例(0.05..0.95) |
| `factorleaf` | | `<n> <ratio>` | | 设置先序叶子序号 `n`(1-based)认领的 split 比例 |
| `splittype` | `rotate` | | ✓ | 切换窗口父节点的分割轴(左右 ⇄ 上下) |
| `exchange` | | `<left\|right\|up\|down>` | ✓ | 与方向邻居交换窗口内容(树结构不变) |
| `single` | `single-mode` | `[on\|off]` | | 单窗显示模式:焦点窗独占树区(省略 = 翻转) |

### 4.2 查询

| 命令 | 别名 | 参数 | 目标 | 说明 |
|---|---|---|---|---|
| `count` | `windows` | | | 查询窗口数量 |
| `info` | | | ✓ | 查询窗口信息(字体/会话/比例/自动关闭) |
| `focus-get` | `getfocus` | | | 查询焦点窗口 id |
| `size` | | | ✓ | 查询窗格尺寸(cols x rows) |
| `head` | | `<n>` | ✓ | 取**面板(视口)**从最上面数前 n 行的文本 |

**`head` 的语义细节**(常被误解):

- 起点是**面板第一行**,不是缓冲区开头。普通模式下视口贴底(显示最新),
  review 模式下跟随 `review_line`
- 每行一条,**行尾空白已裁**,宽字符按整字输出
- `n` 超过面板行数 → 给多少算多少(不报错)
- 输出受 ret 容量上限约束,**装不下时末尾补一行 `[truncated]`**(绝不静默丢 —— 否则"要 n 行"这个量化就是假的)

### 4.3 字体 / 会话

| 命令 | 别名 | 参数 | 目标 | 说明 |
|---|---|---|---|---|
| `font` | | `"<path\|name>" <size>` | ✓ | 设置窗口字体(路径或系统字体名) |
| `font` | | `<size>` | ✓ | **单数字参数** = 只改字号(等价 `fontsize`) |
| `fontset` | | `"<主字体>" "<中文字体>" <size>` | ✓ | **设置字体集**:主字体定字符格,中文字体适配它(全角 = 2 格);中文字体写 `""` = 用系统候选 |
| `fontsize` | | `<size>` | ✓ | 改字号(保留字体) |
| `fontsizeup` | | | ✓ | 字号 +2 |
| `fontsizedown` | | | ✓ | 字号 -2 |
| `launch` | | `"<cmd>"` | ✓ | 用窗口字体启动 console 应用(需先设字体) |
| `feed` | | `"<text>"` | ✓ | 向窗口会话写入输入(见 §5.1) |
| `clearconsole` | `clearc` | | ✓ | 清空窗格会话(保留窗格与字体) |
| `scroll` | | `<lines>` | ✓ | 历史滚动:正 = 向下(新),负 = 向上(旧,进 review) |
| `reviewup` | | | ✓ | 上翻一屏历史 |
| `reviewdown` | | | ✓ | 下翻一屏历史 |
| `review-exit` | `exitreview` | | ✓ | 退出 review 回实时跟随 |

### 4.4 页

| 命令 | 别名 | 参数 | 说明 |
|---|---|---|---|
| `page-new` | | `["<title>"]` | 新建页并切换(可选标题;自动建根窗 + 默认启动) |
| `page` | | `<n>` | 切换页(n = 页存活序,1-based) |
| `page-next` | | | 下一页(环绕) |
| `page-prev` | | | 上一页(环绕) |
| `page-close` | | `[n]` | 关页(缺省 = 当前页;最后一页拒绝) |
| `page-title` | `title` | `"<title>" [n]` | 设置页标题(缺省 = 当前页) |
| `pages` | | | 列出所有页(序号/标题/当前标记) |

### 4.5 选区 / 剪贴板

| 命令 | 别名 | 说明 |
|---|---|---|
| `copy` | | 复制文本选区到剪贴板 |
| `paste` | | 粘贴剪贴板到焦点窗口 |
| `clearselection` | `deselect` | 清除文本选区 |
| `selectall` | | 全选焦点窗口缓冲 |

### 4.6 外观 / UI

| 命令 | 别名 | 参数 | 说明 |
|---|---|---|---|
| `theme` | | `[name]` | 切换主题(缺省 = 列出全部主题) |
| `theme-set` | `tset` | `"<name>" <字段> <#RRGGBB>` | 设置命名主题的字段(名字不存在则新建) |
| `uifont` | | `"<path\|name>" <size>` | 设置 UI 字体(页签/状态栏/FPS 共用) |
| `uifont-reset` | `uireset` | | UI 字体回默认(`consola 18`) |
| `borderless` | `toggle-borderless` | `[on\|off]` | 无边框窗口(省略 = 翻转) |
| `vsync` | | `[on\|off]` | 垂直同步(省略 = 翻转) |
| `blockloop` | `block` | `[on\|off]` | 主循环阻塞:on = 没活就睡(静止 CPU≈0);off = 每帧无条件跑(排查用) |
| `fps` | | `[on\|off]` | 状态栏右下角 FPS 标签(**默认关**;省略 = 翻转) |
| `conpty` | | `[on\|off]` | **新会话**的 ConPTY 实现:on = 外部 `conpty.dll`(新版 OpenConsole);off = 系统 kernel32;省略 = 翻转。**只影响新会话**(已有会话的 HPCON 与实现绑定) |
| `hinting` | | `[stb\|off\|light\|normal]` | 字形光栅化模式:`stb` = stb_truetype(无 hinting,旧行为);`off`/`light`/`normal` = FreeType 提示强度(`normal` 为默认)。省略 = 查询当前。**切换后字形缓存重新光栅化**;FreeType 缺失时自动退回 stb |
| `bgshader` | `bg` | `["<path>"]` | 背景 shader:缺省 = 重载默认文件,带路径 = 编译该文件 |
| `toggle-commandbar` | `togglebar` | | 命令栏开关 |

**`theme-set` 的字段名**(完整列表见 `src/canvas/theme.odin` 的 `THEME_FIELDS`):

```
fg  bg  cursor  frame  focus_border
ansi0 .. ansi15
fps_bg  fps_fg
tab_fg  tab_active_fg  tab_bar_bg  tab_active_bg  tab_hover_bg
selection_bg  selection_fg
```

### 4.7 会话默认 / 配置

| 命令 | 别名 | 参数 | 说明 |
|---|---|---|---|
| `default-launch` | `startup` | `"<cmd>" ["<font>" <size> ["<中文字体>"]]` | 新建窗口的默认启动配置(`cmd` 空 = 不自动启动) |
| `load` | | `"<path>"` | 执行另一个命令文件(见 §3.3) |
| `cwd` | | `["<path>"]` | 全局会话工作目录:所有新窗口的初始目录(省略 = 查询当前值) |

### 4.8 键位

| 命令 | 别名 | 参数 | 说明 |
|---|---|---|---|
| `bind` | | `<mods+key> "<命令>"` | 绑定键位(见 §5.2) |
| `unbind` | | `<mods+key>` | 移除绑定(不存在 = 失败) |
| `bindings` | | | 枚举全部绑定(**输出可直接再 bind**) |

### 4.9 帮助

| 命令 | 别名 | 参数 | 说明 |
|---|---|---|---|
| `help` | `?` | `[命令]` | 列出全部命令(带参数 = 单条用法) |

**`help` 输出的行数 = 命令数 + 1**(末尾多一行提示),`parsertest` 会校验这一点 ——
所以新增命令后 `help` 行数自动跟着走。

---

## 5. 两个参数形态的特殊语义

### 5.1 `feed` 的参数解释转义(**只有它**)

子进程信道(OSC 999)的载荷物理上带不了控制字节 —— vtparse 状态机对 `0x00-0x1F`
一律 `Ignore`,所以 `\r` 会被**静默吞掉**。因此**只有 `feed` 的字符串参数**解释转义:

| 转义 | 结果 |
|---|---|
| `\r` | `0x0D` 回车 |
| `\n` | `0x0A` 换行 |
| `\t` | `0x09` 制表 |
| `\e` | `0x1B` ESC |
| `\\` | 一个反斜杠 |
| `\0` | `0x00` NUL |
| `\xNN` | 两位十六进制字节 |

**其余命令的字符串保持字面** —— 否则 `cwd "C:\Users"` 这类路径会被吃掉反斜杠。
未知转义(如 `\q`)按**字面**保留,不做替换。

```
feed "ls -la\r"        # 执行 ls 并回车
feed "\e[A"            # 上箭头
cwd "C:\Users\me"      # 反斜杠原样(不解释转义)
```

### 5.2 `bind` 的键组合

```
<mods+key>
```

- **修饰前缀**:`alt` / `ctrl`(或 `ctl`)/ `shift` / `win`(或 `super`)
  - **必须小写**;可零个,可重复出现;顺序任意;以 `+` 连接
- **键名**:SDL 的 scancode 名(`SDL_SCANCODE_` 后缀),**大小写不敏感**
  - 例:`H` `F2` `PAGEUP` `EQUALS` `W` `LEFT` `RETURN` `BACKSPACE` `SPACE`
- 键名是**物理键**,与键盘布局无关

```
bind alt+h "focus left"
bind ctrl+shift+t "page-new"
bind F2 "toggle-commandbar"
bind alt+shift+l "split right"
```

`bind` 的子命令**不能再是** `bind` / `unbind` / `help`(嵌套拒绝)。

`bindings` 的输出就是同样的语法,所以可以**导出-改-再导入**做备份。

---

## 6. 错误处理与诊断

### 6.1 失败长什么样

解析失败的原因写入 errbuf(`<命令>: <原因>(用法: ...)`),常见原因:

| 原因 | 触发 |
|---|---|
| `空命令` | 空串/纯空白/纯注释 |
| `未知命令` | 命令名不在表里 |
| `参数不足` / `参数过多` | 与表项的 `req` / `args` 不符 |
| `需要数字` / `需要整数` | `F32` / `I32` 参数解析失败 |
| `需要 on/off` | `.Toggle` 参数不是 on/off |
| `需要 right/left/up/down` | 方向参数非法 |
| `@id 需要数字` / `@id 不支持` | 见 §2.4 |
| `键组合非法` | 修饰名大小写错 / 未知修饰 / 未知键名 |
| `未知字段` / `需要 #RRGGBB` | `theme-set` |
| `子命令不能是 bind/unbind/help` | `bind` 嵌套限制 |
| `子命令表满` | `bind` 子命令槽(32)耗尽 |

### 6.2 失败时的行为差别

| 场景 | 行为 |
|---|---|
| **配置文件某行失败** | stderr 报 `路径:行号 + 原因`,**继续下一行**;统计里 `failed++` |
| **命令栏提交失败** | 原因打到 stderr(命令栏内驻留显示待做) |
| **OSC 999 失败** | 回执 `>err;<原因>`,子进程能读到(见 `OSC999.md` §3) |

### 6.3 `ret` 的三态(为什么"没有输出"和"失败"要分开)

| 态 | 含义 |
|---|---|
| `None` | 命令串显式标了 no-ret(见 `OSC999.md` §5.1)→ 消费者一个字节都不该写 |
| `Ok` | 成功;`ret` 可以为空(动作类命令没有回显) |
| `Err` | 失败;`ret` **必非空**(原因) |

**不能靠"ret 为空"判断无返回** —— on-ret 却没有返回值的命令也产生空 ret,会撞在一起。

---

## 7. 不变式清单(可断言)

1. **单一解释器**:所有命令都经 `ExecuteCommand` 分派;解析器里不写命令名特判
2. **单一真相源**:命令全集 = `COMMAND_SPECS`;`help` 行数 = 表长 + 1
3. **解析不执行**:`ParseCommandString*` 只产出数据,不碰任何业务状态
4. **命令数据可往返**:`FormatCommand(ParseCommandString(s))` 再解析得到同一条命令(`bindings` 依赖它)
5. **大小写**:命令名/键名不敏感;修饰名**必须小写**;字符串参数原样
6. **引号内无引号**:没有转义,`"` 一律结束
7. **失败必有原因**:`ok = false` 时 `ret`(或 errbuf)非空
8. **不静默截断**:超 token 上限 / ret 容量都显式报出(`参数过多` / `[truncated]`)
9. **只有 `feed` 解释转义**:其余命令的字符串参数保持字面
10. **注释只判行首**:`#` / `//` 在行首才算注释

---

## 8. 完整示例

### 8.1 一份最小可用配置

```ceterm
# ---- 主题 ----
load "themes.ceterm"
theme tango-dark

# ---- 外观 ----
default-launch "pwsh.exe" "Cascadia Code" 18
cwd "C:/Users/me/projects"
vsync off
fps off

# ---- 页 ----
page-new "main"

# ---- 焦点(Alt + HJKL)----
bind alt+h "focus left"
bind alt+l "focus right"
bind alt+k "focus up"
bind alt+j "focus down"

# ---- 分屏(Alt+Shift + HJKL)----
bind alt+shift+h "split left"
bind alt+shift+l "split right"
bind alt+shift+k "split up"
bind alt+shift+j "split down"

# ---- 页签 ----
bind ctrl+shift+t "page-new"
bind ctrl+shift+w "page-close"

# ---- 命令栏 ----
bind F2 "toggle-commandbar"

# ---- OSC 999 信道(授权当前窗格)----
bind alt+o "osc on"
```

### 8.2 从命令栏查东西

```
help                    # 列全部命令
help head               # 单条用法
count                   # 有几个窗口
info                    # 焦点窗格详情
size                    # 焦点窗格 cols x rows
head 5                  # 面板前 5 行
bindings                # 现有键位(可直接复用)
pages                   # 页列表
theme                   # 主题列表
```

### 8.3 用 `@id` 精确操作

```
count                   # → windows: 3
info @2                 # 看窗格 2 是什么
factor 0.7 @2           # 调它的分割比例
split down @3           # 在窗格 3 下面再分一个
head 24 @3              # 读窗格 3 的面板
```

### 8.4 分片组织

`config.ceterm`:

```ceterm
load "themes.ceterm"      # 相对本文件目录
load "keys.ceterm"
load "look.ceterm"
page-new
```

`keys.ceterm`(同目录):

```ceterm
bind alt+h "focus left"
bind alt+l "focus right"
```

每个分片里的相对 `load` 都相对**它自己**所在目录 —— 所以分片可以再放进子目录里。

---

## 9. 实现索引

| 关注点 | 文件 | 关键符号 |
|---|---|---|
| 命令全集(唯一真相源) | `src/command/spec.odin` | `COMMAND_SPECS` / `CommandSpec` / `findSpec` |
| 解析 | `src/command/command.odin` | `ParseCommandStringEx` / `parseTokens` / `parseKeyCombo` |
| 逆变换(`bindings` 回显) | `src/command/command.odin` | `FormatCommand` |
| 解释器(唯一) | `src/command/command.odin` | `ExecuteCommand` → userapi |
| 配置文件加载 | `src/command/config.odin` | `LoadConfig` / `configRunText` / `configLoadFile` |
| 键位表 | `src/command/keybindings.odin` | `SetKeyBinding` / `findBinding` |
| 信道消费 | `src/command/execute.odin` | `processCommandEvents` |
| 各域 userapi | `src/canvas/userapi.odin` 等 | `SplitNewWindow` / `SetThemeField` / … |

## 10. 尚未完成

- 命令栏内的结果驻留显示(当前查询输出打到 stdout)
- 配置热重载(改完配置需重启,或手动 `load`)
- `help` 未按域分组(是平铺列表)
