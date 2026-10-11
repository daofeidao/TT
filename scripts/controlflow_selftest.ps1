# ControlFlowDetector 的 PowerShell 移植自检。
#
# 为什么要移植而不是只靠 CI：ControlFlowDetector 判错的后果是
# 「for/if 被切开跑成废命令」或者「普通命令被误判」，两个都不会崩，
# 只会安静地给出错误结果——CI 编译通过根本发现不了，只能靠用例。
#
# 必须存 UTF-8 BOM：PS 5.1 按 GBK 读无 BOM 的脚本，脚本里的中文会变乱码。
# 不能用 $input 作形参（PowerShell 自动变量）。

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

function Test-ControlFlow([string]$line) {
    foreach ($word in (Get-Words $line)) {
        $lower = $word.ToLowerInvariant()
        if ($openers -contains $lower -or $closers -contains $lower) { return $true }
    }
    return $false
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

Check 'for 计数'                (Test-ControlFlow 'for i in 1 2 3; do echo $i; done') $true
Check 'for 遍历单词'            (Test-ControlFlow 'for f in a b c; do echo $f; done') $true
Check 'if then'                 (Test-ControlFlow 'if [ -f /etc/hosts ]; then echo 有; fi') $true
Check 'if 单行 then 在前'       (Test-ControlFlow 'if true; then echo yes; fi') $true
Check 'if/else'                 (Test-ControlFlow 'if [ -d /tmp ]; then echo t; else echo f; fi') $true
Check 'elif'                    (Test-ControlFlow 'if [ -d /a ]; then echo 1; elif [ -d /b ]; then echo 2; fi') $true
Check 'while'                   (Test-ControlFlow 'while [ -f /tmp/go ]; do echo 还在; done') $true
Check 'until'                   (Test-ControlFlow 'until [ -f /tmp/stop ]; do echo 转; done') $true
Check 'case esac'               (Test-ControlFlow 'case x in a) echo A;; esac') $true
Check '嵌套 for'                (Test-ControlFlow 'for i in 1 2; do for j in a b; do echo $i$j; done; done') $true
Check 'do 单独出现'             (Test-ControlFlow 'do echo x') $true
Check 'done 单独出现'           (Test-ControlFlow 'done') $true
Check 'fi 单独出现'             (Test-ControlFlow 'fi') $true
Check 'then 后面粘分号'         (Test-ControlFlow 'if true; then; fi') $true
Check '大小写混写'              (Test-ControlFlow 'FOR i IN 1 2; DO echo $i; DONE') $true
Check 'if 带 && 分支'           (Test-ControlFlow 'if [ -f /etc/hosts ] && echo 有; fi') $true
Check '管道在 if 里'            (Test-ControlFlow 'if echo x | cat; then echo ok; fi') $true

Write-Host ''
Write-Host '── ControlFlowDetector：普通命令（应为假）──'

Check 'ls'                      (Test-ControlFlow 'ls') $false
Check 'ls -l /etc'              (Test-ControlFlow 'ls -l /etc') $false
Check '管道'                    (Test-ControlFlow 'echo abc | wc') $false
Check '&& 链'                   (Test-ControlFlow 'ls && echo ok') $false
Check '|| 链'                   (Test-ControlFlow 'ls || echo 失败') $false
Check '重定向'                  (Test-ControlFlow 'echo hi > /tmp/a.txt') $false
Check '追加重定向'              (Test-ControlFlow 'echo hi >> /tmp/a.txt') $false
Check '路径含 do'               (Test-ControlFlow 'ls /tmp/do') $false
Check '参数含 fi'               (Test-ControlFlow 'cat /etc/hosts') $false
Check '空行'                    (Test-ControlFlow '') $false
Check '纯空格'                  (Test-ControlFlow '   ') $false
Check 'seq'                     (Test-ControlFlow 'seq 1 10') $false
Check 'ttdebug'                 (Test-ControlFlow 'ttdebug') $false
Check '带引号的 for 文本'        (Test-ControlFlow 'echo "for i in 1 2 3"') $false
Check '引号里的 do'             (Test-ControlFlow 'echo "do not do that"') $false
Check '单引号里的 if'           (Test-ControlFlow "echo 'if you see this'") $false
Check '中文参数'                (Test-ControlFlow 'echo 你好世界') $false

Write-Host ''
if ($failed -eq 0) {
    Write-Host ("全部通过 {0}/{0}" -f $passed) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 {0} 条，通过 {1} 条" -f $failed, $passed) -ForegroundColor Red
    exit 1
}