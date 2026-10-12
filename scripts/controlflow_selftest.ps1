# ControlFlowDetector 的 PowerShell 移植自检。
#
# 为什么要移植而不是只靠 CI：ControlFlowDetector 判错的后果是
# 「for/if 被切开跑成废命令」或者「普通命令被误判」，两个都不会崩，
# 只会安静地给出错误结果——CI 编译通过根本发现不了，只能靠用例。
#
# 必须存 UTF-8 BOM：PS 5.1 按 GBK 读无 BOM 的脚本，脚本里的中文会变乱码。
# 不能用 $input 作形参（PowerShell 自动变量）。
#
# ⚠️ **这是 Swift 的移植版，两边分叉过一次（2026-10-13）。**
#    Swift 的 isAssignment 被手译成了「遍历剩余字符，不是字母数字就 false」，
#    于是 x=10 在 `=` 上就被判 false，hasStatefulAssignment 恒假，
#    v0.8.2 的「整段执行」修复**从头到尾没生效过**。
#    本脚本用的正则判定是对的，所以 51 例全绿——绿灯够不着 Swift。
#    教训：**改 Swift 的同一段逻辑时必须同步改这里**，否则绿灯是假的。
#    真正兜底的是真机执行（v0.9.0 的「测试清单」就是这么抓到它的）。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'TT\ContentView.swift'
$source = Get-Content $sourcePath -Raw -Encoding UTF8

if ($source -notmatch 'enum ControlFlowDetector') {
    Write-Host "FAIL: ContentView.swift 里找不到 ControlFlowDetector" -ForegroundColor Red
    exit 1
}

$openers = @('for', 'if', 'while', 'until', 'case', 'select')
$closers = @('do', 'done', 'then', 'fi', 'elif', 'else', 'esac')

function Get-Words([string]$line) {
    $result = New-Object System.Collections.Generic.List[string]
    $current = ''
    $quote = [char]0

    foreach ($ch in $line.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            if ($current -ne '') { $result.Add($current); $current = '' }
            continue
        }
        if ([char]::IsWhiteSpace($ch) -or $ch -eq ';' -or $ch -eq '|' -or $ch -eq '&' -or $ch -eq '(' -or $ch -eq ')') {
            if ($current -ne '') { $result.Add($current); $current = '' }
            continue
        }
        $current += $ch
    }
    if ($current -ne '') { $result.Add($current) }
    return $result.ToArray()
}

function Test-WholeLine([string]$line) {
    # 控制流
    foreach ($word in (Get-Words $line)) {
        $lower = $word.ToLowerInvariant()
        if ($openers -contains $lower -or $closers -contains $lower) { return $true }
    }
    # cd 优先：整行交给 mksh 的话改的是子进程的 cwd，TT 这边不跟着动
    if (Test-HasTopLevelCd $line) { return $false }
    # 变量赋值 + 顶层分隔符
    if (-not (Test-HasSeparator $line)) { return $false }
    foreach ($word in (Get-Words $line)) {
        if (Test-IsAssignment $word) { return $true }
    }
    return $false
}

# 顶层（引号外）有没有一条 cd 段。
# 只认行首、或紧跟 `;` `&` `|` 的那个 token —— 和 Swift 的 hasTopLevelCd 一一对应。
#
# ⚠️ token 为空时必须原样返回、**不许动 segmentStart**：
#    `x=1; cd /tmp` 的 `;` 后面还有一个空格，那一格若顺手把 segmentStart 清成 false，
#    真正该判的 cd 就永远轮不到 —— cd 保护会**静默失效**。
function Test-HasTopLevelCd([string]$line) {
    $token = ''
    $segmentStart = $true
    $quote = [char]0
    for ($i = 0; $i -lt $line.Length; $i++) {
        $ch = $line[$i]
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 } else { $token += $ch }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq ';' -or $ch -eq '&' -or $ch -eq '|') {
            if ($token -ne '') {
                if ($segmentStart -and $token -eq 'cd') { return $true }
                $segmentStart = $false
                $token = ''
            }
            $segmentStart = $true
            continue
        }
        if ([char]::IsWhiteSpace($ch)) {
            if ($token -ne '') {
                if ($segmentStart -and $token -eq 'cd') { return $true }
                $segmentStart = $false
                $token = ''
            }
            continue
        }
        $token += $ch
    }
    if ($token -ne '' -and $segmentStart -and $token -eq 'cd') { return $true }
    return $false
}

# 顶层（引号外）有分段符吗
function Test-HasSeparator([string]$line) {
    $quote = [char]0
    foreach ($ch in $line.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq ';' -or $ch -eq '|' -or $ch -eq '&') { return $true }
    }
    return $false
}

# 一个词是不是变量赋值：x=10 X=1 _foo=bar
function Test-IsAssignment([string]$word) {
    if ($word -notmatch '^[A-Za-z_][A-Za-z0-9_]*=') { return $false }
    return $true
}

# --- 分段执行时 && / || 该不该跳过这一段 ---
#
# 对应 Swift 里 ShellCommandRunner.run 的这两行：
#     if precedingSeparator == "&&" && lastExitCode != 0 { continue }
#     if precedingSeparator == "||" && lastExitCode == 0  { continue }
#
# 这段逻辑以前**从来没被任何测试覆盖过**，于是「跳过用 break」能一直躺着：
# `which 不存在的命令 && echo 找到了 || echo 没找到` 会掐断整条链，
# 一个字都不输出。break 改成 continue 才对。

function Test-SkipSegment([string]$precedingSeparator, [int]$lastExitCode) {
    if ($precedingSeparator -eq '&&' -and $lastExitCode -ne 0) { return $true }
    if ($precedingSeparator -eq '||' -and $lastExitCode -eq 0) { return $true }
    return $false
}

# 模拟整条链：@($分隔符数组, @($各段退出码数组)) → @($实际跑了的段的序号)
function Get-ExecutedSegments([string[]]$separators, [int[]]$exitCodes) {
    $ran = @()
    $last = 0
    for ($i = 0; $i -lt $exitCodes.Count; $i++) {
        $before = if ($i -eq 0) { '' } else { $separators[$i - 1] }
        # 注意是 continue 不是 break：跳过一段不等于掐断整条链
        if (Test-SkipSegment $before $last) { continue }
        $ran += $i
        $last = $exitCodes[$i]
    }
    return $ran
}

$passed = 0
$failed = 0

function Check([string]$name, [bool]$actual, [bool]$expected) {
    if ($actual -eq $expected) {
        $script:passed++
    } else {
        $script:failed++
        $mark = if ($expected) { '该判成控制流' } else { '不该判成控制流' }
        Write-Host ("FAIL: {0} —— 实际 {1}，{2}" -f $name, $actual, $mark) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '── ControlFlowDetector：控制流（应为真）──'

Check 'for 计数'                (Test-WholeLine 'for i in 1 2 3; do echo $i; done') $true
Check 'for 遍历单词'            (Test-WholeLine 'for f in a b c; do echo $f; done') $true
Check 'if then'                 (Test-WholeLine 'if [ -f /etc/hosts ]; then echo 有; fi') $true
Check 'if 单行 then 在前'       (Test-WholeLine 'if true; then echo yes; fi') $true
Check 'if/else'                 (Test-WholeLine 'if [ -d /tmp ]; then echo t; else echo f; fi') $true
Check 'elif'                    (Test-WholeLine 'if [ -d /a ]; then echo 1; elif [ -d /b ]; then echo 2; fi') $true
Check 'while'                   (Test-WholeLine 'while [ -f /tmp/go ]; do echo 还在; done') $true
Check 'until'                   (Test-WholeLine 'until [ -f /tmp/stop ]; do echo 转; done') $true
Check 'case esac'               (Test-WholeLine 'case x in a) echo A;; esac') $true
Check '嵌套 for'                (Test-WholeLine 'for i in 1 2; do for j in a b; do echo $i$j; done; done') $true
Check 'do 单独出现'             (Test-WholeLine 'do echo x') $true
Check 'done 单独出现'           (Test-WholeLine 'done') $true
Check 'fi 单独出现'             (Test-WholeLine 'fi') $true
Check 'then 后面粘分号'         (Test-WholeLine 'if true; then; fi') $true
Check '大小写混写'              (Test-WholeLine 'FOR i IN 1 2; DO echo $i; DONE') $true
Check 'if 带 && 分支'           (Test-WholeLine 'if [ -f /etc/hosts ] && echo 有; fi') $true
Check '管道在 if 里'            (Test-WholeLine 'if echo x | cat; then echo ok; fi') $true

Write-Host ''
Write-Host '── ControlFlowDetector：普通命令（应为假）──'

Check 'ls'                      (Test-WholeLine 'ls') $false
Check 'ls -l /etc'              (Test-WholeLine 'ls -l /etc') $false
Check '管道'                    (Test-WholeLine 'echo abc | wc') $false
Check '&& 链'                   (Test-WholeLine 'ls && echo ok') $false
Check '|| 链'                   (Test-WholeLine 'ls || echo 失败') $false
Check '重定向'                  (Test-WholeLine 'echo hi > /tmp/a.txt') $false
Check '追加重定向'              (Test-WholeLine 'echo hi >> /tmp/a.txt') $false
Check '路径含 do'               (Test-WholeLine 'ls /tmp/do') $false
Check '参数含 fi'               (Test-WholeLine 'cat /etc/hosts') $false
Check '空行'                    (Test-WholeLine '') $false
Check '纯空格'                  (Test-WholeLine '   ') $false
Check 'seq'                     (Test-WholeLine 'seq 1 10') $false
Check 'ttdebug'                 (Test-WholeLine 'ttdebug') $false
Check '带引号的 for 文本'        (Test-WholeLine 'echo "for i in 1 2 3"') $false
Check '引号里的 do'             (Test-WholeLine 'echo "do not do that"') $false
Check '单引号里的 if'           (Test-WholeLine "echo 'if you see this'") $false
Check '中文参数'                (Test-WholeLine 'echo 你好世界') $false

Write-Host ''
Write-Host '── ControlFlowDetector：变量赋值（应为整段）──'

Check '赋值后用'              (Test-WholeLine 'x=10; echo $x') $true
Check '算术里用变量'          (Test-WholeLine 'x=10; echo $((x*2))') $true
Check '多个赋值'              (Test-WholeLine 'x=1; y=2; echo $x$y') $true
Check 'export 形式'           (Test-WholeLine 'export X=1; echo $X') $true
Check '下划线开头'            (Test-WholeLine '_a=5; echo $_a') $true
Check '带 && 的赋值链'        (Test-WholeLine 'n=3 && echo $n') $true
Check '混合控制流和赋值'      (Test-WholeLine 'i=0; for x in 1 2; do echo $x; done') $true

Write-Host ''
Write-Host '── ControlFlowDetector：不该整段的（应为分段）──'

Check '孤立赋值'              (Test-WholeLine 'x=10') $false
Check 'cd 跨命令保持'         (Test-WholeLine 'cd /tmp && pwd') $false
Check '管道'                  (Test-WholeLine 'echo abc | wc') $false
Check '&& 链'                 (Test-WholeLine 'ls && echo ok') $false
Check '重定向'                (Test-WholeLine 'echo hi > /tmp/a.txt') $false
Check '等号在参数里'          (Test-WholeLine 'echo a=1') $false
Check 'ls 带选项'             (Test-WholeLine 'ls -l /etc') $false
Check '通配符配合循环'        (Test-WholeLine 'for f in /etc/*; do echo $f; done') $true
Check '赋值写在引号里'        (Test-WholeLine 'echo "x=10; echo $x"') $false
Check '赋值在管道里'          (Test-WholeLine 'echo "x=10" | cat') $false

Write-Host ''
Write-Host '── ControlFlowDetector：cd 优先于变量赋值 ──'
Write-Host '   整行交给 mksh 的话改的是子进程 cwd，TT 的当前目录不跟着动，' -ForegroundColor DarkGray
Write-Host '   所以 cd 一律走分段（由 TT 自己拦下）。' -ForegroundColor DarkGray

Check 'cd 在前'               (Test-WholeLine 'cd /tmp; x=1') $false
Check 'cd 在后'               (Test-WholeLine 'x=1; cd /tmp') $false
Check 'cd 夹在中间'           (Test-WholeLine 'x=1; cd /tmp; echo $x') $false
Check 'cd 用 && 连'           (Test-WholeLine 'cd /tmp && pwd') $false
Check 'cd 用 || 连'           (Test-WholeLine 'x=1 || cd /tmp') $false
Check '只是参数里带 cd'       (Test-WholeLine 'x=1; echo cd') $true
Check 'cd 在引号里不算'       (Test-WholeLine 'x=1; echo "cd /tmp"') $true
Check '路径叫 cd 也不算'      (Test-WholeLine 'x=1; cat /tmp/cd') $true

Write-Host ''
Write-Host '── 分段执行：&& / || 跳过的是「这一段」不是「整条链」──'

# 约定：分隔符数组的个数 = 段数 - 1；退出码数组每段一个。
# 例如 `a && b` 传 @('&&') @(0,0)：a 的退出码 0，于是 b 也跑。

Check '&& 成功就往下跑'        ((Get-ExecutedSegments @('&&') @(0,0)).Count -eq 2) $true
Check '&& 失败只跳这一段'      ((Get-ExecutedSegments @('&&') @(1,0)).Count -eq 1) $true
Check '|| 失败就往下跑'        ((Get-ExecutedSegments @('||') @(1,0)).Count -eq 2) $true
Check '|| 成功就跳这一段'      ((Get-ExecutedSegments @('||') @(0,0)).Count -eq 1) $true
# 真机报的那条：which 失败 → 跳掉 && 那段 → || 那段照样要跑
Check '&&失败后 || 仍执行'     ((Get-ExecutedSegments @('&&','||') @(1,0,0)) -contains 2) $true
Check '&&失败后 || 那段被跑'   ((Get-ExecutedSegments @('&&','||') @(1,0,0)).Count -eq 2) $true
Check '&& 全成功跑满三段'      ((Get-ExecutedSegments @('&&','&&') @(0,0,0)).Count -eq 3) $true
Check '&& 成功则 || 那段跳过'  ((Get-ExecutedSegments @('&&','||') @(0,0,0)) -contains 2) $false
Check 'a&&b&&c 中间失败'       ((Get-ExecutedSegments @('&&','&&') @(0,1,0)) -contains 2) $false
Check 'a&&b||c||d 链路'        ((Get-ExecutedSegments @('&&','||','||') @(1,0,0,0)).Count -eq 2) $true
Check '全失败时只跑第一段'     ((Get-ExecutedSegments @('&&','&&') @(1,0,0)).Count -eq 1) $true

Write-Host ''
Write-Host '── 防分叉：Swift 源码里那几行还在不在 ──'
Write-Host '   移植版再对也可能和 Swift 对不上。这一节直接查源码，' -ForegroundColor DarkGray
Write-Host '   改了 Swift 却没改本脚本时，至少这里会红。' -ForegroundColor DarkGray

function Check-Source([string]$name, [string]$needle, [bool]$shouldExist) {
    $found = $source.Contains($needle)
    if ($found -eq $shouldExist) {
        $script:passed++
        $mark = if ($shouldExist) { '在' } else { '确实不在' }
        Write-Host ("  [通过] {0,-28} {1}" -f $name, $mark) -ForegroundColor DarkGreen
    }
    else {
        $script:failed++
        $mark = if ($shouldExist) { '源码里已经找不到了' } else { '源码里又出现了' }
        Write-Host ("  [失败] {0,-28} {1}" -f $name, $mark) -ForegroundColor Red
    }
}

# isAssignment 必须以 `=` 收尾判断，而不是早期的 contains("=")
Check-Source 'isAssignment 收尾'      'return rest.first == "="' $true
# 整段执行的判据必须带 cd 保护
Check-Source 'cd 保护'                'hasStatefulAssignment(line) && !hasTopLevelCd(line)' $true
# && / || 必须跳过一段（continue），不能掐断整条链（break）
Check-Source '&& 跳过用 continue'     'precedingSeparator == "&&" && lastExitCode != 0 { continue }' $true
Check-Source '|| 跳过用 continue'     'precedingSeparator == "||" && lastExitCode == 0 { continue }' $true
# 这两个是当年把 bug 引进来的写法，源码里不该再出现
Check-Source '别退回 break'            'lastExitCode != 0 { break }' $false
Check-Source '别退回 contains(=)'      'return word.contains("=")' $false
Check-Source '别退回手译 isAssignment' 'for character in lower.dropFirst()' $false

Write-Host ''
if ($failed -eq 0) {
    Write-Host ("全部通过 {0}/{0}" -f $passed) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 {0} 条，通过 {1} 条" -f $failed, $passed) -ForegroundColor Red
    exit 1
}