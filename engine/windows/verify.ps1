#requires -Version 5.1
<#
    verify.ps1 —— Windows 侧验收脚本

    这个脚本存在的唯一理由：引擎的作者在 macOS 上写完它，没法在 Windows 上跑。
    所以把「能不能用」压缩成一条命令，让在这台 Windows 上的人替它回答。

    用法（在 surehand 的 engine\windows 目录里）：
        powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1

    它会：
      1. 检查 PowerShell 版本与 UIAutomation 程序集
      2. 起一个记事本窗口当靶子（不动你正在编辑的东西）
      3. 启动引擎、握手、ping
      4. apps / windows / snapshot / act / state / attrs 各打一遍
      5. 把结果写成 verify-report.json，并打印人读版本

    全程只对记事本动手，结束时关掉那个记事本。
#>
param(
    [switch]$KeepOpen,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wccd = Join-Path $here 'wccd.ps1'
$report = [ordered]@{}
$fails = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

function Step([string]$name, [scriptblock]$body) {
    $t0 = Get-Date
    try {
        $r = & $body
        $ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 1)
        Write-Host ('  ok   {0,-34} {1,7} ms' -f $name, $ms) -ForegroundColor Green
        $report[$name] = @{ ok = $true; ms = $ms; detail = $r }
        return $r
    }
    catch {
        $ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 1)
        Write-Host ('  FAIL {0,-34} {1,7} ms' -f $name, $ms) -ForegroundColor Red
        Write-Host ('       {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
        [void]$fails.Add("$name : $($_.Exception.Message)")
        $report[$name] = @{ ok = $false; ms = $ms; error = $_.Exception.Message }
        throw
    }
}

Write-Host ''
Write-Host 'Surehand / Windows 引擎验收' -ForegroundColor Cyan
Write-Host ('=' * 58)

$psv = $PSVersionTable.PSVersion
Write-Host ('PowerShell {0}  ({1})' -f $psv, $PSVersionTable.PSEdition)
if ($psv.Major -lt 5) { throw "需要 PowerShell 5.1 或更高，当前 $psv" }
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    [void]$notes.Add('当前不是 Windows PowerShell（Desktop 版）。UIAutomation 只在 5.1 上可用，请改用 powershell.exe。')
}

# ---- 1. 程序集
Step 'UIAutomation 程序集' {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Web.Extensions
    return 'ok'
}

# ---- 2. DPI 感知（点错的头号原因）
Step 'DPI 环境' {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DpiProbe {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@ -Language CSharp
    [void][DpiProbe]::SetProcessDPIAware()
    return @{ screen = @([DpiProbe]::GetSystemMetrics(0), [DpiProbe]::GetSystemMetrics(1)) }
}

# ---- 3. 靶子：记事本
$np = $null
Step '起记事本当靶子' {
    $np = Start-Process notepad.exe -PassThru
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $np.Refresh()
        if ($np.MainWindowHandle -ne 0) { break }
    }
    if ($np.MainWindowHandle -eq 0) { throw '记事本起来了但拿不到主窗口句柄' }
    return @{ pid = $np.Id; hwnd = $np.MainWindowHandle }
}

# ---- 4. 引擎
$engineProc = $null
$client = $null
$reader = $null
$writer = $null

function Connect-Engine {
    $script:endpointFile = Join-Path $env:LOCALAPPDATA 'surehand\wccd.json'
    if (Test-Path $script:endpointFile) {
        try {
            $ep = Get-Content $script:endpointFile -Raw | ConvertFrom-Json
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', [int]$ep.port)
            $script:reader = New-Object System.IO.StreamReader($c.GetStream(), [System.Text.Encoding]::UTF8)
            $script:writer = New-Object System.IO.StreamWriter($c.GetStream(), (New-Object System.Text.UTF8Encoding($false)))
            $script:writer.AutoFlush = $true
            $script:writer.WriteLine((@{ token = $ep.token } | ConvertTo-Json -Compress))
            $ack = $script:reader.ReadLine() | ConvertFrom-Json
            if ($ack.ok) { $script:client = $c; return 'reused' }
            $c.Close()
        } catch { }
    }
    $script:engineProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $wccd
    )
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path $script:endpointFile)) { continue }
        try {
            $ep = Get-Content $script:endpointFile -Raw | ConvertFrom-Json
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', [int]$ep.port)
            $script:reader = New-Object System.IO.StreamReader($c.GetStream(), [System.Text.Encoding]::UTF8)
            $script:writer = New-Object System.IO.StreamWriter($c.GetStream(), (New-Object System.Text.UTF8Encoding($false)))
            $script:writer.AutoFlush = $true
            $script:writer.WriteLine((@{ token = $ep.token } | ConvertTo-Json -Compress))
            $ack = $script:reader.ReadLine() | ConvertFrom-Json
            if ($ack.ok) { $script:client = $c; return 'started' }
            $c.Close()
        } catch { }
    }
    throw "引擎 40 秒内没就绪，看 $env:TEMP\surehand-engine.log"
}

Step '引擎启动与握手' { Connect-Engine }

function Rpc($obj) {
    $script:writer.WriteLine(($obj | ConvertTo-Json -Compress -Depth 12))
    $line = $script:reader.ReadLine()
    if (-not $line) { throw '引擎断开连接' }
    return ($line | ConvertFrom-Json)
}

Step 'ping' {
    $r = Rpc @{ cmd = 'ping' }
    if (-not $r.ok) { throw "ping 失败：$($r.error)" }
    return @{ version = $r.version; pid = $r.pid; platform = $r.platform }
}

Step 'apps 列表' {
    $r = Rpc @{ cmd = 'apps' }
    if (-not $r.ok) { throw "apps 失败：$($r.error)" }
    $n = @($r.apps).Count
    if ($n -lt 1) { throw '一个带窗口的应用都没列出来，UIA 或进程枚举有问题' }
    return @{ count = $n; sample = (@($r.apps) | Select-Object -First 3 | ForEach-Object { $_.name }) }
}

Step 'windows 列表' {
    $r = Rpc @{ cmd = 'windows'; app = 'notepad' }
    if (-not $r.ok) { throw "windows 失败：$($r.error)" }
    return @{ count = @($r.windows).Count }
}

Step 'snapshot 记事本' {
    $r = Rpc @{ cmd = 'snapshot'; app = 'notepad'; max_nodes = 800 }
    if (-not $r.ok) { throw "snapshot 失败：$($r.error)" }
    $script:snap = $r
    if ($r.visited -lt 2) { throw "只遍历到 $($r.visited) 个节点，UIA 树没读出来" }
    return @{
        visited = $r.visited; complete = $r.complete
        issued = $r.refs_issued; restricted = $r.refs_restricted
        withheld = $r.refs_withheld; ms = $r.elapsed_ms
        incomplete_because = $r.incomplete_because
    }
}

Step '发证口径自洽' {
    $r = $script:snap
    if ($r.complete) {
        $withRef = @($r.nodes | Where-Object { $_.ref }).Count
        if ($withRef -ne $r.refs_issued) {
            throw "refs_issued=$($r.refs_issued) 与实际带 ref 的节点数 $withRef 不一致"
        }
        foreach ($n in $r.nodes) {
            if ($n.ref -and $n.witness -ne 1) { throw "发了证但 witness=$($n.witness)，唯一性没满足" }
            if (-not $n.ref -and -not $n.handle) { throw '既没 ref 也没 handle，节点失去了可寻址性' }
        }
    }
    return @{ complete = $r.complete; checked = @($r.nodes).Count }
}

Step 'act fill 写文字' {
    $edit = @($script:snap.nodes | Where-Object { $_.ref -and ($_.actions -contains 'setvalue') }) | Select-Object -First 1
    if (-not $edit) { throw '记事本里找不到可填的编辑区（应先有 ValuePattern）' }
    $r = Rpc @{ cmd = 'act'; action = 'fill'; ref = $edit.ref; text = 'surehand-verify' }
    if (-not $r.ok) { throw "fill 失败：$($r.error)" }
    if ($r.delivery.state -ne 'delivered') { throw "fill 未送达：$($r.delivery.state)" }
    return @{ ref = $edit.ref; method = $r.method; after = $r.after }
}

Step 'read 回读' {
    $r = Rpc @{ cmd = 'snapshot'; app = 'notepad'; max_nodes = 800 }
    $v = @($r.nodes | Where-Object { $_.value -like '*surehand-verify*' })
    if ($v.Count -eq 0) { throw '写进去的文字在重新快照里读不回来' }
    return @{ matched = $v.Count }
}

Step 'state 复核' {
    $edit = @($script:snap.nodes | Where-Object { $_.ref -and ($_.actions -contains 'setvalue') }) | Select-Object -First 1
    $r = Rpc @{ cmd = 'state'; ref = $edit.ref; verify = 'strict' }
    if (-not $r.ok) { throw "state 失败：$($r.error)" }
    return @{ role = $r.role; value = $r.value }
}

Step '句柄不能动手' {
    $h = @($script:snap.nodes | Where-Object { $_.handle }) | Select-Object -First 1
    if (-not $h) { return @{ skipped = '这份快照没有句柄' } }
    $r = Rpc @{ cmd = 'act'; action = 'click'; ref = $h.handle }
    if ($r.ok) { throw '句柄被允许点击，令牌与句柄没有分开' }
    if ($r.error -ne 'HANDLE_NOT_TOKEN') { throw "拒绝理由是 $($r.error)，应为 HANDLE_NOT_TOKEN" }
    return @{ error = $r.error }
}

Step 'shot 截图' {
    $r = Rpc @{ cmd = 'shot'; app = 'notepad' }
    if (-not $r.ok) { throw "shot 失败：$($r.error)" }
    if (-not (Test-Path $r.out)) { throw "截图文件不存在：$($r.out)" }
    return @{ out = $r.out; bbox = $r.bbox }
}

Step '错误契约' {
    $r = Rpc @{ cmd = 'snapshot'; app = 'no-such-app-xyz' }
    if ($r.ok) { throw '对不存在的应用竟然返回成功' }
    if ($r.error -ne 'APP_NOT_FOUND') { throw "错误码是 $($r.error)，应为 APP_NOT_FOUND" }
    $r2 = Rpc @{ cmd = 'act'; action = 'click'; ref = 'e99999' }
    if ($r2.error -ne 'REF_STALE') { throw "过期 ref 的错误码是 $($r2.error)，应为 REF_STALE" }
    return @{ app = $r.error; stale = $r2.error }
}

# ---- 收尾
if ($client) { try { [void](Rpc @{ cmd = 'shutdown' }); $client.Close() } catch { } }
if (-not $KeepOpen) {
    try { if ($np -and -not $np.HasExited) { $np.Kill() } } catch { }
}

$report['summary'] = @{
    failed = $fails.Count
    notes = @($notes)
    when = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ps = "$psv"
}
$outFile = Join-Path $here 'verify-report.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $outFile -Encoding UTF8

Write-Host ('=' * 58)
if ($fails.Count -eq 0) {
    Write-Host "全部通过。报告：$outFile" -ForegroundColor Green
} else {
    Write-Host "$($fails.Count) 项失败：" -ForegroundColor Red
    foreach ($f in $fails) { Write-Host "  - $f" -ForegroundColor Red }
    Write-Host "报告：$outFile"
}
foreach ($n in $notes) { Write-Host "注意：$n" -ForegroundColor Yellow }
exit $fails.Count
