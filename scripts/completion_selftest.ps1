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

# 手册里哪些命令的参数**确实是路径**。手工维护，但每加一条新工具就顺手核对一次。
$shouldAcceptPath = @(
    'ls', 'cat', 'cp', 'mv', 'rm', 'touch', 'stat',
    'head', 'tail', 'wc', 'grep', 'du',
    'basename', 'dirname'
)
$gate = @($dirOnly + $anyEntry)

Write-Host ''
Write-Host '路径补全白名单 —— 吃路径的命令必须能被补出候选' -ForegroundColor Cyan
Write-Host ('  directoryOnly = {0}' -f ($dirOnly -join ' ')) -ForegroundColor DarkGray
Write-Host ('  anyEntry      = {0}' -f ($anyEntry -join ' ')) -ForegroundColor DarkGray

$gateFail = @()
foreach ($name in $shouldAcceptPath) {
    if ($gate -contains $name) {
        Write-Host ('  [通过] {0}' -f $name) -ForegroundColor DarkGreen
    }
    else {
        $gateFail += $name
        Write-Host ('  [失败] {0,-10} 吃路径但不在白名单里，打 `dirname /et` 一个候选都不会出' -f $name) -ForegroundColor Red
    }
}
# 反向：白名单里不该有不存在的命令（拼错的命令名等于这条永久失效）
foreach ($name in $gate) {
    if ($docs | Where-Object { $_.name -eq $name }) { continue }
    $gateFail += $name
    Write-Host ('  [失败] 白名单里的 {0} 手册中不存在' -f $name) -ForegroundColor Red
}
Write-Host ''

Write-Host ''
Write-Host '补全自检 —— optionList / InputParser / completions 的 PowerShell 移植' -ForegroundColor Cyan
Write-Host ('从 {0} 解析出 {1} 条手册条目' -f (Split-Path -Leaf $sourcePath), $docs.Count)
Write-Host ''

$pass = 0; $fail = @()

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
$total = $cases.Count + $gateFail.Count
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
