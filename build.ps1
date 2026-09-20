# CompileErrorTerminal (CETerm) — 发布构建脚本。
#
# ⚠️ 本文件必须保存为「UTF-8 带 BOM」(前 3 字节 = EF BB BF)。
#    Windows PowerShell 5.1 对没有 BOM 的 .ps1 会按系统 ANSI 代码页解码(中文系统 = GBK),
#    中文注释被解成乱码后会把引号/括号拆错位,脚本直接语法错误 —— 而且报错位置毫无道理
#    (会指向一句完全正常的 Write-Host)。多数编辑器"另存为 UTF-8"默认不加 BOM,改完请确认。
#    build.sh 相反:shell 脚本绝不能有 BOM,否则 shebang 前面多出乱码字节,直接拒跑。
#
# 解决的核心问题:exe 输出到 build/ 之后跑不起来。
#   ① SDL3 是动态链接(foreign import lib { "SDL3.lib" }),Windows 从 exe 同目录解析导入表 ——
#      DLL 不在 build/ 里,进程在进入 main 之前就被加载器杀掉,连一行错误都打不出来。
#      这一层程序内部无法自救(导入表在 main 之前解析),只能把 DLL 放到 exe 旁边。
#   ② 资源根解析顺序是 <exe目录>/resource → <cwd>/resource(见 src/paths/paths.odin),
#      双击 build/ceterm.exe 时两者都是 build/resource,于是读不到 shader/字体。
#
# 用法(仓库根目录):
#     .\build.ps1              开发/自测构建:exe + SDL3.dll + build/resource 目录联接(瞬时,零拷贝)
#     .\build.ps1 -Stage       发布打包:装配便携目录 + 出 zip + SHA256SUMS(见下"产物")
#     .\build.ps1 -Console     构建控制台子系统版本(开发排查用,见下)
#     .\build.ps1 -NoSmoke     跳过启动冒烟测试
#   bash(Git Bash / msys2)里用 ./build.sh,参数完全相同 —— bash 直接跑 .ps1 会当 sh 脚本解析并报错。
#
# 关于子系统(默认 -subsystem:windows):
#   控制台子系统(PE Subsystem = 3)的程序,Windows 在启动时**必须**给它分配一个控制台窗口 ——
#   双击时就会多弹一个黑框(等于每次都要多开一个终端宿主)。GUI 子系统(Subsystem = 2)不分配。
#   代价:GUI 子系统下进程不挂到父控制台,从终端启动也看不到 fmt.println/eprintln 的输出。
#   要边跑边看日志就用 -Console 构建;或重定向输出(重定向会给出有效 std 句柄,照样能拿到日志)。
#
# 产物(总在 build/ 下,是开发/自测布局):
#     build/ceterm.exe        带图标与版本信息(经 ceterm.rc)
#     build/SDL3.dll
#     build/resource/         联接(默认)或真实拷贝(-Stage)
#
# -Stage 额外产出(可直接上传 GitHub Releases):
#     build/CETerm-<版本>-win64/        便携目录:exe + SDL3.dll + resource/ + 文档
#     build/CETerm-<版本>-win64.zip     压缩包(顶层目录名同便携目录)
#     build/SHA256SUMS.txt
#   版本号从 ceterm.rc 的 FileVersion 字符串解析 —— 编进 exe 的版本信息与包名同源,不会对不上。
[CmdletBinding()]
param(
    [switch]$Stage,
    [switch]$Console,
    [switch]$NoSmoke,
    [int]$SmokeWaitMs = 2500
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$outDir = Join-Path $root 'build'
$exe    = Join-Path $outDir 'ceterm.exe'
$dll    = Join-Path $outDir 'SDL3.dll'
$resDir = Join-Path $outDir 'resource'

function Fail($msg) { Write-Host "错误: $msg" -ForegroundColor Red; exit 1 }

# 删目录。目录联接必须非递归删除 —— 只摘掉重解析点(链接本身),不跟进目标:
# 实测本机 PowerShell 5.1.26100 的 Remove-Item -Recurse 对联接是安全的(只删链接、目标幸存),
# 但这条路径走错的代价是删掉 resource/ 里 127MB 字体,所以不赌版本行为。
# 不用 cmd /c rmdir:本机 PATH 里 msys2 的 /usr/bin/cmd 会抢先命中,拿到的不是 Windows 的 cmd.exe。
function Remove-Tree($path) {
    if (-not (Test-Path $path)) { return }
    if ((Get-Item $path -Force).LinkType) { [System.IO.Directory]::Delete($path, $false) }
    else { Remove-Item $path -Recurse -Force }
}

# --- 0. 版本:取自 ceterm.rc 里 FileVersion 的字符串值 ---
# 用它而不是 FILEVERSION 的二进制四段值:Windows 强制那四段是数字(0,451,0,0),
# 而显示串可以直接写 "0.451"。这个串同时喂资源管理器"详细信息"、发布包名和 git tag,
# 三者天然一致,不会出现"exe 里写 0.451.0.0、包名叫 v0.451.0"这种对不上的情况。
$ver = $null
if ((Get-Content (Join-Path $root 'ceterm.rc') -Raw) -match 'VALUE\s+"FileVersion"\s*,\s*"([^"]+)"') {
    $ver = $Matches[1]
} else {
    Fail "无法从 ceterm.rc 解析 FileVersion 字符串"
}
$pkgName = "CETerm-$ver-win64"

# --- 1. 定位 Odin(项目自带工具链优先,其次 PATH)---
$odin = Join-Path $root 'reference\odin\odin.exe'
if (-not (Test-Path $odin)) {
    $cmd = Get-Command odin -ErrorAction SilentlyContinue
    if (-not $cmd) { Fail "找不到 Odin 编译器(reference\odin\odin.exe 与 PATH 都没有)" }
    $odin = $cmd.Source
}

# --- 2. 编译(-resource 需要 cwd = 仓库根,所以上面先 Set-Location)---
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$subsystem = if ($Console) { 'console' } else { 'windows' }
Write-Host "[1/5] 编译 src/ -> build/ceterm.exe  (-subsystem:$subsystem, v$ver)"
& $odin build src/ -out:$exe -resource:ceterm.rc "-subsystem:$subsystem"
if ($LASTEXITCODE -ne 0) { Fail "编译失败(exit $LASTEXITCODE)" }

# 复核产物子系统 —— 这是"双击会不会多弹一个控制台窗口"的唯一判据,别靠猜
$pe = [System.IO.File]::ReadAllBytes($exe)
$sub = [BitConverter]::ToUInt16($pe, [BitConverter]::ToInt32($pe, 0x3C) + 24 + 68)
$subName = switch ($sub) { 2 { 'GUI —— 不分配控制台窗口' } 3 { 'Console —— 双击必然多一个黑框' } default { "未知($sub)" } }
Write-Host "      PE Subsystem = $sub : $subName"
if (-not $Console -and $sub -ne 2) { Fail "期望 GUI 子系统(2),实际 $sub —— 检查 -subsystem 是否被 Odin 接受" }
if ($Console -and $sub -ne 3) { Fail "期望控制台子系统(3),实际 $sub" }

# --- 3. SDL3.dll 放到 exe 旁边(必须在,否则程序进不了 main)---
Write-Host "[2/5] 部署 SDL3.dll"
$dllSrc = Join-Path $root 'SDL3.dll'
if (-not (Test-Path $dllSrc)) {
    # 回落:Odin 自带的 vendor 副本(与仓库根那份是同一个文件)
    $dllSrc = Join-Path $root 'reference\odin\vendor\sdl3\SDL3.dll'
}
if (-not (Test-Path $dllSrc)) { Fail "找不到 SDL3.dll(仓库根与 reference\odin\vendor\sdl3 都没有)" }
Copy-Item $dllSrc $dll -Force
Write-Host ("      $dllSrc -> build\SDL3.dll ({0:N0} bytes)" -f (Get-Item $dll).Length)

# --- 4. 资源目录 ---
if ($Stage) {
    Write-Host "[3/5] -Stage:真实拷贝 resource/ 到 build\(装配用源)"
    Remove-Tree $resDir
    # robocopy 会跟随目录联接,所以上面先删干净;退出码 <8 都算成功
    & robocopy (Join-Path $root 'resource') $resDir /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "robocopy 失败(exit $LASTEXITCODE)" }
    $n = (Get-ChildItem $resDir -Recurse -File).Count
    Write-Host "      build\resource\ 共 $n 个文件"
} else {
    Write-Host "[3/5] 目录联接 build\resource -> ..\resource(瞬时;要真实拷贝用 -Stage)"
    if (Test-Path $resDir) {
        if ((Get-Item $resDir -Force).LinkType) {
            # 已经是联接:重建以跟上目标路径变化
            Remove-Tree $resDir
            New-Item -ItemType Junction -Path $resDir -Target (Join-Path $root 'resource') | Out-Null
            Write-Host "      联接已刷新"
        } else {
            Write-Host "      已存在真实目录,保留不动(要改回联接请先删掉 build\resource)"
        }
    } else {
        New-Item -ItemType Junction -Path $resDir -Target (Join-Path $root 'resource') | Out-Null
        Write-Host "      联接已建立"
    }
}

# --- 5. 冒烟测试:从 build/ 启动,模拟双击(cwd = build,不走仓库根回落)---
if ($NoSmoke) {
    Write-Host "[4/5] 跳过冒烟测试"
} else {
    Write-Host "[4/5] 冒烟测试(从 build/ 启动,等价于双击)"
    $errFile = Join-Path $outDir '_smoke_err.txt'
    $outFile = Join-Path $outDir '_smoke_out.txt'
    Remove-Item $errFile, $outFile -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath $exe -WorkingDirectory $outDir -PassThru `
        -RedirectStandardError $errFile -RedirectStandardOutput $outFile
    Start-Sleep -Milliseconds $SmokeWaitMs
    $alive = -not $proc.HasExited
    if ($alive) { Stop-Process -Id $proc.Id -Force }
    Start-Sleep -Milliseconds 200

    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    Remove-Item $errFile, $outFile -ErrorAction SilentlyContinue

    if ($err -match '\[font\]|\[conpty\]') {
        # 已经走到字体/ConPTY 初始化 = 加载器、GL、资源三关都过了
        Write-Host "      OK:已初始化到字体+ConPTY,程序能起来" -ForegroundColor Green
    } elseif ([string]::IsNullOrWhiteSpace($err) -and [string]::IsNullOrWhiteSpace($out) -and -not $alive) {
        Fail "程序在进入 main 之前就退出了(没有任何输出)= 导入表解析失败,检查 build\SDL3.dll 是否存在、架构是否匹配"
    } else {
        Write-Host "      FAIL:启动后未到达字体初始化" -ForegroundColor Red
        if ($err) { Write-Host "      stderr: $($err.Trim())" }
        if ($out) { Write-Host "      stdout: $($out.Trim())" }
        exit 1
    }
}

# --- 6. 打包(-Stage):装配便携目录 + zip + 校验和 ---
if (-not $Stage) {
    Write-Host "[5/5] 未指定 -Stage,跳过打包(build\ceterm.exe 已可直接运行)"
} else {
    $pkgDir = Join-Path $outDir $pkgName
    Write-Host "[5/5] 装配 $pkgName\"
    Remove-Tree $pkgDir
    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null

    Copy-Item $exe (Join-Path $pkgDir 'ceterm.exe')
    Copy-Item $dll (Join-Path $pkgDir 'SDL3.dll')
    & robocopy $resDir (Join-Path $pkgDir 'resource') /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "robocopy resource 失败(exit $LASTEXITCODE)" }

    # 文档随包分发:缺了要吵,但不能因为缺文档就不出包
    foreach ($doc in 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md') {
        $srcDoc = Join-Path $root $doc
        if (Test-Path $srcDoc) { Copy-Item $srcDoc (Join-Path $pkgDir $doc) }
        else { Write-Host "      注意:缺 $doc,包里不含它" -ForegroundColor Yellow }
    }

    $zip = Join-Path $outDir "$pkgName.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    # Compress-Archive 会把顶层目录名一起写进包,解压出来就是 CETerm-<版本>-win64\
    Compress-Archive -Path $pkgDir -DestinationPath $zip -CompressionLevel Optimal

    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    "$hash  $pkgName.zip" | Set-Content (Join-Path $outDir 'SHA256SUMS.txt') -Encoding ASCII

    # 逐条打印包内清单:发布前人眼过一遍,比事后被用户发现少文件强
    $files = Get-ChildItem $pkgDir -Recurse -File | Sort-Object FullName
    Write-Host ("      包内 {0} 个文件,压缩后 {1:N2} MB" -f $files.Count, ((Get-Item $zip).Length / 1MB))
    foreach ($f in $files) {
        Write-Host ("        {0,10:N0}  {1}" -f $f.Length, $f.FullName.Substring($pkgDir.Length + 1))
    }
    Write-Host "      SHA256 $hash"
}

Write-Host ""
if ($Stage) {
    Write-Host "完成。发布包:" -ForegroundColor Green
    Write-Host "    build\$pkgName.zip"
    Write-Host "    build\SHA256SUMS.txt"
    Write-Host ""
    Write-Host "上传 GitHub Releases(打 tag 后):"
    Write-Host "    gh release create v$ver build\$pkgName.zip build\SHA256SUMS.txt"
} else {
    Write-Host "完成。运行:" -ForegroundColor Green
    Write-Host "    .\build\ceterm.exe"
}
