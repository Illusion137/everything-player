import {
  app,
  ipcMain,
  protocol,
  session as electronSession,
  type OnBeforeRedirectListenerDetails,
  type OnBeforeSendHeadersListenerDetails,
  type OnHeadersReceivedListenerDetails,
  type Session,
} from 'electron'
import { createReadStream, promises as fs } from 'fs'
import * as path from 'path'
import { Readable } from 'stream'
import { FILE_SCHEME, HOST_CHANNEL, type HostInfo, type HostRequest } from './shared'

export interface EverythingPlayerMainOptions {
  downloadsDir?: string
  session?: Session
  webRequest?: boolean
}

const MIME: Record<string, string> = {
  '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4',
  '.mp3': 'audio/mpeg',
  '.aac': 'audio/aac',
  '.webm': 'video/webm',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.flac': 'audio/flac',
  '.wav': 'audio/wav',
  '.m3u8': 'application/vnd.apple.mpegurl',
  '.ts': 'video/mp2t',
  '.m4s': 'video/mp4',
}

const MAX_URLS = 4096
const corsOrigins = new Set<string>()
const urlHeaders = new Map<string, Record<string, string>>()
let schemesRegistered = false
let installed = false

function originOf(url: string): string | undefined {
  try {
    return new URL(url).origin
  } catch {
    return undefined
  }
}

function setHeader(headers: Record<string, string | string[]>, name: string, value: string | string[]): void {
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === name.toLowerCase()) delete headers[key]
  }
  headers[name] = value
}

function registerHeaders(url: string, headers: Record<string, string>): void {
  const origin = originOf(url)
  if (origin) corsOrigins.add(origin)
  if (Object.keys(headers).length === 0) return
  urlHeaders.delete(url)
  urlHeaders.set(url, headers)
  if (urlHeaders.size > MAX_URLS) urlHeaders.delete(urlHeaders.keys().next().value!)
}

export function applyRedirect(details: OnBeforeRedirectListenerDetails): void {
  const headers = urlHeaders.get(details.url)
  if (headers) registerHeaders(details.redirectURL, headers)
  else if (corsOrigins.has(originOf(details.url) ?? '')) registerHeaders(details.redirectURL, {})
}

export function applyRequestHeaders(details: OnBeforeSendHeadersListenerDetails): Record<string, string> {
  const headers = { ...details.requestHeaders }
  const extra = urlHeaders.get(details.url)
  if (!extra) return headers
  for (const [name, value] of Object.entries(extra)) setHeader(headers, name, value)
  return headers as Record<string, string>
}

export function applyResponseHeaders(details: OnHeadersReceivedListenerDetails): {
  responseHeaders?: Record<string, string[]>
  statusLine?: string
} {
  const origin = originOf(details.url)
  if (!origin || !corsOrigins.has(origin)) return {}
  const headers: Record<string, string | string[]> = { ...(details.responseHeaders ?? {}) }
  setHeader(headers, 'Access-Control-Allow-Origin', ['*'])
  setHeader(headers, 'Access-Control-Allow-Headers', ['*'])
  setHeader(headers, 'Access-Control-Allow-Methods', ['GET, POST, HEAD, OPTIONS'])
  setHeader(headers, 'Access-Control-Expose-Headers', ['*'])
  const responseHeaders = headers as Record<string, string[]>
  if (details.method === 'OPTIONS') return { responseHeaders, statusLine: 'HTTP/1.1 200 OK' }
  return { responseHeaders }
}

export function registerEverythingPlayerSchemes(): void {
  if (schemesRegistered) return
  schemesRegistered = true
  protocol.registerSchemesAsPrivileged([
    {
      scheme: FILE_SCHEME,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
        stream: true,
        bypassCSP: true,
      },
    },
  ])
}

function inside(root: string, relative: string): string {
  const resolved = path.resolve(root, relative.replace(/^[\\/]+/, ''))
  if (resolved !== root && !resolved.startsWith(root + path.sep)) {
    throw new Error('Path escapes the downloads directory')
  }
  return resolved
}

async function readRange(file: string, start?: number, end?: number): Promise<Uint8Array> {
  if (start === undefined && end === undefined) return new Uint8Array(await fs.readFile(file))
  const handle = await fs.open(file, 'r')
  try {
    const size = (await handle.stat()).size
    const from = Math.min(start ?? 0, size)
    const to = Math.min(end ?? size, size)
    const out = Buffer.alloc(Math.max(0, to - from))
    let offset = 0
    while (offset < out.length) {
      const { bytesRead } = await handle.read(out, offset, out.length - offset, from + offset)
      if (bytesRead <= 0) break
      offset += bytesRead
    }
    return new Uint8Array(out.buffer, out.byteOffset, offset)
  } finally {
    await handle.close()
  }
}

async function handle(root: string, request: HostRequest): Promise<unknown> {
  switch (request.op) {
    case 'info': {
      const info: HostInfo = { version: 1, root, fileScheme: FILE_SCHEME }
      return info
    }
    case 'stat':
      try {
        const s = await fs.stat(inside(root, request.path))
        return { size: s.size }
      } catch {
        return null
      }
    case 'read':
      return readRange(inside(root, request.path), request.start, request.end)
    case 'write': {
      const file = inside(root, request.path)
      await fs.mkdir(path.dirname(file), { recursive: true })
      if (request.append) await fs.appendFile(file, request.data)
      else await fs.writeFile(file, request.data)
      return null
    }
    case 'remove':
      await fs.rm(inside(root, request.path), { recursive: true, force: true })
      return null
    case 'mkdir':
      await fs.mkdir(inside(root, request.path), { recursive: true })
      return null
    case 'rename': {
      const to = inside(root, request.to)
      await fs.rm(to, { recursive: true, force: true })
      await fs.rename(inside(root, request.from), to)
      return null
    }
    case 'headers':
      registerHeaders(request.url, request.headers)
      return null
  }
}

async function serveFile(root: string, request: Request): Promise<Response> {
  const url = new URL(request.url)
  let file: string
  try {
    file = inside(root, decodeURIComponent(url.pathname))
  } catch {
    return new Response(null, { status: 403 })
  }
  let size: number
  try {
    size = (await fs.stat(file)).size
  } catch {
    return new Response(null, { status: 404 })
  }
  const headers: Record<string, string> = {
    'Content-Type': MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Access-Control-Allow-Origin': '*',
  }
  const range = /bytes=(\d*)-(\d*)/.exec(request.headers.get('range') ?? '')
  let start = 0
  let end = size - 1
  let status = 200
  if (range && (range[1] || range[2])) {
    if (range[1]) {
      start = Number(range[1])
      if (range[2]) end = Math.min(Number(range[2]), size - 1)
    } else {
      start = Math.max(0, size - Number(range[2]))
    }
    if (start >= size || start > end) {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
    }
    status = 206
    headers['Content-Range'] = `bytes ${start}-${end}/${size}`
  }
  headers['Content-Length'] = String(Math.max(0, end - start + 1))
  if (request.method === 'HEAD' || size === 0) return new Response(null, { status, headers })
  const stream = Readable.toWeb(createReadStream(file, { start, end })) as unknown as ReadableStream
  return new Response(stream, { status, headers })
}

export function setupEverythingPlayer(options: EverythingPlayerMainOptions = {}): void {
  if (installed) return
  installed = true
  if (!app.isReady()) {
    try {
      registerEverythingPlayerSchemes()
    } catch {}
  }
  const root = path.resolve(
    options.downloadsDir ?? path.join(app.getPath('userData'), 'EverythingPlayer', 'downloads')
  )
  ipcMain.handle(HOST_CHANNEL, (_event, request: HostRequest) => handle(root, request))
  app.whenReady().then(async () => {
    await fs.mkdir(root, { recursive: true }).catch(() => {})
    const ses = options.session ?? electronSession.defaultSession
    ses.protocol.handle(FILE_SCHEME, (request) => serveFile(root, request))
    if (options.webRequest === false) return
    const filter = { urls: ['http://*/*', 'https://*/*'] }
    ses.webRequest.onBeforeSendHeaders(filter, (details, callback) => {
      callback({ requestHeaders: applyRequestHeaders(details) })
    })
    ses.webRequest.onHeadersReceived(filter, (details, callback) => {
      callback(applyResponseHeaders(details))
    })
    ses.webRequest.onBeforeRedirect(filter, applyRedirect)
  })
}
