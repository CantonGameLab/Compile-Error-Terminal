# CETerm 发布流程(Release Pipeline)

> 状态:**设计稿**。本文定义"发一个版本"的完整流程与判定标准;实现按 §11 顺序推进。
> 文中所有体积/数量均为实测值,不是估算。

## 1. 目标与硬约束

**目标**:一条命令产出可发布的 Windows x64 便携包;打 tag 后 CI 自动构建 → 校验 → 发布到 GitHub Releases。

**硬约束**(每条都有实测依据,不是设想):

| 约束 | 依据 |
|---|---|
| 便携 zip:不安装、不写注册表 | 项目定位 |
| 运行时只依赖 `SDL3.dll` | 实测 exe 导入表 = `SDL3.dll` + `KERNEL32.dll`,无 VC++ redist |
| PE 子系统必须是 **2 (GUI)** | 子系统 3 会让 Windows 每次启动都分配控制台窗口(双击多一个黑框) |
| **不打包字体** | `resource/font/` 曾占 127.38 MB = 资源目录的 98.4%;已从工作区删除 |
| 无字体也必须能起来 | 实测:`resource/font/` 为空 → 冒烟测试通过(字体索引回落到系统字体) |
| Windows 10 1809+ / x64 | 装箱 ConPTY 的下限;外部 `conpty.dll` 亦声明 `10.0.17763.0` 以上 |

## 2. 产物形态

```
CETerm-0.1.0-win64.zip
└── CETerm-0.1.0-win64/
    ├── ceterm.exe                 1.1 MB   GUI 子系统,内嵌图标 + VERSIONINFO
    ├── SDL3.dll                   2.8 MB
    ├── resource/
    │   ├── config.ceterm          3.8 KB   出厂配置(由 config.factory.ceterm 改名而来)
    │   ├── themes.ceterm         32.1 KB   24 套主题
    │   ├── shader/                6 个     GLSL
    │   ├── freetype/x64/                  freetype.dll + zlib1.dll + 两份 LICENSE
    │   ├── conpty/x64/                    conpty.dll + OpenConsole.exe
    │   ├── icon/ceterm.png       34 KB     运行时窗口图标
    │   └── font/README.md                 新建:告诉用户把字体放这里
    ├── README.md
    ├── LICENSE                            GPL-3.0
    ├── THIRD_PARTY_NOTICES.md
    └── CHANGELOG.md
```

外加两个**独立**的 Release 附件(不放进 zip):

- `SHA256SUMS.txt`
- `CETerm-0.1.0-win64.zip.sha256`

解压后约 **6 MB**,zip 约 **3 MB**(待首次实测确认)。

## 3. 版本单一来源

**问题**:`ceterm.rc` 里版本号写死 `0.1.0.0`,发布时一定会忘。

**方案**:

1. 新增根目录 `VERSION` 文件,内容一行 SemVer:`0.1.0` —— **唯一真相**。
2. `ceterm.rc` → 改为模板 `ceterm.rc.in`,占位符 `@VERSION@`(点分)与 `@VERSION_COMMA@`(逗号分)。
3. `build.ps1` 读 `VERSION` → 生成 `build/ceterm.rc`。
   顺带解决另一个问题:`ceterm.res` 中间产物落在 `.rc` 旁边,现在会落进 `build/`(已 gitignore),不再污染仓库根。
4. 同时用 `-define:CETERM_VERSION="0.1.0"` 注入程序,新增 `version` 命令(F2 命令栏可查,启动时也打一行)。
5. **CI 强校验**:tag `v0.1.0` 必须与 `VERSION` 内容逐字相等,否则直接失败。

## 4. 出厂配置 vs 用户配置

现状 `resource/config.ceterm` 是**你的个人配置**(`theme gruvbox-dark`、`default-launch "C:\msys64\msys2_shell.cmd ..." "Hack Nerd Font"`)。发布包不能发这个 —— 别人机器上没有 msys2,也没有那个字体。

已确认的解析顺序(`src/command/config.odin:33-48`):

1. `%LOCALAPPDATA%\CETerm\config.ceterm` —— 用户配置,**优先**
2. `<资源根>/config.ceterm` —— 出厂兜底

**方案**:

- 仓库里 `resource/config.ceterm` 保持"开发用"(你的),不动。
- 新增 `resource/config.factory.ceterm` = 出厂配置:系统自带字体 + `default-launch "cmd.exe"` + 保守的 vsync 设置。
- `build.ps1 -Stage` 装配时把它复制为包内的 `config.ceterm`。
- **首次运行体验**(P0 必须做):`%LOCALAPPDATA%\CETerm\` 不存在时,除了用出厂配置,还要能告诉用户"配置文件在哪、怎么改"—— 否则新手打开是一片默认外观,不知道从哪下手。

> ⚠️ **未验证的前提**:出厂配置写的字体名在"没装 Nerd Font 的干净机器"上会回退成什么?
> 必须在干净环境实测一次,否则发出去的包在别人机器上可能是糊的或方框。

## 5. 本地装配流程

`build.ps1` 从现在的 4 步扩成 8 步:

```
[1/8] 读 VERSION → 生成 build/ceterm.rc
[2/8] 编译 src/ → build/ceterm.exe  (-o:speed -subsystem:windows -resource:build/ceterm.rc)
[3/8] 校验 PE:子系统=2、Machine=0x8664、非系统导入只有 SDL3.dll
[4/8] 部署 SDL3.dll + 校验 SHA256(与 reference/odin/vendor/sdl3/SDL3.dll 一致)
[5/8] 冒烟测试(启动到 font+conpty)—— 本地特有,CI 不跑(见 §7)
[6/8] -Stage:装配便携目录(ceterm.exe + SDL3.dll + resource/ + 文档)
[7/8] 校验装配完整性(逐条对照清单 + zip 内容比对)
[8/8] 生成 SHA256SUMS.txt + zip
```

**新增的关键校验**(防的是"发出去的包在别人机器上起不来"):

- **导入表白名单**:解析 PE 导入表,断言非系统 DLL 只有 `SDL3.dll`。多出任何东西 = 失败。
  这条能挡住"某次依赖变更引入了新的隐式 DLL 依赖"这种最难排查的发布事故。
- **架构**:PE Machine == `0x8664`。
- **资源清单**:`tools/release-manifest.txt` 逐行列出包内必须存在的相对路径,缺一个即失败。
  比"我记得要拷 shader/"可靠。
  **必须包含 `resource/conpty/x64/OpenConsole.exe`**:`conpty.dll` 只是壳,缺宿主 exe 时会**静默**
  用回装箱 conhost(实测踩过,见 `resource/conpty/README.md`)—— 少拷这一个文件,包没有任何报错,
  只是 ConPTY 新实现从来没生效。

这些校验实现为**独立脚本 `tools/verify_release.ps1`**,由 `build.ps1` 与 CI **共用同一份** —— 避免本地过、CI 不过。

## 6. 第三方合规

### 6.1 现状清点

| 组件 | 版本 | 许可 | 随包分发 | 许可原文现状 |
|---|---|---|---|---|
| SDL3 | 3.4.2 | Zlib | 是(`SDL3.dll`) | ❌ **缺**:DLL 在仓库根,旁边没有许可文件 |
| FreeType | 2.9.1 | FTL / GPLv2 | 是 | ✅ `resource/freetype/LICENSE.freetype.txt` |
| zlib | — | Zlib | 是(`zlib1.dll`) | ✅ `resource/freetype/LICENSE.zlib.txt` |
| ConPTY / OpenConsole | 1.24.260710001 | MIT | 是 | ⚠️ 只在 `resource/conpty/README.md` 里写明了,没有许可原文 |
| 字体 | — | OFL/BSD | **否**(已移除) | N/A —— 移除后这块合规面直接消失 |

好消息:项目自带的 `resource/*/README.md` 已经把**版本、来源 URL、许可、更新方法**都写全了(`conpty/README.md` 连 nuspec 的 license 字段原文都记了),`THIRD_PARTY_NOTICES.md` 基本可以从这些汇总。

### 6.2 待办

1. 新增 `THIRD_PARTY_NOTICES.md`(手工维护 —— 法律文本不该自动生成),逐组件列出:名称、版本、许可、来源 URL、随包分发的文件名、许可原文位置。
2. 补 `resource/sdl3/LICENSE.sdl3.txt`(SDL3 的 Zlib 许可原文)与 `resource/conpty/LICENSE.conpty.txt`(MIT 原文)。
3. **CI 校验**:`resource/**/LICENSE*` 里每个文件都必须在 `THIRD_PARTY_NOTICES.md` 里被提到 —— 防漏。

> 不打包字体后,整个分发物的许可面收敛为 **GPL-3.0-only(自身)+ Zlib + FTL/GPLv2 + MIT**,清爽很多。

## 7. CI 工作流

### 7.1 `release.yml`(触发:`push` tag `v*`)

```
windows-latest
  1. checkout
  2. 装 Odin:钉死 dev-2026-07-nightly:819fdc7(从 odin-lang/Odin releases 下载,按版本串缓存)
  3. .\build.ps1 -Stage -NoSmoke
  4. .\tools\verify_release.ps1      ← 与本地同一份脚本
  5. 校验 tag 名 == "v" + (VERSION 内容)
  6. 打 zip + SHA256SUMS.txt
  7. gh release create $tag --generate-notes + 上传两个附件
```

> Odin 的下载资产名与校验和在实现时确认,不在这里猜。

### 7.2 `ci.yml`(触发:`push`/`PR` 到 `main`)

```
  1. checkout
  2. 装 Odin(同上,缓存)
  3. odin build src/ -out:build/ci.exe        ← 确保 main 永远可编译
  4. 跑 tests/(见下)
```

### 7.3 CI **不做**运行时冒烟测试 —— 这是刻意的

runner 上 OpenGL 4.4 core 不可靠。一个会随机假失败的 CI,唯一的效果是训练所有人忽略 CI。

所以职责切分:

| | 本地 `build.ps1` | CI |
|---|---|---|
| 能不能起来 | ✅ 真启动,跑到 font+conpty | ❌ 不跑 |
| ConPTY 宿主在位 | ✅ 日志须出现「宿主 OpenConsole.exe 已就位」;出现 `⚠` = 载荷没带全 | ❌ |
| PE 头/导入表/清单/哈希 | ✅ | ✅ |
| 干净机器上能不能用 | ❌ | ❌(都做不到,靠人工在 VM 验一次) |

### 7.4 前置问题:`playground/` 被 gitignore,CI 跑不了回归

`.gitignore` 里有 `playground/`,所以 CI 拿不到那 109 个探针 —— CI 只能验证"能编译",回归全靠你手动。

**建议**:把关键探针从 `playground/` 提升为**被跟踪的 `tests/`**,首批 3–5 个:

- `configprobe` —— 配置链路(命令解析/主题/键位)
- `themefileprobe` —— `themes.ceterm` 逐行 + 颜色值
- `iconprobe` —— 图标 PNG 的 alpha 与像素
- `pathfontprobe` —— 资源根解析 + 字体扫描
- `ftcheck` —— FreeType 布局与 stb 对照

探针本身就是"可执行断言",`odin run tests/<name>/` 即回归。

## 8. 版本与 tag 流程

- `main` = 发布分支,**永远保持可构建**。
- 发布一次:

```powershell
# 1. 改 VERSION 为 0.2.0;CHANGELOG.md 加一节
# 2. 本地出包并实测
.\build.ps1 -Stage
# 3. 提交 + 打 tag + 推
git add -A; git commit -m "release: v0.2.0"
git tag -a v0.2.0 -m "CETerm v0.2.0"
git push origin main --tags
# 4. CI 自动出包并发布
```

- **预发布**:`v0.2.0-rc.1` → GitHub Release 勾 prerelease。
- **修 bug**:出 `v0.2.1`,**不要**重用已发布的 tag —— 可能已经有人下载了。

> 推送依赖本机代理(`http.https://github.com.proxy` → `127.0.0.1:7993`)。代理没启动时 `git push` 会失败并报"连不上 github.com"。

## 9. CHANGELOG

Keep a Changelog 格式(`Added / Changed / Fixed / Removed`),`## [Unreleased]` 置顶。

Release body = **CHANGELOG 里当前版本那一节** + `gh` 自动生成的 Full Changelog 链接。比纯 `--generate-notes` 的提交流水可读得多 —— 后者会把 "fix typo" 和真正的改动混在一起。

## 10. 已知风险与待决

| # | 风险 | 处置 |
|---|---|---|
| 1 | **字体删除尚未提交** | 48 个 ttf 现在是工作区 ` D`(HEAD 里还在)。必须提交这次删除,否则 clone 仍是 127 MB、CI 与实际不一致 |
| 2 | 未做代码签名 | 首次运行会触发 SmartScreen("更多信息 → 仍要运行")。README 里写明;要消除需 OV/EV 证书(年费) |
| 3 | 出厂配置的字体回退**未验证** | §4 的 P0 项;必须在干净环境实测 |
| 4 | Odin nightly 会漂 | CI 钉死 `dev-2026-07-nightly:819fdc7`;升级走显式提交 |
| 5 | 根 `SDL3.dll` 与 `reference/odin/vendor/sdl3/SDL3.dll` 是两份 | §5 步骤 4 的哈希校验挡住不同步 |
| 6 | `playground/dsrcheck/dsrcheck.exe` 被误提交(653 KB) | `.gitignore` 里有 `playground/`,但对**已跟踪**文件无效。`git rm --cached` 清掉 |
| 7 | `docs/` 里的 `DESIGN.md`/`SCRIPT.md` 等未进发布包 | 有意为之(面向贡献者);若想让用户看到,改为随包发 |

## 11. 实施顺序

### P0 —— 出第一个 release 的最小集

1. `git rm` 字体 + 清掉误提交的 `dsrcheck.exe` + 提交(仓库 132 MB → ≈4.2 MB)
2. `VERSION` + `ceterm.rc.in` + `build.ps1` 生成 rc
3. `resource/config.factory.ceterm`(系统字体 + `cmd.exe`)
4. `build.ps1` 补 §5 的 [6][7][8] 步:装配 + 清单校验 + zip/校验和
5. `tools/verify_release.ps1`(PE/导入表/清单/哈希,本地与 CI 共用)
6. `THIRD_PARTY_NOTICES.md` + 补 SDL3/ConPTY 许可原文
7. `CHANGELOG.md` + 首版条目
8. **人工验收**:解压到干净目录 → 双击能起 → 改配置生效

### P1 —— 自动化

9. `.github/workflows/release.yml` + `ci.yml`
10. 挑 3–5 个探针提升为被跟踪的 `tests/`
11. `version` 命令 + `-define:CETERM_VERSION`

### P2 —— 打磨

12. README 重写(平台要求 / 构建 / 键位 / 配置路径 / 支持与不支持矩阵)
13. 代码签名(可选)
