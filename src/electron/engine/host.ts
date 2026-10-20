import {
  BRIDGE_GLOBAL,
  HOST_CHANNEL,
  type HostBridge,
  type HostInfo,
} from '../shared'

type NodeRequire = (id: string) => any

export interface FileStat {
  size: number
}

export interface FileStore {
  readonly root: string
  absolute(path: string): string
  stat(path: string): Promise<FileStat | null>
  read(path: string, start?: number, end?: number): Promise<Uint8Array>
  write(path: string, data: Uint8Array, append?: boolean): Promise<void>
  remove(path: string): Promise<void>
  mkdir(path: string): Promise<void>
  rename(from: string, to: string): Promise<void>
}

export interface Host {
  readonly files: FileStore | undefined
  readonly managesHeaders: boolean
  fileUrl(path: string): string
  prepare(url: string, headers: Record<string, string>): Promise<void>
}

function nodeRequire(): NodeRequire | undefined {
  const r = (globalThis as { require?: unknown }).require
  return typeof r === 'function' ? (r as NodeRequire) : undefined
}

function findBridge(): HostBridge | undefined {
  const exposed = (globalThis as Record<string, unknown>)[BRIDGE_GLOBAL] as
    | HostBridge
    | undefined
  if (exposed && typeof exposed.invoke === 'function') return exposed
  try {
    const ipc = nodeRequire()?.('electron')?.ipcRenderer
    if (ipc && typeof ipc.invoke === 'function') {
      return { invoke: (request) => ipc.invoke(HOST_CHANNEL, request) }
    }
  } catch {}
  return undefined
}

function joinPath(root: string, path: string): string {
  const sep = root.includes('\\') && !root.includes('/') ? '\\' : '/'
  const clean = path.split(/[\\/]+/).filter((p) => p && p !== '.' && p !== '..')
  return [root.replace(/[\\/]+$/, ''), ...clean].join(sep)
}

function toFileUrl(absolute: string): string {
  let p = absolute.replace(/\\/g, '/')
  if (!p.startsWith('/')) p = '/' + p
  return 'file://' + p.split('/').map(encodeURIComponent).join('/').replace(/^\/([A-Za-z])%3A/, '/$1:')
}

function bytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  }
  throw new Error('Unexpected host response')
}

class BridgeFileStore implements FileStore {
  constructor(
    private readonly bridge: HostBridge,
    readonly root: string
  ) {}

  absolute(path: string): string {
    return joinPath(this.root, path)
  }

  async stat(path: string): Promise<FileStat | null> {
    return (await this.bridge.invoke({ op: 'stat', path })) as FileStat | null
  }

  async read(path: string, start?: number, end?: number): Promise<Uint8Array> {
    return bytes(await this.bridge.invoke({ op: 'read', path, start, end }))
  }

  async write(path: string, data: Uint8Array, append = false): Promise<void> {
    await this.bridge.invoke({ op: 'write', path, data, append })
  }

  async remove(path: string): Promise<void> {
    await this.bridge.invoke({ op: 'remove', path })
  }

  async mkdir(path: string): Promise<void> {
    await this.bridge.invoke({ op: 'mkdir', path })
  }

  async rename(from: string, to: string): Promise<void> {
    await this.bridge.invoke({ op: 'rename', from, to })
  }
}

class NodeFileStore implements FileStore {
  private readonly fs: any

  constructor(
    require: NodeRequire,
    readonly root: string
  ) {
    this.fs = require('fs').promises
  }

  absolute(path: string): string {
    return joinPath(this.root, path)
  }

  async stat(path: string): Promise<FileStat | null> {
    try {
      const s = await this.fs.stat(this.absolute(path))
      return { size: Number(s.size) }
    } catch {
      return null
    }
  }

  async read(path: string, start?: number, end?: number): Promise<Uint8Array> {
    const file = this.absolute(path)
    if (start === undefined && end === undefined) {
      return new Uint8Array(await this.fs.readFile(file))
    }
    const handle = await this.fs.open(file, 'r')
    try {
      const from = start ?? 0
      const size = Number((await handle.stat()).size)
      const to = Math.min(end ?? size, size)
      const out = new Uint8Array(Math.max(0, to - from))
      let offset = 0
      while (offset < out.length) {
        const { bytesRead } = await handle.read(out, offset, out.length - offset, from + offset)
        if (bytesRead <= 0) break
        offset += bytesRead
      }
      return out.subarray(0, offset)
    } finally {
      await handle.close()
    }
  }

  async write(path: string, data: Uint8Array, append = false): Promise<void> {
    const file = this.absolute(path)
    await this.fs.mkdir(file.replace(/[\\/][^\\/]*$/, ''), { recursive: true })
    if (append) await this.fs.appendFile(file, data)
    else await this.fs.writeFile(file, data)
  }

  async remove(path: string): Promise<void> {
    await this.fs.rm(this.absolute(path), { recursive: true, force: true })
  }

  async mkdir(path: string): Promise<void> {
    await this.fs.mkdir(this.absolute(path), { recursive: true })
  }

  async rename(from: string, to: string): Promise<void> {
    await this.fs.rm(this.absolute(to), { recursive: true, force: true })
    await this.fs.rename(this.absolute(from), this.absolute(to))
  }
}

function defaultNodeRoot(require: NodeRequire): string {
  const os = require('os')
  const path = require('path')
  const home = os.homedir()
  const proc = (globalThis as any).process ?? {}
  const env = proc.env ?? {}
  const base =
    proc.platform === 'darwin'
      ? path.join(home, 'Library', 'Application Support')
      : proc.platform === 'win32'
        ? env.APPDATA ?? path.join(home, 'AppData', 'Roaming')
        : env.XDG_DATA_HOME ?? path.join(home, '.local', 'share')
  return path.join(base, 'EverythingPlayer', 'downloads')
}

class ElectronHost implements Host {
  private readonly origins = new Set<string>()
  private readonly urls = new Map<string, string>()

  constructor(
    private readonly bridge: HostBridge | undefined,
    private readonly info: HostInfo | undefined,
    readonly files: FileStore | undefined
  ) {}

  get managesHeaders(): boolean {
    return this.info !== undefined
  }

  fileUrl(path: string): string {
    if (this.info) {
      const encoded = path
        .split(/[\\/]+/)
        .filter(Boolean)
        .map(encodeURIComponent)
        .join('/')
      return `${this.info.fileScheme}://local/${encoded}`
    }
    return toFileUrl(this.files ? this.files.absolute(path) : path)
  }

  async prepare(url: string, headers: Record<string, string>): Promise<void> {
    if (!this.bridge || !this.info) return
    let origin: string
    try {
      const parsed = new URL(url)
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return
      origin = parsed.origin
    } catch {
      return
    }
    const empty = Object.keys(headers).length === 0
    const key = JSON.stringify(headers)
    if (empty ? this.origins.has(origin) : this.urls.get(url) === key) return
    if (empty) this.origins.add(origin)
    else {
      this.urls.set(url, key)
      if (this.urls.size > 2048) this.urls.delete(this.urls.keys().next().value!)
    }
    try {
      await this.bridge.invoke({ op: 'headers', url, headers })
    } catch {
      if (empty) this.origins.delete(origin)
      else this.urls.delete(url)
    }
  }
}

let hostPromise: Promise<Host> | undefined
let resolvedHost: Host | undefined

async function createHost(): Promise<Host> {
  const bridge = findBridge()
  if (bridge) {
    try {
      const info = (await bridge.invoke({ op: 'info' })) as HostInfo
      if (info && info.version === 1) {
        return new ElectronHost(bridge, info, new BridgeFileStore(bridge, info.root))
      }
    } catch {}
  }
  const require = nodeRequire()
  if (require) {
    try {
      return new ElectronHost(
        undefined,
        undefined,
        new NodeFileStore(require, defaultNodeRoot(require))
      )
    } catch {}
  }
  return new ElectronHost(undefined, undefined, undefined)
}

export function getHost(): Promise<Host> {
  hostPromise ??= createHost().then((host) => {
    resolvedHost = host
    return host
  })
  return hostPromise
}

export function currentHost(): Host | undefined {
  return resolvedHost
}
