# Surehand 安装脚本（Windows）
#
# 目标：把仓库放到技能目录，并跑一次引擎验收。
# 不覆盖已存在的目录——有内容就停下来说清楚。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
param(
    [string]$Target = "$env:USERPROFILE\.workbuddy\skills\surehand"
)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "源目录：$src"
Write-Host "目标：  $Target"

if ((Resolve-Path $src).Path -eq $Target) {
    Write-Host '已经在技能目录里，跳过复制。'
}
elseif (Test-Path $Target) {
    Write-Host ''
    Write-Host '目标已存在，没有动它。想重装的话先自己处理：' -ForegroundColor Yellow
    Write-Host ('  Rename-Item "{0}" "{0}.bak.{1}"' -f $Target, (Get-Date -Format 'yyyyMMddHHmmss'))
    Write-Host '然后重跑本脚本。'
    exit 1
}
else {
    $parent = Split-Path -Parent $Target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    # 先试目录联接（不需要管理员权限，git pull 后立即生效）；不行就复制。
    $linked = $false
    try {
        New-Item -ItemType Junction -Path $Target -Target $src | Out-Null
        $linked = $true
    } catch {
        Copy-Item -Path $src -Destination $Target -Recurse -Force
    }
    if ($linked) { Write-Host '已创建目录联接。' } else { Write-Host '已复制文件。' }
}

Write-Host ''
Write-Host '环境检查……'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host '找不到 Python。装一个（3.8+），并确保 python 在 PATH 里。' -ForegroundColor Red
    exit 1
}
& $py.Source "$Target\scripts\cli.py" up

Write-Host ''
Write-Host '通道起来之后建议跑一次引擎验收（会起一个记事本当靶子）：'
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}\engine\windows\verify.ps1"' -f $Target)
Write-Host ''
Write-Host '两点硬约束：'
Write-Host '  1. 必须是 Windows PowerShell 5.1，不能用 pwsh（那边没有 UIAutomation 程序集）'
Write-Host '  2. 管理员权限的窗口受 UIPI 保护，普通进程点不进去'
