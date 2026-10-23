<#
  idm-bridge.ps1 - Windows UI bridge that hands a URL to Internet Download Manager.

  Why UI automation: many IDM builds (including repackaged installs) ship a
  broken COM LocalServer registration and a command line that exits 0 without
  downloading, so the only portable handoff is IDM's own "New Task" dialog.
  This script drives that dialog with Win32 messages - no focus stealing, no
  SendInput, no pixel hunting.

  Invoked with -Payload <base64 of UTF-8 JSON>, because Windows PowerShell
  re-parses raw `-File` arguments and strips backslashes out of them.

  Emits exactly one JSON object on stdout.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Payload
)

$ErrorActionPreference = 'Stop'

$cfg = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Payload)) | ConvertFrom-Json
$Action     = [string]$cfg.action
$Url        = [string]$cfg.url
$OutDir     = [string]$cfg.dir
$FileName   = [string]$cfg.fileName
$TimeoutSec = if ($cfg.timeoutSec) { [int]$cfg.timeoutSec } else { 1800 }
$NoWait     = ($cfg.wait -eq $false)

if ($Action -notin @('add', 'status')) { throw "Unknown action '$Action'." }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class IdmWin {
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int index);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

  public delegate bool EnumProc(IntPtr h, IntPtr lp);
}
"@

# ---------------------------------------------------------------- Win32 helpers

function Get-TopWindows([int]$ProcessId) {
  $script:acc = New-Object System.Collections.ArrayList
  $cb = [IdmWin+EnumProc]{
    param($h, $lp)
    $owner = 0
    [void][IdmWin]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $ProcessId) {
      $cls = New-Object System.Text.StringBuilder 256
      [void][IdmWin]::GetClassNameW($h, $cls, 256)
      $txt = New-Object System.Text.StringBuilder 512
      [void][IdmWin]::GetWindowTextW($h, $txt, 512)
      [void]$script:acc.Add([pscustomobject]@{
        Handle  = $h
        Class   = $cls.ToString()
        Title   = $txt.ToString()
        Visible = [IdmWin]::IsWindowVisible($h)
      })
    }
    return $true
  }
  [void][IdmWin]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:acc
}

function Get-Kids([IntPtr]$Parent) {
  $script:kids = New-Object System.Collections.ArrayList
  $cb = [IdmWin+EnumProc]{
    param($h, $lp)
    $cls = New-Object System.Text.StringBuilder 256
    [void][IdmWin]::GetClassNameW($h, $cls, 256)
    $txt = New-Object System.Text.StringBuilder 512
    [void][IdmWin]::GetWindowTextW($h, $txt, 512)
    [void]$script:kids.Add([pscustomobject]@{
      Handle = $h
      Id     = [IdmWin]::GetDlgCtrlID($h)
      Class  = $cls.ToString()
      Text   = $txt.ToString()
      Style  = [IdmWin]::GetWindowLongW($h, -16)
    })
    return $true
  }
  [void][IdmWin]::EnumChildWindows($Parent, $cb, [IntPtr]::Zero)
  return $script:kids
}

function Read-Text([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 4096
  [void][IdmWin]::SendMessageW($h, 0x000D, [IntPtr]4096, $sb)   # WM_GETTEXT
  return $sb.ToString()
}

function Set-Text([IntPtr]$h, [string]$s) {
  [void][IdmWin]::SendMessageW($h, 0x000C, [IntPtr]::Zero, $s)  # WM_SETTEXT
}

function Clear-Text([IntPtr]$h) {
  [void][IdmWin]::SendMessageW($h, 0x00B1, [IntPtr]::Zero, [IntPtr](-1))  # EM_SETSEL(0,-1)
  [void][IdmWin]::PostMessageW($h, 0x0102, [IntPtr]8, [IntPtr]1)          # WM_CHAR backspace
  Start-Sleep -Milliseconds 40
}

function Send-Keys([IntPtr]$h, [string]$s) {
  foreach ($ch in $s.ToCharArray()) {
    [void][IdmWin]::PostMessageW($h, 0x0102, [IntPtr][int]$ch, [IntPtr]1)  # WM_CHAR
    Start-Sleep -Milliseconds 4
  }
  Start-Sleep -Milliseconds 120
}

function Click-Btn([IntPtr]$h) {
  [void][IdmWin]::PostMessageW($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)  # BM_CLICK
}

function Get-ChildById([object]$Kids, [int]$Id) {
  return ($Kids | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Get-EditTarget([IntPtr]$Handle) {
  # A ComboBox keeps the real text in a child Edit, and IDM reads that control's
  # EN_CHANGE state - WM_SETTEXT on the combo alone does not stick.
  $kid = Get-Kids $Handle | Where-Object { $_.Class -eq 'Edit' } | Select-Object -First 1
  if ($kid) { return $kid.Handle }
  return $Handle
}

function Set-FieldText([IntPtr]$Handle, [string]$Text) {
  $target = Get-EditTarget $Handle
  Clear-Text $target
  Send-Keys $target $Text
  $back = (Read-Text $target).Trim()
  if ($back -ne $Text.Trim()) {
    Clear-Text $target
    Set-Text $target $Text
    Start-Sleep -Milliseconds 120
  }
  return (Read-Text $target).Trim()
}

function Wait-Dialog($ProcessId, [int[]]$Exclude, [scriptblock]$Match, [int]$TimeoutMs = 10000) {
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    foreach ($w in (Get-TopWindows $ProcessId)) {
      if (-not $w.Visible) { continue }
      if ($w.Class -ne '#32770') { continue }
      if ($Exclude -contains [int64]$w.Handle) { continue }
      if (-not $Match) { return $w }
      if (& $Match (Get-Kids $w.Handle)) { return $w }
    }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

# IDM likes to pop a Yes/No box in the middle of a running download, for example:
#   The file to be saved is named "v2.7.0", but the server the following file name
#   "cleanyourtv-2.7.0.zip". Do you want to save the file using the name provided
#   by the server?
# Nobody clicks it, so the transfer stalls behind the modal and the caller waits
# forever. Auto-answer "yes" (prefer the server name) and let the caller rename
# the finished file afterwards.
function Answer-YesNoPrompt($ProcessId, $Exclude) {
  foreach ($w in @(Get-TopWindows $ProcessId)) {
    if (-not $w.Visible -or $w.Class -ne '#32770') { continue }
    if ($Exclude -contains [int64]$w.Handle) { continue }
    $kids = Get-Kids $w.Handle
    $buttons = @($kids | Where-Object { $_.Class -eq 'Button' })
    if ($buttons.Count -ne 2) { continue }
    $yes = $buttons | Where-Object { $_.Text -match '^\s*(是|Yes)' } | Select-Object -First 1
    $no = $buttons | Where-Object { $_.Text -match '^\s*(否|No)' } | Select-Object -First 1
    if (-not ($yes -and $no)) { continue }
    Click-Btn $yes.Handle
    Start-Sleep -Milliseconds 120
    return $w.Handle
  }
  return $null
}

# ---------------------------------------------------------------- IDM specifics

$IdmCandidates = @(
  'C:\Program Files (x86)\Internet Download Manager\IDMan.exe',
  'C:\Program Files\Internet Download Manager\IDMan.exe'
)

function Get-IdmExe {
  foreach ($candidate in $IdmCandidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $reg = Get-ItemProperty 'HKCU:\Software\DownloadManager' -ErrorAction SilentlyContinue
  if ($reg -and $reg.ExePath -and (Test-Path -LiteralPath $reg.ExePath)) { return $reg.ExePath }
  return $null
}

function Get-IdmProcess {
  return (Get-Process -Name 'IDMan' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Find-IdmMain($ProcessId) {
  # The main window is a #32770 titled "Internet Download Manager ...". When IDM
  # lives in the tray it still exists but is hidden, and Process.MainWindowHandle
  # reports 0 for such a window, so enumerate instead of trusting Process.
  $best = $null
  foreach ($w in (Get-TopWindows $ProcessId)) {
    if ($w.Class -ne '#32770') { continue }
    if ($w.Title -notmatch 'Internet Download Manager') { continue }
    $kids = Get-Kids $w.Handle
    if (-not ($kids | Where-Object { $_.Class -eq 'SysListView32' })) { continue }
    if ($w.Visible) { return $w }
    if (-not $best) { $best = $w }
  }
  return $best
}

function Ensure-Idm {
  $exe = Get-IdmExe
  if (-not $exe) { throw 'Internet Download Manager is not installed (IDMan.exe not found).' }

  $proc = Get-IdmProcess
  if (-not $proc) {
    Start-Process -FilePath $exe | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 300
      $proc = Get-IdmProcess
      if ($proc) { break }
    }
  }
  if (-not $proc) { throw 'Could not start Internet Download Manager.' }

  for ($i = 0; $i -lt 24; $i++) {
    $main = Find-IdmMain $proc.Id
    if ($main -and $main.Visible) {
      return [pscustomobject]@{ Process = $proc; Main = $main.Handle }
    }
    if ($main) {
      # Hidden in the tray: restore it without forcing it to the foreground.
      [void][IdmWin]::ShowWindow($main.Handle, 9)   # SW_RESTORE
      [void][IdmWin]::ShowWindow($main.Handle, 5)   # SW_SHOW
      Start-Sleep -Milliseconds 500
      $again = Find-IdmMain $proc.Id
      if ($again -and $again.Visible) {
        return [pscustomobject]@{ Process = $proc; Main = $again.Handle }
      }
    }
    if ($i -eq 4 -or $i -eq 14) { Start-Process -FilePath $exe | Out-Null }
    Start-Sleep -Milliseconds 400
  }
  throw 'IDM main window could not be shown (the process runs headless in the tray and did not restore its window).'
}

function Clear-ModalWindows($ProcessId) {
  for ($round = 0; $round -lt 6; $round++) {
    $open = @(Get-TopWindows $ProcessId | Where-Object { $_.Visible -and $_.Class -eq '#32770' })
    if ($open.Count -eq 0) { return }
    foreach ($w in $open) { [void][IdmWin]::PostMessageW($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    Start-Sleep -Milliseconds 400
  }
}

function Get-IdmSaveDir {
  # IDM remembers its last save folder in REG_BINARY LocalPathW (UTF-16LE).
  $raw = (Get-ItemProperty 'HKCU:\Software\DownloadManager' -Name 'LocalPathW' -ErrorAction SilentlyContinue).LocalPathW
  if ($raw -is [byte[]] -and $raw.Length -gt 3) {
    $text = [System.Text.Encoding]::Unicode.GetString($raw).Trim([char]0).Trim()
    if ($text -and (Test-Path -LiteralPath $text -PathType Container)) { return $text.TrimEnd('\') }
  }
  $downloads = Join-Path $env:USERPROFILE 'Downloads'
  if (Test-Path -LiteralPath $downloads -PathType Container) { return $downloads }
  return $null
}

function Invoke-Status {
  $proc = Get-IdmProcess
  $exe = Get-IdmExe
  $version = $null
  if ($exe) { $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
  $main = if ($proc) { Find-IdmMain $proc.Id } else { $null }
  $proxy = 0
  $reg = Get-ItemProperty 'HKCU:\Software\DownloadManager' -Name 'UseHttpProxy' -ErrorAction SilentlyContinue
  if ($reg) { $proxy = [int]$reg.UseHttpProxy }
  return [pscustomobject]@{
    ok           = [bool]$exe
    installed    = [bool]$exe
    exe          = $exe
    version      = $version
    running      = [bool]$proc
    pid          = if ($proc) { $proc.Id } else { $null }
    windowTitle  = if ($main) { $main.Title } else { '' }
    saveDir      = Get-IdmSaveDir
    httpProxy    = ($proxy -ne 0)
  }
}

function Invoke-Add {
  if (-not $Url) { throw 'A url is required.' }

  $idm = Ensure-Idm
  $proc = $idm.Process
  $main = $idm.Main
  Clear-ModalWindows $proc.Id

  # IDM does not always show the "save as" dialog, so the destination cannot be
  # trusted to any single control. Watch every plausible folder instead and move
  # the finished file afterwards.
  if ($OutDir -and -not (Test-Path -LiteralPath $OutDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Force -Path $OutDir -ErrorAction SilentlyContinue
  }
  $watchDirs = New-Object System.Collections.Generic.List[string]
  foreach ($cand in @($OutDir, (Get-IdmSaveDir), (Join-Path $env:USERPROFILE 'Downloads'))) {
    if (-not $cand) { continue }
    $full = $cand.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
    $key = $full.ToLowerInvariant()
    if (-not $watchDirs.Contains($key)) { $watchDirs.Add($key) }
  }
  $start = Get-Date
  $before = @{}
  foreach ($d in $watchDirs) {
    foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
      $before[$f.FullName.ToLowerInvariant()] = "$($f.LastWriteTimeUtc.Ticks):$($f.Length)"
    }
  }

  $existing = @()
  foreach ($w in (Get-TopWindows $proc.Id)) {
    if ($w.Class -eq '#32770' -and $w.Visible) { $existing += [int64]$w.Handle }
  }

  [void][IdmWin]::PostMessageW($main, 0x0111, [IntPtr]32771, [IntPtr]::Zero)

  $urlDlg = Wait-Dialog $proc.Id $existing { param($kids) [bool](Get-ChildById $kids 1001) } 12000
  if (-not $urlDlg) { throw 'IDM "Add URL" dialog did not appear.' }

  $urlEdit = (Get-ChildById (Get-Kids $urlDlg.Handle) 1001).Handle
  $typed = Set-FieldText $urlEdit $Url
  if ($typed -ne $Url) { throw "Could not fill the IDM address field (got '$typed')." }

  $okBtn = Get-ChildById (Get-Kids $urlDlg.Handle) 1022
  if ($okBtn) { Click-Btn $okBtn.Handle }
  else { [void][IdmWin]::PostMessageW($urlDlg.Handle, 0x0111, [IntPtr]1, [IntPtr]::Zero) }

  $savedName = $null
  $infoSeen = $false
  $deadline = (Get-Date).AddSeconds(60)

  while ((Get-Date) -lt $deadline -and -not $infoSeen) {
    Start-Sleep -Milliseconds 200
    $null = Answer-YesNoPrompt $proc.Id @([int64]$main)
    $dlgs = @(Get-TopWindows $proc.Id | Where-Object { $_.Visible -and $_.Class -eq '#32770' })
    foreach ($d in $dlgs) {
      $kids = Get-Kids $d.Handle

      # "Download file info": has 开始下载 (1006)
      $startBtn = Get-ChildById $kids 1006
      if ($startBtn) {
        if ($OutDir) {
          $saveCombo = Get-ChildById $kids 1008
          if ($saveCombo) { [void](Set-FieldText $saveCombo.Handle ($OutDir.TrimEnd('\') + '\')) }
        }
        $nameEdit = Get-ChildById $kids 1009
        if ($nameEdit) {
          if ($FileName) { $savedName = Set-FieldText $nameEdit.Handle $FileName }
          else { $savedName = (Read-Text (Get-EditTarget $nameEdit.Handle)).Trim() }
        }
        Click-Btn $startBtn.Handle
        $infoSeen = $true
        break
      }

      # "Duplicate download": pick "overwrite" when it is offered, then confirm.
      if (Get-ChildById $kids 1643) {
        Click-Btn (Get-ChildById $kids 1643).Handle
        Start-Sleep -Milliseconds 150
      }
      $confirm = $kids | Where-Object { $_.Class -eq 'Button' -and $_.Id -eq 1 } | Select-Object -First 1
      if ((Get-ChildById $kids 1643) -or (Get-ChildById $kids 1642)) {
        if ($confirm) { Click-Btn $confirm.Handle }
        break
      }

      # Anything else is an error box: IDM shows the reason in a static or edit.
      $buttons = @($kids | Where-Object { $_.Class -eq 'Button' })
      if ($buttons.Count -eq 1) {
        $reason = (@($kids |
          Where-Object { ($_.Class -eq 'Static' -or $_.Class -eq 'Edit') -and $_.Text.Trim() } |
          ForEach-Object { $_.Text.Trim() }) -join ' ')
        Click-Btn $buttons[0].Handle
        throw "IDM rejected the URL: $reason"
      }
    }
  }

  if (-not $savedName) {
    $savedName = [System.IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
    if (-not $savedName) { $savedName = 'download.bin' }
  }
  $dest = if ($OutDir) { Join-Path $OutDir.TrimEnd('\') $savedName } else { $null }

  if ($NoWait) {
    return [pscustomobject]@{
      ok = $true; queued = $true; url = $Url; path = $dest; fileName = $savedName; infoDialog = $infoSeen
    }
  }

  $found = $null
  $lastSize = -1
  $stable = 0
  $limit = $start.AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $limit) {
    Start-Sleep -Milliseconds 500

    # A mid-transfer Yes/No box (server file-name mismatch, overwrite, ...) would
    # otherwise freeze the transfer until the timeout expires.
    $null = Answer-YesNoPrompt $proc.Id @([int64]$main)

    # Any file that appeared or changed after the handoff is a candidate. The
    # fingerprint check keeps unrelated recent files out of the result.
    $newest = $null
    foreach ($d in $watchDirs) {
      foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
        if ($f.Length -le 0) { continue }
        if ($f.Name -match '(?i)\.(tmp|part|idm|!ut|crdownload)$') { continue }
        if ($f.LastWriteTime -lt $start.AddSeconds(-1)) { continue }
        $key = $f.FullName.ToLowerInvariant()
        $stamp = "$($f.LastWriteTimeUtc.Ticks):$($f.Length)"
        if ($before.ContainsKey($key) -and $before[$key] -eq $stamp) { continue }
        if (-not $newest -or $f.LastWriteTime -gt $newest.LastWriteTime) { $newest = $f }
      }
    }
    if ($newest) {
      if ($newest.FullName -ne $found) { $found = $newest.FullName; $lastSize = -1; $stable = 0 }
      if ((Get-Item -LiteralPath $found).Length -eq $lastSize) { $stable++ } else { $stable = 0 }
      $lastSize = (Get-Item -LiteralPath $found).Length
      if ($stable -ge 3) { break }
    }

    # Dismiss IDM's "download complete" box (关闭 = 1079) so the next run is clean.
    foreach ($d in @(Get-TopWindows $proc.Id | Where-Object { $_.Visible -and $_.Class -eq '#32770' })) {
      $kids = Get-Kids $d.Handle
      $close = $kids | Where-Object { $_.Class -eq 'Button' -and $_.Id -eq 1079 } | Select-Object -First 1
      if ($close) { Click-Btn $close.Handle }
    }
  }

  if (-not $found) {
    $where = $watchDirs -join ', '
    throw "IDM did not produce a new file in $where within $TimeoutSec s. If the site needs a proxy, configure it in IDM under Options -> Proxy / Socks; IDM does not follow the Windows system proxy by default."
  }

  if ($dest -and ($found -ne $dest)) {
    Move-Item -LiteralPath $found -Destination $dest -Force
    $found = $dest
  }

  $item = Get-Item -LiteralPath $found
  return [pscustomobject]@{
    ok         = $true
    queued     = $false
    url        = $Url
    path       = $found
    fileName   = $item.Name
    bytes      = $item.Length
    elapsedMs  = [int]((Get-Date) - $start).TotalMilliseconds
    infoDialog = $infoSeen
  }
}

# ---------------------------------------------------------------- entry point

try {
  $result = if ($Action -eq 'status') { Invoke-Status } else { Invoke-Add }
  $result | ConvertTo-Json -Compress -Depth 5
  exit 0
}
catch {
  [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress -Depth 5
  exit 1
}
