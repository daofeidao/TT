# TT 终端

TT 是面向 iPhone 的轻量终端测试项目，优先保证 iOS 15 兼容和实际设备上的交互体验。

## 当前版本（v0.3.2 去沙盒权限与内置 Shell，测试构建）

- 保留 TT 专属应用图标、中文界面、清空终端、输入历史与原生文本选择/复制。
- 应用以最小去沙盒权限签名（`com.apple.private.security.no-sandbox` + `platform-application`，TrollStore 官方文档方案，详见 `tt.entitlements`）。
- 内置 userland：`mksh`（真实 shell，支持管道、重定向、`&&`、通配符）+ 命令工具 `ls`/`cat`/`date`/`whoami`/`uname`/`df`（CI 现场编译，位于应用包 `ttbin/`）。命令经 `mksh -c` 真实执行。
- 启动自检输出：uid/euid、工作目录、**签名与权限（运行时 entitlements）**、关键路径检查、三个启动探测（`/bin/sh`、内置 mksh、容器内探针）与结论。
- mksh 启动失败时自动降级内置解释器（真实系统接口），每条输出注明引擎，绝不回显伪装。

## 根因记录（v0.3.0/v0.3.1 真机）

- 真机（iOS 15.6.1 + TrollStore）**系统不含 `/bin/sh`、`/usr/bin/true`**（自检：存在=否，ENOENT）——启动系统 shell 的路线不成立。
- 无去沙盒权限时**进程创建被整体拒绝**（容器内探针同样 EPERM）。
- TrollStore 官方文档：非沙盒应用可用 posix_spawn 启动程序；`no-sandbox` + `platform-application` 实现去沙盒。

## 重要说明

- 每条输入启动一次 mksh 进程，无持久会话状态，`cd` 不会保留到下一条命令；交互式程序（`vim`、`top`）不支持。
- `whoami` 返回 mobile（应用身份）；如需 root 身份属后续版本评估范围（persona-mgmt）。
- 容器内探针 `ttprobe` 由 CI 编译打包，用于区分进程创建限制的边界。

## 获取安装包

打开仓库的「发行版（Releases）」页面下载已发布版本。开发分支的构建产物可在 GitHub Actions 对应运行记录中下载。

## 兼容性与构建

- 最低部署版本：iOS 15.0
- 界面：SwiftUI + UIKit 文本选择视图
- Xcode 项目：由 `project.yml` 自动生成
- 编译平台：GitHub Actions 的 macOS 云端环境（mksh 从 Debian 官方源现场编译，ttbin 工具与探针用 clang 现场编译）
- 安装：TrollStore；安装后 entitlements 由 TrollStore 应用，启动自检「签名与权限」行可核实。

## 仓库目录说明

- `TT/`：应用界面与入口代码
- `TT/Assets.xcassets/`：应用图标资源
- `tt.entitlements`：应用签名权限（最小去沙盒对）
- `scripts/`：图标生成、ttprobe、ttbin 工具源码与 mksh 构建脚本
- `.github/workflows/`：自动编译与发行版发布流程
