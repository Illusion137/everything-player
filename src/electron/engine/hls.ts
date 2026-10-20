import type { NativeVideoQualityRange } from '../../specs/EverythingPlayer.nitro'
import type { FileStore, Host } from './host'
import { EPError, pickInRange } from './models'

interface Key {
  method: string
  uri?: string
  iv?: Uint8Array
}

interface ByteRange {
  length: number
  offset: number
}

interface MapEntry {
  uri: string
  range?: ByteRange
}

interface Segment {
  uri: string
  duration: number
  sequence: number
  discontinuity: number
  range?: ByteRange
  key?: Key
  map?: MapEntry
}

interface MediaPlaylist {
  targetDuration: number
  ended: boolean
  segments: Segment[]
}

interface Variant {
  uri: string
  bandwidth: number
  width?: number
  height?: number
  codecs: string[]
  audioGroup?: string
}

interface Rendition {
  groupId: string
  uri?: string
  isDefault: boolean
}

interface MasterPlaylist {
  variants: Variant[]
  audio: Rendition[]
}

const VIDEO_CODECS = ['avc1', 'avc3', 'hvc1', 'hev1', 'dvh1', 'dvhe', 'av01', 'vp09']
const AUDIO_CODECS = ['mp4a', 'ac-3', 'ec-3', 'opus', 'flac', 'alac', 'mp3']

const isVideoCodec = (c: string) => VIDEO_CODECS.some((p) => c.startsWith(p))
const isAudioCodec = (c: string) => AUDIO_CODECS.some((p) => c.startsWith(p))

function attributes(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    const value = m[2] ?? ''
    out[m[1]!] = value.startsWith('"') ? value.slice(1, -1) : value
  }
  return out
}

function resolve(uri: string, base: string): string {
  return new URL(uri, base).toString()
}

function parseRange(text: string, previousEnd: number): ByteRange {
  const [len, off] = text.split('@')
  const length = Number(len)
  return { length, offset: off !== undefined ? Number(off) : previousEnd }
}

function hexIv(text: string): Uint8Array {
  const hex = text.replace(/^0x/i, '').padStart(32, '0')
  const out = new Uint8Array(16)
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

function parse(text: string, base: string): { master?: MasterPlaylist; media?: MediaPlaylist } {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  if (lines[0] !== '#EXTM3U') throw new EPError('source-error', 'Not an HLS playlist')
  if (lines.some((l) => l.startsWith('#EXT-X-STREAM-INF'))) {
    const variants: Variant[] = []
    const audio: Rendition[] = []
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        const a = attributes(line.slice(18))
        const uri = lines[i + 1]
        if (!uri || uri.startsWith('#')) continue
        const [w, h] = (a.RESOLUTION ?? '').split('x').map(Number)
        variants.push({
          uri: resolve(uri, base),
          bandwidth: Number(a['AVERAGE-BANDWIDTH'] ?? a.BANDWIDTH ?? 0),
          width: w || undefined,
          height: h || undefined,
          codecs: (a.CODECS ?? '').split(',').map((c) => c.trim()).filter(Boolean),
          audioGroup: a.AUDIO,
        })
      } else if (line.startsWith('#EXT-X-MEDIA:')) {
        const a = attributes(line.slice(13))
        if (a.TYPE !== 'AUDIO' || !a['GROUP-ID']) continue
        audio.push({
          groupId: a['GROUP-ID'],
          uri: a.URI ? resolve(a.URI, base) : undefined,
          isDefault: a.DEFAULT === 'YES',
        })
      }
    }
    return { master: { variants, audio } }
  }
  const segments: Segment[] = []
  let targetDuration = 0
  let sequence = 0
  let discontinuity = 0
  let ended = false
  let duration = 0
  let key: Key | undefined
  let map: MapEntry | undefined
  let range: ByteRange | undefined
  let lastEnd = 0
  for (const line of lines) {
    if (line.startsWith('#EXT-X-TARGETDURATION:')) targetDuration = Number(line.slice(22))
    else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) sequence = Number(line.slice(22))
    else if (line.startsWith('#EXT-X-ENDLIST')) ended = true
    else if (line.startsWith('#EXT-X-PLAYLIST-TYPE:VOD')) ended = true
    else if (line.startsWith('#EXT-X-DISCONTINUITY')) discontinuity += 1
    else if (line.startsWith('#EXTINF:')) duration = parseFloat(line.slice(8))
    else if (line.startsWith('#EXT-X-BYTERANGE:')) range = parseRange(line.slice(17), lastEnd)
    else if (line.startsWith('#EXT-X-KEY:')) {
      const a = attributes(line.slice(11))
      key =
        a.METHOD === 'NONE'
          ? undefined
          : { method: a.METHOD ?? '', uri: a.URI ? resolve(a.URI, base) : undefined, iv: a.IV ? hexIv(a.IV) : undefined }
    } else if (line.startsWith('#EXT-X-MAP:')) {
      const a = attributes(line.slice(11))
      if (a.URI) {
        map = { uri: resolve(a.URI, base), range: a.BYTERANGE ? parseRange(a.BYTERANGE, 0) : undefined }
      }
    } else if (!line.startsWith('#')) {
      segments.push({ uri: resolve(line, base), duration, sequence, discontinuity, range, key, map })
      if (range) lastEnd = range.offset + range.length
      sequence += 1
      range = undefined
    }
  }
  return { media: { targetDuration, ended, segments } }
}

function segmentExtension(uri: string): string {
  try {
    const ext = /\.([A-Za-z0-9]{1,5})$/.exec(new URL(uri).pathname)?.[1]?.toLowerCase()
    if (ext && ext !== 'm3u8') return ext
  } catch {}
  return 'ts'
}

function sequenceIv(sequence: number): Uint8Array {
  const iv = new Uint8Array(16)
  new DataView(iv.buffer).setUint32(12, sequence >>> 0)
  return iv
}

class Loader {
  private keys = new Map<string, Promise<CryptoKey>>()

  constructor(
    private readonly host: Host,
    private readonly headers: Record<string, string>,
    private readonly signal: AbortSignal
  ) {}

  async fetch(url: string, range?: ByteRange): Promise<Uint8Array> {
    await this.host.prepare(url, this.headers)
    const headers: Record<string, string> = this.host.managesHeaders ? {} : { ...this.headers }
    if (range) headers.Range = `bytes=${range.offset}-${range.offset + range.length - 1}`
    const response = await fetch(url, { headers, signal: this.signal })
    if (!response.ok) throw new EPError('network-error', `HTTP ${response.status} for ${url}`)
    return new Uint8Array(await response.arrayBuffer())
  }

  async text(url: string): Promise<string> {
    return new TextDecoder().decode(await this.fetch(url))
  }

  private key(uri: string): Promise<CryptoKey> {
    let key = this.keys.get(uri)
    if (!key) {
      key = this.fetch(uri).then((raw) =>
        crypto.subtle.importKey('raw', raw as BufferSource, 'AES-CBC', false, ['decrypt'])
      )
      this.keys.set(uri, key)
    }
    return key
  }

  async decrypt(data: Uint8Array, key: Key | undefined, sequence: number): Promise<Uint8Array> {
    if (!key) return data
    if (key.method !== 'AES-128' || !key.uri) {
      throw new EPError('source-error', 'Unsupported HLS encryption for download')
    }
    const iv = key.iv ?? sequenceIv(sequence)
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-CBC', iv: iv as BufferSource },
      await this.key(key.uri),
      data as BufferSource
    )
    return new Uint8Array(plain)
  }
}

export interface HlsProgress {
  done: number
  total: number
  bytes: number
}

function pickAudioVariant(master: MasterPlaylist): Variant | undefined {
  const audioOnly = master.variants.filter((v) => v.codecs.length > 0 && v.codecs.every(isAudioCodec))
  const withRendition = master.variants.filter((v) => audioRendition(master, v))
  const pool = audioOnly.length ? audioOnly : withRendition.length ? withRendition : master.variants
  return pool.reduce<Variant | undefined>((best, v) => (!best || v.bandwidth < best.bandwidth ? v : best), undefined)
}

function audioRendition(master: MasterPlaylist, variant: Variant): Rendition | undefined {
  if (!variant.audioGroup) return undefined
  const options = master.audio.filter((r) => r.groupId === variant.audioGroup && r.uri)
  return options.find((r) => r.isDefault) ?? options[0]
}

export async function downloadHls(options: {
  url: string
  headers: Record<string, string>
  includeVideo: boolean
  range: NativeVideoQualityRange
  folder: string
  host: Host
  files: FileStore
  signal: AbortSignal
  progress: (p: HlsProgress) => void
}): Promise<string> {
  const { files, folder, signal } = options
  const loader = new Loader(options.host, options.headers, signal)
  const root = parse(await loader.text(options.url), options.url)
  const jobs: { name: string; playlist: MediaPlaylist }[] = []
  let variant: Variant | undefined
  const media = async (url: string) => {
    const p = parse(await loader.text(url), url).media
    if (!p) throw new EPError('source-error', 'Expected a media playlist')
    return p
  }
  if (root.media) {
    jobs.push({ name: 'main', playlist: root.media })
  } else if (root.master) {
    const master = root.master
    const videoVariants = master.variants.filter((v) => !v.codecs.length || v.codecs.some(isVideoCodec) || v.height)
    const chosen =
      (options.includeVideo
        ? pickInRange(options.range, videoVariants, (v) => v.height, (v) => v.bandwidth)
        : undefined) ?? pickAudioVariant(master)
    if (!chosen) throw new EPError('source-error', 'No downloadable HLS variant')
    variant = chosen
    jobs.push({ name: 'main', playlist: await media(chosen.uri) })
    const rendition = audioRendition(master, chosen)
    if (rendition?.uri) jobs.push({ name: 'audio', playlist: await media(rendition.uri) })
  }
  for (const job of jobs) {
    if (!job.playlist.ended) throw new EPError('source-error', 'Live HLS streams cannot be downloaded')
  }
  await files.mkdir(folder)
  const total = jobs.reduce((n, j) => n + j.playlist.segments.length, 0)
  let done = 0
  let bytes = 0
  for (const job of jobs) {
    await files.mkdir(`${folder}/${job.name}`)
    const maps = new Map<string, string>()
    const lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:7',
      '#EXT-X-PLAYLIST-TYPE:VOD',
      `#EXT-X-TARGETDURATION:${Math.ceil(job.playlist.targetDuration)}`,
      '#EXT-X-MEDIA-SEQUENCE:0',
    ]
    let lastMap: string | undefined
    let lastDiscontinuity = job.playlist.segments[0]?.discontinuity
    for (const [i, segment] of job.playlist.segments.entries()) {
      if (signal.aborted) throw new DOMException('Aborted', 'AbortError')
      if (segment.map) {
        const mapKey = `${segment.map.uri}|${segment.map.range?.offset ?? ''}`
        let name = maps.get(mapKey)
        if (!name) {
          name = `${job.name}/init-${maps.size}.mp4`
          const path = `${folder}/${name}`
          if (!(await files.stat(path))) {
            let data = await loader.fetch(segment.map.uri, segment.map.range)
            if (segment.key?.iv) data = await loader.decrypt(data, segment.key, segment.sequence)
            await files.write(path, data)
          }
          maps.set(mapKey, name)
        }
        if (name !== lastMap) {
          lastMap = name
          lines.push(`#EXT-X-MAP:URI="${name}"`)
        }
      }
      if (segment.discontinuity !== lastDiscontinuity) {
        lastDiscontinuity = segment.discontinuity
        lines.push('#EXT-X-DISCONTINUITY')
      }
      const name = `${job.name}/${i}.${segmentExtension(segment.uri)}`
      const path = `${folder}/${name}`
      const existing = await files.stat(path)
      if (existing) {
        bytes += existing.size
      } else {
        const raw = await loader.fetch(segment.uri, segment.range)
        const data = await loader.decrypt(raw, segment.key, segment.sequence)
        await files.write(`${path}.part`, data)
        await files.rename(`${path}.part`, path)
        bytes += data.byteLength
      }
      lines.push(`#EXTINF:${segment.duration},`, name)
      done += 1
      options.progress({ done, total, bytes })
    }
    lines.push('#EXT-X-ENDLIST')
    await files.write(`${folder}/${job.name}.m3u8`, new TextEncoder().encode(lines.join('\n')))
  }
  if (!variant) return 'main.m3u8'
  const master = ['#EXTM3U', '#EXT-X-VERSION:7']
  let inf = `#EXT-X-STREAM-INF:BANDWIDTH=${variant.bandwidth}`
  if (variant.codecs.length) inf += `,CODECS="${variant.codecs.join(',')}"`
  if (variant.width && variant.height) inf += `,RESOLUTION=${variant.width}x${variant.height}`
  if (jobs.some((j) => j.name === 'audio')) {
    master.push('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"')
    inf += ',AUDIO="audio"'
  }
  master.push(inf, 'main.m3u8')
  await files.write(`${folder}/master.m3u8`, new TextEncoder().encode(master.join('\n')))
  return 'master.m3u8'
}
