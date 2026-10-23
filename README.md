# dsh-idm-download

**给 DSH 里的智能体自己用的下载加速器。** 模型要拉插件、拉仓库归档、拉 release 二进制、拉依赖包时，
单线程 `curl` 往往慢到没法干活；把这条下载交给 **Internet Download Manager（IDM）** 多连接分段拉，
落盘之后把路径交还给模型，模型拿着路径直接解包使用。

> 不是给用户点按钮下电影的下载器。它的存在意义是：**模型自己干活时别再被下载速度卡住。**

GitHub / `codeload` / `raw.githubusercontent.com` 这类源经常对单连接限速，或者传到一半把连接掐掉；
IDM 会开多连接分段拉同一个文件，通常快得多。这个插件就是那座桥：

> Windows only · 需要本机已安装 IDM · DSH ≥ 0.2.0

### 什么时候该用、什么时候不该用

| 场景 | 走哪条 |
| --- | --- |
| 估计 ≥ 1 MB（release、仓库 zip/tar、插件包、二进制、模型、数据集） | `idm_download` |
| 已知慢速/掐连接的源（github.com、codeload、raw.githubusercontent、sourceforge、npm tarball） | `idm_download` |
| 几百字节 ~ 1 MB 的小文件、纯文本、API JSON | 普通 `curl` / `Invoke-WebRequest`，别惊动 IDM |

---

## 装上之后多出两个工具

| 工具 | 作用 |
| --- | --- |
| `idm_download` | 把 URL 交给 IDM 下载，等文件大小稳定后返回路径 / 字节数 / 耗时 |
| `idm_status` | IDM 是否安装、版本、是否在运行、保存目录、有没有配代理 |

模型调用示例：

```jsonc
// 慢速 GitHub 文件：指定目录 + 文件名
{ "url": "https://raw.githubusercontent.com/git/git/master/README.md",
  "dir": "D:\\downloads", "fileName": "git-readme.md" }

// 大文件只丢进 IDM 队列，立刻返回
{ "url": "https://example.com/big.iso", "wait": false }

// 卡住就设超时（秒）
{ "url": "https://example.com/file.zip", "timeoutSec": 600 }
```

返回：

```json
{ "ok": true, "queued": false, "path": "D:\\downloads\\git-readme.md",
  "fileName": "git-readme.md", "bytes": 3808, "elapsedMs": 4531 }
```

## 安装

**桌面端（Electron 管理的 profile）只能用界面装：**

1. 左侧栏 → **插件**（Plugins）
2. 右上 **Add plugin**
3. 粘进 Git 地址：`github:hongyehe646-afk/dsh-idm-download`
4. **Install** → 装完点 **Enable now**（或重启 DSH）

**命令行 profile：**

```bash
# 注意 --profile 必须放在 add 前面
dsh plugin --profile <profile> add github:hongyehe646-afk/dsh-idm-download

# 或者用压缩包（国内网络更稳）
dsh plugin --profile <profile> add https://github.com/hongyehe646-afk/dsh-idm-download/archive/refs/heads/main.zip
```

卸载：插件页里 Remove，或 `dsh plugin --profile <profile> remove dsh-idm-download`。

## ⚠️ 先解决代理，否则 GitHub 依然连不上

**IDM 默认不走 Windows 系统代理**，它有自己的代理设置。如果你挂着 Clash / FlClash / v2ray 之类，请：

1. IDM → `选项`（Options）→ `代理服务器 / Socks`（Proxy / Socks）
2. 勾选 `使用 HTTP 代理`，填 `127.0.0.1` 和你本地混合端口（Clash 常见 `7890`）
3. 确定后重试

`idm_status` 的 `httpProxy` 字段会告诉你 IDM 里有没有配代理；`false` 时模型会知道要提醒你先配。

## 为什么要用「界面自动化」这种办法

正常思路是调 IDM 的 COM API（`IDMan.CIDMLinkTransmitter`）或命令行：

```bat
IDMan.exe /d "https://example.com/file.zip" /p "D:\downloads" /f file.zip /n /q
```

现实是：**大量国内安装包（尤其是被重新打包的 IDM）把 COM 注册弄坏了，命令行则静默失败**—— `/d` 立刻返回 0、退出码漂亮，但下载列表里什么都不加，也不报错。本机实测：

| 途径 | 结果 |
| --- | --- |
| `IDMan.exe /d ... /n /q` | 退出码 0，无任务、无文件 |
| COM `IDMan.CIDMLinkTransmitter` | `E_ACCESSDENIED` / `CO_E_SERVER_EXEC_FAILURE`，32 位也拿不到 |
| IE 的 `DownlWithIDM.IDMDwnlMgr` | 对象能创建，但 `QueryInterface` 拿不到任何下载接口 |
| 浏览器扩展的 native messaging | 协议是混淆的紧凑二进制，不是 JSON |
| **IDM 自己的「新建任务」对话框** | ✅ 稳定可用 |

所以插件改成：用 Win32 消息驱动 IDM 自己的对话框——**不截图、不抢焦点、不需要 SendInput**。

## 工作原理（给好奇的人）

1. 确保 IDM 进程在跑；如果它缩在托盘里（`MainWindowHandle == 0`），用 `ShowWindow` 把主窗口叫回来。
2. 向主窗口 `PostMessage(WM_COMMAND, 32771)` —— 就是菜单里「任务 → 新建任务」那一项，绕过 owner-draw 菜单点不中的问题。
3. 等到标题为「输入新任务的地址」的 `#32770` 对话框，往地址框（控件 id `1001`）逐字符 `PostMessage(WM_CHAR)`。
   - 注意：`WM_SETTEXT` 读回来是对的，但 IDM 提交时会用自己记住的旧值覆盖，等于白设，所以必须逐字符输入。
4. `BM_CLICK` 点「确定」（id `1022`）。
5. 之后可能出现的对话框都处理掉：
   - 「下载文件信息」→ 填另存为目录（`1008` 是 ComboBox，真正接收输入的是它的子 Edit）和文件名（`1009`），点「开始下载」（`1006`）。
   - 「重复下载」→ 选「覆盖原文件」（`1643`）再确认。
   - 报错框 → 读出静态文本，作为错误抛出，不静默超时。
6. 有些 URL 根本不弹「下载文件信息」，直接开下（文件名它自己定、还可能自动改名 `xxx_2`）。所以插件**同时盯着**你指定的目录、IDM 的保存目录、`%USERPROFILE%\Downloads`，用「下载开始前的文件指纹快照」找出新出现的那个文件，大小连续 3 次不变即视为完成，再 `Move-Item` 到你要求的路径。
7. 关掉「下载完成」提示框，返回结果。

指纹快照这一步是必须的：只看「最近修改过的文件」会把你刚编辑过的源码当成下载结果移走（开发时真踩过）。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `IDM main window could not be shown` | 手动打开一次 IDM 主窗口，或结束 `IDMan.exe` 让插件重新拉起 |
| `IDM rejected the URL: ...` | 后面跟的就是 IDM 弹框里的原文（404、需要登录、防盗链等） |
| 超时且没文件 | 多半是网络/代理问题，先按上面配 IDM 代理；也可能是 IDM 卡在「正在连接」 |
| 文件落到 `Downloads` 而不是你给的目录 | 该 URL 没弹保存对话框，插件已按你给的 `dir`/`fileName` 搬过去了；若搬运失败会直接报错而不是假装成功 |
| 报"对话框没出现" | 有别的 IDM 模态框挡着。先手动关掉 IDM 里所有弹窗再试 |
| 装了多个 IDM / 绿色版 | 插件按注册表 `HKCU\Software\DownloadManager\ExePath` 和两个默认安装路径找 `IDMan.exe` |

## 已知限制

- 只有 Windows；Web 版 DSH 必须跑在装了 IDM 的那台机器上（插件在 Host 侧执行）。
- 需要 IDM 能正常弹窗：被安全软件拦截弹窗、或 IDM 处于"静默模式"时会失败。
- 不解析 IDM 的进度：只以"目标文件存在且大小稳定"判定完成，所以分片下载中的 `.tmp` 会被跳过。
- 需要下载鉴权头（Cookie / Referer）的站点暂不支持，因为对话框没有这些输入项。

## 开发

```bash
git clone https://github.com/hongyehe646-afk/dsh-idm-download
cd dsh-idm-download
# 本地链接安装（改完重启 DSH 生效）
dsh plugin add link:$(pwd)
```

结构：

```
lib/index.js          # 两个工具的定义 + 调 PowerShell 桥
scripts/idm-bridge.ps1 # 全部 Win32 对话框逻辑（可单独命令行测试）
cordis.patch.yml      # bundle patch，注册插件
```

桥脚本可以脱离 DSH 单测：

```powershell
$p = @{ action='status' } | ConvertTo-Json -Compress
$b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p))
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/idm-bridge.ps1 -Payload $b
```

> 参数为什么用 base64：Windows PowerShell 用 `-File` 接收参数时会重新解析引号，反斜杠会被吃掉（`D:\a\b` 变成 `D:ab`）。整包 base64 是唯一稳妥的传参方式。

## License

MIT
