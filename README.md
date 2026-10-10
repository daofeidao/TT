# TT 终端

TT 是面向 iPhone 的轻量终端测试项目，优先保证 iOS 15 兼容和实际设备上的交互体验。

## 当前版本（v0.3.1 诊断与内置解释器）

- 保留 TT 专属应用图标、中文界面、清空终端、输入历史与原生文本选择/复制。
- 启动时自动自检并输出：进程 uid/euid、工作目录、关键路径（`/bin/sh`、`/usr/bin/true`、`/etc/passwd`、容器内探针）的存在/可读/可执行检查，以及三个启动探测的真实结果与结论。
- 命令优先通过设备 `/bin/sh -c` 真实执行；若 iOS 拒绝启动（v0.3.0 真机上的 EPERM），自动切换**内置解释器**，每条输出注明执行引擎，绝不回显伪装。
- 内置解释器真实调用系统接口（文件系统、sysctl、statfs）实现：`pwd`、`ls`、`whoami`、`uname -a`、`date`、`echo`、`cat`、`df`、`help`、`clear`。
- Shell 启动失败时输出完整记录（目标路径、错误码、uid/euid、工作目录、存在/可执行检查）。

## 根因记录（v0.3.0 真机）

- v0.3.0 真机执行任何命令报 `Operation not permitted（errno 1）`：posix_spawn 在进程创建/目标路径策略阶段被拒，`/bin/sh` 从未开始运行。
- 静态取证：App 二进制 adhoc 签名、不携带任何 entitlements；对照 TrollTerm（携带 no-sandbox / platform-application / persona 等 entitlements 后进程启动正常），定位为 iOS 15.6.1 + TrollStore 环境对无 entitlements 应用启动系统路径程序的策略限制。

## 重要说明

- 每条输入启动一次进程（系统 shell 路径），无持久会话状态，`cd` 不会保留到下一条命令。
- 管道、重定向、外部程序仅在系统 shell 可用时支持；内置解释器模式下会明确提示不可用。
- 容器内探针 `ttprobe` 由 CI 用 clang 编译并打进 App 包，用于区分「系统路径被拒」与「进程创建整体被拒」。

## 获取安装包

打开仓库的「发行版（Releases）」页面下载已发布版本。开发分支的构建产物可在 GitHub Actions 对应运行记录中下载。

## 兼容性与构建

- 最低部署版本：iOS 15.0
- 界面：SwiftUI + UIKit 文本选择视图
- Xcode 项目：由 `project.yml` 自动生成
- 编译平台：GitHub Actions 的 macOS 云端环境（含 `ttprobe` 的 clang 编译）
- 安装：用于 TrollStore 测试；能否启动系统 Shell 以启动自检结果为准。

## 仓库目录说明

- `TT/`：应用界面与入口代码
- `TT/Assets.xcassets/`：应用图标资源
- `scripts/`：图标生成脚本与探针源码（`ttprobe.c`）
- `.github/workflows/`：自动编译与发行版发布流程
