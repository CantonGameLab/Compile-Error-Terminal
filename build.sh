#!/bin/sh
# CompileErrorTerminal (CETerm) — build.ps1 的 bash 入口。
#
# 为什么需要它:在 Git Bash / msys2 bash 里敲 ./build.ps1,bash 会拿着这个文件当 sh 脚本解析,
# 读到 [CmdletBinding()] 就报 "syntax error near unexpected token `]'"。.ps1 的执行关联只对
# Windows 的 PowerShell/cmd 生效,bash 不认。
#
# 这里只做转发:构建逻辑全部在 build.ps1 里,不复制第二份实现(两份实现必然会漂移)。
#
# 用法(与 build.ps1 完全相同):
#     ./build.sh              开发/自测构建
#     ./build.sh -Stage       发布构建(真实拷贝 resource/,出便携目录)
#     ./build.sh -NoSmoke     跳过启动冒烟测试
set -e

here=$(cd "$(dirname "$0")" && pwd)

# 转成 Windows 路径,免得原生 powershell.exe 收到 /c/... 这种 msys 路径
if command -v cygpath >/dev/null 2>&1; then
    script=$(cygpath -w "$here/build.ps1")
else
    script="$here/build.ps1"
fi

if command -v powershell.exe >/dev/null 2>&1; then
    ps=powershell.exe
elif command -v powershell >/dev/null 2>&1; then
    ps=powershell
else
    echo "错误: 找不到 powershell.exe(请在 Windows 的 PowerShell 里改用 .\\build.ps1)" >&2
    exit 1
fi

# exec:不套一层 shell,退出码原样传出去
exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" "$@"
