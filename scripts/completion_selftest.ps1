#requires -Version 5
<#
    completion_selftest.ps1

    TT/ContentView.swift 里 `CommandDoc.optionList` + `InputParser` + `completions(for:`
    的 PowerShell 等价移植。本机没有 Swift 编译器，但这套逻辑是纯字符串处理，
    搬过来就能跑——「ls 后面为什么不出 -l」就是靠它一次抓出来的。

    抓到的真 bug：
        Swift 原来写的是
            .filter { $0.hasPrefix("-") }
            .map { 去方括号 }
        而手册里选项几乎都写成 `[-l]` 这种带方括号的占位形式，
        `"[-l]".hasPrefix("-")` 是 false —— 全部 32 条命令的 optionList 都返回空数组。
        顺序必须是「先剥方括号，再判断是不是选项」。

        第二个坑：剥完方括号还得**按 `|` 再拆一次**。
        `id [-u|-g|-G|-n]` 里 `|` 是「同一位置只能选其一」，
        不拆的话整块会变成一个名叫 `-u|-g|-G|-n` 的选项，候选条上显示成一根粘死的糊条。
        顺序：先剥方括号，再拆 `|`（反过来会留下 `[-u` 这种带括号的碎片）。

    ⚠️ **这是 Swift 的移植版，两边分叉过一次（2026-10-13）。**
        Swift 的 `CommandDoc.optionList` 漏了按 `|` 拆，本脚本照样 33 例全绿——
        因为它测的是 PowerShell 这边，够不着 Swift。
        **改 Swift 的同一段逻辑时必须同步改这里，否则绿灯是假的。**

    用法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\completion_selftest.ps1
#>

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'TT\ContentView.swift'
$src = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)

# ---------------------------------------------------------------- 移植层

# 从源码里抠出所有 CommandDoc(name:, syntax:)
$docs = @()
foreach ($m in [regex]::Matches($src, 'CommandDoc\(name:\s*"([^"]*)",\s*syntax:\s*"((?:[^"\\]|\\.)*)"')) {
    $docs += [pscustomobject]@{ name = $m.Groups[1].Value; syntax = $m.Groups[2].Value }
}

function Get-OptionList([string]$syntax) {
    $first = ($syntax -split ' / ')[0]
    if (-not $first) { $first = $syntax }
    $out = @()
    foreach ($tok in ($first -split ' ')) {
        if ($tok -eq '') { continue }
        $t = $tok -replace '[\[\]]', ''
        $t = $t.Trim()
        # 先剥方括号，再按 `|` 拆（顺序不能反）。顺序同 Swift 里的 optionList。
        foreach ($piece in ($t -split '\|')) {
            if ($piece.Length -gt 1 -and $piece.StartsWith('-')) { $out += $piece.Trim() }
        }
    }
    return $out
}

function Parse-Input([string]$command) {
    if ($command.Length -eq 0) { return @{ words = @(); token = '' } }
    $last = $command[$command.Length - 1]
    $endsWithSep = ($last -eq ' ' -or $last -eq "`t" -or $last -eq "`n")
    $cleaned = if ($endsWithSep) { $command.Substring(0, $command.Length - 1) } else { $command }
    $segments = @($cleaned -split ' ' | Where-Object { $_ -ne '' })
    if ($endsWithSep) { return @{ words = $segments; token = '' } }
    if ($segments.Count -eq 0) { return @{ words = @(); token = $cleaned } }
    $words = @(); if ($segments.Count -gt 1) { $words = @($segments[0..($segments.Count - 2)]) }
    return @{ words = $words; token = $segments[-1] }
}

function Get-Completions([string]$cmdText) {
    $p = Parse-Input $cmdText
    $commandName = if ($p.words.Count -gt 0) { $p.words[0] } else { '' }
    $token = $p.token
    if ($commandName -ne '') {
        if (-not ($token -eq '' -or $token.StartsWith('-'))) { return @() }
        $doc = $docs | Where-Object { $_.name -eq $commandName } | Select-Object -First 1
        if (-not $doc) { return @() }
        if ($p.words.Count -gt 1) {
            foreach ($w in $p.words[1..($p.words.Count - 1)]) {
                if (-not $w.StartsWith('-')) { return @() }
            }
        }
        $token2 = $token
        return @(Get-OptionList $doc.syntax | Where-Object { $token2 -eq '' -or $token2 -eq '-' -or $_.StartsWith($token2) })
    }
    if ($token -eq '') { return @() }
    $lower = $token.ToLower()
    $names = @($docs | ForEach-Object { $_.name })
    return @($names | Where-Object { $_.ToLower().StartsWith($lower) })
}

# ---------------------------------------------------------------- 用例

# @($输入, @($期望候选...))
$cases = @(
    # —— 命令名补全 ——
    @('l',        @('ls')),
    @('ls',       @('ls')),
    @('mk',       @('mkdir')),
    @('tt',       @('ttfork', 'ttprobe')),

    # —— 「命令 + 空格」必须出选项 ——
    @('ls ',      @('-l', '-a')),
    @('mkdir ',   @('-p')),
    @('head ',    @('-n')),
    @('tail ',    @('-n')),
    @('sort ',    @('-n', '-r', '-u')),
    @('grep ',    @('-i', '-v', '-n')),
    @('wc ',      @('-l', '-w', '-c')),
    @('uniq ',    @('-c')),
    @('tr ',      @('-d')),
    @('df ',      @('-h')),
    @('du ',      @('-s', '-h')),
    @('uname ',   @('-a')),
    @('cp ',      @('-r')),
    @('rm ',      @('-f')),
    @('cut ',     @('-d', '-f', '-c')),
    @('find ',    @('-name', '-type')),

    # —— 「`|` 是择一」不能糊成一整条 ——
    @('id ',      @('-u', '-g', '-G', '-n')),
    @('id -',     @('-u', '-g', '-G', '-n')),
    @('id -G',    @('-G')),
    # `nl [-b a|t|n]` / `find [-type f|d]`：带 `|` 的是**另一个** token，不该被拆进选项
    @('nl ',      @('-b')),
    @('find ',    @('-name', '-type')),

    # —— 这些命令本来就没有选项，必须是空 ——
    @('cat ',     @()),
    @('mv ',      @()),
    @('touch ',   @()),
    @('stat ',    @()),
    @('echo ',    @()),
    @('cd ',      @()),
    @('pwd ',     @()),
    @('date ',    @()),
    @('dirname ', @()),
    @('basename ', @()),

    # —— 补到一半的选项 ——
    @('ls -',     @('-l', '-a')),
    @('ls -l',    @('-l')),

    # —— 叠第二个选项 ——
    @('ls -l ',   @('-l', '-a')),

    # —— 已经打过真参数就不再出选项 ——
    @('sort abc.txt ', @()),
    @('cat file ',    @())
)

# ------------------------------------------------------- 路径补全白名单自检

# 第二个 bug 是这么漏出去的：`optionList` 这套逻辑从引进那天起就有测试，
# 但**路径补全的准入名单从来没有对过任何测试**。
# 结果 `dirname /et`、`basename /et` 一个候选都不出，看着像「候选条坏了」。
#
# 这里直接从源码里把名单抠出来，再跟「手册里哪些命令确实吃路径」对账。
# 对不上就红——新增一个吃路径的命令却忘了登记名字，这类漏网就抓得住。

function Get-PathGate([string]$varName) {
    $m = [regex]::Match($src, ('(?s)let\s+' + $varName + ':\s*Set<String>\s*=\s*\[(.*?)\]'))
    if (-not $m.Success) { throw ('抠不出 ' + $varName) }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
}

$dirOnly = Get-PathGate 'directoryOnly'
$anyEntry = Get-PathGate 'anyEntry'

# 手册里哪些命令的参数**确实是路径**。
#
# 不再手工维护这份清单 —— **从手册的 syntax 自动推**：凡是 syntax 里写了
# 「文件 / 路径 / 目录」的，就一定吃路径，就必须登记。
#
# 为什么改自动：手工清单漏过一次，而且漏得很有欺骗性——
# `tee ` 能补出 `-a`（走**选项**那条路），于是看着「补全是好的」，
# 可 `tee /e` 一个候选都不出（路径那条路在名单检查那里就 return 了）。
# **两条路是分开的，别用前者证明后者。** 手工清单不会告诉你「你漏了谁」。
$shouldAcceptPath = @(
    $docs | Where-Object { $_.syntax -match '文件|路径|目录' } |
        ForEach-Object { $_.name } | Sort-Object -Unique
)
# 反向豁免：确实写了路径字样、但**不该**给路径候选的。
# 现在是空的；将来有了就写在这里，并在旁边写清楚理由。
$pathExempt = @()

$gate = @($dirOnly + $anyEntry)

Write-Host ''
Write-Host '路径补全白名单 —— 吃路径的命令必须能被补出候选' -ForegroundColor Cyan
Write-Host ('  directoryOnly = {0}' -f ($dirOnly -join ' ')) -ForegroundColor DarkGray
Write-Host ('  anyEntry      = {0}' -f ($anyEntry -join ' ')) -ForegroundColor DarkGray
Write-Host ('  从手册自动推得 {0} 条吃路径的命令' -f $shouldAcceptPath.Count) -ForegroundColor DarkGray

$gateFail = @()
foreach ($name in $shouldAcceptPath) {
    if ($pathExempt -contains $name) { continue }
    if ($gate -contains $name) {
        Write-Host ('  [通过] {0}' -f $name) -ForegroundColor DarkGreen
    }
    else {
        $gateFail += $name
        Write-Host ('  [失败] {0,-10} 手册语法写了文件/路径/目录，但不在白名单里 —— 打 `{1} /e` 一个候选都不会出' -f $name, $name) -ForegroundColor Red
    }
}
# 反向：白名单里不该有不存在的命令（拼错的命令名等于这条永久失效）
foreach ($name in $gate) {
    if ($docs | Where-Object { $_.name -eq $name }) { continue }
    $gateFail += $name
    Write-Host ('  [失败] 白名单里的 {0} 手册中不存在' -f $name) -ForegroundColor Red
}
# 名单不能是空的：抠不出东西时下面「不在白名单里」会**全部通过**，绿灯是假的
if ($gate.Count -lt 10) {
    $gateFail += '(名单为空或过短)'
    Write-Host ('  [失败] 名单只抠到 {0} 条，抠空会让上面这批检查变成假绿' -f $gate.Count) -ForegroundColor Red
}
Write-Host ''

Write-Host ''
Write-Host '补全自检 —— optionList / InputParser / completions 的 PowerShell 移植' -ForegroundColor Cyan
Write-Host ('从 {0} 解析出 {1} 条手册条目' -f (Split-Path -Leaf $sourcePath), $docs.Count)
Write-Host ''

$pass = 0; $fail = @()

# ---------------------------------------------------------------- 结构性守卫
# 守的是 2026-10-14 修掉的两个「静默失效」类 bug。它们**不崩、不报错**，
# 只是安静地给错结果（补全莫名其妙全没了 / 诊断给不出答案），所以只能靠源码断言守。
#
# ⚠️ 这类检查只能保证「那行代码不在了」，**保证不了替换它的实现是对的**。
#    真正的验证仍然是真机跑一遍功能自检清单。
# 这个脚本没有 `Check`（那两个有，这里没有），断言统一走这两个。
function Check([string]$name, [bool]$ok, [string]$why = '') {
    if ($ok) {
        $script:pass++
        Write-Host ("  [通过] {0}" -f $name) -ForegroundColor DarkGreen
    } else {
        $script:fail += $name
        Write-Host ("  [失败] {0}{1}" -f $name, $(if ($why) { "  ← $why" } else { '' })) -ForegroundColor Red
    }
}

function Check-Source([string]$name, [string]$needle, [bool]$shouldExist) {
    # 这个脚本读源码的变量叫 `$src`（不是 `$source`——那是 capability_selftest 里的名字）
    $found = $src.Contains($needle)
    if ($found -eq $shouldExist) {
        $script:pass++
        Write-Host ("  [通过] {0}" -f $name) -ForegroundColor DarkGreen
    } else {
        $script:fail += $name
        $mark = if ($shouldExist) { '源码里已经找不到了' } else { '源码里又出现了' }
        Write-Host ("  [失败] {0,-30} {1}" -f $name, $mark) -ForegroundColor Red
    }
}

Write-Host '── 结构性守卫：两处「静默失效」不能退回旧写法 ──' -ForegroundColor Cyan
$guardCases = 12
# ① listing() 把「列不出来」的空结果当事实缓存住 → 一次失败永久固化
Check-Source '空结果不进缓存'   'if !result.isEmpty {' $true
Check-Source '失败提前返回'      '// 列不出来：返回空，但**不写缓存**' $true
# ② ttdebug 的「路径候选数」被 `if input == command` 关掉，三种用法下全是 false
Check-Source '诊断不再条件化'   '别再改回条件判断' $true
Check-Source '诊断当场探测'     '当场探一次（同步，不受防抖与过期丢弃影响）' $true
Check-Source '别退回旧条件'     'if input == command {' $false

# ③ 手册的三个分区。这条**能静态查**，所以不该留在真机自检里靠人看。
#    少一个分区不会崩、不会报错，只是「测试清单」那个页签不见了。
$vm = [regex]::Match($src, '(?s)enum\s+ViewMode\s*:\s*Int[^{]*\{(.*?)\}')
$vmCases = if ($vm.Success) { @([regex]::Matches($vm.Groups[1].Value, 'case\s+(\w+)') | ForEach-Object { $_.Groups[1].Value }) } else { @() }
Check 'ViewMode 抠到且有 3 个 case' ($vmCases.Count -eq 3) "抠到 $($vmCases.Count) 个：$($vmCases -join ' ')，抠空会让下面变假绿"
foreach ($c in @('category', 'alphabet', 'test')) {
    Check ("分区 $c 有对应 case") ($vmCases -contains $c) "少了它就有一个页签消失"
}
foreach ($c in $vmCases) {
    # 每个 case 都必须在 Picker 里真的被 tag 出来，否则是死 case
    Check ("分区 $c 被 Picker 用到") ($src -match ("Text\([^)]*\)\.tag\(ViewMode\.$c\)")) '在 ViewMode 里声明了但没挂到 Picker 上'
}
Write-Host ''

foreach ($c in $cases) {
    $input = $c[0]
    $expect = @($c[1])
    $got = @(Get-Completions $input)

    # `l` 这类前缀可能命中多条，只要**包含**全部期望项就算过
    $ok = $true
    foreach ($e in $expect) {
        if ($got -notcontains $e) { $ok = $false }
    }
    if ($expect.Count -eq 0 -and $got.Count -ne 0) { $ok = $false }

    if ($ok) {
        $pass++
        Write-Host ('  [通过] {0,-16} → {1}' -f $input, ($got -join ' ')) -ForegroundColor DarkGreen
    }
    else {
        $fail += $input
        Write-Host ('  [失败] {0,-16} → 得到 [{1}]  期望 [{2}]' -f $input, ($got -join ' '), ($expect -join ' ')) -ForegroundColor Red
    }
}

Write-Host ''
$total = $cases.Count + $gateFail.Count + $guardCases
# $guardCases 是上面「结构性守卫」那批的条数，必须计入分母，
# 否则会出现「45/40」这种通过数大于总数的情况——看着像加错了，其实是把新用例漏算了。
if ($fail.Count -eq 0 -and $gateFail.Count -eq 0) {
    Write-Host ('全部通过：{0}/{1}' -f $pass, $total) -ForegroundColor Green
    exit 0
}
else {
    Write-Host ('{0} 条失败，{1} 条通过' -f ($fail.Count + $gateFail.Count), $pass) -ForegroundColor Red
    foreach ($f in $fail) { Write-Host ('  · 输入 `{0}`' -f $f) -ForegroundColor Red }
    foreach ($f in $gateFail) { Write-Host ('  · 路径白名单 `{0}`' -f $f) -ForegroundColor Red }
    exit 1
}
