/**
 * dsh-idm-download
 *
 * Hands downloads to Internet Download Manager on Windows and waits for the
 * finished file. IDM's own COM API and command line are unreliable on many
 * builds (repackaged installs register a COM server that cannot be activated,
 * and `IDMan.exe /d` exits 0 without downloading), so this plugin drives IDM's
 * "New Task" dialog through Win32 messages: no screen scraping, no focus theft,
 * no SendInput.
 *
 * @module dsh-idm-download
 */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/** Cordis plugin name. */
export const name = 'idm-download'

/** Services required before the tools can be registered. */
export const inject = ['tools']

const HERE = path.dirname(fileURLToPath(import.meta.url))
// Windows PowerShell re-parses `-File` arguments and strips backslashes from
// them when the process is spawned by Node, so the script path uses forward
// slashes and every value travels base64-encoded.
const SCRIPT = path.join(HERE, '..', 'scripts', 'idm-bridge.ps1').split(path.sep).join('/')

const IS_WINDOWS = process.platform === 'win32'

function powershellExe() {
  // Windows PowerShell ships with every supported Windows build; `pwsh` can be
  // forced through the environment for testing.
  return process.env.DSH_IDM_POWERSHELL || 'powershell.exe'
}

/**
 * Run the bridge once and parse its single-line JSON result.
 * @param {string[]} args
 * @param {AbortSignal | undefined} signal
 */
function runBridge(payload, signal) {
  return new Promise((resolve, reject) => {
    if (!IS_WINDOWS) {
      reject(new Error('dsh-idm-download only works on Windows: Internet Download Manager has no other build.'))
      return
    }
    if (!existsSync(SCRIPT)) {
      reject(new Error(`idm-bridge.ps1 is missing at ${SCRIPT}. Reinstall the plugin from a complete package.`))
      return
    }

    const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64')
    const child = spawn(powershellExe(), [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', SCRIPT,
      '-Payload', encoded,
    ], { windowsHide: true })

    let stdout = ''
    let stderr = ''
    let settled = false

    const onAbort = () => {
      if (!settled) child.kill()
    }
    signal?.addEventListener('abort', onAbort, { once: true })

    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })

    child.on('error', (error) => {
      settled = true
      signal?.removeEventListener('abort', onAbort)
      reject(error)
    })

    child.on('close', (code, killSignal) => {
      settled = true
      signal?.removeEventListener('abort', onAbort)
      if (signal?.aborted) {
        reject(new Error('The download was aborted.'))
        return
      }
      const line = stdout.trim().split(/\r?\n/).filter(Boolean).at(-1)
      if (!line) {
        reject(new Error(stderr.trim() || `idm-bridge.ps1 exited with ${killSignal ?? code} and printed nothing.`))
        return
      }
      let parsed
      try {
        parsed = JSON.parse(line)
      } catch {
        reject(new Error(`Unexpected bridge output: ${line.slice(0, 400)}`))
        return
      }
      if (parsed.ok !== true) {
        reject(new Error(parsed.error || 'Internet Download Manager did not accept the download.'))
        return
      }
      resolve(parsed)
    })
  })
}

function cleanDir(dir) {
  if (typeof dir !== 'string' || dir.trim() === '') return undefined
  const trimmed = dir.trim().replace(/\\+$/, '')
  if (trimmed === '' || trimmed.includes('"') || trimmed.includes(String.fromCharCode(10)) || trimmed.includes(String.fromCharCode(13))) return undefined
  return trimmed
}

function humanBytes(bytes) {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes < 0) return 'unknown size'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1 }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`
}

function humanDuration(ms) {
  if (typeof ms !== 'number' || ms < 0) return 'unknown time'
  if (ms < 1000) return `${ms} ms`
  const seconds = ms / 1000
  if (seconds < 60) return `${seconds.toFixed(1)} s`
  const minutes = Math.floor(seconds / 60)
  return `${minutes} min ${Math.round(seconds - minutes * 60)} s`
}

/** @type {import('@deepseek-ai/dsh-tools').ToolDefinition} */
const downloadTool = {
  name: 'idm_download',
  description:
    'Agent-owned download accelerator. Use this for YOUR OWN downloads, not for the user to click: '
    + 'whenever you are about to fetch something you expect to be ~1 MB or larger (releases, repo archives, '
    + 'plugin/tarball packages, binaries, models, datasets) or when the host is known to throttle single '
    + 'connections (github.com, codeload.github.com, raw.githubusercontent.com, sourceforge, npm tarballs), '
    + 'route the fetch through IDM instead of curl/wget/Invoke-WebRequest. IDM splits the file across several '
    + 'connections and is usually far faster than one HTTP stream. Downloads under ~1 MB should stay on plain '
    + 'HTTP so no IDM dialog is involved. Waits for the file to land and returns the absolute path you can then '
    + 'unpack or use. Requires Windows with IDM installed.',
  parameters: {
    type: 'object',
    properties: {
      url: { type: 'string', description: 'The http(s) URL to download.' },
      dir: { type: 'string', description: 'Absolute folder to save into. Defaults to the IDM download folder.' },
      fileName: { type: 'string', description: 'File name to save as. Defaults to the name IDM derives from the URL.' },
      timeoutSec: { type: 'integer', minimum: 10, maximum: 86400, description: 'Give up after this many seconds (default 1800).' },
      wait: { type: 'boolean', description: 'Wait for the file to finish (default true). Set false to only queue the task.' },
    },
    required: ['url'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        queued: { type: 'boolean' },
        url: { type: 'string' },
        path: { type: 'string' },
        fileName: { type: 'string' },
        bytes: { type: 'number' },
        elapsedMs: { type: 'number' },
      },
      required: ['ok', 'url'],
      additionalProperties: true,
    },
    render(_args, value) {
      if (value.queued) {
        const target = value.path ? ` -> ${value.path}` : ''
        return [{ type: 'text', text: `Queued in IDM: ${value.url}${target}` }]
      }
      const size = humanBytes(value.bytes)
      const time = humanDuration(value.elapsedMs)
      return [{
        type: 'text',
        text: `IDM finished ${value.fileName} (${size}) in ${time}\n${value.path}`,
      }]
    },
  },
  timeoutMs: 86_400_000,
  async execute(args, exec) {
    return runBridge({
      action: 'add',
      url: args.url,
      dir: cleanDir(args.dir),
      fileName: args.fileName || undefined,
      timeoutSec: Number.isInteger(args.timeoutSec) ? args.timeoutSec : undefined,
      wait: args.wait !== false,
    }, exec?.signal)
  },
}

/** @type {import('@deepseek-ai/dsh-tools').ToolDefinition} */
const statusTool = {
  name: 'idm_status',
  description:
    'Report whether Internet Download Manager is installed and running on this Windows machine, '
    + 'its version, executable path, running state and default save folder. Check this before idm_download '
    + 'when IDM availability is unknown, or after a failed idm_download to tell "IDM not running" apart '
    + 'from "the download really failed".',
  parameters: { type: 'object', properties: {}, additionalProperties: false },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        installed: { type: 'boolean' },
        exe: { type: 'string' },
        version: { type: 'string' },
        running: { type: 'boolean' },
        pid: { type: 'number' },
        windowTitle: { type: 'string' },
        saveDir: { type: 'string' },
        httpProxy: { type: 'boolean' },
      },
      required: ['ok', 'installed', 'running'],
      additionalProperties: true,
    },
    render(_args, value) {
      if (!value.installed) return [{ type: 'text', text: 'Internet Download Manager is not installed.' }]
      const state = value.running ? `running (pid ${value.pid})` : 'installed, not running'
      const proxy = value.httpProxy ? 'proxy configured' : 'no proxy configured in IDM'
      return [{
        type: 'text',
        text: `Internet Download Manager ${value.version ?? ''} — ${state}\n${value.exe}\nSave folder: ${value.saveDir ?? 'unknown'} · ${proxy}`,
      }]
    },
  },
  timeoutMs: 60_000,
  async execute(_args, exec) {
    return runBridge({ action: 'status' }, exec?.signal)
  },
}

/**
 * Register the IDM tools.
 * @param {import('cordis').Context} ctx
 */
export function apply(ctx) {
  ctx.tools.register(downloadTool)
  ctx.tools.register(statusTool)
}
