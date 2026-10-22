# TokenTool

macOS 顶部菜单栏 AI 用量监控工具，实时查看 **Qoder**、**WorkBuddy**、**Codex** 的额度与剩余用量。

无 Dock 图标、无后台常驻窗口，点击菜单栏即可展开详情；三家平台可独立控制是否显示在菜单栏，并可直接打开对应客户端或官网，还支持每日领取与额度重置提醒。项目以 **MIT** 协议开源，并内置版本检查与升级入口。

当前版本：**1.4.0**（build 6） · 许可证：[MIT](LICENSE) · 源码：[GitHub](https://github.com/pumf/token_tool)

## 功能

- **菜单栏常驻**：紧凑显示三家的关键指标（Qoder 剩余积分、WorkBuddy 剩余积分、Codex 已用比例），带完整 tooltip。
- **独立显示开关**：面板底部可分别隐藏 / 显示 Qoder、WorkBuddy、Codex；全部隐藏时仍保留一个 `AI` 入口，点击照常展开面板，数据也继续在后台采集。
- **自适应面板**：面板高度随屏幕可用区域自动调整；屏幕较小时内容可滚动，不再被裁切。
- **详情面板**：套餐名称、Credits 进度条、剩余 / 总量、限额窗口、重置时间、最后更新时间与错误状态。
- **用量洞察**：按本机历史采样估算今日消耗与近 7 日日均；领取额度或窗口重置带来的增加不计入消耗。
- **快捷入口**：每张卡片提供「打开」客户端与「官网」链接；Qoder 未登录 / 未安装时额外提供「终端登录」「安装 CLI」按钮。
- **领取提醒**：Qoder 每天 10:00、WorkBuddy 每天 00:00 提醒领取 100 额度；Codex 按最长限额窗口的重置时间提醒。三路可独立开关。
- **趋势与耗尽预测**：每 5 分钟记录一次用量快照，展示近 7 天剩余比例曲线，并按近期消耗速度估算额度耗尽时间；Codex 会判断能否撑到窗口重置。
- **智能预警**：支持低额度（剩余 ≤ 20%）、预计重置前耗尽、消耗突然加速三类本地通知，可独立开关。
- **通知快捷动作**：点击领取、重置或预警通知可直接打开对应客户端。
- **版本检查与升级**：每 24 小时自动检查 GitHub Releases，也可手动「检查更新」；发现新版本后自动匹配当前芯片下载 DMG 并打开，拖入「应用程序」即可完成升级。
- **开源信息**：面板底部展示当前版本、GitHub 源码与 MIT 许可证入口。
- **自动刷新**：Codex 与 WorkBuddy 每 60 秒，Qoder 每 5 分钟；支持手动刷新，系统唤醒后自动刷新一次。
- **本地缓存**：启动时先展示上次数据，再异步更新；历史快照保留 14 天。
- **开机启动**：面板一键开关，通过 LaunchAgent 实现，不产生 Dock 图标。
- **原生安装包**：分别提供 Apple Silicon（arm64）与 Intel（x86_64）安装包，另附通用二进制，最低 macOS 12。
- **应用图标**：三色环形仪表盘图标，安装后可在访达、启动台与 DMG 中识别。

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

首次开启提醒或预警会请求系统通知权限；若系统通知被关闭，面板会显示提示和「去开启」入口。

「智能预警」一行的三个按钮：

| 按钮 | 行为 |
| --- | --- |
| `低额度` | 任一平台剩余比例降至 20% 及以下时提醒，恢复至 25% 以上后重新布防 |
| `重置前耗尽` | Codex 按近期速度预计会在限额窗口重置前用完时提醒 |
| `消耗加速` | 近 15 分钟消耗速度达到此前 1 小时的 2.5 倍以上时提醒 |

预警均为本机通知，并带冷却时间去重，避免短时间内重复弹出。预测基于历史消耗速度，领取额度或窗口重置后需要几个采样点重新稳定，仅供提前预警参考。

卡片底部会出现一条趋势行：左侧是近 7 天剩余比例曲线，右侧是预测结论。历史数据不足（少于两个采样点）时暂不显示。

趋势行上方会显示「今日消耗 · 近 7 日日均」；日均至少需要 6 小时历史样本，数据不足时显示 `--`。

面板最底部：

| 元素 | 说明 |
| --- | --- |
| `v1.4.0` | 当前安装版本 |
| `GitHub` | 打开项目源码仓库 |
| `MIT` | 打开 MIT 许可证 |
| `检查更新` / `已是最新` / `重试检查` | 手动检查 GitHub Releases；失败时悬停可查看原因 |

### 版本与更新

- 应用启动后及面板打开时会检查更新，自动检查最多每 24 小时一次；底部按钮可随时手动检查。
- 优先请求 GitHub Releases API；若 API 被限流或不可用，会自动回退到发布页，不要求登录或 Token。
- 发现新版本时，面板顶部显示「新版本 x.y.z 可用」，并下载与当前芯片匹配的安装包：arm64 选 `-arm64.dmg`，Intel 选 `-x86_64.dmg`，找不到时使用通用 DMG。
- 下载完成后自动打开 DMG，将 **TokenTool** 拖入「应用程序」覆盖旧版本即可；应用不会静默替换自身，避免 ad-hoc 签名应用的权限与 Gatekeeper 问题。
- 更新检查遵循系统代理设置；若使用代理访问 GitHub，请确认「系统设置 → 网络 → 代理」已配置。
- 更新检查只读取版本号与安装包地址，不上传任何账号、额度或使用数据。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 12 Monterey 及以上 |
| 架构 | Apple Silicon（arm64）或 Intel（x86_64），提供独立安装包与通用版本 |
| Python | Python 3（系统 Command Line Tools 自带即可） |
| Qoder | 已安装官方 CLI `qoderclicn` 并完成登录 |
| WorkBuddy | 客户端已安装、已登录并保持运行 |
| Codex | ChatGPT.app 已安装并登录（内置 codex CLI） |

## 安装

### 从 Release 安装（推荐）

按 Mac 芯片选择对应安装包（DMG 与 ZIP 内容相同，任选其一）：

| Mac 类型 | 安装包 |
| --- | --- |
| Apple Silicon（M1 / M2 / M3 / M4…） | [`TokenTool-1.4.0-arm64.dmg`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0-arm64.dmg) / [`.zip`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0-arm64.zip) |
| Intel（x86_64） | [`TokenTool-1.4.0-x86_64.dmg`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0-x86_64.dmg) / [`.zip`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0-x86_64.zip) |
| 不确定 / 通用版本 | [`TokenTool-1.4.0.dmg`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0.dmg) / [`.zip`](https://github.com/pumf/token_tool/releases/download/v1.4.0/TokenTool-1.4.0.zip) |

不确定芯片类型时，点击左上角苹果菜单 →「关于本机」，查看「芯片」一栏：Apple M 系列选 `arm64`，Intel 选 `x86_64`。

1. 下载与芯片匹配的 DMG 或 ZIP。
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

`build.sh` 会分别编译 `arm64` 与 `x86_64`，产出：

- `build/TokenTool-arm64.app`：Apple Silicon 原生版本
- `build/TokenTool-x86_64.app`：Intel 原生版本
- `build/TokenTool.app`：用 `lipo` 合并的通用版本

三个应用包均包含图标与采集器，并完成 ad-hoc 签名。

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
- 版本检查仅访问 GitHub 的公开 Releases 页面 / API，不携带账号凭据或用量数据；安装包从 GitHub Releases 下载。
- 缓存与历史仅包含套餐、额度、百分比、时间戳等展示数据，路径为：
  ```
  ~/Library/Application Support/TokenTool/cache.json
  ~/Library/Application Support/TokenTool/history.json
  ```
- 历史快照最多保留 14 天，用于趋势与耗尽预测；不包含任何账号凭据。
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
| 检查更新失败 | 确认网络或系统代理可访问 GitHub；应用在 API 限流时会自动回退发布页，稍后点「重试检查」即可 |
| 更新下载后如何安装 | 应用会自动打开对应芯片的 DMG，将 TokenTool 拖入「应用程序」覆盖旧版本，再重新启动 |
| 已是最新但 Release 有更新 | 点击底部「已是最新」重新检查；若仍不生效，确认版本号大于当前安装版本 |

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
├── TokenToolApp.swift   # NSStatusItem + NSPopover 入口，无 Dock 图标
├── Views.swift          # 菜单栏标签、详情面板、数据状态、通知与刷新调度
├── Analytics.swift      # 历史采样、趋势与耗尽预测、加速检测、用量洞察
├── Update.swift         # GitHub Releases 版本检查、安装包匹配与下载
├── collector.py         # Codex / WorkBuddy / Qoder 本地数据采集器
├── AppIcon.icns         # 应用图标
├── LICENSE              # MIT 开源许可证
├── Info.plist           # 应用元数据（LSUIElement / 图标 / 版本号）
├── build.sh             # arm64 / x86_64 / 通用版本构建与 ad-hoc 签名
└── README.md
```

## 版本记录

### 1.4.0

- 新增自适应详情面板：按屏幕可用高度调整，小屏自动滚动，底部设置不再被裁切。
- 新增用量洞察：展示今日消耗与近 7 日日均，领取或重置带来的增加不计入消耗。
- 新增版本检查与升级：每 24 小时自动检查 GitHub Releases，也可手动检查；自动匹配 arm64 / x86_64 / 通用安装包并打开 DMG。
- GitHub API 限流或不可用时自动回退到发布页，更新检查无需登录或 Token。
- 面板底部新增当前版本、GitHub 源码与 MIT 许可证入口。
- 项目以 MIT License 开源，补充版本与开源信息。
- arm64、x86_64 与通用包同步更新。

### 1.3.1

- 最低系统要求从 macOS 13 降至 macOS 12 Monterey。
- 菜单栏入口由 SwiftUI `MenuBarExtra` 改为 AppKit `NSStatusItem + NSPopover`，功能与面板内容不变。
- arm64、x86_64 与通用包同步更新。

### 1.3.0

- 新增近 7 天用量趋势曲线与额度耗尽时间预测。
- 新增低额度、重置前耗尽、消耗加速三类智能预警，均可独立开关。
- 通知支持快捷动作，点击后直接打开对应客户端。
- 历史快照保留 14 天，用于趋势和预测；不记录任何账号凭据。

### 1.2.1

- Qoder 与 WorkBuddy 的菜单栏和详情改为显示积分数值，不再显示百分比。
- WorkBuddy 菜单栏积分改为完整数值（如 `3,523`），不再使用 `3.5k` 缩写。
- 新增应用图标：深色圆角底、三色环形仪表盘与白色指针。
- 新增 Apple Silicon（arm64）与 Intel（x86_64）独立安装包，同时保留通用版本。

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

## 开源许可

本项目采用 [MIT License](LICENSE) 开源。

| 项目 | 地址 |
| --- | --- |
| 源码仓库 | <https://github.com/pumf/token_tool> |
| 问题反馈 | <https://github.com/pumf/token_tool/issues> |
| 版本发布 | <https://github.com/pumf/token_tool/releases> |
| 当前版本 | 1.4.0（build 6） |

欢迎提交 Issue 与 Pull Request。应用内的「检查更新」会读取 GitHub Releases 的最新版本，不会上传任何本地数据。

## 免责声明

本项目为非官方工具，与 Qoder、WorkBuddy、OpenAI 无隶属关系。数据读取依赖各官方客户端 / CLI 的本地接口，接口变更可能导致暂时不可用；请以官方客户端显示为准。
