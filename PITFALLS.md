# 踩坑记录 / War stories

开发 [dsh-idm-download](README.md) 时在 IDM 6.43（Windows 11）上踩到的全部坑。
每条都写了**现象 → 根因 → 结论**，方便后来者少走弯路。

[中文](#中文) · [English](#english)

---

# 中文

## 1. COM `IDMan.CIDMLinkTransmitter` 拿不到

**现象**：`CreateObject("IDMan.CIDMLinkTransmitter")` 在 VBScript 里返回对象，`TypeName` 却是 `Unknown`；
调用 `SendLinkToIDM` / `SendLinkToIDM2` 报 `424 缺少对象`。PowerShell 的 `New-Object -ComObject` 配上 11 个参数报
「缺少没有默认值的参数」。

**根因**：`ICIDMLinkTransmitter2` 不是 `IDispatch`/dual 接口，只能早期绑定（vtable 固定偏移）。脚本语言走的是
`IDispatch::Invoke`，根本没有这条路。

**结论**：要么写 C# `[ComImport]` 早期绑定，要么放弃 COM。而且它只在
`HKLM\SOFTWARE\Classes\WOW6432Node\CLSID` 下注册，**32 位进程才能看见**。

## 2. 早期绑定也拿不到对象

**现象**：用 `[ComImport]` + 精确 IID 写了个 x86 的 `idm-bridge.exe`，`Activator.CreateInstance` 抛
`0x80070005 E_ACCESSDENIED`；把 IDM 进程杀掉再跑，变成 `0x80080005 CO_E_SERVER_EXEC_FAILURE`。

**根因**：AppID `{AC746233-E9D3-49CD-862F-068F7B7CCCA4}` 注册成 `RunAs = Interactive User`，跨会话激活被拒；
同一个 CLSID 在 64 位视图里压根没注册。

**结论**：这条路依赖 IDM 安装时的注册表完好度。大量重新打包的安装包（绿色版、国内魔改版）就是坏的，修不了。

## 3. 命令行 `/d` 静默失败

**现象**：

```bat
IDMan.exe /n /q /d "https://raw.githubusercontent.com/git/git/master/README.md" /p "D:\test" /f readme.md
```

退出码 `0`，一秒内返回，**下载列表里没有任务、磁盘上没有文件**。IDM 主窗口没启动时更绝：进程直接挂着不返回。

**根因**：`/q` 的语义是「下载完成后退出」，加 `/n` 静默后错误被彻底吞掉；IDM 还要求主程序已在运行。

**结论**：命令行不能当 API 用。它能正常工作的前提恰好是「你已经不需要它了」。

## 4. `DownlWithIDM.IDMDwnlMgr` 也拿不到下载接口

**现象**：`downlWithIDM.dll` 里注册了 `DownlWithIDM.IDMDwnlMgr`、`IDMLinkProcessor` 等 CLSID，对象能创建，
但 `QueryInterface` 只返回 `IUnknown`，要 `IDownloadManager` 一律 `E_NOINTERFACE`。TypeLib 里明明声明了 coclass 实现它。

**根因**：这些是给 IE 扩展用的内部对象，对外暴露的只有 `IDispatch` 的窄接口，真正的下载入口没公开。

**结论**：注册表里有 CLSID ≠ 能用。

## 5. 菜单项点不中

**现象**：`GetMenu` 能拿到菜单，`WM_COMMAND` 也行，但用 `SendInput`/`mouse_event` 去点「任务 → 新建任务」经常点空。

**根因**：IDM 的主菜单是 owner-draw 的，还带自绘图标，坐标会随 DPI 缩放漂移。

**结论**：别点菜单。直接 `PostMessage(main, WM_COMMAND, 32771, 0)` —— `32771` 就是「新建任务」的命令 ID，
从 `GetMenu` 枚举子项拿到的，跨版本稳定。

## 6. `WM_SETTEXT` 设了地址框，IDM 却用旧值

**现象**：往地址输入框（`1001`）`SendMessage(WM_SETTEXT)`，`GetWindowText` 读回来完全正确；一按确定，
IDM 用的是它自己记住的上一条 URL，下载的是错东西。

**根因**：IDM 的编辑框是自绘 + 自维护缓冲，`WM_SETTEXT` 只改了窗口文本，没进它内部的输入缓冲。

**结论**：必须逐字符 `PostMessage(WM_CHAR)` 喂进去，像人打字一样。附带好处：这不是「注入」，不触发任何防护。

## 7. PowerShell `-File` 把反斜杠吃掉

**现象**：`powershell -File idm-bridge.ps1 -OutDir "D:\downloads"` 里，脚本收到的 `$OutDir` 变成 `D:downloads`。

**根因**：Windows PowerShell 5.1 对 `-File` 的参数会重新做一次命令行解析，反斜杠和引号被二次转义吃掉。

**结论**：所有参数打包成 base64 JSON 一次传（`-Payload <base64>`），彻底绕开引号地狱。这条对任何
「Node/Go 调 PowerShell 脚本」的场景都适用。

## 8. 「服务器文件名不一致」弹窗把下载挂死

**现象**：下载 `.../v2.7.0.zip` 时 IDM 弹框：

> 待保存的文件名称是"v2.7.0"，但服务器发送了如下的文件名"cleanyourtv-2.7.0.zip"。您希望用服务器提供的文件名保存文件吗？

没人点它，传输就一直停在「正在连接」，调用方等到超时，最后报一个毫无信息量的 `The download was aborted.`。

**根因**：这是**下载过程中**的模态框，不在「新建任务」流程里，早期版本只处理了 info / 重复 / 报错三类对话框。

**结论**：等待循环里必须持续扫描「恰好两个按钮、文本是 是/否」的 `#32770`，自动点「是」（采用服务器文件名），
落盘后再按调用方要求的名字重命名。**任何模态确认框都会让后台任务永久挂起**——这类东西必须主动扫，不能等它自己消失。

## 9. 文件定位不能靠「最近修改」

**现象**：早期版本用「目标目录里最近修改的文件」判定下载结果，结果把刚编辑过的源码文件当成下载产物 `Move-Item` 走了。

**根因**：IDM 有时候不弹保存框，文件名自己定，甚至自动改名 `xxx_2`，落点也不一定是你指定的目录。

**结论**：下载前给三个候选目录（指定目录 / IDM 保存目录 / `Downloads`）拍一次「文件指纹快照」
（`LastWriteTimeUtc.Ticks + Length`），之后只认「快照里没有或已变化」的文件，并且要求大小连续 3 次采样不变。

## 10. IDM 缩在托盘时 `MainWindowHandle == 0`

**现象**：IDM 最小化到托盘后，`Process.MainWindowHandle` 返回 `0`，`PostMessage` 全部失败；
有时 `Process.GetProcessesByName` 里干脆看不到窗口，但 `IDMan.exe` 明明在跑。

**根因**：托盘态下主窗口被隐藏，`MainWindowHandle` 只认可见窗口。

**结论**：用 `EnumWindows` 按进程 ID 找类名 `#32770`、标题以 `Internet Download Manager` 开头的窗口，
再用 `ShowWindow(SW_RESTORE)` 叫回来；顺便用 `GetLastActivePopup` 清掉残留模态框。

## 11. 成品任务清单

| 路 | 能用 | 备注 |
| --- | --- | --- |
| COM `ICIDMLinkTransmitter2` | ❌ | 非 dual，需 32 位 + 注册表完好，本机 `E_ACCESSDENIED` |
| COM `DownlWithIDM.*` | ❌ | `QueryInterface` 拿不到 `IDownloadManager` |
| 命令行 `/d` | ❌ | 退出码 0 但什么都不下 |
| 扩展 native messaging | ❌ | 混淆协议，成本过高 |
| **Win32 消息驱动对话框** | ✅ | 本插件采用的方案 |

---

# English

## 1. COM `IDMan.CIDMLinkTransmitter` is unreachable

**Symptom**: VBScript `CreateObject` returns an object whose `TypeName` is `Unknown`; calling `SendLinkToIDM2` raises
`424 Object required`. PowerShell's `New-Object -ComObject` with 11 arguments complains about a missing parameter.

**Cause**: `ICIDMLinkTransmitter2` is not an `IDispatch`/dual interface. It only works through early binding with a fixed
vtable. Scripting languages go through `IDispatch::Invoke`, which does not exist here.

**Takeaway**: either write a C# `[ComImport]` client, or drop COM. It is also registered **only** under
`HKLM\SOFTWARE\Classes\WOW6432Node\CLSID`, i.e. visible to 32-bit processes only.

## 2. Early binding fails too

**Symptom**: a hand-written x86 `idm-bridge.exe` using `[ComImport]` and the exact IID throws `0x80070005 E_ACCESSDENIED`;
after killing IDM it becomes `0x80080005 CO_E_SERVER_EXEC_FAILURE`.

**Cause**: the AppID `{AC746233-E9D3-49CD-862F-068F7B7CCCA4}` is registered as `RunAs = Interactive User`, so
cross-session activation is refused, and the 64-bit CLSID view has no entry at all.

**Takeaway**: this route depends on the installer having registered everything correctly. Repacked/portable IDM builds
usually have not, and that is not something a plugin can fix.

## 3. The command line is a silent no-op

**Symptom**:

```bat
IDMan.exe /n /q /d "https://raw.githubusercontent.com/git/git/master/README.md" /p "D:\test" /f readme.md
```

Exits `0` within a second, adds no task to the list and writes no file. With IDM not running, the process simply hangs.

**Cause**: `/q` means "quit after the download finishes"; combined with `/n` (silent) every error is swallowed. IDM also
expects the main application to be running already.

**Takeaway**: it is not an API. It only works when you did not need it.

## 4. `DownlWithIDM.IDMDwnlMgr` exposes no download interface

**Symptom**: objects from `downlWithIDM.dll` (`IDMDwnlMgr`, `IDMLinkProcessor`, …) create fine, but `QueryInterface`
only ever returns `IUnknown`; asking for `IDownloadManager` gives `E_NOINTERFACE`, even though the typelib declares the coclass.

**Cause**: those are internal IE-extension helpers. What is exposed is a narrow `IDispatch` surface, not the real
download entry point.

**Takeaway**: a CLSID in the registry does not mean a usable object.

## 5. Menu items cannot be clicked

**Symptom**: `GetMenu` works and `WM_COMMAND` works, but clicking `Tasks → Add new download` via `SendInput`/`mouse_event`
misses often.

**Cause**: the main menu is owner-drawn with custom icons and its coordinates drift with DPI scaling.

**Takeaway**: do not click menus. `PostMessage(main, WM_COMMAND, 32771, 0)` — `32771` is the command ID of
"Add new download", discovered by enumerating the submenu, and it is stable across versions.

## 6. `WM_SETTEXT` on the URL box is ignored

**Symptom**: `SendMessage(WM_SETTEXT)` into control `1001`; `GetWindowText` reads it back perfectly. Press OK and IDM
downloads whatever URL it remembered from last time.

**Cause**: the edit control is owner-drawn with its own buffer; `WM_SETTEXT` changes the window text but not that buffer.

**Takeaway**: feed it one character at a time with `PostMessage(WM_CHAR)`, like a human typing. Bonus: this is not
"injection", so nothing gets suspicious.

## 7. PowerShell `-File` eats backslashes

**Symptom**: with `powershell -File idm-bridge.ps1 -OutDir "D:\downloads"`, the script receives `D:downloads`.

**Cause**: Windows PowerShell 5.1 re-parses the command line for `-File` arguments, and backslashes plus quotes get
consumed by a second round of escaping.

**Takeaway**: ship every parameter as one base64 JSON blob (`-Payload <base64>`). This applies to any
"Node/Go process invoking a PowerShell script" setup.

## 8. A "server file name differs" modal freezes the transfer

**Symptom**: downloading `.../v2.7.0.zip`, IDM pops:

> The file to be saved is named "v2.7.0", but the server provided the file name "cleanyourtv-2.7.0.zip".
> Do you want to save the file using the name provided by the server?

Nobody clicks it, so the transfer sits on "connecting", the caller waits until the timeout, and then reports the
unhelpful `The download was aborted.`

**Cause**: this is a **mid-transfer** modal, outside the "new task" flow. Early versions only handled info / duplicate /
error dialogs.

**Takeaway**: the wait loop must keep scanning for `#32770` windows that have exactly two buttons labelled Yes/No and
click Yes (accept the server name), then rename the finished file to what the caller asked for. **Any modal will hang a
background job forever** — you have to hunt for these, not wait for them to go away.

## 9. "Most recently modified file" is the wrong heuristic

**Symptom**: an early version treated the newest file in the target folder as the download and `Move-Item`ed a source
file that had just been edited.

**Cause**: IDM sometimes skips the save dialog, picks its own file name, may add `_2`, and does not necessarily land in
the folder you asked for.

**Takeaway**: fingerprint all three candidate folders (`dir`, IDM's save folder, `Downloads`) before the handoff
(`LastWriteTimeUtc.Ticks + Length`), then only accept a file that is new or changed, and require its size to stay
identical across 3 consecutive samples.

## 10. `MainWindowHandle == 0` when IDM is in the tray

**Symptom**: with IDM minimized to tray, `Process.MainWindowHandle` returns `0` and every `PostMessage` fails; sometimes
`GetProcessesByName` shows no window at all while `IDMan.exe` is clearly running.

**Cause**: the main window is hidden in tray mode, and `MainWindowHandle` only tracks visible windows.

**Takeaway**: `EnumWindows` by process ID for class `#32770` with a title starting with `Internet Download Manager`,
restore it with `ShowWindow(SW_RESTORE)`, and clear leftover modals with `GetLastActivePopup`.

## 11. Summary

| Route | Works | Note |
| --- | --- | --- |
| COM `ICIDMLinkTransmitter2` | ❌ | not dual; needs 32-bit + intact registration; `E_ACCESSDENIED` here |
| COM `DownlWithIDM.*` | ❌ | `QueryInterface` never yields `IDownloadManager` |
| CLI `/d` | ❌ | exits 0, downloads nothing |
| Extension native messaging | ❌ | obfuscated protocol, not worth it |
| **Win32 message-driven dialogs** | ✅ | what this plugin uses |

---

MIT · [Back to README](README.md)
