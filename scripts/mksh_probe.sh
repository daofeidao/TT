#!/bin/bash
# mksh 行为探针。
#
# 为什么需要它：这份内置 mksh 到底支持哪些 shell 特性，**只有编译它的 macOS runner
# 能回答**——本机是 Windows 且没有 shell，App 里的行为只能靠真机发现，而真机一轮
# 反馈很慢。与其猜，不如在这里把刚编出来的 mksh 跑一遍，把结论打进 CI 日志。
#
# 已确认踩到的坑：
#   `for i in {1..5}; do echo $i; done` 在真机上只循环一次、输出 `{1..5}`，
#   也就是**默认没开花括号展开**（花括号展开是 ksh93 的特性）。
#   本探针用来确定「加什么 set 选项能开」，
#   免得靠猜再发一版装到手机上才发现还是不对。
#
# 用法：bash scripts/mksh_probe.sh <mksh 可执行文件路径>
# 退出码恒为 0：**探针只报告、不拦截**。哪条支持与否由人读日志决定。

set -uo pipefail

MKSH="${1:-}"
if [ -z "$MKSH" ] || [ ! -x "$MKSH" ]; then
  echo "::error::用法：bash scripts/mksh_probe.sh <mksh 路径>（传进来的不是可执行文件：'$MKSH'）"
  exit 1
fi

run() {
  # run <说明> <脚本>
  local desc="$1" script="$2" out
  out="$("$MKSH" -c "$script" 2>&1 | tr '\n' '~')"
  printf '  %-34s → %s\n' "$desc" "$out"
}

echo "=============================================================="
echo "mksh 行为探针：$MKSH"
echo "=============================================================="

echo ""
echo "【版本】"
"$MKSH" -c 'echo "$KSH_VERSION"' 2>&1 | sed 's/^/  /'
file "$MKSH" 2>/dev/null | sed 's/^/  /'

echo ""
echo "【花括号展开】—— 真机报的那条就在这组里"
run 'echo {1..5}'                'echo {1..5}'
run 'for i in {1..5}; do echo $i; done' 'for i in {1..5}; do echo $i; done'
run 'set -B; echo {1..5}'        'set -B; echo {1..5}'
run 'set -B; for 循环'           'set -B; for i in {1..5}; do echo $i; done'
run 'set -B; 字母序列'           'set -B; echo {a..e}'
run 'set -o ksh93; echo {1..5}'  'set -o ksh93; echo {1..5}'
run 'set -o ksh93; for 循环'     'set -o ksh93; for i in {1..5}; do echo $i; done'
run 'set -B; 逗号列表'           'set -B; echo {a,b,c}'
run 'set -B; 嵌套'               'set -B; echo pre{1,2}post'
run 'set -o ksh93 后 for ((...))' 'set -o ksh93; for ((i=0;i<3;i++)); do echo $i; done'

echo ""
echo "【控制流基本形态】—— 已真机验收过，留着当回归"
run 'for 列表'                   'for i in 1 2 3; do echo $i; done'
run 'if / fi'                    'if [ -f /etc/hosts ]; then echo 有; fi'
run 'elif'                       'if [ -d /a ]; then echo 1; elif [ -d /b ]; then echo 2; fi'
run 'while'                      'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done'
run 'case / esac'                'case abc in a*) echo 以a开头;; *) echo 其他;; esac'
run '嵌套 for'                   'for i in 1 2; do for j in a b; do echo $i$j; done; done'
run 'glob 展开'                  'for f in /etc/h*; do echo 找到 $f; done'

echo ""
echo "【变量与算术】"
run '跨分号赋值'                 'x=10; echo $((x*2)) 和 ${x} 和 ${#x}'
run '多个赋值'                   'x=1; y=2; echo $x$y'
run '算术自增'                   'i=5; echo $((i+1))'
run 'export 后可见'              'export X=1; echo $X'

echo ""
echo "【短路】"
run '&& 成功'                    'true && echo 会出现'
run '&& 失败'                    'false && echo 不该出现'
run '|| 失败后执行'              'false && echo 不该出现 || echo 出现'
run '|| 成功后跳过'              'true || echo 不该出现'

echo ""
echo "【重定向与管道】"
run '管道'                       'echo abc | wc'
run '管道给 for'                 'printf "1\n2\n" | while read v; do echo 读到 $v; done'
run '重定向'                     'echo hi > /tmp/probe.txt; cat /tmp/probe.txt'
run '追加重定向'                 'echo a > /tmp/p2.txt; echo b >> /tmp/p2.txt; cat /tmp/p2.txt'
rm -f /tmp/probe.txt /tmp/p2.txt 2>/dev/null || true

echo ""
echo "=============================================================="
echo "探针结束。注意：花括号展开那组里，"
echo "「for 循环」要输出 1 2 3 4 5 五行才算开着了。"
echo "=============================================================="