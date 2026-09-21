#Requires -Version 5.1
<#
.SYNOPSIS
    CS2 快速重建着色器缓存工具
.DESCRIPTION
    流程依据小黑盒教程《CS更新后掉帧严重？一张图片解决你的问题！》(作者: 忧郁美男子):
      1. 删除 CS2 game\core 目录下 shaders* 开头的文件
      2. Steam 校验 CS2 文件完整性 (被删除的文件会自动重新下载)
      3. 清理 Windows DirectX 着色器缓存 (等同"磁盘清理"中的 DirectX 着色器缓存项)
      4. Steam 控制台执行 shader_build 730 预编译着色器 (命令自动复制到剪贴板)
      5. 启动 CS2, 离线跑图完成着色器重建
    某些步骤想单独重跑时, 开场可输入步骤编号从该步开始 (前置检查始终执行)。
    仅支持 Windows + Steam 版 CS2。
.PARAMETER AppId
    Steam 游戏 AppId, 默认 730 (CS2)。
.PARAMETER DryRun
    演练模式: 只演示将要执行的操作, 不做任何实际改动。
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Rebuild-CS2ShaderCache.ps1 -DryRun
.NOTES
    适用环境: Windows 10/11, 系统自带的 Windows PowerShell 5.1 即可运行, 无需安装依赖。
    退出码  : 0 = 流程完成; 1 = 发生错误提前退出。
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = '交互式控制台 UI 工具, 需要彩色分节输出, 不面向管道复用, 有意使用 Write-Host')]
[CmdletBinding()]
param(
    [ValidateRange(1, [int]::MaxValue)]
    [int]$AppId = 730,
    [switch]$DryRun
)

Set-StrictMode -Version 3.0

$script:DryRun  = [bool]$DryRun
$script:FakeTest = $false
$script:Version = '1.2'
$script:KnownGameDirName = 'Counter-Strike Global Offensive'
$script:UIWidth = 66   # 界面总宽度 (显示列; 控制台里中文占 2 列)
$script:StartStep = 1  # 开场菜单选定的起始步骤
$script:Summary = New-Object System.Collections.Generic.List[string]
$script:TotalFreed = 0L   # 全程累计释放的字节数 (用于摘要)
$script:LastFreed = 0L    # 最近一次 Clear-CacheFolder 释放的字节数
$script:Timer = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------- 定位 Steam / CS2 ----------------
function Find-SteamRoot {
    # 从注册表与默认安装位置收集 Steam 安装根目录
    $roots = @()
    foreach ($regPath in @('HKCU:\Software\Valve\Steam',
                           'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                           'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                # 用属性集合索引代替 $props.$name: 注册表键不保证两个属性都存在
                $prop = $props.PSObject.Properties[$name]
                if ($prop -and $prop.Value) {
                    $v = ([string]$prop.Value).Replace('\\', '\').Trim().Trim('"').TrimEnd('\')
                    if ($v -and (Test-Path -LiteralPath $v)) { $roots += $v }
                }
            }
        } catch {
            Write-Verbose ('跳过不可用的注册表项: ' + $regPath)
        }
    }
    $guess = "${env:ProgramFiles(x86)}\Steam"
    if (Test-Path -LiteralPath $guess) { $roots += $guess }
    return @($roots | Select-Object -Unique)
}

function Find-SteamLibrary {
    # 收集所有 Steam 游戏库根目录 (含 libraryfolders.vdf 里登记的自定义库)
    $libs = @()
    foreach ($r in (Find-SteamRoot)) {
        if (Test-Path -LiteralPath (Join-Path $r 'steam.exe')) { $libs += $r }
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            # vdf 是 UTF-8 编码, 显式指定, 避免中文库路径被按系统 ANSI 代码页误读
            foreach ($line in (Get-Content -LiteralPath $vdf -Encoding UTF8)) {
                if ($line -match '"path"\s+"(.+?)"') {
                    $p = $Matches[1].Replace('\\', '\').Trim('"').TrimEnd('\')
                    if ($p -and (Test-Path -LiteralPath $p)) { $libs += $p }
                }
            }
        }
    }
    return @($libs | Select-Object -Unique)
}

function Find-GameDir {
    # 在每个游戏库里查 appmanifest_<AppId>.acf, 读出 installdir 对应的安装目录
    foreach ($lib in (Find-SteamLibrary)) {
        $acf = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f $AppId)
        if (Test-Path -LiteralPath $acf) {
            $raw = Get-Content -LiteralPath $acf -Raw -Encoding UTF8
            if ($raw -match '"installdir"\s+"([^"]+)"') {
                $dir = Join-Path $lib ('steamapps\common\' + $Matches[1])
                if (Test-Path -LiteralPath $dir) { return $dir }
            }
        }
        $known = Join-Path $lib ('steamapps\common\' + $script:KnownGameDirName)
        if (Test-Path -LiteralPath $known) { return $known }
    }
    return $null
}

# ---------------- 清理辅助 ----------------
function Get-DirSize {
    # 返回目录总字节数 (目录不存在或为空时返回 0)
    param([string]$Path)
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if (-not $s) { $s = 0 }
    return $s
}

function Clear-CacheFolder {
    # 清空一个缓存目录的全部内容; 返回目录是否存在 (被占用的项会跳过并提示)
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $sizeBefore = Get-DirSize $Path
    $failed = 0
    foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $item.FullName) { $failed++ }
    }
    $freed = $sizeBefore - (Get-DirSize $Path)
    $script:LastFreed = $freed
    $script:TotalFreed += $freed
    if ($failed -gt 0) {
        Write-Ok ('清理 {0} : 释放 {1:N1} MB ; {2} 项被占用暂时跳过' -f $Path, ($freed / 1MB), $failed)
    } else {
        Write-Ok ('清理 {0} : 释放 {1:N1} MB' -f $Path, ($freed / 1MB))
    }
    return $true
}

# ================= 界面辅助 =================
# 注意: 控制台中文字符占 2 列, 含中文的对齐必须按"显示宽度"计算,
#       否则边框会错位; 制表符 (─ │ ╔ ╗ 等) 在常用控制台字体下按 1 列渲染。
# 符号 √ × · → 均为 GBK 收录字符, 中文 Windows 控制台字体都能正常显示。

function Get-DispWidth {
    # 计算字符串在控制台中的显示宽度 (CJK 全角字符按 2 列计)
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or
            ($c -ge 0x3000 -and $c -le 0x303E)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

function Format-PaddedText {
    # 按"显示宽度"补空格到指定宽度; 传 -Center 时居中
    param([string]$Text, [int]$Width, [switch]$Center)
    $pad = $Width - (Get-DispWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    if ($Center) {
        $left = [int][math]::Floor($pad / 2)
        return (' ' * $left) + $Text + (' ' * ($pad - $left))
    }
    return $Text + (' ' * $pad)
}

function Write-Line {
    # 无标签的普通输出行 (缩进 2 格)
    param([string]$Text, [ConsoleColor]$Color = 'Gray')
    Write-Host ('  ' + $Text) -ForegroundColor $Color
}

function Write-Status {
    # 带彩色符号标签的状态行: [√] / [i] / [!] / [×]
    param([string]$Tag, [ConsoleColor]$Color, [string]$Text)
    Write-Host ('    [' + $Tag + '] ') -ForegroundColor $Color -NoNewline
    Write-Host $Text
}

function Write-Ok   { param([string]$Text) Write-Status -Tag '√' -Color 'Green'  -Text $Text }
function Write-Info { param([string]$Text) Write-Status -Tag 'i' -Color 'Gray'   -Text $Text }
function Write-Warn { param([string]$Text) Write-Status -Tag '!' -Color 'Yellow' -Text $Text }
function Write-Err  { param([string]$Text) Write-Status -Tag '×' -Color 'Red'    -Text $Text }

function Write-Phase {
    # 分步标题: ── [n/6] 步骤名 ─────────
    param([string]$Label)
    $dash = $script:UIWidth - 5 - (Get-DispWidth $Label) - 1
    if ($dash -lt 4) { $dash = 4 }
    Write-Host ''
    Write-Host '  ── ' -ForegroundColor Cyan -NoNewline
    Write-Host $Label -ForegroundColor Yellow -NoNewline
    Write-Host (' ' + ('─' * $dash)) -ForegroundColor Cyan
}

function Write-Banner {
    # 开场横幅 (双线框, 内容按显示宽度居中; 版本号放框下方小字)
    $w = $script:UIWidth - 4
    Write-Host ''
    Write-Host ('  ╔' + ('═' * $w) + '╗') -ForegroundColor Cyan
    Write-Host '  ║' -ForegroundColor Cyan -NoNewline
    Write-Host (Format-PaddedText 'CS2 着色器缓存一键重建工具' $w -Center) -ForegroundColor White -NoNewline
    Write-Host '║' -ForegroundColor Cyan
    Write-Host '  ║' -ForegroundColor Cyan -NoNewline
    Write-Host (Format-PaddedText '重建着色器缓存, 修复更新后掉帧卡顿' $w -Center) -ForegroundColor Gray -NoNewline
    Write-Host '║' -ForegroundColor Cyan
    Write-Host ('  ╚' + ('═' * $w) + '╝') -ForegroundColor Cyan
    $meta = 'v' + $script:Version + ' · 仅支持 Windows + Steam 版 CS2'
    Write-Host ('  ' + (Format-PaddedText $meta $w -Center)) -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Callout {
    # 重要信息提示框 (宽度按显示宽度对齐)
    param([string[]]$Lines, [ConsoleColor]$Color = 'Yellow')
    $inner = $script:UIWidth - 6
    Write-Host ''
    Write-Host ('  ┌' + ('─' * ($inner + 2)) + '┐') -ForegroundColor $Color
    foreach ($t in $Lines) {
        Write-Host '  │ ' -ForegroundColor $Color -NoNewline
        Write-Host (Format-PaddedText $t $inner) -ForegroundColor $Color -NoNewline
        Write-Host ' │' -ForegroundColor $Color
    }
    Write-Host ('  └' + ('─' * ($inner + 2)) + '┘') -ForegroundColor $Color
}

function Read-Input {
    # 读取一行输入。提示符必须由 Read-Host 自己带: Read-Host '' 会抛
    # "name cannot be null or empty" 且是【非终止错误】, 关卡会被无声跳过。
    param([string]$Message)
    return (Read-Host ('    → ' + $Message))
}

function Wait-Enter {
    # 等待用户按回车; 演练模式下自动继续
    param([string]$Message)
    if ($script:DryRun) { Write-Info ('(演练) 自动继续: ' + $Message); return }
    Read-Input $Message | Out-Null
}

function Confirm-YesNo {
    # 询问是/否, 回车默认为是; 演练模式下自动选是
    param([string]$Message)
    if ($script:DryRun) { Write-Info '(演练) 自动选择: 是'; return $true }
    $a = Read-Input ($Message + ' [回车=是, n=否]')
    return ($a -eq '' -or $a -match '^(y|yes|是)$')
}

function Wait-Exit {
    # 出错时提示并退出 (退出码 1)
    if (-not $script:DryRun) { Read-Input '按回车键退出' | Out-Null }
    exit 1
}

function Read-StartStep {
    # 开场菜单: 回车=从第 1 步全流程; 输入编号=从该步开始 (等 Steam 校验很慢, 常需回来接着跑)
    param([int]$Max)
    if ($script:DryRun) { Write-Info '(演练) 自动从第 1 步开始'; return 1 }
    while ($true) {
        $a = Read-Input ('从第几步开始? [回车=从 1 全流程, 可输入 1-' + $Max + ']')
        if ($a -eq '') { return 1 }
        $n = 0
        if ([int]::TryParse($a.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Max) { return $n }
        Write-Warn ('没看懂 "' + $a + '" 是什么步骤, 请输入 1-' + $Max + ' 之间的数字 (回车=从 1 全流程)')
    }
}

function Test-Step {
    # 编号步骤是否需要执行; 起始步骤之后的都会被跳过
    param([int]$N)
    return ($script:StartStep -le $N)
}

function Add-Summary { param([string]$Text) $script:Summary.Add($Text) }

# ================= 主流程 =================
try { $Host.UI.RawUI.WindowTitle = ('CS2 着色器缓存一键重建工具 v' + $script:Version) } catch {
    Write-Verbose '当前宿主不支持设置窗口标题, 已跳过。'
}

Write-Banner
if ($script:DryRun) { Write-Warn '当前为演练模式 (-DryRun), 不会执行任何实际改动' }

Write-Line '执行流程 (基本全自动, 只需按提示做少数几步操作):' White
$flow = @(
    '移出 core 目录下 shaders* 开头的文件 (先备份, 不直接删)',
    '拉起 Steam 校验文件完整性, 被移出的文件自动重新下载',
    '清理 DirectX 着色器缓存 (可选: 顺带清理显卡驱动缓存)',
    '打开 Steam 控制台, 预编译命令自动复制到剪贴板',
    '启动 CS2, 离线跑图让着色器在游戏内重新编译'
)
for ($i = 0; $i -lt $flow.Count; $i++) {
    $mark = '├─ '
    if ($i -eq $flow.Count - 1) { $mark = '└─ ' }
    Write-Line ($mark + ($i + 1) + '. ' + $flow[$i]) Gray
}
Write-Line '前置检查与定位安装目录每次都会先做, 不占下面的编号。' DarkGray

Write-Host ''
$script:StartStep = Read-StartStep -Max $flow.Count

# ---------- 前置检查 (始终执行: 后面每一步都依赖这里的结果) ----------
Write-Phase '[准备] 前置检查 + 定位 CS2 目录'
if (Get-Process -Name cs2 -ErrorAction SilentlyContinue) {
    Write-Err '检测到 CS2 正在运行, 请先完全退出游戏 (含后台), 再重新运行本工具。'
    Wait-Exit
}
Write-Ok 'CS2 未在运行'
if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
    Write-Ok 'Steam 正在运行'
} else {
    Write-Info 'Steam 未在运行, 后面会自动拉起。'
}

# ---------- 定位 CS2 安装目录 ----------
$gameDir = Find-GameDir
if (-not $gameDir -and $script:DryRun) {
    # 演练模式下若本机没装 CS2, 用临时目录模拟, 以便完整演示流程
    $script:FakeTest = $true
    $gameDir = Join-Path $env:TEMP 'CS2ShaderTool_SelfTest'
    New-Item -ItemType Directory -Path (Join-Path $gameDir 'game\core') -Force | Out-Null
    1..3 | ForEach-Object {
        Set-Content -Path (Join-Path $gameDir ('game\core\shaders_lib_test' + $_ + '.dll')) -Value ('dummy' * 4096)
    }
    Write-Info ('(演练) 本机未找到 CS2, 使用临时目录模拟: ' + $gameDir)
}
if (-not $gameDir) {
    Write-Err ('未能自动定位 CS2 (Steam AppId=' + $AppId + ') 的安装目录。')
    $manual = Read-Input '请输入 CS2 安装目录路径 (可把文件夹直接拖进本窗口): '
    $manual = $manual.Trim().Trim('"')
    if ($manual -and (Test-Path -LiteralPath (Join-Path $manual 'game\core'))) {
        $gameDir = $manual
    } else {
        Write-Err '该目录下找不到 game\core, 请确认是 ...\steamapps\common\Counter-Strike Global Offensive'
        Wait-Exit
    }
}
$coreDir = Join-Path $gameDir 'game\core'
if (-not (Test-Path -LiteralPath $coreDir)) {
    Write-Err ('未找到 core 目录: ' + $coreDir)
    Wait-Exit
}
Write-Ok ('CS2 目录: ' + $gameDir)
if ($script:StartStep -gt 1) {
    Write-Warn ('按选择从第 ' + $script:StartStep + ' 步开始, 已跳过第 1-' + ($script:StartStep - 1) + ' 步 (视为已完成)')
}

# ---------- 步骤 1: 移出 core 下 shaders* 文件 ----------
if (Test-Step 1) {
    Write-Phase '[1/5] 移出 game\core 下 shaders* 开头的文件'
    $shaderFiles = @(Get-ChildItem -LiteralPath $coreDir -Filter 'shaders*' -File -ErrorAction SilentlyContinue)
    if ($shaderFiles.Count -eq 0) {
        Write-Info '未发现 shaders* 文件 (可能此前已删除, 等待校验时重新下载即可)。'
    } else {
        $totalLen = ($shaderFiles | Measure-Object -Property Length -Sum).Sum
        if (-not $totalLen) { $totalLen = 0 }
        Write-Line ('发现 {0} 个文件, 共 {1:N1} MB:' -f $shaderFiles.Count, ($totalLen / 1MB)) White
        $nameW = 0
        foreach ($f in $shaderFiles) {
            $lw = Get-DispWidth $f.Name
            if ($lw -gt $nameW) { $nameW = $lw }
        }
        $nameW += 2
        foreach ($f in $shaderFiles) {
            Write-Line ('  - ' + (Format-PaddedText $f.Name $nameW) + ('{0,8:N1} MB' -f ($f.Length / 1MB))) Gray
        }
        if ($script:FakeTest) {
            # 演练且目录为临时模拟: 实际执行移动以自测逻辑
            $backupDir = Join-Path $gameDir ('core_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $moved = 0
            foreach ($f in $shaderFiles) {
                try {
                    Move-Item -LiteralPath $f.FullName -Destination $backupDir -Force -ErrorAction Stop
                    $moved++
                } catch {
                    Write-Err ('无法移动: ' + $f.Name + ' —— ' + $_.Exception.Message)
                }
            }
            Write-Ok ('(演练自测) 已移出 ' + $moved + ' 个文件到: ' + $backupDir)
        } elseif ($script:DryRun) {
            Write-Info '(演练) 将把这些文件移动到备份目录, 而不是直接永久删除'
        } else {
            $backupDir = Join-Path $env:LOCALAPPDATA ('CS2ShaderCacheTool\backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $moved = 0
            foreach ($f in $shaderFiles) {
                try {
                    Move-Item -LiteralPath $f.FullName -Destination $backupDir -Force -ErrorAction Stop
                    $moved++
                } catch {
                    Write-Err ('无法移动: ' + $f.Name + ' —— ' + $_.Exception.Message)
                    Write-Info '若提示拒绝访问, 请右键本工具选择"以管理员身份运行"。'
                }
            }
            Write-Ok ('已移出 ' + $moved + ' 个文件到备份目录 (见下方路径):')
            Write-Line $backupDir White
            Add-Summary ('已移出 ' + $moved + ' 个 shaders 文件, 备份在 ' + $backupDir)
            Write-Info '这些文件稍后由 Steam 校验自动重新下载; 备份仅用于应急还原。'
        }
    }
}

# ---------- 步骤 2: Steam 校验完整性 ----------
if (Test-Step 2) {
    Write-Phase '[2/5] Steam 校验 CS2 文件完整性'
    if ($script:DryRun) {
        Write-Info ('(演练) 将打开 steam://validate/' + $AppId)
    } else {
        Start-Process ('steam://validate/' + $AppId)
        Write-Ok '已请求 Steam 开始校验 (若 Steam 未启动会自动拉起)。'
        Write-Info '请切到 Steam 窗口等校验完成, 刚才移出的文件会自动重新下载。'
        Wait-Enter '校验完成后回到本窗口, 按回车继续'
        Add-Summary '已请求 Steam 校验 CS2 文件完整性'
    }
}

# ---------- 步骤 3: 清理着色器缓存 ----------
if (Test-Step 3) {
    Write-Phase '[3/5] 清理着色器缓存'
    $dxCache = Join-Path $env:LOCALAPPDATA 'Microsoft\DirectX Shader Cache'
    if ($script:DryRun) {
        if (Test-Path -LiteralPath $dxCache) {
            Write-Info ('(演练) 将清理: ' + $dxCache + ' (' + ('{0:N1} MB' -f ((Get-DirSize $dxCache) / 1MB)) + ')')
        } else {
            Write-Info '(演练) 未找到 DirectX Shader Cache 目录 (该项无需清理)'
        }
    } else {
        if (Clear-CacheFolder $dxCache) {
            Add-Summary ('清理 DirectX 着色器缓存, 释放 {0:N1} MB' -f ($script:LastFreed / 1MB))
        } else {
            Write-Info '未找到 DirectX Shader Cache 目录 (该项无需清理)。'
        }
    }

    $vendorCaches = @(
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NV_Cache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxcCache'),
        (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')
    )
    $foundCaches = @()
    foreach ($vc in $vendorCaches) {
        if (Test-Path -LiteralPath $vc) { $foundCaches += $vc }
    }
    if ($foundCaches.Count -eq 0) {
        Write-Info '未检测到显卡驱动 (NVIDIA/AMD/Intel) 着色器缓存, 该项自动跳过。'
    } else {
        Write-Line ('检测到 {0} 个显卡驱动着色器缓存:' -f $foundCaches.Count) White
        foreach ($vc in $foundCaches) {
            $short = $vc.Substring($env:LOCALAPPDATA.Length + 1)
            Write-Line ('  - ' + (Format-PaddedText $short 30) + ('{0,8:N1} MB' -f ((Get-DirSize $vc) / 1MB))) Gray
        }
        if (Confirm-YesNo '是否一并清理? 更彻底, 但其他游戏首次启动时会重新编译着色器') {
            if ($script:DryRun) {
                foreach ($vc in $foundCaches) { Write-Info ('(演练) 将清理: ' + $vc) }
            } else {
                $freedBefore = $script:TotalFreed
                foreach ($vc in $foundCaches) { Clear-CacheFolder $vc | Out-Null }
                Add-Summary ('清理显卡驱动着色器缓存, 释放 {0:N1} MB' -f (($script:TotalFreed - $freedBefore) / 1MB))
            }
        }
    }
}

# ---------- 步骤 4: Steam 控制台预编译 ----------
if (Test-Step 4) {
    Write-Phase '[4/5] Steam 控制台预编译着色器'
    $buildCmd = 'shader_build ' + $AppId
    if ($script:DryRun) {
        Write-Info ('(演练) 将打开 steam://open/console, 并把命令复制到剪贴板: ' + $buildCmd)
    } else {
        Start-Process 'steam://open/console'
        Write-Ok '已打开 Steam 控制台。'
        Add-Summary '已打开 Steam 控制台'
        $copied = $false
        try {
            Set-Clipboard -Value $buildCmd
            $copied = $true
        } catch {
            Write-Verbose ('无法访问剪贴板: ' + $_.Exception.Message)
        }
        if ($copied) {
            Write-Callout -Lines @(
                ('命令已复制到剪贴板:  ' + $buildCmd),
                '在 Steam 控制台底部输入框按 Ctrl+V 粘贴, 回车执行'
            ) -Color Yellow
        } else {
            Write-Callout -Lines @(
                ('请在 Steam 控制台底部输入框输入:  ' + $buildCmd),
                '输入后按回车执行, Steam 会自动为 CS2 预编译着色器'
            ) -Color Yellow
        }
        Wait-Enter '执行完成后回到本窗口, 按回车继续'
    }
}

# ---------- 步骤 5: 启动游戏跑图 ----------
if (Test-Step 5) {
    Write-Phase '[5/5] 启动 CS2, 游戏内重建着色器'
    Write-Callout -Lines @(
        '重要: 着色器必须在游戏内重新编译才会生效!',
        '启动 CS2 后请先打 1-2 局离线 (人机/跑图), 把常用地图跑一遍,',
        '否则实战中仍可能出现掉帧!'
    ) -Color Yellow
    if (Confirm-YesNo '是否现在启动 CS2 ?') {
        if ($script:DryRun) {
            Write-Info ('(演练) 将打开 steam://rungameid/' + $AppId)
        } else {
            Start-Process ('steam://rungameid/' + $AppId)
            Write-Ok '已请求 Steam 启动 CS2。'
            Add-Summary '已请求 Steam 启动 CS2'
        }
    }
}

# ---------- 运行摘要 ----------
Write-Phase '运行摘要'
if ($script:Summary.Count -gt 0) {
    foreach ($s in $script:Summary) { Write-Line ('· ' + $s) Gray }
} else {
    Write-Info '(本次无实际改动)'
}
if (-not $script:DryRun) {
    $t = $script:Timer.Elapsed
    if ($t.TotalMinutes -ge 1) {
        $timeText = ('{0} 分 {1} 秒' -f [int]$t.TotalMinutes, $t.Seconds)
    } else {
        $timeText = ('{0} 秒' -f [int][math]::Round($t.TotalSeconds))
    }
    $foot = '总耗时 ' + $timeText
    if ($script:TotalFreed -gt 0) { $foot = ('累计释放 {0:N1} MB  ·  ' -f ($script:TotalFreed / 1MB)) + $foot }
    Write-Host ''
    Write-Host ('  ' + $foot) -ForegroundColor Cyan
}

Write-Callout -Lines @('√ 全部完成, 祝游戏愉快! 记得先进游戏离线跑图。') -Color Green
Write-Host ''
if (-not $script:DryRun) { Read-Input '按回车键退出' | Out-Null }
exit 0
