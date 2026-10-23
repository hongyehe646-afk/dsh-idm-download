# dsh-idm-download

[![DeepSeek Harness plugin](https://img.shields.io/badge/DeepSeek%20Harness-plugin-4B6EF5)](https://github.com/deepseek-ai)
[![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-lightgrey)](#requirements)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**这是一个 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）插件。**

它给智能体一副自己的下载加速器：模型要拉插件、拉仓库归档、拉 release 二进制、拉依赖包时，把这条下载交给
**Internet Download Manager（IDM）** 多连接分段拉，落盘之后把绝对路径交还给模型，模型拿着路径直接解包使用。

**A [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin that hands the agent's own downloads to Internet Download Manager.**

The model asks for a release, a repo archive, a plugin tarball or a binary; the plugin drives IDM, waits for the bytes to
land, and returns the absolute path so the agent can unpack and keep working.

> 不是给用户点按钮下电影的下载器。它的存在意义是：**模型自己干活时别再被单线程下载卡住。**
> Not a downloader for end users to click. It exists so the agent stops stalling on slow single-stream `curl`.

- [中文](#中文)
- [English](#english)

---

# 中文

## 这是什么

DSH 里的模型经常需要临时下载东西：装插件、拉 GitHub 归档、取 release 里的 exe、下模型权重。这些源对单连接限速，
传到一半还可能把连接掐掉，`curl` / `Invoke-WebRequest` 单流慢慢爬能把一次任务拖成十几分钟。

IDM 会把同一个文件切成多段并发拉，通常快得多。这个插件就是那座桥：

```
模型 → idm_download → PowerShell 桥 → IDM（多线程）→ 落盘 → 返回路径 → 模型解包使用
```

## 要求

| 项 | 说明 |
| --- | --- |
| 系统 | Windows 10 / 11 |
| IDM | 已安装 Internet Download Manager 6.x（本机实测 6.43） |
| DSH | ≥ 0.2.0，插件在 Host 侧执行 |
| 桌面 | **不能锁屏/睡眠**，插件通过 Win32 消息驱动 IDM 的对话框 |

## 安装

**桌面端（Electron 管理的 profile）只能用界面装：**

1. 左侧栏 → **插件**
2. 右上 **添加插件**
3. 粘贴：`https://github.com/hongyehe646-afk/dsh-idm-download`
4. **安装** → 装完点 **立即启用**

**命令行 profile：**

```bash
# 注意 --profile 必须写在 add 前面
dsh plugin --profile <profile> add github:hongyehe646-afk/dsh-idm-download
```

卸载：插件页里移除，或 `dsh plugin --profile <profile> remove dsh-idm-download`。

## 装完多出两个工具

| 工具 | 作用 |
| --- | --- |
| `idm_download` | 把 URL 交给 IDM，等文件落盘并稳定后返回路径 / 字节数 / 耗时 |
| `idm_status` | IDM 是否安装、版本、是否在跑、保存目录、有没有配代理 |

```jsonc
// 指定目录和文件名
{ "url": "https://github.com/Gathin23/cleanyourtv/archive/refs/tags/v2.7.0.zip",
  "dir": "D:\\downloads", "fileName": "cleanyourtv-v2.7.0.zip" }

// 大文件只丢进队列，立刻返回
{ "url": "https://example.com/big.iso", "wait": false }

// 给个超时（秒）
{ "url": "https://example.com/file.zip", "timeoutSec": 600 }
```

返回：

```json
{ "ok": true, "queued": false, "path": "D:\\downloads\\cleanyourtv-v2.7.0.zip",
  "fileName": "cleanyourtv-v2.7.0.zip", "bytes": 13234654, "elapsedMs": 41915 }
```

## 什么时候该用、什么时候不该用

| 场景 | 走哪条 |
| --- | --- |
| 估计 ≥ 1 MB（release、仓库 zip/tar、插件包、二进制、模型、数据集） | `idm_download` |
| 已知慢速/掐连接的源（github.com、codeload、raw.githubusercontent、sourceforge、npm tarball） | `idm_download` |
| 几百字节 ~ 1 MB 的小文件、纯文本、API JSON | 普通 `curl` / `Invoke-WebRequest`，别惊动 IDM |

## ⚠️ 先解决代理，否则 GitHub 依然连不上

**IDM 默认不走 Windows 系统代理**，它有自己的代理设置。挂着 Clash / FlClash / v2ray 的话：

1. IDM → `选项` → `代理服务器 / Socks`
2. 勾选 `使用 HTTP 代理`，填 `127.0.0.1` 和本地混合端口（Clash 常见 `7890`）
3. 确定后重试

`idm_status` 的 `httpProxy` 字段会告诉你 IDM 里配没配代理；`false` 时模型会提醒你先配。

## 为什么要用「界面自动化」这种办法

正常思路是调 IDM 的 COM API 或命令行，但这些路在本机实测全部走不通：

| 途径 | 结果 |
| --- | --- |
| `IDMan.exe /d … /n /q` | 退出码 0，下载列表里无任务、磁盘上无文件，静默失败 |
| COM `IDMan.CIDMLinkTransmitter` | `E_ACCESSDENIED`（0x80070005）；结束 IDM 后变 `CO_E_SERVER_EXEC_FAILURE`（0x80080005） |
| COM `DownlWithIDM.IDMDwnlMgr` | 对象能创建，`QueryInterface` 拿不到 `IDownloadManager`，只有 `IUnknown` |
| 浏览器扩展的 native messaging | 协议是混淆的紧凑数组，不是 JSON，逆向成本过高 |
| **IDM 自己的「新建任务」对话框** | ✅ 稳定可用 |

所以插件改成：用 Win32 消息驱动 IDM 自己的对话框——**不截图、不抢焦点、不需要 SendInput**。
完整的踩坑记录见 [PITFALLS.md](PITFALLS.md)。

## 工作原理

1. 确保 IDM 进程在跑；缩在托盘里（`MainWindowHandle == 0`）就用 `ShowWindow` 把主窗口叫回来。
2. 向主窗口 `PostMessage(WM_COMMAND, 32771)` —— 菜单里「任务 → 新建任务」那一项，绕过 owner-draw 菜单点不中的问题。
3. 等到「输入新任务的地址」`#32770` 对话框，往地址框（控件 id `1001`）逐字符 `PostMessage(WM_CHAR)`。
   - `WM_SETTEXT` 读回来是对的，但 IDM 提交时会用自己记住的旧值覆盖，等于白设，必须逐字符输入。
4. `BM_CLICK` 点「确定」（`1022`）。
5. 之后可能出现的对话框全部接管：
   - 「下载文件信息」→ 填另存为目录（`1008` 是 ComboBox，真正接收输入的是子 Edit）和文件名（`1009`），点「开始下载」（`1006`）。
   - **「服务器文件名不一致」→ 自动点「是」**（采用服务器给的名字），下载完再按你指定的名字重命名。
   - 「重复下载」→ 选「覆盖原文件」（`1643`）再确认。
   - 报错框 → 读出静态文本作为错误抛出，不静默超时。
6. 有些 URL 根本不弹「下载文件信息」，直接开下（名字它自己定、还可能自动改名 `xxx_2`）。所以插件**同时盯着**
   你指定的目录、IDM 保存目录、`%USERPROFILE%\Downloads`，用下载前的文件指纹快照找出新出现的那个文件，
   大小连续 3 次不变即视为完成，再 `Move-Item` 到你要求的路径。
7. 关掉「下载完成」提示框，返回结果。

指纹快照是必须的：只看「最近修改过的文件」会把你刚编辑过的源码当成下载结果移走（开发时真踩过）。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `IDM main window could not be shown` | 手动打开一次 IDM，或结束 `IDMan.exe` 让插件重新拉起 |
| `IDM rejected the URL: …` | 后面跟的就是 IDM 弹框原文（404、需要登录、防盗链等） |
| 超时且没文件 | 多半是网络/代理问题，先按上面配 IDM 代理；也可能卡在「正在连接」 |
| 文件落到 `Downloads` 而不是你给的目录 | 该 URL 没弹保存框，插件已按 `dir`/`fileName` 搬过去；搬运失败会直接报错而不是假装成功 |
| 报「对话框没出现」 | 有别的 IDM 模态框挡着，先手动关掉所有弹窗再试 |
| 装了多个 IDM / 绿色版 | 插件按 `HKCU\Software\DownloadManager\ExePath` 和两个默认安装路径找 `IDMan.exe` |

## 已知限制

- 只有 Windows；Web 版 DSH 必须跑在装了 IDM 的那台机器上（插件在 Host 侧执行）。
- 需要 IDM 能正常弹窗：被安全软件拦弹窗、或 IDM 处于「静默模式」时会失败。
- 不解析 IDM 的进度条：只以「目标文件存在且大小稳定」判定完成，分片下载中的 `.tmp` 会被跳过。
- 需要鉴权头（Cookie / Referer / UA）的站点暂不支持，对话框没有这些输入项。

## 开发

```bash
git clone https://github.com/hongyehe646-afk/dsh-idm-download
cd dsh-idm-download
# 本地链接安装（改完重启 DSH 生效）
dsh plugin --profile <profile> add link:$(pwd)
```

```
lib/index.js           # 两个工具的定义 + 调 PowerShell 桥
scripts/idm-bridge.ps1 # 全部 Win32 对话框逻辑（可单独命令行测试）
cordis.patch.yml       # bundle patch，注册插件
```

桥脚本可脱离 DSH 单测：

```powershell
$p = @{ action='status' } | ConvertTo-Json -Compress
$b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p))
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/idm-bridge.ps1 -Payload $b
```

> 参数为什么用 base64：Windows PowerShell 用 `-File` 接收参数时会重新解析引号，反斜杠会被吃掉
> （`D:\a\b` 变成 `D:ab`）。整包 base64 是唯一稳妥的传参方式。

---

# English

## What it is

A **[DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin**. DSH agents constantly fetch things mid-task:
plugins, GitHub archives, release binaries, model weights. Those hosts throttle a single connection and often drop it
halfway, so a plain `curl` / `Invoke-WebRequest` can turn a two-minute job into fifteen.

IDM splits one file across several connections and is usually far faster. This plugin is the bridge:

```
agent → idm_download → PowerShell bridge → IDM (multi-connection) → file lands → path returned → agent unpacks it
```

## Requirements

| Item | Notes |
| --- | --- |
| OS | Windows 10 / 11 |
| IDM | Internet Download Manager 6.x installed (verified on 6.43) |
| DSH | ≥ 0.2.0; the plugin runs on the Host side |
| Desktop | **must stay unlocked** — the plugin drives IDM dialogs via Win32 messages |

## Install

**Desktop app (Electron-managed profile): use the UI.**

1. Sidebar → **Plugins**
2. **Add plugin** (top right)
3. Paste `https://github.com/hongyehe646-afk/dsh-idm-download`
4. **Install** → **Enable now**

**CLI profile:**

```bash
dsh plugin --profile <profile> add github:hongyehe646-afk/dsh-idm-download
```

## Tools

| Tool | Purpose |
| --- | --- |
| `idm_download` | Hand a URL to IDM, wait until the file lands and its size is stable, return path / bytes / elapsed |
| `idm_status` | Is IDM installed, which version, is it running, default save folder, is a proxy configured |

```jsonc
{ "url": "https://github.com/Gathin23/cleanyourtv/archive/refs/tags/v2.7.0.zip",
  "dir": "D:\\downloads", "fileName": "cleanyourtv-v2.7.0.zip" }
```

## When to use it, when not to

| Case | Path |
| --- | --- |
| Expected ≥ 1 MB (releases, repo archives, plugin tarballs, binaries, weights, datasets) | `idm_download` |
| Hosts that throttle or cut single streams (github.com, codeload, raw.githubusercontent, sourceforge, npm tarballs) | `idm_download` |
| A few hundred bytes up to ~1 MB, plain text, API JSON | plain `curl` / `Invoke-WebRequest` — don't wake IDM up |

## ⚠️ Fix the proxy first

**IDM does not use the Windows system proxy by default.** If you run Clash / v2ray / FlClash:

1. IDM → `Options` → `Proxy / Socks`
2. Tick `Use HTTP proxy`, enter `127.0.0.1` and your local mixed port (Clash: `7890`)
3. OK, then retry

`idm_status` reports `httpProxy`; when it is `false` the agent knows to ask you to configure it.

## Why UI automation instead of the API

The obvious routes are IDM's COM API and its command line. Both are dead on many real-world installs, including the one
this plugin was developed on:

| Route | Result |
| --- | --- |
| `IDMan.exe /d … /n /q` | exit code 0, no task in the list, no file on disk — silent no-op |
| COM `IDMan.CIDMLinkTransmitter` | `E_ACCESSDENIED` (0x80070005); with IDM stopped, `CO_E_SERVER_EXEC_FAILURE` (0x80080005) |
| COM `DownlWithIDM.IDMDwnlMgr` | object creates fine, but `QueryInterface` never yields `IDownloadManager` |
| Browser-extension native messaging | obfuscated compact array protocol, not JSON; not worth reversing |
| **IDM's own "new task" dialog** | ✅ reliable |

So the plugin drives IDM's own dialogs with Win32 messages — **no screenshots, no focus stealing, no SendInput**.
The full war story is in [PITFALLS.md](PITFALLS.md).

## How it works

1. Make sure IDM runs; if it is minimized to tray (`MainWindowHandle == 0`), bring the main window back with `ShowWindow`.
2. `PostMessage(WM_COMMAND, 32771)` to the main window — that is the `Tasks → Add new download` menu item, which bypasses
   the owner-drawn menu that cannot be clicked programmatically.
3. Wait for the `#32770` dialog titled "Enter the address of the new task", then type the URL into control `1001` one
   character at a time with `PostMessage(WM_CHAR)`.
   - `WM_SETTEXT` reads back correctly but IDM overwrites it with its remembered value on commit, so it must be typed.
4. `BM_CLICK` on OK (`1022`).
5. Take over whatever dialog shows up next:
   - "Download file info" → fill the save folder (`1008` is a ComboBox; the child Edit takes the text) and the file name
     (`1009`), click "Start download" (`1006`).
   - **"Server file name differs" → answer Yes automatically** (keep the server's name), then rename to your requested
     name after the transfer.
   - "Duplicate download" → pick "overwrite" (`1643`) and confirm.
   - Error boxes → read the static text and throw it as the error instead of timing out silently.
6. Some URLs skip the info dialog entirely and start downloading with their own name (sometimes `name_2`). So the plugin
   watches **three** folders at once — your `dir`, IDM's save folder, `%USERPROFILE%\Downloads` — fingerprints every file
   before the handoff, finds the new one afterwards, and treats "size unchanged 3 samples in a row" as complete. Then it
   `Move-Item`s the file to the exact path you asked for.
7. Dismiss the "download complete" box and return.

The fingerprint step is not optional: matching "most recently modified file" will happily move a source file you just
edited (this happened during development).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `IDM main window could not be shown` | Open IDM once by hand, or kill `IDMan.exe` and let the plugin relaunch it |
| `IDM rejected the URL: …` | The rest is IDM's own message text (404, login required, hotlink protection) |
| Timeout, no file | Usually network/proxy — configure IDM's proxy as above; or it is stuck on "connecting" |
| File landed in `Downloads`, not your folder | That URL never showed a save dialog; the plugin already moved it to `dir`/`fileName`, and reports a hard error if the move fails |
| "dialog did not appear" | Another IDM modal is in the way — close all IDM popups and retry |
| Multiple IDM installs / portable build | The plugin resolves `IDMan.exe` from `HKCU\Software\DownloadManager\ExePath` and the two default install paths |

## Limitations

- Windows only; the Web build of DSH must run on the machine that has IDM (the plugin executes on the Host side).
- IDM must be able to show dialogs: blocked dialogs or IDM's silent mode will break it.
- It does not read IDM's progress bar: completion is "file exists and its size stopped changing", and `.tmp` parts are skipped.
- Sites that need custom headers (Cookie / Referer / UA) are not supported yet — those dialogs have no such fields.

## Development

```bash
git clone https://github.com/hongyehe646-afk/dsh-idm-download
cd dsh-idm-download
dsh plugin --profile <profile> add link:$(pwd)
```

```
lib/index.js           # tool definitions + node → PowerShell bridge
scripts/idm-bridge.ps1 # every Win32 dialog detail (also runnable standalone)
cordis.patch.yml       # bundle patch that registers the plugin
```

Standalone bridge test (no DSH needed):

```powershell
$p = @{ action='status' } | ConvertTo-Json -Compress
$b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p))
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/idm-bridge.ps1 -Payload $b
```

> Why base64: Windows PowerShell re-parses the command line for `-File` arguments and eats backslashes
> (`D:\a\b` becomes `D:ab`). Shipping one base64 payload is the only reliable way to pass paths.

## License

MIT — see [LICENSE](LICENSE).
