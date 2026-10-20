export const HOST_CHANNEL = 'everything-player:host'
export const FILE_SCHEME = 'everything-player-file'
export const BRIDGE_GLOBAL = 'everythingPlayerHost'

export interface HostInfo {
  version: 1
  root: string
  fileScheme: string
}

export type HostRequest =
  | { op: 'info' }
  | { op: 'stat'; path: string }
  | { op: 'read'; path: string; start?: number; end?: number }
  | { op: 'write'; path: string; data: Uint8Array; append: boolean }
  | { op: 'remove'; path: string }
  | { op: 'mkdir'; path: string }
  | { op: 'rename'; from: string; to: string }
  | { op: 'headers'; url: string; headers: Record<string, string> }

export interface HostBridge {
  invoke(request: HostRequest): Promise<unknown>
}
