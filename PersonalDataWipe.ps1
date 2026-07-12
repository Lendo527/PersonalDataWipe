# ============================================
# PersonalDataWipe
# 适用系统：Windows 10 / Windows 11
# 用途：换电脑前彻底清除本机所有个人使用记录与凭证
# 模块按从简单到困难排序，统一执行并实时显示进度
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Continue"

# ========== 全局配置 ==========
$script:LogFile = "$env:USERPROFILE\Desktop\PersonalDataWipe_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ErrorRecords = @()
$script:Stats = @{ Deleted = 0; Failed = 0; Skipped = 0 }
$script:ModuleStats = @{}  # 每模块独立统计
$script:OpCounter = 0      # 全局操作计数器
$script:TestMode = $false  # 测试模式：只扫描不删除
$script:TranscriptActive = $false  # Start-Transcript 是否启动成功（影响末尾日志提示）

# 通过环境变量 WIPE_TEST_MODE=1 触发测试模式（绝对安全，不删除任何文件）
if ($env:WIPE_TEST_MODE -eq "1") {
    $script:TestMode = $true
    Write-Host "[TEST MODE ENABLED] 不会实际删除任何文件，仅扫描和报告" -ForegroundColor Magenta
} else {
    # 实际清理模式：检查管理员权限
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[ERROR] 实际清理模式需要管理员权限。请右键 PowerShell -> 以管理员身份运行" -ForegroundColor Red
        Write-Host "[HINT] 如需仅测试扫描（不删除），请设置环境变量：`$env:WIPE_TEST_MODE='1'" -ForegroundColor Yellow
        exit 1
    }
}

# Ctrl+C 中断时尽力关闭日志（注：ConsoleHost 会先拦截 Ctrl+C，CancelKeyPress 不一定触发，仅作为兜底）
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
} -SupportEvent
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
} -SupportEvent -ErrorAction SilentlyContinue

# ========== 辅助：错误收集 ==========
function Add-ErrorItem {
    param([string]$Stage, [string]$Message)
    $script:ErrorRecords += [PSCustomObject]@{
        Stage   = $Stage
        Message = $Message
        Time    = (Get-Date -Format "HH:mm:ss")
    }
}

# ========== 辅助：日志输出 ==========
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $color = switch ($Level) {
        "Info"    { "Gray" }
        "Step"    { "Yellow" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { "White" }
    }
    Write-Host $Message -ForegroundColor $color
}

# ========== 辅助：模块进度头 ==========
function Write-ModuleHeader {
    param([int]$Current, [int]$Total, [string]$Id, [string]$Name)
    $percent = if ($Total -gt 0) { [math]::Round($Current / $Total * 100) } else { 0 }
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  [$Current/$Total] $Id - $Name  ($percent%)" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

# ========== 辅助：进程关闭并等待 ==========
function Stop-ProcessAndWait {
    param(
        [string[]]$ProcessNames,
        [int]$TimeoutSeconds = 10,
        [int]$PollIntervalMs = 500
    )
    foreach ($name in $ProcessNames) {
        try { Stop-Process -Name $name -Force -ErrorAction SilentlyContinue } catch { }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $stillRunning = $false
        foreach ($name in $ProcessNames) {
            if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
                $stillRunning = $true; break
            }
        }
        if (-not $stillRunning) { return $true }
        Start-Sleep -Milliseconds $PollIntervalMs
    }
    return $false
}

# ========== 辅助：安全删除路径（带重试） ==========
function Remove-PathSafe {
    param(
        [string]$Path,
        [int]$Retries = 3,
        [string]$Stage = "Unknown"
    )
    # 空路径不递增 OpCounter，避免日志序号跳号
    if (-not $Path) {
        $script:Stats.Skipped++
        return $false
    }
    $script:OpCounter++
    $opId = "[#{0,4:D4}]" -f $script:OpCounter
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "  $opId [SKIP] 路径不存在: $Path" -Level "Info"
        $script:Stats.Skipped++
        return $false
    }
    # 测试模式：只报告不删除
    if ($script:TestMode) {
        Write-Log "  $opId [TEST][FOUND] $Path" -Level "Warning"
        $script:Stats.Deleted++
        return $true
    }
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Log "  $opId [DEL] $Path" -Level "Success"
            $script:Stats.Deleted++
            return $true
        } catch {
            if ($i -lt $Retries) {
                Start-Sleep -Milliseconds 500
            } else {
                Write-Log "  $opId [FAIL x$Retries] $Path - $($_.Exception.Message)" -Level "Error"
                Add-ErrorItem -Stage $Stage -Message "删除失败: $Path - $($_.Exception.Message)"
                $script:Stats.Failed++
                return $false
            }
        }
    }
    # 循环内每个分支都已 return，此处不可达，省略冗余 return
}

# ========== 辅助：清除注册表键 ==========
function Remove-RegistryKey {
    param([string]$Path, [string]$Stage = "Unknown")
    $script:OpCounter++
    $opId = "[#{0,4:D4}]" -f $script:OpCounter
    if (-not (Test-Path $Path)) {
        Write-Log "  $opId [SKIP] 注册表不存在: $Path" -Level "Info"
        $script:Stats.Skipped++
        return
    }
    if ($script:TestMode) {
        Write-Log "  $opId [TEST][REGFOUND] $Path" -Level "Warning"
        $script:Stats.Deleted++
        return
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "  $opId [REGDEL] $Path" -Level "Success"
        $script:Stats.Deleted++
    } catch {
        Write-Log "  $opId [REGFAIL] $Path - $($_.Exception.Message)" -Level "Error"
        Add-ErrorItem -Stage $Stage -Message "RegKey 失败: $Path"
        $script:Stats.Failed++
    }
}

# ========== 辅助：通配符删除（用于 ssfn* 等模式匹配）==========
function Remove-PathWildcard {
    param([string]$Pattern, [string]$Stage = "Unknown")
    $parent = Split-Path $Pattern -Parent
    $leaf = Split-Path $Pattern -Leaf
    if (-not (Test-Path -LiteralPath $parent)) {
        $script:OpCounter++
        $opId = "[#{0,4:D4}]" -f $script:OpCounter
        Write-Log "  $opId [SKIP] 父目录不存在: $parent" -Level "Info"
        $script:Stats.Skipped++
        return
    }
    $items = @(Get-ChildItem -LiteralPath $parent -Filter $leaf -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        $script:OpCounter++
        $opId = "[#{0,4:D4}]" -f $script:OpCounter
        Write-Log "  $opId [SKIP] 无匹配: $Pattern" -Level "Info"
        $script:Stats.Skipped++
        return
    }
    foreach ($item in $items) {
        Remove-PathSafe -Path $item.FullName -Stage $Stage
    }
}

# ========== 启动操作日志 ==========
try {
    Start-Transcript -Path $script:LogFile -Force -ErrorAction Stop | Out-Null
    $script:TranscriptActive = $true
} catch {
    Write-Log "日志启动失败（继续执行，但末尾不会输出日志路径）: $($_.Exception.Message)" -Level "Warning"
}

# ========== 主入口 ==========
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  PersonalDataWipe" -ForegroundColor Cyan
Write-Host "  作者: Lendo527  |  版本: v6.0  |  日期: 2026-07-02" -ForegroundColor Gray
if ($script:TestMode) {
    Write-Host "  [TEST MODE] 仅扫描，不实际删除" -ForegroundColor Magenta
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
if (-not $script:TestMode) {
    Write-Host "⚠️ 警告：本工具将彻底擦除本机所有个人使用记录与凭证" -ForegroundColor Red
    Write-Host "⚠️ 操作不可逆，请确认已备份所有需要保留的资料" -ForegroundColor Red
    Write-Host ""
}

# ========== 模块清单（按从简单到困难排序）==========
$modules = @(
    [PSCustomObject]@{ Id = "M01"; Name = "临时文件与缓存（Temp/ThumbCache）" }
    [PSCustomObject]@{ Id = "M02"; Name = "回收站清空" }
    [PSCustomObject]@{ Id = "M03"; Name = "系统使用痕迹（Recent/Jumplist/剪贴板）" }
    [PSCustomObject]@{ Id = "M04"; Name = "命令行历史与 PROFILE（PSReadLine/CMD）" }
    [PSCustomObject]@{ Id = "M05"; Name = "下载工具配置（IDM/迅雷/BT）" }
    [PSCustomObject]@{ Id = "M06"; Name = "截图与搜索工具历史（Snipaste/ShareX/Everything）" }
    [PSCustomObject]@{ Id = "M07"; Name = "浏览器数据（Edge/Chrome/Firefox 含密码）" }
    [PSCustomObject]@{ Id = "M08"; Name = "通讯软件（QQ/微信/Telegram/Discord/钉钉/飞书）" }
    [PSCustomObject]@{ Id = "M09"; Name = "邮件客户端（Thunderbird/Foxmail/网易邮箱大师）" }
    [PSCustomObject]@{ Id = "M10"; Name = "网盘客户端（百度/坚果云/Dropbox/阿里）" }
    [PSCustomObject]@{ Id = "M11"; Name = "远程会议与录屏（Zoom/Teams/腾讯会议/OBS）" }
    [PSCustomObject]@{ Id = "M12"; Name = "笔记与知识库（Obsidian/Notion/印象/为知）" }
    [PSCustomObject]@{ Id = "M13"; Name = "密码管理器（Sticky Password/1P/Bitwarden/KeePass）" }
    [PSCustomObject]@{ Id = "M14"; Name = "数据库工具（Navicat/DBeaver/SSMS/MySQL WB）" }
    [PSCustomObject]@{ Id = "M15"; Name = "远程连接（SSH/PuTTY/WinSCP/TeamViewer/FileZilla）" }
    [PSCustomObject]@{ Id = "M16"; Name = "游戏与创意软件（Unity/Steam/Epic/Adobe/Figma）" }
    [PSCustomObject]@{ Id = "M17"; Name = "网络隧道工具（OpenVPN/WG/Clash 等）" }
    [PSCustomObject]@{ Id = "M18"; Name = "版本控制凭证（Git/SVN/Mercurial）" }
    [PSCustomObject]@{ Id = "M19"; Name = "开发工具 token（VSCode/VS/Docker/Cloud/VM/Android/Rust/Helm/Terraform/Maven/Conda/Postman）" }
    [PSCustomObject]@{ Id = "M20"; Name = "微软账户+凭据管理器+DPAPI+系统日志（终极）" }
    [PSCustomObject]@{ Id = "M21"; Name = "WSL 发行版内个人数据（.ssh/.aws/git-credentials/history）" }
)

Write-Host "========== 清理步骤（共 $($modules.Count) 项，按从简单到困难顺序）==========" -ForegroundColor Cyan
for ($i = 0; $i -lt $modules.Count; $i++) {
    $num = "{0,2}" -f ($i + 1)
    Write-Host "  $num. $($modules[$i].Id) - $($modules[$i].Name)" -ForegroundColor White
}
Write-Host ""
Write-Host "📌 执行时会显示实时进度：[当前步/总步数] Mxx - 模块名 (XX%)" -ForegroundColor Cyan
Write-Host "📌 每个操作显示序号：[#0001] [DEL/TEST/SKIP] 路径" -ForegroundColor Cyan
Write-Host ""
if ($script:TestMode) {
    Write-Host "[TEST MODE] 跳过确认，直接开始扫描..." -ForegroundColor Magenta
    $confirm = "Y"
} else {
    $confirm = Read-Host "确认执行以上全部清理？(Y/N)"
}
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Log "已取消" -Level "Warning"
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
    pause
    exit
}

$selectedModules = $modules
$totalSteps = $selectedModules.Count

# ============================================================
# 模块函数定义（按从简单到困难排序）
# ============================================================

# ---------- M01: 临时文件与缓存 ----------
function Invoke-M01Temp {
    Write-Log "[M01] 清理临时文件与缓存..." "Step"
    # 清理 TEMP 与 INetCache 下的子项（Sort-Object -Unique 防止二者恰好相同时重复扫描）
    $tempPaths = @("$env:TEMP", "$env:LOCALAPPDATA\Microsoft\Windows\INetCache") | Sort-Object -Unique
    foreach ($tp in $tempPaths) {
        if (Test-Path $tp) {
            Get-ChildItem -LiteralPath $tp -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-PathSafe -Path $_.FullName -Stage "M01 Temp"
            }
        }
    }
    # 缩略图与图标缓存（实际为 Explorer 目录下的 thumbcache_*.db / iconcache_*.db 散落文件）
    Remove-PathWildcard -Pattern "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Stage "M01 Temp"
    Remove-PathWildcard -Pattern "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Stage "M01 Temp"
    Remove-PathSafe -Path "$env:LOCALAPPDATA\IconCache.db" -Stage "M01 Temp"
    Write-Log "[M01] 完成" "Success"
}

# ---------- M02: 回收站清空 ----------
function Invoke-M02RecycleBin {
    Write-Log "[M02] 清空回收站..." "Step"
    $shell = $null
    try {
        # 清空所有驱动器的回收站
        $shell = New-Object -ComObject Shell.Application
        $recycleBins = $shell.Namespace(0xA)
        if ($recycleBins) {
            $items = @($recycleBins.Items())
            foreach ($item in $items) {
                if ($script:TestMode) {
                    Write-Log "  [TEST] 回收站项: $($item.Name)" -Level "Warning"
                } else {
                    try {
                        Remove-Item -LiteralPath $item.Path -Recurse -Force -ErrorAction Stop
                    } catch {
                        Add-ErrorItem -Stage "M02 RecycleBin" -Message "COM 删除失败: $($item.Path) - $($_.Exception.Message)"
                    }
                }
            }
        }
        # 兜底：直接清空 $Recycle.Bin（跳过 desktop.ini 等系统保护文件）
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
            $rbPath = Join-Path $_.DeviceID '$Recycle.Bin'
            if (Test-Path $rbPath) {
                Get-ChildItem -LiteralPath $rbPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    # 跳过 desktop.ini 等系统文件
                    if ($_.Name -eq 'desktop.ini') { return }
                    Remove-PathSafe -Path $_.FullName -Stage "M02 RecycleBin"
                }
            }
        }
        if ($script:TestMode) {
            Write-Log "  回收站扫描完成（测试模式未实际删除）"
        } else {
            Write-Log "  回收站已清空"
        }
    } catch {
        Add-ErrorItem -Stage "M02" -Message $_.Exception.Message
    } finally {
        if ($shell) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { } }
    }
    Write-Log "[M02] 完成" "Success"
}

# ---------- M03: 系统使用痕迹 ----------
function Invoke-M03Traces {
    Write-Log "[M03] 清理系统使用痕迹..." "Step"
    # 资源管理器 Recent（AutomaticDestinations / CustomDestinations 为标准 Jumplist 子目录）
    @(
        "$env:APPDATA\Microsoft\Windows\Recent",
        "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations",
        "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M03 Recent" }
    # INetCache / History
    @(
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:LOCALAPPDATA\Microsoft\Windows\History"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M03 Cache" }
    # 剪贴板历史
    Remove-PathSafe -Path "$env:LOCALAPPDATA\Microsoft\Windows\Clipboard" -Stage "M03 Clipboard"
    if (-not $script:TestMode) {
        try { Set-Clipboard -Value "" -ErrorAction SilentlyContinue } catch { }
    } else {
        Write-Log "  [TEST] 将清空剪贴板" -Level "Warning"
    }
    # Office 最近文档
    @("16.0", "15.0") | ForEach-Object {
        Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Office\$_\Word\File MRU" -Stage "M03 Office"
        Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Office\$_\Excel\File MRU" -Stage "M03 Office"
        Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Office\$_\PowerPoint\File MRU" -Stage "M03 Office"
    }
    # 自动补全
    Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoComplete" -Stage "M03 AutoC"
    Write-Log "[M03] 完成" "Success"
}

# ---------- M04: 命令行历史与 PROFILE ----------
function Invoke-M04CmdHistory {
    Write-Log "[M04] 清理命令行历史与 PROFILE..." "Step"
    # PowerShell PSReadLine 历史（Windows PowerShell 5.1 与 PowerShell 7 路径不同，均需清理）
    Remove-PathSafe -Path "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Stage "M04 PSReadLine"
    Remove-PathSafe -Path "$env:APPDATA\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt" -Stage "M04 PSReadLine"
    Remove-PathSafe -Path "$env:APPDATA\Microsoft\PowerShell\PSReadLine\Visual Studio Code_host_history.txt" -Stage "M04 PSReadLine"
    # CMD 历史（注册表）
    Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Stage "M04 RunMRU"
    # Windows Terminal 配置（正式版与预览版统一删除整个 LocalState，含 settings.json 与 state.json 等会话痕迹）
    @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M04 WinTerm" }
    # Snip & Sketch
    Remove-PathSafe -Path "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\LocalState" -Stage "M04 SnipSketch"
    # PowerShell / Python PROFILE
    @(
        "$env:USERPROFILE\Documents\WindowsPowerShell\profile.ps1",
        "$env:USERPROFILE\Documents\PowerShell\profile.ps1",
        "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\.python_history"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M04 Profile" }
    Write-Log "[M04] 完成" "Success"
}

# ---------- M05: 下载工具配置 ----------
function Invoke-M05Downloads {
    Write-Log "[M05] 清理下载工具配置..." "Step"
    # IDM
    Stop-ProcessAndWait -ProcessNames @("IDMan", "IEMonitor") -TimeoutSeconds 8 | Out-Null
    Remove-RegistryKey -Path "HKCU:\Software\DownloadManager" -Stage "M05 IDM"
    # 迅雷
    Stop-ProcessAndWait -ProcessNames @("Thunder", "XLEngine", "ThunderPlatform") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\Thunder",
        "$env:APPDATA\Thunder Network",
        "$env:LOCALAPPDATA\Thunder",
        "$env:ProgramData\Thunder Network"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M05 Thunder" }
    # qBittorrent / uTorrent
    Stop-ProcessAndWait -ProcessNames @("qbittorrent", "uTorrent") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\qBittorrent\qBittorrent.ini",
        "$env:APPDATA\qBittorrent\qBittorrent-data.ini",
        "$env:APPDATA\uTorrent",
        "$env:APPDATA\BitTorrent"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M05 BT" }
    Write-Log "[M05] 完成" "Success"
}

# ---------- M06: 截图与搜索工具历史 ----------
function Invoke-M06Screenshot {
    Write-Log "[M06] 清理截图与搜索工具历史..." "Step"
    Stop-ProcessAndWait -ProcessNames @("Snipaste", "ShareX") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\Snipaste",
        "$env:APPDATA\ShareX"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M06 Screenshot" }
    # Everything 搜索历史
    Stop-ProcessAndWait -ProcessNames @("Everything") -TimeoutSeconds 5 | Out-Null
    @(
        "$env:APPDATA\Everything\Everything.ini",
        "$env:LOCALAPPDATA\Everything"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M06 Everything" }
    # Listary 搜索历史与配置
    Stop-ProcessAndWait -ProcessNames @("Listary", "ListaryUserAssistant") -TimeoutSeconds 5 | Out-Null
    @(
        "$env:APPDATA\Listary",
        "$env:LOCALAPPDATA\Listary"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M06 Listary" }
    Write-Log "[M06] 完成" "Success"
}

# ---------- M07: 浏览器数据 ----------
function Invoke-M07Browsers {
    Write-Log "[M07] 清理浏览器数据..." "Step"
    $browsers = @(
        @{ Name = "Edge";   Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";   Procs = @("msedge", "msedgewebview2") }
        @{ Name = "Chrome"; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data";   Procs = @("chrome") }
        @{ Name = "Firefox";Path = "$env:APPDATA\Mozilla\Firefox\Profiles";       Procs = @("firefox") }
        @{ Name = "Brave";  Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Procs = @("brave") }
        @{ Name = "Opera";  Path = "$env:APPDATA\Opera Software\Opera Stable";    Procs = @("opera") }
        @{ Name = "Vivaldi";Path = "$env:LOCALAPPDATA\Vivaldi\User Data";          Procs = @("vivaldi") }
    )
    foreach ($b in $browsers) {
        if (Test-Path $b.Path) {
            Write-Log "  清理 $($b.Name)..." "Step"
            Stop-ProcessAndWait -ProcessNames $b.Procs -TimeoutSeconds 10 | Out-Null
            Remove-PathSafe -Path $b.Path -Stage "M07 $($b.Name)"
        }
    }
    # Firefox 全局配置
    Remove-PathSafe -Path "$env:APPDATA\Mozilla\Firefox\profiles.ini" -Stage "M07 Firefox"
    Write-Log "[M07] 完成" "Success"
}

# ---------- M08: 通讯软件 ----------
function Invoke-M08IM {
    Write-Log "[M08] 清理通讯软件..." "Step"
    # QQ
    Stop-ProcessAndWait -ProcessNames @("QQ") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\Documents\Tencent Files", "$env:APPDATA\Tencent\QQ", "$env:LOCALAPPDATA\Tencent\QQ") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 QQ" }
    # 微信
    Stop-ProcessAndWait -ProcessNames @("WeChat", "WeChatAppEx") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\Documents\WeChat Files", "$env:APPDATA\Tencent\WeChat", "$env:LOCALAPPDATA\Tencent\WeChat") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 WeChat" }
    # 企业微信
    Stop-ProcessAndWait -ProcessNames @("WXWork") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\Documents\WXWork", "$env:APPDATA\Tencent\WXWork") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 WXWork" }
    # Telegram
    Stop-ProcessAndWait -ProcessNames @("Telegram", "tdesktop") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Telegram Desktop", "$env:LOCALAPPDATA\Telegram Desktop") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 Telegram" }
    # Discord
    Stop-ProcessAndWait -ProcessNames @("Discord") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\discord", "$env:LOCALAPPDATA\discord") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 Discord" }
    # Slack
    Stop-ProcessAndWait -ProcessNames @("slack") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Slack", "$env:LOCALAPPDATA\Slack") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 Slack" }
    # 钉钉 / 飞书
    Stop-ProcessAndWait -ProcessNames @("DingTalk", "Lark", "Feishu") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\DingTalk", "$env:LOCALAPPDATA\DingTalk", "$env:APPDATA\Lark", "$env:LOCALAPPDATA\Lark", "$env:APPDATA\Feishu") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M08 WorkIM" }
    Write-Log "[M08] 完成" "Success"
}

# ---------- M09: 邮件客户端 ----------
function Invoke-M09Mail {
    Write-Log "[M09] 清理邮件客户端..." "Step"
    # Outlook（OST/IMAP 缓存含全部邮件/联系人/日历，是重大个人数据）
    Stop-ProcessAndWait -ProcessNames @("OUTLOOK") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\Microsoft\Outlook", "$env:APPDATA\Microsoft\Outlook") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M09 Outlook" }
    # Thunderbird
    Stop-ProcessAndWait -ProcessNames @("thunderbird") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Thunderbird\Profiles", "$env:APPDATA\Thunderbird\profiles.ini", "$env:APPDATA\Thunderbird\registry.dat") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M09 Thunderbird" }
    # Foxmail
    Stop-ProcessAndWait -ProcessNames @("Foxmail") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Tencent\Foxmail", "$env:LOCALAPPDATA\Tencent\Foxmail") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M09 Foxmail" }
    # 网易邮箱大师
    Stop-ProcessAndWait -ProcessNames @("MailMaster") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\NetEase\MailMaster", "$env:LOCALAPPDATA\NetEase\MailMaster") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M09 NetEaseMail" }
    Write-Log "[M09] 完成" "Success"
}

# ---------- M10: 网盘客户端 ----------
function Invoke-M10CloudDrives {
    Write-Log "[M10] 清理网盘客户端..." "Step"
    # 百度网盘
    Stop-ProcessAndWait -ProcessNames @("BaiduNetdisk") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\Documents\BaiduNetdiskDownload", "$env:APPDATA\baidu\BaiduNetdisk", "$env:LOCALAPPDATA\BaiduNetdisk") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M10 Baidu" }
    # 坚果云
    Stop-ProcessAndWait -ProcessNames @("Nutstore") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\Nutstore", "$env:APPDATA\Nutstore", "$env:USERPROFILE\Documents\Nutstore Files") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M10 Nutstore" }
    # Dropbox
    Stop-ProcessAndWait -ProcessNames @("Dropbox") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\Dropbox", "$env:APPDATA\Dropbox", "$env:LOCALAPPDATA\Dropbox") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M10 Dropbox" }
    # 阿里云盘
    Stop-ProcessAndWait -ProcessNames @("AliyunDrive", "aDrive") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\alibaba", "$env:LOCALAPPDATA\AliyunDrive", "$env:LOCALAPPDATA\aDrive") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M10 Aliyun" }
    Write-Log "[M10] 完成" "Success"
}

# ---------- M11: 远程会议与录屏 ----------
function Invoke-M11Meeting {
    Write-Log "[M11] 清理远程会议与录屏..." "Step"
    # Zoom
    Stop-ProcessAndWait -ProcessNames @("Zoom") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Zoom", "$env:LOCALAPPDATA\Zoom") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 Zoom" }
    # Teams（账户部分已在 M20 处理，这里清缓存；含旧版 Teams 与新版 MSTeams）
    Stop-ProcessAndWait -ProcessNames @("Teams", "ms-teams") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Microsoft\Teams\Cache", "$env:APPDATA\Microsoft\Teams\GPUCache", "$env:APPDATA\Microsoft\Teams\Local Storage") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 Teams" }
    # 新版 Teams (MSTeams) 为 MSIX 应用，包目录名形如 MSTeams_8wekyb3d8bbwe，需先展开通配符
    Get-Item -Path "$env:LOCALAPPDATA\Packages\MSTeams_*" -ErrorAction SilentlyContinue | ForEach-Object {
        @("$($_.FullName)\LocalCache\Microsoft\Teams", "$($_.FullName)\LocalCache\LBStorage", "$($_.FullName)\AC") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 MSTeams" }
    }
    # 腾讯会议
    Stop-ProcessAndWait -ProcessNames @("wemeetapp") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Tencent\WeMeet", "$env:LOCALAPPDATA\Tencent\WeMeet") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 WeMeet" }
    # WebEx
    Stop-ProcessAndWait -ProcessNames @("webex") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Cisco\WebEx", "$env:LOCALAPPDATA\Cisco\WebEx") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 WebEx" }
    # OBS Studio（录屏软件配置）
    Stop-ProcessAndWait -ProcessNames @("obs64", "obs32") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\obs-studio", "$env:APPDATA\OBS") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M11 OBS" }
    Write-Log "[M11] 完成" "Success"
}

# ---------- M12: 笔记与知识库 ----------
function Invoke-M12Notes {
    Write-Log "[M12] 清理笔记与知识库..." "Step"
    # Obsidian（含 sync token）
    Stop-ProcessAndWait -ProcessNames @("Obsidian") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\obsidian", "$env:APPDATA\Obsidian") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M12 Obsidian" }
    # Notion
    Stop-ProcessAndWait -ProcessNames @("Notion") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Notion", "$env:LOCALAPPDATA\Notion") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M12 Notion" }
    # 印象笔记 / Evernote
    Stop-ProcessAndWait -ProcessNames @("Evernote", "印象笔记") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Evernote", "$env:LOCALAPPDATA\Evernote", "$env:USERPROFILE\Documents\Evernote") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M12 Evernote" }
    # 为知笔记
    Stop-ProcessAndWait -ProcessNames @("WizNote") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\WizNote", "$env:LOCALAPPDATA\WizNote") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M12 WizNote" }
    Write-Log "[M12] 完成" "Success"
}

# ---------- M13: 密码管理器 ----------
function Invoke-M13PasswordMgr {
    Write-Log "[M13] 清理密码管理器..." "Step"
    # Sticky Password（用户指定）
    Stop-ProcessAndWait -ProcessNames @("spnt", "Sticky Password") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\Lamantine\Sticky Password",
        "$env:LOCALAPPDATA\Lamantine\Sticky Password",
        "$env:APPDATA\Sticky Password",
        "$env:LOCALAPPDATA\Sticky Password"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M13 StickyPwd" }
    Remove-RegistryKey -Path "HKCU:\Software\Lamantine" -Stage "M13 StickyPwd"
    # 1Password
    Stop-ProcessAndWait -ProcessNames @("1Password", "1Password-BrowserSupport") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\1Password", "$env:LOCALAPPDATA\1Password") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M13 1Password" }
    # 1Password UWP 包目录名形如 AgileBits.1Password_8wekyb3d8bbwe，需先展开通配符再删（Remove-PathSafe 用 -LiteralPath 不支持通配）
    Get-Item -Path "$env:LOCALAPPDATA\Packages\AgileBits.1Password_*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-PathSafe -Path $_.FullName -Stage "M13 1Password" }
    # Bitwarden
    Stop-ProcessAndWait -ProcessNames @("Bitwarden") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Bitwarden", "$env:LOCALAPPDATA\Bitwarden") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M13 Bitwarden" }
    # KeePass（数据库文件，可能含密码）
    Stop-ProcessAndWait -ProcessNames @("KeePass", "KeePassXC") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\KeePass", "$env:APPDATA\KeePassXC", "$env:LOCALAPPDATA\KeePassXC") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M13 KeePass" }
    # LastPass
    Stop-ProcessAndWait -ProcessNames @("LastPass") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\LastPass") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M13 LastPass" }
    Write-Log "[M13] 完成" "Success"
}

# ---------- M14: 数据库工具 ----------
function Invoke-M14DbTools {
    Write-Log "[M14] 清理数据库工具..." "Step"
    # Navicat
    Stop-ProcessAndWait -ProcessNames @("navicat", "navicat15", "navicat16", "navicat17") -TimeoutSeconds 8 | Out-Null
    @("HKCU:\Software\PremiumSoft\NaviCat", "HKCU:\Software\PremiumSoft\NavicatPremium", "HKCU:\Software\PremiumSoft\Navicat") | ForEach-Object { Remove-RegistryKey -Path $_ -Stage "M14 Navicat" }
    Get-ChildItem -LiteralPath "$env:APPDATA\PremiumSoft" -ErrorAction SilentlyContinue | ForEach-Object { Remove-PathSafe -Path $_.FullName -Stage "M14 Navicat" }
    # DBeaver
    Stop-ProcessAndWait -ProcessNames @("dbeaver") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\DBeaverData\workspace6\General\.dbeaver",
        "$env:APPDATA\DBeaverData\workspace6\General\.dbeaver-credentials.json",
        "$env:APPDATA\DBeaverData\credentials-config.json",
        "$env:APPDATA\DBeaverData\workspace6\.metadata"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M14 DBeaver" }
    # SSMS（Stop-Process -Name 大小写不敏感，Ssms 与 ssms 等价，仅需其一）
    Stop-ProcessAndWait -ProcessNames @("Ssms") -TimeoutSeconds 8 | Out-Null
    Remove-PathSafe -Path "$env:APPDATA\Microsoft\SQL Server Management Studio" -Stage "M14 SSMS"
    Get-ChildItem -LiteralPath "HKCU:\Software\Microsoft\SQL Server Management Studio" -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "Server|Connection" } | ForEach-Object {
                Remove-RegistryKey -Path $_.PSPath -Stage "M14 SSMS"
            }
        }
    }
    # MySQL Workbench（删除整个 Workbench 目录即包含 connections.xml，无需单独列出）
    Stop-ProcessAndWait -ProcessNames @("MySQLWorkbench") -TimeoutSeconds 8 | Out-Null
    Remove-PathSafe -Path "$env:APPDATA\MySQL\Workbench" -Stage "M14 MySQLWB"
    # Redis / Mongo 工具
    @("$env:APPDATA\Redis Desktop Manager", "$env:APPDATA\RedisInsight", "$env:USERPROFILE\.redisinsight", "$env:APPDATA\3T Software Labs", "$env:APPDATA\Robomongo", "$env:LOCALAPPDATA\Robomongo") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M14 NoSQL" }
    Write-Log "[M14] 完成" "Success"
}

# ---------- M15: 远程连接（SSH + 远程控制合并）----------
function Invoke-M15Remote {
    Write-Log "[M15] 清理远程连接..." "Step"
    # OpenSSH
    $sshDir = "$env:USERPROFILE\.ssh"
    if (Test-Path $sshDir) {
        Get-ChildItem -LiteralPath $sshDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-PathSafe -Path $_.FullName -Stage "M15 SSH"
        }
    }
    # PuTTY
    @("HKCU:\Software\SimonTatham\PuTTY\Sessions", "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys", "HKCU:\Software\SimonTatham\PuTTYJumper\Sessions") | ForEach-Object { Remove-RegistryKey -Path $_ -Stage "M15 PuTTY" }
    # WinSCP
    @("$env:APPDATA\WinSCP.ini", "$env:APPDATA\WinSCP\WinSCP.ini") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 WinSCP" }
    Remove-RegistryKey -Path "HKCU:\Software\Martin Prikryl\WinSCP 2" -Stage "M15 WinSCP"
    # MobaXterm
    @("$env:USERPROFILE\Documents\MobaXterm\MobaXterm.ini", "$env:USERPROFILE\Documents\MobaXterm\MxtSessions.ini", "$env:APPDATA\MobaXterm") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 MobaXterm" }
    # RDP
    Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Terminal Server Client\Default" -Stage "M15 RDP"
    Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Terminal Server Client\Servers" -Stage "M15 RDP"
    # TeamViewer
    Stop-ProcessAndWait -ProcessNames @("TeamViewer", "tv_w32", "tv_w64") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\TeamViewer", "$env:LOCALAPPDATA\TeamViewer") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 TV" }
    @("HKCU:\Software\TeamViewer", "HKCU:\Software\Wow6432Node\TeamViewer") | ForEach-Object { Remove-RegistryKey -Path $_ -Stage "M15 TV" }
    # AnyDesk
    Stop-ProcessAndWait -ProcessNames @("AnyDesk") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\AnyDesk", "$env:LOCALAPPDATA\AnyDesk", "$env:ProgramData\AnyDesk") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 AnyDesk" }
    # 向日葵
    Stop-ProcessAndWait -ProcessNames @("SunloginClient", "SunloginRemote") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Oray\SunloginClient", "$env:LOCALAPPDATA\Oray\SunloginClient", "$env:ProgramData\Oray\SunloginClient") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 Sunlogin" }
    # ToDesk
    Stop-ProcessAndWait -ProcessNames @("ToDesk") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\ToDesk", "$env:LOCALAPPDATA\ToDesk", "$env:ProgramData\ToDesk") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 ToDesk" }
    # RustDesk
    Stop-ProcessAndWait -ProcessNames @("RustDesk") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\RustDesk", "$env:LOCALAPPDATA\RustDesk", "$env:ProgramData\RustDesk") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 RustDesk" }
    # FileZilla（明文密码！）
    Stop-ProcessAndWait -ProcessNames @("filezilla") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\FileZilla\recentservers.xml", "$env:APPDATA\FileZilla\sitemanager.xml", "$env:APPDATA\FileZilla\filezilla.xml") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M15 FileZilla" }
    Write-Log "[M15] 完成" "Success"
}

# ---------- M16: 游戏与创意软件 ----------
function Invoke-M16GameCreative {
    Write-Log "[M16] 清理游戏与创意软件..." "Step"
    # Unity Hub
    Stop-ProcessAndWait -ProcessNames @("Unity Hub", "Unity") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\UnityHub", "$env:APPDATA\UnityHub-Secondary", "$env:USERPROFILE\.unity", "$env:LOCALAPPDATA\Unity", "$env:ProgramData\Unity") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 Unity" }
    Remove-RegistryKey -Path "HKCU:\Software\Unity Technologies" -Stage "M16 Unity"
    # Steam
    Stop-ProcessAndWait -ProcessNames @("steam", "steamwebhelper") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Steam", "$env:LOCALAPPDATA\Steam") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 Steam" }
    $steamInstall = Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction SilentlyContinue
    if ($steamInstall -and $steamInstall.SteamPath) {
        Remove-PathSafe -Path "$($steamInstall.SteamPath)\config" -Stage "M16 Steam"
        Remove-PathSafe -Path "$($steamInstall.SteamPath)\steamapps\loginusers.vdf" -Stage "M16 Steam"
        Remove-PathWildcard -Pattern "$($steamInstall.SteamPath)\ssfn*" -Stage "M16 Steam"
    }
    # Epic
    Stop-ProcessAndWait -ProcessNames @("EpicGamesLauncher") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\EpicGames\EpicGamesLauncher\Saved\Config", "$env:LOCALAPPDATA\EpicGames\EpicGamesLauncher\Saved\Logs", "$env:LOCALAPPDATA\EpicGames\EpicGamesLauncher\Saved\webengine") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 Epic" }
    # Battle.net / EA / Ubisoft / Riot / GOG
    Stop-ProcessAndWait -ProcessNames @("Battle.net", "EADesktop", "UbisoftConnect", "UbisoftGameLauncher", "RiotClient", "GOG Galaxy") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Battle.net", "$env:LOCALAPPDATA\Battle.net", "$env:ProgramData\Electronic Arts", "$env:LOCALAPPDATA\Electronic Arts", "$env:LOCALAPPDATA\Ubisoft Game Launcher\save", "$env:LOCALAPPDATA\Ubisoft Game Launcher\logs", "$env:APPDATA\Riot Client", "$env:LOCALAPPDATA\Riot Client", "$env:ProgramData\GOG.com") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 GamePlatform" }
    # Adobe Creative Cloud
    Stop-ProcessAndWait -ProcessNames @("Creative Cloud", "Adobe CEF Helper", "Creative-Cloud-Installer") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Adobe", "$env:LOCALAPPDATA\Adobe", "$env:USERPROFILE\.adobe") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 Adobe" }
    Remove-RegistryKey -Path "HKCU:\Software\Adobe\Adobe\Common" -Stage "M16 Adobe"
    # Figma
    Stop-ProcessAndWait -ProcessNames @("Figma") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Figma", "$env:LOCALAPPDATA\Figma") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 Figma" }
    # Minecraft
    Stop-ProcessAndWait -ProcessNames @("MinecraftLauncher", "Minecraft") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\.minecraft\launcher_accounts.json", "$env:APPDATA\.minecraft\launcher_profiles.json", "$env:APPDATA\.minecraft\servers.dat", "$env:APPDATA\.minecraft\logs") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M16 MC" }
    Write-Log "[M16] 完成" "Success"
}

# ---------- M17: 网络隧道工具 ----------
function Invoke-M17NetworkTunnel {
    Write-Log "[M17] 清理网络隧道工具..." "Step"
    # OpenVPN（可能装在 Program Files 或 Program Files (x86)）
    Stop-ProcessAndWait -ProcessNames @("openvpn", "openvpn-gui") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:USERPROFILE\OpenVPN",
        "$env:ProgramFiles\OpenVPN\config",
        "${env:ProgramFiles(x86)}\OpenVPN\config"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 OpenVPN" }
    # WireGuard
    Stop-ProcessAndWait -ProcessNames @("wireguard") -TimeoutSeconds 8 | Out-Null
    Remove-PathSafe -Path "$env:APPDATA\WireGuard" -Stage "M17 WG"
    # Clash 系（含 Clash Verge / Clash for Windows）
    Stop-ProcessAndWait -ProcessNames @("clash", "clash-verge", "Clash for Windows", "mihomo") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\.config\clash", "$env:APPDATA\clash", "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev", "$env:APPDATA\clash-verge", "$env:APPDATA\Clash for Windows") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 Clash" }
    # V2Ray / Nekoray / NekoBox
    Stop-ProcessAndWait -ProcessNames @("v2rayN", "nekoray", "nekoray_core") -TimeoutSeconds 8 | Out-Null
    @("$env:USERPROFILE\.config\nekoray", "$env:APPDATA\v2rayN", "$env:LOCALAPPDATA\v2rayN") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 V2Ray" }
    # 商业牌（N/E/A）
    @("$env:APPDATA\NordVPN", "$env:LOCALAPPDATA\NordVPN", "$env:APPDATA\ExpressVPN", "$env:LOCALAPPDATA\ExpressVPN", "$env:APPDATA\Atlas VPN", "$env:LOCALAPPDATA\Atlas VPN") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 Commercial" }
    # Tailscale / ZeroTier（Mesh 组网）
    Stop-ProcessAndWait -ProcessNames @("tailscaled", "tailscale-ipn", "Tailscale") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\Tailscale", "$env:APPDATA\Tailscale", "$env:ProgramData\Tailscale") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 Tailscale" }
    Stop-ProcessAndWait -ProcessNames @("zerotier-one", "ZeroTierOne") -TimeoutSeconds 8 | Out-Null
    @("$env:ProgramData\ZeroTier\One", "$env:LOCALAPPDATA\ZeroTier") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 ZeroTier" }
    # Sing-box
    Stop-ProcessAndWait -ProcessNames @("sing-box") -TimeoutSeconds 5 | Out-Null
    @("$env:USERPROFILE\.config\sing-box", "$env:APPDATA\sing-box") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M17 SingBox" }
    Write-Log "[M17] 完成" "Success"
}

# ---------- M18: 版本控制凭证 ----------
function Invoke-M18VCS {
    Write-Log "[M18] 清理版本控制凭证..." "Step"
    # Git
    @(
        "$env:USERPROFILE\.git-credentials",
        "$env:USERPROFILE\.gitconfig",
        "$env:USERPROFILE\.config\git\credentials",
        "$env:LOCALAPPDATA\GitCredentials"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M18 Git" }
    Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Git-Credential-Manager" -Stage "M18 Git"
    @("$env:APPDATA\Git-Credential-Manager-for-Windows", "$env:LOCALAPPDATA\Git-Credential-Manager", "$env:LOCALAPPDATA\Programs\GitCredentialManager") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M18 Git" }
    # SVN（删除 auth 即包含 svn.simple / svn.username 子目录，无需单独列出）
    Remove-PathSafe -Path "$env:APPDATA\Subversion\auth" -Stage "M18 SVN"
    # Mercurial
    @("$env:USERPROFILE\.hgrc", "$env:USERPROFILE\Mercurial.ini") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M18 Hg" }
    Write-Log "[M18] 完成" "Success"
}

# ---------- M19: 开发工具 token ----------
function Invoke-M19DevTools {
    Write-Log "[M19] 清理开发工具 token..." "Step"
    # VS Code
    Stop-ProcessAndWait -ProcessNames @("Code", "Code-Insiders") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:APPDATA\Code\User\settings.json",
        "$env:APPDATA\Code\User\keybindings.json",
        "$env:APPDATA\Code\User\globalStorage",
        "$env:APPDATA\Code\User\workspaceStorage",
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\CachedExtensions",
        "$env:APPDATA\Code\logs",
        "$env:APPDATA\Code\storage",
        "$env:APPDATA\Code - Insiders\User"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 VSCode" }
    # Cursor
    Stop-ProcessAndWait -ProcessNames @("Cursor") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Cursor\User\globalStorage", "$env:APPDATA\Cursor\User\workspaceStorage", "$env:APPDATA\Cursor\storage") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Cursor" }
    # JetBrains
    Get-ChildItem -LiteralPath "$env:APPDATA\JetBrains" -ErrorAction SilentlyContinue | ForEach-Object {
        $optionsDir = Join-Path $_.FullName "options"
        if (Test-Path $optionsDir) {
            Get-ChildItem $optionsDir -Filter "*.xml" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '(other\.xml|security\.xml|github\.xml|gist\.xml|proxy\.settings)'
            } | ForEach-Object { Remove-PathSafe -Path $_.FullName -Stage "M19 JetBrains" }
        }
    }
    # Visual Studio Pro
    Stop-ProcessAndWait -ProcessNames @("devenv") -TimeoutSeconds 8 | Out-Null
    @("$env:LOCALAPPDATA\Microsoft\VisualStudio", "$env:LOCALAPPDATA\Microsoft\VSCommon", "$env:APPDATA\Microsoft\VisualStudio\OnlineSettingsCache", "$env:LOCALAPPDATA\Microsoft\IdentityService") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 VSPro" }
    # 注意：.nuget\packages 是构建产物缓存（不含个人数据/凭证，可重新下载），不再删除以避免下次构建重新下载数 GB
    # Docker：.docker 整目录在下方 VM 段统一删除（含 config.json 的 auths 凭证），无需单独处理
    # 云 CLI
    @(
        "$env:USERPROFILE\.aws\credentials",
        "$env:USERPROFILE\.aws\config",
        "$env:USERPROFILE\.azure\accessTokens.json",
        "$env:USERPROFILE\.azure\azureProfile.json",
        "$env:USERPROFILE\.azure\msal_token_cache.json",
        "$env:USERPROFILE\.azure\msal_http_cache.json",
        "$env:USERPROFILE\.config\gcloud\credentials.db",
        "$env:USERPROFILE\.config\gcloud\legacy_credentials",
        "$env:APPDATA\gcloud\credentials.db",
        "$env:USERPROFILE\.kube\config",
        "$env:USERPROFILE\.kube\cache"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Cloud" }
    # 包管理器
    @(
        "$env:USERPROFILE\.npmrc",
        "$env:USERPROFILE\.yarnrc",
        "$env:USERPROFILE\.yarnrc.yml",
        "$env:APPDATA\npm\.npmrc",
        "$env:USERPROFILE\.pypirc",
        "$env:APPDATA\pip\pip.ini",
        "$env:LOCALAPPDATA\pip\pip.conf",
        "$env:USERPROFILE\.nuget\NuGet\NuGet.Config",
        "$env:APPDATA\NuGet\NuGet.Config"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 PkgMgr" }
    # 编辑器配置（Vim/Emacs/Sublime）
    @(
        "$env:USERPROFILE\.vimrc",
        "$env:USERPROFILE\.vim",
        "$env:USERPROFILE\.config\nvim",
        "$env:USERPROFILE\.emacs",
        "$env:USERPROFILE\.emacs.d",
        "$env:APPDATA\Sublime Text",
        "$env:APPDATA\Sublime Text 3"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Editor" }
    # 容器/虚拟化配置（含 VM 配置）
    @(
        "$env:USERPROFILE\.docker",
        "$env:USERPROFILE\.config\containers",
        "$env:USERPROFILE\.minikube",
        "$env:USERPROFILE\.VirtualBox",
        "$env:APPDATA\VMware"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 VM" }
    # Android 开发（含签名 keystore！注意：.gradle\caches 与 daemon 是构建产物，不含凭证，不再删除）
    Stop-ProcessAndWait -ProcessNames @("studio64", "android") -TimeoutSeconds 8 | Out-Null
    @(
        "$env:USERPROFILE\.android",
        "$env:USERPROFILE\.gradle\gradle.properties"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Android" }
    # Java/Maven（注意：.m2\repository 是构建产物缓存，不含凭证，保留；仅删 settings.xml 与 .java\.userPrefs）
    @(
        "$env:USERPROFILE\.m2\settings.xml",
        "$env:USERPROFILE\.java\.userPrefs"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Maven" }
    # Rust / Cargo（crates.io token）
    @(
        "$env:USERPROFILE\.cargo\credentials",
        "$env:USERPROFILE\.cargo\credentials.toml"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Cargo" }
    # Helm（仓库凭据）
    @("$env:APPDATA\helm\repositories.yaml", "$env:APPDATA\helm\registry.json") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Helm" }
    # Terraform（Cloud token）
    @("$env:USERPROFILE\.terraform.d\credentials.tfrc.json", "$env:USERPROFILE\.terraform.d\terraform.rc") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Terraform" }
    # Vagrant（boxes + insecure key）
    Remove-PathSafe -Path "$env:USERPROFILE\.vagrant.d" -Stage "M19 Vagrant"
    # Conda / Jupyter（可能含 token）
    @(
        "$env:USERPROFILE\.condarc",
        "$env:USERPROFILE\.continuum",
        "$env:USERPROFILE\.jupyter\jupyter_notebook_config.json",
        "$env:USERPROFILE\.jupyter\jupyter_lab_config.py",
        "$env:USERPROFILE\.jupyter\nbconfig"
    ) | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Conda" }
    # Go telemetry / Go env
    @("$env:USERPROFILE\.config\go\telemetry", "$env:APPDATA\go-env") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Go" }
    # Postman / Insomnia（API 测试工具 token）
    Stop-ProcessAndWait -ProcessNames @("Postman") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Postman", "$env:LOCALAPPDATA\Postman") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Postman" }
    Stop-ProcessAndWait -ProcessNames @("Insomnia") -TimeoutSeconds 8 | Out-Null
    @("$env:APPDATA\Insomnia", "$env:LOCALAPPDATA\Insomnia") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 Insomnia" }
    # Hugging Face / OpenAI token
    @("$env:USERPROFILE\.cache\huggingface\token", "$env:USERPROFILE\.openai") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M19 AI" }
    Write-Log "[M19] 完成" "Success"
}

# ---------- M20: 微软账户 + 凭据管理器 + DPAPI + 系统日志 ----------
function Invoke-M20MicrosoftUltimate {
    Write-Log "[M20] 终极清理：微软账户+凭据+DPAPI+日志..." "Step"
    # 1. OneDrive
    Write-Log "[M20.1] 断开 OneDrive..." "Step"
    if (Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue) {
        if (-not (Stop-ProcessAndWait -ProcessNames @("OneDrive", "OneDriveStandaloneUpdater", "FileCoAuth") -TimeoutSeconds 8)) {
            Add-ErrorItem -Stage "M20.1 OneDrive" -Message "进程未在超时内退出"
        }
    }
    @("$env:USERPROFILE\OneDrive", "$env:LOCALAPPDATA\Microsoft\OneDrive\settings", "$env:APPDATA\Microsoft\OneDrive") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M20.1 OneDrive" }
    # 2. Office
    Write-Log "[M20.2] 清除 Office..." "Step"
    $officeProcs = @("WINWORD","EXCEL","POWERPNT","OUTLOOK","ONENOTE","MSACCESS","ONENOTEM")
    $officeProcs | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    }
    Start-Sleep -Seconds 2
    Stop-ProcessAndWait -ProcessNames @("WINWORD","EXCEL","POWERPNT","OUTLOOK","ONENOTE","MSACCESS") -TimeoutSeconds 8 | Out-Null
    @("16.0", "15.0") | ForEach-Object { Remove-RegistryKey -Path "HKCU:\Software\Microsoft\Office\$_\Common\Identity" -Stage "M20.2 Office" }
    @("$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing", "$env:LOCALAPPDATA\Microsoft\Office\15.0\Licensing") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M20.2 Office" }
    # 3. AAD Broker
    Write-Log "[M20.3] 清除 AAD Broker..." "Step"
    @("$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin*", "$env:LOCALAPPDATA\Packages\Microsoft.AccountsControl*") | ForEach-Object {
        Get-Item -Path $_ -ErrorAction SilentlyContinue | ForEach-Object { Remove-PathSafe -Path $_.FullName -Stage "M20.3 AAD" }
    }
    # 4. 预配应用
    Write-Log "[M20.4] 重置预配应用..." "Step"
    $userApps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        # 含新版 Teams（MSTeams，无 Microsoft. 前缀）
        $_.Name -match '^(Microsoft\.(AccountsControl|AAD\.BrokerPlugin|WindowsCommunicationsApps|WindowsStore|MicrosoftEdge|Office\.Hub|OneDriveSync|SkypeApp|Teams|YourPhone|Windows\.CloudExperienceHost)|MSTeams)'
    }
    foreach ($app in $userApps) {
        try {
            $manifestPath = Join-Path $app.InstallLocation "AppxManifest.xml"
            if (-not $app.InstallLocation -or -not (Test-Path $manifestPath)) { continue }
            if ($script:TestMode) {
                Write-Log "  [TEST] 将重置: $($app.Name)" -Level "Warning"
            } else {
                Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction SilentlyContinue
                Write-Log "  已重置: $($app.Name)"
            }
        } catch { Add-ErrorItem -Stage "M20.4 Appx" -Message "$($app.Name): $($_.Exception.Message)" }
    }
    # 5. 微软注册表
    Write-Log "[M20.5] 清理微软账户注册表..." "Step"
    # IdentityCRL / IdentityStore 是子键，直接删除
    @("HKCU:\Software\Microsoft\IdentityCRL", "HKCU:\Software\Microsoft\IdentityStore") | ForEach-Object { Remove-RegistryKey -Path $_ -Stage "M20.5 Reg" }
    # IE Main\Identity 通常是 DWORD 值而非子键，Test-Path 对值返回 false 会静默跳过，需用 Remove-ItemProperty
    $ieMainPath = "HKCU:\Software\Microsoft\Internet Explorer\Main"
    if (Test-Path $ieMainPath) {
        if ($script:TestMode) {
            if (Get-ItemProperty -Path $ieMainPath -Name "Identity" -ErrorAction SilentlyContinue) {
                Write-Log "  [TEST][REGVAL] $ieMainPath\Identity" -Level "Warning"
                $script:Stats.Deleted++
            } else {
                $script:Stats.Skipped++
            }
        } else {
            try {
                Remove-ItemProperty -Path $ieMainPath -Name "Identity" -ErrorAction Stop
                Write-Log "  [#regval] [REGDELVAL] $ieMainPath\Identity" -Level "Success"
                $script:Stats.Deleted++
            } catch {
                Write-Log "  [REGVALSKIP] $ieMainPath\Identity 不存在或无法删除" -Level "Info"
                $script:Stats.Skipped++
            }
        }
    }
    if (-not $script:TestMode) {
        # reg.exe 是原生程序，失败时设 $LASTEXITCODE 而非抛异常，需检查退出码
        reg delete "HKU\.DEFAULT\Software\Microsoft\IdentityCRL" /f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
            # 退出码 1 通常表示键不存在，属正常情况；其他码记为错误
            Add-ErrorItem -Stage "M20.5 Reg" -Message "HKU\.DEFAULT IdentityCRL: reg 退出码 $LASTEXITCODE"
        }
        try {
            $sidPaths = Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-5-21-" }
            foreach ($sidPath in $sidPaths) {
                $identityCRLPath = Join-Path $sidPath.PSPath "Software\Microsoft\IdentityCRL"
                # 统一走 Remove-PathSafe 以进入统计与日志（Remove-Item -LiteralPath 支持 HKU 下的注册表路径）
                Remove-PathSafe -Path $identityCRLPath -Stage "M20.5 HKU"
            }
        } catch { Add-ErrorItem -Stage "M20.5 Reg" -Message "HKU 清理: $($_.Exception.Message)" }
    } else {
        Write-Log "  [TEST] 将清理 HKU IdentityCRL" -Level "Warning"
    }
    # 6. 凭据管理器全清
    Write-Log "[M20.6] 清空凭据管理器..." "Step"
    if ($script:TestMode) {
        $credList = cmdkey /list 2>$null
        # 用 @() 包裹防止 $credList 为 null 时 .Count 异常
        $credCount = @($credList | Select-String '^\s*(Target|目标)\s*:\s*(.+)$').Count
        Write-Log "  [TEST] 将清空凭据管理器（约 $credCount 条）" -Level "Warning"
    } else {
        cmdkey /list 2>$null | ForEach-Object {
            if ($_ -match '^\s*(Target|目标)\s*:\s*(.+)$') {
                $target = $Matches[2].Trim()
                # target 可能含空格（如 TERMSRV:host），需用引号包裹避免被解析为多个参数
                if ($target) { cmdkey "/delete:$target" 2>$null; Write-Log "  已删除凭据: $target" }
            }
        }
    }
    # PasswordVault（WinRT 类型在 Win10+ 自动加载，无需 Add-Type）
    try {
        $vaultType = [Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType = WindowsRuntime]
        $vault = [Activator]::CreateInstance($vaultType)
        $all = @($vault.RetrieveAll())
        if ($null -ne $all -and $all.Count -gt 0) {
            foreach ($c in $all) { try { $vault.Remove($c) } catch { } }
            Write-Log "  PasswordVault 已清空（$($all.Count) 条）"
        } else {
            Write-Log "  PasswordVault 无凭据"
        }
    } catch { Write-Log "  PasswordVault 不可用，跳过: $($_.Exception.Message)" -Level "Warning" }
    # 7. DPAPI Master Key
    Write-Log "[M20.7] 删除 DPAPI Master Key..." "Step"
    $protectPath = "$env:APPDATA\Microsoft\Protect"
    if (Test-Path $protectPath) {
        Get-ChildItem -LiteralPath $protectPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-PathSafe -Path $_.FullName -Stage "M20.7 DPAPI"
        }
    }
    Remove-PathSafe -Path "$env:LOCALAPPDATA\Microsoft\Credentials" -Stage "M20.7 CredRoam"
    Remove-PathSafe -Path "$env:APPDATA\Microsoft\Credentials" -Stage "M20.7 CredRoam"
    @("$env:LOCALAPPDATA\Low\Microsoft\CryptnetUrlCache", "$env:LOCALAPPDATA\Microsoft\CryptnetUrlCache") | ForEach-Object { Remove-PathSafe -Path $_ -Stage "M20.7 CryptNet" }
    # Windows Hello
    Remove-PathSafe -Path "$env:LOCALAPPDATA\Microsoft\Windows\WinBio" -Stage "M20.7 WinHello"
    Remove-PathSafe -Path "$env:LOCALAPPDATA\Microsoft\Windows\AccountPictures" -Stage "M20.7 WinHello"
    # NGC
    try {
        $ngcPath = "$env:LOCALAPPDATA\Microsoft\Ngc"
        if (Test-Path $ngcPath) {
            if ($script:TestMode) {
                Write-Log "  [TEST] 将停止 NgcSvc 并删除 NGC 容器" -Level "Warning"
            } else {
                try {
                    Stop-Service -Name "NgcSvc" -Force -ErrorAction SilentlyContinue
                    Remove-PathSafe -Path $ngcPath -Stage "M20.7 NGC"
                } finally {
                    Start-Service -Name "NgcSvc" -ErrorAction SilentlyContinue
                }
            }
        }
    } catch { Add-ErrorItem -Stage "M20.7 NGC" -Message $_.Exception.Message }
    # 8. 系统事件日志
    Write-Log "[M20.8] 清空系统事件日志..." "Step"
    if ($script:TestMode) {
        Write-Log "  [TEST] 将清空系统事件日志" -Level "Warning"
        Write-Log "[M20] 完成" "Success"
        return
    }
    $logs = @("Application", "Security", "System", "Setup", "ForwardedEvents", "Microsoft-Windows-PowerShell/Operational", "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational", "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational", "Windows PowerShell")
    foreach ($logName in $logs) {
        # WevtUtil 是原生程序，失败时设 $LASTEXITCODE 而非抛异常，需检查退出码而非依赖 catch
        WevtUtil cl "$logName" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  已清空 $logName"
        } else {
            Add-ErrorItem -Stage "M20.8 EventLog" -Message "$logName : WevtUtil 退出码 $LASTEXITCODE"
        }
    }
    # 额外枚举（限制数量避免耗时过长）
    try {
        $extraLogs = wevtutil el 2>$null | Where-Object { $_ -match "^(Microsoft-Windows|Security|System|Application)" -and $_ -notmatch "/Debug$" }
        $cleared = 0
        $maxExtra = 200
        foreach ($log in $extraLogs) {
            if ($cleared -ge $maxExtra) { Write-Log "  达到上限 $maxExtra，停止额外清理" -Level "Warning"; break }
            WevtUtil cl "$log" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $cleared++ }
        }
        Write-Log "  额外清理 $cleared 个运营日志"
    } catch { Add-ErrorItem -Stage "M20.8 ExtraLogs" -Message $_.Exception.Message }
    Write-Log "[M20] 完成" "Success"
}

# ---------- M21: WSL 发行版内个人数据 ----------
function Invoke-M21WSL {
    Write-Log "[M21] 清理 WSL 发行版内个人数据..." "Step"
    # 检查 WSL 是否安装
    $wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslExe) {
        Write-Log "  WSL 未安装，跳过"
        $script:Stats.Skipped++
        return
    }
    # 枚举所有发行版（wsl 输出为 UTF-16LE，PowerShell 读取时会有 null 字符）
    $distros = @()
    try {
        $rawOutput = & wsl.exe --list --quiet 2>$null
        if ($rawOutput) {
            $distros = $rawOutput | ForEach-Object {
                # 去除 UTF-16 双字节空字符和 BOM
                $clean = $_ -replace "`0", '' -replace "\uFEFF", ''
                $clean.Trim()
            } | Where-Object { $_ -and $_.Length -gt 0 -and $_ -notmatch 'distribution|发行版' }
        }
    } catch { Add-ErrorItem -Stage "M21" -Message "枚举 WSL 失败: $($_.Exception.Message)" }

    if ($distros.Count -eq 0) {
        Write-Log "  无 WSL 发行版，跳过"
        $script:Stats.Skipped++
        return
    }

    # 在每个发行版内清理个人数据
    $targets = @(
        ".ssh",
        ".aws",
        ".config/gcloud",
        ".kube",
        ".docker",
        ".git-credentials",
        ".netrc",
        ".bash_history",
        ".zsh_history",
        ".python_history",
        ".lesshst",
        ".viminfo",
        ".local/share/jupyter",
        ".config/gh/hosts.yml",
        ".cache/huggingface/token"
    )

    foreach ($distro in $distros) {
        Write-Log "  清理发行版: $distro" "Step"
        foreach ($t in $targets) {
            try {
                # 先检查是否存在
                $checkResult = wsl.exe -d $distro -- bash -c "if [ -e ~/$t ]; then echo EXISTS; fi" 2>$null
                if ($checkResult -match "EXISTS") {
                    if ($script:TestMode) {
                        Write-Log "    [TEST] 将删除: ~/$t" -Level "Warning"
                        $script:Stats.Deleted++
                    } else {
                        wsl.exe -d $distro -- bash -c "rm -rf ~/$t" 2>$null
                        Write-Log "    已删除: ~/$t"
                        $script:Stats.Deleted++
                    }
                } else {
                    Write-Log "    [SKIP] 不存在: ~/$t" -Level "Info"
                    $script:Stats.Skipped++
                }
            } catch {
                Add-ErrorItem -Stage "M21 $distro" -Message "$t : $($_.Exception.Message)"
                $script:Stats.Failed++
            }
        }
        # 清理 git 配置中的凭证辅助器设置（保留其他配置）
        if (-not $script:TestMode) {
            try {
                wsl.exe -d $distro -- bash -c "git config --global --unset credential.helper 2>/dev/null; git config --global --unset user.email 2>/dev/null; git config --global --unset user.name 2>/dev/null" 2>$null
                Write-Log "    已清理 git 全局凭证配置"
            } catch { }
        } else {
            Write-Log "    [TEST] 将清理 git 全局凭证配置" -Level "Warning"
        }
    }
    Write-Log "[M21] 完成" "Success"
}

# ============================================================
# 模块执行映射
# ============================================================
$moduleMap = @{
    "M01" = { Invoke-M01Temp }
    "M02" = { Invoke-M02RecycleBin }
    "M03" = { Invoke-M03Traces }
    "M04" = { Invoke-M04CmdHistory }
    "M05" = { Invoke-M05Downloads }
    "M06" = { Invoke-M06Screenshot }
    "M07" = { Invoke-M07Browsers }
    "M08" = { Invoke-M08IM }
    "M09" = { Invoke-M09Mail }
    "M10" = { Invoke-M10CloudDrives }
    "M11" = { Invoke-M11Meeting }
    "M12" = { Invoke-M12Notes }
    "M13" = { Invoke-M13PasswordMgr }
    "M14" = { Invoke-M14DbTools }
    "M15" = { Invoke-M15Remote }
    "M16" = { Invoke-M16GameCreative }
    "M17" = { Invoke-M17NetworkTunnel }
    "M18" = { Invoke-M18VCS }
    "M19" = { Invoke-M19DevTools }
    "M20" = { Invoke-M20MicrosoftUltimate }
    "M21" = { Invoke-M21WSL }
}

# ============================================================
# 执行已选模块（带进度显示 + ETA）
# ============================================================
$startTime = Get-Date
$currentStep = 0
foreach ($mod in $selectedModules) {
    $currentStep++
    Write-ModuleHeader -Current $currentStep -Total $totalSteps -Id $mod.Id -Name $mod.Name
    $modStart = Get-Date
    $beforeDeleted = $script:Stats.Deleted
    $beforeFailed = $script:Stats.Failed
    $beforeSkipped = $script:Stats.Skipped
    try {
        & $moduleMap[$mod.Id]
    } catch {
        Add-ErrorItem -Stage $mod.Id -Message "模块执行异常: $($_.Exception.Message)"
        Write-Log "  模块异常: $($_.Exception.Message)" -Level "Error"
    }
    $modElapsed = (Get-Date) - $modStart
    $modDeleted = $script:Stats.Deleted - $beforeDeleted
    $modFailed = $script:Stats.Failed - $beforeFailed
    $modSkipped = $script:Stats.Skipped - $beforeSkipped
    $script:ModuleStats[$mod.Id] = @{
        Deleted = $modDeleted
        Failed = $modFailed
        Skipped = $modSkipped
        Seconds = [math]::Round($modElapsed.TotalSeconds, 1)
    }
    Write-Log "  模块耗时 $([math]::Round($modElapsed.TotalSeconds, 1))s | 增量: 删$modDeleted 失败$modFailed 跳过$modSkipped" "Info"
    # ETA 预估
    if ($currentStep -lt $totalSteps) {
        $avgPerStep = ((Get-Date) - $startTime).TotalSeconds / $currentStep
        $remaining = ($totalSteps - $currentStep) * $avgPerStep
        Write-Log "  预计剩余: $([math]::Round($remaining, 0))s（共 $totalSteps 步，已完成 $currentStep 步）" "Info"
    }
}

# ============================================================
# 完成汇总
# ============================================================
$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  全部清理完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "⏱️ 总耗时: $([math]::Round($elapsed.TotalSeconds, 1)) 秒" -ForegroundColor Cyan
Write-Host ""
Write-Host "📊 执行统计：" -ForegroundColor Cyan
Write-Host "   已删除: $($script:Stats.Deleted)  失败: $($script:Stats.Failed)  跳过: $($script:Stats.Skipped)" -ForegroundColor White
Write-Host ""
# 每模块统计表
if ($script:ModuleStats.Count -gt 0) {
    Write-Host "📊 各模块明细：" -ForegroundColor Cyan
    $moduleRows = @()
    foreach ($mod in $selectedModules) {
        if ($script:ModuleStats.ContainsKey($mod.Id)) {
            $s = $script:ModuleStats[$mod.Id]
            $moduleRows += [PSCustomObject]@{
                模块 = $mod.Id
                删除 = $s.Deleted
                失败 = $s.Failed
                跳过 = $s.Skipped
                耗时s = $s.Seconds
            }
        }
    }
    $moduleRows | Format-Table -AutoSize
    Write-Host ""
}
if ($script:ErrorRecords.Count -gt 0) {
    Write-Host "📌 错误/警告详情（详见日志）：" -ForegroundColor Yellow
    $script:ErrorRecords | Format-Table -AutoSize
    Write-Host ""
} else {
    Write-Host "✅ 无错误/警告" -ForegroundColor Green
}
Write-Host "📌 后续步骤：" -ForegroundColor Cyan
Write-Host "  1. 重启电脑（强烈建议立即重启）" -ForegroundColor White
Write-Host "  2. 重启后逐一确认各软件已退出登录" -ForegroundColor White
Write-Host "  3. 浏览器首次启动会像新安装一样，需重新配置" -ForegroundColor White
Write-Host "  4. 如需转让电脑，建议执行「重置此电脑」彻底清理" -ForegroundColor White
Write-Host ""
Write-Host "📌 操作日志：" -ForegroundColor Cyan
if ($script:TranscriptActive) {
    Write-Host "   $script:LogFile" -ForegroundColor Gray
} else {
    Write-Host "   ⚠️ 日志未生成（Start-Transcript 启动失败），上述输出即为全部记录" -ForegroundColor Yellow
}
Write-Host ""
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
pause
