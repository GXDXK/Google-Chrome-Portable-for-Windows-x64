#Requires -Version 5.1
# =====================================================================
#  ChromePlusUpdater.ps1
#  Chrome 便携版更新器 —— 基于 Chrome++ Next 的 Chrome 便携版 构建/更新工具
#
#  功能：
#    1. 显示 Chrome / Chrome++ Next 的本地版本号
#    2. 检查最新版本（Chrome 走 Google update2 API，Chrome++ Next 走 GitHub Releases API）
#    3. 更新 Chrome（下载离线安装包 → 解压 → 注入 version-x64.dll → 组装 App）
#    4. 更新 Chrome++ Next（下载 release 的 setdll.7z → 更新 Tool\chrome_plus 目录）
#    5. 一键检查并更新两者
#
#  启动方式：双击 ChromePlusUpdater.bat
#  命令行：  powershell -NoProfile -ExecutionPolicy Bypass -STA -File ChromePlusUpdater.ps1
#  测试模式：powershell -NoProfile -File ChromePlusUpdater.ps1 -Test
# =====================================================================

param(
    [switch]$Test,      # 命令行测试模式（不启动 GUI，直接检查一次并输出结果）
    [switch]$GuiSmoke   # GUI 冒烟测试（启动界面后 2.5 秒自动关闭，用于验证界面可正常构建）
)

# 让进程启用系统 DPI 感知并立即隐藏控制台窗口：
#   - DPI 感知保证高分屏（如 150% 缩放）上界面清晰（PowerShell 7 已默认感知，此调用静默失败、无影响）
#   - 隐藏控制台避免启动时闪现 PowerShell 黑框（仅 GUI 模式，测试模式保留控制台输出）
if (-not $script:WorkerMode -and -not $Test) {
    try {
        Add-Type -Name NativeWin -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int awareness);
[DllImport("user32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        [void][Win32.NativeWin]::SetProcessDpiAwareness(1)
        $hwnd = [Win32.NativeWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [void][Win32.NativeWin]::ShowWindow($hwnd, 0) }
    } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 兼容 Windows PowerShell 5.1 的 TLS 1.2（PowerShell 7 默认已启用）
try {
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch { }

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# 全局配置
# ---------------------------------------------------------------------
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:BaseDir = if ($script:WorkerBaseDir) { $script:WorkerBaseDir }
                  elseif ($PSScriptRoot) { $PSScriptRoot }
                  else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ToolDir = Join-Path $script:BaseDir 'Tool'
$script:AppDir  = Join-Path $script:BaseDir 'App'
$script:TempDir = Join-Path $script:BaseDir 'Temp'

# Tool 目录结构：Tool\7-Zip\、Tool\chrome_plus\、Tool\Wget\（每类工具分开放置）
$script:ZipToolDir  = Join-Path $script:ToolDir '7-Zip'
$script:PlusToolDir = Join-Path $script:ToolDir 'chrome_plus'
$script:WgetToolDir = Join-Path $script:ToolDir 'Wget'

$script:SevenZipFull = Join-Path $script:ZipToolDir '7z.exe'
$script:SevenZipDll  = Join-Path $script:ZipToolDir '7z.dll'
$script:SevenZip     = Join-Path $script:ZipToolDir '7za.exe'
$script:SevenZipR    = Join-Path $script:ZipToolDir '7zr.exe'
$script:WgetExe      = Join-Path $script:WgetToolDir 'wget.exe'
$script:SetDll       = Join-Path $script:PlusToolDir 'setdll-x64.exe'
$script:VersionDll   = Join-Path $script:PlusToolDir 'version-x64.dll'
$script:DefaultIni   = Join-Path $script:PlusToolDir 'chrome++.ini'
$script:ChromeExe  = Join-Path $script:AppDir 'chrome.exe'

$script:ChromeUpdateCheckUrl = 'https://tools.google.com/service/update2'
$script:ChromeDownloadUrl    = 'https://dl.google.com/tag/s/installdataindex/update2/installers/ChromeStandaloneSetup64.exe'
$script:ChromePlusApiUrl     = 'https://api.github.com/repos/Bush2021/chrome_plus/releases/latest'
$script:ChromePlusReleaseUrl = 'https://github.com/Bush2021/chrome_plus/releases/latest'
$script:WgetUrl              = 'https://eternallybored.org/misc/wget/1.21.4/64/wget.exe'
$script:SevenZipApi          = 'https://api.github.com/repos/ip7z/7zip/releases/latest'

# 硬编码的 update_check.xml（用于查询 Chrome 最新版本，不再依赖 Tool 中的文件）
$script:EmbeddedUpdateXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" installsource="update3web-ondemand" dedup="cr">
  <os platform="win" version="10.0.26200.1000" arch="x64" />
  <app appid="{8A69D345-D564-463C-AFF1-A69D9E530F96}" ap="x64-stable-multi-chrome" lang="en-us">
    <updatecheck />
  </app>
</request>
'@

# 运行状态（worker runspace 与 UI runspace 共享，通过线程安全的哈希表传递）
$script:ChromeLocal   = $null
$script:ChromeLatest  = $null
$script:PlusLocal     = $null
$script:PlusLatest    = $null
$script:PlusRelease   = $null
$script:IsBusy        = $false
$script:UIScale       = 1.0
$script:WorkerRunspace = $null
$script:WorkerPowerShell = $null
$script:WorkerHandle  = $null
$script:ForceShown    = $false
if (-not $script:Shared) {
    $script:Shared = [hashtable]::Synchronized(@{
        LogQueue       = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        Cancel         = $false
        CurrentProcess = $null
    })
}

# ---------------------------------------------------------------------
# 基础工具函数
# ---------------------------------------------------------------------

function Get-Color {
    param([string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Send-Log {
    param([string]$Level, [string]$Text)
    $script:Shared.LogQueue.Enqueue([pscustomobject]@{ L = $Level; T = $Text })
}

function Send-Status {
    param([string]$Text)
    $script:Shared.LogQueue.Enqueue([pscustomobject]@{ L = 'STATUS'; T = $Text })
}

function Send-Section {
    # 统一的小节标题（如：========== 检查更新 ==========）
    param([string]$Name)
    Send-Log STEP "========== $Name =========="
}

function Send-ProgressReset {
    # 通知界面把进度条从“确定百分比”恢复为不确定（Marquee）状态
    $script:Shared.LogQueue.Enqueue([pscustomobject]@{ L = 'PROGRESS_RESET'; T = '' })
}

function Format-FileSize {
    # 统一文件大小显示：小于 1MB 用 KB，否则用 MB（保留 1 位小数）
    param([long]$Bytes)
    if ($Bytes -lt 1MB) {
        return ("{0:N0} KB" -f ($Bytes / 1KB))
    }
    return ("{0:N1} MB" -f ($Bytes / 1MB))
}

function Test-Cancelled {
    if ($script:Shared.Cancel) {
        throw '用户取消了操作'
    }
}

function Join-ArgumentString {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
}

function Compare-Version {
    # 数值分段比较版本号，返回 -1 / 0 / 1（a < b / a = b / a > b）
    param([string]$A, [string]$B)
    $pa = @($A -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse(($_ -replace '\D.*$', ''), [ref]$n); $n })
    $pb = @($B -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse(($_ -replace '\D.*$', ''), [ref]$n); $n })
    $max = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Get-ChromeLocalVersion {
    if (Test-Path -LiteralPath $script:ChromeExe) {
        try {
            $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:ChromeExe)
            if ($v.ProductVersion) { return ([string]$v.ProductVersion).Trim() }
        } catch { }
    }
    return $null
}

function Get-ChromePlusLocalVersion {
    if (Test-Path -LiteralPath $script:VersionDll) {
        try {
            $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:VersionDll)
            if ($v.ProductVersion) { return ([string]$v.ProductVersion).Trim() }
        } catch { }
    }
    return $null
}

function Get-LatestChromeVersion {
    # 通过 Google update2 API 查询 Chrome 最新稳定版（x64），update_check.xml 已硬编码在脚本中
    $body = [System.Text.Encoding]::UTF8.GetBytes($script:EmbeddedUpdateXml)
    $resp = Invoke-WebRequest -Uri $script:ChromeUpdateCheckUrl -Method Post `
        -ContentType 'application/xml' -Body $body -UseBasicParsing -TimeoutSec 30
    [xml]$doc = $resp.Content
    $node = $doc.SelectSingleNode('/response/app/updatecheck/manifest/@version')
    if (-not $node) { throw 'Chrome 更新服务返回了意外的响应格式' }
    return ([string]$node.Value).Trim()
}

function Get-LatestChromePlusVersion {
    # 查询 chrome_plus 最新 release（GitHub API），返回版本号与 setdll.7z 下载地址
    $rel = Invoke-RestMethod -Uri $script:ChromePlusApiUrl `
        -Headers @{ 'User-Agent' = 'Chrome-Portable-Updater/1.0' } -TimeoutSec 30
    $tag = [string]$rel.tag_name
    $ver = $tag -replace '^[vV]', ''
    $asset = @($rel.assets) | Where-Object { $_.name -eq 'setdll.7z' } | Select-Object -First 1
    if (-not $asset) { throw "最新 release（$tag）中没有找到 setdll.7z 资产" }
    return @{
        Version  = $ver
        AssetUrl = [string]$asset.browser_download_url
        HtmlUrl  = [string]$rel.html_url
    }
}

function Get-RunningPortableChrome {
    try {
        return @(Get-Process -Name chrome -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -eq $script:ChromeExe })
    } catch {
        return @()
    }
}

function Invoke-Download {
    # 优先使用 Tool\wget.exe（支持断点续传），失败时回退到 .NET 下载
    param(
        [string]$Url,
        [string]$Dest,
        [long]$MinBytes,
        [string]$Label
    )
    Send-Log INFO $Label
    $destDir = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    if (Test-Path -LiteralPath $script:WgetExe) {
        Send-Status '正在下载…'
        $code = Invoke-WgetDownload -Url $Url -Dest $Dest
        $size = (Get-Item -LiteralPath $Dest -ErrorAction SilentlyContinue).Length
        if ($code -eq 0 -and $size -ge $MinBytes) {
            Send-ProgressReset
            Send-Status '下载完成'
            return $size
        }
        Send-Log WARN 'wget 下载未成功，改用内置下载器重试…'
    } else {
        Send-Log WARN 'Tool\wget.exe 不存在，使用内置下载器下载（无断点续传）…'
    }

    Test-Cancelled
    Send-Status '正在下载（内置下载器，无进度显示）…'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
    } catch {
        Send-ProgressReset
        throw "下载失败：$($_.Exception.Message)"
    }
    $size = (Get-Item -LiteralPath $Dest -ErrorAction SilentlyContinue).Length
    if ($size -lt $MinBytes) {
        Send-ProgressReset
        throw "下载的文件不完整（$size 字节）"
    }
    Send-Status '下载完成'
    return $size
}

function Update-WgetProgress {
    # 解析 wget 的进度行（如：7zr.exe  91%[====>  ] 536.56K  2.15MB/s）并推送界面更新
    param([string]$Line)
    if ($Line -notmatch '%') { return }
    $pct = $null
    if ($Line -match '(\d+)\s*%') { $pct = [int]$Matches[1] }
    $speed = ''
    if ($Line -match '(\d[\d.]*)([KMGT]?)B/s') { $speed = '{0} {1}B/s' -f $Matches[1], $Matches[2] }
    $eta = ''
    if ($Line -match '\beta\s+([0-9ms ]+)') { $eta = $Matches[1].Trim() }
    if ($null -ne $pct) {
        $script:Shared.LogQueue.Enqueue([pscustomobject]@{ L = 'PROGRESS'; T = $pct })
        $text = "正在下载：$pct%"
        if ($speed) { $text += " · $speed" }
        if ($eta) { $text += " · 剩余 $eta" }
        $script:Shared.LogQueue.Enqueue([pscustomobject]@{ L = 'STATUS'; T = $text })
    }
}

function Invoke-WgetDownload {
    # 以带进度输出的方式运行 wget，逐行解析进度并实时更新界面
    param([string]$Url, [string]$Dest)
    $destDir = Split-Path -Parent $Dest
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:WgetExe
    $psi.Arguments = Join-ArgumentString @('-c', '--tries=3', '--timeout=30', '--progress=bar:force:noscroll', $Url, '-P', $destDir)
    $psi.WorkingDirectory = $script:BaseDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        throw "无法运行 wget.exe：$($_.Exception.Message)"
    }
    $script:Shared.CurrentProcess = $proc
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    try {
        while (-not $proc.StandardError.EndOfStream) {
            if ($script:Shared.Cancel) {
                Send-Log WARN '正在取消当前操作…'
                try { $proc.Kill() } catch { }
                throw '用户取消了操作'
            }
            $line = $proc.StandardError.ReadLine()
            if ($line) { Update-WgetProgress $line }
        }
        while (-not $proc.WaitForExit(200)) {
            if ($script:Shared.Cancel) {
                Send-Log WARN '正在取消当前操作…'
                try { $proc.Kill() } catch { }
                throw '用户取消了操作'
            }
        }
    } finally {
        $script:Shared.CurrentProcess = $null
    }
    $out = $outTask.Result
    if ($proc.ExitCode -ne 0) {
        $tail = (($out -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 3) -join ' | '
        Send-Log WARN "命令退出码 $($proc.ExitCode)$(if ($tail) { "（$tail）" })"
    }
    return $proc.ExitCode
}

function Invoke-ToolProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Label = (Split-Path -Leaf $FilePath),
        [string]$WorkingDirectory = $script:BaseDir
    )
    Send-Log INFO $Label
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-ArgumentString $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        throw "无法运行 $FilePath：$($_.Exception.Message)"
    }
    $script:Shared.CurrentProcess = $proc
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try {
        while (-not $proc.WaitForExit(200)) {
            if ($script:Shared.Cancel) {
                Send-Log WARN '正在取消当前操作…'
                try { $proc.Kill() } catch { }
                throw '用户取消了操作'
            }
        }
    } finally {
        $script:Shared.CurrentProcess = $null
    }
    $output = ($outTask.Result) + ($errTask.Result)
    if ($proc.ExitCode -ne 0) {
        $tail = (($output -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '^\s*[|<>~+=-]+\s*$' } | Select-Object -Last 4) -join ' | '
        Send-Log WARN "命令退出码 $($proc.ExitCode)$(if ($tail) { "（$tail）" })"
    }
    return $proc.ExitCode
}

function Remove-TempDir {
    # 只允许删除 BaseDir 下的 Temp，防止误删
    $p = $script:TempDir
    if ($p -and $p.StartsWith($script:BaseDir, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $p)) {
        for ($i = 0; $i -lt 3; $i++) {
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                return
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

# ---------------------------------------------------------------------
# 核心操作（在 worker 线程中执行）
# ---------------------------------------------------------------------

function Send-Versions {
    # 将最新版本信息发回 UI 线程（消息队列中的 VERSIONS 消息）
    $script:Shared.LogQueue.Enqueue([pscustomobject]@{
        L = 'VERSIONS'
        T = @{
            ChromeLatest = $script:ChromeLatest
            PlusLatest   = $script:PlusLatest
            PlusRelease  = $script:PlusRelease
        }
    })
}

function Invoke-CheckUpdates {
    # 每次运行都检查 Tool 完整性，缺失时自动恢复
    [void](Repair-ToolFiles)
    Send-Log STEP '开始检查更新…'
    Test-Cancelled
    try {
        $script:ChromeLatest = Get-LatestChromeVersion
        Send-Log OK "Chrome 最新版本：$($script:ChromeLatest)"
    } catch {
        $script:ChromeLatest = $null
        Send-Log ERR "Chrome 版本检查失败：$($_.Exception.Message)"
    }
    Test-Cancelled
    try {
        $script:PlusRelease = Get-LatestChromePlusVersion
        $script:PlusLatest = $script:PlusRelease.Version
        Send-Log OK "Chrome++ Next 最新版本：$($script:PlusLatest)"
    } catch {
        $script:PlusLatest = $null
        $script:PlusRelease = $null
        Send-Log ERR "Chrome++ Next 版本检查失败：$($_.Exception.Message)"
    }
    Send-Versions
    Send-Log OK '检查完成'
}

function Repair-ToolFiles {
    # 每次运行都检查 Tool 完整性，缺失时按顺序自动获取：
    #   1) wget.exe（优先，供后续下载使用）
    #   2) 7-Zip 工具（7z.exe+7z.dll / 7za.exe / 7zr.exe）
    #   3) Chrome++ Next x64 工具（setdll-x64.exe / version-x64.dll / chrome++.ini）
    $okWget = Ensure-Wget
    $okZip  = Ensure-SevenZip
    $okPlus = Ensure-PlusFiles
    return ($okWget -and $okZip -and $okPlus)
}

function Ensure-PlusFiles {
    # 确保 Tool\chrome_plus 中的 x64 工具完整（setdll-x64.exe / version-x64.dll / chrome++.ini），
    # 缺失时从 Chrome++ Next 最新 release 的 setdll.7z 恢复（仅保留 x64，不复制 arm64/x86 文件）
    $required = @($script:SetDll, $script:VersionDll, $script:DefaultIni)
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -eq 0) { return $true }

    $names = ($missing | ForEach-Object { Split-Path -Leaf $_ }) -join '、'
    Send-Log WARN "Chrome++ Next 工具缺少 $names，正在自动恢复…"

    try {
        $rel = Get-LatestChromePlusVersion
    } catch {
        Send-Log ERR "获取 Chrome++ Next 最新 release 失败：$($_.Exception.Message)"
        return $false
    }
    Test-Cancelled

    Remove-TempDir
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $pkg = Join-Path $script:TempDir 'setdll.7z'
    try {
        $size = Invoke-Download -Url $rel.AssetUrl -Dest $pkg -MinBytes 10KB -Label "正在下载 setdll.7z（Chrome++ Next $($rel.Version)）"
        Send-Log OK ("已下载 setdll.7z（{0}）" -f (Format-FileSize $size))
    } catch {
        Send-Log ERR "setdll.7z 下载失败：$($_.Exception.Message)"
        Remove-TempDir
        return $false
    }

    $extractDir = Join-Path $script:TempDir 'setdll_repair'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    $r = Invoke-ToolProcess $script:SevenZip @('x', $pkg, ("-o" + $extractDir), '-y') '7-Zip 解压 setdll.7z'
    if ($r -gt 1) {
        Send-Log ERR '解压 setdll.7z 失败'
        Remove-TempDir
        return $false
    }

    # 仅复制 x64 工具到 Tool\chrome_plus
    New-Item -ItemType Directory -Force -Path $script:PlusToolDir | Out-Null
    foreach ($f in @('setdll-x64.exe', 'version-x64.dll', 'chrome++.ini')) {
        $src = Join-Path $extractDir $f
        if (-not (Test-Path -LiteralPath $src)) {
            Send-Log ERR "setdll.7z 内容缺少 $f"
            Remove-TempDir
            return $false
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $script:PlusToolDir $f) -Force
    }
    # 同步 App 中的插件文件
    if (Test-Path -LiteralPath $script:AppDir) {
        Copy-Item -LiteralPath (Join-Path $script:PlusToolDir 'version-x64.dll') -Destination (Join-Path $script:AppDir 'version-x64.dll') -Force
    }
    Remove-TempDir

    Send-Log OK "Chrome++ Next x64 工具已恢复（$($rel.Version)）"
    return $true
}

function Ensure-SevenZip {
    # 确保 7-Zip 命令行工具可用：
    #   1) 优先 7z.exe + 7z.dll（完整版，支持全部格式）
    #   2) 其次 7za.exe（独立精简版）
    # 全部缺失时自动获取（引导链：查询最新 release → 临时下载 7zr.exe → 解压 extra 包解出 7za →
    #   删除 7zr → 下载最新 7zNNNN-x64.exe 解出完整版 7z.exe + 7z.dll）

    if ((Test-Path -LiteralPath $script:SevenZipFull) -and (Test-Path -LiteralPath $script:SevenZipDll)) {
        $script:SevenZip = $script:SevenZipFull
        return $true
    }
    if (Test-Path -LiteralPath $script:SevenZip) { return $true }   # 7za.exe 可用

    Send-Log WARN '缺少 7-Zip 命令行工具，正在自动获取…'

    # 查询最新 release（7zr.exe / extra 包 / x64 安装包共用同一个最新 tag）
    Send-Log INFO '查询 7-Zip 最新版本…'
    try {
        $rel = Invoke-RestMethod -Uri $script:SevenZipApi -Headers @{ 'User-Agent' = 'Chrome-Portable-Updater/1.0' } -TimeoutSec 30
    } catch {
        Send-Log ERR "查询 7-Zip 最新 release 失败：$($_.Exception.Message)"
        return $false
    }
    $tag = [string]$rel.tag_name
    $asset7zr = @($rel.assets) | Where-Object { $_.name -eq '7zr.exe' } | Select-Object -First 1
    $assetExtra = @($rel.assets) | Where-Object { $_.name -match '^7z\d+-extra\.7z$' } | Select-Object -First 1
    $assetX64 = @($rel.assets) | Where-Object { $_.name -match '^7z\d+-x64\.exe$' } | Select-Object -First 1
    if (-not $asset7zr -or -not $assetExtra -or -not $assetX64) {
        Send-Log ERR "最新 release（$tag）中缺少所需资产（7zr.exe / extra 包 / x64 安装包）"
        return $false
    }

    # 引导：临时下载 7zr.exe（仅支持 7z 格式，仅用于解压纯 7z 的 extra 包，用后即删）
    $tmp7zr = $null
    try {
        Remove-TempDir
        New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
        $tmp7zr = Join-Path $script:TempDir '7zr.exe'
        Send-Log INFO '正在下载 7zr.exe（临时引导，仅用于解压 extra 包）…'
        $sz = Invoke-Download -Url $asset7zr.browser_download_url -Dest $tmp7zr -MinBytes 100KB -Label '正在下载 7zr.exe'
        Send-Log OK ("已下载 7zr.exe（{0}）" -f (Format-FileSize $sz))
    } catch {
        Send-Log ERR "7zr.exe 下载失败：$($_.Exception.Message)"
        Remove-TempDir
        return $false
    }

    # 用 7zr 解出 7za.exe（extra 包是纯 7z 格式），随后删除 7zr.exe
    try {
        $extra = Join-Path $script:TempDir $assetExtra.name
        Send-Log INFO "正在下载 $($assetExtra.name)（含 7za.exe）…"
        $null = Invoke-Download -Url $assetExtra.browser_download_url -Dest $extra -MinBytes 100KB -Label "正在下载 $($assetExtra.name)"
        $outDir = Join-Path $script:TempDir '7zip_extra'
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $r = Invoke-ToolProcess $tmp7zr @('x', $extra, ("-o" + $outDir), '-y') '7zr 解压 extra 包'
        if ($r -gt 1) { throw "解压 extra 包失败（退出码 $r）" }
        $candidate = Get-ChildItem -Path $outDir -Recurse -Filter '7za.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
        if (-not $candidate) {
            $candidate = Get-ChildItem -Path $outDir -Recurse -Filter '7za.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $candidate) { throw 'extra 包中未找到 7za.exe' }
        New-Item -ItemType Directory -Force -Path $script:ZipToolDir | Out-Null
        Copy-Item -LiteralPath $candidate.FullName -Destination $script:SevenZip -Force
        # 7zr.exe 仅用于引导，使用完毕立即删除
        Remove-Item -LiteralPath $tmp7zr -Force -ErrorAction SilentlyContinue
        Send-Log OK '已获取 7za.exe，临时 7zr.exe 已删除'
    } catch {
        Send-Log ERR "获取 7za.exe 失败：$($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp7zr -Force -ErrorAction SilentlyContinue
        Remove-TempDir
        return $false
    }

    # 用 7za 解压最新 x64 自解压安装包，获取完整版 7z.exe + 7z.dll
    try {
        Remove-TempDir
        New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
        $installer = Join-Path $script:TempDir $assetX64.name
        Send-Log INFO "正在下载 $($assetX64.name)（7-Zip $tag）…"
        $null = Invoke-Download -Url $assetX64.browser_download_url -Dest $installer -MinBytes 500KB -Label "正在下载 $($assetX64.name)"
        $outDir = Join-Path $script:TempDir '7zip_full'
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $r = Invoke-ToolProcess $script:SevenZip @('x', $installer, ("-o" + $outDir), '-y') '解压 7-Zip 安装包'
        if ($r -gt 1) { throw "解压安装包失败（退出码 $r）" }
        if (-not (Test-Path -LiteralPath (Join-Path $outDir '7z.exe')) -or
            -not (Test-Path -LiteralPath (Join-Path $outDir '7z.dll'))) {
            throw '安装包中未找到 7z.exe / 7z.dll'
        }
        Copy-Item -LiteralPath (Join-Path $outDir '7z.exe') -Destination $script:SevenZipFull -Force
        Copy-Item -LiteralPath (Join-Path $outDir '7z.dll') -Destination $script:SevenZipDll -Force
        Remove-TempDir
        $script:SevenZip = $script:SevenZipFull
        Send-Log OK "已获取完整版 7z.exe + 7z.dll（7-Zip $tag）"
        return $true
    } catch {
        Send-Log ERR "获取完整版 7z.exe + 7z.dll 失败：$($_.Exception.Message)"
        Remove-TempDir
        Send-Log INFO '继续使用已获取的 7za.exe'
        return $true
    }
}

function Ensure-Wget {
    # wget.exe 缺失时，用 PowerShell 内置下载器从 eternallybored.org 获取
    if (Test-Path -LiteralPath $script:WgetExe) { return $true }
    Send-Log WARN "缺少 wget.exe，正在从 eternallybored.org 下载…"
    try {
        Remove-TempDir
        New-Item -ItemType Directory -Force -Path $script:WgetToolDir, $script:TempDir | Out-Null
        $tmp = Join-Path $script:TempDir 'wget.exe'
        Invoke-WebRequest -Uri $script:WgetUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 120
        $size = (Get-Item -LiteralPath $tmp -ErrorAction SilentlyContinue).Length
        if ($size -lt 1MB) { throw "下载的 wget.exe 不完整（$size 字节）" }
        Copy-Item -LiteralPath $tmp -Destination $script:WgetExe -Force
        Remove-TempDir
        Send-Log OK ("已下载 wget.exe（{0}）" -f (Format-FileSize $size))
        return $true
    } catch {
        Send-Log ERR "wget.exe 下载失败：$($_.Exception.Message)"
        Remove-TempDir
        return $false
    }
}

function Invoke-ChromeUpdate {
    param([bool]$Force = $false)

    Test-Cancelled
    if (-not (Repair-ToolFiles)) {
        throw 'Tool 工具完整性检查失败，无法继续'
    }
    if (-not (Test-Path -LiteralPath $script:SevenZip)) {
        throw '7-Zip 命令行工具不可用，无法继续'
    }
    if (-not $script:ChromeLatest) {
        $script:ChromeLatest = Get-LatestChromeVersion
    }
    $latest = $script:ChromeLatest
    $local = Get-ChromeLocalVersion
    if (-not $Force -and $local -and (Compare-Version $latest $local) -le 0) {
    Send-Log OK "Chrome 已是最新版本 $local，无需更新"
        return $false
    }
    if ($local) {
    Send-Log INFO "当前 Chrome $local → 目标 $latest"
    } else {
        Send-Log INFO "未检测到本地 Chrome，开始全新构建（目标 $latest）"
    }

    # 准备临时目录，备份用户配置
    Remove-TempDir
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $iniBackup = $null
    $appIni = Join-Path $script:AppDir 'chrome++.ini'
    if (Test-Path -LiteralPath $appIni) {
        $iniBackup = Join-Path $script:TempDir 'chrome++.ini.bak'
        Copy-Item -LiteralPath $appIni -Destination $iniBackup -Force
        Send-Log INFO '已备份 App\chrome++.ini（更新完成后自动恢复）'
    }

    # 下载离线安装包
    $installer = Join-Path $script:TempDir 'ChromeStandaloneSetup64.exe'
    Send-Log STEP '正在下载 Chrome 离线安装包（约 160MB，请耐心等待）…'
        $size = Invoke-Download -Url $script:ChromeDownloadUrl -Dest $installer -MinBytes 50MB -Label '正在下载 ChromeStandaloneSetup64.exe'
        Send-Log OK ("已下载 ChromeStandaloneSetup64.exe（{0}）" -f (Format-FileSize $size))
    Test-Cancelled

    # 解压链路：安装包 → updater.7z → chrome_installer.exe → chrome.7z → Chrome-bin
    $stage = Join-Path $script:TempDir 'App_new'
    $r = Invoke-ToolProcess $script:SevenZip @('x', $installer, ("-o" + $script:TempDir), '-y') '7-Zip 解压 ChromeStandaloneSetup64.exe'
    if ($r -gt 1) { throw '解压 ChromeStandaloneSetup64.exe 失败' }
    Test-Cancelled

    $updater7z = Get-ChildItem -LiteralPath $script:TempDir -Filter 'updater.7z' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $updater7z) { throw '解压后未找到 updater.7z' }
    $r = Invoke-ToolProcess $script:SevenZip @('x', $updater7z.FullName, ("-o" + $script:TempDir), '-y') '7-Zip 解压 updater.7z'
    if ($r -gt 1) { throw '解压 updater.7z 失败' }
    Test-Cancelled

    $chromeInstaller = Get-ChildItem -LiteralPath $script:TempDir -Recurse -Filter '*chrome_installer.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$stage*" } | Select-Object -First 1
    if (-not $chromeInstaller) { throw '未找到 chrome_installer.exe' }
    $r = Invoke-ToolProcess $script:SevenZip @('x', $chromeInstaller.FullName, ("-o" + $script:TempDir), '-y') '7-Zip 解压 chrome_installer.exe'
    if ($r -gt 1) { throw '解压 chrome_installer.exe 失败' }
    Test-Cancelled

    $chrome7z = Get-ChildItem -LiteralPath $script:TempDir -Recurse -Filter 'chrome.7z' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$stage*" } | Select-Object -First 1
    if (-not $chrome7z) { throw '未找到 chrome.7z' }
    $r = Invoke-ToolProcess $script:SevenZip @('x', $chrome7z.FullName, ("-o" + $script:TempDir), '-y') '7-Zip 解压 chrome.7z'
    if ($r -gt 1) { throw '解压 chrome.7z 失败' }
    Test-Cancelled

    $chromeBin = Get-ChildItem -LiteralPath $script:TempDir -Recurse -Directory -Filter 'Chrome-bin' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$stage*" } | Select-Object -First 1
    if (-not $chromeBin) { throw '未找到 Chrome-bin 目录' }

    # 组装新的 App（先在临时目录中构建，成功后再整体替换，避免更新失败破坏现有 App）
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -Path (Join-Path $chromeBin.FullName '*') -Destination $stage -Recurse -Force
    $stageChrome = Join-Path $stage 'chrome.exe'
    if (-not (Test-Path -LiteralPath $stageChrome)) { throw '构建结果缺少 chrome.exe' }
    Send-Log OK 'Chrome 主体文件已就绪'
    Test-Cancelled

    # 注入 version-x64.dll 并补齐插件文件
    $r = Invoke-ToolProcess $script:SetDll @('/d:version-x64.dll', $stageChrome) 'setdll 注入 version-x64.dll'
    if ($r -gt 1) { throw '注入 version-x64.dll 失败' }
    Copy-Item -LiteralPath $script:VersionDll -Destination (Join-Path $stage 'version-x64.dll') -Force
    Copy-Item -LiteralPath $script:DefaultIni -Destination (Join-Path $stage 'chrome++.ini') -Force
    if ($iniBackup -and (Test-Path -LiteralPath $iniBackup)) {
        Copy-Item -LiteralPath $iniBackup -Destination (Join-Path $stage 'chrome++.ini') -Force
        Send-Log OK '已恢复用户 chrome++.ini 配置'
    }
    Remove-Item -LiteralPath (Join-Path $stage 'chrome.exe~') -Force -ErrorAction SilentlyContinue
    Test-Cancelled

    # 原子替换 App
    if (Test-Path -LiteralPath $script:AppDir) {
        $old = Join-Path $script:BaseDir 'App_old'
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        Move-Item -LiteralPath $script:AppDir -Destination $old
        try {
            Move-Item -LiteralPath $stage -Destination $script:AppDir
            Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            if (Test-Path -LiteralPath $old -and -not (Test-Path -LiteralPath $script:AppDir)) {
                try { Move-Item -LiteralPath $old -Destination $script:AppDir } catch { }
            }
            throw
        }
    } else {
        Move-Item -LiteralPath $stage -Destination $script:AppDir
    }

    $script:ChromeLocal = Get-ChromeLocalVersion
    Send-Log OK "Chrome 构建完成，当前版本 $($script:ChromeLocal)"
    return $true
}

function Invoke-ChromePlusUpdate {
    param([bool]$Force = $false)

    Test-Cancelled
    if (-not (Repair-ToolFiles)) {
        throw 'Tool 工具完整性检查失败，无法继续'
    }
    if (-not $script:PlusRelease) {
        $script:PlusRelease = Get-LatestChromePlusVersion
    }
    $latest = $script:PlusRelease.Version
    $local = Get-ChromePlusLocalVersion
    if (-not $Force -and $local -and (Compare-Version $latest $local) -le 0) {
    Send-Log OK "Chrome++ Next 已是最新版本 $local，无需更新"
        return $false
    }
    if ($local) {
    Send-Log INFO "当前 Chrome++ Next $local → 目标 $latest"
    } else {
        Send-Log INFO "本地未检测到 version-x64.dll，开始全新安装（目标 $latest）"
    }

    Remove-TempDir
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $pkg = Join-Path $script:TempDir 'setdll.7z'
    Send-Log STEP '正在下载 setdll.7z…'
        $size = Invoke-Download -Url $script:PlusRelease.AssetUrl -Dest $pkg -MinBytes 10KB -Label '正在下载 setdll.7z'
        Send-Log OK ("已下载 setdll.7z（{0}）" -f (Format-FileSize $size))
    Test-Cancelled

    $extractDir = Join-Path $script:TempDir 'setdll_new'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    $r = Invoke-ToolProcess $script:SevenZip @('x', $pkg, ("-o" + $extractDir), '-y') '7-Zip 解压 setdll.7z'
    if ($r -gt 1) { throw '解压 setdll.7z 失败' }
    $newDll = Join-Path $extractDir 'version-x64.dll'
    if (-not (Test-Path -LiteralPath $newDll)) { throw 'setdll.7z 内容缺少 version-x64.dll，包结构异常' }
    Test-Cancelled

    # 更新 Tool 目录（setdll / version DLL / chrome++.ini 默认配置）
    Copy-Item -Path (Join-Path $extractDir '*') -Destination $script:ToolDir -Recurse -Force
    Send-Log OK 'Tool\chrome_plus 目录中的 setdll、version DLL、chrome++.ini 已更新'

    # 同步 App 中的插件文件（注意：不覆盖 App\chrome++.ini 用户配置）
    if (Test-Path -LiteralPath $script:AppDir) {
        Copy-Item -LiteralPath $newDll -Destination (Join-Path $script:AppDir 'version-x64.dll') -Force
        Send-Log OK 'App\version-x64.dll 已同步为最新版本'
    }

    $script:PlusLocal = $latest
    Send-Log OK "Chrome++ Next 已更新到 $latest"
    return $true
}

function Invoke-OneClickUpdate {
    $modeLabel = if (Get-ChromeLocalVersion) { '一键更新' } else { '一键构建' }
    Send-Log STEP '先检查最新版本，再按需构建 / 更新'
    Invoke-CheckUpdates
    Test-Cancelled

    $localChrome = Get-ChromeLocalVersion
    $localPlus = Get-ChromePlusLocalVersion
    $chromeNeeds = $false
    if (-not $localChrome) { $chromeNeeds = [bool]$script:ChromeLatest }
    elseif ($script:ChromeLatest) { $chromeNeeds = (Compare-Version $script:ChromeLatest $localChrome) -gt 0 }
    $plusNeeds = $false
    if (-not $localPlus) { $plusNeeds = [bool]$script:PlusLatest }
    elseif ($script:PlusLatest) { $plusNeeds = (Compare-Version $script:PlusLatest $localPlus) -gt 0 }

    if (-not $chromeNeeds -and -not $plusNeeds) {
    Send-Log OK 'Chrome 与 Chrome++ Next 都已是最新版本，无需更新'
        return $false
    }
    if ($chromeNeeds) {
        if (-not $localChrome) {
            Send-Log STEP 'Chrome 未安装，将进行全新构建'
        } else {
            Send-Log STEP "发现新版 Chrome（$($script:ChromeLatest)），开始更新"
        }
        [void](Invoke-ChromeUpdate -Force $false)
    }
    Test-Cancelled
    if ($plusNeeds) {
        if (-not $localPlus) {
        Send-Log STEP 'Chrome++ Next 未安装，将全新安装'
        } else {
            Send-Log STEP "发现新版 Chrome++ Next（$($script:PlusLatest)），开始更新"
        }
        [void](Invoke-ChromePlusUpdate -Force $false)
    }
    Send-Versions
    Send-Log OK "$modeLabel 完成"
    return $true
}

# ---------------------------------------------------------------------
# GUI 部分
# ---------------------------------------------------------------------

function Add-Control {
    param($Parent, $Control)
    $Parent.Controls.Add($Control)
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 0,
        [int]$Height = 0,
        [string]$ColorHex = '#202124',
        [System.Drawing.Font]$Font,
        [bool]$AutoSize = $false
    )
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point([int]($X * $script:UIScale), [int]($Y * $script:UIScale))
    $l.ForeColor = Get-Color $ColorHex
    $l.AutoSize = $AutoSize
    if ($Width -gt 0) { $l.Width = [int]($Width * $script:UIScale) }
    if ($Height -gt 0) { $l.Height = [int]($Height * $script:UIScale) }
    if ($Font) { $l.Font = $Font }
    return $l
}

function New-StyledButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [string]$BackColorHex,
        [string]$HoverColorHex,
        [string]$ForeColorHex = '#FFFFFF'
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point([int]($X * $script:UIScale), [int]($Y * $script:UIScale))
    $btn.Size = New-Object System.Drawing.Size([int]($Width * $script:UIScale), [int](36 * $script:UIScale))
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = Get-Color $BackColorHex
    $btn.ForeColor = Get-Color $ForeColorHex
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $btn.UseVisualStyleBackColor = $false
    # 颜色存入 Tag，事件处理脚本块从 $this.Tag 读取，
    # 避免引用函数局部变量（函数返回后作用域销毁，会解析为 $null）
    $btn.Tag = @{ Bc = Get-Color $BackColorHex; Hc = Get-Color $HoverColorHex }
    $btn.Add_MouseEnter({ $this.BackColor = $this.Tag.Hc })
    $btn.Add_MouseLeave({ $this.BackColor = $this.Tag.Bc })
    return $btn
}

function Set-StatusChip {
    param($Chip, [string]$Text, [string]$FgHex, [string]$BgHex)
    $Chip.Text = "  $Text  "
    $Chip.ForeColor = Get-Color $FgHex
    $Chip.BackColor = Get-Color $BgHex
}

function Add-LogLine {
    param([string]$Level, [string]$Text)
    $color = switch ($Level) {
        'STEP' { Get-Color '#1A73E8' }
        'OK'   { Get-Color '#188038' }
        'WARN' { Get-Color '#E37400' }
        'ERR'  { Get-Color '#D93025' }
        default { Get-Color '#3C4043' }
    }
    $bold = $Level -in @('STEP', 'ERR')
    $logBox = $script:LogBox
    $useFont = if ($bold) {
        New-Object System.Drawing.Font($logBox.Font.FontFamily, $logBox.Font.Size, [System.Drawing.FontStyle]::Bold)
    } else { $logBox.Font }
    $tag = switch ($Level) {
        'STEP' { '步骤' }
        'OK'   { '完成' }
        'WARN' { '警告' }
        'ERR'  { '错误' }
        default { '信息' }
    }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$stamp] [$tag] $Text`r`n"
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionColor = $color
    $logBox.SelectionFont = $useFont
    $logBox.AppendText($line)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Refresh-VersionPanel {
    $script:ChromeLocal = Get-ChromeLocalVersion
    $script:PlusLocal = Get-ChromePlusLocalVersion

    # 根据是否已安装 Chrome，动态调整“一键更新 / 一键构建”按钮文案
    if ($script:BtnOneClick) {
        $script:BtnOneClick.Text = if ($script:ChromeLocal) { '一键更新' } else { '一键构建' }
    }

    $script:LblChromeLocal.Text = if ($script:ChromeLocal) { $script:ChromeLocal } else { '未安装' }
    $script:LblChromeLatest.Text = if ($script:ChromeLatest) { $script:ChromeLatest } else { '—' }
    $script:LblPlusLocal.Text = if ($script:PlusLocal) { $script:PlusLocal } else { '未安装' }
    $script:LblPlusLatest.Text = if ($script:PlusLatest) { $script:PlusLatest } else { '—' }

    # Chrome 状态徽标
    if (-not $script:ChromeLocal) {
        if ($script:ChromeLatest) { Set-StatusChip $script:ChipChrome '可全新构建' '#E37400' '#FEF7E0' }
        else { Set-StatusChip $script:ChipChrome '未安装' '#5F6368' '#F1F3F4' }
    } elseif (-not $script:ChromeLatest) {
        Set-StatusChip $script:ChipChrome '状态未知' '#5F6368' '#F1F3F4'
    } elseif ((Compare-Version $script:ChromeLatest $script:ChromeLocal) -gt 0) {
        Set-StatusChip $script:ChipChrome '有新版本' '#E37400' '#FEF7E0'
    } else {
        Set-StatusChip $script:ChipChrome '已是最新' '#137333' '#E6F4EA'
    }

    # Chrome++ 状态徽标
    if (-not $script:PlusLocal) {
        if ($script:PlusLatest) { Set-StatusChip $script:ChipPlus '可全新安装' '#E37400' '#FEF7E0' }
        else { Set-StatusChip $script:ChipPlus '未安装' '#5F6368' '#F1F3F4' }
    } elseif (-not $script:PlusLatest) {
        Set-StatusChip $script:ChipPlus '状态未知' '#5F6368' '#F1F3F4'
    } elseif ((Compare-Version $script:PlusLatest $script:PlusLocal) -gt 0) {
        Set-StatusChip $script:ChipPlus '有新版本' '#E37400' '#FEF7E0'
    } else {
        Set-StatusChip $script:ChipPlus '已是最新' '#137333' '#E6F4EA'
    }
}

function Set-UiBusy {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    foreach ($b in $script:ActionButtons) { $b.Enabled = -not $Busy }
    $script:BtnCancel.Visible = $Busy
    $script:Progress.Visible = $Busy
    if ($Busy) {
        $script:Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $script:Progress.MarqueeAnimationSpeed = 22
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    } else {
        $script:Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $script:Progress.MarqueeAnimationSpeed = 0
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Invoke-WorkerEntry {
    # 在后台 runspace 中执行的入口（与界面 runspace 完全隔离）
    param([string]$Mode)
    try {
        switch ($Mode) {
            'check'    { Invoke-CheckUpdates }
            'chrome'   { Invoke-ChromeUpdate -Force $true }
            'plus'     { Invoke-ChromePlusUpdate -Force $true }
            'oneclick' { Invoke-OneClickUpdate }
            'repair'   { [void](Repair-ToolFiles) }
        }
        # 成功后清理临时目录
        Remove-TempDir
    } catch {
        Send-Log ERR ('操作失败：' + $_.Exception.Message)
        if (Test-Path -LiteralPath $script:TempDir) {
        Send-Log WARN "临时文件已保留在 $($script:TempDir)，便于排查"
        }
    }
}

function New-WorkerRunspace {
    # 创建专用后台 runspace，并把整个脚本作为“worker 模式”加载进去，
    # 使其拥有与界面一致的函数定义与配置，同时通过 $script:Shared 与界面通信。
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Shared', $script:Shared)
    $rs.SessionStateProxy.SetVariable('WorkerBaseDir', $script:BaseDir)
    $init = [System.Management.Automation.PowerShell]::Create()
    $init.Runspace = $rs
    try {
        $text = [System.IO.File]::ReadAllText($script:ScriptPath, [System.Text.Encoding]::UTF8)
        # #Requires 只在脚本文件中合法，加载为字符串前先移除
        $text = $text -replace '(?m)^\s*#Requires[^\r\n]*\r?\n', ''
        # param 块同样只在脚本文件顶层合法，作为字符串执行前先移除
        $text = $text -replace '(?ms)^param\(.*?^\)\s*', ''
        $bootstrap = "`$script:WorkerMode = `$true`n" + $text
        $null = $init.AddScript($bootstrap).Invoke()
        if ($init.HadErrors) {
            $err = $init.Streams.Error | Select-Object -First 1
            throw "后台运行空间初始化失败：$err"
        }
    } finally {
        $init.Dispose()
    }
    $script:WorkerRunspace = $rs
}

function Start-Worker {
    param([string]$Mode)
    if ($script:IsBusy) { return }
    try {
        if (-not $script:WorkerRunspace) { New-WorkerRunspace }
        $script:Shared.Cancel = $false
        Set-UiBusy $true

        $modeName = switch ($Mode) {
            'check'    { '检查更新' }
        'chrome'   { '更新 Chrome' }
            'plus'     { '更新 Chrome++ Next' }
        'oneclick' { if ($script:ChromeLocal) { '一键更新' } else { '一键构建' } }
        'repair'   { '恢复工具文件' }
        default    { $Mode }
    }
    Send-Section $modeName
    Send-Status "正在「$modeName」…"

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $script:WorkerRunspace
        [void]$ps.AddScript("Invoke-WorkerEntry -Mode '$Mode'")
        $script:WorkerPowerShell = $ps
        $script:WorkerHandle = $ps.BeginInvoke()
    } catch {
        Send-Log ERR ('无法启动后台任务：' + $_.Exception.Message)
        Set-UiBusy $false
        $script:StatusLabel.Text = '就绪'
    }
}

function Start-Gui {
    param([int]$AutoCloseMs = 0)

    # 计算界面缩放比例（按系统 DPI，仅在进程为 DPI 感知时生效；
    # DPI 感知下字体按点渲染会自动随 DPI 放大，这里同步放大控件坐标与尺寸）
    $script:UIScale = 1.0
    try {
        Add-Type -Name DpiHelper -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
[DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr hprocess, out int awareness);
'@ -ErrorAction SilentlyContinue
        $aware = 0
        [void][Win32.DpiHelper]::GetProcessDpiAwareness([IntPtr]::Zero, [ref]$aware)
        if ($aware -gt 0) {
            $dpi = [Win32.DpiHelper]::GetDpiForSystem()
            if ($dpi -gt 0) { $script:UIScale = $dpi / 96.0 }
        }
    } catch { $script:UIScale = 1.0 }

    # 控制台窗口已在脚本顶部隐藏，这里兜底再隐藏一次（类型已定义）
    try {
        $hwnd = [Win32.NativeWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [void][Win32.NativeWin]::ShowWindow($hwnd, 0) }
    } catch { }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Chrome 便携版更新器'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size([int](860 * $script:UIScale), [int](690 * $script:UIScale))
    $form.MinimumSize = New-Object System.Drawing.Size([int](820 * $script:UIScale), [int](630 * $script:UIScale))
    $form.BackColor = Get-Color '#F4F6F8'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    # 界面按固定布局设计，禁用窗口缩放
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false

    # ---------- 顶部标题栏 ----------
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = [int](78 * $script:UIScale)
    $header.BackColor = Get-Color '#2C5FD9'
    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15.75, [System.Drawing.FontStyle]::Bold)
    $titleLabel = New-Label -Text 'Chrome 便携版更新器' -X 18 -Y 9 -ColorHex '#FFFFFF' -Font $titleFont -AutoSize $true
    $subFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $subLabel = New-Label -Text '基于 Chrome++ Next · Chrome 便携版 构建 / 更新工具' -X 20 -Y 48 -ColorHex '#CFE0FF' -Font $subFont -AutoSize $true
    Add-Control $header $titleLabel
    Add-Control $header $subLabel
    Add-Control $form $header

    # ---------- 版本信息面板 ----------
    $groupFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $hintFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $verFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $chipFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)

    $chromeGroup = New-Object System.Windows.Forms.GroupBox
    $chromeGroup.Text = 'Google Chrome 浏览器'
    $chromeGroup.Font = $groupFont
    $chromeGroup.Location = New-Object System.Drawing.Point([int](12 * $script:UIScale), [int](90 * $script:UIScale))
    $chromeGroup.Size = New-Object System.Drawing.Size([int](410 * $script:UIScale), [int](128 * $script:UIScale))
    $chromeGroup.BackColor = [System.Drawing.Color]::White

    $lblChromeLocal = $null
    $lblChromeLatest = $null
    $chipChrome = $null
    Add-Control $chromeGroup (New-Label -Text '本地版本：' -X 18 -Y 31 -Width 84 -Height 20 -ColorHex '#5F6368' -Font $hintFont)
    $lblChromeLocal = New-Label -Text '未安装' -X 104 -Y 26 -Width 270 -Height 30 -ColorHex '#202124' -Font $verFont
    Add-Control $chromeGroup $lblChromeLocal
    Add-Control $chromeGroup (New-Label -Text '最新版本：' -X 18 -Y 61 -Width 84 -Height 20 -ColorHex '#5F6368' -Font $hintFont)
    $lblChromeLatest = New-Label -Text '—' -X 104 -Y 56 -Width 270 -Height 30 -ColorHex '#202124' -Font $verFont
    Add-Control $chromeGroup $lblChromeLatest
    $chipChrome = New-Label -Text ' 状态未知 ' -X 18 -Y 92 -ColorHex '#5F6368' -Font $chipFont -AutoSize $true
    $chipChrome.BackColor = Get-Color '#F1F3F4'
    $chipChrome.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    Add-Control $chromeGroup $chipChrome
    Add-Control $form $chromeGroup
    $script:LblChromeLocal = $lblChromeLocal
    $script:LblChromeLatest = $lblChromeLatest
    $script:ChipChrome = $chipChrome

    $plusGroup = New-Object System.Windows.Forms.GroupBox
    $plusGroup.Text = 'Chrome++ Next'
    $plusGroup.Font = $groupFont
    $plusGroup.Location = New-Object System.Drawing.Point([int](438 * $script:UIScale), [int](90 * $script:UIScale))
    $plusGroup.Size = New-Object System.Drawing.Size([int](410 * $script:UIScale), [int](128 * $script:UIScale))
    $plusGroup.BackColor = [System.Drawing.Color]::White

    $lblPlusLocal = $null
    $lblPlusLatest = $null
    $chipPlus = $null
    Add-Control $plusGroup (New-Label -Text '本地版本：' -X 18 -Y 31 -Width 84 -Height 20 -ColorHex '#5F6368' -Font $hintFont)
    $lblPlusLocal = New-Label -Text '未安装' -X 104 -Y 26 -Width 270 -Height 30 -ColorHex '#202124' -Font $verFont
    Add-Control $plusGroup $lblPlusLocal
    Add-Control $plusGroup (New-Label -Text '最新版本：' -X 18 -Y 61 -Width 84 -Height 20 -ColorHex '#5F6368' -Font $hintFont)
    $lblPlusLatest = New-Label -Text '—' -X 104 -Y 56 -Width 270 -Height 30 -ColorHex '#202124' -Font $verFont
    Add-Control $plusGroup $lblPlusLatest
    $chipPlus = New-Label -Text ' 状态未知 ' -X 18 -Y 92 -ColorHex '#5F6368' -Font $chipFont -AutoSize $true
    $chipPlus.BackColor = Get-Color '#F1F3F4'
    $chipPlus.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    Add-Control $plusGroup $chipPlus
    Add-Control $form $plusGroup
    $script:LblPlusLocal = $lblPlusLocal
    $script:LblPlusLatest = $lblPlusLatest
    $script:ChipPlus = $chipPlus

    # ---------- 操作按钮 ----------
    $btnCheck = New-StyledButton -Text '检查更新' -X 12 -Y 232 -Width 100 -BackColorHex '#2C5FD9' -HoverColorHex '#1B4BB8'
    $btnOneClick = New-StyledButton -Text '一键更新' -X 116 -Y 232 -Width 100 -BackColorHex '#188038' -HoverColorHex '#136F30'
    $btnChrome = New-StyledButton -Text '更新 Chrome' -X 222 -Y 232 -Width 128 -BackColorHex '#1A73E8' -HoverColorHex '#135FC4'
    $btnPlus = New-StyledButton -Text '更新 Chrome++ Next' -X 356 -Y 232 -Width 168 -BackColorHex '#9334E6' -HoverColorHex '#7A29C4'
    $btnRun = New-StyledButton -Text '启动浏览器' -X 530 -Y 232 -Width 98 -BackColorHex '#5F6368' -HoverColorHex '#4A4E53'
    $btnOpen = New-StyledButton -Text '打开目录' -X 634 -Y 232 -Width 100 -BackColorHex '#5F6368' -HoverColorHex '#4A4E53'
    $btnIni = New-StyledButton -Text '编辑配置' -X 740 -Y 232 -Width 108 -BackColorHex '#7F8C8D' -HoverColorHex '#657374'

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    # 取消按钮放在进度条右侧、与按钮行右缘对齐（仅在操作中与进度条一起出现）
    $btnCancel.Location = New-Object System.Drawing.Point([int](748 * $script:UIScale), [int](278 * $script:UIScale))
    $btnCancel.Size = New-Object System.Drawing.Size([int](100 * $script:UIScale), [int](32 * $script:UIScale))
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.FlatAppearance.BorderColor = Get-Color '#D93025'
    $btnCancel.BackColor = [System.Drawing.Color]::White
    $btnCancel.ForeColor = Get-Color '#D93025'
    $btnCancel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Visible = $false
    $btnCancel.Add_Click({
        $script:Shared.Cancel = $true
        try { if ($script:Shared.CurrentProcess) { $script:Shared.CurrentProcess.Kill() } } catch { }
        Send-Log WARN '已请求取消，正在停止当前操作…'
    })

    foreach ($b in @($btnCheck, $btnOneClick, $btnChrome, $btnPlus, $btnRun, $btnOpen, $btnIni, $btnCancel)) {
        Add-Control $form $b
    }
    $script:ActionButtons = @($btnCheck, $btnOneClick, $btnChrome, $btnPlus, $btnRun, $btnOpen, $btnIni)
    $script:BtnOneClick = $btnOneClick
    $script:BtnCancel = $btnCancel
    $script:Form = $form

    # ---------- 进度与状态 ----------
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point([int](12 * $script:UIScale), [int](286 * $script:UIScale))
    $progress.Size = New-Object System.Drawing.Size([int](724 * $script:UIScale), [int](16 * $script:UIScale))
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
    $progress.Visible = $false
    Add-Control $form $progress
    $script:Progress = $progress

    $statusLabel = New-Label -Text '就绪' -X 12 -Y 310 -Width 836 -ColorHex '#5F6368' -Font $hintFont
    Add-Control $form $statusLabel
    $script:StatusLabel = $statusLabel

    # ---------- 运行日志 ----------
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = '运行日志'
    $logGroup.Font = $groupFont
    $logGroup.Location = New-Object System.Drawing.Point([int](12 * $script:UIScale), [int](342 * $script:UIScale))
    # 日志区向下延伸至页脚上方，避免底部留白
    $logGroup.Size = New-Object System.Drawing.Size([int](836 * $script:UIScale), [int](300 * $script:UIScale))
    $logGroup.BackColor = [System.Drawing.Color]::White
    $logGroup.Padding = New-Object System.Windows.Forms.Padding([int](10 * $script:UIScale))
    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.ReadOnly = $true
    $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $logBox.BackColor = [System.Drawing.Color]::White
    $logBox.DetectUrls = $true
    $logBox.Add_LinkClicked({
        param($s, $e)
        try { [void][System.Diagnostics.Process]::Start($e.LinkText) } catch { }
    })
    Add-Control $logGroup $logBox
    Add-Control $form $logGroup
    $script:LogBox = $logBox

    # ---------- 底部信息 ----------
    $footerFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $footerLabel = New-Label -Text ('Chrome 便携版更新器 v1.0.0 · 目录：' + $script:BaseDir) -X 12 -Y 652 -Width 560 -ColorHex '#5F6368' -Font $footerFont
    Add-Control $form $footerLabel
    $linkLabel = New-Object System.Windows.Forms.LinkLabel
    $linkLabel.Text = 'Chrome++ Next 项目'
    $linkLabel.Location = New-Object System.Drawing.Point([int](706 * $script:UIScale), [int](652 * $script:UIScale))
    $linkLabel.AutoSize = $true
    $linkLabel.Font = $footerFont
    $linkLabel.LinkColor = Get-Color '#1A73E8'
    $linkLabel.Add_LinkClicked({
        param($s, $e)
        try { [void][System.Diagnostics.Process]::Start($script:ChromePlusReleaseUrl) } catch { }
    })
    Add-Control $form $linkLabel

    # ---------- 按钮事件 ----------
    $btnCheck.Add_Click({ Start-Worker 'check' })
    $btnRun.Add_Click({
        if (-not (Test-Path -LiteralPath $script:ChromeExe)) {
            [void][System.Windows.Forms.MessageBox]::Show('App 目录中没有 chrome.exe，请先构建或更新。', '提示',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        try { [void][System.Diagnostics.Process]::Start($script:ChromeExe) } catch {
            [void][System.Windows.Forms.MessageBox]::Show("启动失败：$($_.Exception.Message)", '错误',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $btnOpen.Add_Click({
        New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
        [void][System.Diagnostics.Process]::Start('explorer.exe', $script:AppDir)
    })
    $btnIni.Add_Click({
        $ini = Join-Path $script:AppDir 'chrome++.ini'
        if (-not (Test-Path -LiteralPath $ini)) { $ini = $script:DefaultIni }
        if (Test-Path -LiteralPath $ini) {
            [void][System.Diagnostics.Process]::Start('notepad.exe', $ini)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('未找到 chrome++.ini。', '提示',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })
    $btnChrome.Add_Click({
        $running = Get-RunningPortableChrome
        if ($running.Count -gt 0) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                '检测到便携版 Chrome 正在运行，更新前需要关闭它。是否立即关闭所有相关进程？',
                'Chrome 正在运行',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            foreach ($p in $running) { try { $p.Kill() } catch { } }
            Start-Sleep -Milliseconds 600
        }
        if ($script:ChromeLocal -and $script:ChromeLatest -and
            (Compare-Version $script:ChromeLatest $script:ChromeLocal) -le 0) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "当前 Chrome 已是最新版本 $($script:ChromeLocal)，仍要重新下载构建吗？",
                '确认操作',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Start-Worker 'chrome'
    })
    $btnPlus.Add_Click({
        if ($script:PlusLocal -and $script:PlusLatest -and
            (Compare-Version $script:PlusLatest $script:PlusLocal) -le 0) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "当前 Chrome++ Next 已是最新版本 $($script:PlusLocal)，仍要重新下载更新吗？",
                '确认操作',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Start-Worker 'plus'
    })
    $btnOneClick.Add_Click({
        if ($script:ChromeLocal -and $script:ChromeLatest -and
            $script:PlusLocal -and $script:PlusLatest -and
            (Compare-Version $script:ChromeLatest $script:ChromeLocal) -le 0 -and
            (Compare-Version $script:PlusLatest $script:PlusLocal) -le 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Chrome 与 Chrome++ Next 都已是最新版本。', '提示',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $running = Get-RunningPortableChrome
        if ($running.Count -gt 0) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                '检测到便携版 Chrome 正在运行，更新前需要关闭它。是否立即关闭所有相关进程？',
                'Chrome 正在运行',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            foreach ($p in $running) { try { $p.Kill() } catch { } }
            Start-Sleep -Milliseconds 600
        }
        Start-Worker 'oneclick'
    })

    # ---------- 定时器：将 worker 队列消息同步到 UI ----------
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        try {
            # 若以隐藏方式启动（wscript 以 SW_HIDE 启动，避免终端窗口），在消息循环启动后强制显示主窗口
            if (-not $script:ForceShown) {
                $script:ForceShown = $true
                if (-not $script:Form.Visible) {
                    $null = $script:Form.Handle
                    [void][Win32.NativeWin]::ShowWindow($script:Form.Handle, 5)   # SW_SHOW
                }
            }
            while (-not $script:Shared.LogQueue.IsEmpty) {
                $item = $null
                if ($script:Shared.LogQueue.TryDequeue([ref]$item)) {
                    switch ($item.L) {
                        'STATUS' {
                            $script:StatusLabel.Text = $item.T
                        }
                        'PROGRESS' {
                            # 下载进度：切换到确定百分比进度条并更新数值
                            $script:Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                            $script:Progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$item.T))
                            $script:Progress.Visible = $true
                        }
                        'PROGRESS_RESET' {
                            # 下载结束：恢复为不确定（Marquee）进度条
                            if ($script:IsBusy) {
                                $script:Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
                                $script:Progress.MarqueeAnimationSpeed = 22
                            }
                        }
                        'VERSIONS' {
                            $script:ChromeLatest = $item.T.ChromeLatest
                            $script:PlusLatest = $item.T.PlusLatest
                            $script:PlusRelease = $item.T.PlusRelease
                            Refresh-VersionPanel
                        }
                        default { Add-LogLine $item.L $item.T }
                    }
                }
            }
            if ($script:WorkerHandle -and $script:WorkerHandle.IsCompleted) {
                try {
                    $null = $script:WorkerPowerShell.EndInvoke($script:WorkerHandle)
                } catch {
                    Add-LogLine 'ERR' ('后台任务异常：' + $_.Exception.Message)
                }
                $script:WorkerPowerShell.Dispose()
                $script:WorkerPowerShell = $null
                $script:WorkerHandle = $null
                Set-UiBusy $false
                $script:StatusLabel.Text = '就绪'
                # 后台任务完成后重新读取本地版本并刷新面板（如自动恢复工具文件后刷新 Chrome++ 版本）
                Refresh-VersionPanel
            }
        } catch {
            try {
                [void][System.Windows.Forms.MessageBox]::Show('界面更新出错：' + $_.Exception.Message, '错误',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            } catch { }
        }
    })
    $timer.Start()

    # ---------- 关闭保护 ----------
    $form.Add_FormClosing({
        param($s, $e)
        if ($script:IsBusy) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                '正在执行操作，确定要取消并退出吗？', '确认退出',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                $script:Shared.Cancel = $true
                try { if ($script:Shared.CurrentProcess) { $script:Shared.CurrentProcess.Kill() } } catch { }
            } else {
                $e.Cancel = $true
            }
        }
    })

    # ---------- 启动画面 ----------
    $form.Add_Shown({
        Refresh-VersionPanel
        Add-LogLine 'INFO' "目录：$($script:BaseDir)"
        Add-LogLine 'INFO' ("本地 Chrome：{0}" -f $(if ($script:ChromeLocal) { $script:ChromeLocal } else { '未安装' }))
        Add-LogLine 'INFO' ("本地 Chrome++ Next：{0}" -f $(if ($script:PlusLocal) { $script:PlusLocal } else { '未安装' }))
        $needRepair = $false
        $zipToolOk = ((Test-Path -LiteralPath $script:SevenZipFull) -and (Test-Path -LiteralPath $script:SevenZipDll)) -or
            (Test-Path -LiteralPath $script:SevenZip)
        if (-not $zipToolOk) {
            Add-LogLine 'WARN' '缺少 7-Zip 命令行工具（7z/7za），正在自动从 ip7z/7zip release 获取…'
            $needRepair = $true
        }
        foreach ($t in @(
                @($script:WgetExe, 'wget.exe', 'eternallybored.org'),
                @($script:SetDll, 'setdll-x64.exe', 'Chrome++ Next release'),
                @($script:VersionDll, 'version-x64.dll', 'Chrome++ Next release'),
                @($script:DefaultIni, 'chrome++.ini', 'Chrome++ Next release'))) {
            if (-not (Test-Path -LiteralPath $t[0])) {
                Add-LogLine 'WARN' "Tool 目录缺少 $($t[1])，正在自动从 $($t[2]) 恢复…"
                $needRepair = $true
            }
        }
        if ($needRepair) {
            Start-Worker 'repair'
        }
        Add-LogLine 'INFO' '点击「检查更新」查询最新版本，或直接点击「一键更新 / 一键构建」。'
    })

    if ($AutoCloseMs -gt 0) {
        $closeTimer = New-Object System.Windows.Forms.Timer
        $closeTimer.Interval = $AutoCloseMs
        $closeTimer.Add_Tick({
            $this.Stop()
            $script:Form.Close()
        })
        $closeTimer.Start()
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    # 捕获 UI 线程未处理异常，弹出友好提示而不是 JIT 调试框
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::Add_ThreadException({
            param($s, $e)
            try {
                [void][System.Windows.Forms.MessageBox]::Show('界面出现未处理的错误：' + $e.Exception.Message, '错误',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            } catch { }
        })
    } catch { }
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------
# 测试模式
# ---------------------------------------------------------------------

function Invoke-TestMode {
    Write-Host '== Chrome 便携版更新器 · 测试模式 ==' -ForegroundColor Cyan
    $script:ChromeLocal = Get-ChromeLocalVersion
    $script:PlusLocal = Get-ChromePlusLocalVersion
    Write-Host ("本地 Chrome   : {0}" -f $(if ($script:ChromeLocal) { $script:ChromeLocal } else { '未安装' }))
    Write-Host ("本地 Chrome++ Next：{0}" -f $(if ($script:PlusLocal) { $script:PlusLocal } else { '未安装' }))
    try {
        $script:ChromeLatest = Get-LatestChromeVersion
        Write-Host ("最新 Chrome   : {0}" -f $script:ChromeLatest) -ForegroundColor Green
    } catch {
        Write-Host ("最新 Chrome   : 检查失败 - {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    try {
        $script:PlusRelease = Get-LatestChromePlusVersion
        $script:PlusLatest = $script:PlusRelease.Version
        Write-Host ("最新 Chrome++ Next：{0}" -f $script:PlusLatest) -ForegroundColor Green
        Write-Host ("setdll.7z     : {0}" -f $script:PlusRelease.AssetUrl)
    } catch {
        Write-Host ("最新 Chrome++ Next：检查失败 - {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host '== 测试完成 ==' -ForegroundColor Cyan
}

# ---------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------
if ($script:WorkerMode) {
    # 后台 runspace 模式：仅加载函数与配置定义，等待 Invoke-WorkerEntry 调用
    return
}
if ($Test) {
    Invoke-TestMode
    exit
}
if ($GuiSmoke) {
    Start-Gui -AutoCloseMs 2500
    exit
}
if ($MyInvocation.InvocationName -ne '.') {
    Start-Gui
}
