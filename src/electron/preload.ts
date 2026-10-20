import { contextBridge, ipcRenderer } from 'electron'
import { BRIDGE_GLOBAL, HOST_CHANNEL, type HostBridge } from './shared'

export function exposeEverythingPlayer(): void {
  const bridge: HostBridge = {
    invoke: (request) => ipcRenderer.invoke(HOST_CHANNEL, request),
  }
  if (process.contextIsolated) contextBridge.exposeInMainWorld(BRIDGE_GLOBAL, bridge)
  else (globalThis as Record<string, unknown>)[BRIDGE_GLOBAL] = bridge
}
