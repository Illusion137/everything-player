import type { EmitterSubscription } from '../types/Event'

type Handler = (payload: any) => void

export class Emitter<Map extends object> {
  private handlers = new Map<keyof Map, Set<Handler>>()

  constructor(private onFirstListener: () => void) {}

  on<K extends keyof Map>(
    event: K,
    handler: (payload: Map[K]) => void
  ): EmitterSubscription {
    this.onFirstListener()
    let set = this.handlers.get(event)
    if (!set) {
      set = new Set()
      this.handlers.set(event, set)
    }
    set.add(handler)
    return { remove: () => set.delete(handler) }
  }

  emit<K extends keyof Map>(event: K, payload: Map[K]): void {
    const set = this.handlers.get(event)
    if (!set) return
    for (const handler of [...set]) {
      try {
        handler(payload)
      } catch (e) {
        console.error(
          `[react-native-everything-player] ${String(event)} handler threw`,
          e
        )
      }
    }
  }

  removeAll(event?: keyof Map): void {
    if (event === undefined) this.handlers.clear()
    else this.handlers.delete(event)
  }
}
