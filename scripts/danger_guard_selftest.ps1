#requires -Version 5
<#
    danger_guard_selftest.ps1

    TT/ContentView.swift 里 `DangerGuard` 的 PowerShell 移植。
    规则、归一化方式、判定顺序都与 Swift 版一一对应——改一边必须改另一边。

    为什么需要它：Swift 编译器本机没有，危险规则改错了要等 CI 甚至真机才发现。
    这里把同一套逻辑搬过来，本机一条命令就能跑完全部用例。

    跑法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\danger_guard_selftest.ps1

    硬规则（来自 AGENTS.md）：这里的用例只用来**验证拦截**，任何一条 BLOCK 用例
    都不得被执行。本脚本不执行任何被测命令，只在字符串上做匹配。
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 移植层

function Normalized([string]$command) {
    $s = $command.ToLowerInvariant()
    $s = $s.Replace('\', ' ')
    $s = $s.Replace("'", '')
    $s = $s.Replace('"', '')
    $parts = @($s -split '[ \n\t\r]+' | Where-Object { $_ -ne '' })
    return ($parts -join ' ')
}

function Compact([string]$command) {
    return $command.Replace(' ', '')
}

function RmTargets([string]$command) {
    $tokens = @($command -split ' ')
    $head = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -eq 'rm' -or $tokens[$i].EndsWith('/rm')) { $head = $i; break }
    }
    if ($head -lt 0) { return @() }
    $out = @()
    for ($i = $head + 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].StartsWith('-')) { continue }
        $out += $tokens[$i]
    }
    return $out
}

function HomeTargets([string]$command) {
    return ($command.Contains('$home') -or $command.Contains('{home') -or $command.Contains('~/'))
}

function RmRecursive([string]$command) {
    return ($command.Contains('rm -r') -or $command.Contains('--recursive'))
}

$script:CriticalPaths = @('/etc', '/var', '/usr', '/bin', '/sbin', '/lib', '/private', '/system', '/applications')

function CriticalPath([string]$path) {
    $t = $path
    if ($t.EndsWith('/')) { $t = $t.Substring(0, $t.Length - 1) }
    foreach ($c in $script:CriticalPaths) {
        if ($t -eq $c -or $t.StartsWith($c + '/')) { return $true }
    }
    return $false
}

function Evaluate([string]$raw) {
    $c = Normalized $raw
    $cp = Compact $c
    $targets = @(RmTargets $c)

    if ($c.Contains('mkfs') -or $c.Contains('newfs')) { return '格式化文件系统，会清空整个分区且不可恢复' }
    if ($c.Contains('diskutil') -and ($c.Contains('erase') -or $c.Contains('reformat') -or $c.Contains('partitiondisk') -or $c.Contains('secureerase'))) {
        return 'diskutil 擦除或重分区，会彻底销毁磁盘数据'
    }
    if ($c.Contains('dd ') -and $c.Contains('of=/dev/')) { return 'dd 直接写入块设备，可能覆盖整个磁盘分区' }
    if ($cp.Contains('>/dev/rdisk') -or $cp.Contains('>/dev/disk')) { return '重定向到块设备等于直接覆写磁盘原始数据' }
    if (($targets -contains '/') -or ($targets -contains '/*') -or ($targets -contains '~') -or (HomeTargets $c)) {
        return '删除根目录或整个用户目录，系统将无法启动'
    }
    foreach ($t in $targets) {
        if ($t.Contains('*') -or $t.Contains('?')) { return '使用通配符递归删除，命中范围不可预估' }
    }
    if (RmRecursive $c) {
        foreach ($t in $targets) {
            if (CriticalPath $t) { return '递归强制删除系统关键目录' }
        }
    }
    if ($c.Contains('find') -and ($c.Contains('-delete') -or ($c.Contains('-exec') -and $c.Contains('rm')))) {
        return 'find -delete / -exec rm，删哪些文件由遍历结果决定，范围无法预估'
    }
    if ($cp.Contains('chmod-r777/') -or ($cp.Contains('chown-r') -and $c.EndsWith('/'))) {
        return '递归修改根目录权限或属主'
    }
    if ($c.Contains('killall') -or $c.Contains('kill -9 -1')) { return '批量结束系统进程，可能导致系统不稳定' }
    if ($cp.Contains(':(){') -and $cp.Contains('};')) { return 'fork 炸弹，会瞬间耗尽进程与 CPU' }

    return $null
}

# ---------------------------------------------------------------- 用例

# $true = 必须拦下；$false = 必须放行（日常操作不能被误伤）
$cases = @(
    # —— 2025-10-10 事故本体与它的各种写法 ——
    @{ Cmd = 'rm -rf /';                          Block = $true;  Tag = '事故本体' }
    @{ Cmd = 'RM -RF /';                          Block = $true;  Tag = '大小写' }
    @{ Cmd = 'rm  -rf  /';                        Block = $true;  Tag = '多余空格' }
    @{ Cmd = 'rm -fr /';                          Block = $true;  Tag = '选项换序' }
    @{ Cmd = 'rm -r -f /';                        Block = $true;  Tag = '选项拆开' }
    @{ Cmd = 'rm --recursive --force /';          Block = $true;  Tag = '长选项' }
    @{ Cmd = 'sh -c "rm -rf /"';                  Block = $true;  Tag = '套一层 sh' }
    @{ Cmd = "rm -rf '/var/mobile'";              Block = $true;  Tag = '单引号包裹' }
    @{ Cmd = 'rm -rf /var/mobile';                Block = $true;  Tag = '系统数据目录' }
    @{ Cmd = "echo hi`nrm -rf /";                 Block = $true;  Tag = '多行脚本夹一行' }
    @{ Cmd = 'rm -rf /*';                         Block = $true;  Tag = '根目录通配' }
    @{ Cmd = 'rm -rf ~';                          Block = $true;  Tag = '家目录简写' }
    @{ Cmd = 'rm -rf $HOME';                      Block = $true;  Tag = '家目录变量' }
    @{ Cmd = 'rm -rf ${HOME}';                    Block = $true;  Tag = '家目录带花括号' }
    @{ Cmd = 'rm -rf /tmp/*';                     Block = $true;  Tag = '通配符删除' }
    @{ Cmd = 'rm -rf /var/??';                    Block = $true;  Tag = '单字符通配' }
    @{ Cmd = '/bin/rm -rf /etc';                  Block = $true;  Tag = '全路径 rm' }

    # —— 其他系统关键目录 ——
    @{ Cmd = 'rm -rf /etc';                       Block = $true;  Tag = '递归删关键目录' }
    @{ Cmd = 'rm -rf /usr';                       Block = $true;  Tag = '递归删关键目录' }
    @{ Cmd = 'rm -rf /private/var/mobile';        Block = $true;  Tag = '递归删关键目录' }
    @{ Cmd = 'rm -rf /System/Library';            Block = $true;  Tag = '递归删关键目录' }

    # —— 磁盘与格式化 ——
    @{ Cmd = 'mkfs.ext4 /dev/rdisk0s1';           Block = $true;  Tag = '格式化' }
    @{ Cmd = 'newfs /dev/disk0s1';                Block = $true;  Tag = '格式化' }
    @{ Cmd = 'diskutil eraseDisk /dev/disk2';     Block = $true;  Tag = '擦除磁盘' }
    @{ Cmd = 'diskutil reformat /dev/disk2';      Block = $true;  Tag = '重分区' }
    @{ Cmd = 'dd if=/dev/zero of=/dev/rdisk0s1';  Block = $true;  Tag = '写块设备' }
    @{ Cmd = 'cat x > /dev/rdisk0s1';             Block = $true;  Tag = '重定向块设备' }

    # —— 遍历型删除与进程 ——
    @{ Cmd = "find /tmp -name '*.txt' -delete";   Block = $true;  Tag = 'find -delete' }
    @{ Cmd = 'find /tmp -exec rm {} \;';          Block = $true;  Tag = 'find -exec rm' }
    @{ Cmd = 'chmod -R 777 /';                    Block = $true;  Tag = '递归改权限' }
    @{ Cmd = 'chown -R root /';                   Block = $true;  Tag = '递归改属主' }
    @{ Cmd = 'killall -9 SpringBoard';            Block = $true;  Tag = '批量杀进程' }
    @{ Cmd = 'kill -9 -1';                        Block = $true;  Tag = '批量杀进程' }
    @{ Cmd = ':(){ :|:& };:';                     Block = $true;  Tag = 'fork 炸弹' }

    # —— 日常操作，一条都不许误伤 ——
    @{ Cmd = 'rm -rf /tmp/ttd';                   Block = $false; Tag = '临时目录' }
    @{ Cmd = 'rm -f /tmp/tt2.txt /tmp/tt4.txt';   Block = $false; Tag = '删临时文件' }
    @{ Cmd = 'rm /tmp/a.txt';                     Block = $false; Tag = '删单个临时文件' }
    @{ Cmd = 'ls -la';                            Block = $false; Tag = '列出' }
    @{ Cmd = 'ls /etc';                           Block = $false; Tag = '列出' }
    @{ Cmd = 'pwd';                               Block = $false; Tag = '当前目录' }
    @{ Cmd = 'cd /etc';                           Block = $false; Tag = '切目录' }
    @{ Cmd = 'cd bin';                            Block = $false; Tag = '切目录' }
    @{ Cmd = 'cat /etc/hosts';                    Block = $false; Tag = '读文件' }
    @{ Cmd = 'echo hello > /tmp/tt1.txt';         Block = $false; Tag = '写临时文件' }
    @{ Cmd = 'echo world >> /tmp/tt1.txt';        Block = $false; Tag = '追加临时文件' }
    @{ Cmd = 'echo "a>b"';                        Block = $false; Tag = '引号内大于号' }
    @{ Cmd = 'echo abc | wc';                     Block = $false; Tag = '管道' }
    @{ Cmd = 'cd /etc; pwd';                      Block = $false; Tag = '分号串联' }
    @{ Cmd = 'find /tmp -name tt1.txt -type f';   Block = $false; Tag = 'find 只查不删' }
    @{ Cmd = 'find / -name x.txt -type f';        Block = $false; Tag = 'find 只查不删' }
    @{ Cmd = 'mkdir -p /tmp/ttd';                 Block = $false; Tag = '建目录' }
    @{ Cmd = 'touch /tmp/tt2.txt';                Block = $false; Tag = '建文件' }
    @{ Cmd = 'du -sh /tmp';                       Block = $false; Tag = '占空间' }
    @{ Cmd = 'df -h';                             Block = $false; Tag = '磁盘用量' }
    @{ Cmd = 'whoami';                            Block = $false; Tag = '身份' }
    @{ Cmd = 'cp /tmp/a /tmp/b';                  Block = $false; Tag = '复制' }
    @{ Cmd = 'mv /tmp/a /tmp/b';                  Block = $false; Tag = '改名' }
    @{ Cmd = 'stat /tmp/a';                       Block = $false; Tag = '元信息' }
    @{ Cmd = 'wc -l /tmp/a';                      Block = $false; Tag = '计数' }
    @{ Cmd = 'grep -n foo /tmp/a';                Block = $false; Tag = '搜索' }
    @{ Cmd = 'chmod 644 /tmp/a';                  Block = $false; Tag = '改单文件权限' }
    @{ Cmd = 'echo $PATH';                        Block = $false; Tag = '打印变量' }
    @{ Cmd = 'ttprobe';                           Block = $false; Tag = '内置探针' }
    @{ Cmd = 'ttfork';                            Block = $false; Tag = '内置探针' }
    @{ Cmd = 'ttdebug';                           Block = $false; Tag = '内置诊断' }
)

# ---------------------------------------------------------------- 执行

Write-Host ''
Write-Host 'DangerGuard 自检 —— 规则移植自 TT/ContentView.swift' -ForegroundColor Cyan
Write-Host ('共 {0} 条用例：{1} 条必须拦下，{2} 条必须放行' -f $cases.Count,
    @($cases | Where-Object { $_.Block }).Count,
    @($cases | Where-Object { -not $_.Block }).Count)
Write-Host ''

$passed = 0
$failed = @()

foreach ($case in $cases) {
    $reason = Evaluate $case.Cmd
    $blocked = ($null -ne $reason)
    $ok = ($blocked -eq $case.Block)

    if ($ok) {
        $passed++
        $mark = '拦截'   # 被拦下
        $verdict = if ($case.Block) { '拦下' } else { '放行' }
        Write-Host ('  [通过] {0,-10} {1}' -f $verdict, $case.Cmd.Replace("`n", '\n')) -ForegroundColor DarkGreen
    }
    else {
        $failed += $case
        $verdict = if ($case.Block) { '漏放行!!' } else { '误伤!!' }
        Write-Host ('  [失败] {0,-10} {1}' -f $verdict, $case.Cmd.Replace("`n", '\n')) -ForegroundColor Red
        if ($reason) { Write-Host ('           实际理由：{0}' -f $reason) -ForegroundColor Red }
    }
}

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host ('全部通过：{0}/{1}' -f $passed, $cases.Count) -ForegroundColor Green
    Write-Host ''
    exit 0
}
else {
    Write-Host ('{0} 条失败，{1} 条通过' -f $failed.Count, $passed) -ForegroundColor Red
    foreach ($case in $failed) { Write-Host ('  · {0}' -f $case.Cmd.Replace("`n", '\n')) -ForegroundColor Red }
    Write-Host ''
    exit 1
}
