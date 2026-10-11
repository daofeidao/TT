# TT 终端

TT 是面向 iPhone 的轻量终端测试项目，优先保证 iOS 15 兼容和实际设备上的交互体验。

## 安全策略：高危命令一律硬拦截

v0.4.16 起，`DangerGuard` **不再按权限分级**，命中的命令一律不执行，弹窗里没有放行按钮。

起因是一次真机事故：旧版逻辑是"非 root → 只弹一次确认，点「仍然执行」就放行"，
弹窗还写着"这条命令只能影响本 App 权限范围内的数据"。**这个前提是错的**——
应用带着 `no-sandbox`、`platform-application`、`MobileContainerManager.allowed`
这些 entitlement（见上），**不是 root 也写得动 `/var/mobile/Library` 下的系统数据**。
一条 `rm -rf /` 下去，设置里大片变英文、桌面布局重置、Apple Watch 连不上。

> **权限等级不能用来决定"要不要给人放行"**：破坏不可逆，而放行只要点一下。

改规则时必须同步改 `scripts/danger_guard_selftest.ps1`（DangerGuard 的 PowerShell 等价移植，
因为本机没有 Swift 编译器），并跑通全部 **65** 条用例——34 条必须拦下、31 条必须放行。
跑法：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\danger_guard_selftest.ps1
```

> 这个脚本上线当天就抓出两个真 bug：归一化会把命令转成小写，而 `chmod-R777/` 和
> `chown-R` 两条规则却拿**大写 `R`** 去比，导致 `chmod -R 777 /`、`chown -R root /`
> 从来没被拦过。详见根目录 `AGENTS.md`。

## 当前版本（v0.3.8）

- 命令由应用内置 `mksh` 真实执行（系统不含 `/bin/sh`），每条输出注明执行引擎。
- 应用以 TrollStore RootHelper 验证过的权限配方签名（`no-sandbox`、`platform-application`、
  `container-required=false`、`storage-exempt.heritable`、`container-manager`、
  `MobileContainerManager.allowed`），见 `tt.entitlements`。
- 嵌套二进制（mksh / 探针 / 工具）在构建阶段逐个附加 entitlements 签名——这是 AMFI
  SIGKILL 的直接修复，TrollStore 安装后会完整保留（启动自检可核实）。
- 管道、`&&`、`||`、`;`、`>`、`>>`、`<` 由应用层拆分为单条命令逐段执行（原因见「已知限制」）。
- 启动自检输出：uid/euid、工作目录、运行时签名权限、ttbin 清单、三个启动探测、
  fork 能力探针与结论。
- 保留中文界面、长按选择/复制、一键复制全部、清屏、输入历史。

## 已知限制

**本设备 `fork()` 不可用。** ttfork 探针确认 fork 子进程出生即 SIGBUS（第 1 次迭代即崩溃，
三阶段 8/8 全中），而 `posix_spawn()` 完全正常。mksh 对 `-c` 的最后一条命令直接 exec 而不 fork，
所以单条命令可用；任何需要 fork 的形态（管道、多命令）会 SIGBUS。
因此组合命令与重定向由应用层拆分执行，每段仍由 mksh 真实执行——
这不是权宜之计，是该设备上唯一可行的架构。

其余限制：

- 无持久会话状态；交互式程序（`vim`、`top`）不支持。
- `whoami` 返回 mobile（应用身份）；root 身份属后续版本评估范围（persona-mgmt）。
- 系统不含任何 shell（`/bin/sh`、`/usr/bin/true` 均 ENOENT），全部 userland 由应用内置。

## 本地构建

`TT/ttbin/`、`scripts/ttprobe`、mksh 都是 CI 现场编译的产物，已在 `.gitignore` 中忽略。
本地构建必须与 CI 同序——**先生成工具，再生成 Xcode 工程**：

```bash
SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SYSROOT" -O2 -o scripts/ttprobe scripts/ttprobe.c
mkdir -p TT/ttbin
for t in ls cat date whoami uname df wc head tail grep; do
  xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SYSROOT" -O2 -o "TT/ttbin/$t" "scripts/tttools/tt${t}.c"
done
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SYSROOT" -O2 -o TT/ttbin/ttfork scripts/tttools/ttfork.c
bash scripts/build-mksh.sh
xcodegen generate
```

顺序不能颠倒：`project.yml` 把这些路径声明为资源，xcodegen 会校验它们存在。

## 获取安装包

打开仓库的「发行版（Releases）」页面下载已发布版本。

## 兼容性与构建

- 最低部署版本：iOS 15.0
- 界面：SwiftUI + UIKit 文本选择视图
- Xcode 工程：由 `project.yml` 自动生成（版本号唯一来源为 workflow 的 `env.VERSION`）
- 编译平台：GitHub Actions 的 macOS 云端环境
- 安装：TrollStore；安装后 entitlements 由 TrollStore 应用，启动自检可核实

## 仓库目录说明

- `TT/`：应用界面与入口代码
- `TT/ttbin/`：内置命令工具（构建产物，不入库）
- `tt.entitlements`：应用权限
- `scripts/`：图标生成、探针源码（`ttprobe.c`、`tttools/*.c`）与 mksh 构建脚本
- `.github/workflows/`：自动编译与发行版发布流程