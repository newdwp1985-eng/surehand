#requires -Version 5.1
<#
    wccd.ps1 —— Surehand 的 Windows 桌面引擎（常驻 + 回环 TCP + JSON-lines）

    它和 macOS 的 mccd 是同一个协议的两种实现，上面那层 cli 分不出来：
    一行一个 JSON 请求，一行一个 JSON 响应；命令名、字段名、错误码、投递语义全部一致。

    为什么是 PowerShell 而不是编译一个 exe：
      Windows 10/11 自带 Windows PowerShell 5.1 与 .NET Framework 的 UIAutomation，
      零安装、零构建，clone 下来就能跑。代价是首启动要 Add-Type 现场编译约 1~2 秒，
      这由常驻进程摊掉。**只支持 Windows PowerShell 5.1，不支持 PowerShell 7**——
      pwsh 上没有 UIAutomationClient 程序集。

    三个平台差异，写在代码里而不是藏起来：
      1. UIA 的三态精度低于 macOS AX。AX 会用 attributeUnsupported 明确回答「没这个属性」，
         UIA 只是抛 COM 异常，所以这里的 unknown 基本只代表「元素读不到了」。
      2. 角色名用 UIA 官方小写名（button / edit / text），不是 AXButton 那套。
         上层 Python 做归一化，两边写 --role button 都能用。
      3. 单线程串行处理。UIA 客户端本来就要求串行调用；不同连接用非阻塞轮询轮转，
         一条空闲连接不会堵死别人。

    只服务本机回环，因此必须验令牌；端点文件只对当前用户可读。
#>
param(
    [switch]$Version,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$script:VERSION = '1.1.2'
$script:MUTEX_NAME = 'Local\SurehandEngine'
$script:ENDPOINT_DIR = Join-Path $env:LOCALAPPDATA 'surehand'
$script:ENDPOINT_FILE = Join-Path $script:ENDPOINT_DIR 'wccd.json'
$script:LOG_FILE = Join-Path $env:TEMP 'surehand-engine.log'

if ($Version) { Write-Output "wccd $($script:VERSION)"; exit 0 }

function Write-Log([string]$msg) {
    try {
        Add-Content -Path $script:LOG_FILE -Encoding UTF8 `
            -Value ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg)
    } catch { }
}

# ---------------------------------------------------------------- 原生层

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

namespace Surehand
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public int type; public INPUTUNION u; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static class N
    {
        public const int INPUT_MOUSE = 0;
        public const int INPUT_KEYBOARD = 1;
        public const uint KEYEVENTF_KEYUP = 0x0002;
        public const uint KEYEVENTF_UNICODE = 0x0004;
        public const uint MOUSEEVENTF_MOVE = 0x0001;
        public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const uint MOUSEEVENTF_LEFTUP = 0x0004;
        public const uint MOUSEEVENTF_WHEEL = 0x0800;
        public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

        public const int SM_XVIRTUALSCREEN = 76;
        public const int SM_YVIRTUALSCREEN = 77;
        public const int SM_CXVIRTUALSCREEN = 78;
        public const int SM_CYVIRTUALSCREEN = 79;
        public const int SM_CXSCREEN = 0;
        public const int SM_CYSCREEN = 1;

        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
        [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

        public static void MakeDpiAware()
        {
            // 不设这一步，125%/150% 缩放的机器上 UIA 报逻辑坐标、SendInput 吃物理坐标，
            // 两者差一个缩放因子——所有点击都会系统性偏移。这是 Windows 自动化最常踩的坑，
            // 必须在任何 UIA 调用之前执行。
            try { SetProcessDpiAwareness(2); return; } catch { }
            try { SetProcessDPIAware(); } catch { }
        }

        public static string Title(IntPtr h)
        {
            var sb = new StringBuilder(1024);
            GetWindowTextW(h, sb, 1024);
            return sb.ToString();
        }

        public static uint PidOf(IntPtr h)
        {
            uint pid; GetWindowThreadProcessId(h, out pid); return pid;
        }

        public static RECT Rect(IntPtr h)
        {
            RECT r; GetWindowRect(h, out r); return r;
        }

        public static List<IntPtr> TopWindows()
        {
            var list = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                // 只要可见的顶层窗口且必须有标题：无标题的多是输入法候选、隐藏消息窗、
                // 工具提示，混进来只会让 apps 列表失真。
                if (IsWindowVisible(h) && Title(h).Length > 0) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public static bool ForceForeground(IntPtr h)
        {
            if (h == IntPtr.Zero) return false;
            if (IsIconic(h)) ShowWindow(h, 9); else ShowWindow(h, 5);
            if (GetForegroundWindow() == h) return true;
            // 前台锁：系统只允许「正在接收输入」的进程抢前台，借前台线程的输入队列绕过。
            uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out uint _unused);
            uint myTid = GetCurrentThreadId();
            bool attached = false;
            if (fgTid != 0 && fgTid != myTid) attached = AttachThreadInput(myTid, fgTid, true);
            bool ok;
            try { ok = SetForegroundWindow(h); }
            finally { if (attached) AttachThreadInput(myTid, fgTid, false); }
            return ok || GetForegroundWindow() == h;
        }

        static void Norm(int x, int y, out int nx, out int ny)
        {
            int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
            int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (vw <= 1) vw = GetSystemMetrics(SM_CXSCREEN);
            if (vh <= 1) vh = GetSystemMetrics(SM_CYSCREEN);
            // 绝对坐标是 0..65535 的归一化值域，按虚拟桌面（多显示器合并后的整块）算，
            // 副屏上的元素也能一次点准。
            nx = (int)Math.Round((x - vx) * 65535.0 / Math.Max(1, vw - 1));
            ny = (int)Math.Round((y - vy) * 65535.0 / Math.Max(1, vh - 1));
        }

        public static void Move(int x, int y)
        {
            int nx, ny; Norm(x, y, out nx, out ny);
            var a = new INPUT[1];
            a[0].type = INPUT_MOUSE;
            a[0].u.mi.dx = nx; a[0].u.mi.dy = ny;
            a[0].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
            SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
        }

        public static uint Click(int x, int y, int count, bool right)
        {
            int nx, ny; Norm(x, y, out nx, out ny);
            uint down = right ? 0x0008u : MOUSEEVENTF_LEFTDOWN;
            uint up = right ? 0x0010u : MOUSEEVENTF_LEFTUP;
            if (count < 1) count = 1;
            var a = new INPUT[2 * count];
            for (int i = 0; i < count; i++)
            {
                a[i * 2].type = INPUT_MOUSE;
                a[i * 2].u.mi.dx = nx; a[i * 2].u.mi.dy = ny;
                a[i * 2].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | down;
                a[i * 2 + 1].type = INPUT_MOUSE;
                a[i * 2 + 1].u.mi.dx = nx; a[i * 2 + 1].u.mi.dy = ny;
                a[i * 2 + 1].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | up;
            }
            return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
        }

        public static uint Wheel(int x, int y, int delta, int times)
        {
            int nx, ny; Norm(x, y, out nx, out ny);
            if (times < 1) times = 1;
            var a = new INPUT[times];
            for (int i = 0; i < times; i++)
            {
                a[i].type = INPUT_MOUSE;
                a[i].u.mi.dx = nx; a[i].u.mi.dy = ny;
                a[i].u.mi.mouseData = unchecked((uint)(delta * 120));
                a[i].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_WHEEL;
            }
            return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
        }

        public static uint Key(ushort vk, bool up)
        {
            var a = new INPUT[1];
            a[0].type = INPUT_KEYBOARD;
            a[0].u.ki.wVk = vk;
            a[0].u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
            return SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
        }

        public static uint Text(string s)
        {
            if (s == null || s.Length == 0) return 0;
            var list = new List<INPUT>(s.Length * 2);
            foreach (char ch in s)
            {
                var down = new INPUT(); down.type = INPUT_KEYBOARD;
                down.u.ki.wScan = ch; down.u.ki.dwFlags = KEYEVENTF_UNICODE;
                var up = new INPUT(); up.type = INPUT_KEYBOARD;
                up.u.ki.wScan = ch; up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
                list.Add(down); list.Add(up);
            }
            return SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT)));
        }

        public static string Capture(int x, int y, int w, int h, string outPath, int gridStep)
        {
            if (w <= 0 || h <= 0) throw new ArgumentException("capture area is empty");
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
                    if (gridStep > 0)
                    {
                        using (var pen = new Pen(Color.FromArgb(90, 255, 0, 0), 1))
                        {
                            for (int gx = gridStep; gx < w; gx += gridStep) g.DrawLine(pen, gx, 0, gx, h);
                            for (int gy = gridStep; gy < h; gy += gridStep) g.DrawLine(pen, 0, gy, w, gy);
                        }
                    }
                }
                bmp.Save(outPath, ImageFormat.Png);
            }
            return outPath;
        }
    }
}
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies 'System.Drawing' | Out-Null

[void][Surehand.N]::MakeDpiAware()

$AE     = [System.Windows.Automation.AutomationElement]
$TS     = [System.Windows.Automation.TreeScope]
$COND   = [System.Windows.Automation.Condition]::TrueCondition
$INVOKE = [System.Windows.Automation.InvokePattern]::Pattern
$VALUE  = [System.Windows.Automation.ValuePattern]::Pattern
$TOGGLE = [System.Windows.Automation.TogglePattern]::Pattern
$SELITEM= [System.Windows.Automation.SelectionItemPattern]::Pattern
$EXPAND = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
$SCROLL = [System.Windows.Automation.ScrollPattern]::Pattern

# ---------------------------------------------------------------- UIA 读数

function Get-Role($el) {
    try {
        $p = $el.Current.ControlType.ProgrammaticName
        return ($p -replace '^ControlType\.', '').ToLowerInvariant()
    } catch { return 'unknown' }
}

function Try-Read($el, [string]$prop) {
    try { return @{ ev = 'known'; v = $el.Current.$prop } }
    catch { return @{ ev = 'unknown'; v = $null } }
}

function Get-Str($el, [string]$prop) {
    $r = Try-Read $el $prop
    if ($r.ev -eq 'unknown') { return @{ ev = 'unknown'; v = '' } }
    if ($null -eq $r.v) { return @{ ev = 'absent'; v = '' } }
    $s = [string]$r.v
    if ($s.Length -eq 0) { return @{ ev = 'absent'; v = '' } }
    return @{ ev = 'known'; v = $s }
}

function Get-Bbox($el) {
    try {
        $r = $el.Current.BoundingRectangle
        if ($r.IsEmpty) { return $null }
        if ($r.Width -le 0 -or $r.Height -le 0) { return $null }
        return @([int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
    } catch { return $null }
}

function Has-Pattern($el, $pattern) {
    try {
        $p = $null
        return $el.TryGetCurrentPattern($pattern, [ref]$p)
    } catch { return $false }
}

function Get-Patterns($el) {
    # 动作能力清单。名字对齐 macOS 的 AXPress/setvalue 那套，让上层不用分平台。
    $acts = @()
    if (Has-Pattern $el $INVOKE) { $acts += 'press' }
    if (Has-Pattern $el $VALUE) {
        try {
            $p = $null
            [void]$el.TryGetCurrentPattern($VALUE, [ref]$p)
            if ($p.Current.IsReadOnly) { $acts += 'readvalue' } else { $acts += 'setvalue' }
        } catch { }
    }
    if (Has-Pattern $el $TOGGLE) { $acts += 'toggle' }
    if (Has-Pattern $el $SELITEM) { $acts += 'select' }
    if (Has-Pattern $el $EXPAND) { $acts += 'expand'; $acts += 'collapse' }
    if (Has-Pattern $el $SCROLL) { $acts += 'scroll' }
    return $acts
}

function Get-Value($el) {
    # 值不是 UIA 通用属性，只能走 ValuePattern；没有这个 pattern 就是 absent。
    try {
        $p = $null
        if ($el.TryGetCurrentPattern($VALUE, [ref]$p)) {
            $v = [string]$p.Current.Value
            if ($v.Length -eq 0) { return @{ ev = 'absent'; v = '' } }
            return @{ ev = 'known'; v = $v }
        }
        return @{ ev = 'absent'; v = '' }
    } catch { return @{ ev = 'unknown'; v = '' } }
}

function Get-Children($el) {
    try {
        $c = $el.FindAll($TS::Children, $COND)
        return @{ ev = 'known'; v = @($c) }
    } catch { return @{ ev = 'unknown'; v = @() } }
}

# ---------------------------------------------------------------- 应用与窗口

function Get-WindowIndex {
    $map = @{}
    foreach ($h in [Surehand.N]::TopWindows()) {
        $id = [int][Surehand.N]::PidOf($h)
        if (-not $map.ContainsKey($id)) { $map[$id] = @() }
        $map[$id] = @($map[$id]) + @($h)
    }
    return $map
}

function Resolve-App([string]$name) {
    # 三种写法都认：进程名（notepad）、显示名（记事本）、窗口标题片段。
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $needle = $name.Trim().ToLowerInvariant()
    $wins = Get-WindowIndex
    $procs = @(Get-Process | Where-Object { $wins.ContainsKey($_.Id) })

    $exact = @($procs | Where-Object { $_.ProcessName.ToLowerInvariant() -eq $needle })
    if ($exact.Count -eq 0) {
        $exact = @($procs | Where-Object { $_.ProcessName.ToLowerInvariant().Contains($needle) })
    }
    if ($exact.Count -eq 0) {
        $exact = @($procs | Where-Object {
            $_.MainWindowTitle -and $_.MainWindowTitle.ToLowerInvariant().Contains($needle)
        })
    }
    if ($exact.Count -eq 0) { return $null }
    return ($exact | Sort-Object -Property @{ Expression = { if ($_.MainWindowHandle -ne 0) { 0 } else { 1 } } } |
            Select-Object -First 1)
}

function Pick-Window($proc, [string]$titleHint) {
    $wins = @((Get-WindowIndex)[$proc.Id])
    if ($wins.Count -eq 0) { return [IntPtr]::Zero }
    if (-not [string]::IsNullOrWhiteSpace($titleHint)) {
        foreach ($h in $wins) {
            if ([Surehand.N]::Title($h).Contains($titleHint)) { return $h }
        }
    }
    if ($proc.MainWindowHandle -ne 0 -and ($wins -contains $proc.MainWindowHandle)) {
        return $proc.MainWindowHandle
    }
    return $wins[0]
}

function Get-RootEl([string]$app, [string]$windowTitle) {
    $proc = Resolve-App $app
    if (-not $proc) { return @{ err = 'APP_NOT_FOUND' } }
    $h = Pick-Window $proc $windowTitle
    if ($h -eq [IntPtr]::Zero) { return @{ err = 'NO_WINDOW' } }
    try {
        $el = $AE::FromHandle($h)
        if ($null -eq $el) { return @{ err = 'NO_WINDOW' } }
        return @{ el = $el; hwnd = $h; proc = $proc }
    } catch { return @{ err = 'NO_WINDOW' } }
}

# ---------------------------------------------------------------- 注册表

$script:Registry = @{}
$script:RefCounter = 0
$script:SnapshotId = ''
$script:RegistryRoot = $null
$script:RegistryPid = 0

function Reset-Registry($rootEl, [int]$procId) {
    # 不清空 $script:Registry，也不清零 $script:RefCounter。
    # 清空会让「刚 find 到的令牌」在另一次观察后立刻失效；清零会让编号被复用，
    # 旧 ref 静默指向另一个元素。两者都让调用方承担不该承担的后果。
    # 编号单调递增 + 容量回收，是这个组合里唯一自洽的做法。
    if ($script:Registry.Count -gt 5000) {
        $keys = $script:Registry.Keys | Sort-Object { [int]($_ -replace '^e', '') }
        $drop = [int]($keys.Count / 2)
        for ($i = 0; $i -lt $drop; $i++) { $script:Registry.Remove($keys[$i]) }
    }
    $script:RegistryRoot = $rootEl
    $script:RegistryPid = $procId
    $epoch = [int64](([DateTime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    $script:SnapshotId = 's' + $epoch
}

function Put-Ref($el, [string]$role, [string]$name, [string]$desc, [string]$ident,
                  [int]$witness, [string]$addressedBy, [bool]$proven,
                  [bool]$restricted, [string]$scope) {
    $script:RefCounter += 1
    $r = 'e' + $script:RefCounter
    $script:Registry[$r] = @{
        el = $el; role = $role; name = $name; desc = $desc; id = $ident
        witness = $witness; addressed_by = $addressedBy; proven = $proven
        restricted = $restricted; scope = $scope; pid = $script:RegistryPid
    }
    return $r
}

function Get-IdentityKey([string]$role, [string]$name, [string]$desc, [string]$ident,
                         $bbox, [string]$value) {
    # 有机器标识就用它：比显示名稳定，也不受系统语言影响（计算器按钮就是典型）。
    if ($ident) { return "id|$ident" }
    if ($name -or $desc) { return "role|$role|$name|$desc" }
    # 没名字没标识只能按位置认。这种 ref 一滚动就作废，标 addressed_by=geometry 让人掂量。
    if ($null -ne $bbox) { return "geo|$role|$value|$($bbox[0]),$($bbox[1]),$($bbox[2]),$($bbox[3])" }
    return "anon|$role|$value"
}

# ---------------------------------------------------------------- 快照

function Get-Snapshot($req) {
    $t0 = Get-Date
    $root = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($root.err) { return @{ ok = $false; error = $root.err } }

    $rootEl = $root.el
    $proc = $root.proc
    $hwnd = $root.hwnd
    $maxNodes = 1500
    if ($req.max_nodes) { $maxNodes = [int]$req.max_nodes }
    $maxDepth = 40
    if ($req.max_depth) { $maxDepth = [int]$req.max_depth }
    $scope = 'window'

    # --from：从上次快照的某个节点往下钻。唯一性随之只在该子树里成立，不假装证明了整窗。
    $fromRef = ''
    if ($req.from) { $fromRef = [string]$req.from }
    if ($req.from_ref) { $fromRef = [string]$req.from_ref }
    if ($fromRef) {
        $entry = $script:Registry[$fromRef]
        if (-not $entry) { return @{ ok = $false; error = 'REF_STALE' } }
        $rootEl = $entry.el
        $scope = 'subtree:' + $fromRef
    }

    Reset-Registry $rootEl ([int]$proc.Id)

    $recs = New-Object System.Collections.ArrayList
    $visited = 0
    $overflow = $false
    $depthCapped = $false
    $unknownSubtrees = 0

    # 逐层 FindAll 而不是逐节点取 FirstChild：一次跨进程调用拿回一层，
    # 层数通常不到 10，比每个节点各来一次 IPC 快一个量级。
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($rootEl, 0))
    while ($queue.Count -gt 0) {
        $pair = $queue.Dequeue()
        $el = $pair[0]
        $depth = [int]$pair[1]

        $role = Get-Role $el
        if ($role -eq 'unknown') { $unknownSubtrees += 1; continue }

        $nR = Get-Str $el 'Name'
        $iR = Get-Str $el 'AutomationId'
        $hR = Get-Str $el 'HelpText'
        $cR = Get-Str $el 'ClassName'
        $vR = Get-Value $el
        $bbox = Get-Bbox $el
        $acts = Get-Patterns $el
        $enR = Try-Read $el 'IsEnabled'
        $offR = Try-Read $el 'IsOffscreen'
        $foR = Try-Read $el 'HasKeyboardFocus'

        # 名字：UIA 的 Name 经常是空的，ClassName 和 HelpText 里才有可辨识的东西。
        $name = $nR.v
        $nameFrom = ''
        if (-not $name -and $hR.v) { $name = $hR.v; $nameFrom = 'helptext' }
        if (-not $name -and $cR.v -and $role -eq 'pane') { $name = $cR.v; $nameFrom = 'classname' }

        $attested = (($nR.ev -ne 'unknown') -and ($iR.ev -ne 'unknown') -and
                     ($hR.ev -ne 'unknown') -and ($vR.ev -ne 'unknown') -and
                     ($enR.ev -ne 'unknown'))
        $by = 'name'
        if ($iR.v) { $by = 'id' }
        elseif ((-not $name) -and ($null -ne $bbox)) { $by = 'geometry' }

        [void]$recs.Add(@{
            el = $el; depth = $depth; role = $role
            name = $name; name_from = $nameFrom; desc = $hR.v; id = $iR.v
            value = $vR.v; bbox = $bbox; acts = $acts
            enabled_ev = $enR.ev; enabled = [bool]$enR.v
            focused = (($foR.ev -eq 'known') -and [bool]$foR.v)
            offscreen = (($offR.ev -eq 'known') -and [bool]$offR.v)
            attested = $attested; addressed_by = $by
        })
        $visited += 1
        if ($visited -ge $maxNodes) { $overflow = $true; break }

        if ($depth -ge $maxDepth) { $depthCapped = $true; continue }
        $kids = Get-Children $el
        if ($kids.ev -eq 'unknown') { $unknownSubtrees += 1; continue }
        foreach ($k in $kids.v) { $queue.Enqueue(@($k, $depth + 1)) }
    }

    $complete = ((-not $depthCapped) -and (-not $overflow) -and ($unknownSubtrees -eq 0))

    # 身份频次：整窗重名的一律不发证。歧义必须由调用方消解，不能由我们猜。
    $freq = @{}
    foreach ($rec in $recs) {
        $key = Get-IdentityKey $rec.role $rec.name $rec.desc $rec.id $rec.bbox $rec.value
        if ($freq.ContainsKey($key)) { $freq[$key] = $freq[$key] + 1 } else { $freq[$key] = 1 }
    }

    $nodes = New-Object System.Collections.ArrayList
    $issued = 0; $withheld = 0; $restrictedCount = 0
    foreach ($rec in $recs) {
        $key = Get-IdentityKey $rec.role $rec.name $rec.desc $rec.id $rec.bbox $rec.value
        $witness = $freq[$key]
        $d = @{ role = $rec.role; depth = $rec.depth; witness = $witness }
        if ($rec.name) { $d.name = $rec.name }
        if ($rec.name_from) { $d.name_from = $rec.name_from }
        if ($rec.desc) { $d.desc = $rec.desc }
        if ($rec.id) { $d.id = $rec.id }
        if ($rec.value) {
            if ($rec.value.Length -gt 300) { $d.value = $rec.value.Substring(0, 300) }
            else { $d.value = $rec.value }
        }
        if ($null -ne $rec.bbox) { $d.bbox = $rec.bbox }
        if ($rec.acts.Count -gt 0) { $d.actions = $rec.acts }
        if ($rec.focused) { $d.focused = $true }
        if ($rec.offscreen) { $d.offscreen = $true }

        $ev = @{}
        if ($rec.enabled_ev -eq 'known') { $d.enabled = $rec.enabled } else { $ev.enabled = $rec.enabled_ev }
        if ((-not $rec.attested) -and $complete) { $ev.identity = 'unknown' }
        if ($ev.Count -gt 0) { $d.evidence = $ev }

        # 发证三档，判据是「能对它做什么」而不是「读得全不全」，与 macOS 侧一字不差。
        if ($complete -and ($witness -eq 1) -and $rec.attested) {
            $d.ref = Put-Ref $rec.el $rec.role $rec.name $rec.desc $rec.id $witness $rec.addressed_by $true $false $scope
            if ($rec.addressed_by -eq 'geometry') { $d.addressed_by = 'geometry' }
            if ($scope -ne 'window') { $d.proven_in = $scope }
            $issued += 1
        }
        elseif ($complete -and ($witness -eq 1) -and $rec.id) {
            $d.ref = Put-Ref $rec.el $rec.role $rec.name $rec.desc $rec.id $witness $rec.addressed_by $true $true $scope
            $d.restricted = $true
            $d.allowed = @('fill', 'read')
            if ($scope -ne 'window') { $d.proven_in = $scope }
            $restrictedCount += 1
            $issued += 1
        }
        else {
            # 没证明的元素仍留一个导航句柄：能拿去 --from 继续钻，不能动手。
            $d.handle = Put-Ref $rec.el $rec.role $rec.name $rec.desc $rec.id $witness $rec.addressed_by $false $false $scope
            if ($witness -gt 1) { $d.ambiguous = $witness }
            if (-not $rec.attested) { $d.unattested = $true }
            $withheld += 1
        }
        [void]$nodes.Add($d)
    }

    $wr = [Surehand.N]::Rect($hwnd)
    $out = @{
        ok = $true
        snapshot_id = $script:SnapshotId
        app = $proc.ProcessName
        pid = [int]$proc.Id
        window = [Surehand.N]::Title($hwnd)
        window_bbox = @($wr.Left, $wr.Top, ($wr.Right - $wr.Left), ($wr.Bottom - $wr.Top))
        scope = $scope
        complete = $complete
        visited = $visited
        count = $nodes.Count
        refs_issued = $issued
        refs_restricted = $restrictedCount
        refs_withheld = $withheld
        truncated = $overflow
        elapsed_ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 3)
        platform = 'windows'
        nodes = $nodes.ToArray()
    }
    if (-not $complete) {
        $why = @()
        if ($depthCapped) { $why += "depth_cap:$maxDepth" }
        if ($overflow) { $why += "node_cap:$maxNodes" }
        if ($unknownSubtrees -gt 0) { $why += "unknown_subtree:$unknownSubtrees" }
        $out.incomplete_because = $why
        $out.refs_usable = $false
    }
    else { $out.refs_usable = ($issued -gt 0) }
    return $out
}

# ---------------------------------------------------------------- 目标解析

function Resolve-Target($req) {
    if ($req.ref) {
        $entry = $script:Registry[[string]$req.ref]
        if (-not $entry) { return @{ err = 'REF_STALE' } }
        if (-not $entry.proven) { return @{ err = 'HANDLE_NOT_TOKEN' } }
        $mode = 'attach'
        if ($req.verify) { $mode = [string]$req.verify }
        if ($mode -ne 'none') {
            try {
                if ($script:RegistryPid -ne 0) {
                    $curPid = [int][Surehand.N]::PidOf($script:RegistryRoot)
                    if ($curPid -ne $script:RegistryPid) { return @{ err = 'REF_REBOUND:pid_changed' } }
                }
                $role = Get-Role $entry.el
                if ($role -eq 'unknown') { return @{ err = 'REF_DETACHED' } }
                if ($role -ne $entry.role) { return @{ err = 'REF_REBOUND:role_changed' } }
                if ($entry.name) {
                    $now = (Get-Str $entry.el 'Name').v
                    if ($now -ne $entry.name) { return @{ err = 'REF_REBOUND:name_changed' } }
                }
            } catch { return @{ err = 'REF_DETACHED' } }
        }
        if ($mode -eq 'strict') {
            $n = 0
            foreach ($x in $script:Registry.Values) {
                if (($x.role -eq $entry.role) -and ($x.name -eq $entry.name) -and ($x.id -eq $entry.id)) { $n += 1 }
            }
            if ($n -eq 0) { return @{ err = 'REF_STALE' } }
        }
        return @{ target = @{ el = $entry.el; role = $entry.role; name = $entry.name;
                              desc = $entry.desc; witness = $entry.witness; via = 'ref';
                              restricted = $entry.restricted; scope = $entry.scope } }
    }

    $root = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($root.err) { return @{ err = $root.err } }
    $role = [string]$req.role
    $name = [string]$req.name
    $ident = [string]$req.id
    $contains = [bool]$req.contains
    if ((-not $role) -and (-not $name) -and (-not $ident)) { return @{ err = 'NO_TARGET' } }

    $hits = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($root.el, 0))
    while (($queue.Count -gt 0) -and ($hits.Count -le 40)) {
        $pair = $queue.Dequeue()
        $el = $pair[0]
        $depth = [int]$pair[1]
        if ($depth -gt 40) { continue }
        $r = Get-Role $el
        if ($r -eq 'unknown') { continue }
        $nVal = (Get-Str $el 'Name').v
        $hVal = (Get-Str $el 'HelpText').v
        $iVal = (Get-Str $el 'AutomationId').v
        $vVal = (Get-Value $el).v
        $roleOK = $true
        if ($role) { $roleOK = ($r -eq $role.ToLowerInvariant()) }
        $nameOK = $true
        if ($ident) { $nameOK = ($iVal -eq $ident) }
        elseif ($name) {
            $hay = @($nVal, $hVal, $vVal)
            if ($contains) {
                $nameOK = $false
                foreach ($h in $hay) { if ($h -and $h.Contains($name)) { $nameOK = $true; break } }
            }
            else { $nameOK = ($hay -contains $name) }
        }
        if ($roleOK -and $nameOK) { $hits += $el }
        $kids = Get-Children $el
        if ($kids.ev -eq 'known') { foreach ($k in $kids.v) { $queue.Enqueue(@($k, $depth + 1)) } }
    }
    if ($hits.Count -eq 0) { return @{ err = 'NOT_FOUND' } }
    if (($hits.Count -gt 1) -and (-not $contains)) { return @{ err = "AMBIGUOUS:$($hits.Count)" } }
    $el = $hits[0]
    $rr = Get-Role $el
    # via 说的是「靠什么认出来的」。按 AutomationId 命中却报 via=name，
    # 会让查「为什么点错了」的人一直盯着名字看，而真正生效的是标识符。
    $how = if ($ident) { 'id' } elseif ($name) { 'name' } else { 'role' }
    return @{ target = @{ el = $el; role = $rr; name = (Get-Str $el 'Name').v;
                          desc = (Get-Str $el 'HelpText').v; witness = $hits.Count;
                          via = $how; restricted = $false; scope = 'window' } }
}

function Get-Center($el) {
    $b = Get-Bbox $el
    if ($null -eq $b) { return $null }
    return @([int]($b[0] + $b[2] / 2), [int]($b[1] + $b[3] / 2))
}

function Delivery($state, $retry, $witness) {
    return @{ state = $state; retry = $retry; witness = $witness }
}

# ---------------------------------------------------------------- 动作

$script:RESTRICTED_OK = @('setvalue', 'fill', 'type_into', 'read', 'get', 'state')
$script:RESERVED_CENTER = $null

function Invoke-Act($req) {
    $t0 = Get-Date
    $action = 'click'
    if ($req.action) { $action = [string]$req.action }
    $res = Resolve-Target $req
    if ($res.err) { return @{ ok = $false; error = $res.err } }
    $t = $res.target
    $el = $t.el
    $before = (Get-Value $el).v

    # 受限令牌的门禁：这里回的是「确定没做」，不是「不确定」。
    # 拒绝一个动作必须给出可执行的替代方案，否则调用方只会去试别的歪路。
    if ($t.restricted -and ($script:RESTRICTED_OK -notcontains $action)) {
        return @{
            ok = $false; error = 'TOKEN_RESTRICTED'; action = $action
            role = $t.role; name = $t.name
            allowed = @('fill', 'read', 'state')
            hint = '该元素身份字段没读全，只发了受限令牌（只许填值）。要点击请用 --app/--role/--id 按身份定位。'
            delivery = (Delivery 'not_delivered' 'safe' 'no_path')
        }
    }

    $finish = {
        param($method, $state, $retry, $witness, $extra)
        $after = (Get-Value $el).v
        $o = @{
            ok = ($state -ne 'not_delivered'); action = $action; via = $t.via
            role = $t.role; name = $t.name; before = $before; after = $after
            method = $method
            elapsed_ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 3)
        }
        if ($t.scope -ne 'window') { $o.proven_in = $t.scope }
        if ($t.restricted) { $o.restricted = $true }
        $st = $state
        $wt = $witness
        # 值变了就是最硬的送达证据，可以把 uncertain 升级成 delivered
        if (($st -eq 'uncertain') -and ($before -ne $after)) { $st = 'delivered'; $wt = 'value_delta' }
        $o.delivery = Delivery $st $retry $wt
        if ($st -ne 'delivered') { $o.ok = $false }
        if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
        return $o
    }

    switch ($action) {
        'read' {
            $o = @{ ok = $true; action = 'read'; via = $t.via; role = $t.role; name = $t.name
                    value = $before; witness = $t.witness
                    elapsed_ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 3) }
            if ($t.scope -ne 'window') { $o.proven_in = $t.scope }
            if ($t.restricted) { $o.restricted = $true }
            return $o
        }
        'get' {
            $o = @{ ok = $true; action = 'read'; via = $t.via; role = $t.role; name = $t.name
                    value = $before; witness = $t.witness
                    elapsed_ms = [math]::Round(((Get-Date) - $t0).TotalMilliseconds, 3) }
            if ($t.scope -ne 'window') { $o.proven_in = $t.scope }
            if ($t.restricted) { $o.restricted = $true }
            return $o
        }
        'click' {
            $prefer = 'auto'
            if ($req.prefer) { $prefer = [string]$req.prefer }
            $center = Get-Center $el
            $cnt = 1
            if ($req.count) { $cnt = [int]$req.count }
            if ($prefer -eq 'cg') {
                if ($null -eq $center) { return @{ ok = $false; error = 'NO_BBOX'; delivery = (Delivery 'not_delivered' 'safe' 'no_path') } }
                $n = [Surehand.N]::Click($center[0], $center[1], $cnt, $false)
                return (& $finish 'cgevent_forced' 'uncertain' 'unsafe' 'event_posted' @{ point = $center; sent = $n })
            }
            # auto 优先 InvokePattern：它给确定回执，坐标点击只给「事件已投递」。
            # 这和 macOS 侧的选择一致：宁可多付一次 IPC，也要拿到确认。
            $canInvoke = Has-Pattern $el $INVOKE
            if ($canInvoke) {
                try {
                    $p = $null
                    [void]$el.TryGetCurrentPattern($INVOKE, [ref]$p)
                    $p.Invoke()
                    return (& $finish 'invoke' 'delivered' 'unsafe' 'ax_action_result' @{ ax_error = 0 })
                } catch { }
            }
            # 没有 Invoke 的控件（列表项、标签页）走 SelectionItem，这也算确定回执
            $canSel = Has-Pattern $el $SELITEM
            if ($canSel) {
                try {
                    $p2 = $null
                    [void]$el.TryGetCurrentPattern($SELITEM, [ref]$p2)
                    $p2.Select()
                    return (& $finish 'select' 'delivered' 'unsafe' 'ax_action_result' @{ ax_error = 0 })
                } catch { }
            }
            if ($null -ne $center) {
                $n = [Surehand.N]::Click($center[0], $center[1], $cnt, $false)
                $method = 'cgevent'
                if ($canInvoke -or $canSel) { $method = 'cgevent_after_axpress_fail' }
                return (& $finish $method 'uncertain' 'unsafe' 'event_posted' @{ point = $center; sent = $n; ax_error = 1 })
            }
            if ($canInvoke -or $canSel) {
                return (& $finish 'invoke_failed' 'not_delivered' 'safe' 'ax_action_error' @{ ax_error = 1 })
            }
            return @{ ok = $false; error = 'NO_ACTION_PATH'; role = $t.role; name = $t.name
                      delivery = (Delivery 'not_delivered' 'safe' 'no_path') }
        }
        'press' {
            $canInvoke = Has-Pattern $el $INVOKE
            if ($canInvoke) {
                try {
                    $p = $null
                    [void]$el.TryGetCurrentPattern($INVOKE, [ref]$p)
                    $p.Invoke()
                    return (& $finish 'invoke' 'delivered' 'unsafe' 'ax_action_result' @{ ax_error = 0 })
                } catch { }
            }
            $center = Get-Center $el
            if ($null -ne $center) {
                $n = [Surehand.N]::Click($center[0], $center[1], 1, $false)
                return (& $finish 'cgevent' 'uncertain' 'unsafe' 'event_posted' @{ point = $center; sent = $n })
            }
            return @{ ok = $false; error = 'NO_ACTION_PATH'; delivery = (Delivery 'not_delivered' 'safe' 'no_path') }
        }
        'setvalue' {
            if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
            $text = [string]$req.text
            $ok = $false
            try {
                $vp = $null
                if ($el.TryGetCurrentPattern($VALUE, [ref]$vp)) { $vp.SetValue($text); $ok = $true }
            } catch { $ok = $false }
            if (-not $ok) {
                # 没有 ValuePattern 的输入框（不少自绘控件）退到「聚焦 + 全选 + 输入」
                try {
                    $el.SetFocus()
                    [void][Surehand.N]::Key(0x11, $false)
                    [void][Surehand.N]::Key(0x41, $false)
                    [void][Surehand.N]::Key(0x41, $true)
                    [void][Surehand.N]::Key(0x11, $true)
                    [void][Surehand.N]::Text($text)
                    return (& $finish 'focus_and_type' 'uncertain' 'unsafe' 'event_posted' @{ ax_error = 1 })
                } catch { }
                return (& $finish 'setvalue' 'not_delivered' 'safe' 'ax_action_error' @{ ax_error = 1 })
            }
            return (& $finish 'setvalue' 'delivered' 'safe' 'ax_action_result' @{ ax_error = 0 })
        }
        'fill' {
            if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
            $text = [string]$req.text
            $ok = $false
            try {
                $vp = $null
                if ($el.TryGetCurrentPattern($VALUE, [ref]$vp)) { $vp.SetValue($text); $ok = $true }
            } catch { $ok = $false }
            if (-not $ok) {
                try {
                    $el.SetFocus()
                    [void][Surehand.N]::Key(0x11, $false)
                    [void][Surehand.N]::Key(0x41, $false)
                    [void][Surehand.N]::Key(0x41, $true)
                    [void][Surehand.N]::Key(0x11, $true)
                    [void][Surehand.N]::Text($text)
                    return (& $finish 'focus_and_type' 'uncertain' 'unsafe' 'event_posted' @{ ax_error = 1 })
                } catch { }
                return (& $finish 'setvalue' 'not_delivered' 'safe' 'ax_action_error' @{ ax_error = 1 })
            }
            return (& $finish 'setvalue' 'delivered' 'safe' 'ax_action_result' @{ ax_error = 0 })
        }
        'type_into' {
            if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
            $ok = $false
            try { $el.SetFocus() } catch { }
            try {
                $vp = $null
                if ($el.TryGetCurrentPattern($VALUE, [ref]$vp)) { $vp.SetValue([string]$req.text); $ok = $true }
            } catch { $ok = $false }
            if (-not $ok) {
                [void][Surehand.N]::Text([string]$req.text)
                return (& $finish 'focus_and_type' 'uncertain' 'unsafe' 'event_posted' @{ ax_error = 1 })
            }
            return (& $finish 'setvalue' 'delivered' 'safe' 'ax_action_result' @{ ax_error = 0 })
        }
        'type' {
            if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
            try { $el.SetFocus() } catch { }
            [void][Surehand.N]::Text([string]$req.text)
            return (& $finish 'sendinput_unicode' 'uncertain' 'unsafe' 'event_posted' @{})
        }
        'key' {
            $combo = [string]$req.key
            if (-not $combo) { return @{ ok = $false; error = 'NO_KEY' } }
            $ok = Send-Combo $combo
            if ($ok) { return (& $finish 'sendinput_key' 'uncertain' 'unsafe' 'event_posted' @{}) }
            return (& $finish 'sendinput_key_failed' 'not_delivered' 'unsafe' 'no_path' @{})
        }
        'scroll' {
            $center = Get-Center $el
            if ($null -eq $center) { return @{ ok = $false; error = 'NO_BBOX' } }
            $dy = 3
            if ($req.dy) { $dy = [int]$req.dy }
            [void][Surehand.N]::Wheel($center[0], $center[1], (-1 * $dy), 1)
            return (& $finish 'sendinput_wheel' 'uncertain' 'safe' 'event_posted' @{})
        }
        default {
            return @{ ok = $false; error = "UNKNOWN_ACTION:$action" }
        }
    }
}

# ---------------------------------------------------------------- 输入

$script:VK = @{
    'ctrl' = 0x11; 'control' = 0x11; 'alt' = 0x12; 'option' = 0x12; 'shift' = 0x10
    'win' = 0x5B; 'cmd' = 0x11; 'command' = 0x11; 'meta' = 0x11
    'enter' = 0x0D; 'return' = 0x0D; 'esc' = 0x1B; 'escape' = 0x1B
    'tab' = 0x09; 'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E; 'del' = 0x2E
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
    'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22
    'insert' = 0x2D; 'printscreen' = 0x2C; 'capslock' = 0x14
}

function Get-VK([string]$k) {
    $key = $k.Trim().ToLowerInvariant()
    if ($script:VK.ContainsKey($key)) { return $script:VK[$key] }
    if ($key.Length -eq 1) {
        $c = $key.ToUpperInvariant()
        if ($c -match '^[A-Z0-9]$') { return [int][char]$c }
    }
    if ($key -match '^f([1-9]|1[0-2])$') {
        $idx = [int]$Matches[1]
        return (0x70 + $idx - 1)
    }
    return 0
}

function Send-Combo([string]$combo) {
    $parts = @($combo -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $false }
    $vks = @()
    foreach ($p in $parts) {
        $v = Get-VK $p
        if ($v -eq 0) { return $false }
        $vks += $v
    }
    for ($i = 0; $i -lt $vks.Count; $i++) { [void][Surehand.N]::Key([uint16]$vks[$i], $false) }
    for ($i = $vks.Count - 1; $i -ge 0; $i--) { [void][Surehand.N]::Key([uint16]$vks[$i], $true) }
    return $true
}

# ---------------------------------------------------------------- 命令

function Cmd-Ping {
    return @{ ok = $true; version = $script:VERSION; pid = $PID
              platform = 'windows'; ax_trusted = $true; screen_trusted = $true
              frontmost = [Surehand.N]::Title([Surehand.N]::GetForegroundWindow()) }
}

function Cmd-Apps {
    $wins = Get-WindowIndex
    $fg = [Surehand.N]::GetForegroundWindow()
    $out = @()
    foreach ($p in @(Get-Process | Where-Object { $wins.ContainsKey($_.Id) })) {
        $hs = @($wins[$p.Id])
        $title = ''
        if ($p.MainWindowHandle -ne 0) { $title = [Surehand.N]::Title($p.MainWindowHandle) }
        if (-not $title) { $title = [Surehand.N]::Title($hs[0]) }
        $isFg = $false
        foreach ($h in $hs) { if ($h -eq $fg) { $isFg = $true } }
        $out += @{ name = $p.ProcessName; pid = [int]$p.Id; windows = $hs.Count
                   window = $title; frontmost = $isFg }
    }
    $sorted = @($out | Sort-Object -Property @{ Expression = { if ($_.frontmost) { 0 } else { 1 } } },
                                              @{ Expression = { $_.name } })
    return @{ ok = $true; apps = $sorted }
}

function Cmd-Windows($req) {
    $wins = Get-WindowIndex
    $fg = [Surehand.N]::GetForegroundWindow()
    $out = @()
    $procs = @(Get-Process | Where-Object { $wins.ContainsKey($_.Id) })
    if ($req.app) {
        $one = Resolve-App ([string]$req.app)
        if (-not $one) { return @{ ok = $false; error = 'APP_NOT_FOUND' } }
        $procs = @($one)
    }
    foreach ($p in $procs) {
        if (-not $p) { continue }
        foreach ($h in @($wins[$p.Id])) {
            $r = [Surehand.N]::Rect($h)
            $out += @{
                app = $p.ProcessName; pid = [int]$p.Id; title = [Surehand.N]::Title($h)
                bbox = @($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
                frontmost = ($h -eq $fg)
                main = ($h -eq $p.MainWindowHandle)
            }
        }
    }
    if (($out.Count -eq 0) -and $req.app) { return @{ ok = $false; error = 'NO_WINDOW' } }
    return @{ ok = $true; windows = $out }
}

function Cmd-Activate($req) {
    $r = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($r.err) { return @{ ok = $false; error = $r.err } }
    $ok = [Surehand.N]::ForceForeground($r.hwnd)
    if (-not $ok) {
        return @{ ok = $false; error = 'FOREGROUND_REFUSED'
                  hint = '系统拒绝了前台切换（前台锁）。这是 Windows 的保护机制：让目标窗口自己弹出来，或先手动切一次前台再试。' }
    }
    Start-Sleep -Milliseconds 40
    return @{ ok = $true; app = $r.proc.ProcessName; window = [Surehand.N]::Title($r.hwnd)
              frontmost = [Surehand.N]::Title([Surehand.N]::GetForegroundWindow()) }
}

function Cmd-State($req) {
    $res = Resolve-Target $req
    if ($res.err) { return @{ ok = $false; error = $res.err } }
    $el = $res.target.el
    $o = @{ ok = $true; role = $res.target.role }
    $n = Get-Str $el 'Name';       if ($n.v) { $o.name = $n.v }
    $h = Get-Str $el 'HelpText';   if ($h.v) { $o.desc = $h.v }
    $i = Get-Str $el 'AutomationId'; if ($i.v) { $o.id = $i.v }
    $v = Get-Value $el;            if ($v.v) { $o.value = $v.v }
    $b = Get-Bbox $el;             if ($null -ne $b) { $o.bbox = $b }
    $a = Get-Patterns $el;         if ($a.Count -gt 0) { $o.actions = $a }
    $ev = @{}
    $en = Try-Read $el 'IsEnabled'
    if ($en.ev -eq 'known') { $o.enabled = [bool]$en.v } else { $ev.enabled = $en.ev }
    $fo = Try-Read $el 'HasKeyboardFocus'
    if (($fo.ev -eq 'known') -and [bool]$fo.v) { $o.focused = $true }
    if ($ev.Count -gt 0) { $o.evidence = $ev }
    if ($req.ref) { $o.ref = [string]$req.ref }
    return $o
}

function Cmd-Attrs($req) {
    $el = $null
    if ($req.ref) {
        $entry = $script:Registry[[string]$req.ref]
        if (-not $entry) { return @{ ok = $false; error = 'REF_STALE' } }
        $el = $entry.el
    }
    elseif (($null -ne $req.x) -and ($null -ne $req.y)) {
        $pt = New-Object Surehand.POINT
        $pt.X = [int]$req.x
        $pt.Y = [int]$req.y
        $h = [Surehand.N]::WindowFromPoint($pt)
        if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; error = 'NO_ELEMENT' } }
        $el = $AE::FromHandle($h)
    }
    else { return @{ ok = $false; error = 'NO_POINT' } }

    $props = @{}
    foreach ($p in @('Name', 'AutomationId', 'ClassName', 'HelpText', 'LocalizedControlType',
                     'IsEnabled', 'IsOffscreen', 'IsKeyboardFocusable', 'HasKeyboardFocus',
                     'AcceleratorKey', 'AccessKey', 'ProcessId', 'FrameworkId', 'Orientation')) {
        $r = Try-Read $el $p
        if ($r.ev -eq 'known') { $props[$p] = [string]$r.v } else { $props[$p] = '<unknown>' }
    }
    return @{ ok = $true; role = (Get-Role $el); bbox = (Get-Bbox $el)
              actions = (Get-Patterns $el); props = $props }
}

function Cmd-Shot($req) {
    $r = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($r.err) { return @{ ok = $false; error = $r.err } }
    $wr = [Surehand.N]::Rect($r.hwnd)
    $w = $wr.Right - $wr.Left
    $h = $wr.Bottom - $wr.Top
    if (($w -le 0) -or ($h -le 0)) { return @{ ok = $false; error = 'NO_WINDOW' } }
    $out = Join-Path $env:TEMP ('surehand-{0}.png' -f (Get-Date -Format 'HHmmssfff'))
    if ($req.out) { $out = [string]$req.out }
    $grid = 0
    if ($req.grid) {
        $grid = 100
        if ($req.grid_step) { $grid = [int]$req.grid_step }
    }
    try { [void][Surehand.N]::Capture($wr.Left, $wr.Top, $w, $h, $out, $grid) }
    catch {
        return @{ ok = $false; error = 'CAPTURE_FAILED'
                  hint = '窗口可能被遮挡或最小化；先 activate 再试。'
                  detail = $_.Exception.Message }
    }
    return @{ ok = $true; app = $r.proc.ProcessName; window = [Surehand.N]::Title($r.hwnd)
              out = $out; bbox = @($wr.Left, $wr.Top, $w, $h) }
}

function Cmd-ClickAt($req) {
    $r = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($r.err) { return @{ ok = $false; error = $r.err } }
    if (-not [Surehand.N]::ForceForeground($r.hwnd)) {
        return @{ ok = $false; error = 'FOREGROUND_REFUSED'; delivery = (Delivery 'not_delivered' 'safe' 'no_path') }
    }
    Start-Sleep -Milliseconds 30
    $wr = [Surehand.N]::Rect($r.hwnd)
    # 坐标是窗口内点数，不是屏幕坐标，也不是截图像素——截图会被缩放，照抄必偏。
    $wx = [int]$req.x
    $wy = [int]$req.y
    $x = $wr.Left + $wx
    $y = $wr.Top + $wy
    $cnt = 1
    if ($req.count) { $cnt = [int]$req.count }
    [void][Surehand.N]::Click($x, $y, $cnt, $false)
    return @{ ok = $true; action = 'click'; method = 'sendinput'
              point = @($x, $y); window_point = @($wx, $wy)
              delivery = (Delivery 'uncertain' 'unsafe' 'event_posted') }
}

function Cmd-ScrollAt($req) {
    $r = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($r.err) { return @{ ok = $false; error = $r.err } }
    if (-not [Surehand.N]::ForceForeground($r.hwnd)) {
        return @{ ok = $false; error = 'FOREGROUND_REFUSED'; delivery = (Delivery 'not_delivered' 'safe' 'no_path') }
    }
    $wr = [Surehand.N]::Rect($r.hwnd)
    $x = $wr.Left + [int]$req.x
    $y = $wr.Top + [int]$req.y
    $dy = -6
    if ($req.dy) { $dy = [int]$req.dy }
    $times = 1
    if ($req.times) { $times = [int]$req.times }
    [void][Surehand.N]::Wheel($x, $y, $dy, $times)
    return @{ ok = $true; action = 'scroll'; method = 'sendinput_wheel'
              point = @($x, $y); dy = $dy; times = $times
              delivery = (Delivery 'uncertain' 'safe' 'event_posted') }
}

function Cmd-MoveAt($req) {
    $r = Get-RootEl ([string]$req.app) ([string]$req.window)
    if ($r.err) { return @{ ok = $false; error = $r.err } }
    $wr = [Surehand.N]::Rect($r.hwnd)
    $x = $wr.Left + [int]$req.x
    $y = $wr.Top + [int]$req.y
    [Surehand.N]::Move($x, $y)
    return @{ ok = $true; action = 'hover'; point = @($x, $y) }
}

function Cmd-TypeText($req) {
    if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
    $n = [Surehand.N]::Text([string]$req.text)
    return @{ ok = $true; action = 'type'; sent = $n
              delivery = (Delivery 'uncertain' 'unsafe' 'event_posted') }
}

function Cmd-Keys($req) {
    $ok = Send-Combo ([string]$req.key)
    if ($ok) {
        return @{ ok = $true; action = 'keys'; delivery = (Delivery 'uncertain' 'unsafe' 'event_posted') }
    }
    return @{ ok = $false; action = 'keys'; delivery = (Delivery 'not_delivered' 'unsafe' 'no_path') }
}

function Cmd-Paste($req) {
    if ($null -eq $req.text) { return @{ ok = $false; error = 'NO_TEXT' } }
    $prev = $null
    $had = $false
    try { $prev = Get-Clipboard -Raw; $had = $true } catch { }
    try { Set-Clipboard -Value ([string]$req.text) }
    catch { return @{ ok = $false; error = 'CLIPBOARD_FAILED'; detail = $_.Exception.Message } }
    # 粘贴是「不确定投递」：按键进去了，目标是否接受只有界面知道。
    [void](Send-Combo 'ctrl+v')
    if ($req.restore -and $had -and ($null -ne $prev)) {
        Start-Sleep -Milliseconds 120
        try { Set-Clipboard -Value $prev } catch { }
    }
    return @{ ok = $true; action = 'paste'; chars = ([string]$req.text).Length
              delivery = (Delivery 'uncertain' 'unsafe' 'event_posted') }
}

function Cmd-Hit($req) {
    if (($null -eq $req.x) -or ($null -eq $req.y)) { return @{ ok = $false; error = 'NO_POINT' } }
    $pt = New-Object Surehand.POINT
    $pt.X = [int]$req.x
    $pt.Y = [int]$req.y
    $h = [Surehand.N]::WindowFromPoint($pt)
    if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; error = 'NO_ELEMENT' } }
    $el = $AE::FromHandle($h)
    $o = @{ ok = $true; role = (Get-Role $el); pid = [int][Surehand.N]::PidOf($h)
            window = [Surehand.N]::Title($h) }
    $n = Get-Str $el 'Name'
    if ($n.v) { $o.name = $n.v }
    $b = Get-Bbox $el
    if ($null -ne $b) { $o.bbox = $b }
    return $o
}

function Handle($req) {
    $cmd = [string]$req.cmd
    switch ($cmd) {
        'ping'     { return Cmd-Ping }
        'apps'     { return Cmd-Apps }
        'windows'  { return Cmd-Windows $req }
        'snapshot' { return Get-Snapshot $req }
        'act'      { return Invoke-Act $req }
        'state'    { return Cmd-State $req }
        'attrs'    { return Cmd-Attrs $req }
        'shot'     { return Cmd-Shot $req }
        'clickat'  { return Cmd-ClickAt $req }
        'scrollat' { return Cmd-ScrollAt $req }
        'moveat'   { return Cmd-MoveAt $req }
        'hover'    { return Cmd-MoveAt $req }
        'activate' { return Cmd-Activate $req }
        'typetext' { return Cmd-TypeText $req }
        'keys'     { return Cmd-Keys $req }
        'paste'    { return Cmd-Paste $req }
        'hit'      { return Cmd-Hit $req }
        'sleep'    { Start-Sleep -Milliseconds ([int]$req.ms); return @{ ok = $true } }
        default    { return @{ ok = $false; error = "UNKNOWN_CMD:$cmd" } }
    }
}

# ---------------------------------------------------------------- 单实例与服务端

$mutex = [System.Threading.Mutex]::new($false, $script:MUTEX_NAME)
$owned = $false
try { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    # 已经有一个在跑：这不是错误，是单实例语义。让它继续，本进程安静退出。
    Write-Log 'another instance holds the lock, exiting'
    Write-Output 'WCCD_ALREADY_RUNNING'
    exit 0
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$raw = New-Object byte[] 32
$rng.GetBytes($raw)
$token = [Convert]::ToBase64String($raw)

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$realPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

New-Item -ItemType Directory -Force -Path $script:ENDPOINT_DIR | Out-Null
$epJson = @{ port = $realPort; token = $token; pid = $PID; version = $script:VERSION } |
    ConvertTo-Json -Compress
# 必须写无 BOM 的 UTF-8：带 BOM 的 JSON 会让 Python 侧 json.loads 直接失败。
[System.IO.File]::WriteAllText($script:ENDPOINT_FILE, $epJson,
    (New-Object System.Text.UTF8Encoding($false)))
try {
    # 端点文件含令牌，只给当前用户读。失败不致命（家目录 ACL 通常已足够）。
    & icacls.exe $script:ENDPOINT_FILE /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
} catch { }

Write-Log "listening 127.0.0.1:$realPort pid=$PID"

$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue
$ser.RecursionLimit = 200

function Send-Json($client, $obj) {
    try {
        $json = $ser.Serialize($obj)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json + "`n")
        $client.GetStream().Write($bytes, 0, $bytes.Length)
        $client.GetStream().Flush()
    } catch { Write-Log "write failed: $($_.Exception.Message)" }
}

$clients = New-Object System.Collections.ArrayList
$running = $true

while ($running) {
    try {
        # 非阻塞轮转：一条空闲连接（客户端发完请求不关）不许堵死其他连接。
        # UIA 客户端本来就要求串行调用，所以不做多线程，只做不互相挡。
        if ($listener.Pending()) {
            $c = $listener.AcceptTcpClient()
            $c.NoDelay = $true
            [void]$clients.Add(@{ Sock = $c; Buf = (New-Object System.Text.StringBuilder); Authed = $false })
        }

        foreach ($st in @($clients)) {
            $c = $st.Sock
            $stream = $null
            try { $stream = $c.GetStream() } catch { [void]$clients.Remove($st); continue }
            if (-not $stream.DataAvailable) { continue }

            $buf = New-Object byte[] 65536
            $read = 0
            try { $read = $stream.Read($buf, 0, $buf.Length) } catch { $read = 0 }
            if ($read -le 0) {
                try { $c.Close() } catch { }
                [void]$clients.Remove($st)
                continue
            }

            [void]$st.Buf.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $read))
            $text = $st.Buf.ToString()
            $drop = $false
            while ($text.Contains("`n")) {
                $idx = $text.IndexOf("`n")
                $line = $text.Substring(0, $idx).Trim()
                $text = $text.Substring($idx + 1)
                if (-not $line) { continue }

                try { $req = ConvertFrom-Json $line }
                catch {
                    Send-Json $c @{ ok = $false; error = 'BAD_JSON' }
                    continue
                }

                if (-not $st.Authed) {
                    $tok = [string]$req.token
                    if ($tok -ne $token) {
                        Send-Json $c @{ ok = $false; error = 'BAD_TOKEN' }
                        Write-Log 'rejected client with bad token'
                        $drop = $true
                        break
                    }
                    $st.Authed = $true
                    Send-Json $c @{ ok = $true }
                    continue
                }

                $cmdName = [string]$req.cmd
                if ($cmdName -eq 'shutdown') {
                    Send-Json $c @{ ok = $true }
                    Write-Log 'shutdown requested'
                    $running = $false
                    break
                }

                try { $resp = Handle $req }
                catch {
                    $resp = @{ ok = $false; error = 'INTERNAL'; detail = $_.Exception.Message }
                    Write-Log "handler error ($cmdName): $($_.Exception.Message)"
                }
                Send-Json $c $resp
            }
            [void]$st.Buf.Clear()
            [void]$st.Buf.Append($text)
            if ($drop) {
                try { $c.Close() } catch { }
                [void]$clients.Remove($st)
            }
        }
    }
    catch { Write-Log "loop error: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 4
}

try { $listener.Stop() } catch { }
foreach ($st in @($clients)) { try { $st.Sock.Close() } catch { } }
try { Remove-Item $script:ENDPOINT_FILE -ErrorAction SilentlyContinue } catch { }
try { $mutex.ReleaseMutex() } catch { }
Write-Log 'stopped'
exit 0
