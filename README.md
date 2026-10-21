# TokenTool

macOS 顶部菜单栏 AI 用量监控工具，实时查看 **Qoder**、**WorkBuddy**、**Codex** 的额度与剩余用量。

无 Dock 图标、无后台常驻窗口，点击菜单栏即可展开详情；三家平台可独立控制是否显示在菜单栏，并可直接打开对应客户端或官网，还支持每日领取与额度重置提醒。

## 功能

- **菜单栏常驻**：紧凑显示三家的关键指标（Qoder 剩余积分、WorkBuddy 剩余积分、Codex 已用比例），带完整 tooltip。
- **独立显示开关**：面板底部可分别隐藏 / 显示 Qoder、WorkBuddy、Codex；全部隐藏时仍保留一个 `AI` 入口，点击照常展开面板，数据也继续在后台采集。
- **详情面板**：套餐名称、Credits 进度条、剩余 / 总量、限额窗口、重置时间、最后更新时间与错误状态。
- **快捷入口**：每张卡片提供「打开」客户端与「官网」链接；Qoder 未登录 / 未安装时额外提供「终端登录」「安装 CLI」按钮。
- **领取提醒**：Qoder 每天 10:00、WorkBuddy 每天 00:00 提醒领取 100 额度；Codex 按最长限额窗口的重置时间提醒。三路可独立开关。
- **自动刷新**：Codex 与 WorkBuddy 每 60 秒，Qoder 每 5 分钟；支持手动刷新，系统唤醒后自动刷新一次。
- **本地缓存**：启动时先展示上次数据，再异步更新。
- **开机启动**：面板一键开关，通过 LaunchAgent 实现，不产生 Dock 图标。
- **通用二进制**：同时支持 Apple Silicon 与 Intel Mac，最低 macOS 13。

## 界面说明

菜单栏文字由三部分组成，可在面板中任意组合：

```
Q 1,770   W 12,480   C 8.5%
```

| 部分 | 含义 |
| --- | --- |
| `Q` | Qoder 剩余 Credits（套餐 + 附加额度） |
| `W` | WorkBuddy 剩余 Credits |
| `C` | Codex 主限额窗口的已用比例 |

面板中每张卡片底部：

- **打开**：启动对应客户端（Qoder CN / WorkBuddy / ChatGPT）。
- **官网**：在浏览器打开官方站点。

底部「菜单栏显示」三个眼睛按钮分别控制菜单栏可见性，状态立即生效并持久保存。

「提醒」一行的三个铃铛按钮分别控制：

| 按钮 | 行为 |
| --- | --- |
| `Qoder 10:00` | 每天 10:00 提醒领取 100 Credits |
| `WorkBuddy 00:00` | 每天 00:00 提醒领取 100 积分 |
| `Codex 重置` | 在当前最长限额窗口重置时提醒 |

首次开启提醒会请求系统通知权限；若系统通知被关闭，面板会显示提示和「去开启」入口。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 13 Ventura 及以上 |
| 架构 | Apple Silicon / Intel（Universal Binary） |
| Python | Python 3（系统 Command Line Tools 自带即可） |
| Qoder | 已安装官方 CLI `qoderclicn` 并完成登录 |
| WorkBuddy | 客户端已安装、已登录并保持运行 |
| Codex | ChatGPT.app 已安装并登录（内置 codex CLI） |

## 安装

### 从 Release 安装（推荐）

1. 前往 [Releases](https://github.com/pumf/token_tool/releases) 下载最新的 `TokenTool-<版本>.dmg` 或 `.zip`。
2. 打开 DMG，将 **TokenTool** 拖入「应用程序」；ZIP 则解压后拖入。
3. 首次启动若被 macOS 拦截（应用为本地构建，未使用 Developer ID 签名与公证），请：
   - 在「应用程序」中右键 TokenTool →「打开」→ 再次确认「打开」；或
   - 执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/TokenTool.app
     ```
4. 启动后应用只出现在菜单栏，不占用 Dock。
5. 首次启用提醒时，请在系统弹窗中允许通知。

### 从源码构建

依赖 Xcode Command Line Tools：

```bash
xcode-select --install
git clone https://github.com/pumf/token_tool.git
cd token_tool
./build.sh
open build/TokenTool.app
```

`build.sh` 会分别编译 `arm64` 与 `x86_64`，用 `lipo` 合并为通用二进制，并进行 ad-hoc 签名。

安装到「应用程序」：

```bash
cp -R build/TokenTool.app /Applications/
open /Applications/TokenTool.app
```

## 数据来源与隐私

所有数据均在本机通过官方客户端 / CLI 获取，不上传任何用量或账号信息。

| 平台 | 采集方式 | 说明 |
| --- | --- | --- |
| Qoder | 官方 CLI `qoderclicn` 的 `/usage` 面板 | 通过伪终端自动进入会话并读取额度，不读取、不解密 Qoder 的加密登录文件，也不访问 Keychain |
| WorkBuddy | 本机 WBIPC 通道 | 与运行中的客户端完成本机握手后，调用其额度汇总接口，仅在本机通信 |
| Codex | ChatGPT.app 内置 `codex app-server` | 通过 JSON-RPC 调用 `account/read` 与 `account/rateLimits/read`，不直接读取登录凭据 |

补充说明：

- 应用不会打印或保存 token、refresh token、密码、邮箱、UIN 等敏感信息。
- 提醒由 macOS 本地通知调度，不经过任何服务器。
- 缓存仅包含套餐、额度、百分比、时间戳等展示数据，路径为：
  ```
  ~/Library/Application Support/TokenTool/cache.json
  ```
- 清除缓存：退出应用后删除上述文件即可。
- 用量接口可能随官方客户端升级而变化；如遇读取失败，请先更新对应客户端或 CLI。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| Qoder 提示「未登录」 | 点击卡片上的「终端登录」，或执行 `~/.local/bin/qoderclicn login` |
| Qoder 提示「未安装」 | 点击「安装 CLI」查看官方文档，或执行 `curl -fsSL https://static.qoder.com.cn/qoder-cli-cn/install.sh \| bash` |
| Qoder 读取超时 | 确认 CLI 可在终端正常打开 `/usage`；首次运行需信任工作目录 |
| WorkBuddy 未运行 / 授权失效 | 打开 WorkBuddy 并重新登录，保持客户端运行后刷新 |
| Codex 提示未找到 CLI | 安装并登录 ChatGPT.app，确认 `/Applications/ChatGPT.app` 存在 |
| 刷新失败但仍有旧数据 | 卡片显示「上次成功」，数据保留，稍后手动刷新即可 |
| 菜单栏找不到应用 | 确认未全部隐藏（全部隐藏时显示 `AI`）；或重新启动应用 |
| 开机启动无效 | 检查 `~/Library/LaunchAgents/com.local.tokentool.plist` 是否存在，并在面板重新开关一次 |
| 没有收到提醒 | 在「系统设置 → 通知」中允许 TokenTool / AI 用量 的通知权限；面板出现提示时点击「去开启」 |

## 卸载

```bash
osascript -e 'quit app "TokenTool"'
rm -rf /Applications/TokenTool.app
launchctl bootout gui/$(id -u)/com.local.tokentool 2>/dev/null
rm -f ~/Library/LaunchAgents/com.local.tokentool.plist
rm -rf ~/Library/Application\ Support/TokenTool
defaults delete com.local.tokentool 2>/dev/null
```

## 项目结构

```
.
├── TokenToolApp.swift   # MenuBarExtra 入口，无 Dock 图标
├── Views.swift          # 菜单栏标签、详情面板、数据状态与刷新调度
├── collector.py         # Codex / WorkBuddy / Qoder 本地数据采集器
├── Info.plist           # 应用元数据（LSUIElement / 版本号）
├── build.sh             # 通用二进制构建与 ad-hoc 签名
└── README.md
```

## 版本记录

### 1.2.1

- Qoder 与 WorkBuddy 的菜单栏和详情改为显示积分数值，不再显示百分比。
- WorkBuddy 菜单栏积分改为完整数值（如 `3,523`），不再使用 `3.5k` 缩写。

### 1.2.0

- 新增领取提醒：Qoder 每天 10:00、WorkBuddy 每天 00:00，Codex 按限额窗口重置时间提醒。
- 三路提醒可独立开关，状态持久化；系统通知未授权时面板提供开启入口。
- 提醒通过 macOS 本地通知调度，不依赖服务器。

### 1.1.0

- 新增 Qoder / WorkBuddy / Codex 菜单栏独立显示开关，状态持久化。
- 全部隐藏时保留 `AI` 入口，面板与数据采集不受影响。
- 每张卡片新增「打开」客户端与「官网」快捷链接。
- Qoder 未登录 / 未安装时提供「终端登录」「安装 CLI」快捷操作。
- 修正 ChatGPT.app 的 Bundle ID（`com.openai.codex`）。

### 1.0.0

- 首个版本：菜单栏展示三家额度，详情面板、自动刷新、开机启动、本地缓存。

## 免责声明

本项目为非官方工具，与 Qoder、WorkBuddy、OpenAI 无隶属关系。数据读取依赖各官方客户端 / CLI 的本地接口，接口变更可能导致暂时不可用；请以官方客户端显示为准。
