# CapabilityProbe（权限检测报告）的静态自检。
#
# 为什么只查「清单」不查行为：
#   权限探针的逻辑全是 `access()` / `FileManager` / 真正的建文件再删掉，
#   **本机是 Windows、没有 iOS 容器，这些行为一条都跑不了**，只能真机验。
#   但它依赖的**两份清单是纯数据**，可以静态守住——而这两份清单恰恰是
#   出过 bug 的地方（2026-10-13）。
#
# 抓到的真 bug：
#   `/usr/libexec` 被放进了越狱痕迹表。它在**原版 iOS 上本来就存在**
#   （ldid、symptomsd 等），跟越狱无关。结果是每台**未越狱**的机器都被报成
#   「发现 1 项越狱痕迹」——不是多一行，是**整份报告的结论不可信**。
#   真机报告里 `有 /usr/libexec` 就是它。
#
# 守住的原则：**越狱痕迹表里只准放「原版 iOS 上一定不存在」的路径。**
#
# 必须存 UTF-8 BOM：PS 5.1 按 GBK 读无 BOM 的脚本，中文会变乱码。
# 不能用 $input 作形参（PowerShell 自动变量）。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'TT\ContentView.swift'
$source = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)

$passed = 0
$failed = 0

function Check([string]$name, [bool]$ok, [string]$why = '') {
    if ($ok) {
        $script:passed++
        Write-Host ("  [通过] {0}" -f $name) -ForegroundColor DarkGreen
    } else {
        $script:failed++
        Write-Host ("  [失败] {0}{1}" -f $name, $(if ($why) { "  ← $why" } else { '' })) -ForegroundColor Red
    }
}

# 从源码里抠出 Swift 数组字面量的内容
#
# ⚠️ `=\s*\[` 前面必须容得下空格：源码里写的是 `let jailbreakMarkers = [`，
#    正则写成 `(?::[^=]+)?=` 的话，紧跟在名字后面就找不到 `=`，三份清单全抠成空。
#    抠空更糟的是「不该含有 X」那批检查会**全部通过**（空数组当然不含任何东西），
#    绿灯是假的。所以下面紧接着有一条「清单不能为空」的兜底。
function Get-SwiftArray([string]$varName) {
    $m = [regex]::Match($source, ('(?s)let\s+' + [regex]::Escape($varName) + '\s*(?::[^=\[]+)?=\s*\[(.*?)\]'))
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}

$markers = @(Get-SwiftArray 'jailbreakMarkers')
$probePaths = @(Get-SwiftArray 'probePaths')
$binaryDirs = @(Get-SwiftArray 'binaryDirs')

Write-Host ''
Write-Host 'CapabilityProbe 静态自检 —— 权限检测报告的清单' -ForegroundColor Cyan
Write-Host ('  越狱痕迹 {0} 条 / 探测路径 {1} 条 / 二进制目录 {2} 条' -f $markers.Count, $probePaths.Count, $binaryDirs.Count) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- 先验清单本身抠到了
# 没有这一步，抠空会让「不该含有」那批检查**全部通过**——
# 空数组不含任何东西，绿灯是假的。这正是本脚本第一版犯的错。
Check '抠到越狱痕迹表且非空' ($markers.Count -ge 5) "只抠到 $($markers.Count) 条，抠空会让下面一半检查变成假绿"
Check '抠到探测路径表且非空' ($probePaths.Count -ge 10) "只抠到 $($probePaths.Count) 条"
Check '抠到二进制目录表且非空' ($binaryDirs.Count -ge 3) "只抠到 $($binaryDirs.Count) 条"

# ---------------------------------------------------------------- 越狱痕迹表
# 原版 iOS 上**一定存在**的路径。混进越狱痕迹表 = 每台正常机器都被误报。
$alwaysPresentOnStockiOS = @(
    '/usr/libexec'   # ldid、symptomsd 等，真机报告证实未越狱机器上也有
    '/usr/lib'
    '/System'
    '/private'
    '/var'
    '/bin'
    '/sbin'
    '/usr/bin'
    '/usr/sbin'
    '/Library'
)

foreach ($path in $alwaysPresentOnStockiOS) {
    Check ("痕迹表不含原版必有的 $path") ($markers -notcontains $path) '它在原版 iOS 上存在，会造成误判'
}

# 反向：真正的越狱痕迹一个都不能少（少了就是漏检）
$mustHaveMarkers = @(
    '/var/jb', '/private/var/jb', '/bin/bash', '/etc/apt',
    '/Library/MobileSubstrate', '/Applications/Cydia.app', '/bin/zsh'
)
foreach ($path in $mustHaveMarkers) {
    Check ("痕迹表仍含 $path") ($markers -contains $path) '少了它就漏检了'
}

# 痕迹表里不该出现可执行文件目录（那是 binaryDirs 的职责）
foreach ($dir in @('/usr/libexec', '/bin', '/usr/bin')) {
    Check ("痕迹表不含系统二进制目录 $dir") ($markers -notcontains $dir) '它属于 binaryDirs，放这里必然误判'
}

# ---------------------------------------------------------------- 探测路径表
# `/lib` 是 macOS 才有的（软链到 /usr/lib），iOS 上不存在。
# 留着它不是错（报告现在会明确写「不存在」），但必须由 paths() 区分「不存在」与「不可」。
Check 'paths() 区分「不存在」' ($source -match '不存在') '否则 /lib 会显示成「不可」，看着像有但没权限'

# ---------------------------------------------------------------- 二进制目录
# /usr/libexec 从痕迹表挪走后，仍然必须留在 binaryDirs 里（要列它里面的可执行文件）
Check 'binaryDirs 仍含 /usr/libexec' ($binaryDirs -contains '/usr/libexec') '它不是越狱痕迹，是系统可执行文件目录'

# ---------------------------------------------------------------- 结论措辞
Check '结论写明「查不到≠没越狱」' ($source -match '不等于') '越狱方式可能不落在这些路径上'

Write-Host ''
if ($failed -eq 0) {
    Write-Host ("全部通过：{0}/{0}" -f $passed) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 {0} 条，通过 {1} 条" -f $failed, $passed) -ForegroundColor Red
    exit 1
}